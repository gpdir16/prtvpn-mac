// WireGuard 터널 하나의 수명 주기를 관리함.
package main

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

type tunnel struct {
	mu sync.Mutex

	state          string
	lastError      string
	iface          string
	connectedSince time.Time
	config         *TunnelConfig
	firewall       FirewallConfig
	// 자동 모드에서 방화벽이 켜져 있어야 하는지: 연결에 성공하면 참, 사용자가 직접 끊으면 거짓.
	armed bool
	// 곧 연결하려는 VPN 서버 IP. 방화벽이 켜져 있어도 이 서버로는 터널 밖 접속을 허용함.
	prepared string

	dev      *device.Device
	stopChan chan struct{}
}

func newTunnel() *tunnel {
	return &tunnel{state: "disconnected"}
}

func keyToHex(key string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(key))
	if err != nil || len(raw) != 32 {
		return "", fmt.Errorf("키 형식이 올바르지 않음")
	}
	return hex.EncodeToString(raw), nil
}

func uapiConfig(cfg *TunnelConfig) (string, error) {
	privateKey, err := keyToHex(cfg.PrivateKey)
	if err != nil {
		return "", err
	}
	publicKey, err := keyToHex(cfg.PeerPublicKey)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", privateKey)
	b.WriteString("replace_peers=true\n")
	fmt.Fprintf(&b, "public_key=%s\n", publicKey)
	endpoint := cfg.EndpointHost
	if strings.Contains(endpoint, ":") {
		endpoint = "[" + endpoint + "]"
	}
	fmt.Fprintf(&b, "endpoint=%s:%d\n", endpoint, cfg.EndpointPort)
	if cfg.PersistentKeepalive > 0 {
		fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", cfg.PersistentKeepalive)
	}
	b.WriteString("replace_allowed_ips=true\n")
	for _, allowed := range cfg.AllowedIPs {
		fmt.Fprintf(&b, "allowed_ip=%s\n", strings.TrimSpace(allowed))
	}
	return b.String(), nil
}

// connect 는 기존 터널을 내리고 새 설정으로 터널을 올림.
func (t *tunnel) connect(cfg *TunnelConfig) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	t.teardownLocked()

	if cfg.SocketType == "" {
		cfg.SocketType = "udp"
	}
	settings, err := uapiConfig(cfg)
	if err != nil {
		return t.failLocked(err)
	}

	t.config = cfg
	t.state = "connecting"
	t.lastError = ""

	// 방화벽이 켜져 있으면 VPN 서버로 나가는 길을 먼저 열어 줌(그 밖의 트래픽은 계속 막힘).
	if err := t.refreshFirewallLocked(); err != nil {
		return t.failLocked(fmt.Errorf("방화벽 설정 실패: %v", err))
	}

	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = 1280
	}
	tunDevice, err := tun.CreateTUN("utun", mtu)
	if err != nil {
		return t.failLocked(fmt.Errorf("utun 생성 실패: %v", err))
	}
	iface, err := tunDevice.Name()
	if err != nil {
		tunDevice.Close()
		return t.failLocked(err)
	}

	connLogger := conn.Logger{
		Verbosef: func(format string, args ...interface{}) { log.Printf("[wg] "+format, args...) },
		Errorf:   func(format string, args ...interface{}) { log.Printf("[wg][error] "+format, args...) },
	}
	logger := &device.Logger{Logger: connLogger}
	handshakes := make(chan device.HandshakeState, 16)
	socketErrors := make(chan error, 16)
	bind := conn.CreateStdNetBind(cfg.SocketType, &connLogger, socketErrors)
	// TCP/TLS 바인드는 수신 루틴이 시작되자마자 엔드포인트로 접속함. utun 이 올라오는 이벤트만으로도 수신 루틴이
	// 시작되므로, WireGuard 설정(IpcSet)이 엔드포인트를 알려 주기 전에 접속을 시도해 nil 참조로 죽음. 미리 알려 둠.
	if _, err := bind.ParseEndpoint(net.JoinHostPort(cfg.EndpointHost, strconv.Itoa(cfg.EndpointPort))); err != nil {
		tunDevice.Close()
		return t.failLocked(fmt.Errorf("잘못된 엔드포인트: %v", err))
	}
	dev := device.NewDevice(tunDevice, bind, logger, handshakes)

	t.dev = dev
	t.iface = iface
	t.stopChan = make(chan struct{})

	// 엔드포인트 경로는 소켓이 열리기 전에 있어야 함.
	addEndpointRoute(cfg.EndpointHost)

	if err := dev.IpcSet(settings); err != nil {
		return t.failLocked(fmt.Errorf("WireGuard 설정 실패: %v", err))
	}
	if err := dev.Up(); err != nil {
		return t.failLocked(fmt.Errorf("WireGuard 시작 실패: %v", err))
	}
	if err := configureInterface(iface, cfg); err != nil {
		return t.failLocked(err)
	}
	// 터널 인터페이스를 지나는 트래픽을 허용함.
	if err := t.refreshFirewallLocked(); err != nil {
		return t.failLocked(fmt.Errorf("방화벽 설정 실패: %v", err))
	}
	if err := addTunnelRoutes(iface, cfg); err != nil {
		return t.failLocked(err)
	}
	if err := setDNS(cfg.DNS); err != nil {
		return t.failLocked(fmt.Errorf("DNS 설정 실패: %v", err))
	}

	go t.watch(dev, cfg, handshakes, socketErrors, t.stopChan)
	log.Printf("터널 시작: %s, 서버 %s:%d (%s)", iface, cfg.EndpointHost, cfg.EndpointPort, cfg.SocketType)
	return nil
}

// watch 는 핸드셰이크 결과를 상태에 반영하고, 네트워크가 바뀌면 엔드포인트 경로를 다시 잡음.
func (t *tunnel) watch(dev *device.Device, cfg *TunnelConfig, handshakes <-chan device.HandshakeState, socketErrors <-chan error, stop <-chan struct{}) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	lastGateway, lastIface := defaultRouteExcludingTunnel(cfg.EndpointHost)
	for {
		select {
		case <-stop:
			return
		case state := <-handshakes:
			t.mu.Lock()
			if t.dev == dev {
				switch state {
				case device.HandshakeSuccess:
					if t.state != "connected" {
						t.state = "connected"
						t.connectedSince = time.Now()
						log.Printf("핸드셰이크 성공, 연결됨")
						t.armLocked()
					}
				case device.HandshakeFail:
					log.Printf("핸드셰이크 실패 (계속 재시도)")
				}
			}
			t.mu.Unlock()
		case err := <-socketErrors:
			log.Printf("소켓 오류: %v", err)
		case <-ticker.C:
			gateway, iface := defaultRouteExcludingTunnel(cfg.EndpointHost)
			if gateway != lastGateway || iface != lastIface {
				log.Printf("기본 경로 변경: %s(%s) 에서 %s(%s) 로", lastGateway, lastIface, gateway, iface)
				lastGateway, lastIface = gateway, iface
				if gateway != "" {
					addEndpointRoute(cfg.EndpointHost)
					if err := dev.BindUpdate(); err == nil {
						dev.SendKeepalivesToPeersWithCurrentKeypair()
					}
				}
			}
			// 핸드셰이크 알림을 놓쳤을 때를 대비해 실제 핸드셰이크 시각도 확인함.
			t.mu.Lock()
			if t.dev == dev && t.state == "connecting" && lastHandshake(dev) > 0 {
				t.state = "connected"
				t.connectedSince = time.Now()
				t.armLocked()
			}
			t.mu.Unlock()
		}
	}
}

// defaultRouteExcludingTunnel 은 터널이 0/1, 128/1 로 덮고 있어도 남아 있는 실제 기본 경로를 봄.
func defaultRouteExcludingTunnel(endpoint string) (string, string) {
	family := "-inet"
	if strings.Contains(endpoint, ":") {
		family = "-inet6"
	}
	return defaultRoute(family)
}

func ipcValue(dev *device.Device, key string) uint64 {
	settings, err := dev.IpcGet()
	if err != nil {
		return 0
	}
	var total uint64
	for _, line := range strings.Split(settings, "\n") {
		if strings.HasPrefix(line, key+"=") {
			value, _ := strconv.ParseUint(strings.TrimPrefix(line, key+"="), 10, 64)
			total += value
		}
	}
	return total
}

func lastHandshake(dev *device.Device) uint64 {
	return ipcValue(dev, "last_handshake_time_sec")
}

func (t *tunnel) failLocked(err error) error {
	log.Printf("연결 실패: %v", err)
	t.teardownLocked()
	t.state = "error"
	t.lastError = err.Error()
	return err
}

// refreshFirewallLocked 는 현재 터널 상태에 맞춰 방화벽 규칙을 다시 씀.
func (t *tunnel) refreshFirewallLocked() error {
	var servers []string
	if t.config != nil {
		servers = append(servers, t.config.EndpointHost)
	}
	if t.prepared != "" && (t.config == nil || t.prepared != t.config.EndpointHost) {
		servers = append(servers, t.prepared)
	}
	return applyFirewall(t.firewall, t.armed, t.iface, servers)
}

// armLocked 는 연결에 성공했음을 기록함. 자동 모드라면 이때부터 방화벽이 켜짐.
func (t *tunnel) armLocked() {
	if t.armed {
		return
	}
	t.armed = true
	saveFirewallArmed(true)
	if err := t.refreshFirewallLocked(); err != nil {
		log.Printf("방화벽 갱신 실패: %v", err)
	}
}

// disarm 은 사용자가 직접 연결을 끊으려 함을 기록함. 자동 모드라면 방화벽이 꺼짐.
// 앱이 스스로 끊거나(재연결, 시간 초과) 터널이 죽은 경우에는 부르지 않으므로, 그때는 방화벽이 켜진 채로 남음.
func (t *tunnel) disarm() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.armed {
		return
	}
	t.armed = false
	saveFirewallArmed(false)
	log.Printf("방화벽: 사용자가 연결을 끊음")
	if err := t.refreshFirewallLocked(); err != nil {
		log.Printf("방화벽 갱신 실패: %v", err)
	}
}

// prepare 는 곧 연결할 VPN 서버를 방화벽 예외에 넣음. 다음 prepare 나 disconnect 까지 유지됨.
func (t *tunnel) prepare(endpoint string) error {
	if net.ParseIP(endpoint) == nil {
		return fmt.Errorf("잘못된 서버 주소")
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.prepared = endpoint
	return t.refreshFirewallLocked()
}

// teardownLocked 는 터널과 시스템 설정을 정리함.
// 방화벽 스위치는 터널과 무관하므로 건드리지 않음. 켜져 있으면 터널이 없는 동안 전부 막힘.
func (t *tunnel) teardownLocked() {
	if t.stopChan != nil {
		close(t.stopChan)
		t.stopChan = nil
	}
	if t.dev != nil {
		// 인터페이스가 사라지면 그 인터페이스의 주소와 경로도 함께 사라짐.
		t.dev.Close()
		t.dev = nil
	}
	if t.config != nil {
		removeEndpointRoute(t.config.EndpointHost)
	}
	restoreDNS()
	t.iface = ""
	t.config = nil
	t.connectedSince = time.Time{}
	t.state = "disconnected"
	if err := t.refreshFirewallLocked(); err != nil {
		log.Printf("방화벽 갱신 실패: %v", err)
	}
}

func (t *tunnel) disconnect() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.prepared = ""
	t.teardownLocked()
	t.lastError = ""
	log.Printf("터널 종료")
}

// setFirewall 은 방화벽 스위치를 바꾸고 바로 적용함.
func (t *tunnel) setFirewall(config FirewallConfig) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if err := saveFirewallConfig(config); err != nil {
		return err
	}
	t.firewall = config
	// 이미 연결된 상태에서 자동 모드로 바꾸면 바로 켜져야 함.
	if t.state == "connected" && !t.armed {
		t.armed = true
		saveFirewallArmed(true)
	}
	log.Printf("방화벽: mode=%s allowLAN=%v armed=%v", config.mode(), config.AllowLAN, t.armed)
	return t.refreshFirewallLocked()
}

func (t *tunnel) status() Status {
	t.mu.Lock()
	defer t.mu.Unlock()
	status := Status{
		State:         t.state,
		Interface:     t.iface,
		LastError:     t.lastError,
		Firewall:      t.firewall.mode() != firewallOff,
		FirewallMode:  t.firewall.mode(),
		FirewallArmed: t.armed,
		Version:       daemonVersion,
	}
	if !t.connectedSince.IsZero() {
		status.ConnectedSince = t.connectedSince.Unix()
	}
	if t.dev != nil {
		status.RxBytes = ipcValue(t.dev, "rx_bytes")
		status.TxBytes = ipcValue(t.dev, "tx_bytes")
	}
	return status
}
