// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

enum KeychainReadResult {
    case value(String)
    case missing
    case failure(OSStatus)
}

enum KeychainStore {
    static func readString(forKey key: String) -> KeychainReadResult {
        var result = readString(forKey: key, useDataProtectionKeychain: true)
#if DEBUG
        let shouldTryLoginKeychain: Bool
        switch result {
        case .missing:
            // An improperly signed Debug app is not consistent here: reads
            // may report item-not-found even though writes report the more
            // accurate missing-entitlement error. Check the same fallback
            // store used by set() before treating the credential as absent.
            shouldTryLoginKeychain = true
        case let .failure(status):
            shouldTryLoginKeychain = status == errSecMissingEntitlement
        case .value:
            shouldTryLoginKeychain = false
        }
        if shouldTryLoginKeychain {
            logDebugKeychainFallback()
            result = readString(forKey: key, useDataProtectionKeychain: false)
        }
#endif
        if case let .failure(status) = result {
            logFailure(operation: "read", status: status)
        }
        return result
    }

    private static func readString(forKey key: String, useDataProtectionKeychain: Bool) -> KeychainReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "PocketCtrl",
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess else {
            return .failure(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .failure(errSecDecode)
        }
        return .value(value)
    }

    static func string(forKey key: String) -> String? {
        if case let .value(value) = readString(forKey: key) {
            return value
        }
        return nil
    }

    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        var useDataProtectionKeychain = true
        var writeStatus = write(value, forKey: key, useDataProtectionKeychain: true)
#if DEBUG
        if writeStatus == errSecMissingEntitlement {
            logDebugKeychainFallback()
            useDataProtectionKeychain = false
            writeStatus = write(value, forKey: key, useDataProtectionKeychain: false)
        }
#endif
        guard writeStatus == errSecSuccess else {
            logFailure(operation: "write", status: writeStatus)
            return false
        }
        guard case let .value(savedValue) = readString(
            forKey: key,
            useDataProtectionKeychain: useDataProtectionKeychain
        ), savedValue == value else {
            logFailure(operation: "verify", status: errSecVerifyFailed)
            return false
        }
        return true
    }

    private static func write(
        _ value: String,
        forKey key: String,
        useDataProtectionKeychain: Bool
    ) -> OSStatus {
        let service = Bundle.main.bundleIdentifier ?? "PocketCtrl"
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var attributes: [String: Any] = [kSecValueData as String: data]
        if useDataProtectionKeychain {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            if useDataProtectionKeychain {
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
            return SecItemAdd(item as CFDictionary, nil)
        }
        return updateStatus
    }

    @discardableResult
    static func delete(forKey key: String) -> Bool {
        var status = delete(forKey: key, useDataProtectionKeychain: true)
#if DEBUG
        if status == errSecMissingEntitlement || status == errSecItemNotFound {
            logDebugKeychainFallback()
            status = delete(forKey: key, useDataProtectionKeychain: false)
        }
#endif
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logFailure(operation: "delete", status: status)
            return false
        }
        return true
    }

    private static func delete(forKey key: String, useDataProtectionKeychain: Bool) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "PocketCtrl",
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return SecItemDelete(query as CFDictionary)
    }

    static func deleteLegacy(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "PocketCtrl",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteLegacyKeys(withPrefix prefix: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "PocketCtrl",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            deleteLegacy(forKey: account)
        }
    }

    private static func logFailure(operation: String, status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        NSLog("PocketCtrl secure credential storage \(operation) failed: \(message) (\(status))")
    }

#if DEBUG
    private static func logDebugKeychainFallback() {
        NSLog("PocketCtrl Debug build is using the macOS login Keychain because this build lacks data-protection Keychain entitlements.")
    }
#endif
}
