// 앱이 사라졌을 때 사용자에게 알리고 데몬을 스스로 제거하는 부분.
// 앱만 지우면 데몬과 방화벽이 남아 인터넷이 막힌 채로 복구할 방법이 없어지므로, 데몬이 직접 확인함.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/user"
	"strings"
	"time"
)

const (
	// 앱이 마지막으로 알려 준 자기 위치. 앱을 실행할 때마다 갱신됨.
	appPathFile      = stateDir + "/app-path"
	launchdLabel     = "app.prtvpn.daemon"
	launchDaemonPath = "/Library/LaunchDaemons/app.prtvpn.daemon.plist"
	daemonLogPath    = "/var/log/prtvpn-daemon.log"
	// 마지막으로 실행된 데몬 파일의 해시. 설치나 업데이트 직후인지 가리는 데 씀.
	installedHashFile = stateDir + "/installed-hash"

	appCheckInterval = 20 * time.Second
	// 업데이트나 재설치로 앱이 잠깐 없어지는 경우를 거르기 위해, 연속으로 이만큼 없어야 사라진 것으로 봄.
	appMissingChecks = 3
	// 사용자가 나중에 하겠다고 하면 이만큼 지난 뒤 다시 물음.
	appPromptSnooze = 24 * time.Hour
)

func loadAppPath() string {
	data, err := os.ReadFile(appPathFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// setAppPath 는 앱이 알려 준 위치를 기억함. 앱 번들 경로만 받음.
func setAppPath(path string) error {
	if !strings.HasPrefix(path, "/") || !strings.HasSuffix(path, ".app") {
		return fmt.Errorf("잘못된 앱 경로")
	}
	return os.WriteFile(appPathFile, []byte(path), 0o600)
}

// watchApp 은 앱이 계속 있는지 지켜보다가, 사라지면 사용자에게 데몬을 제거할지 물음.
func watchApp(t *tunnel, uid int) {
	missing := 0
	var snoozedUntil time.Time
	for {
		time.Sleep(appCheckInterval)
		path := loadAppPath()
		if path == "" {
			// 앱이 아직 위치를 알려 준 적이 없음. 판단할 근거가 없으므로 아무것도 하지 않음.
			continue
		}
		if _, err := os.Stat(path); err == nil {
			missing = 0
			continue
		}
		missing++
		if missing < appMissingChecks || time.Now().Before(snoozedUntil) {
			continue
		}
		log.Printf("앱을 찾을 수 없음: %s", path)
		remove, asked := askToUninstall(t, uid, path)
		if !asked {
			// 로그인한 사용자가 없어 물어보지 못했음. 다음 확인 때 다시 시도함.
			continue
		}
		// 묻는 동안 앱이 돌아왔으면(옮긴 앱을 다시 실행해 새 위치를 알려 준 경우 포함) 없던 일로 함.
		if current := loadAppPath(); current != "" {
			if _, err := os.Stat(current); err == nil {
				missing = 0
				continue
			}
		}
		if remove {
			uninstall(t, uid)
			return
		}
		snoozedUntil = time.Now().Add(appPromptSnooze)
	}
}

// userPrefersKorean 은 사용자의 macOS 언어가 한국어인지 봄.
func userPrefersKorean(uid int) bool {
	// 데몬은 루트라서 그냥 읽으면 루트의 설정이 나옴. 사용자의 설정 파일을 직접 읽음.
	account, err := user.LookupId(fmt.Sprint(uid))
	if err != nil {
		return false
	}
	out, err := run("/usr/bin/defaults", "read", account.HomeDir+"/Library/Preferences/.GlobalPreferences", "AppleLanguages")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.Trim(strings.TrimSpace(line), "\",")
		if line == "" || line == "(" || line == ")" {
			continue
		}
		return strings.HasPrefix(line, "ko")
	}
	return false
}

// askToUninstall 은 사용자의 화면에 안내 창을 띄움. asked 가 거짓이면 창을 띄우지 못한 것임.
func askToUninstall(t *tunnel, uid int, path string) (remove, asked bool) {
	status := t.status()
	blocking := status.FirewallMode == firewallOn || status.FirewallMode == firewallLockdown ||
		(status.FirewallMode == firewallAuto && status.FirewallArmed)

	var message, later, removeButton string
	if userPrefersKorean(uid) {
		message = "prtvpn 앱을 찾을 수 없습니다.\n" + path + "\n\n터널 데몬과 방화벽은 아직 이 Mac에 남아 있습니다."
		if blocking {
			message += " 방화벽이 켜져 있어 인터넷이 차단되고 있을 수 있습니다."
		}
		message += "\n\n제거를 누르면 VPN 연결을 끊고 방화벽을 푼 뒤 데몬을 지웁니다.\n앱을 다른 위치로 옮겼다면 \"나중에\"를 누르고 앱을 한 번 실행하세요."
		later, removeButton = "나중에", "제거"
	} else {
		message = "The prtvpn app could not be found.\n" + path + "\n\nIts tunnel daemon and firewall are still on this Mac."
		if blocking {
			message += " The firewall is on and may be blocking your internet access."
		}
		message += "\n\nRemove disconnects the VPN, turns the firewall off and deletes the daemon.\nIf you moved the app, choose \"Later\" and open the app once."
		later, removeButton = "Later", "Remove"
	}

	// 값은 스크립트 본문에 끼워 넣지 않고 인자로 넘김.
	script := `on run argv
	set answer to display dialog (item 1 of argv) with title "prtvpn" buttons {item 2 of argv, item 3 of argv} default button 2 cancel button 1 with icon caution
	return button returned of answer
end run`
	out, err := exec.Command("/bin/launchctl", "asuser", fmt.Sprint(uid), "/usr/bin/osascript", "-e", script, message, later, removeButton).CombinedOutput()
	text := strings.TrimSpace(string(out))
	if err != nil {
		// 취소 버튼(나중에)은 "User canceled" 오류로 돌아옴. 그 밖의 오류는 창을 띄우지 못한 것임.
		if strings.Contains(text, "-128") {
			return false, true
		}
		log.Printf("안내 창을 띄우지 못함: %v: %s", err, text)
		return false, false
	}
	return text == removeButton, true
}

// uninstall 은 터널과 방화벽을 정리하고 데몬이 남긴 것을 모두 지운 뒤 스스로 내려감.
func uninstall(t *tunnel, uid int) {
	log.Printf("앱이 없어 데몬을 제거함")
	t.disconnect()
	disableFirewall()
	restoreDNS()
	os.RemoveAll(stateDir)
	os.Remove(socketPath)
	os.Remove(launchDaemonPath)
	if self, err := os.Executable(); err == nil {
		os.Remove(self)
	}
	os.Remove(daemonLogPath)
	if uid >= 0 {
		notifyUser(uid, "prtvpn 터널 데몬과 방화벽을 제거했습니다.", "The prtvpn tunnel daemon and firewall were removed.")
	}
	// KeepAlive 라 그냥 종료하면 launchd 가 다시 띄움. 서비스에서 빠져야 끝남(이 호출로 이 프로세스도 종료됨).
	exec.Command("/bin/launchctl", "bootout", "system/"+launchdLabel).Run()
	os.Exit(0)
}

// notifyUser 는 사용자의 화면에 확인 버튼만 있는 안내 창을 띄움. 로그인한 사용자가 없으면 아무것도 하지 않음.
// 사용자가 누르지 않아도 30초 뒤에 닫힘.
func notifyUser(uid int, korean, english string) {
	message := english
	if userPrefersKorean(uid) {
		message = korean
	}
	script := `on run argv
	display dialog (item 1 of argv) with title "prtvpn" buttons {"OK"} default button 1 giving up after 30
end run`
	if out, err := exec.Command("/bin/launchctl", "asuser", fmt.Sprint(uid), "/usr/bin/osascript", "-e", script, message).CombinedOutput(); err != nil {
		log.Printf("안내 창을 띄우지 못함: %v: %s", err, strings.TrimSpace(string(out)))
	}
}

// announceInstall 은 데몬이 새로 설치됐거나 다른 파일로 바뀐 뒤 처음 실행될 때 사용자에게 알림.
// 재부팅이나 재시작처럼 같은 파일이 다시 실행된 경우에는 알리지 않음.
func announceInstall(uid int) {
	self, err := os.Executable()
	if err != nil {
		return
	}
	data, err := os.ReadFile(self)
	if err != nil {
		return
	}
	sum := sha256.Sum256(data)
	current := hex.EncodeToString(sum[:])
	previous, err := os.ReadFile(installedHashFile)
	if err == nil && strings.TrimSpace(string(previous)) == current {
		return
	}
	if writeErr := os.WriteFile(installedHashFile, []byte(current), 0o600); writeErr != nil {
		log.Printf("설치 기록 실패: %v", writeErr)
	}
	if err != nil {
		log.Printf("데몬이 새로 설치됨")
		notifyUser(uid, "prtvpn 터널 데몬을 설치했습니다.\n\n데몬은 VPN 연결과 방화벽을 맡습니다. prtvpn 앱을 지우면 데몬도 제거할지 묻습니다.",
			"The prtvpn tunnel daemon was installed.\n\nIt runs the VPN connection and the firewall. If you delete the prtvpn app, it asks whether to remove itself too.")
		return
	}
	log.Printf("데몬이 업데이트됨")
	notifyUser(uid, "prtvpn 터널 데몬을 업데이트했습니다.", "The prtvpn tunnel daemon was updated.")
}
