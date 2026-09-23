// SPDX-License-Identifier: MPL-2.0

import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import OSLog

enum PocketCtrlHostDiagnostics {
    private static let connectionLogger = Logger(subsystem: "app.pocketctrl.mac", category: "ConnectionDebug")

    // Only for random, non-secret host/credential IDs, never secrets or addresses.
    static func identifierTag(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func connection(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "[ConnectionDebug v1] \(message())"
        connectionLogger.notice("\(line, privacy: .public)")
        write(line)
        #endif
    }

    private static let lock = NSLock()
    private static let maximumLogBytes: UInt64 = 512 * 1024
    private static let archivedLogCount = 3

    static var logURL: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PocketCtrl", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PocketCtrl", isDirectory: true)
        return directory.appendingPathComponent("host-diagnostics.log")
    }

    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) \(message())\n"

        lock.lock()
        defer { lock.unlock() }

        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let size = attributes[.size] as? NSNumber,
               size.uint64Value >= maximumLogBytes {
                try rotateLogs()
            }
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL)
            }
        } catch {
            NSLog("PocketCtrl diagnostic log write failed: \(error.localizedDescription)")
        }
        #endif
    }

    private static func rotateLogs() throws {
        let fileManager = FileManager.default
        for index in stride(from: archivedLogCount, through: 1, by: -1) {
            let destination = archivedLogURL(index: index)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            let source = index == 1 ? logURL : archivedLogURL(index: index - 1)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    private static func archivedLogURL(index: Int) -> URL {
        logURL.deletingLastPathComponent()
            .appendingPathComponent("host-diagnostics.\(index).log")
    }
}

enum RemoteInputKind: String, Codable {
    case mouseMove
    case mouseMoveRelative
    case mouseMoveRelativeNormalized
    case mouseDown
    case mouseUp
    case scroll
    case keyDown
    case keyUp
}

enum RemoteMouseButton: Int, Codable {
    case left = 0
    case right = 1
    case center = 2

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .center: return .center
        }
    }
}

struct RemoteInputEvent: Codable {
    let kind: RemoteInputKind
    let x: Double
    let y: Double
    let button: RemoteMouseButton
    let deltaX: Double
    let deltaY: Double
    let keyCode: UInt16
    let modifiers: UInt64
    let clickCount: Int?

    static func pointer(_ kind: RemoteInputKind, x: Double, y: Double, button: RemoteMouseButton, clickCount: Int = 1) -> RemoteInputEvent {
        RemoteInputEvent(kind: kind, x: x, y: y, button: button, deltaX: 0, deltaY: 0, keyCode: 0, modifiers: 0, clickCount: clickCount)
    }

    static func relativePointer(deltaX: Double, deltaY: Double, button: RemoteMouseButton) -> RemoteInputEvent {
        RemoteInputEvent(kind: .mouseMoveRelative, x: 0, y: 0, button: button, deltaX: deltaX, deltaY: deltaY, keyCode: 0, modifiers: 0, clickCount: nil)
    }

    static func normalizedRelativePointer(deltaX: Double, deltaY: Double, button: RemoteMouseButton) -> RemoteInputEvent {
        RemoteInputEvent(kind: .mouseMoveRelativeNormalized, x: 0, y: 0, button: button, deltaX: deltaX, deltaY: deltaY, keyCode: 0, modifiers: 0, clickCount: nil)
    }

    static func currentPointerButton(_ kind: RemoteInputKind, button: RemoteMouseButton, clickCount: Int = 1) -> RemoteInputEvent {
        RemoteInputEvent(kind: kind, x: -1, y: -1, button: button, deltaX: 0, deltaY: 0, keyCode: 0, modifiers: 0, clickCount: clickCount)
    }

    static func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) -> RemoteInputEvent {
        RemoteInputEvent(kind: .scroll, x: x, y: y, button: .left, deltaX: deltaX, deltaY: deltaY, keyCode: 0, modifiers: 0, clickCount: nil)
    }

    static func key(_ kind: RemoteInputKind, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> RemoteInputEvent {
        RemoteInputEvent(kind: kind, x: 0, y: 0, button: .left, deltaX: 0, deltaY: 0, keyCode: keyCode, modifiers: modifiers.cgEventFlags.rawValue, clickCount: nil)
    }
}

enum RemoteInputDebugLog {
    static func write(_ message: String) {
        #if DEBUG
        let line = "input \(message)"
        NSLog("PocketCtrl \(line)")
        PocketCtrlHostDiagnostics.write(line)
        #endif
    }

    static func event(_ event: RemoteInputEvent) -> String {
        "kind=\(event.kind.rawValue) x=\(number(event.x)) y=\(number(event.y)) deltaX=\(number(event.deltaX)) deltaY=\(number(event.deltaY)) button=\(event.button.rawValue) clickCount=\(event.normalizedClickCount)"
    }

    static func point(_ point: CGPoint) -> String {
        "(\(number(point.x)),\(number(point.y)))"
    }

    static func rect(_ rect: CGRect) -> String {
        "(x:\(number(rect.minX)) y:\(number(rect.minY)) w:\(number(rect.width)) h:\(number(rect.height)))"
    }

    static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func number(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }
}

struct ViewerFeedback: Codable {
    let fps: Int
    let videoWidth: Int
    let videoHeight: Int
    let receivedChunks: Int
    let completedFrames: Int
    let skippedFrames: Int
    let estimatedLossPercent: Double
    let keyframeRequested: Bool?
    let qualityProfile: ViewerQualityProfile?
    // Optional explicit limits (bits per second, frames per second, pixels).
    // Viewers with a slider-based quality setting send these; preset-only
    // viewers omit them and the profile's limits apply.
    let maximumFrameRate: Int?
    let maximumBitrate: Int?
    let maximumCaptureWidth: Int?
    // Set by multi-viewer aggregation only; never sent on the wire.
    var resolvedLimits: ViewerStreamLimits? = nil

    private enum CodingKeys: String, CodingKey {
        case fps, videoWidth, videoHeight, receivedChunks, completedFrames, skippedFrames
        case estimatedLossPercent, keyframeRequested, qualityProfile
        case maximumFrameRate, maximumBitrate, maximumCaptureWidth
    }

    var hasMeasuredViewerStats: Bool {
        fps > 0 || receivedChunks > 0 || completedFrames > 0
    }

    /// The limits the host should honor for this viewer: explicit numeric
    /// limits when present, otherwise the preset profile's limits.
    var streamLimits: ViewerStreamLimits {
        if let resolvedLimits { return resolvedLimits }
        let profile = qualityProfile ?? .balanced
        guard maximumFrameRate != nil || maximumBitrate != nil || maximumCaptureWidth != nil else {
            return profile.limits
        }
        return ViewerStreamLimits.custom(
            maximumBitrate: maximumBitrate ?? profile.maximumBitrate,
            maximumFrameRate: maximumFrameRate ?? profile.maximumFrameRate,
            maximumCaptureWidth: maximumCaptureWidth ?? profile.maximumCaptureWidth
        )
    }

    init(
        fps: Int,
        videoWidth: Int,
        videoHeight: Int,
        receivedChunks: Int,
        completedFrames: Int,
        skippedFrames: Int,
        estimatedLossPercent: Double,
        keyframeRequested: Bool?,
        qualityProfile: ViewerQualityProfile? = nil,
        maximumFrameRate: Int? = nil,
        maximumBitrate: Int? = nil,
        maximumCaptureWidth: Int? = nil
    ) {
        self.fps = fps
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.receivedChunks = receivedChunks
        self.completedFrames = completedFrames
        self.skippedFrames = skippedFrames
        self.estimatedLossPercent = estimatedLossPercent
        self.keyframeRequested = keyframeRequested
        self.qualityProfile = qualityProfile
        self.maximumFrameRate = maximumFrameRate
        self.maximumBitrate = maximumBitrate
        self.maximumCaptureWidth = maximumCaptureWidth
    }
}

/// The concrete caps the host applies for a viewer (or for all viewers
/// combined). Presets and slider-based custom settings both resolve to this.
struct ViewerStreamLimits: Equatable {
    let maximumBitrate: Int
    let minimumBitrate: Int
    let maximumFrameRate: Int
    let maximumCaptureWidth: Int
    let idleFrameRate: Int

    /// Derives the adaptive floor and idle pacing from explicit caps sent by a
    /// viewer. Inputs come from an authenticated peer but are still bounded.
    static func custom(maximumBitrate: Int, maximumFrameRate: Int, maximumCaptureWidth: Int) -> ViewerStreamLimits {
        let bitrate = min(100_000_000, max(100_000, maximumBitrate))
        let frameRate = min(240, max(1, maximumFrameRate))
        let width = min(16_384, max(320, maximumCaptureWidth))
        // The floor leaves room to back off on a bad link but never collapses
        // a high-detail request into a blurry stream.
        let minimum = min(bitrate, max(100_000, min(3_000_000, bitrate * 35 / 100)))
        let idle = min(frameRate, frameRate <= 20 ? 1 : (frameRate <= 30 ? 8 : 30))
        return ViewerStreamLimits(
            maximumBitrate: bitrate,
            minimumBitrate: minimum,
            maximumFrameRate: frameRate,
            maximumCaptureWidth: width,
            idleFrameRate: idle
        )
    }

    /// With several viewers, every cap is the strictest one requested.
    func mostConstrained(with other: ViewerStreamLimits) -> ViewerStreamLimits {
        let bitrate = min(maximumBitrate, other.maximumBitrate)
        return ViewerStreamLimits(
            maximumBitrate: bitrate,
            minimumBitrate: min(bitrate, min(minimumBitrate, other.minimumBitrate)),
            maximumFrameRate: min(maximumFrameRate, other.maximumFrameRate),
            maximumCaptureWidth: min(maximumCaptureWidth, other.maximumCaptureWidth),
            idleFrameRate: min(idleFrameRate, other.idleFrameRate)
        )
    }

    func frameRate(hostFrameRate: Int, backoff: Int = 1) -> Int {
        max(1, min(hostFrameRate, maximumFrameRate) / max(1, backoff))
    }

    func bitrateCap(hostBitrate: Int, codecFactor: Double = 1) -> Int {
        max(1, Int((Double(min(hostBitrate, maximumBitrate)) * codecFactor).rounded()))
    }
}

/// Timestamp-based pacing preserves rates such as 45 fps from a 60 fps source
/// without rounding down to every second frame. Missed frames never accumulate
/// a backlog, and a slower capture source is not unnecessarily throttled.
struct StreamFramePacer {
    private var nextFrameTime: Double?
    private var previousTime: Double?
    private var frameRate = 0

    mutating func shouldSend(at time: Double, frameRate requestedRate: Int) -> Bool {
        guard time.isFinite else { return false }
        let rate = max(1, requestedRate)
        let interval = 1 / Double(rate)
        if rate != frameRate || previousTime.map({ time < $0 }) == true {
            nextFrameTime = nil
        }
        frameRate = rate
        previousTime = time
        guard let next = nextFrameTime else {
            nextFrameTime = time + interval
            return true
        }
        guard time + 0.000_001 >= next else { return false }
        let elapsedIntervals = max(1, floor((time - next + 0.000_001) / interval) + 1)
        nextFrameTime = next + elapsedIntervals * interval
        return true
    }
}

enum ViewerQualityProfile: String, Codable, Equatable, CaseIterable, Identifiable {
    case dataSaver
    case balanced
    case smooth
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dataSaver: return "Saver"
        case .balanced: return "Balanced"
        case .smooth: return "Smooth"
        case .max: return "Max"
        }
    }

    var subtitle: String {
        switch self {
        case .dataSaver: return "Lowest data use for cellular."
        case .balanced: return "Lower data with clear screen detail."
        case .smooth: return "Highest frame rate for motion, moderate detail."
        case .max: return "Best picture. The app can still back off if needed."
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.dataSaver.rawValue:
            self = .dataSaver
        case Self.smooth.rawValue:
            self = .smooth
        case Self.max.rawValue:
            self = .max
        default:
            // Unknown values (including a viewer's "custom") fall back to
            // balanced; explicit numeric limits, when sent, still apply.
            self = .balanced
        }
    }

    var maximumBitrate: Int {
        switch self {
        case .dataSaver: return 2_000_000
        case .balanced: return 6_000_000
        case .smooth: return 9_000_000
        case .max: return 30_000_000
        }
    }

    var minimumBitrate: Int {
        switch self {
        case .dataSaver: return 700_000
        case .balanced: return 3_000_000
        case .smooth: return 3_000_000
        case .max: return 3_000_000
        }
    }

    var idleFrameRate: Int {
        switch self {
        case .dataSaver: return 1
        case .balanced: return 8
        case .smooth: return 30
        case .max: return 30
        }
    }

    var maximumFrameRate: Int {
        switch self {
        case .dataSaver: return 20
        case .balanced: return 30
        case .smooth: return 60
        case .max: return 60
        }
    }

    var maximumCaptureWidth: Int {
        switch self {
        case .dataSaver: return 1_280
        case .balanced: return 1_600
        case .smooth: return 1_600
        case .max: return Int.max
        }
    }

    var limits: ViewerStreamLimits {
        ViewerStreamLimits(
            maximumBitrate: maximumBitrate,
            minimumBitrate: minimumBitrate,
            maximumFrameRate: maximumFrameRate,
            maximumCaptureWidth: maximumCaptureWidth,
            idleFrameRate: idleFrameRate
        )
    }
}

struct ViewerZoomRegion: Codable {
    let enabled: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ViewerAudioSetting: Codable {
    let enabled: Bool
}

struct ClipboardPayload: Codable {
    let text: String
    let changeID: String
}

enum ControlPayloadType: String, Codable {
    case input
    case feedback
    case zoomRegion
    case audioSetting
    case computerUse
    case clipboard
}

struct AuthenticatedControlEnvelope: Codable {
    let version: Int
    let credentialID: String
    let type: ControlPayloadType
    let timestamp: TimeInterval
    let nonce: String
    let sealedPayload: Data
}

enum AuthenticatedControlDatagram {
    private struct CredentialClaim: Decodable {
        let version: Int
        let credentialID: String
    }

    static let currentVersion = 1
    private static let allowedClockDrift: TimeInterval = 60
    private static let maximumRememberedNonces = 16_384
    private static let retainedNoncesAfterPruning = 8_192

    static func seal<T: Encodable>(
        _ value: T,
        type: ControlPayloadType,
        credentialID: String,
        secret: String,
        encoder: JSONEncoder
    ) -> Data? {
        guard !credentialID.isEmpty, !secret.isEmpty,
              let payload = try? encoder.encode(value) else {
            return nil
        }

        let timestamp = Date().timeIntervalSince1970
        let nonce = UUID().uuidString
        let metadata = authenticationMetadata(
            credentialID: credentialID,
            type: type,
            timestamp: timestamp,
            nonce: nonce
        )
        guard let sealed = try? ChaChaPoly.seal(
            payload,
            using: encryptionKey(secret: secret, credentialID: credentialID),
            authenticating: metadata
        ) else { return nil }
        let envelope = AuthenticatedControlEnvelope(
            version: currentVersion,
            credentialID: credentialID,
            type: type,
            timestamp: timestamp,
            nonce: nonce,
            sealedPayload: sealed.combined
        )
        return try? encoder.encode(envelope)
    }

    static func open(
        _ data: Data,
        credentialProvider: (String) -> TrustedDeviceCredential?,
        decoder: JSONDecoder,
        seenNonces: inout [String: Date]
    ) -> (type: ControlPayloadType, payload: Data, credential: TrustedDeviceCredential)? {
        guard let envelope = try? decoder.decode(AuthenticatedControlEnvelope.self, from: data),
              envelope.version == currentVersion else {
            return nil
        }

        let now = Date()
        guard abs(now.timeIntervalSince1970 - envelope.timestamp) <= allowedClockDrift else {
            return nil
        }

        if seenNonces.count >= maximumRememberedNonces {
            seenNonces = Dictionary(
                uniqueKeysWithValues: seenNonces
                    .sorted { $0.value > $1.value }
                    .prefix(retainedNoncesAfterPruning)
                    .map { ($0.key, $0.value) }
            )
        }
        guard seenNonces[envelope.nonce] == nil else {
            return nil
        }

        guard let credential = credentialProvider(envelope.credentialID) else { return nil }
        let metadata = authenticationMetadata(
            credentialID: envelope.credentialID,
            type: envelope.type,
            timestamp: envelope.timestamp,
            nonce: envelope.nonce
        )
        guard let box = try? ChaChaPoly.SealedBox(combined: envelope.sealedPayload),
              let payload = try? ChaChaPoly.open(
                box,
                using: encryptionKey(secret: credential.secret, credentialID: credential.record.id),
                authenticating: metadata
              ) else {
            return nil
        }

        seenNonces[envelope.nonce] = now
        return (envelope.type, payload, credential)
    }

    static func claimedCredentialID(in data: Data, decoder: JSONDecoder) -> String? {
        guard let claim = try? decoder.decode(CredentialClaim.self, from: data),
              claim.version == currentVersion,
              !claim.credentialID.isEmpty else {
            return nil
        }
        return claim.credentialID
    }

    private static func authenticationMetadata(
        credentialID: String,
        type: ControlPayloadType,
        timestamp: TimeInterval,
        nonce: String
    ) -> Data {
        var body = Data()
        body.append(Data(credentialID.utf8))
        body.append(0)
        body.append(Data(type.rawValue.utf8))
        body.append(0)
        body.append(Data(String(format: "%.3f", timestamp).utf8))
        body.append(0)
        body.append(Data(nonce.utf8))
        return body
    }

    private static func encryptionKey(secret: String, credentialID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data(credentialID.utf8),
            info: Data("PocketCtrl encrypted control v2".utf8),
            outputByteCount: 32
        )
    }
}

enum ClipboardVideoDatagram {
    private static let prefix = Data("PCTRL_CLIPBOARD_V1\n".utf8)

    static func seal(_ payload: ClipboardPayload, encoder: JSONEncoder) -> Data? {
        guard let controlData = try? encoder.encode(payload) else { return nil }
        var data = prefix
        data.append(controlData)
        return data
    }

    static func open(
        _ data: Data,
        decoder: JSONDecoder
    ) -> ClipboardPayload? {
        guard data.starts(with: prefix) else { return nil }
        let controlData = Data(data.dropFirst(prefix.count))
        return try? decoder.decode(ClipboardPayload.self, from: controlData)
    }
}

struct ClipboardFrameChunk {
    let frameID: UInt32
    let chunkIndex: UInt16
    let chunkCount: UInt16
    let totalPayloadSize: Int
    let payload: Data
}

enum UDPClipboardFraming {
    private static let magic: UInt32 = 0x50435443 // PCTC
    private static let version: UInt16 = 1
    private static let headerSize = 20
    private static let maxPayloadSize = 1 * 1_024 * 1_024
    private static let maxChunkCount: UInt16 = 1_024

    static func chunk(_ payload: Data, frameID: UInt32, maxDatagramSize: Int = UDPVideoFraming.maxDatagramSize) -> [Data] {
        let maxPayloadSize = max(1, maxDatagramSize - headerSize)
        let chunkCount = UInt16((payload.count + maxPayloadSize - 1) / maxPayloadSize)
        guard chunkCount > 0 else { return [] }

        var datagrams: [Data] = []
        datagrams.reserveCapacity(Int(chunkCount))

        for chunkIndex in 0..<Int(chunkCount) {
            let lower = chunkIndex * maxPayloadSize
            let upper = min(payload.count, lower + maxPayloadSize)
            let payloadSlice = payload[lower..<upper]

            var datagram = Data()
            datagram.reserveCapacity(headerSize + payloadSlice.count)
            ByteCoding.appendUInt32(magic, to: &datagram)
            ByteCoding.appendUInt16(version, to: &datagram)
            ByteCoding.appendUInt32(frameID, to: &datagram)
            ByteCoding.appendUInt16(UInt16(chunkIndex), to: &datagram)
            ByteCoding.appendUInt16(chunkCount, to: &datagram)
            ByteCoding.appendUInt32(UInt32(payload.count), to: &datagram)
            ByteCoding.appendUInt16(UInt16(payloadSlice.count), to: &datagram)
            datagram.append(payloadSlice)
            datagrams.append(datagram)
        }

        return datagrams
    }

    static func parseDatagram(_ datagram: Data) -> ClipboardFrameChunk? {
        guard datagram.count >= headerSize,
              ByteCoding.uint32(datagram, at: 0) == magic,
              ByteCoding.uint16(datagram, at: 4) == version,
              let frameID = ByteCoding.uint32(datagram, at: 6),
              let chunkIndex = ByteCoding.uint16(datagram, at: 10),
              let chunkCount = ByteCoding.uint16(datagram, at: 12),
              let totalPayloadSize = ByteCoding.uint32(datagram, at: 14),
              let payloadSize = ByteCoding.uint16(datagram, at: 18) else {
            return nil
        }

        let payloadStart = headerSize
        let payloadEnd = payloadStart + Int(payloadSize)
        guard payloadEnd <= datagram.count,
              chunkIndex < chunkCount,
              chunkCount > 0,
              chunkCount <= maxChunkCount,
              totalPayloadSize > 0,
              totalPayloadSize <= UInt32(maxPayloadSize) else {
            return nil
        }

        return ClipboardFrameChunk(
            frameID: frameID,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            totalPayloadSize: Int(totalPayloadSize),
            payload: datagram[payloadStart..<payloadEnd]
        )
    }
}

final class ClipboardFrameReassembler {
    private struct PartialFrame {
        let chunkCount: UInt16
        let totalPayloadSize: Int
        var chunks: [UInt16: Data]
        var lastTouched: Date
    }

    private var partialFrames: [UInt32: PartialFrame] = [:]
    private let staleInterval: TimeInterval

    init(staleInterval: TimeInterval = 4.0) {
        self.staleInterval = staleInterval
    }

    func push(_ chunk: ClipboardFrameChunk) -> Data? {
        pruneStaleFrames()

        if partialFrames[chunk.frameID] == nil, partialFrames.count >= 32,
           let oldestFrameID = partialFrames.min(by: { $0.value.lastTouched < $1.value.lastTouched })?.key {
            partialFrames.removeValue(forKey: oldestFrameID)
        }

        var partial = partialFrames[chunk.frameID] ?? PartialFrame(
            chunkCount: chunk.chunkCount,
            totalPayloadSize: chunk.totalPayloadSize,
            chunks: [:],
            lastTouched: Date()
        )

        guard partial.chunkCount == chunk.chunkCount,
              partial.totalPayloadSize == chunk.totalPayloadSize else {
            partialFrames.removeValue(forKey: chunk.frameID)
            return nil
        }

        partial.chunks[chunk.chunkIndex] = chunk.payload
        partial.lastTouched = Date()
        partialFrames[chunk.frameID] = partial

        guard partial.chunks.count == Int(partial.chunkCount) else { return nil }

        var payload = Data()
        payload.reserveCapacity(partial.totalPayloadSize)
        for index in 0..<partial.chunkCount {
            guard let chunkPayload = partial.chunks[index] else { return nil }
            payload.append(chunkPayload)
        }

        partialFrames.removeValue(forKey: chunk.frameID)
        guard payload.count == partial.totalPayloadSize else { return nil }
        return payload
    }

    private func pruneStaleFrames() {
        let now = Date()
        partialFrames = partialFrames.filter { _, partial in
            now.timeIntervalSince(partial.lastTouched) < staleInterval
        }
    }
}

final class ClipboardSynchronizer {
    static let maximumTextBytes = 24_000

    private let label: String
    private let onLocalChange: (ClipboardPayload) -> Void
    private var timer: DispatchSourceTimer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastSyncedText: String?
    private var appliedChangeIDs: [String: Date] = [:]

    init(label: String, onLocalChange: @escaping (ClipboardPayload) -> Void) {
        self.label = label
        self.onLocalChange = onLocalChange
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let pasteboard = NSPasteboard.general
            self.lastChangeCount = pasteboard.changeCount
            self.lastSyncedText = pasteboard.string(forType: .string)

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                self?.pollPasteboard()
            }
            self.timer = timer
            timer.resume()
            NSLog("PocketCtrl clipboard sync started label=\(self.label) maxBytes=\(Self.maximumTextBytes)")
            PocketCtrlHostDiagnostics.write("clipboard sync started label=\(self.label) maxBytes=\(Self.maximumTextBytes)")
        }
    }

    func stop() {
        if Thread.isMainThread {
            stopOnMain()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.stopOnMain()
            }
        }
    }

    func apply(_ payload: ClipboardPayload) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            self.appliedChangeIDs = self.appliedChangeIDs.filter { now.timeIntervalSince($0.value) < 120 }
            guard self.appliedChangeIDs[payload.changeID] == nil else {
                PocketCtrlHostDiagnostics.write("clipboard duplicate ignored label=\(self.label) changeID=\(payload.changeID)")
                return
            }
            self.appliedChangeIDs[payload.changeID] = now

            let byteCount = payload.text.utf8.count
            guard byteCount <= Self.maximumTextBytes else {
                NSLog("PocketCtrl clipboard apply skipped label=\(self.label) bytes=\(byteCount) maxBytes=\(Self.maximumTextBytes)")
                PocketCtrlHostDiagnostics.write("clipboard apply skipped label=\(self.label) bytes=\(byteCount) maxBytes=\(Self.maximumTextBytes)")
                return
            }

            let pasteboard = NSPasteboard.general
            if pasteboard.string(forType: .string) != payload.text {
                pasteboard.clearContents()
                pasteboard.setString(payload.text, forType: .string)
            }
            self.lastChangeCount = pasteboard.changeCount
            self.lastSyncedText = payload.text
            NSLog("PocketCtrl clipboard applied label=\(self.label) bytes=\(byteCount) changeID=\(payload.changeID)")
            PocketCtrlHostDiagnostics.write("clipboard applied label=\(self.label) bytes=\(byteCount) changeID=\(payload.changeID)")
        }
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        guard let text = pasteboard.string(forType: .string) else { return }
        guard text != lastSyncedText else { return }

        let byteCount = text.utf8.count
        guard byteCount <= Self.maximumTextBytes else {
            NSLog("PocketCtrl clipboard send skipped label=\(label) bytes=\(byteCount) maxBytes=\(Self.maximumTextBytes)")
            PocketCtrlHostDiagnostics.write("clipboard send skipped label=\(label) bytes=\(byteCount) maxBytes=\(Self.maximumTextBytes)")
            return
        }

        lastSyncedText = text
        let payload = ClipboardPayload(text: text, changeID: UUID().uuidString)
        NSLog("PocketCtrl clipboard local change label=\(label) bytes=\(byteCount) changeID=\(payload.changeID)")
        PocketCtrlHostDiagnostics.write("clipboard local change label=\(label) bytes=\(byteCount) changeID=\(payload.changeID)")
        onLocalChange(payload)
    }

    private func stopOnMain() {
        timer?.cancel()
        timer = nil
        NSLog("PocketCtrl clipboard sync stopped label=\(label)")
        PocketCtrlHostDiagnostics.write("clipboard sync stopped label=\(label)")
    }
}

final class RemoteInputSender {
    private static let relativeFlushInterval: DispatchTimeInterval = .milliseconds(4)
    private static let maximumRelativeDelta = 10_000.0
    private let sender: any DatagramSending
    private let sharedSecret: String
    private let credentialID: String
    private let encoder = JSONEncoder()
    private let clipboardEncoder = JSONEncoder()
    private let queue = DispatchQueue(label: "pocketctrl.input.sender", qos: .userInteractive)
    private let clipboardQueue = DispatchQueue(label: "pocketctrl.input.clipboard.sender", qos: .utility)
    private var pendingRelativeDeltaX = 0.0
    private var pendingRelativeDeltaY = 0.0
    private var pendingRelativeButton = RemoteMouseButton.left
    private var pendingRelativeKind = RemoteInputKind.mouseMoveRelative
    private var pendingRelativeFlush: DispatchWorkItem?
    private var debugSentInputCount = 0
    private var debugRelativeEnqueueCount = 0

    init(host: String, port: UInt16, credentialID: String, sharedSecret: String) throws {
        sender = try UDPSender(host: host, port: port)
        self.credentialID = credentialID
        self.sharedSecret = sharedSecret
        NSLog("PocketCtrl remote input sender created port=\(port)")
    }

    func send(_ event: RemoteInputEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            self.logSenderDebug("queue event \(RemoteInputDebugLog.event(event)) pendingRelative=(\(RemoteInputDebugLog.number(self.pendingRelativeDeltaX)),\(RemoteInputDebugLog.number(self.pendingRelativeDeltaY))) pendingKind=\(self.pendingRelativeKind.rawValue)")
            if event.kind.isRelativeMouseMove {
                self.enqueueRelativeMove(event)
            } else {
                self.flushPendingRelativeMove()
                self.sendNow(event)
            }
        }
    }

    private func enqueueRelativeMove(_ event: RemoteInputEvent) {
        if pendingRelativeKind != event.kind {
            logSenderDebug("relative kind switch old=\(pendingRelativeKind.rawValue) new=\(event.kind.rawValue); flushing before enqueue")
            flushPendingRelativeMove()
        }

        pendingRelativeDeltaX = Self.clampedRelativeDelta(pendingRelativeDeltaX + event.deltaX)
        pendingRelativeDeltaY = Self.clampedRelativeDelta(pendingRelativeDeltaY + event.deltaY)
        pendingRelativeButton = event.button
        pendingRelativeKind = event.kind
        debugRelativeEnqueueCount += 1
        if debugRelativeEnqueueCount <= 60 || max(abs(event.deltaX), abs(event.deltaY)) > 120 {
            logSenderDebug("relative enqueue index=\(debugRelativeEnqueueCount) incoming=\(RemoteInputDebugLog.event(event)) pending=(\(RemoteInputDebugLog.number(pendingRelativeDeltaX)),\(RemoteInputDebugLog.number(pendingRelativeDeltaY)))")
        }

        guard pendingRelativeFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRelativeFlush = nil
            self?.flushPendingRelativeMove()
        }
        pendingRelativeFlush = work
        queue.asyncAfter(deadline: .now() + Self.relativeFlushInterval, execute: work)
    }

    private func flushPendingRelativeMove() {
        pendingRelativeFlush?.cancel()
        pendingRelativeFlush = nil
        guard pendingRelativeDeltaX != 0 || pendingRelativeDeltaY != 0 else { return }
        let event = pendingRelativeKind == .mouseMoveRelativeNormalized
            ? RemoteInputEvent.normalizedRelativePointer(deltaX: pendingRelativeDeltaX, deltaY: pendingRelativeDeltaY, button: pendingRelativeButton)
            : RemoteInputEvent.relativePointer(deltaX: pendingRelativeDeltaX, deltaY: pendingRelativeDeltaY, button: pendingRelativeButton)
        pendingRelativeDeltaX = 0
        pendingRelativeDeltaY = 0
        pendingRelativeKind = .mouseMoveRelative
        logSenderDebug("relative flush send \(RemoteInputDebugLog.event(event))")
        sendNow(event)
    }

    private func sendNow(_ event: RemoteInputEvent) {
        guard let data = AuthenticatedControlDatagram.seal(event, type: .input, credentialID: credentialID, secret: sharedSecret, encoder: encoder) else { return }
        do {
            try sender.send(data)
            debugSentInputCount += 1
            if shouldLogSenderEvent(event) {
                logSenderDebug("sent index=\(debugSentInputCount) bytes=\(data.count) \(RemoteInputDebugLog.event(event))")
            }
        } catch {
            NSLog("PocketCtrl failed to send input control packet type=\(event.kind.rawValue): \(error)")
        }
    }

    private func shouldLogSenderEvent(_ event: RemoteInputEvent) -> Bool {
        if !event.kind.isRelativeMouseMove { return true }
        return debugSentInputCount <= 80 || max(abs(event.deltaX), abs(event.deltaY)) > 120
    }

    private func logSenderDebug(_ message: String) {
        RemoteInputDebugLog.write("sender \(message)")
    }

    func send(_ feedback: ViewerFeedback) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingRelativeMove()
            guard let data = AuthenticatedControlDatagram.seal(feedback, type: .feedback, credentialID: self.credentialID, secret: self.sharedSecret, encoder: self.encoder) else { return }
            do {
                try self.sender.send(data)
            } catch {
                NSLog("PocketCtrl failed to send viewer feedback packet: \(error)")
            }
        }
    }

    func send(_ audioSetting: ViewerAudioSetting) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingRelativeMove()
            guard let data = AuthenticatedControlDatagram.seal(audioSetting, type: .audioSetting, credentialID: self.credentialID, secret: self.sharedSecret, encoder: self.encoder) else { return }
            do {
                try self.sender.send(data)
            } catch {
                NSLog("PocketCtrl failed to send audio setting packet enabled=\(audioSetting.enabled): \(error)")
            }
        }
    }

    func send(_ clipboard: ClipboardPayload) {
        clipboardQueue.async { [weak self] in
            guard let self else { return }
            for attempt in 1...3 {
                guard let data = AuthenticatedControlDatagram.seal(clipboard, type: .clipboard, credentialID: self.credentialID, secret: self.sharedSecret, encoder: self.clipboardEncoder) else { return }
                do {
                    try self.sender.send(data)
                    NSLog("PocketCtrl sent clipboard control packet attempt=\(attempt) bytes=\(clipboard.text.utf8.count) changeID=\(clipboard.changeID)")
                } catch {
                    NSLog("PocketCtrl failed to send clipboard control packet attempt=\(attempt) bytes=\(clipboard.text.utf8.count): \(error)")
                }

                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.04)
                }
            }
        }
    }

    private static func clampedRelativeDelta(_ delta: Double) -> Double {
        min(max(delta, -maximumRelativeDelta), maximumRelativeDelta)
    }
}

final class RemoteInputListener {
    var computerUseGate: ComputerUseExecutionGate?
    var onComputerUse: ((ComputerUseFragment, TrustedDeviceCredential) -> Void)?
    private let controllerLock = NSRecursiveLock()
    func reserveComputerUse(_ credential: TrustedDeviceCredential) -> Bool {
        controllerLock.lock(); defer { controllerLock.unlock() }
        guard let computerUseGate, !computerUseGate.ownsControl else { return false }
        return allowActiveController(credential: credential, sourceHost: nil)
    }

    private struct AuthenticatedPacketWindow {
        var startedAt: Date
        var count: Int
    }

    private let receiver: any DatagramReceiving
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "pocketctrl.input.listener", qos: .userInteractive)
    private let injector: MacInputInjector
    private let credentialStore: TrustedDeviceCredentialStore
    private let sessionRegistry: ActiveViewerSessionRegistry
    private let onFeedback: (ViewerFeedback, TrustedDeviceCredential) -> Void
    private let onZoomRegion: (ViewerZoomRegion) -> Void
    private let onAudioSetting: (ViewerAudioSetting, TrustedDeviceCredential) -> Void
    private let onClipboard: (ClipboardPayload) -> Void
    private let onInputEvent: (RemoteInputEvent) -> Void
    private let onAuthenticatedDevice: (TrustedDeviceCredential, String?) -> Void
    private let onActiveControllerChanged: (TrustedDeviceCredential?, String?) -> Void
    private let inputEnabledLock = NSLock()
    private var inputEnabledStorage: Bool
    private var seenNonces: [String: Date] = [:]
    private var isRunning = true
    private var authenticatedPacketCount = 0
    private var rejectedPacketCount = 0
    private var rejectedPacketsBySource: [String: [Date]] = [:]
    private var globalRejectedPackets: [Date] = []
    private var lastRejectionSummaryAt = Date.distantPast
    private var lastRejectionPruneAt = Date.distantPast
    private var authenticatedPacketWindows: [String: AuthenticatedPacketWindow] = [:]
    private var activeControllerCredentialID: String?
    private var activeControllerLastSeen = Date.distantPast
    private var lastActiveControllerNotificationAt = Date.distantPast
    private var didLogDisabledInput = false
    private var credentialsLoggedWithoutInputPermission = Set<String>()
    private static let maximumControlDatagramBytes = 48 * 1024
    private static let rejectionWindow: TimeInterval = 60
    private static let maximumRejectedPacketsPerSource = 60
    private static let maximumRejectedPacketsGlobally = 300
    private static let authenticatedPacketWindow: TimeInterval = 1
    private static let maximumAuthenticatedPacketsPerCredential = 600
    private static let activeControllerTimeout: TimeInterval = 1.5

    init(
        port: UInt16,
        injector: MacInputInjector,
        credentialStore: TrustedDeviceCredentialStore,
        sessionRegistry: ActiveViewerSessionRegistry,
        onFeedback: @escaping (ViewerFeedback, TrustedDeviceCredential) -> Void = { _, _ in },
        onZoomRegion: @escaping (ViewerZoomRegion) -> Void = { _ in },
        onAudioSetting: @escaping (ViewerAudioSetting, TrustedDeviceCredential) -> Void = { _, _ in },
        onClipboard: @escaping (ClipboardPayload) -> Void = { _ in },
        onInputEvent: @escaping (RemoteInputEvent) -> Void = { _ in },
        onAuthenticatedDevice: @escaping (TrustedDeviceCredential, String?) -> Void = { _, _ in },
        onActiveControllerChanged: @escaping (TrustedDeviceCredential?, String?) -> Void = { _, _ in },
        inputEnabled: Bool = true
    ) throws {
        receiver = try UDPReceiver(port: port)
        self.injector = injector
        self.credentialStore = credentialStore
        self.sessionRegistry = sessionRegistry
        self.onFeedback = onFeedback
        self.onZoomRegion = onZoomRegion
        self.onAudioSetting = onAudioSetting
        self.onClipboard = onClipboard
        self.onInputEvent = onInputEvent
        self.onAuthenticatedDevice = onAuthenticatedDevice
        self.onActiveControllerChanged = onActiveControllerChanged
        self.inputEnabledStorage = inputEnabled
    }

    init(
        receiver: any DatagramReceiving,
        injector: MacInputInjector,
        credentialStore: TrustedDeviceCredentialStore,
        sessionRegistry: ActiveViewerSessionRegistry,
        inputEnabled: Bool = true,
        onFeedback: @escaping (ViewerFeedback, TrustedDeviceCredential) -> Void = { _, _ in },
        onZoomRegion: @escaping (ViewerZoomRegion) -> Void = { _ in },
        onAudioSetting: @escaping (ViewerAudioSetting, TrustedDeviceCredential) -> Void = { _, _ in },
        onClipboard: @escaping (ClipboardPayload) -> Void = { _ in },
        onInputEvent: @escaping (RemoteInputEvent) -> Void = { _ in },
        onAuthenticatedDevice: @escaping (TrustedDeviceCredential, String?) -> Void = { _, _ in },
        onActiveControllerChanged: @escaping (TrustedDeviceCredential?, String?) -> Void = { _, _ in }
    ) {
        self.receiver = receiver
        self.injector = injector
        self.credentialStore = credentialStore
        self.sessionRegistry = sessionRegistry
        self.inputEnabledStorage = inputEnabled
        self.onFeedback = onFeedback
        self.onZoomRegion = onZoomRegion
        self.onAudioSetting = onAudioSetting
        self.onClipboard = onClipboard
        self.onInputEvent = onInputEvent
        self.onAuthenticatedDevice = onAuthenticatedDevice
        self.onActiveControllerChanged = onActiveControllerChanged
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let inputEnabled = self.isInputEnabled
            NSLog("PocketCtrl remote input listener started inputEnabled=\(inputEnabled)")
            PocketCtrlHostDiagnostics.write("remote input listener started inputEnabled=\(inputEnabled)")
            while self.isRunning, let datagram = self.receiver.receiveWithSource(maxSize: Self.maximumControlDatagramBytes + 1) {
                let source = datagram.sourceHost ?? "unknown"
                let claimsKnownCredential = AuthenticatedControlDatagram
                    .claimedCredentialID(in: datagram.data, decoder: self.decoder)
                    .flatMap { self.credentialStore.credential(for: $0) } != nil
                guard !self.isRejectionRateLimited(
                    source: source,
                    bypassGlobalLimit: claimsKnownCredential
                ) else { continue }
                guard datagram.data.count <= Self.maximumControlDatagramBytes else {
                    self.recordRejectedPacket(source: source, bytes: datagram.data.count)
                    continue
                }
                guard let authenticated = AuthenticatedControlDatagram.open(
                    datagram.data,
                    credentialProvider: { self.credentialStore.credential(for: $0) },
                    decoder: self.decoder,
                    seenNonces: &self.seenNonces
                ) else {
                    if self.rejectedPacketCount < 3 {
                        PocketCtrlHostDiagnostics.connection("control.rejected knownCredential=\(claimsKnownCredential) reason=authenticationEnvelopeRejected")
                    }
                    self.recordRejectedPacket(source: source, bytes: datagram.data.count)
                    continue
                }
                guard self.allowAuthenticatedPacket(credentialID: authenticated.credential.record.id) else {
                    continue
                }
                guard let sourceHost = datagram.sourceHost,
                      self.sessionRegistry.register(
                        credential: authenticated.credential,
                        sourceHost: sourceHost
                      ) else {
                    continue
                }
                self.expireActiveControllerIfNeeded()
                self.authenticatedPacketCount += 1
                if self.authenticatedPacketCount == 1 {
                    PocketCtrlHostDiagnostics.connection("control.firstAuthenticated credential=\(PocketCtrlHostDiagnostics.identifierTag(authenticated.credential.record.id))")
                }
                if self.authenticatedPacketCount <= 5 || authenticated.type != .input {
                    NSLog("PocketCtrl authenticated control packet type=\(authenticated.type.rawValue) count=\(self.authenticatedPacketCount)")
                    PocketCtrlHostDiagnostics.write("authenticated control packet type=\(authenticated.type.rawValue) count=\(self.authenticatedPacketCount)")
                }
                self.onAuthenticatedDevice(authenticated.credential, datagram.sourceHost)

                switch authenticated.type {
                case .computerUse:
                    guard let fragment = try? self.decoder.decode(ComputerUseFragment.self, from: authenticated.payload) else { continue }
                    self.onComputerUse?(fragment, authenticated.credential)
                case .feedback:
                    guard let feedback = try? self.decoder.decode(ViewerFeedback.self, from: authenticated.payload) else { continue }
                    self.onFeedback(feedback, authenticated.credential)
                case .zoomRegion:
                    guard self.computerUseGate?.ownsControl != true else { continue }
                    guard self.isInputEnabled,
                          authenticated.credential.record.allowsRemoteInput,
                          self.allowActiveController(credential: authenticated.credential, sourceHost: sourceHost) else { continue }
                    guard let zoomRegion = try? self.decoder.decode(ViewerZoomRegion.self, from: authenticated.payload) else { continue }
                    self.onZoomRegion(zoomRegion)
                case .audioSetting:
                    guard authenticated.credential.record.allowsAudio else { continue }
                    guard let setting = try? self.decoder.decode(ViewerAudioSetting.self, from: authenticated.payload) else { continue }
                    self.onAudioSetting(setting, authenticated.credential)
                case .clipboard:
                    guard self.computerUseGate?.ownsControl != true else { continue }
                    guard authenticated.credential.record.allowsClipboard else { continue }
                    guard self.allowActiveController(credential: authenticated.credential, sourceHost: sourceHost) else { continue }
                    guard let clipboard = try? self.decoder.decode(ClipboardPayload.self, from: authenticated.payload) else { continue }
                    self.onClipboard(clipboard)
                case .input:
                    guard self.computerUseGate?.ownsControl != true else { continue }
                    guard self.isInputEnabled else {
                        if !self.didLogDisabledInput {
                            self.didLogDisabledInput = true
                            PocketCtrlHostDiagnostics.write("authenticated input ignored because host-wide remote input is off")
                        }
                        continue
                    }
                    guard authenticated.credential.record.allowsRemoteInput else {
                        if self.credentialsLoggedWithoutInputPermission.insert(authenticated.credential.record.id).inserted {
                            PocketCtrlHostDiagnostics.write("authenticated input ignored because device was approved without control permission")
                        }
                        continue
                    }
                    guard self.allowActiveController(credential: authenticated.credential, sourceHost: sourceHost) else { continue }
                    guard let event = try? self.decoder.decode(RemoteInputEvent.self, from: authenticated.payload) else { continue }
                    self.onInputEvent(event)
                    self.injector.post(event)
                }
            }
        }
    }

    func stop() {
        NSLog("PocketCtrl remote input listener stopping authenticated=\(authenticatedPacketCount) rejected=\(rejectedPacketCount)")
        isRunning = false
        receiver.stop()
    }

    func setInputEnabled(_ enabled: Bool) {
        inputEnabledLock.lock()
        let changed = inputEnabledStorage != enabled
        inputEnabledStorage = enabled
        inputEnabledLock.unlock()
        guard changed else { return }
        NSLog("PocketCtrl remote input listener inputEnabled changed to \(enabled)")
        PocketCtrlHostDiagnostics.write("remote input listener inputEnabled changed to \(enabled)")
    }

    func disconnect(deviceID: String) {
        controllerLock.lock(); defer { controllerLock.unlock() }
        guard activeControllerCredentialID == deviceID else { return }
        if computerUseGate?.ownsControl != true { injector.releaseActiveInputs() }
        activeControllerCredentialID = nil
        activeControllerLastSeen = .distantPast
        onActiveControllerChanged(nil, nil)
    }

    private var isInputEnabled: Bool {
        inputEnabledLock.lock()
        defer { inputEnabledLock.unlock() }
        return inputEnabledStorage
    }

    private func isRejectionRateLimited(source: String, bypassGlobalLimit: Bool) -> Bool {
        let now = Date()
        pruneRejectedPackets(now: now)
        return (rejectedPacketsBySource[source]?.count ?? 0) >= Self.maximumRejectedPacketsPerSource
            || (!bypassGlobalLimit && globalRejectedPackets.count >= Self.maximumRejectedPacketsGlobally)
    }

    private func allowAuthenticatedPacket(credentialID: String) -> Bool {
        let now = Date()
        var window = authenticatedPacketWindows[credentialID]
            ?? AuthenticatedPacketWindow(startedAt: now, count: 0)
        if now.timeIntervalSince(window.startedAt) >= Self.authenticatedPacketWindow {
            window = AuthenticatedPacketWindow(startedAt: now, count: 0)
        }
        guard window.count < Self.maximumAuthenticatedPacketsPerCredential else {
            authenticatedPacketWindows[credentialID] = window
            return false
        }
        window.count += 1
        authenticatedPacketWindows[credentialID] = window
        return true
    }

    private func allowActiveController(credential: TrustedDeviceCredential, sourceHost: String?) -> Bool {
        controllerLock.lock(); defer { controllerLock.unlock() }
        let now = Date()
        let credentialID = credential.record.id
        guard let activeControllerCredentialID else {
            self.activeControllerCredentialID = credentialID
            activeControllerLastSeen = now
            notifyActiveController(credential, sourceHost: sourceHost, now: now)
            return true
        }
        if activeControllerCredentialID == credentialID {
            activeControllerLastSeen = now
            if now.timeIntervalSince(lastActiveControllerNotificationAt) >= 1 {
                notifyActiveController(credential, sourceHost: sourceHost, now: now)
            }
            return true
        }

        let activeCredentialIsStillAllowed = credentialStore.credential(for: activeControllerCredentialID) != nil
        guard !activeCredentialIsStillAllowed || now.timeIntervalSince(activeControllerLastSeen) >= Self.activeControllerTimeout else {
            return false
        }
        injector.releaseActiveInputs()
        self.activeControllerCredentialID = credentialID
        activeControllerLastSeen = now
        notifyActiveController(credential, sourceHost: sourceHost, now: now)
        PocketCtrlHostDiagnostics.write("active controller changed after disconnect or timeout")
        return true
    }

    private func expireActiveControllerIfNeeded(now: Date = Date()) {
        controllerLock.lock(); defer { controllerLock.unlock() }
        guard computerUseGate?.ownsControl != true else { return }
        guard activeControllerCredentialID != nil,
              now.timeIntervalSince(activeControllerLastSeen) >= Self.activeControllerTimeout else { return }
        injector.releaseActiveInputs()
        activeControllerCredentialID = nil
        activeControllerLastSeen = .distantPast
        lastActiveControllerNotificationAt = now
        onActiveControllerChanged(nil, nil)
    }

    private func notifyActiveController(_ credential: TrustedDeviceCredential, sourceHost: String?, now: Date) {
        lastActiveControllerNotificationAt = now
        onActiveControllerChanged(credential, sourceHost)
    }

    private func recordRejectedPacket(source: String, bytes: Int) {
        let now = Date()
        pruneRejectedPackets(now: now)
        rejectedPacketCount += 1
        rejectedPacketsBySource[source, default: []].append(now)
        globalRejectedPackets.append(now)

        guard rejectedPacketCount <= 3 || now.timeIntervalSince(lastRejectionSummaryAt) >= Self.rejectionWindow else {
            return
        }
        lastRejectionSummaryAt = now
        let message = "rejected unauthenticated control packets total=\(rejectedPacketCount) recent=\(globalRejectedPackets.count) source=\(source) bytes=\(bytes)"
        NSLog("PocketCtrl \(message)")
        PocketCtrlHostDiagnostics.write(message)
    }

    private func pruneRejectedPackets(now: Date) {
        guard now.timeIntervalSince(lastRejectionPruneAt) >= 1 else { return }
        lastRejectionPruneAt = now
        globalRejectedPackets.removeAll { now.timeIntervalSince($0) >= Self.rejectionWindow }
        rejectedPacketsBySource = rejectedPacketsBySource.compactMapValues { attempts in
            let recent = attempts.filter { now.timeIntervalSince($0) < Self.rejectionWindow }
            return recent.isEmpty ? nil : recent
        }
    }
}

// All mutable input state is confined to queue; the gate serializes ownership.
final class MacInputInjector: @unchecked Sendable {
    private struct TransferredEvent: @unchecked Sendable { let value: CGEvent }
    private let eventPoster: (CGEvent) -> Void
    var computerUseGate: ComputerUseExecutionGate?

    func postComputerEvent(_ event: CGEvent, token: UInt64) async throws {
        let transferred = TransferredEvent(value: event)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, let gate = self.computerUseGate else { continuation.resume(throwing: CancellationError()); return }
                let posted = gate.perform(token) {
                    let event = transferred.value
                    switch event.type {
                    case .leftMouseDown: self.activeMouseButton = .left
                    case .rightMouseDown: self.activeMouseButton = .right
                    case .otherMouseDown: self.activeMouseButton = .center
                    case .leftMouseUp, .rightMouseUp, .otherMouseUp: self.activeMouseButton = nil
                    case .keyDown: self.activeKeyCodes.insert(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
                    case .keyUp: self.activeKeyCodes.remove(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
                    case .flagsChanged:
                        // Quartz creates flagsChanged, rather than keyDown/keyUp, for modifier keys.
                        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                        let mask: CGEventFlags
                        switch code {
                        case 54, 55: mask = .maskCommand
                        case 56, 60: mask = .maskShift
                        case 58, 61: mask = .maskAlternate
                        case 59, 62: mask = .maskControl
                        default: mask = []
                        }
                        if !mask.isEmpty && event.flags.contains(mask) { self.activeKeyCodes.insert(code) }
                        else { self.activeKeyCodes.remove(code) }
                    default: break
                    }
                    self.eventPoster(event)
                }
                if posted { continuation.resume() } else { continuation.resume(throwing: CancellationError()) }
            }
        }
    }

    func emergencyReleaseInputs() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.emergencyReleaseNow()
                continuation.resume()
            }
        }
    }

    /// Only called by the main-thread application-termination handler.
    func emergencyReleaseInputsBeforeExit() {
        queue.sync { emergencyReleaseNow() }
    }

    private func emergencyReleaseNow() {
        pendingPointerFlush?.cancel(); pendingPointerFlush = nil; pendingPointerMove = nil
        if let button = activeMouseButton {
            postMouse(type: mouseUpType(for: button), input: .currentPointerButton(.mouseUp, button: button), button: button)
            activeMouseButton = nil
        }
        for code in activeKeyCodes { postKey(.key(.keyUp, keyCode: code, modifiers: []), isDown: false) }
        activeKeyCodes.removeAll()
    }

    private static let pointerFlushInterval: DispatchTimeInterval = .milliseconds(4)
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let displayIDProvider: () -> CGDirectDisplayID
    private let queue = DispatchQueue(label: "pocketctrl.input.injector", qos: .userInteractive)
    private var normalizedInputRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var activeMouseButton: RemoteMouseButton?
    private var activeKeyCodes = Set<UInt16>()
    private var pendingPointerMove: RemoteInputEvent?
    private var pendingPointerFlush: DispatchWorkItem?
    private var debugPostedInputCount = 0
    private var debugInjectedPointerCount = 0

    init(displayIDProvider: @escaping () -> CGDirectDisplayID,
         eventPoster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.displayIDProvider = displayIDProvider
        self.eventPoster = eventPoster
    }

    func requestAccessibilityTrust() {
        MacPermissions.requestAccessibilityPrompt()
    }

    func updateInputRegion(_ region: CGRect?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.normalizedInputRegion = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            self.logInjectorDebug("input region updated region=\(RemoteInputDebugLog.rect(self.normalizedInputRegion))")
        }
    }

    func post(_ input: RemoteInputEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            self.debugPostedInputCount += 1
            if self.shouldLogInjectorEvent(input) {
                self.logInjectorDebug("received index=\(self.debugPostedInputCount) \(RemoteInputDebugLog.event(input)) current=\(RemoteInputDebugLog.point(self.currentMouseLocation())) pending=\(self.pendingPointerMove.map(RemoteInputDebugLog.event) ?? "nil")")
            }
            switch input.kind {
            case .mouseMove, .mouseMoveRelative, .mouseMoveRelativeNormalized:
                self.enqueuePointerMove(input)
            default:
                self.logInjectorDebug("non-move event flushing pending before postNow kind=\(input.kind.rawValue)")
                self.flushPendingPointerMove()
                self.postNow(input)
            }
        }
    }

    func releaseActiveInputs() {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingPointerMove()
            if let button = self.activeMouseButton {
                let input = RemoteInputEvent.currentPointerButton(.mouseUp, button: button)
                self.postMouse(type: self.mouseUpType(for: button), input: input)
                self.activeMouseButton = nil
            }
            for keyCode in self.activeKeyCodes {
                self.postKey(RemoteInputEvent.key(.keyUp, keyCode: keyCode, modifiers: []), isDown: false)
            }
            self.activeKeyCodes.removeAll()
        }
    }

    private func enqueuePointerMove(_ input: RemoteInputEvent) {
        if let pendingPointerMove {
            if pendingPointerMove.kind == input.kind, input.kind.isRelativeMouseMove {
                self.pendingPointerMove = input.kind == .mouseMoveRelativeNormalized
                    ? RemoteInputEvent.normalizedRelativePointer(
                        deltaX: Self.clampedRelativeDelta(pendingPointerMove.deltaX + input.deltaX),
                        deltaY: Self.clampedRelativeDelta(pendingPointerMove.deltaY + input.deltaY),
                        button: input.button
                    )
                    : RemoteInputEvent.relativePointer(
                        deltaX: Self.clampedRelativeDelta(pendingPointerMove.deltaX + input.deltaX),
                        deltaY: Self.clampedRelativeDelta(pendingPointerMove.deltaY + input.deltaY),
                        button: input.button
                    )
                if shouldLogInjectorEvent(input) {
                    logInjectorDebug("coalesced relative pending old=\(RemoteInputDebugLog.event(pendingPointerMove)) incoming=\(RemoteInputDebugLog.event(input)) new=\(RemoteInputDebugLog.event(self.pendingPointerMove ?? input))")
                }
                return
            }

            if pendingPointerMove.kind != input.kind {
                logInjectorDebug("move kind switch pending=\(pendingPointerMove.kind.rawValue) incoming=\(input.kind.rawValue); flushing pending first")
                flushPendingPointerMove()
            }
        }

        pendingPointerMove = input
        if shouldLogInjectorEvent(input) {
            logInjectorDebug("pending move set \(RemoteInputDebugLog.event(input))")
        }

        guard pendingPointerFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPointerFlush = nil
            self.flushPendingPointerMove()
        }
        pendingPointerFlush = work
        queue.asyncAfter(deadline: .now() + Self.pointerFlushInterval, execute: work)
    }

    private func flushPendingPointerMove() {
        pendingPointerFlush?.cancel()
        pendingPointerFlush = nil
        guard let input = pendingPointerMove else { return }
        pendingPointerMove = nil
        logInjectorDebug("flush pending move \(RemoteInputDebugLog.event(input)) currentBefore=\(RemoteInputDebugLog.point(currentMouseLocation()))")
        postNow(input)
    }

    private func postNow(_ input: RemoteInputEvent) {
        if let gate = computerUseGate { gate.performManual { self.postManualNow(input) } }
        else { postManualNow(input) }
    }

    private func postManualNow(_ input: RemoteInputEvent) {
        switch input.kind {
        case .mouseMove:
            if let activeMouseButton {
                postMouse(type: mouseDraggedType(for: activeMouseButton), input: input, button: activeMouseButton)
            } else {
                postMouse(type: .mouseMoved, input: input)
            }
        case .mouseMoveRelative:
            postRelativeMouse(input)
        case .mouseMoveRelativeNormalized:
            postNormalizedRelativeMouse(input)
        case .mouseDown:
            activeMouseButton = input.button
            postMouse(type: mouseDownType(for: input.button), input: input)
        case .mouseUp:
            postMouse(type: mouseUpType(for: input.button), input: input)
            if activeMouseButton == input.button {
                activeMouseButton = nil
            }
        case .scroll:
            postScroll(input)
        case .keyDown:
            activeKeyCodes.insert(input.keyCode)
            postKey(input, isDown: true)
        case .keyUp:
            activeKeyCodes.remove(input.keyCode)
            postKey(input, isDown: false)
        }
    }

    private func postMouse(type: CGEventType, input: RemoteInputEvent, button: RemoteMouseButton? = nil) {
        let point = input.usesCurrentMouseLocation
            ? currentMouseLocation()
            : pointForNormalizedPosition(x: input.x, y: input.y)
        debugInjectedPointerCount += 1
        if shouldLogInjectorEvent(input) {
            logInjectorDebug("postMouse index=\(debugInjectedPointerCount) cgType=\(type.rawValue) point=\(RemoteInputDebugLog.point(point)) usesCurrent=\(input.usesCurrentMouseLocation) bounds=\(RemoteInputDebugLog.rect(CGDisplayBounds(displayIDProvider()))) region=\(RemoteInputDebugLog.rect(normalizedInputRegion)) \(RemoteInputDebugLog.event(input))")
        }
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: (button ?? input.button).cgButton) else {
            logInjectorDebug("postMouse failed to create CGEvent \(RemoteInputDebugLog.event(input))")
            return
        }
        event.flags = CGEventFlags(rawValue: input.modifiers)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(input.normalizedClickCount))
        self.eventPoster(event)
    }

    private func postNormalizedRelativeMouse(_ input: RemoteInputEvent) {
        let bounds = CGDisplayBounds(displayIDProvider())
        let deltaX = Self.clampedRelativeDelta(input.deltaX * bounds.width * normalizedInputRegion.width)
        let deltaY = Self.clampedRelativeDelta(input.deltaY * bounds.height * normalizedInputRegion.height)
        logInjectorDebug("normalized relative converted inputDelta=(\(RemoteInputDebugLog.number(input.deltaX)),\(RemoteInputDebugLog.number(input.deltaY))) pixelDelta=(\(RemoteInputDebugLog.number(deltaX)),\(RemoteInputDebugLog.number(deltaY))) bounds=\(RemoteInputDebugLog.rect(bounds)) region=\(RemoteInputDebugLog.rect(normalizedInputRegion))")
        postRelativeMouse(RemoteInputEvent.relativePointer(deltaX: deltaX, deltaY: deltaY, button: input.button))
    }

    private func postRelativeMouse(_ input: RemoteInputEvent) {
        let deltaX = Self.clampedRelativeDelta(input.deltaX)
        let deltaY = Self.clampedRelativeDelta(input.deltaY)
        guard deltaX != 0 || deltaY != 0 else { return }

        let current = currentMouseLocation()
        let bounds = CGDisplayBounds(displayIDProvider())
        let nextPoint = CGPoint(
            x: min(max(current.x + deltaX, bounds.minX), bounds.maxX - 1),
            y: min(max(current.y + deltaY, bounds.minY), bounds.maxY - 1)
        )
        debugInjectedPointerCount += 1
        if shouldLogInjectorEvent(input) {
            logInjectorDebug("postRelativeMouse index=\(debugInjectedPointerCount) delta=(\(RemoteInputDebugLog.number(deltaX)),\(RemoteInputDebugLog.number(deltaY))) current=\(RemoteInputDebugLog.point(current)) next=\(RemoteInputDebugLog.point(nextPoint)) bounds=\(RemoteInputDebugLog.rect(bounds)) activeButton=\(activeMouseButton?.rawValue.description ?? "nil") \(RemoteInputDebugLog.event(input))")
        }
        let button = activeMouseButton ?? input.button
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: activeMouseButton.map(mouseDraggedType(for:)) ?? .mouseMoved,
            mouseCursorPosition: nextPoint,
            mouseButton: button.cgButton
        ) else {
            logInjectorDebug("postRelativeMouse failed to create CGEvent \(RemoteInputDebugLog.event(input))")
            return
        }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY.rounded()))
        event.flags = CGEventFlags(rawValue: input.modifiers)
        self.eventPoster(event)
    }

    private func shouldLogInjectorEvent(_ event: RemoteInputEvent) -> Bool {
        if !event.kind.isRelativeMouseMove { return true }
        return debugPostedInputCount <= 120 || max(abs(event.deltaX), abs(event.deltaY)) > 120
    }

    private func logInjectorDebug(_ message: String) {
        RemoteInputDebugLog.write("injector \(message)")
    }

    private func postScroll(_ input: RemoteInputEvent) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(input.deltaY),
            wheel2: Int32(input.deltaX),
            wheel3: 0
        ) else {
            return
        }
        self.eventPoster(event)
    }

    private func postKey(_ input: RemoteInputEvent, isDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: input.keyCode, keyDown: isDown) else {
            return
        }
        event.flags = CGEventFlags(rawValue: input.modifiers)
        self.eventPoster(event)
    }

    private func pointForNormalizedPosition(x: Double, y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayIDProvider())
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        let regionX = normalizedInputRegion.minX + normalizedInputRegion.width * clampedX
        let regionY = normalizedInputRegion.minY + normalizedInputRegion.height * clampedY
        return CGPoint(
            x: bounds.minX + bounds.width * regionX,
            y: bounds.minY + bounds.height * regionY
        )
    }

    private func currentMouseLocation() -> CGPoint {
        CGEvent(source: eventSource)?.location ?? {
            let bounds = CGDisplayBounds(displayIDProvider())
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }()
    }

    private static func clampedRelativeDelta(_ delta: Double) -> Double {
        min(max(delta, -10_000), 10_000)
    }

    private func mouseDownType(for button: RemoteMouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .center: return .otherMouseDown
        }
    }

    private func mouseUpType(for button: RemoteMouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .center: return .otherMouseUp
        }
    }

    private func mouseDraggedType(for button: RemoteMouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .center: return .otherMouseDragged
        }
    }
}

private extension RemoteInputEvent {
    var normalizedClickCount: Int {
        min(max(clickCount ?? 1, 1), 3)
    }

    var usesCurrentMouseLocation: Bool {
        x < 0 || y < 0
    }
}

private extension RemoteInputKind {
    var isRelativeMouseMove: Bool {
        self == .mouseMoveRelative || self == .mouseMoveRelativeNormalized
    }
}

extension NSEvent.ModifierFlags {
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.capsLock) { flags.insert(.maskAlphaShift) }
        return flags
    }
}
