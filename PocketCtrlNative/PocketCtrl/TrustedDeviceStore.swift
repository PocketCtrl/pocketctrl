// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

enum TrustedDeviceAccessMode: String, Codable, CaseIterable {
    case sessionOnly
    case unattended
}

struct PairingApprovalOptions: Equatable {
    var accessMode: TrustedDeviceAccessMode = .sessionOnly
    var allowsRemoteInput = false
    var allowsClipboard = false
    var allowsAudio = false
}

struct TrustedDeviceRecord: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    let createdAt: Date
    var lastConnectedAt: Date?
    var allowsRemoteInput: Bool
    var allowsClipboard: Bool
    var allowsAudio: Bool
    let accessMode: TrustedDeviceAccessMode
}

struct TrustedDeviceCredential: Equatable {
    var record: TrustedDeviceRecord
    let secret: String
}

/// The stream stack reads this store from background receive queues, while the
/// model updates it on the main actor. Secrets never enter UserDefaults.
final class TrustedDeviceCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: TrustedDeviceCredential] = [:]
    private var suspendedDeviceIDs: Set<String> = []

    func replace(with values: [TrustedDeviceCredential]) {
        lock.lock()
        credentials = Dictionary(uniqueKeysWithValues: values.map { ($0.record.id, $0) })
        suspendedDeviceIDs.removeAll()
        lock.unlock()
    }

    func insert(_ credential: TrustedDeviceCredential) {
        lock.lock()
        credentials[credential.record.id] = credential
        suspendedDeviceIDs.remove(credential.record.id)
        lock.unlock()
    }

    func credential(for deviceID: String) -> TrustedDeviceCredential? {
        lock.lock()
        defer { lock.unlock() }
        guard !suspendedDeviceIDs.contains(deviceID) else { return nil }
        return credentials[deviceID]
    }

    @discardableResult
    func remove(deviceID: String) -> TrustedDeviceCredential? {
        lock.lock()
        defer { lock.unlock() }
        suspendedDeviceIDs.remove(deviceID)
        return credentials.removeValue(forKey: deviceID)
    }

    func removeSessionOnlyCredentials() {
        lock.lock()
        let sessionOnlyIDs = credentials.values
            .filter { $0.record.accessMode == .sessionOnly }
            .map { $0.record.id }
        sessionOnlyIDs.forEach {
            credentials.removeValue(forKey: $0)
            suspendedDeviceIDs.remove($0)
        }
        lock.unlock()
    }

    func suspend(deviceID: String) {
        lock.lock()
        suspendedDeviceIDs.insert(deviceID)
        lock.unlock()
    }

    func clearSuspensions() {
        lock.lock()
        suspendedDeviceIDs.removeAll()
        lock.unlock()
    }
}

enum PocketCtrlCredentialGenerator {
    static func secret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
    }
}
