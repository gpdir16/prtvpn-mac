// prtvpn 터널 데몬. launchd 가 루트로 실행하며, 앱의 요청을 받아 utun 인터페이스 위에 WireGuard 터널을 올림.
// (NetworkExtension 을 쓰지 않으므로 Apple 개발자 서명이 필요 없음.)
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"golang.org/x/sys/unix"
)

const socketPath = "/var/run/prtvpn-daemon.sock"

func peerUID(c *net.UnixConn) (uint32, bool) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, false
	}
	var uid uint32
	ok := false
	raw.Control(func(fd uintptr) {
		cred, err := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if err == nil {
			uid, ok = cred.Uid, true
		}
	})
	return uid, ok
}

func handle(c *net.UnixConn, t *tunnel, allowedUID int, requirement string) {
	defer c.Close()
	// 소켓 권한에 더해, 접속한 프로세스의 사용자도 확인함.
	if uid, ok := peerUID(c); !ok || (uid != 0 && int(uid) != allowedUID) {
		log.Printf("허용되지 않은 사용자의 접속 거부")
		return
	}
	// 같은 사용자의 다른 프로세스가 터널이나 방화벽을 조작하지 못하도록, 설치한 앱의 코드 서명인지 확인함.
	if err := verifyPeer(c, requirement); err != nil {
		log.Printf("접속 거부: %v", err)
		return
	}
	scanner := bufio.NewScanner(c)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	encoder := json.NewEncoder(c)
	for scanner.Scan() {
		var request Request
		response := Response{OK: true}
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			response.OK, response.Error = false, "잘못된 요청"
		} else {
			switch request.Command {
			case "status", "version":
			case "prepare":
				if err := t.prepare(request.Endpoint); err != nil {
					response.OK, response.Error = false, err.Error()
				}
			case "connect":
				if request.Config == nil {
					response.OK, response.Error = false, "설정이 없음"
				} else if err := t.connect(request.Config); err != nil {
					response.OK, response.Error = false, err.Error()
				}
			case "disconnect":
				t.disconnect()
			case "disarm":
				t.disarm()
			case "app":
				if err := setAppPath(request.AppPath); err != nil {
					response.OK, response.Error = false, err.Error()
				}
			case "firewall":
				if request.Firewall == nil {
					response.OK, response.Error = false, "방화벽 설정이 없음"
				} else if err := t.setFirewall(*request.Firewall); err != nil {
					response.OK, response.Error = false, err.Error()
				}
			default:
				response.OK, response.Error = false, "알 수 없는 명령"
			}
		}
		response.Status = t.status()
		if err := encoder.Encode(response); err != nil {
			return
		}
	}
}

func main() {
	allowedUID := flag.Int("uid", -1, "소켓 접속을 허용할 사용자 ID")
	requirement := flag.String("requirement", "", "접속을 허용할 앱의 코드 서명 요구 조건")
	flag.Parse()
	log.SetFlags(log.LstdFlags)

	if os.Geteuid() != 0 {
		log.Fatal("루트 권한으로 실행해야 합니다")
	}
	if *allowedUID < 0 {
		log.Fatal("-uid 가 필요합니다")
	}
	if *requirement == "" {
		log.Fatal("-requirement 가 필요합니다")
	}
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		log.Fatal(err)
	}

	// 로그에는 접속한 서버 주소가 남으므로 앱을 설치한 사용자만 읽을 수 있게 함. 파일은 launchd 가 만듦.
	os.Chown(daemonLogPath, *allowedUID, 0)
	os.Chmod(daemonLogPath, 0o600)

	// 이전 실행이 비정상 종료했을 때 남은 DNS 설정을 되돌림.
	restoreDNS()

	os.Remove(socketPath)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		log.Fatal(err)
	}
	if err := os.Chown(socketPath, *allowedUID, 0); err != nil {
		log.Fatal(err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		log.Fatal(err)
	}

	t := newTunnel()
	// 방화벽 설정은 데몬 재시작이나 재부팅과 무관하게 유지됨. 켜져 있었다면 터널이 없는 지금은 전부 막음.
	t.firewall = loadFirewallConfig()
	t.armed = loadFirewallArmed()
	if err := applyFirewall(t.firewall, t.armed, "", nil); err != nil {
		log.Printf("방화벽 복원 실패: %v", err)
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-signals
		log.Printf("종료 신호 수신, 정리 후 종료")
		t.disconnect()
		listener.Close()
		os.Remove(socketPath)
		os.Exit(0)
	}()

	go watchApp(t, *allowedUID)
	go announceInstall(*allowedUID)

	log.Printf("prtvpn-daemon v%s 시작 (uid %d 허용)", daemonVersion, *allowedUID)
	for {
		c, err := listener.AcceptUnix()
		if err != nil {
			log.Printf("accept 실패: %v", err)
			return
		}
		go handle(c, t, *allowedUID, *requirement)
	}
}
