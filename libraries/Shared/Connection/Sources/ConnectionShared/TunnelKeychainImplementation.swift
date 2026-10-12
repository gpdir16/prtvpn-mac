//
//  Created on 19/06/2024.
//
//  Copyright (c) 2024 Proton AG
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

import Foundation

package enum KeychainEnvironment {
    static let secItemAdd = SecItemAdd
    static let secItemDelete = SecItemDelete
    static let secItemCopyMatching = SecItemCopyMatching
    static let secKeyCreateWithData = SecKeyCreateWithData
    static let secKeyVerifySignature = SecKeyVerifySignature
}

public enum VPNKeychainError: Error {
    case encodingError
    case referenceAlreadyExists
    case resultIsNotADictionary
    case resultDictionaryHasNoData
}

public enum TunnelKeychainImplementationError: Error {
    /// The data retrieved from keychain isn't valid.
    case invalidDataFormatRetrievedFromKeychain
}

public struct TunnelKeychainImplementation {
    private enum StorageKey {
        // 공식 Proton VPN 앱의 키체인 항목과 섞이지 않도록 macOS에서는 별도 이름을 씀
        #if os(macOS)
            static let wireguardSettings = "prtvpn_wg_settings"
        #else
            static let wireguardSettings = "ProtonVPN_wg_settings"
        #endif
    }

    private let encoder = JSONEncoder()

    public init() {}

    #if os(macOS)
        // macOS 에서는 터널을 데몬이 올리므로 확장에 넘길 키체인 항목이 필요 없음.
        // 키체인을 건드리면 암호 창이 뜨기 때문에 설정은 메모리에만 둠.
        private static let memory = MemoryStore()

        private final class MemoryStore: @unchecked Sendable {
            private let lock = NSLock()
            private var data: Data?

            func get() -> Data? {
                lock.lock()
                defer { lock.unlock() }
                return data
            }

            func set(_ newValue: Data?) {
                lock.lock()
                defer { lock.unlock() }
                data = newValue
            }
        }

        public func store(_ configData: Data) throws -> Data {
            Self.memory.set(configData)
            return Data(StorageKey.wireguardSettings.utf8)
        }

        public func loadWireguardConfig() throws -> Data? {
            Self.memory.get()
        }

        public func clear() throws {
            Self.memory.set(nil)
        }
    #else
        public func store(_ configData: Data) throws -> Data {
            try setPassword(configData, forKey: StorageKey.wireguardSettings)
            return try fetchWireguardConfigurationReference()
        }

        public func loadWireguardConfig() throws -> Data? {
            try getPasswordData(forKey: StorageKey.wireguardSettings)
        }

        public func clear() throws {
            try clearPassword(forKey: StorageKey.wireguardSettings)
        }
    #endif

    // Password is set and retrieved without using the library because NEVPNProtocol requires it to be
    // a "persistent keychain reference to a keychain item containing the password component of the
    // tunneling protocol authentication credential".
    private func getPasswordReference(forKey key: String) throws -> Data {
        var query = formBaseQuery(forKey: key)
        query[kSecMatchLimit as AnyHashable] = kSecMatchLimitOne
        query[kSecReturnPersistentRef as AnyHashable] = kCFBooleanTrue

        var secItem: AnyObject?
        let result = KeychainEnvironment.secItemCopyMatching(query as CFDictionary, &secItem)
        guard result == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
        }

        guard let item = secItem as? Data else {
            throw TunnelKeychainImplementationError.invalidDataFormatRetrievedFromKeychain
        }

        return item
    }

    private func setPassword(_ passwordData: Data, forKey key: String) throws {
        guard let existingPasswordData = try getPasswordData(forKey: key) else {
            try setPasswordData(passwordData, forKey: key)
            return
        }

        if existingPasswordData == passwordData {
            return // No need to overwrite the keychain item - the data is unchanged
        }

        try clearPassword(forKey: key) // Attempting to overwrite the keychain item results in `errSecDuplicateItem`
        try setPasswordData(passwordData, forKey: key)
    }

    private func getPasswordData(forKey key: String) throws -> Data? {
        var query = formBaseQuery(forKey: key)
        query[kSecMatchLimit as AnyHashable] = kSecMatchLimitOne
        query[kSecReturnAttributes as AnyHashable] = kCFBooleanTrue
        query[kSecReturnData as AnyHashable] = kCFBooleanTrue

        var secItem: AnyObject?
        let result = KeychainEnvironment.secItemCopyMatching(query as CFDictionary, &secItem)
        switch result {
        case errSecItemNotFound:
            return nil

        case errSecSuccess:
            guard let secItemDict = secItem as? [String: AnyObject] else {
                throw VPNKeychainError.resultIsNotADictionary
            }
            guard let passwordData = secItemDict[kSecValueData as String] as? Data else {
                throw VPNKeychainError.resultDictionaryHasNoData
            }
            return passwordData

        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
        }
    }

    private func setPasswordData(_ data: Data, forKey key: String) throws {
        var query = formBaseQuery(forKey: key)
        query[kSecValueData as AnyHashable] = data

        let result = KeychainEnvironment.secItemAdd(query as CFDictionary, nil)
        switch result {
        case errSecSuccess:
            return

        case errSecDuplicateItem:
            throw VPNKeychainError.referenceAlreadyExists

        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
        }
    }

    @discardableResult
    private func clearPassword(forKey key: String) throws -> Bool {
        let query = formBaseQuery(forKey: key)
        let result = KeychainEnvironment.secItemDelete(query as CFDictionary)

        switch result {
        case errSecItemNotFound:
            return false

        case errSecSuccess:
            return true

        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
        }
    }

    private func formBaseQuery(forKey key: String) -> [AnyHashable: Any] {
        [
            kSecClass as AnyHashable: kSecClassGenericPassword,
            kSecAttrGeneric as AnyHashable: key,
            kSecAttrAccount as AnyHashable: key,
            kSecAttrService as AnyHashable: key,
            kSecAttrAccessible as AnyHashable: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as [AnyHashable: Any]
    }

    private func fetchWireguardConfigurationReference() throws -> Data {
        try getPasswordReference(forKey: StorageKey.wireguardSettings)
    }
}
