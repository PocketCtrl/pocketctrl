// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

enum ClientKeychainReadResult {
    case value(String)
    case missing
    case failure(OSStatus)
}

enum ClientKeychainStore {
    static func readString(forKey key: String) -> ClientKeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "PocketCtrlMobile",
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess else {
            logFailure(operation: "read", status: status)
            return .failure(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            logFailure(operation: "decode", status: errSecDecode)
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
        let service = Bundle.main.bundleIdentifier ?? "PocketCtrlMobile"
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let writeStatus: OSStatus
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            writeStatus = SecItemAdd(item as CFDictionary, nil)
        } else {
            writeStatus = updateStatus
        }

        guard writeStatus == errSecSuccess else {
            logFailure(operation: "write", status: writeStatus)
            return false
        }
        guard case let .value(savedValue) = readString(forKey: key), savedValue == value else {
            logFailure(operation: "verify", status: errSecVerifyFailed)
            return false
        }
        return true
    }

    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "PocketCtrlMobile",
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logFailure(operation: "delete", status: status)
            return false
        }
        return true
    }

    static func deleteLegacy(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "PocketCtrlMobile",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteLegacyKeys(withPrefix prefix: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "PocketCtrlMobile",
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
}
