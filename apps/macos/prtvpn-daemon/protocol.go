// prtvpn 터널 데몬과 앱이 주고받는 메시지 정의.
// 유닉스 소켓 위에서 한 줄에 JSON 하나씩 요청/응답함.
package main

// Request 는 앱이 데몬에 보내는 명령임.
type Request struct {
	Command  string          `json:"command"` // "status" | "prepare" | "connect" | "disconnect" | "disarm" | "firewall" | "app" | "version"
	Config   *TunnelConfig   `json:"config,omitempty"`
	Firewall *FirewallConfig `json:"firewall,omitempty"`
	// "prepare": 곧 연결할 VPN 서버의 IP. 방화벽이 켜져 있어도 앱이 연결 전에 이 서버의 포트를 탐색할 수 있게 열어 둠.
	Endpoint string `json:"endpoint,omitempty"`
	// "app": 앱 번들의 위치. 앱이 사라졌는지 데몬이 확인하는 데 씀.
	AppPath string `json:"appPath,omitempty"`
}

// TunnelConfig 는 터널 하나를 올리는 데 필요한 모든 값임.
type TunnelConfig struct {
	PrivateKey          string   `json:"privateKey"` // base64
	Addresses           []string `json:"addresses"`  // CIDR, 예: "10.2.0.2/32"
	DNS                 []string `json:"dns"`
	PeerPublicKey       string   `json:"peerPublicKey"` // base64
	EndpointHost        string   `json:"endpointHost"`  // IP 주소
	EndpointPort        int      `json:"endpointPort"`
	AllowedIPs          []string `json:"allowedIPs"`
	PersistentKeepalive int      `json:"persistentKeepalive"`
	SocketType          string   `json:"socketType"` // "udp" | "tcp" | "tls"
	MTU                 int      `json:"mtu"`
}

// 방화벽 모드.
const (
	// 아무것도 막지 않음.
	firewallOff = "off"
	// VPN 에 연결되면 켜지고, 사용자가 직접 연결을 끊으면 꺼짐. 예기치 않게 끊긴 동안에는 켜진 채로 남음.
	firewallAuto = "auto"
	// 항상 VPN 터널을 지나는 트래픽만 통과시킴(연결이 끊겨 있어도, 재부팅해도 유지).
	firewallOn = "on"
	// VPN 터널을 포함해 인터넷으로 나가는 모든 트래픽을 막음.
	firewallLockdown = "lockdown"
)

// FirewallConfig 는 방화벽 설정임.
type FirewallConfig struct {
	Mode     string `json:"mode"`
	AllowLAN bool   `json:"allowLAN"`
	// 방화벽이 켜진 채로도 앱이 로그인하고 서버 목록을 받을 수 있도록 예외로 둘 API 서버 (호스트 이름별 IP 목록).
	// 방화벽이 켜져 있으면 DNS 질의도 막히므로, 이 이름들은 /etc/hosts 에 적어 DNS 없이 풀리게 함.
	AllowedHosts map[string][]string `json:"allowedHosts"`
}

// Status 는 데몬의 현재 터널 상태임.
type Status struct {
	State          string `json:"state"` // "disconnected" | "connecting" | "connected" | "error"
	Interface      string `json:"interface,omitempty"`
	ConnectedSince int64  `json:"connectedSince,omitempty"` // 유닉스 초
	LastError      string `json:"lastError,omitempty"`
	RxBytes        uint64 `json:"rxBytes"`
	TxBytes        uint64 `json:"txBytes"`
	Firewall       bool   `json:"firewall"`
	FirewallMode   string `json:"firewallMode"`
	// 자동 모드에서 방화벽이 지금 막고 있는지 (연결된 적이 있고, 사용자가 끊지 않았음)
	FirewallArmed bool   `json:"firewallArmed"`
	Version       string `json:"version"`
}

// Response 는 모든 명령에 대한 응답임.
type Response struct {
	OK     bool   `json:"ok"`
	Error  string `json:"error,omitempty"`
	Status Status `json:"status"`
}

const daemonVersion = "1.0"
