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
    var allowsComputerUse = false
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
    var allowsComputerUse = false

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, lastConnectedAt, allowsRemoteInput, allowsClipboard, allowsAudio, accessMode, allowsComputerUse
    }
    init(id: String, name: String, createdAt: Date, lastConnectedAt: Date?, allowsRemoteInput: Bool,
         allowsClipboard: Bool, allowsAudio: Bool, accessMode: TrustedDeviceAccessMode, allowsComputerUse: Bool = false) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.lastConnectedAt = lastConnectedAt
        self.allowsRemoteInput = allowsRemoteInput; self.allowsClipboard = allowsClipboard
        self.allowsAudio = allowsAudio; self.accessMode = accessMode; self.allowsComputerUse = allowsComputerUse
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        allowsRemoteInput = try c.decode(Bool.self, forKey: .allowsRemoteInput)
        allowsClipboard = try c.decode(Bool.self, forKey: .allowsClipboard)
        allowsAudio = try c.decode(Bool.self, forKey: .allowsAudio)
        accessMode = try c.decode(TrustedDeviceAccessMode.self, forKey: .accessMode)
        allowsComputerUse = try c.decodeIfPresent(Bool.self, forKey: .allowsComputerUse) ?? false
    }
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
