// 시스템 네트워크 설정(주소, 경로, DNS, 방화벽)을 다루는 부분.
// wireguard-tools 의 wg-quick(darwin) 이 하는 일과 같은 순서를 따름.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
)

const (
	stateDir      = "/var/db/prtvpn"
	dnsBackupPath = stateDir + "/dns-backup.json"
	pfRulesPath   = stateDir + "/firewall.pf.conf"
	// 방화벽 스위치 상태. 데몬이 죽거나 재부팅해도 켜진 상태가 유지되도록 디스크에 둠.
	firewallStatePath = stateDir + "/firewall.json"
	// 자동 모드에서 방화벽이 켜져 있어야 하는지. 내용은 그 시점의 부팅 시각이라, 재부팅하면 저절로 무효가 됨.
	firewallArmedPath = stateDir + "/firewall-armed"
	// macOS 기본 pf.conf 는 `anchor "com.apple/*"` 를 평가하므로 그 아래에 두면 기본 규칙 파일을 고치지 않아도 됨.
	pfAnchor = "com.apple/prtvpn"
)

func run(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	text := strings.TrimSpace(string(out))
	if err != nil {
		return text, fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, text)
	}
	return text, nil
}

// defaultRoute 는 터널이 아닌 실제 기본 경로의 게이트웨이와 인터페이스를 돌려줌.
func defaultRoute(family string) (gateway, iface string) {
	out, err := run("/sbin/route", "-n", "get", family, "default")
	if err != nil {
		return "", ""
	}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		switch fields[0] {
		case "gateway:":
			gateway = fields[1]
		case "interface:":
			iface = fields[1]
		}
	}
	return gateway, iface
}

func configureInterface(iface string, cfg *TunnelConfig) error {
	for _, cidr := range cfg.Addresses {
		ip, _, err := net.ParseCIDR(cidr)
		if err != nil {
			return fmt.Errorf("잘못된 주소 %q: %v", cidr, err)
		}
		if ip.To4() != nil {
			if _, err := run("/sbin/ifconfig", iface, "inet", cidr, ip.String(), "alias"); err != nil {
				return err
			}
		} else {
			if _, err := run("/sbin/ifconfig", iface, "inet6", cidr, "alias"); err != nil {
				return err
			}
		}
	}
	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = 1280
	}
	_, err := run("/sbin/ifconfig", iface, "mtu", fmt.Sprint(mtu), "up")
	return err
}

// addEndpointRoute 는 VPN 서버로 가는 패킷이 터널로 되돌아오지 않도록 실제 게이트웨이를 통하는 호스트 경로를 넣음.
func addEndpointRoute(endpoint string) {
	ip := net.ParseIP(endpoint)
	if ip == nil {
		return
	}
	family := "-inet"
	if ip.To4() == nil {
		family = "-inet6"
	}
	run("/sbin/route", "-q", "-n", "delete", family, endpoint)
	gateway, iface := defaultRoute(family)
	if gateway == "" || strings.HasPrefix(iface, "utun") {
		return
	}
	if strings.HasPrefix(gateway, "link#") {
		run("/sbin/route", "-q", "-n", "add", family, endpoint, "-interface", iface)
	} else {
		run("/sbin/route", "-q", "-n", "add", family, endpoint, gateway)
	}
}

func removeEndpointRoute(endpoint string) {
	ip := net.ParseIP(endpoint)
	if ip == nil {
		return
	}
	family := "-inet"
	if ip.To4() == nil {
		family = "-inet6"
	}
	run("/sbin/route", "-q", "-n", "delete", family, endpoint)
}

// addTunnelRoutes 는 기본 경로를 지우지 않고 /1 두 개로 덮어, 터널이 내려가면 원래 경로가 그대로 살아나게 함.
func addTunnelRoutes(iface string, cfg *TunnelConfig) error {
	hasV6 := false
	for _, allowed := range cfg.AllowedIPs {
		_, network, err := net.ParseCIDR(strings.TrimSpace(allowed))
		if err != nil {
			return fmt.Errorf("잘못된 AllowedIPs %q: %v", allowed, err)
		}
		ones, _ := network.Mask.Size()
		isV4 := network.IP.To4() != nil
		var routes []string
		family := "-inet"
		switch {
		case isV4 && ones == 0:
			routes = []string{"0.0.0.0/1", "128.0.0.0/1"}
		case !isV4 && ones == 0:
			family, routes, hasV6 = "-inet6", []string{"::/1", "8000::/1"}, true
		case isV4:
			routes = []string{network.String()}
		default:
			family, routes, hasV6 = "-inet6", []string{network.String()}, true
		}
		for _, route := range routes {
			if _, err := run("/sbin/route", "-q", "-n", "add", family, route, "-interface", iface); err != nil {
				return err
			}
		}
	}
	// 터널에 IPv6 가 없어도 IPv6 트래픽이 터널 밖으로 새지 않도록 터널로 보내 버림.
	if !hasV6 {
		run("/sbin/route", "-q", "-n", "add", "-inet6", "::/1", "-interface", iface)
		run("/sbin/route", "-q", "-n", "add", "-inet6", "8000::/1", "-interface", iface)
	}
	return nil
}

// MARK: DNS

type dnsBackup struct {
	Servers map[string][]string `json:"servers"` // 네트워크 서비스 이름별 원래 DNS 서버 (비어 있으면 자동)
}

func networkServices() []string {
	out, err := run("/usr/sbin/networksetup", "-listallnetworkservices")
	if err != nil {
		return nil
	}
	var services []string
	for i, line := range strings.Split(out, "\n") {
		// 첫 줄은 안내문, '*' 로 시작하면 비활성 서비스
		if i == 0 || line == "" || strings.HasPrefix(line, "*") {
			continue
		}
		services = append(services, line)
	}
	return services
}

func setDNS(servers []string) error {
	if len(servers) == 0 {
		return nil
	}
	// 이미 백업이 있으면(이전 연결이 정리되지 않은 경우) 그 백업을 원본으로 유지함.
	if _, err := os.Stat(dnsBackupPath); err != nil {
		backup := dnsBackup{Servers: map[string][]string{}}
		for _, service := range networkServices() {
			out, _ := run("/usr/sbin/networksetup", "-getdnsservers", service)
			var current []string
			for _, line := range strings.Split(out, "\n") {
				if net.ParseIP(strings.TrimSpace(line)) != nil {
					current = append(current, strings.TrimSpace(line))
				}
			}
			backup.Servers[service] = current
		}
		data, _ := json.Marshal(backup)
		if err := os.WriteFile(dnsBackupPath, data, 0o600); err != nil {
			return err
		}
	}
	for _, service := range networkServices() {
		args := append([]string{"-setdnsservers", service}, servers...)
		run("/usr/sbin/networksetup", args...)
	}
	run("/usr/bin/dscacheutil", "-flushcache")
	run("/usr/bin/killall", "-HUP", "mDNSResponder")
	return nil
}

func restoreDNS() {
	data, err := os.ReadFile(dnsBackupPath)
	if err != nil {
		return
	}
	var backup dnsBackup
	if json.Unmarshal(data, &backup) == nil {
		for service, servers := range backup.Servers {
			args := []string{"-setdnsservers", service}
			if len(servers) == 0 {
				args = append(args, "Empty")
			} else {
				args = append(args, servers...)
			}
			run("/usr/sbin/networksetup", args...)
		}
	}
	os.Remove(dnsBackupPath)
	run("/usr/bin/dscacheutil", "-flushcache")
	run("/usr/bin/killall", "-HUP", "mDNSResponder")
}

// MARK: 방화벽 (pf)

func loadFirewallConfig() FirewallConfig {
	var config FirewallConfig
	if data, err := os.ReadFile(firewallStatePath); err == nil {
		json.Unmarshal(data, &config)
	}
	return config
}

func saveFirewallConfig(config FirewallConfig) error {
	data, _ := json.Marshal(config)
	return os.WriteFile(firewallStatePath, data, 0o600)
}

// mode 는 설정의 방화벽 모드를 돌려줌. 모르는 값이면 꺼진 것으로 봄.
func (config FirewallConfig) mode() string {
	switch config.Mode {
	case firewallOff, firewallAuto, firewallOn, firewallLockdown:
		return config.Mode
	}
	return firewallOff
}

// bootID 는 이번 부팅을 구분하는 값임.
func bootID() string {
	out, err := run("/usr/sbin/sysctl", "-n", "kern.boottime")
	if err != nil {
		return ""
	}
	return out
}

// loadFirewallArmed 는 자동 모드의 방화벽이 켜져 있어야 하는지 읽음.
// 데몬이 죽었다 살아나도 유지되지만, 재부팅하면 풀림(재부팅 뒤에는 사용자가 다시 연결하기 전까지 막을 이유가 없음).
func loadFirewallArmed() bool {
	data, err := os.ReadFile(firewallArmedPath)
	if err != nil {
		return false
	}
	id := bootID()
	return id != "" && strings.TrimSpace(string(data)) == id
}

func saveFirewallArmed(armed bool) {
	if !armed {
		os.Remove(firewallArmedPath)
		return
	}
	if err := os.WriteFile(firewallArmedPath, []byte(bootID()), 0o600); err != nil {
		log.Printf("방화벽 상태 저장 실패: %v", err)
	}
}

// applyFirewall 은 방화벽 설정을 pf 에 반영함.
// 켜져 있으면 루프백, 터널, VPN 서버로 가는 패킷, DHCP, 예외 IP 만 허용하고 나머지를 모두 막음.
// armed 는 자동 모드에서만 봄: 참이면 켜진 것처럼, 거짓이면 꺼진 것처럼 동작함.
// iface 와 cfg 는 현재 터널이 없으면 비어 있음(그러면 터널 관련 허용 규칙 없이 막기만 함).
// servers 는 터널 밖으로도 접속을 허용할 VPN 서버 IP 다 (연결 중인 서버와, 곧 연결하려고 포트를 탐색 중인 서버).
func applyFirewall(config FirewallConfig, armed bool, iface string, servers []string) error {
	mode := config.mode()
	if mode == firewallOff || (mode == firewallAuto && !armed) {
		disableFirewall()
		return nil
	}
	if mode == firewallLockdown {
		// 터널도, VPN 서버도, LAN 도, API 서버도 열지 않음. 주소 할당(DHCP, 이웃 탐색)만 남겨 모드를 바꾸면 바로 복구되게 함.
		writeHostsBlock(nil)
		var rules strings.Builder
		rules.WriteString("pass quick on lo0 all\n")
		rules.WriteString("pass quick inet proto udp from any port { 67, 68 } to any port { 67, 68 }\n")
		rules.WriteString("pass quick inet6 proto udp from any port { 546, 547 } to any port { 546, 547 }\n")
		rules.WriteString("pass quick inet6 proto ipv6-icmp all icmp6-type { routersol, routeradv, neighbrsol, neighbradv }\n")
		rules.WriteString("block drop quick all\n")
		return loadFirewallRules(rules.String())
	}

	var rules strings.Builder
	var allowed []string
	for name, addresses := range config.AllowedHosts {
		if !isAllowedHostname(name) {
			continue
		}
		for _, address := range addresses {
			if net.ParseIP(address) != nil {
				allowed = append(allowed, address)
			}
		}
	}
	sort.Strings(allowed)
	writeHostsBlock(config.AllowedHosts)
	if len(allowed) > 0 {
		fmt.Fprintf(&rules, "table <prtvpn_allowed> const { %s }\n", strings.Join(allowed, ", "))
	}
	if config.AllowLAN {
		rules.WriteString("table <prtvpn_lan> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, fe80::/10, ff00::/8 }\n")
	}
	rules.WriteString("pass quick on lo0 all\n")
	if iface != "" {
		fmt.Fprintf(&rules, "pass quick on %s all\n", iface)
	}
	for _, server := range servers {
		ip := net.ParseIP(server)
		if ip == nil {
			continue
		}
		family := "inet"
		if ip.To4() == nil {
			family = "inet6"
		}
		// 포트는 제한하지 않음: 전송 방식(UDP/TCP/TLS)에 따라 쓰는 포트가 다르고, 앱이 연결 전에 여러 포트를 탐색함.
		fmt.Fprintf(&rules, "pass out quick %s proto { udp, tcp } to %s\n", family, ip.String())
	}
	rules.WriteString("pass quick inet proto udp from any port { 67, 68 } to any port { 67, 68 }\n")
	rules.WriteString("pass quick inet6 proto udp from any port { 546, 547 } to any port { 546, 547 }\n")
	rules.WriteString("pass quick inet6 proto ipv6-icmp all icmp6-type { routersol, routeradv, neighbrsol, neighbradv }\n")
	if len(allowed) > 0 {
		rules.WriteString("pass out quick proto tcp to <prtvpn_allowed> port 443\n")
	}
	if config.AllowLAN {
		rules.WriteString("pass out quick to <prtvpn_lan>\n")
		rules.WriteString("pass in quick from <prtvpn_lan>\n")
	}
	rules.WriteString("block drop quick all\n")
	return loadFirewallRules(rules.String())
}

// loadFirewallRules 는 규칙을 pf 앵커에 올리고 pf 를 켬.
func loadFirewallRules(rules string) error {
	if err := os.WriteFile(pfRulesPath, []byte(rules), 0o600); err != nil {
		return err
	}
	if _, err := run("/sbin/pfctl", "-a", pfAnchor, "-f", pfRulesPath); err != nil {
		return err
	}
	// pf 가 꺼져 있으면 참조 토큰을 받아 켬. 토큰은 끌 때 돌려줌.
	// 재부팅하면 토큰은 무효가 되므로, 이번 부팅에서 받은 토큰인지 메모리로만 기억함.
	if pfToken == "" {
		out, err := run("/sbin/pfctl", "-E")
		if err != nil {
			return err
		}
		for _, line := range strings.Split(out, "\n") {
			if strings.HasPrefix(line, "Token : ") {
				pfToken = strings.TrimPrefix(line, "Token : ")
			}
		}
	}
	return nil
}

var pfToken string

func disableFirewall() {
	writeHostsBlock(nil)
	run("/sbin/pfctl", "-a", pfAnchor, "-F", "all")
	if pfToken != "" {
		run("/sbin/pfctl", "-X", pfToken)
		pfToken = ""
	}
	os.Remove(pfRulesPath)
}

// MARK: /etc/hosts

const (
	hostsPath       = "/etc/hosts"
	hostsBlockBegin = "# prtvpn firewall begin"
	hostsBlockEnd   = "# prtvpn firewall end"
)

var hostnamePattern = regexp.MustCompile(`^[A-Za-z0-9.-]+$`)

// /etc/hosts 에 적어 줄 수 있는 이름. Proton 의 API 도메인만 받음.
// 아무 이름이나 받으면 앱이 장악됐을 때 다른 사이트의 주소를 바꿔치기하는 데 쓰일 수 있음.
var allowedHostSuffixes = []string{".proton.me", ".protonvpn.ch", ".protonvpn.com"}

func isAllowedHostname(name string) bool {
	if !hostnamePattern.MatchString(name) {
		return false
	}
	name = strings.ToLower(name)
	for _, suffix := range allowedHostSuffixes {
		if strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return false
}

// writeHostsBlock 은 /etc/hosts 에서 prtvpn 구간만 바꿔 씀. hosts 가 비어 있으면 구간을 지움.
func writeHostsBlock(hosts map[string][]string) {
	data, err := os.ReadFile(hostsPath)
	if err != nil {
		return
	}
	var kept []string
	inBlock := false
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		switch {
		case line == hostsBlockBegin:
			inBlock = true
		case line == hostsBlockEnd:
			inBlock = false
		case !inBlock:
			kept = append(kept, line)
		}
	}
	var names []string
	for name := range hosts {
		if isAllowedHostname(name) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	var block []string
	for _, name := range names {
		for _, address := range hosts[name] {
			if net.ParseIP(address) != nil {
				block = append(block, address+" "+name)
			}
		}
	}
	if len(block) > 0 {
		kept = append(kept, hostsBlockBegin)
		kept = append(kept, block...)
		kept = append(kept, hostsBlockEnd)
	}
	content := strings.Join(kept, "\n") + "\n"
	if content == string(data) {
		return
	}
	// 같은 디렉터리에 임시 파일을 쓰고 바꿔치기해, 쓰다 죽어도 hosts 파일이 깨지지 않게 함.
	temporary := hostsPath + ".prtvpn.tmp"
	if err := os.WriteFile(temporary, []byte(content), 0o644); err != nil {
		return
	}
	if err := os.Rename(temporary, hostsPath); err != nil {
		os.Remove(temporary)
		return
	}
	run("/usr/bin/dscacheutil", "-flushcache")
	run("/usr/bin/killall", "-HUP", "mDNSResponder")
}
