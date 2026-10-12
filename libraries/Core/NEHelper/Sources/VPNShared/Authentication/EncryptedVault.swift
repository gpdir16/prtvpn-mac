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

    import CryptoKit
    import Foundation

    /// macOS 에서 값마다 키체인 항목을 만드는 대신 쓰는 비밀 저장소.
    ///
    /// 키체인에는 암호화 키 하나만 두고, 실제 값들은 그 키로 암호화(AES-GCM)해 파일 하나에 저장함.
    /// macOS 키체인은 Apple 이 서명하지 않은 앱의 접근 권한을 cdhash 로 묶기 때문에, 앱을 새로 빌드하면
    /// 항목마다 암호 창을 띄움. 항목이 하나뿐이면 창도 한 번만 뜨고, 실행 중에는 키를 메모리에 들고 있으므로
    /// 다시 뜨지 않음.
    public struct EncryptedVault: Sendable {
        public enum VaultError: Error {
            /// 키체인에서 암호화 키를 읽지 못했음 (사용자가 암호 창에서 거부한 경우 포함).
            case keyUnavailable(OSStatus)
        }

        /// 같은 이름의 키가 다른 용도와 섞이지 않도록 키 앞에 붙이는 이름 (키체인의 service 에 해당).
        private let namespace: String

        public init(namespace: String) {
            self.namespace = namespace
        }

        public func getData(_ key: String, ignoringAttributeSynchronizable _: Bool = true) throws -> Data? {
            try Self.storage.get(storageKey(key))
        }

        public func set(_ value: Data, key: String, ignoringAttributeSynchronizable _: Bool = true) throws {
            try Self.storage.set(value, key: storageKey(key))
        }

        public func remove(_ key: String, ignoringAttributeSynchronizable _: Bool = true) throws {
            try Self.storage.set(nil, key: storageKey(key))
        }

        public subscript(data key: String) -> Data? {
            get { try? getData(key) }
            nonmutating set {
                if let newValue {
                    try? set(newValue, key: key)
                } else {
                    try? remove(key)
                }
            }
        }

        private func storageKey(_ key: String) -> String {
            "\(namespace)/\(key)"
        }

        private static let storage = EncryptedVaultStorage()
    }

    // MARK: - 저장소

    private final class EncryptedVaultStorage: @unchecked Sendable {
        private let lock = NSLock()
        /// 복호화한 전체 내용. 처음 접근할 때 한 번 읽음.
        private var values: [String: Data]?
        private var key: SymmetricKey?
        /// 이번 실행에서 키를 읽지 못했다면 그 이유. 접근할 때마다 암호 창이 다시 뜨지 않도록 재시도하지 않음.
        private var keyFailure: OSStatus?

        private static let keyService = KeychainConstants.appKeychain
        private static let keyAccount = "vault-key"

        private static var fileURL: URL {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("prtvpn", isDirectory: true)
            return directory.appendingPathComponent("vault.bin")
        }

        func get(_ key: String) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return try loadLocked()[key]
        }

        func set(_ value: Data?, key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            var current = (try? loadLocked()) ?? [:]
            guard current[key] != value else { return }
            current[key] = value
            // 키를 못 읽어 디스크에 쓸 수 없어도 실행 중에는 값을 쓸 수 있게 메모리에는 남김
            values = current
            try saveLocked(current)
        }

        private func loadLocked() throws -> [String: Data] {
            if let values {
                return values
            }
            let key = try keyLocked()
            var loaded: [String: Data] = [:]
            // 파일이 없거나 이 키로 풀리지 않으면(키체인 항목이 새로 만들어진 경우) 빈 상태에서 시작함
            if let sealed = try? Data(contentsOf: Self.fileURL),
               let box = try? AES.GCM.SealedBox(combined: sealed),
               let plain = try? AES.GCM.open(box, using: key),
               let decoded = try? JSONDecoder().decode([String: Data].self, from: plain) {
                loaded = decoded
            }
            values = loaded
            return loaded
        }

        private func saveLocked(_ values: [String: Data]) throws {
            let key = try keyLocked()
            let plain = try JSONEncoder().encode(values)
            guard let sealed = try AES.GCM.seal(plain, using: key).combined else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = Self.fileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try sealed.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        // MARK: 암호화 키 (키체인을 건드리는 유일한 곳)

        private func keyLocked() throws -> SymmetricKey {
            if let key {
                return key
            }
            if let keyFailure {
                throw EncryptedVault.VaultError.keyUnavailable(keyFailure)
            }

            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.keyService,
                kSecAttrAccount: Self.keyAccount,
            ]
            var readQuery = query
            readQuery[kSecMatchLimit] = kSecMatchLimitOne
            readQuery[kSecReturnData] = true

            var item: CFTypeRef?
            var status = SecItemCopyMatching(readQuery as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, data.count == 32 {
                let loaded = SymmetricKey(data: data)
                key = loaded
                return loaded
            }
            guard status == errSecItemNotFound else {
                keyFailure = status
                throw EncryptedVault.VaultError.keyUnavailable(status)
            }

            // 첫 실행: 키를 새로 만들어 키체인에 넣음
            let created = SymmetricKey(size: .bits256)
            var addQuery = query
            addQuery[kSecValueData] = created.withUnsafeBytes { Data($0) }
            addQuery[kSecAttrLabel] = "prtvpn vault key"
            status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                keyFailure = status
                throw EncryptedVault.VaultError.keyUnavailable(status)
            }
            key = created
            return created
        }
    }

#endif
