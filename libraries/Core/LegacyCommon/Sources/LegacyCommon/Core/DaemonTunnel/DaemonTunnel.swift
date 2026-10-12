//
//  Created on 2026-10-11.
//
//  Copyright (c) 2026 Proton AG
//
//  ProtonVPN is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonVPN is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonVPN.  If not, see <https://www.gnu.org/licenses/>.

#if os(macOS)

    import AppKit
    import CryptoKit
    import Foundation
    import NetworkExtension

    import Dependencies
    import Domain
    import Ergonomics
    import Sharing
    import VPNAppCore
    import VPNShared

    // NetworkExtension(시스템 확장) 대신, 루트로 실행되는 prtvpn-daemon 이 utun 위에 WireGuard 터널을 올림.
    // 이 파일은 앱의 기존 연결 로직(VpnManager)이 쓰는 NE 래퍼 프로토콜을 그 데몬으로 구현함.
    // 데몬 소스: apps/macos/prtvpn-daemon

    // MARK: - 데몬 프로토콜 (apps/macos/prtvpn-daemon/protocol.go 와 같아야 함)

    struct DaemonTunnelConfig: Codable, Equatable {
        var privateKey: String
        var addresses: [String]
        var dns: [String]
        var peerPublicKey: String
        var endpointHost: String
        var endpointPort: Int
        var allowedIPs: [String]
        var persistentKeepalive: Int
        var socketType: String
        var mtu: Int
    }

    /// 데몬에 보내는 방화벽 설정. 터널 연결 여부와 관계없이 유지됨. 모드의 뜻은 `FirewallMode` 에 있음.
    struct DaemonFirewallConfig: Codable, Equatable {
        var mode: String
        var allowLAN: Bool
        /// 방화벽이 켜진 채로도 앱이 로그인하고 서버 목록을 받을 수 있도록 예외로 둘 API 서버 (호스트 이름별 IP 목록).
        /// 방화벽이 켜져 있으면 DNS 질의도 막히므로 데몬이 이 이름들을 /etc/hosts 에 적어 둠.
        var allowedHosts: [String: [String]]
    }

    struct DaemonStatus: Codable {
        var state: String
        var interface: String?
        var connectedSince: Int64?
        var lastError: String?
        var rxBytes: UInt64
        var txBytes: UInt64
        var firewall: Bool
        /// 자동 전환 모드에서 방화벽이 지금 켜져 있는지 (연결된 적이 있고, 사용자가 끊지 않았음)
        var firewallArmed: Bool?
        var version: String
    }

    private struct DaemonRequest: Codable {
        var command: String
        var config: DaemonTunnelConfig?
        var firewall: DaemonFirewallConfig?
        var endpoint: String?
        var appPath: String?
    }

    struct DaemonResponse: Codable {
        var ok: Bool
        var error: String?
        var status: DaemonStatus
    }

    enum DaemonTunnelError: LocalizedError {
        case notRunning
        case ioFailure
        case rejected(String)
        case missingConfiguration
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: "The tunnel daemon is not running"
            case .ioFailure: "Communication with the tunnel daemon failed"
            case let .rejected(reason): "The tunnel daemon rejected the request: \(reason)"
            case .missingConfiguration: "No WireGuard configuration available"
            case let .installFailed(reason): "Installing the tunnel daemon failed: \(reason)"
            }
        }
    }

    // MARK: - 소켓 클라이언트

    enum DaemonClient {
        static let socketPath = "/var/run/prtvpn-daemon.sock"
        /// 데몬이 응답하고, 설치된 데몬이 이 앱에 들어 있는 데몬과 같은 파일인지.
        /// 버전 번호를 비교하지 않으므로 데몬을 고칠 때 번호를 올리지 않아도 새 데몬이 설치됨.
        static var isDaemonAvailable: Bool {
            (try? send("version")) != nil && DaemonInstaller.installedBinaryIsCurrent
        }

        /// 요청 하나를 보내고 응답을 기다림. 호출 스레드를 막으므로 메인 스레드에서 부르지 않음.
        static func send(
            _ command: String,
            config: DaemonTunnelConfig? = nil,
            firewall: DaemonFirewallConfig? = nil,
            endpoint: String? = nil,
            appPath: String? = nil
        ) throws -> DaemonResponse {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw DaemonTunnelError.ioFailure }
            defer { close(fd) }

            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                    _ = strlcpy(destination, socketPath, pathCapacity)
                }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw DaemonTunnelError.notRunning }

            var payload = try JSONEncoder().encode(DaemonRequest(command: command, config: config, firewall: firewall, endpoint: endpoint, appPath: appPath))
            payload.append(0x0A)
            let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == payload.count else { throw DaemonTunnelError.ioFailure }

            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !received.contains(0x0A) {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { throw DaemonTunnelError.ioFailure }
                received.append(buffer, count: count)
            }
            return try JSONDecoder().decode(DaemonResponse.self, from: received)
        }
    }

    // MARK: - 설치

    /// 데몬을 시스템에 설치함. 사용자가 macOS 관리자 암호 창에서 직접 승인해야 진행됨.
    enum DaemonInstaller {
        static let label = "app.prtvpn.daemon"
        private static let installedBinaryPath = "/Library/PrivilegedHelperTools/app.prtvpn.daemon"
        private static let launchDaemonPath = "/Library/LaunchDaemons/app.prtvpn.daemon.plist"

        /// 데몬이 없거나 버전이 다르면 설치함.
        static func ensureInstalled() throws {
            if DaemonClient.isDaemonAvailable { return }
            log.info("Tunnel daemon missing or outdated, asking the user to install it", category: .connectionConnect)
            try install()

            // launchd 가 데몬을 띄우고 소켓을 열 때까지 잠깐 기다림
            for _ in 0 ..< 50 {
                if DaemonClient.isDaemonAvailable { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw DaemonTunnelError.installFailed("daemon did not start")
        }

        /// 설치된 데몬이 앱 번들에 들어 있는 데몬과 내용이 같은지
        static var installedBinaryIsCurrent: Bool {
            guard let source = Bundle.main.url(forResource: "prtvpn-daemon", withExtension: nil) else { return false }
            return FileManager.default.contentsEqual(atPath: source.path, andPath: installedBinaryPath)
        }

        private static func install() throws {
            guard let source = Bundle.main.url(forResource: "prtvpn-daemon", withExtension: nil) else {
                throw DaemonTunnelError.installFailed("daemon binary missing from the app bundle")
            }

            // 데몬은 이 요구 조건을 만족하는 코드 서명의 프로세스만 받아 줌.
            let requirement = try ownCodeRequirement()
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [installedBinaryPath, "-uid", "\(getuid())", "-requirement", requirement],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardOutPath": "/var/log/prtvpn-daemon.log",
                "StandardErrorPath": "/var/log/prtvpn-daemon.log",
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

            // 스크립트와 plist 를 파일로 쓰지 않고 명령 한 줄에 담아 넘김. 사용자 폴더에 파일로 두면
            // 암호 창이 떠 있는 동안 다른 프로세스가 바꿔치기해 루트 권한으로 실행시킬 수 있음.
            // 데몬 바이너리는 루트만 쓸 수 있는 곳으로 먼저 복사한 뒤, 그 사본이 이 앱과 같은 인증서로 서명됐는지 확인하고 설치함.
            let staged = installedBinaryPath + ".new"
            let commands = [
                "/bin/mkdir -p /Library/PrivilegedHelperTools",
                "/bin/cp -f \(shellQuoted(source.path)) \(staged)",
                "/usr/sbin/chown root:wheel \(staged)",
                "/bin/chmod 755 \(staged)",
                "{ /usr/bin/codesign --verify -R=\(shellQuoted(try daemonCodeRequirement())) \(staged) || { /bin/rm -f \(staged); exit 1; }; }",
                "{ /bin/launchctl bootout system/\(label) 2>/dev/null || true; }",
                "/bin/mv -f \(staged) \(installedBinaryPath)",
                "/bin/echo \(plistData.base64EncodedString()) | /usr/bin/base64 -D > \(launchDaemonPath)",
                "/usr/sbin/chown root:wheel \(launchDaemonPath)",
                "/bin/chmod 644 \(launchDaemonPath)",
                "/bin/launchctl bootstrap system \(launchDaemonPath)",
            ]
            let script = commands.joined(separator: " && ")
            let escaped = script
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
            var failure: String?
            // NSAppleScript 는 메인 스레드에서 실행해야 함
            let run = {
                var errorInfo: NSDictionary?
                NSAppleScript(source: appleScript)?.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    failure = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
                }
            }
            if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
            if let failure {
                throw DaemonTunnelError.installFailed(failure)
            }
        }

        /// 번들에 든 데몬이 만족해야 하는 요구 조건. 이 앱을 서명한 인증서로 서명된 데몬이어야 함.
        private static func daemonCodeRequirement() throws -> String {
            var code: SecCode?
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
                  let leaf = certificates.first else {
                throw DaemonTunnelError.installFailed("the app is not signed with a certificate")
            }
            let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "identifier \"\(label)\" and certificate leaf = H\"\(hex)\""
        }

        /// 실행 중인 이 앱의 지정 요구 조건(designated requirement). 로컬 인증서로 서명했다면
        /// `identifier "app.prtvpn.mac" and certificate leaf = H"…"` 꼴이라 다시 빌드해도 바뀌지 않음.
        private static func ownCodeRequirement() throws -> String {
            var code: SecCode?
            var staticCode: SecStaticCode?
            var requirement: SecRequirement?
            var text: CFString?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
                  SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
                throw DaemonTunnelError.installFailed("the app is not code signed")
            }
            return text as String
        }

        private static func shellQuoted(_ string: String) -> String {
            "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    // MARK: - 방화벽

    /// 방화벽 모드. 데몬의 모드 이름과 같아야 함.
    public enum FirewallMode: String, CaseIterable, Sendable {
        /// VPN 에 연결되면 켜지고, 사용자가 직접 연결을 끊으면 꺼짐. 예기치 않게 끊긴 동안에는 켜진 채로 남음.
        case auto
        /// 항상 VPN 터널을 지나는 트래픽만 통과시킴. 연결이 끊겨 있으면 인터넷이 전부 막힘.
        case on
        /// VPN 터널을 포함해 인터넷으로 나가는 모든 트래픽을 막음.
        case lockdown
        /// 아무것도 막지 않음.
        case off
    }

    /// 앱의 방화벽 모드를 데몬에 그대로 반영함.
    public final class DaemonFirewall {
        private static let modeKey = "FirewallMode"

        /// 현재 방화벽 모드. 고른 적이 없으면, 예전 킬 스위치를 켜 둔 경우 항상 켜짐, 아니면 자동 전환임.
        public static var mode: FirewallMode {
            get {
                if let raw = UserDefaults.standard.string(forKey: modeKey), let mode = FirewallMode(rawValue: raw) {
                    return mode
                }
                @SharedReader(.killSwitch) var killSwitch: Bool
                return killSwitch ? .on : .auto
            }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
                // 킬 스위치 값을 보는 나머지 코드(LAN 충돌 경고 등)와 어긋나지 않게 맞춰 둠. 값이 바뀌면 관찰자가 데몬에 반영함.
                @Shared(.killSwitch) var killSwitch: Bool
                if killSwitch != (newValue != .off) {
                    $killSwitch.withLock { $0 = newValue != .off }
                }
                shared.sync()
            }
        }

        /// 자동 전환 모드의 방화벽이 지금 켜져 있는지. 데몬이 없으면 nil(방화벽도 없음).
        public static var isArmed: Bool? {
            guard let status = try? DaemonClient.send("status").status else { return nil }
            return status.firewallArmed ?? false
        }

        /// 사용자가 연결 끊기를 직접 누르거나 연결 시도를 취소할 때만 부름. 자동 전환 모드라면 방화벽이 꺼짐.
        /// 앱이 대신 끊는 경우(재연결, 시간 초과, 프로토콜 변경, Secure Core 전환, 세션 전환)에는 부르지 않으므로
        /// 그때는 방화벽이 켜진 채로 남아 IP 가 새지 않음.
        public static func userWillDisconnect() {
            do {
                _ = try DaemonClient.send("disarm")
            } catch DaemonTunnelError.notRunning {
                // 데몬이 없으면 방화벽도 없음.
            } catch {
                log.error("Disarming daemon firewall failed: \(error.localizedDescription)", category: .connectionDisconnect)
            }
        }

        public nonisolated(unsafe) static let shared = DaemonFirewall()

        /// 방화벽이 켜져 있어도 접속할 수 있어야 하는 API 호스트 이름. 앱 시작 시 채움.
        public nonisolated(unsafe) static var apiHosts: [String] = []

        private let queue = DispatchQueue(label: "app.prtvpn.daemon-firewall")
        private var observation: Task<Void, Never>?

        /// 설정 변경을 지켜보기 시작하고, 현재 설정을 한 번 반영함.
        public func start() {
            guard observation == nil else { return }
            // 나중에 막힌 상태에서 모드를 바꿔도 바로 쓸 수 있게 API 서버 주소를 미리 풀어 둠
            Self.resolveQueue.async {
                let hosts = Self.resolve(Self.apiHosts)
                if hosts.count == Self.apiHosts.count { Self.cachedHosts = hosts }
            }
            observation = Task { [weak self] in
                @SharedReader(.killSwitch) var killSwitch: Bool
                for await _ in $killSwitch.publisher.values {
                    self?.sync()
                }
            }
        }

        /// 현재 방화벽 모드를 데몬에 보냄. 데몬이 없으면 아무 일도 하지 않음.
        public func sync() {
            @Dependency(\.appFeaturePropertyProvider) var featurePropertyProvider
            let mode = Self.mode
            // 자동 전환도 끊긴 동안에는 막으므로, 켜질 수 있는 모드에서는 API 서버 주소가 필요함
            let enabled = mode == .auto || mode == .on
            let allowLAN = featurePropertyProvider.getValue(for: ExcludeLocalNetworks.self) == .on
            queue.async {
                Self.registerApp()

                func send(_ hosts: [String: [String]]) {
                    let config = DaemonFirewallConfig(
                        mode: mode.rawValue,
                        allowLAN: allowLAN,
                        allowedHosts: enabled ? hosts : [:]
                    )
                    do {
                        let response = try DaemonClient.send("firewall", firewall: config)
                        if !response.ok {
                            log.error("Daemon rejected firewall change: \(response.error ?? "unknown")", category: .connection)
                        }
                    } catch DaemonTunnelError.notRunning {
                        // 데몬이 아직 설치되지 않았음. 첫 연결 때 설치된 뒤 다시 반영됨.
                    } catch {
                        log.error("Setting daemon firewall failed: \(error.localizedDescription)", category: .connection)
                    }
                }

                // 방화벽이 켜지면 DNS 도 막히므로 API 서버 주소는 미리 풀어 둔 것을 씀.
                // 주소를 푸는 동안 기다리면, 막힌 상태에서 모드를 바꿀 때 DNS 시간 초과만큼 전환이 늦어짐.
                var hosts = Self.cachedHosts
                if enabled, hosts.isEmpty {
                    // 풀어 둔 주소가 없으면 켜기 전에 한 번은 풀어야 함
                    hosts = Self.resolve(Self.apiHosts)
                    if !hosts.isEmpty { Self.cachedHosts = hosts }
                }
                send(hosts)

                // 주소가 바뀌었을 수 있으니 뒤에서 다시 풀어 보고, 달라졌으면 한 번 더 반영함
                guard enabled else { return }
                Self.resolveQueue.async { [weak self] in
                    let fresh = Self.resolve(Self.apiHosts)
                    // 일부만 풀렸다면(막힌 상태) 있던 주소를 덮어쓰지 않음
                    guard fresh.count == Self.apiHosts.count, fresh != hosts else { return }
                    self?.queue.async {
                        Self.cachedHosts = fresh
                        if Self.mode == mode { send(fresh) }
                    }
                }
            }
        }

        /// 앱의 현재 위치를 데몬에 알려 줌. 데몬은 이 위치에서 앱이 사라지면 사용자에게 알리고 스스로 제거할 수 있게 함
        /// (앱만 지우면 방화벽이 켜진 채로 남아 인터넷을 복구할 방법이 없어지기 때문).
        private static func registerApp() {
            let path = Bundle.main.bundlePath
            // 격리된 앱은 실행할 때마다 바뀌는 임시 위치에서 돌기 때문에, 그 위치를 알려 주면 곧 사라진 것으로 보임
            guard !path.contains("/AppTranslocation/") else { return }
            _ = try? DaemonClient.send("app", appPath: path)
        }

        private static let resolveQueue = DispatchQueue(label: "app.prtvpn.daemon-firewall.resolve")
        private static let cachedHostsKey = "FirewallAllowedHosts"

        /// 마지막으로 풀어 둔 API 서버 주소 (호스트 이름별 IP 목록)
        private static var cachedHosts: [String: [String]] {
            get { UserDefaults.standard.dictionary(forKey: cachedHostsKey) as? [String: [String]] ?? [:] }
            set { UserDefaults.standard.set(newValue, forKey: cachedHostsKey) }
        }

        /// 곧 연결할 VPN 서버를 방화벽 예외에 넣음. 방화벽이 켜져 있으면 터널이 없는 동안 모든 트래픽이 막히므로,
        /// 이걸 먼저 하지 않으면 연결 전 포트 탐색(스마트 프로토콜)이 전부 실패함. 데몬이 없으면 아무 일도 하지 않음.
        public static func allowServer(_ address: String) {
            do {
                let response = try DaemonClient.send("prepare", endpoint: address)
                if !response.ok {
                    log.error("Daemon rejected server exception: \(response.error ?? "unknown")", category: .connectionConnect)
                }
            } catch DaemonTunnelError.notRunning {
                // 데몬이 아직 설치되지 않았다면 방화벽도 없음.
            } catch {
                log.error("Allowing server through daemon firewall failed: \(error.localizedDescription)", category: .connectionConnect)
            }
        }

        private static func resolve(_ names: [String]) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for name in names {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(name, nil, &hints, &info) == 0 else { continue }
                defer { freeaddrinfo(info) }
                var addresses: [String] = []
                var cursor = info
                while let entry = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let address = String(cString: buffer)
                        if !addresses.contains(address) {
                            addresses.append(address)
                        }
                    }
                    cursor = entry.pointee.ai_next
                }
                if !addresses.isEmpty {
                    result[name] = addresses
                }
            }
            return result
        }
    }

    // MARK: - WireGuard 설정 전달

    /// 연결 직전에 앱이 만든 WireGuard 설정(`StoredWireguardConfig`, 버전 바이트 + JSON)을 터널 세션에 넘기는 자리.
    /// 원래는 XPC 로 시스템 확장에 보내던 값임.
    public enum DaemonTunnelConfigStore {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var storedData: Data?

        public static var configData: Data? {
            get { lock.withLock { storedData } }
            set { lock.withLock { storedData = newValue } }
        }
    }

    extension DaemonTunnelConfig {
        /// `StoredWireguardConfig.asWireguardConfiguration()` 이 만드는 wg-quick 형식 텍스트를 데몬 설정으로 바꿈.
        init?(storedConfigData data: Data, socketType: String) {
            guard data.count > 1,
                  StoredWireguardConfig.Version(rawValue: Int(data[data.startIndex])) == .v1,
                  let stored = try? JSONDecoder().decode(StoredWireguardConfig.self, from: data.dropFirst()) else {
                return nil
            }
            var values: [String: String] = [:]
            for line in stored.asWireguardConfiguration().split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            func list(_ key: String) -> [String] {
                (values[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            guard let privateKey = values["PrivateKey"],
                  let peerPublicKey = values["PublicKey"],
                  let endpoint = values["Endpoint"],
                  let separator = endpoint.lastIndex(of: ":"),
                  let port = Int(endpoint[endpoint.index(after: separator)...]) else {
                return nil
            }
            // 프리픽스가 없는 주소는 호스트 주소로 봄
            let addresses = list("Address").map { $0.contains("/") ? $0 : ($0.contains(":") ? "\($0)/128" : "\($0)/32") }
            self.init(
                privateKey: privateKey,
                addresses: addresses,
                dns: list("DNS"),
                peerPublicKey: peerPublicKey,
                endpointHost: String(endpoint[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                endpointPort: port,
                allowedIPs: list("AllowedIPs"),
                persistentKeepalive: Int(values["PersistentKeepalive"] ?? "") ?? 25,
                socketType: socketType,
                mtu: 1280
            )
        }
    }

    // MARK: - NE 래퍼 구현

    public final class DaemonTunnelManager: NETunnelProviderManagerWrapper {
        public nonisolated(unsafe) static let shared = DaemonTunnelManager()

        private static let protocolDefaultsKey = "DaemonTunnelProtocolConfiguration"

        public var protocolConfiguration: NEVPNProtocol?
        public var isEnabled = false
        public var isOnDemandEnabled = false
        public var onDemandRules: [NEOnDemandRule]?

        private lazy var session = DaemonTunnelSession(manager: self)

        public var vpnConnection: NEVPNConnectionWrapper { session }

        private init() {
            // 앱을 껐다 켜도 터널은 데몬에서 계속 돌 수 있으므로, 어느 서버에 연결했는지 담긴 구성을 복원함
            if let data = UserDefaults.standard.data(forKey: Self.protocolDefaultsKey) {
                protocolConfiguration = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NETunnelProviderProtocol.self, from: data)
            }
        }

        public func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) {
            DispatchQueue.main.async { completionHandler(nil) }
        }

        public func loadFromPreferences() async throws {}

        public func saveToPreferences(completionHandler: ((Error?) -> Void)?) {
            if let protocolConfiguration,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: protocolConfiguration, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: Self.protocolDefaultsKey)
            }
            DispatchQueue.main.async { completionHandler?(nil) }
        }

        public func removeFromPreferences(completionHandler: ((Error?) -> Void)?) {
            protocolConfiguration = nil
            UserDefaults.standard.removeObject(forKey: Self.protocolDefaultsKey)
            DispatchQueue.main.async { completionHandler?(nil) }
        }
    }

    public final class DaemonTunnelSession: NETunnelProviderSessionWrapper {
        private unowned let manager: DaemonTunnelManager
        private let queue = DispatchQueue(label: "app.prtvpn.daemon-tunnel")
        private let lock = NSLock()
        private var currentStatus: NEVPNStatus = .disconnected
        private var currentConnectedDate: Date?
        private var pollTimer: DispatchSourceTimer?

        public var vpnManager: NEVPNManagerWrapper { manager }

        public var status: NEVPNStatus { lock.withLock { currentStatus } }

        public var connectedDate: Date? { lock.withLock { currentConnectedDate } }

        init(manager: DaemonTunnelManager) {
            self.manager = manager
            // 앱 시작 시 데몬에 이미 터널이 올라와 있으면 그 상태를 그대로 이어받음.
            // 앱은 시작하자마자 어떤 프로토콜이 연결돼 있는지 한 번만 확인하므로, 그 전에 상태가 정해져 있도록
            // 여기서 기다림 (로컬 소켓이라 금방 끝나고, 데몬이 없으면 바로 실패함).
            guard let response = try? DaemonClient.send("status") else { return }
            switch response.status.state {
            case "connected":
                currentStatus = .connected
                currentConnectedDate = response.status.connectedSince.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            case "connecting":
                currentStatus = .connecting
            default:
                return
            }
            queue.async { [weak self] in
                self?.startPolling()
            }
        }

        public func startVPNTunnel() throws {
            guard let data = DaemonTunnelConfigStore.configData else {
                throw DaemonTunnelError.missingConfiguration
            }
            let configuration = manager.protocolConfiguration
            let socketType = (configuration as? NETunnelProviderProtocol)?.wgProtocol ?? "udp"
            guard let config = DaemonTunnelConfig(storedConfigData: data, socketType: socketType) else {
                throw DaemonTunnelError.missingConfiguration
            }

            setStatus(.connecting, connectedDate: nil)
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    try DaemonInstaller.ensureInstalled()
                    DaemonFirewall.shared.sync()
                    let response = try DaemonClient.send("connect", config: config)
                    guard response.ok else {
                        throw DaemonTunnelError.rejected(response.error ?? "unknown")
                    }
                    apply(response.status)
                    startPolling()
                } catch {
                    log.error("Starting daemon tunnel failed: \(error.localizedDescription)", category: .connectionConnect)
                    setStatus(.disconnected, connectedDate: nil)
                }
            }
        }

        public func stopVPNTunnel() {
            setStatus(.disconnecting, connectedDate: nil)
            queue.async { [weak self] in
                guard let self else { return }
                stopPolling()
                if (try? DaemonClient.send("disconnect")) == nil {
                    log.error("Daemon did not acknowledge disconnect", category: .connectionDisconnect)
                }
                setStatus(.disconnected, connectedDate: nil)
            }
        }

        /// 시스템 확장에 보내던 메시지(로그 수집 등)는 받을 상대가 없으므로 응답 없음으로 돌려줌.
        public func sendProviderMessage(_: Data, responseHandler: ((Data?) -> Void)?) throws {
            DispatchQueue.main.async { responseHandler?(nil) }
        }

        // MARK: 상태 추적

        private func startPolling() {
            stopPolling()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard let response = try? DaemonClient.send("status") else {
                    // 데몬이 사라졌으면 터널도 없음
                    setStatus(.disconnected, connectedDate: nil)
                    stopPolling()
                    return
                }
                apply(response.status)
            }
            pollTimer = timer
            timer.resume()
        }

        private func stopPolling() {
            pollTimer?.cancel()
            pollTimer = nil
        }

        private func apply(_ daemonStatus: DaemonStatus) {
            switch daemonStatus.state {
            case "connected":
                let date = daemonStatus.connectedSince.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                setStatus(.connected, connectedDate: date ?? Date())
            case "connecting":
                setStatus(.connecting, connectedDate: nil)
            default:
                if let error = daemonStatus.lastError, !error.isEmpty {
                    log.error("Daemon tunnel error: \(error)", category: .connection)
                }
                setStatus(.disconnected, connectedDate: nil)
                stopPolling()
            }
        }

        private func setStatus(_ newStatus: NEVPNStatus, connectedDate: Date?) {
            let changed: Bool = lock.withLock {
                let changed = currentStatus != newStatus
                currentStatus = newStatus
                currentConnectedDate = connectedDate
                return changed
            }
            guard changed else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: self, userInfo: nil)
            }
        }
    }

#endif
