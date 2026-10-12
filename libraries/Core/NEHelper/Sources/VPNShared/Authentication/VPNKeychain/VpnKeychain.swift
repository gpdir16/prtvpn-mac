//
//  VpnKeychain.swift
//  vpncore - Created on 26.06.19.
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of LegacyCommon.
//
//  vpncore is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  vpncore is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with LegacyCommon.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import KeychainAccess
import Logging

import Dependencies

import VPNCrypto

import Domain

public typealias VpnDowngradeInfo = (from: VpnCredentials, to: VpnCredentials)

public protocol VpnKeychainProtocol {
    func fetch() throws -> VpnCredentials
    func fetchCached() throws -> CachedVpnCredentials
    func fetchOpenVpnPassword() throws -> Data
    func storeAndDetectDowngrade(vpnCredentials: VpnCredentials)
    func getServerCertificate() throws -> SecCertificate
    func storeServerCertificate() throws
    func store(wireguardConfiguration: Data) throws -> Data
    func fetchWireguardConfigurationReference() throws -> Data
    func fetchWireguardConfiguration() throws -> String?
    func clear()

    #if os(iOS)
        func fetchWidgetPublicKey() throws -> CryptoService.Key
    #endif
}

extension VpnKeychainProtocol {
    public var userIsLoggedIn: Bool {
        fetch() != nil
    }

    func fetchCached() -> CachedVpnCredentials? {
        getOptionalCredentials(method: fetchCached)
    }

    func fetch() -> VpnCredentials? {
        getOptionalCredentials(method: fetch)
    }

    private func getOptionalCredentials<CredentialType>(
        method credentialsProvider: () throws -> CredentialType
    ) -> CredentialType? {
        do {
            return try credentialsProvider()
        } catch {
            if let keychainError = error as? KeychainError, case let .credentialsMissing(key) = keychainError {
                log.debug("Credentials missing from vpn keychain", metadata: ["storageKey": "\(key)"])
                return nil
            }
            log.error("Keychain (vpn) read error", category: .keychain, metadata: ["error": "\(error)"])
            return nil
        }
    }
}

enum KeychainEnvironment {
    static var secItemAdd = SecItemAdd
    static var secItemDelete = SecItemDelete
    static var secItemCopyMatching = SecItemCopyMatching
    static var secKeyCreateWithData = SecKeyCreateWithData
    static var secKeyVerifySignature = SecKeyVerifySignature
}

public class VpnKeychain: VpnKeychainProtocol {
    struct Error: Swift.Error {
        let localizedDescription: String
    }

    private enum StorageKey {
        static let vpnCredentials = "vpnCredentials"
        static let openVpnPassword_old = "openVpnPassword"
        // 공식 Proton VPN 앱의 키체인 항목과 섞이지 않도록 macOS에서는 별도 이름을 씀
        #if os(macOS)
            static let vpnServerPassword = "prtvpn-Server-Password"
            static let serverCertificate = "prtvpn_ike_root"
            static let wireguardSettings = "prtvpn_wg_settings"
        #else
            static let vpnServerPassword = "ProtonVPN-Server-Password"
            static let serverCertificate = "ProtonVPN_ike_root"
            static let wireguardSettings = "ProtonVPN_wg_settings"
        #endif
        static let widgetPublicKey = "ch.proton.vpn.widget.public_key"
    }

    #if os(macOS)
        // macOS 에서는 값마다 키체인 항목을 만들지 않고 암호화한 파일에 둠. `EncryptedVault` 참고.
        private let appKeychain = EncryptedVault(namespace: KeychainConstants.appKeychain)
        /// 원래 키체인에 service 이름 없이 따로 저장하던 항목들(서버 암호, WireGuard 설정)이 들어가는 곳.
        private let passwordVault = EncryptedVault(namespace: "password")
    #else
        private let appKeychain = Keychain(service: KeychainConstants.appKeychain).accessibility(.afterFirstUnlockThisDeviceOnly)
    #endif

    /// Singleton implementation of the `VPNKeychain` ensures that the live value provided by `Dependencies` and the
    /// VPNKeychain in the legacy DependencyContainer share a single instance and do not duplicate their cached values.
    public static let instance = VpnKeychain()

    private init() {}

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var cached: CachedVpnCredentials?

    public func fetch() throws -> VpnCredentials {
        let key = StorageKey.vpnCredentials
        guard let data = try appKeychain.getData(key) else {
            throw KeychainError.credentialsMissing(key)
        }

        do {
            let vpnCredentials = try decoder.decode(VpnCredentials.self, from: data)
            cached = CachedVpnCredentials(credentials: vpnCredentials)
            return vpnCredentials
        } catch {
            return try migrateVpnCredentials(data)
        }
    }

    /// We tried decoding with JSON and failed, let's try to decode from NSKeyedUnarchiver
    fileprivate func migrateVpnCredentials(_ data: Data) throws -> VpnCredentials {
        do {
            /// First, let's remove the stored data in case the NSKeyedUnarchiver crashes.
            /// Next time user launches the app, the credentials will be lost, but at least
            /// we won't start a crash cycle from which the user can't recover.
            try? appKeychain.remove(StorageKey.vpnCredentials)
            log.info("Removed VpnCredentials storage for \(StorageKey.vpnCredentials) key before attempting to unarchive with NSKeyedUnarchiver", category: .keychain)
            let rootClasses = [VpnCredentials.self, NSString.self, NSData.self, NSNumber.self]
            let unarchivedObject = try NSKeyedUnarchiver.unarchivedObject(ofClasses: rootClasses, from: data)
            guard let vpnCredentials = unarchivedObject as? VpnCredentials else {
                throw KeychainError.migration(.invalidObjectType(type(of: unarchivedObject)))
            }
            /// Store the unarchived credentials in JSON
            /// Next time the credentials are retrieved they will come from JSONDecoder instead of NSKeyedUnarchiver
            store(vpnCredentials: vpnCredentials)
            log.info("VpnCredentials storage for \(StorageKey.vpnCredentials) migration successful!", category: .keychain)
            return vpnCredentials
        } catch let coderError {
            throw KeychainError.migration(.unarchivingFailure(coderError))
        }
    }

    public func fetchCached() throws -> CachedVpnCredentials {
        try cached ?? CachedVpnCredentials(credentials: fetch())
    }

    public func fetchOpenVpnPassword() throws -> Data {
        do {
            let password = try getPasswordReference(forKey: StorageKey.vpnServerPassword)
            return password
        } catch {
            log.error("Error while fetching open vpn password from the keychain", category: .keychain, metadata: ["error": "\(error)"])
            throw CommonVpnError.vpnCredentialsMissing
        }
    }

    public func storeAndDetectDowngrade(vpnCredentials: VpnCredentials) {
        // TODO: Refactor to make it obvious that code posting notifications is
        // being run AFTER storing credentials to the keychain.
        if let currentCredentials = fetch() {
            log.debug(
                "Comparing vpn credentials to detect possible plan change",
                category: .keychain,
                metadata: [
                    "wasDelinquent": "\(currentCredentials.isDelinquent)",
                    "isDelinquent": "\(vpnCredentials.isDelinquent)",
                    "oldTier": "\(currentCredentials.maxTier)",
                    "newTier": "\(vpnCredentials.maxTier)",
                ]
            )
            DispatchQueue.main.async {
                let downgradeInfo = VpnDowngradeInfo(currentCredentials, vpnCredentials)
                if !currentCredentials.isDelinquent, vpnCredentials.isDelinquent {
                    AppEvent.userDelinquent.post(downgradeInfo)
                }

                if currentCredentials.maxTier != vpnCredentials.maxTier {
                    AppEvent.planChanged.post(downgradeInfo)
                }
            }
        }
        store(vpnCredentials: vpnCredentials)
    }

    private func store(vpnCredentials: VpnCredentials) {
        do {
            let data = try encoder.encode(vpnCredentials)
            try appKeychain.set(data, key: StorageKey.vpnCredentials)
            cached = CachedVpnCredentials(credentials: vpnCredentials)
        } catch {
            log.error("Keychain (vpn) write error", category: .keychain, metadata: ["error": "\(error)"])
        }

        do {
            try setPassword(vpnCredentials.password, forKey: StorageKey.vpnServerPassword)
        } catch {
            log.error("Error occurred during OpenVPN password storage", category: .keychain, metadata: ["error": "\(error)"])
        }

        DispatchQueue.main.async {
            AppEvent.credentialsChanged.post(vpnCredentials)
        }
    }

    public func clear() {
        log.debug("Clearing vpn credentials from keychain", category: .keychain)
        cached = nil
        appKeychain[data: StorageKey.vpnCredentials] = nil
        appKeychain[data: StorageKey.widgetPublicKey] = nil
        deleteServerCertificate()
        do {
            try clearPassword(forKey: StorageKey.vpnServerPassword)
            try clearPassword(forKey: StorageKey.wireguardSettings)
            DispatchQueue.main.async {
                AppEvent.credentialsChanged.post()
            }
        } catch {}
    }

    // Password is set and retrieved without using the library because NEVPNProtocol reuquires it to be
    // a "persistent keychain reference to a keychain item containing the password component of the
    // tunneling protocol authentication credential".
    public func getPasswordReference(forKey key: String) throws -> Data {
        #if os(macOS)
            // 키체인 항목이 없으므로 영구 참조도 없음. 참조를 받아 쓰던 NetworkExtension 을 쓰지 않으니
            // 값이 있는지만 확인하고 키 이름을 돌려줌.
            guard try passwordVault.getData(key) != nil else {
                throw CommonVpnError.vpnCredentialsMissing
            }
            return Data(key.utf8)
        #else
            try getKeychainPasswordReference(forKey: key)
        #endif
    }

    private func getKeychainPasswordReference(forKey key: String) throws -> Data {
        var query = formBaseQuery(forKey: key)
        query[kSecMatchLimit as AnyHashable] = kSecMatchLimitOne
        query[kSecReturnPersistentRef as AnyHashable] = kCFBooleanTrue

        var secItem: AnyObject?
        let result = KeychainEnvironment.secItemCopyMatching(query as CFDictionary, &secItem)
        if result != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
        }

        if let item = secItem as? Data {
            return item
        } else {
            throw CommonVpnError.vpnCredentialsMissing
        }
    }

    private func setPasswordData(_ data: Data, forKey key: String) throws {
        // First, try to get existing password data
        let existingData = try? getPasswordData(forKey: key)

        // If data exists and is the same, skip the operation
        if let existingData, existingData == data {
            log.debug("Skipping password data storage for key \(key), data is unchanged")
            return
        }

        // If data exists but is different, delete it first
        if existingData != nil {
            try? clearPassword(forKey: key)
        }

        // Add the new password data
        #if os(macOS)
            try passwordVault.set(data, key: key)
        #else
            var query = formBaseQuery(forKey: key)
            query[kSecValueData as AnyHashable] = data

            let result = KeychainEnvironment.secItemAdd(query as CFDictionary, nil)
            if result != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
            }
        #endif

        log.debug("Successfully stored password data for key \(key)")
    }

    private func getPasswordData(forKey key: String) throws -> Data? {
        #if os(macOS)
            try passwordVault.getData(key)
        #else
            try getKeychainPasswordData(forKey: key)
        #endif
    }

    private func getKeychainPasswordData(forKey key: String) throws -> Data? {
        var query = formBaseQuery(forKey: key)
        query[kSecMatchLimit as AnyHashable] = kSecMatchLimitOne
        query[kSecReturnAttributes as AnyHashable] = kCFBooleanTrue
        query[kSecReturnData as AnyHashable] = kCFBooleanTrue

        var secItem: AnyObject?
        let result = KeychainEnvironment.secItemCopyMatching(query as CFDictionary, &secItem)

        switch result {
        case errSecItemNotFound:
            log.debug("Get password data storage for key \(key) failed: \(result). Item not found")
            return nil
        case errSecSuccess:
            guard let secItemDict = secItem as? [String: AnyObject],
                  let passwordData = secItemDict[kSecValueData as String] as? Data else {
                log
                    .debug(
                        "Get password data storage for key \(key) failed. Invalid result: \(String(describing: secItem))"
                    )
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
            }
            return passwordData
        default:
            log.debug("Get password data storage for key \(key) failed: \(result)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
        }
    }

    public func setPassword(_ password: String, forKey key: String) throws {
        try setPasswordData(password.data(using: .utf8)!, forKey: key)
    }

    private func clearPassword(forKey key: String) throws {
        #if os(macOS)
            try passwordVault.remove(key)
        #else
            let query = formBaseQuery(forKey: key)

            let result = KeychainEnvironment.secItemDelete(query as CFDictionary)
            if result != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
            }
        #endif
        log.debug("Cleared password data storage for key \(key), data was changed")
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

    // MARK: - Certificates

    public func getServerCertificate() throws -> SecCertificate {
        #if os(macOS)
            // 인증서는 비밀이 아니므로 키체인에 넣지 않고 앱 번들에서 바로 읽음
            guard let certificateFile = Bundle.main.path(forResource: StorageKey.serverCertificate, ofType: "der")
                ?? Bundle.main.path(forResource: "ProtonVPN_ike_root", ofType: "der"),
                let certificateData = NSData(contentsOfFile: certificateFile),
                let certificate = SecCertificateCreateWithData(nil, certificateData) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound), userInfo: nil)
            }
            return certificate
        #else
            try getKeychainServerCertificate()
        #endif
    }

    private func getKeychainServerCertificate() throws -> SecCertificate {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: StorageKey.serverCertificate,
            kSecReturnRef as String: kCFBooleanTrue as Any,
        ]
        var item: CFTypeRef?
        let result = KeychainEnvironment.secItemCopyMatching(query as CFDictionary, &item)
        guard result == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
        }

        return item as! SecCertificate
    }

    public func storeServerCertificate() throws {
        #if os(macOS)
            // macOS 에서는 인증서를 번들에서 바로 읽으므로 저장할 것이 없음
        #else
            try storeKeychainServerCertificate()
        #endif
    }

    private func storeKeychainServerCertificate() throws {
        let certificateFile = Bundle.main.path(forResource: StorageKey.serverCertificate, ofType: "der")!
        let certificateData = NSData(contentsOfFile: certificateFile)!
        let certificate = SecCertificateCreateWithData(nil, certificateData)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: StorageKey.serverCertificate,
        ]

        let result = KeychainEnvironment.secItemAdd(query as CFDictionary, nil)
        guard result == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: nil)
        }
    }

    private func deleteServerCertificate() {
        #if !os(macOS)
            let query: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: StorageKey.serverCertificate,
                kSecReturnRef as String: kCFBooleanTrue as Any,
            ]
            _ = KeychainEnvironment.secItemDelete(query as CFDictionary)
        #endif
    }

    // MARK: - Wireguard

    public func store(wireguardConfiguration: Data) throws -> Data {
        try setPasswordData(wireguardConfiguration, forKey: StorageKey.wireguardSettings)
        return try fetchWireguardConfigurationReference()
    }

    public func fetchWireguardConfigurationReference() throws -> Data {
        try getPasswordReference(forKey: StorageKey.wireguardSettings)
    }

    public func fetchWireguardConfiguration() throws -> String? {
        #if os(macOS)
            try passwordVault.getData(StorageKey.wireguardSettings).flatMap { String(data: $0, encoding: .utf8) }
        #else
            try fetchKeychainWireguardConfiguration()
        #endif
    }

    private func fetchKeychainWireguardConfiguration() throws -> String? {
        var query = formBaseQuery(forKey: StorageKey.wireguardSettings)
        query[kSecMatchLimit as AnyHashable] = kSecMatchLimitOne
        query[kSecValuePersistentRef as AnyHashable] = try fetchWireguardConfigurationReference()
        query[kSecReturnData as AnyHashable] = true

        var secItem: AnyObject?
        let result = KeychainEnvironment.secItemCopyMatching(query as CFDictionary, &secItem)
        if result != errSecSuccess {
            log.error("Keychain error", category: .keychain, metadata: ["SecItemCopyMatching": "\(result)"])
            return nil
        }

        if let item = secItem as? Data {
            let config = String(data: item, encoding: String.Encoding.utf8)
            log.debug("Config read", category: .keychain, metadata: ["config": "\(config ?? "-")"])
            return config

        } else {
            log.error("Keychain error: can't read data", category: .keychain)
            return nil
        }
    }

    // MARK: - Widget

    #if os(iOS)
        public func fetchWidgetPublicKey() throws -> CryptoService.Key {
            guard let data = try appKeychain.getData(StorageKey.widgetPublicKey) else {
                throw Error(localizedDescription: "Keychain error: widget public key not found")
            }

            return try CryptoService.Key(
                data: data,
                keyType: CryptoConstants.widgetChallengeKeyType,
                keyClass: .publicKey,
                keySize: CryptoConstants.widgetChallengeKeyWidth
            )
        }
    #endif
}

public struct VpnKeychainDependencyKey: DependencyKey {
    public static let liveValue: VpnKeychainProtocol = VpnKeychain.instance
    public static let testValue: VpnKeychainProtocol = VpnKeychainMock()
}

public extension DependencyValues {
    var vpnKeychain: VpnKeychainProtocol {
        get { self[VpnKeychainDependencyKey.self] }
        set { self[VpnKeychainDependencyKey.self] = newValue }
    }
}
