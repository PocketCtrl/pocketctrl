// SPDX-License-Identifier: MPL-2.0
import Foundation
import AppKit
// In-memory Keychain substitute: tests never access credentials or emit OS input.
enum KeychainReadResult { case value(String), missing, failure(OSStatus) }
enum KeychainStore {
    static var values: [String: String] = [:]
    static var shouldFail = false
    static func readString(forKey key: String) -> KeychainReadResult {
        if shouldFail { return .failure(-1) }
        return values[key].map(KeychainReadResult.value) ?? .missing
    }
    static func string(forKey key: String) -> String? { shouldFail ? nil : values[key] }
    static func set(_ value: String, forKey key: String) -> Bool {
        guard !shouldFail else { return false }; values[key] = value; return true
    }
    static func delete(forKey key: String) -> Bool {
        guard !shouldFail else { return false }; values.removeValue(forKey: key); return true
    }
}
enum MacPermissions {
    static var screenRecordingGranted = true
    static var accessibilityGranted = true
    static func requestAccessibilityPrompt() {}
}
enum PocketCtrlHostDiagnostics { static func write(_ message: String) {} }
