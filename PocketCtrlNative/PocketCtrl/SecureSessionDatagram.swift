// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Darwin
import Foundation

enum SecureSessionChannel: UInt8 {
    case video = 1
    case audio = 2
}

enum SecureSessionDatagram {
    private static let magic = Data([0x50, 0x43, 0x53, 0x45]) // PCSE
    private static let version: UInt8 = 1

    static func seal(
        _ plaintext: Data,
        channel: SecureSessionChannel,
        credentialID: String,
        secret: String
    ) -> Data? {
        let identifier = Data(credentialID.utf8)
        guard !secret.isEmpty, !identifier.isEmpty, identifier.count <= 96 else { return nil }
        var header = Data()
        header.append(magic)
        header.append(version)
        header.append(channel.rawValue)
        header.append(UInt8(identifier.count))
        header.append(identifier)
        do {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: key(secret: secret, credentialID: credentialID, channel: channel),
                authenticating: header
            )
            header.append(box.combined)
            return header
        } catch {
            return nil
        }
    }

    static func open(
        _ datagram: Data,
        channel: SecureSessionChannel,
        credentialID: String,
        secret: String
    ) -> Data? {
        guard datagram.count > 7 + 28,
              datagram.prefix(4) == magic,
              datagram[4] == version,
              datagram[5] == channel.rawValue else {
            return nil
        }
        let identifierLength = Int(datagram[6])
        let headerLength = 7 + identifierLength
        guard identifierLength > 0,
              datagram.count > headerLength + 28,
              let encodedIdentifier = String(data: datagram.subdata(in: 7..<headerLength), encoding: .utf8),
              encodedIdentifier == credentialID else {
            return nil
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: datagram.dropFirst(headerLength))
            return try ChaChaPoly.open(
                box,
                using: key(secret: secret, credentialID: credentialID, channel: channel),
                authenticating: datagram.prefix(headerLength)
            )
        } catch {
            return nil
        }
    }

    private static func key(secret: String, credentialID: String, channel: SecureSessionChannel) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data(credentialID.utf8),
            info: Data("PocketCtrl session channel \(channel.rawValue) v1".utf8),
            outputByteCount: 32
        )
    }
}

struct ActiveViewerSessionSnapshot {
    let credential: TrustedDeviceCredential
    let sourceHost: String
    let lastSeen: Date
    let audioEnabled: Bool
    let feedback: ViewerFeedback?
}

final class ActiveViewerSessionRegistry: @unchecked Sendable {
    private struct Session {
        var credentialID: String
        var sourceHost: String
        var lastSeen: Date
        var audioEnabled: Bool
        var feedback: ViewerFeedback?
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var capacityRejections = Set<String>()
    private weak var credentialStore: TrustedDeviceCredentialStore?
    private let configuredHost: String
    private let maximumViewerCount: Int
    private let inactivityTimeout: TimeInterval
    var onSessionsChanged: (([ActiveViewerSessionSnapshot]) -> Void)?

    init(
        credentialStore: TrustedDeviceCredentialStore,
        configuredHost: String,
        maximumViewerCount: Int = 3,
        inactivityTimeout: TimeInterval = 10
    ) {
        self.credentialStore = credentialStore
        self.configuredHost = configuredHost
        self.maximumViewerCount = maximumViewerCount
        self.inactivityTimeout = inactivityTimeout
    }

    @discardableResult
    func register(credential: TrustedDeviceCredential, sourceHost: String, now: Date = Date()) -> Bool {
        guard NetworkAddressPolicy.shouldAcceptAuthenticatedStreamPeer(
            configuredHost: configuredHost,
            sourceHost: sourceHost
        ) else {
            return false
        }

        var snapshotsToPublish: [ActiveViewerSessionSnapshot]?
        var accepted = false
        lock.lock()
        let membershipChanged = pruneLocked(now: now)
        if var existing = sessions[credential.record.id] {
            let routeChanged = existing.sourceHost != sourceHost
            existing.sourceHost = sourceHost
            existing.lastSeen = now
            sessions[credential.record.id] = existing
            capacityRejections.remove(credential.record.id)
            accepted = true
            if membershipChanged || routeChanged {
                snapshotsToPublish = snapshotsLocked()
            }
        } else if sessions.count < maximumViewerCount {
            sessions[credential.record.id] = Session(
                credentialID: credential.record.id,
                sourceHost: sourceHost,
                lastSeen: now,
                audioEnabled: false,
                feedback: nil
            )
            capacityRejections.remove(credential.record.id)
            accepted = true
            snapshotsToPublish = snapshotsLocked()
        } else if capacityRejections.insert(credential.record.id).inserted {
            PocketCtrlHostDiagnostics.write("viewer session rejected at capacity max=\(maximumViewerCount)")
        }
        lock.unlock()

        if let snapshotsToPublish {
            onSessionsChanged?(snapshotsToPublish)
        }
        return accepted
    }

    func updateFeedback(_ feedback: ViewerFeedback, deviceID: String) -> ViewerFeedback {
        lock.lock()
        if var session = sessions[deviceID] {
            session.feedback = feedback
            sessions[deviceID] = session
        }
        let feedbacks = sessions.values.compactMap(\.feedback)
        let aggregate = Self.aggregate(feedbacks: feedbacks, fallback: feedback)
        for (id, var session) in sessions where session.feedback?.keyframeRequested == true {
            session.feedback = session.feedback.map(Self.consumingKeyframeRequest)
            sessions[id] = session
        }
        lock.unlock()
        return aggregate
    }

    @discardableResult
    func updateAudioEnabled(_ enabled: Bool, deviceID: String) -> Bool {
        lock.lock()
        if var session = sessions[deviceID] {
            session.audioEnabled = enabled
            sessions[deviceID] = session
        }
        let anyEnabled = sessions.values.contains(where: { $0.audioEnabled })
        lock.unlock()
        return anyEnabled
    }

    func remove(deviceID: String) {
        lock.lock()
        let removed = sessions.removeValue(forKey: deviceID) != nil
        capacityRejections.remove(deviceID)
        let snapshots = removed ? snapshotsLocked() : nil
        lock.unlock()
        if let snapshots {
            onSessionsChanged?(snapshots)
        }
    }

    func removeAll() {
        lock.lock()
        let changed = !sessions.isEmpty
        sessions.removeAll()
        capacityRejections.removeAll()
        lock.unlock()
        if changed {
            onSessionsChanged?([])
        }
    }

    func activeSessions(now: Date = Date()) -> [ActiveViewerSessionSnapshot] {
        lock.lock()
        let changed = pruneLocked(now: now)
        let snapshots = snapshotsLocked()
        lock.unlock()
        if changed {
            onSessionsChanged?(snapshots)
        }
        return snapshots
    }

    private func pruneLocked(now: Date) -> Bool {
        let before = sessions.count
        sessions = sessions.filter { deviceID, session in
            guard now.timeIntervalSince(session.lastSeen) < inactivityTimeout else { return false }
            return credentialStore?.credential(for: deviceID) != nil
        }
        if sessions.count < maximumViewerCount {
            capacityRejections.removeAll()
        }
        return sessions.count != before
    }

    private func snapshotsLocked() -> [ActiveViewerSessionSnapshot] {
        sessions.values.compactMap { session in
            guard let credential = credentialStore?.credential(for: session.credentialID) else { return nil }
            return ActiveViewerSessionSnapshot(
                credential: credential,
                sourceHost: session.sourceHost,
                lastSeen: session.lastSeen,
                audioEnabled: session.audioEnabled,
                feedback: session.feedback
            )
        }
        .sorted { $0.lastSeen > $1.lastSeen }
    }

    private static func aggregate(feedbacks: [ViewerFeedback], fallback: ViewerFeedback) -> ViewerFeedback {
        guard !feedbacks.isEmpty else { return fallback }
        let measured = feedbacks.filter(\.hasMeasuredViewerStats)
        let fps = measured.map(\.fps).filter { $0 > 0 }.min() ?? 0
        let mostConstrainedQuality = feedbacks
            .compactMap(\.qualityProfile)
            .min { qualityRank($0) < qualityRank($1) }
            ?? .balanced
        let representative = measured.first ?? feedbacks[0]
        // Every cap is the strictest one any viewer asked for, whether it
        // came from a preset or from explicit slider limits.
        let limits = feedbacks.map(\.streamLimits).dropFirst().reduce(feedbacks[0].streamLimits) {
            $0.mostConstrained(with: $1)
        }
        var aggregate = ViewerFeedback(
            fps: fps,
            videoWidth: representative.videoWidth,
            videoHeight: representative.videoHeight,
            receivedChunks: measured.map(\.receivedChunks).min() ?? 0,
            completedFrames: measured.map(\.completedFrames).min() ?? 0,
            skippedFrames: measured.map(\.skippedFrames).max() ?? 0,
            estimatedLossPercent: measured.map(\.estimatedLossPercent).max() ?? 0,
            keyframeRequested: feedbacks.contains { $0.keyframeRequested == true },
            qualityProfile: mostConstrainedQuality,
            maximumFrameRate: limits.maximumFrameRate,
            maximumBitrate: limits.maximumBitrate,
            maximumCaptureWidth: limits.maximumCaptureWidth
        )
        aggregate.resolvedLimits = limits
        return aggregate
    }

    private static func qualityRank(_ profile: ViewerQualityProfile) -> Int {
        switch profile {
        case .dataSaver: return 0
        case .balanced: return 1
        case .smooth: return 2
        case .max: return 3
        }
    }

    private static func consumingKeyframeRequest(_ feedback: ViewerFeedback) -> ViewerFeedback {
        var consumed = ViewerFeedback(
            fps: feedback.fps,
            videoWidth: feedback.videoWidth,
            videoHeight: feedback.videoHeight,
            receivedChunks: feedback.receivedChunks,
            completedFrames: feedback.completedFrames,
            skippedFrames: feedback.skippedFrames,
            estimatedLossPercent: feedback.estimatedLossPercent,
            keyframeRequested: false,
            qualityProfile: feedback.qualityProfile,
            maximumFrameRate: feedback.maximumFrameRate,
            maximumBitrate: feedback.maximumBitrate,
            maximumCaptureWidth: feedback.maximumCaptureWidth
        )
        consumed.resolvedLimits = feedback.resolvedLimits
        return consumed
    }
}

final class SecureMultiPeerDatagramSender: DatagramSending {
    var onLocalNetworkSendFailure: ((Int32) -> Void)?

    private let sender: UDPMultiPeerSender
    private let channel: SecureSessionChannel
    private let port: UInt16
    private let sessions: ActiveViewerSessionRegistry
    private let permissionWarningLock = NSLock()
    private var lastNetworkFailureReports: [String: Date] = [:]

    init(sender: UDPMultiPeerSender, channel: SecureSessionChannel, port: UInt16, sessions: ActiveViewerSessionRegistry) {
        self.sender = sender
        self.channel = channel
        self.port = port
        self.sessions = sessions
    }

    func send(_ data: Data) throws {
        try send(data) { _ in true }
    }

    func send(_ data: Data, allowing isAllowed: (TrustedDeviceCredential) -> Bool) throws {
        let activeSessions = sessions.activeSessions().filter {
            isAllowed($0.credential)
                && (channel != .audio || ($0.audioEnabled && $0.credential.record.allowsAudio))
        }
        var firstError: Error?
        var sentCount = 0
        for session in activeSessions {
            guard let sealed = SecureSessionDatagram.seal(
                data,
                channel: channel,
                credentialID: session.credential.record.id,
                secret: session.credential.secret
            ) else { continue }
            do {
                try sender.send(sealed, toHost: session.sourceHost, port: port)
                sentCount += 1
            } catch {
                firstError = firstError ?? error
                reportLocalNetworkSendFailureIfNeeded(error, host: session.sourceHost)
            }
        }
        if !activeSessions.isEmpty, sentCount == 0, let firstError {
            throw firstError
        }
    }

    func stop() {
        sender.stop()
    }

    private func reportLocalNetworkSendFailureIfNeeded(_ error: Error, host: String) {
        // These destinations belong to authenticated, recently active viewers.
        // Log the route category without exposing the viewer's address.
        guard case let UDPSocketError.sendFailed(code) = error,
              code == EPERM || code == EACCES || code == EHOSTUNREACH else { return }
        let isLAN = NetworkAddressPolicy.isPrivateOrLocalAddress(host)
            && !NetworkAddressPolicy.isTailscaleAddress(host) && !IPNetwork.isLoopback(host)
        let route = isLAN ? "local Wi-Fi/Ethernet" : (NetworkAddressPolicy.isTailscaleAddress(host) ? "Tailscale" : "non-LAN")

        let now = Date()
        permissionWarningLock.lock()
        let shouldReport = now.timeIntervalSince(lastNetworkFailureReports[route] ?? .distantPast) >= 10
        if shouldReport {
            lastNetworkFailureReports[route] = now
        }
        permissionWarningLock.unlock()

        guard shouldReport else { return }
        let action = isLAN ? "checking warning" : "skipping Local Network warning for non-LAN route"
        NSLog("PocketCtrl network send failure route=%@ errno=%d: %@", route, code, action)
        PocketCtrlHostDiagnostics.write("network send failure route=\(route) errno=\(code): \(action)")
        guard isLAN else { return }
        onLocalNetworkSendFailure?(code)
    }
}
