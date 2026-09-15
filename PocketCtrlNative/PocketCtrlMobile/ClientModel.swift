// SPDX-License-Identifier: MPL-2.0

import Combine
import CoreGraphics
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import Network
import OSLog
import UIKit

enum ClientDiagnostics {
    private static let connectionLogger = Logger(subsystem: "PocketCtrlMobile", category: "ConnectionDebug")

    // Only for random, non-secret host/credential IDs. Never pass a secret,
    // pairing code, MAC/IP address, device name, or pairing URL here.
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

    static var logURL: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory
            .appendingPathComponent("PocketCtrl", isDirectory: true)
            .appendingPathComponent("client-diagnostics.log")
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
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(resourceValues)

            if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let size = attributes[.size] as? NSNumber,
               size.uint64Value >= maximumLogBytes {
                try FileManager.default.removeItem(at: logURL)
            }

            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try data.write(to: logURL, options: [.atomic, .completeFileProtection])
            }
        } catch {
            Logger(subsystem: "PocketCtrlMobile", category: "Diagnostics")
                .error("Diagnostic log write failed: \(error.localizedDescription, privacy: .private)")
        }
        #endif
    }
}

enum ClientRemoteInputKind: String, Codable {
    case mouseMove
    case mouseDown
    case mouseUp
    case scroll
    case keyDown
    case keyUp
}

enum ClientRemoteMouseButton: Int, Codable {
    case left = 0
    case right = 1
    case center = 2
}

struct ClientRemoteInputEvent: Codable {
    let kind: ClientRemoteInputKind
    let x: Double
    let y: Double
    let button: ClientRemoteMouseButton
    let deltaX: Double
    let deltaY: Double
    let keyCode: UInt16
    let modifiers: UInt64
    let clickCount: Int?

    static func pointer(_ kind: ClientRemoteInputKind, x: Double, y: Double, button: ClientRemoteMouseButton, clickCount: Int = 1) -> ClientRemoteInputEvent {
        ClientRemoteInputEvent(kind: kind, x: x, y: y, button: button, deltaX: 0, deltaY: 0, keyCode: 0, modifiers: 0, clickCount: clickCount)
    }

    static func key(_ kind: ClientRemoteInputKind, keyCode: UInt16, modifiers: UInt64 = 0) -> ClientRemoteInputEvent {
        ClientRemoteInputEvent(kind: kind, x: 0, y: 0, button: .left, deltaX: 0, deltaY: 0, keyCode: keyCode, modifiers: modifiers, clickCount: nil)
    }

    static func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) -> ClientRemoteInputEvent {
        ClientRemoteInputEvent(kind: .scroll, x: x, y: y, button: .left, deltaX: deltaX, deltaY: deltaY, keyCode: 0, modifiers: 0, clickCount: nil)
    }
}

struct ClientZoomRegion: Codable {
    let enabled: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ClientAudioSetting: Codable {
    let enabled: Bool
}

enum ClientStreamQualityProfile: String, Codable, CaseIterable, Identifiable {
    case dataSaver
    case balanced
    case smooth
    case max
    case custom

    var id: String { rawValue }

    /// Legacy presets retained for saved-setting migration and wire compatibility.
    static let presets: [ClientStreamQualityProfile] = [.dataSaver, .balanced, .smooth, .max]

    var title: String {
        switch self {
        case .dataSaver: return "Saver"
        case .balanced: return "Balanced"
        case .smooth: return "Smooth"
        case .max: return "Max"
        case .custom: return "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .dataSaver:
            return "Lowest data use for cellular."
        case .balanced:
            return "Lower data with clear screen detail."
        case .smooth:
            return "Highest frame rate for motion, moderate detail."
        case .max:
            return "Best picture. The app can still back off if needed."
        case .custom:
            return "Your own detail and frame rate."
        }
    }

    var settings: ClientStreamSettings {
        switch self {
        case .dataSaver: return ClientStreamSettings(detail: .reduced, frameRate: 20)
        case .balanced, .custom: return ClientStreamSettings(detail: .standard, frameRate: 30)
        case .smooth: return ClientStreamSettings(detail: .standard, frameRate: 60)
        case .max: return ClientStreamSettings(detail: .full, frameRate: 60)
        }
    }
}

/// Screen detail: the capture width cap and the bitrate budget at 30 fps.
enum ClientStreamDetailLevel: Int, CaseIterable, Identifiable {
    case low = 1
    case reduced
    case standard
    case high
    case full

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .reduced: return "Reduced"
        case .standard: return "Standard"
        case .high: return "High"
        case .full: return "Full"
        }
    }

    /// "Full" leaves resolution to the host, within the protocol's safety cap.
    var maximumCaptureWidth: Int {
        switch self {
        case .low: return 992
        case .reduced: return 1_280
        case .standard: return 1_600
        case .high: return 1_920
        case .full: return 16_384
        }
    }

    var widthDescription: String {
        self == .full ? "Mac's capture limit" : "up to \(maximumCaptureWidth) px"
    }

    /// Bitrate budget at 30 fps. The frame-rate factor scales it.
    var baseBitrate: Int {
        switch self {
        case .low: return 1_708_000
        case .reduced: return 2_500_000
        case .standard: return 6_000_000
        case .high: return 8_000_000
        case .full: return 20_000_000
        }
    }
}

struct ClientStreamSettings: Equatable {
    static let frameRateRange = 3.0...60.0
    private static let profileKey = "PocketCtrlMobile.streamQualityProfile"
    private static let detailKey = "PocketCtrlMobile.streamDetailLevel"
    private static let detailAmountKey = "PocketCtrlMobile.streamDetailAmount"
    private static let frameRateKey = "PocketCtrlMobile.streamFrameRate"

    var detailAmount: Double
    var frameRate: Double

    init(detailAmount: Double, frameRate: Double) {
        self.detailAmount = Self.clamp(detailAmount, to: 0...1, fallback: 0.5)
        self.frameRate = Self.clamp(frameRate, to: Self.frameRateRange, fallback: 30)
    }

    init(detail: ClientStreamDetailLevel, frameRate: Double) {
        self.init(detailAmount: Double(detail.rawValue - 1) / 4, frameRate: frameRate)
    }

    // Compatibility with preset-based callers; the sliders never snap to this.
    var detail: ClientStreamDetailLevel {
        get { ClientStreamDetailLevel(rawValue: Int((normalizedDetail * 4).rounded()) + 1) ?? .standard }
        set { detailAmount = Double(newValue.rawValue - 1) / 4 }
    }

    private var normalizedDetail: Double { Self.clamp(detailAmount, to: 0...1, fallback: 0.5) }
    private var normalizedFPS: Double { (Self.clamp(frameRate, to: Self.frameRateRange, fallback: 30) - Self.frameRateRange.lowerBound) / (Self.frameRateRange.upperBound - Self.frameRateRange.lowerBound) }
    var maximumFrameRate: Int { Int(Self.clamp(frameRate, to: Self.frameRateRange, fallback: 30).rounded()) }
    var maximumCaptureWidth: Int {
        let width = Self.interpolate(normalizedDetail * 4, points: [0, 1, 2, 3, 4], values: [992, 1280, 1600, 1920, 16384])
        return Int(width.rounded()) / 2 * 2
    }

    var qualityTitle: String {
        let detail = normalizedDetail
        let fps = normalizedFPS
        if detail >= 0.9 && fps >= 0.9 { return "Max" }
        if fps - detail >= 0.2 { return "Smooth" }
        if detail - fps >= 0.2 { return "Sharp" }
        if (detail + fps) / 2 < 1.0 / 3 { return "Saver" }
        return "Balanced"
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private static func interpolate(_ value: Double, points: [Double], values: [Double]) -> Double {
        if value <= points[0] { return values[0] }
        for index in 1..<points.count where value <= points[index] {
            let fraction = (value - points[index - 1]) / (points[index] - points[index - 1])
            return values[index - 1] + (values[index] - values[index - 1]) * fraction
        }
        return values.last!
    }

    static func load(from defaults: UserDefaults) -> Self {
        let preset = defaults.string(forKey: profileKey).flatMap(ClientStreamQualityProfile.init(rawValue:)) ?? .balanced
        let savedDetail = defaults.object(forKey: detailKey) as? Int
        let savedRate = defaults.object(forKey: frameRateKey) as? Double
        let savedAmount = defaults.object(forKey: detailAmountKey) as? Double
        let legacyDetail = savedDetail.flatMap(ClientStreamDetailLevel.init(rawValue:)) ?? preset.settings.detail
        return Self(
            detailAmount: savedAmount ?? Double(legacyDetail.rawValue - 1) / 4,
            frameRate: savedRate.flatMap { frameRateRange.contains($0) ? $0 : nil } ?? preset.settings.frameRate
        )
    }

    func save(to defaults: UserDefaults) {
        // Save the whole selection, even if only one slider changed. This also
        // migrates preset-only installs without losing the untouched slider.
        defaults.set(detail.rawValue, forKey: Self.detailKey)
        defaults.set(normalizedDetail, forKey: Self.detailAmountKey)
        defaults.set(frameRate, forKey: Self.frameRateKey)
        defaults.set(matchingPreset.rawValue, forKey: Self.profileKey)
    }

    /// More frames need more bits for the same per-frame quality, so the
    /// budget grows with frame rate. 30 fps is the reference point.
    var maximumBitrate: Int {
        let base = Self.interpolate(normalizedDetail * 4, points: [0, 1, 2, 3, 4], values: [1_708_000, 2_500_000, 6_000_000, 8_000_000, 20_000_000])
        let factor = Self.interpolate(Self.clamp(frameRate, to: Self.frameRateRange, fallback: 30), points: [3, 5, 10, 15, 20, 30, 45, 60], values: [0.2, 1.0 / 3, 0.5, 0.7, 0.8, 1.0, 1.25, 1.5])
        return Int((base * factor).rounded())
    }

    /// The preset these sliders correspond to, if any.
    var matchingPreset: ClientStreamQualityProfile {
        ClientStreamQualityProfile.presets.first { $0.settings == self } ?? .custom
    }

    /// Nominal video budget, excluding audio and transport overhead.
    /// Static screens can use less; encoder peaks can use more.
    var estimatedMegabytesPerMinute: Double {
        Double(maximumBitrate) / 8 / 1_000_000 * 60
    }

    var estimatedUsageDescription: String {
        Self.usageDescription(megabitsPerSecond: Double(maximumBitrate) / 1_000_000)
    }

    static func usageDescription(megabitsPerSecond: Double) -> String {
        let perMinute = megabytesPerMinute(megabitsPerSecond: max(0, megabitsPerSecond))
        let perHour = perMinute * 60 / 1_000
        // Keep small budgets visible instead of rounding them to zero.
        let minuteText = perMinute > 0 && perMinute < 1
            ? String(format: "%.2f", perMinute)
            : String(Int(perMinute.rounded()))
        let hourText = String(format: perHour > 0 && perHour < 0.1 ? "%.3f" : "%.1f", perHour)
        return "\(minuteText) MB/min · \(hourText) GB/hr"
    }

    static func megabytesPerMinute(megabitsPerSecond: Double) -> Double {
        megabitsPerSecond / 8 * 60
    }
}

struct ClientViewerFeedback: Codable {
    let fps: Int
    let videoWidth: Int
    let videoHeight: Int
    let receivedChunks: Int
    let completedFrames: Int
    let skippedFrames: Int
    let estimatedLossPercent: Double
    let keyframeRequested: Bool
    let qualityProfile: ClientStreamQualityProfile
    // Explicit caps from the Detail and Frame rate sliders. The Mac honors
    // these directly; the profile is informational for older hosts.
    var maximumFrameRate: Int? = nil
    var maximumBitrate: Int? = nil
    var maximumCaptureWidth: Int? = nil
}

enum ClientControlPayloadType: String, Codable {
    case input
    case feedback
    case zoomRegion
    case audioSetting
}

struct ClientAuthenticatedControlEnvelope: Codable {
    let version: Int
    let credentialID: String
    let type: ClientControlPayloadType
    let timestamp: TimeInterval
    let nonce: String
    let sealedPayload: Data
}

enum ClientAuthenticatedControlDatagram {
    static let currentVersion = 1

    static func seal<T: Encodable>(
        _ value: T,
        type: ClientControlPayloadType,
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
        let metadata = authenticationMetadata(credentialID: credentialID, type: type, timestamp: timestamp, nonce: nonce)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data(credentialID.utf8),
            info: Data("PocketCtrl encrypted control v2".utf8),
            outputByteCount: 32
        )
        guard let sealed = try? ChaChaPoly.seal(payload, using: key, authenticating: metadata) else { return nil }
        let envelope = ClientAuthenticatedControlEnvelope(
            version: currentVersion,
            credentialID: credentialID,
            type: type,
            timestamp: timestamp,
            nonce: nonce,
            sealedPayload: sealed.combined
        )
        return try? encoder.encode(envelope)
    }

    private static func authenticationMetadata(
        credentialID: String,
        type: ClientControlPayloadType,
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
}

struct ClientSavedMac: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var localHostAddress: String
    var tailscaleHostAddress: String
    var videoPort: String
    var audioPort: String
    var inputPort: String
    var wakeMACAddress: String
    var credentialID: String
    var allowsRemoteInput: Bool
    var allowsClipboard: Bool
    var allowsAudio: Bool
    var lastConnectedAt: Date

    var routeSummary: String {
        if !tailscaleHostAddress.isEmpty {
            return tailscaleHostAddress
        }
        if !localHostAddress.isEmpty {
            return localHostAddress
        }
        return "Paired Mac"
    }
}

enum ClientPairingQRCodeResult: Equatable {
    case credentialApplied
    case approvalRequested
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

@MainActor
final class ClientModel: ObservableObject {
    private static let routeLogger = Logger(subsystem: "PocketCtrlMobile", category: "Route")
    private static let videoLogger = Logger(subsystem: "PocketCtrlMobile", category: "Video")
    private static let connectionLogger = Logger(subsystem: "PocketCtrlMobile", category: "Connection")
    private struct IPInterfaceAddress {
        let name: String
        let address: String
        let netmask: String?
    }

    @Published var hostAddress = "127.0.0.1" {
        didSet {
            UserDefaults.standard.set(hostAddress, forKey: Self.hostAddressKey)
        }
    }
    @Published var localHostAddress = "" {
        didSet {
            UserDefaults.standard.set(localHostAddress, forKey: Self.localHostAddressKey)
        }
    }
    @Published var tailscaleHostAddress = "" {
        didSet {
            UserDefaults.standard.set(tailscaleHostAddress, forKey: Self.tailscaleHostAddressKey)
        }
    }
    @Published var videoPort = "5555" {
        didSet {
            UserDefaults.standard.set(videoPort, forKey: Self.videoPortKey)
        }
    }
    @Published var audioPort = "5557" {
        didSet {
            UserDefaults.standard.set(audioPort, forKey: Self.audioPortKey)
        }
    }
    @Published var inputPort = "5556" {
        didSet {
            UserDefaults.standard.set(inputPort, forKey: Self.inputPortKey)
        }
    }
    @Published var pairingCode = ""
    @Published var credentialID = ""
    @Published private(set) var credentialAllowsInput = false
    @Published private(set) var credentialAllowsClipboard = false
    @Published private(set) var credentialAllowsAudio = false
    @Published var pairedHostID = "" {
        didSet {
            UserDefaults.standard.set(pairedHostID, forKey: Self.pairedHostIDKey)
        }
    }
    @Published var wakeMACAddress = "" {
        didSet {
            UserDefaults.standard.set(wakeMACAddress, forKey: Self.wakeMACAddressKey)
        }
    }
    @Published var wakeBroadcastAddress = "255.255.255.255" {
        didSet {
            UserDefaults.standard.set(wakeBroadcastAddress, forKey: Self.wakeBroadcastAddressKey)
        }
    }
    @Published var wakePort = "9" {
        didSet {
            UserDefaults.standard.set(wakePort, forKey: Self.wakePortKey)
        }
    }
    @Published var wakeStatus = "Ready"
    @Published var status = "Enter your Mac host settings, then connect."
    @Published var lastEvent = "No input sent"
    @Published var isConnected = false
    @Published var isConnectionAttemptInProgress = false
    @Published var isAutomaticReconnectInProgress = false
    @Published private(set) var hasDisplayedVideoFrame = false
    @Published var videoStatus = "No video yet"
    @Published var audioStatus = "Audio off"
    @Published var audioEnabled = false {
        didSet {
            guard !isUpdatingAudioEnabledInternally else { return }
            guard audioEnabled != oldValue else { return }
            setRemoteAudioEnabled(audioEnabled)
            audioEnabled ? startAudioIfPossible() : stopAudio()
        }
    }
    @Published private(set) var streamQualityProfile: ClientStreamQualityProfile = .balanced
    @Published var streamDetailAmount = 0.5 {
        didSet {
            guard streamDetailAmount != oldValue else { return }
            handleStreamSettingsChange(reason: "detail changed")
        }
    }
    @Published var streamFrameRate = 30.0 {
        didSet {
            guard streamFrameRate != oldValue else { return }
            handleStreamSettingsChange(reason: "frame rate changed")
        }
    }
    /// Latest measured video bitrate from the Mac, for the live usage readout.
    @Published private(set) var latestReceivedMbps = 0.0
    @Published var autoZoomFocusedWindow = false {
        didSet {
            UserDefaults.standard.set(autoZoomFocusedWindow, forKey: Self.autoZoomFocusedWindowKey)
            if autoZoomFocusedWindow {
                focusedWindowZoomRevision &+= 1
            }
        }
    }
    @Published var showRemotePointer = true {
        didSet {
            UserDefaults.standard.set(showRemotePointer, forKey: Self.showRemotePointerKey)
        }
    }
    @Published var remoteVideoSize = CGSize(width: 16, height: 9)
    @Published var deviceAddress = "Unknown IP"
    @Published var routeStatus = "Route: automatic"
    @Published var routeDiagnostic = "No route decision yet"
    @Published var localDiscoveryStatus = "Local discovery waiting for pairing."
    @Published private(set) var isConnectingOverLocalWiFi = false
    @Published private(set) var localWiFiSearchFailed = false
    /// iOS reported that PocketCtrl's Local Network permission is denied.
    /// Cleared as soon as a Bonjour search finds any service again.
    @Published private(set) var localNetworkAccessDenied = false
    private var localWiFiSearchTask: Task<Void, Never>?
    private var discoveredLocalWiFiHost: String?
    @Published var manualPairingStatus = "Enter the code shown on the Mac."
    @Published private(set) var isPairingRequestInProgress = false
    @Published var viewerDeviceName: String {
        didSet {
            UserDefaults.standard.set(Self.sanitizedViewerDeviceName(viewerDeviceName) ?? "", forKey: Self.viewerDeviceNameKey)
        }
    }
    @Published private(set) var hasCompletedViewerDeviceNameOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedViewerDeviceNameOnboarding, forKey: Self.viewerDeviceNameOnboardingCompletedKey)
        }
    }
    @Published private(set) var pointerPosition = CGPoint(x: 0.5, y: 0.5)
    @Published var inputTargetStatus = "Input target not detected"
    @Published var isRegionZoomActive = false
    @Published private(set) var focusedWindowRegion: CGRect?
    @Published private(set) var focusedWindowZoomRevision = 0
    @Published private(set) var isFocusedWindowAutoZoomSuspended = false
    @Published private(set) var scrollRailLineBrightness = 0.28
    @Published private(set) var savedMacs: [ClientSavedMac] = []
    @Published private(set) var pendingNewSavedMacID: String?
    private var currentCredentialIsPersistent = false
    private var savedCredentialReadNeedsRetry = false

    private var sender: ClientInputSender?
    private var videoReceiver: ClientVideoReceiver?
    private var audioReceiver: ClientAudioReceiver?
    private let localDiscoveryBrowser = ClientLocalDiscoveryBrowser()
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "pocketctrl.mobile.network.monitor", qos: .utility)
    private var isUpdatingAudioEnabledInternally = false
    private weak var renderView: ClientPixelBufferRenderView?
    private var latestVideoPixelBuffer: CVPixelBuffer?
    private var scrollRailSamplePoint: CGPoint?
    private var lastScrollRailSampleAt = Date.distantPast
    private var activeInputPort: UInt16?
    private var activeInputHost = ""
    private var shouldRefreshInputSenderBeforeNextInput = false
    private var routeOverrideHost: String?
    private var activeZoomRegion: CGRect?
    private var activeMouseButtons: Set<ClientRemoteMouseButton> = []
    private var suppressedFocusedWindowZoomNeedsRefresh = false
    private var shouldSuppressNextFocusedWindowZoomAfterReconnect = false
    private var hasAttemptedAutoReconnect = false
    private var shouldReconnectCurrentSession = false
    private var initialNoVideoReconnectCount = 0
    private var pairingApplicationFailureMessage: String?
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var initialRouteRefreshTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var streamPreferenceSendTask: Task<Void, Never>?
    // Periodic stats and recovery packets use the settled settings too, so
    // they cannot bypass the slider debounce and repeatedly restart capture.
    private var advertisedStreamSettings = ClientStreamQualityProfile.balanced.settings
    private var manualPairingTask: Task<Void, Never>?
    // Identifies the newest pairing attempt. A cancelled attempt's callbacks
    // must never reset the state of the attempt that replaced it.
    private var manualPairingAttemptID = UUID()
    private var manualPairingDiscoveryActive = false
    private var manualPairingDiscoveredHosts: [String: ClientDiscoveredHost] = [:]
    private var textTypingQueue: [ClientTextTyper.Stroke] = []
    private var textTypingTask: Task<Void, Never>?
    private var latestPointerPosition = CGPoint(x: 0.5, y: 0.5)
    private var pointerPublishWork: DispatchWorkItem?
    private var connectionStartedAt = Date.distantPast
    private var lastResumeHandledAt = Date.distantPast
    private var lastNetworkPathHandledAt = Date.distantPast
    private var hasObservedInitialNetworkPath = false
    private var lastObservedNetworkInterfaces = "unknown"
    private var isAppForeground = true
    private var appLeftForegroundAt: Date?
    private var ignoreConnectionHealthUntil = Date.distantPast
    private var lastDecodedFrameAt: Date?
    private var lastReconnectAttemptAt = Date.distantPast
    // Current receiver state. Reconnects reset this, but hasDisplayedVideoFrame
    // remains true so SwiftUI can keep the last frame visible while retrying.
    private var didReceiveVideoInCurrentSession = false
    private var decodedFramesInCurrentSession = 0
    private var lastHealthLogAt = Date.distantPast
    private let frozenVideoTimeout: TimeInterval = 5
    private let waitingVideoTimeout: TimeInterval = 12
    private let localRouteFallbackTimeout: TimeInterval = 3
    private let reconnectCooldown: TimeInterval = 4
    private let foregroundResumeGrace: TimeInterval = 3
    private let maximumInitialNoVideoReconnects = 4
    private static let localNetworkDeniedStatus = "Local Network access is off for PocketCtrl. Allow it in Settings, then try again."
    private static let pairedHostIDKey = "PocketCtrlMobile.pairedHostID"
    private static let hostAddressKey = "PocketCtrlMobile.hostAddress"
    private static let localHostAddressKey = "PocketCtrlMobile.localHostAddress"
    private static let tailscaleHostAddressKey = "PocketCtrlMobile.tailscaleHostAddress"
    private static let videoPortKey = "PocketCtrlMobile.videoPort"
    private static let audioPortKey = "PocketCtrlMobile.audioPort"
    private static let inputPortKey = "PocketCtrlMobile.inputPort"
    private static let wakeMACAddressKey = "PocketCtrlMobile.wakeMACAddress"
    private static let wakeBroadcastAddressKey = "PocketCtrlMobile.wakeBroadcastAddress"
    private static let wakePortKey = "PocketCtrlMobile.wakePort"
    private static let shouldAutoReconnectKey = "PocketCtrlMobile.shouldAutoReconnect"
    private static let savedMacsKey = "PocketCtrlMobile.savedMacs"
    private static let selectedSavedMacIDKey = "PocketCtrlMobile.selectedSavedMacID"
    private static let savedMacCredentialPrefix = "PocketCtrlMobile.savedMacCredential.v1."
    private static let autoZoomFocusedWindowKey = "PocketCtrlMobile.autoZoomFocusedWindow"
    private static let showRemotePointerKey = "PocketCtrlMobile.showRemotePointer"
    private static let viewerDeviceNameKey = "PocketCtrlMobile.viewerDeviceName"
    private static let viewerDeviceNameOnboardingCompletedKey = "PocketCtrlMobile.viewerDeviceNameOnboardingCompleted"

    var pendingNewSavedMac: ClientSavedMac? {
        guard let pendingNewSavedMacID else { return nil }
        return savedMacs.first { $0.id == pendingNewSavedMacID }
    }

    var approvalViewerDeviceName: String {
        Self.sanitizedViewerDeviceName(viewerDeviceName) ?? Self.defaultViewerDeviceName()
    }

    var shouldShowViewerDeviceNameOnboarding: Bool {
        !hasCompletedViewerDeviceNameOnboarding
    }

    var currentPointerPosition: CGPoint {
        latestPointerPosition
    }

    var isInputReady: Bool {
        isConnected && credentialAllowsInput && inputTargetStatus != "Input target not detected"
    }

    var isWaitingForTailscaleVPN: Bool {
        guard isConnectionAttemptInProgress,
              !isConnectingOverLocalWiFi,
              !hasDisplayedVideoFrame,
              !Self.hasTailscaleIPAddress() else {
            return false
        }

        let routeHost = ClientNetworkAddressPolicy.normalized(activeInputHost.isEmpty ? hostAddress : activeInputHost)
        return ClientNetworkAddressPolicy.isTailscaleHost(routeHost)
    }

    var tailscaleRequiredHost: String {
        ClientNetworkAddressPolicy.normalized(activeInputHost.isEmpty ? hostAddress : activeInputHost)
    }

    /// True while the selected route is a LAN address, where a denied Local
    /// Network permission blocks every datagram.
    var isAttemptingLocalRoute: Bool {
        let routeHost = ClientNetworkAddressPolicy.normalized(activeInputHost.isEmpty ? hostAddress : activeInputHost)
        return !routeHost.isEmpty
            && !ClientNetworkAddressPolicy.isTailscaleHost(routeHost)
            && ClientNetworkAddressPolicy.isPrivateOrLocalAddress(routeHost)
    }

    init() {
        ClientDiagnostics.connection("client.start version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        ClientKeychainStore.deleteLegacy(forKey: "PocketCtrlMobile.pairingKey")
        ClientKeychainStore.deleteLegacyKeys(withPrefix: "PocketCtrlMobile.savedMacPairingKey.")
        UserDefaults.standard.removeObject(forKey: "PocketCtrlMobile.lanPairingCode")
        viewerDeviceName = UserDefaults.standard.string(forKey: Self.viewerDeviceNameKey)?.nonEmpty ?? Self.defaultViewerDeviceName()
        hasCompletedViewerDeviceNameOnboarding = UserDefaults.standard.bool(forKey: Self.viewerDeviceNameOnboardingCompletedKey)
        hostAddress = UserDefaults.standard.string(forKey: Self.hostAddressKey) ?? "127.0.0.1"
        localHostAddress = UserDefaults.standard.string(forKey: Self.localHostAddressKey) ?? ""
        tailscaleHostAddress = UserDefaults.standard.string(forKey: Self.tailscaleHostAddressKey) ?? ""
        videoPort = UserDefaults.standard.string(forKey: Self.videoPortKey) ?? "5555"
        audioPort = UserDefaults.standard.string(forKey: Self.audioPortKey) ?? "5557"
        inputPort = UserDefaults.standard.string(forKey: Self.inputPortKey) ?? "5556"
        pairingCode = ""
        credentialID = ""
        pairedHostID = UserDefaults.standard.string(forKey: Self.pairedHostIDKey) ?? ""
        wakeMACAddress = UserDefaults.standard.string(forKey: Self.wakeMACAddressKey) ?? ""
        wakeBroadcastAddress = UserDefaults.standard.string(forKey: Self.wakeBroadcastAddressKey) ?? "255.255.255.255"
        wakePort = UserDefaults.standard.string(forKey: Self.wakePortKey) ?? "9"
        let savedStreamSettings = ClientStreamSettings.load(from: .standard)
        streamDetailAmount = savedStreamSettings.detailAmount
        streamFrameRate = savedStreamSettings.frameRate
        savedStreamSettings.save(to: .standard)
        advertisedStreamSettings = savedStreamSettings
        streamQualityProfile = streamSettings.matchingPreset
        autoZoomFocusedWindow = UserDefaults.standard.bool(forKey: Self.autoZoomFocusedWindowKey)
        showRemotePointer = UserDefaults.standard.object(forKey: Self.showRemotePointerKey) as? Bool ?? true
        savedMacs = Self.loadSavedMacs()
        if let selectedID = UserDefaults.standard.string(forKey: Self.selectedSavedMacIDKey),
           let selected = savedMacs.first(where: { $0.id == selectedID }) {
            restoreSavedMac(selected, reason: "launch")
        }
        configureLocalDiscoveryCallbacks()
        refreshDeviceAddress()
        startLocalDiscoveryIfPossible()
        startNetworkMonitoring()
        logConnectionEvent("ClientModel initialized")
        ClientDiagnostics.write("ClientModel initialized selectedRoute=\(shortRouteLabel(for: hostAddress)) hasLocalHost=\(!localHostAddress.isEmpty) hasTailscaleHost=\(!tailscaleHostAddress.isEmpty) isPaired=\(!pairedHostID.isEmpty) videoPort=\(videoPort) inputPort=\(inputPort)")
    }

    var streamSettings: ClientStreamSettings {
        ClientStreamSettings(detailAmount: streamDetailAmount, frameRate: streamFrameRate)
    }

    func applyStreamQualityPreset(_ preset: ClientStreamQualityProfile) {
        let settings = preset.settings
        // Assign both before the debounced send so one message carries both.
        if streamDetailAmount != settings.detailAmount {
            streamDetailAmount = settings.detailAmount
        }
        if streamFrameRate != settings.frameRate {
            streamFrameRate = settings.frameRate
        }
    }

    private func handleStreamSettingsChange(reason: String) {
        streamQualityProfile = streamSettings.matchingPreset
        streamSettings.save(to: .standard)
        // Sliders fire on every tick; send once the user settles so the Mac
        // does not restart its capture for every intermediate value.
        streamPreferenceSendTask?.cancel()
        streamPreferenceSendTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.sendCurrentStreamQualityPreference(reason: reason)
        }
    }

    func completeViewerDeviceNameOnboarding(name: String) {
        viewerDeviceName = Self.sanitizedViewerDeviceName(name) ?? Self.defaultViewerDeviceName()
        hasCompletedViewerDeviceNameOnboarding = true
    }

    deinit {
        streamPreferenceSendTask?.cancel()
        localWiFiSearchTask?.cancel()
        pointerPublishWork?.cancel()
        manualPairingTask?.cancel()
        localDiscoveryBrowser.stop()
        networkMonitor.cancel()
    }

    func connect() {
        guard !localWiFiSearchFailed else { return }
        logConnectionEvent("connect() requested")
        ClientDiagnostics.write("connect requested selectedRoute=\(shortRouteLabel(for: hostAddress)) hasLocalHost=\(!localHostAddress.isEmpty) hasTailscaleHost=\(!tailscaleHostAddress.isEmpty) isPaired=\(!pairedHostID.isEmpty) videoPort=\(videoPort) inputPort=\(inputPort) interfaces=\(Self.ipInterfaceSummary())")
        guard !isConnected else {
            logConnectionEvent("connect() ignored because already connected")
            ClientDiagnostics.write("connect ignored alreadyConnected=true")
            return
        }
        refreshDeviceAddress()
        startLocalDiscoveryIfPossible()
        let targetHost = preferredConnectionHost(logDecision: true)
        if hostAddress != targetHost {
            hostAddress = targetHost
        }
        guard let inputPortValue = UInt16(inputPort),
              let videoPortValue = UInt16(videoPort) else {
            isConnectionAttemptInProgress = false
            status = "Ports must be between 1 and 65535."
            logConnectionEvent("connect() blocked: invalid ports")
            ClientDiagnostics.write("connect blocked invalidPorts videoPort=\(videoPort) inputPort=\(inputPort)")
            return
        }
        guard !targetHost.isEmpty else {
            if isConnectingOverLocalWiFi {
                // No usable LAN address yet (for example after a network change).
                // Wait for Bonjour, but never without a deadline.
                isConnectionAttemptInProgress = true
                status = "Looking for your Mac on local Wi-Fi..."
                routeStatus = "Route: local Wi-Fi"
                startLocalWiFiSearchDeadlineIfNeeded()
                return
            }
            isConnectionAttemptInProgress = false
            status = "Scan the Mac pairing QR or enter a host address."
            inputTargetStatus = "Host address required"
            logConnectionEvent("connect() blocked: missing host")
            ClientDiagnostics.write("connect blocked missingHost")
            return
        }
        guard isDeviceCredentialUsable else {
            isConnectionAttemptInProgress = false
            status = "Pair this device with the Mac before connecting."
            inputTargetStatus = "Device credential required"
            logConnectionEvent("connect() blocked: device credential missing or invalid")
            ClientDiagnostics.write("connect blocked unusableCredential credentialLength=\(sanitizedPairingCode.count)")
            return
        }
        if ClientNetworkAddressPolicy.isTailscaleHost(targetHost), !Self.hasTailscaleIPAddress() {
            Self.routeLogger.warning("Trying Tailscale even though iOS did not expose an active Tailscale address. target=\(targetHost, privacy: .private) interfaces=\(Self.ipInterfaceSummary(), privacy: .private)")
            routeDiagnostic = "Trying Tailscale even though iOS did not expose a 100.x interface. Interfaces: \(Self.ipInterfaceSummary())"
        }

        startLocalWiFiSearchDeadlineIfNeeded()
        do {
            isConnectionAttemptInProgress = true
            logConnectionEvent("connect() starting receiver setup for \(shortRouteLabel(for: targetHost)) \(targetHost):\(videoPortValue)")
            ClientDiagnostics.write("connect setup route=\(shortRouteLabel(for: targetHost)) videoPort=\(videoPortValue) inputPort=\(inputPortValue)")
            Self.routeLogger.info("Starting client connection. selected=\(targetHost, privacy: .private) route=\(self.shortRouteLabel(for: targetHost), privacy: .public) videoPort=\(self.videoPort, privacy: .public) inputPort=\(self.inputPort, privacy: .public)")
            Self.videoLogger.info("Creating video receiver. selected=\(targetHost, privacy: .private) route=\(self.shortRouteLabel(for: targetHost), privacy: .public) videoPort=\(videoPortValue, privacy: .public)")
            let receiver = try ClientVideoReceiver(
                port: videoPortValue,
                expectedSourceHost: targetHost,
                credentialID: credentialID,
                credentialSecret: sanitizedPairingCode
            )
            receiver.renderer = { [weak self, weak receiver] pixelBuffer in
                DispatchQueue.main.async { [weak self, weak receiver] in
                    guard let self, self.isCurrentVideoReceiver(receiver) else { return }
                    self.latestVideoPixelBuffer = pixelBuffer
                    self.updateScrollRailLineBrightnessIfNeeded()
                    self.renderView?.display(pixelBuffer)
                }
            }
            receiver.onFrameDecoded = { [weak self, weak receiver] in
                Task { @MainActor in
                    guard let self, self.isCurrentVideoReceiver(receiver) else { return }
                    self.recordVideoFrame()
                }
            }
            receiver.onVideoSizeChanged = { [weak self, weak receiver] size in
                Task { @MainActor in
                    guard let self, self.isCurrentVideoReceiver(receiver) else { return }
                    Self.videoLogger.info("Decoded video size changed. width=\(Int(size.width), privacy: .public) height=\(Int(size.height), privacy: .public)")
                    self.remoteVideoSize = size
                }
            }
            receiver.onFocusedWindowRegion = { [weak self, weak receiver] region in
                Task { @MainActor in
                    guard let self, self.isCurrentVideoReceiver(receiver) else { return }
                    self.updateFocusedWindowRegion(region)
                }
            }
            receiver.onStats = { [weak self, weak receiver] stats in
                Task { @MainActor in
                    guard let self, self.isCurrentVideoReceiver(receiver) else { return }
                    Self.videoLogger.info("Video stats. fps=\(stats.fps, privacy: .public) mbps=\(stats.receivedMbps, privacy: .public) frames=\(stats.frames, privacy: .public) chunks=\(stats.chunks, privacy: .public) skipped=\(stats.skippedFrames, privacy: .public) size=\(Int(stats.size.width), privacy: .public)x\(Int(stats.size.height), privacy: .public) keyframeRequested=\(stats.keyframeRequested.description, privacy: .public)")
                    self.remoteVideoSize = stats.size
                    self.latestReceivedMbps = stats.receivedMbps
                    self.videoStatus = "\(stats.fps) fps, \(String(format: "%.1f", stats.receivedMbps)) Mbps, \(stats.frames) frames, \(stats.chunks) chunks, \(stats.skippedFrames) skipped"
                    self.status = "Receiving \(Int(stats.size.width)) x \(Int(stats.size.height)) from Mac host"
                    self.sendViewerFeedback(stats)
                }
            }
            receiver.onRecoveryNeeded = { [weak self, weak receiver] skippedFrames, size in
                Task { @MainActor in
                    guard let self, self.isCurrentVideoReceiver(receiver) else { return }
                    Self.videoLogger.warning("Immediate video recovery requested. skipped=\(skippedFrames, privacy: .public)")
                    self.remoteVideoSize = size
                    self.requestHostKeyframe(skippedFrames: skippedFrames, size: size)
                }
            }
            receiver.onPeerAddress = { [weak self, weak receiver] address in
                Task { @MainActor in
                    guard let self, self.isCurrentVideoReceiver(receiver) else { return }
                    self.routeInput(to: address)
                }
            }

            activeInputHost = targetHost
            activeInputPort = inputPortValue
            advertisedStreamSettings = streamSettings
            sender = makeInputSender(host: targetHost, port: inputPortValue, reason: "initial connect")
            sendStartupRouteProbe(reason: "initial connect")
            inputTargetStatus = "Input to \(targetHost):\(inputPortValue)"
            routeStatus = routeLabel(for: targetHost)
            videoReceiver = receiver
            receiver.start()
            setRemoteAudioEnabled(audioEnabled)
            startAudioIfPossible()
            isConnected = true
            connectionStartedAt = Date()
            lastDecodedFrameAt = nil
            didReceiveVideoInCurrentSession = false
            decodedFramesInCurrentSession = 0
            lastHealthLogAt = Date.distantPast
            shouldReconnectCurrentSession = true
            UserDefaults.standard.set(currentCredentialIsPersistent, forKey: Self.shouldAutoReconnectKey)
            if currentCredentialIsPersistent {
                upsertSavedMacFromCurrent()
            }
            status = "Connecting"
            videoStatus = "Waiting for Mac video"
            routeDiagnostic = "Trying \(shortRouteLabel(for: targetHost)) at \(targetHost), video \(videoPortValue), input \(inputPortValue). Interfaces: \(Self.ipInterfaceSummary())"
            startConnectionWatchdog()
            startInitialRouteRefresh()
            logConnectionEvent("connect() completed setup; waiting for first video frame")
            ClientDiagnostics.write("connect completed setup route=\(shortRouteLabel(for: activeInputHost)) activeInputPort=\(activeInputPort.map(String.init) ?? "nil")")
        } catch {
            isConnectionAttemptInProgress = false
            status = "Video failed: \(error.localizedDescription)"
            logConnectionEvent("connect() failed creating receiver/sender: \(error.localizedDescription)")
            ClientDiagnostics.write("connect failed during receiver or sender setup")
        }
    }

    func connectToCurrentPairing(reason: String) {
        logConnectionEvent("connectToCurrentPairing requested reason=\(reason)")
        if isConnected || isConnectionAttemptInProgress || reconnectTask != nil {
            stopCurrentConnectionForManualSwitch()
        }
        initialNoVideoReconnectCount = 0
        status = "Connecting to paired Mac..."
        videoStatus = "Waiting for Mac video"
        connect()
    }

    func connectOverLocalWiFi() {
        ClientDiagnostics.connection("wifi.retry expectedHost=\(ClientDiagnostics.identifierTag(pairedHostID)) credential=\(ClientDiagnostics.identifierTag(credentialID)) credentialUsable=\(isDeviceCredentialUsable) hasSavedLAN=\(!localHostAddress.isEmpty)")
        stopCurrentConnectionForManualSwitch()
        initialNoVideoReconnectCount = 0
        isConnectingOverLocalWiFi = true
        isConnectionAttemptInProgress = true
        // Refresh Bonjour even when the saved LAN address is missing or stale.
        // The existing credential still authenticates every video/input session.
        connect()
        guard isConnectionAttemptInProgress else {
            resetLocalWiFiAttempt()
            return
        }
        startLocalWiFiSearchDeadlineIfNeeded()
    }

    /// Every local-only attempt is bounded: the first connect, and any automatic
    /// reconnect that is still waiting for Bonjour after a network change. The
    /// deadline is cancelled by the first decoded frame of the current session.
    private func startLocalWiFiSearchDeadlineIfNeeded() {
        guard isConnectingOverLocalWiFi, localWiFiSearchTask == nil else { return }
        localWiFiSearchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, !Task.isCancelled, self.isConnectingOverLocalWiFi,
                  !self.didReceiveVideoInCurrentSession else { return }
            ClientDiagnostics.connection("wifi.timeout expectedHost=\(ClientDiagnostics.identifierTag(self.pairedHostID)) discoveredLAN=\(self.discoveredLocalWiFiHost != nil) receiverStarted=\(self.isConnected) hadVideo=\(self.hasDisplayedVideoFrame) credentialUsable=\(self.isDeviceCredentialUsable) \(self.localDiscoveryBrowser.diagnosticSummary)")
            self.failLocalWiFiAttempt(status: self.localNetworkAccessDenied
                ? Self.localNetworkDeniedStatus
                : "Couldn't reach your Mac over local Wi-Fi.")
        }
    }

    private func failLocalWiFiAttempt(status failureStatus: String) {
        stopCurrentConnectionForManualSwitch()
        isConnectingOverLocalWiFi = true
        isConnectionAttemptInProgress = true
        localWiFiSearchFailed = true
        status = failureStatus
        routeStatus = "Route: local Wi-Fi"
    }

    private func resetLocalWiFiAttempt() {
        if isConnectingOverLocalWiFi {
            ClientDiagnostics.connection("wifi.attemptCleared hadVideo=\(hasDisplayedVideoFrame) searchFailed=\(localWiFiSearchFailed)")
        }
        localWiFiSearchTask?.cancel()
        localWiFiSearchTask = nil
        isConnectingOverLocalWiFi = false
        localWiFiSearchFailed = false
        discoveredLocalWiFiHost = nil
    }

    func connectWithManualPairingCode(_ rawCode: String, updatesConnectionStatus: Bool = false) {
        let code = PairingInvitationCode.normalized(rawCode)
        let invitation: DecodedPairingInvitationCode
        do {
            invitation = try PairingInvitationCode.decode(code)
        } catch {
            manualPairingStatus = error.localizedDescription
            if updatesConnectionStatus {
                status = manualPairingStatus
            }
            return
        }

        prepareForNewPairingAttempt()
        cancelManualPairingAttempt()
        let attemptID = manualPairingAttemptID
        manualPairingDiscoveredHosts.removeAll()
        manualPairingDiscoveryActive = true
        isPairingRequestInProgress = true
        localDiscoveryBrowser.startAnyHostSearch()
        manualPairingStatus = "Looking for your Mac nearby and through Tailscale..."
        if updatesConnectionStatus {
            status = manualPairingStatus
        }

        manualPairingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            let candidates = await MainActor.run {
                self.manualPairingAttemptID == attemptID ? self.manualPairingCandidates(invitation: invitation) : nil
            }
            guard let candidates else { return }
            guard !candidates.isEmpty else {
                await MainActor.run {
                    guard self.manualPairingAttemptID == attemptID else { return }
                    self.manualPairingDiscoveryActive = false
                    self.isPairingRequestInProgress = false
                    self.startLocalDiscoveryIfPossible()
                    self.manualPairingStatus = invitation.tailscaleAddress == nil
                        ? "Connect both devices to the same Wi-Fi, then try again."
                        : "Turn on Tailscale or connect both devices to the same Wi-Fi."
                    if updatesConnectionStatus {
                        self.status = self.manualPairingStatus
                    }
                }
                return
            }

            do {
                let result = try await self.raceManualPairingRequests(code: code, candidates: candidates)
                await MainActor.run {
                    guard self.manualPairingAttemptID == attemptID else { return }
                    self.manualPairingDiscoveryActive = false
                    self.isPairingRequestInProgress = false
                    self.localDiscoveryBrowser.stop()
                    self.manualPairingStatus = "Approved by \(result.response.hostName) through \(result.candidate.routeDescription). Connecting..."
                    if self.applyApprovedPairingResponse(result.response.pairingURL, connectedHost: result.candidate.host) {
                        self.connectToCurrentPairing(reason: "manual pairing code through \(result.candidate.routeDescription)")
                    } else {
                        self.manualPairingStatus = self.pairingApplicationFailureMessage
                            ?? "The approved response did not contain valid pairing details."
                        if updatesConnectionStatus {
                            self.status = self.manualPairingStatus
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.manualPairingAttemptID == attemptID else { return }
                    self.manualPairingDiscoveryActive = false
                    self.isPairingRequestInProgress = false
                    self.startLocalDiscoveryIfPossible()
                }
                return
            } catch {
                await MainActor.run {
                    // A superseded attempt's failure (including its own
                    // cancellation surfacing as a transport error) must not
                    // reset discovery or overwrite the newer attempt's status.
                    guard self.manualPairingAttemptID == attemptID else { return }
                    self.manualPairingDiscoveryActive = false
                    self.isPairingRequestInProgress = false
                    self.startLocalDiscoveryIfPossible()
                    self.manualPairingStatus = error.localizedDescription
                    if updatesConnectionStatus {
                        self.status = self.manualPairingStatus
                    }
                }
            }
        }
    }

    func connect(to savedMac: ClientSavedMac) {
        if isConnected || isConnectionAttemptInProgress || reconnectTask != nil {
            switchConnection(to: savedMac)
            return
        }
        initialNoVideoReconnectCount = 0
        applySavedMac(savedMac)
        connect()
    }

    private func switchConnection(to savedMac: ClientSavedMac) {
        logConnectionEvent("switchConnection requested. target=\(savedMac.name)")
        stopCurrentConnectionForManualSwitch()
        initialNoVideoReconnectCount = 0
        applySavedMac(savedMac)
        status = "Switching to \(savedMac.name)..."
        videoStatus = "Waiting for Mac video"
        connect()
    }

    func renameSavedMac(id: String, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = savedMacs.firstIndex(where: { $0.id == id }) else {
            return
        }

        savedMacs[index].name = name
        saveSavedMacs()
    }

    func removeSavedMac(id: String) {
        let removedCredentialID = savedMacs.first(where: { $0.id == id })?.credentialID
        savedMacs.removeAll { $0.id == id }
        saveSavedMacs()
        if let removedCredentialID = removedCredentialID?.nonEmpty,
           !savedMacs.contains(where: { $0.credentialID == removedCredentialID }) {
            ClientKeychainStore.delete(forKey: credentialKeychainKey(for: removedCredentialID))
        }

        if pendingNewSavedMacID == id {
            pendingNewSavedMacID = nil
        }

        if pairedHostID == id, !isConnected {
            pairedHostID = ""
            localHostAddress = ""
            tailscaleHostAddress = ""
            hostAddress = ""
            pairingCode = ""
            routeOverrideHost = nil
            inputTargetStatus = "Input target not detected"
            routeStatus = "Route: automatic"
            localDiscoveryStatus = "Local discovery waiting for pairing."
        }
    }

    func clearPendingNewSavedMacName() {
        pendingNewSavedMacID = nil
    }

    func disconnect() {
        resetLocalWiFiAttempt()
        logConnectionEvent("disconnect() requested by UI/user")
        ClientDiagnostics.write("disconnect requested")
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectKey)
        shouldReconnectCurrentSession = false
        initialNoVideoReconnectCount = 0
        cancelManualPairingAttempt()
        manualPairingDiscoveryActive = false
        isPairingRequestInProgress = false
        startLocalDiscoveryIfPossible()
        setRemoteAudioEnabled(false)
        requestZoomRegion(nil)
        videoReceiver?.stop()
        videoReceiver = nil
        stopAudio()
        sender = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        initialRouteRefreshTask?.cancel()
        initialRouteRefreshTask = nil
        activeInputHost = ""
        routeOverrideHost = nil
        activeInputPort = nil
        isConnected = false
        isConnectionAttemptInProgress = false
        isAutomaticReconnectInProgress = false
        status = "Disconnected"
        videoStatus = "No video yet"
        audioStatus = audioEnabled ? "Audio waiting for connection" : "Audio off"
        inputTargetStatus = "Input target not detected"
        routeStatus = "Route: automatic"
        activeZoomRegion = nil
        isRegionZoomActive = false
        focusedWindowRegion = nil
        resetMouseInteractionState()
        resetPointerPublishState()
        lastDecodedFrameAt = nil
        didReceiveVideoInCurrentSession = false
        hasDisplayedVideoFrame = false
        latestReceivedMbps = 0
        latestVideoPixelBuffer = nil
        scrollRailSamplePoint = nil
        scrollRailLineBrightness = 0.28
        renderView?.clear()
        logConnectionEvent("disconnect() finished")
        ClientDiagnostics.write("disconnect finished")
    }

    func retryPreviousConnectionIfNeeded() {
        logConnectionEvent("retryPreviousConnectionIfNeeded() called")
        guard !hasAttemptedAutoReconnect, !isConnected else {
            logConnectionEvent("retryPreviousConnectionIfNeeded() ignored: already attempted or connected")
            return
        }
        retrySavedCredentialLoadIfNeeded()
        hasAttemptedAutoReconnect = true
        guard UserDefaults.standard.bool(forKey: Self.shouldAutoReconnectKey),
              isDeviceCredentialUsable else {
            logConnectionEvent("retryPreviousConnectionIfNeeded() skipped: auto reconnect disabled or credential unusable")
            return
        }

        status = "Reconnecting with saved device credential..."
        initialNoVideoReconnectCount = 0
        logConnectionEvent("retryPreviousConnectionIfNeeded() reconnecting with saved pairing")
        connect()
    }

    func pauseConnectionHealthChecks() {
        guard isAppForeground else { return }
        isAppForeground = false
        appLeftForegroundAt = Date()
        // iOS may stop delivering UDP/video work while the app is not foregrounded.
        // Keep the visible session intact and let the active-state watchdog decide
        // whether the stream truly failed after the app has had time to resume.
        Self.videoLogger.info("App left foreground. Pausing connection health checks.")
        logConnectionEvent("scenePhase moved inactive/background; health checks paused")
    }

    func resumeConnectionIfNeeded() {
        logConnectionEvent("resumeConnectionIfNeeded() called")
        refreshDeviceAddress()
        retrySavedCredentialLoadIfNeeded()
        let now = Date()
        isAppForeground = true

        let backgroundDuration = appLeftForegroundAt.map { now.timeIntervalSince($0) } ?? 0
        appLeftForegroundAt = nil
        ignoreConnectionHealthUntil = now.addingTimeInterval(foregroundResumeGrace)
        if localNetworkAccessDenied, !manualPairingDiscoveryActive {
            // The user may have just enabled Local Network in Settings.
            startLocalDiscoveryIfPossible()
        }

        guard shouldReconnectCurrentSession || UserDefaults.standard.bool(forKey: Self.shouldAutoReconnectKey),
              isDeviceCredentialUsable else {
            logConnectionEvent("resumeConnectionIfNeeded() skipped: auto reconnect disabled or credential unusable")
            return
        }

        guard now.timeIntervalSince(lastResumeHandledAt) >= 2 else {
            logConnectionEvent("resumeConnectionIfNeeded() ignored: resume debounce")
            return
        }
        lastResumeHandledAt = now

        if isConnected {
            if didReceiveVideoInCurrentSession {
                lastDecodedFrameAt = now
            } else {
                connectionStartedAt = now
            }
            refreshInputSenderAfterInterfaceResume(reason: "app resumed")
            Self.videoLogger.info("App resumed with active connection. backgroundDuration=\(backgroundDuration, privacy: .public) healthGrace=\(self.foregroundResumeGrace, privacy: .public)")
            logConnectionEvent("resumeConnectionIfNeeded() kept active connection; health grace applied")
        } else {
            status = "Reconnecting after wake..."
            logConnectionEvent("resumeConnectionIfNeeded() reconnecting because model was disconnected")
            connect()
        }
    }

    func refreshTailscaleConnectionAssist(reason: String) {
        refreshDeviceAddress()
        guard isWaitingForTailscaleVPN else { return }
        routeStatus = "Route: Tailscale"
        routeDiagnostic = "The selected address \(tailscaleRequiredHost) uses Tailscale, but no VPN address is visible. You can also try local Wi-Fi. Interfaces: \(Self.ipInterfaceSummary())"
        ClientDiagnostics.write("tailscale assist active reason=\(reason) interfaces=\(Self.ipInterfaceSummary())")
    }

    func refreshInputSenderAfterInterfaceResume(reason: String = "interface resumed") {
        guard isConnected else {
            logConnectionEvent("refreshInputSenderAfterInterfaceResume skipped: not connected. reason=\(reason)")
            return
        }
        shouldRefreshInputSenderBeforeNextInput = true
        logConnectionEvent("refreshInputSenderAfterInterfaceResume requested. reason=\(reason)")
        recreateInputSenderIfPossible(reason: reason, force: false)
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            let interfaces = [
                path.usesInterfaceType(.wifi) ? "wifi" : nil,
                path.usesInterfaceType(.cellular) ? "cellular" : nil,
                path.usesInterfaceType(.wiredEthernet) ? "ethernet" : nil,
                path.usesInterfaceType(.loopback) ? "loopback" : nil,
                path.usesInterfaceType(.other) ? "other" : nil
            ].compactMap { $0 }.joined(separator: ",")

            Task { @MainActor [weak self] in
                self?.handleNetworkPathChange(isSatisfied: isSatisfied, interfaces: interfaces.isEmpty ? "none" : interfaces)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func handleNetworkPathChange(isSatisfied: Bool, interfaces: String) {
        refreshDeviceAddress()
        lastObservedNetworkInterfaces = interfaces
        logConnectionEvent("NWPath update received. satisfied=\(isSatisfied) interfaces=\(interfaces)")

        guard hasObservedInitialNetworkPath else {
            hasObservedInitialNetworkPath = true
            startLocalDiscoveryIfPossible()
            routeDiagnostic = "Network ready on \(interfaces). \(routeDiagnostic)"
            logConnectionEvent("NWPath initial observation recorded")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastNetworkPathHandledAt) >= 2 else {
            logConnectionEvent("NWPath update ignored: debounce")
            return
        }
        lastNetworkPathHandledAt = now
        discoveredLocalWiFiHost = nil

        guard isSatisfied else {
            routeDiagnostic = "Network unavailable. Interfaces: \(Self.ipInterfaceSummary())"
            if isConnected {
                status = "Network unavailable. Waiting for Wi-Fi or Tailscale..."
            }
            logConnectionEvent("NWPath unavailable; not reconnecting until network returns")
            return
        }

        let activeOverrideHost = ClientNetworkAddressPolicy.normalized(routeOverrideHost ?? "")
        let currentActiveHost = ClientNetworkAddressPolicy.normalized(activeInputHost)
        let shouldKeepWorkingFallback = isConnected &&
            !activeOverrideHost.isEmpty &&
            activeOverrideHost == currentActiveHost &&
            ClientNetworkAddressPolicy.isTailscaleHost(activeOverrideHost)
        if !shouldKeepWorkingFallback {
            routeOverrideHost = nil
        }
        startLocalDiscoveryIfPossible()
        routeDiagnostic = "Network changed on \(interfaces). Rechecking route. Interfaces: \(Self.ipInterfaceSummary())"
        guard shouldReconnectCurrentSession || UserDefaults.standard.bool(forKey: Self.shouldAutoReconnectKey),
              isDeviceCredentialUsable else {
            logConnectionEvent("NWPath change skipped: auto reconnect disabled or credential unusable")
            return
        }
        guard isAppForeground else {
            Self.routeLogger.info("Deferring network-change reconnect while app is not foregrounded. interfaces=\(interfaces, privacy: .private)")
            logConnectionEvent("NWPath change deferred: app not foreground")
            return
        }

        if isConnected {
            guard now >= ignoreConnectionHealthUntil else {
                Self.routeLogger.info("Deferring network-change reconnect while app resumes. interfaces=\(interfaces, privacy: .private)")
                logConnectionEvent("NWPath change deferred: foreground resume grace")
                return
            }
            guard now.timeIntervalSince(connectionStartedAt) >= 2 else {
                logConnectionEvent("NWPath change ignored: connection is too new")
                return
            }
            let selectedHost = ClientNetworkAddressPolicy.normalized(preferredConnectionHost())
            let currentHost = ClientNetworkAddressPolicy.normalized(activeInputHost.isEmpty ? hostAddress : activeInputHost)

            guard !selectedHost.isEmpty else {
                logConnectionEvent("NWPath change ignored: selected route is empty")
                return
            }
            guard selectedHost != currentHost else {
                routeStatus = routeLabel(for: currentHost)
                routeDiagnostic = "Network changed on \(interfaces), kept \(shortRouteLabel(for: currentHost)). Interfaces: \(Self.ipInterfaceSummary())"
                Self.routeLogger.info("Ignored network-change reconnect because route did not change. active=\(currentHost, privacy: .private) selected=\(selectedHost, privacy: .private) interfaces=\(interfaces, privacy: .private)")
                logConnectionEvent("NWPath change kept current route \(currentHost)")
                return
            }

            hostAddress = selectedHost
            routeStatus = routeLabel(for: selectedHost)
            Self.routeLogger.info("Network changed selected a new route. active=\(currentHost, privacy: .private) selected=\(selectedHost, privacy: .private) interfaces=\(interfaces, privacy: .private)")
            logConnectionEvent("NWPath change selected new route \(selectedHost); scheduling reconnect")
            scheduleReconnect(reason: "Network route changed. Reconnecting...")
        } else if isConnectionAttemptInProgress || reconnectTask != nil {
            Self.routeLogger.info("Ignored network-change reconnect because a connection attempt is already active. interfaces=\(interfaces, privacy: .private)")
            logConnectionEvent("NWPath change ignored: connection/reconnect already in progress")
        } else {
            status = "Network changed. Reconnecting..."
            logConnectionEvent("NWPath change reconnecting from disconnected state")
            connect()
        }
    }

    func wakeMac() {
        sendWakePacket(macAddress: wakeMACAddress, localHostAddress: localHostAddress)
    }

    func wakeMac(_ savedMac: ClientSavedMac) {
        sendWakePacket(macAddress: savedMac.wakeMACAddress, localHostAddress: savedMac.localHostAddress, macName: savedMac.name)
    }

    private func sendWakePacket(macAddress: String, localHostAddress: String, macName: String? = nil) {
        guard let port = UInt16(wakePort) else {
            setWakeStatus("Wake port must be between 1 and 65535")
            return
        }
        let trimmedMACAddress = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMACAddress.isEmpty else {
            setWakeStatus(macName.map { "No Wake-on-LAN MAC address saved for \($0). Rescan the Mac QR while the Mac app is open." } ?? "Wake MAC address is empty")
            return
        }

        let broadcastAddresses = wakeBroadcastCandidates(localHostAddress: localHostAddress)
        let ports = wakePortCandidates(primary: port)
        guard !broadcastAddresses.isEmpty else {
            setWakeStatus("Wake failed: no broadcast address available")
            return
        }

        let target = macName ?? trimmedMACAddress
        wakeTask?.cancel()
        setWakeStatus("Sending wake packets to \(target)...")
        wakeTask = Task { [weak self] in
            let result = await ClientWakeOnLANSender.sendBurst(
                macAddress: trimmedMACAddress,
                broadcastAddresses: broadcastAddresses,
                ports: ports
            )

            guard !Task.isCancelled else { return }
            if result.didSend {
                let destinations = result.sentTargets.prefix(6).joined(separator: ", ")
                self?.setWakeStatus("Wake packets sent to \(target) on \(destinations)")
            } else if let lastError = result.lastError {
                self?.setWakeStatus("Wake failed: \(lastError.localizedDescription)")
            } else {
                self?.setWakeStatus("Wake failed: no packet was sent")
            }
            self?.wakeTask = nil
        }
    }

    private func setWakeStatus(_ message: String) {
        wakeStatus = message
        status = message
    }

    private func wakeBroadcastCandidates(localHostAddress: String) -> [String] {
        let configured = wakeBroadcastAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let localBroadcasts = [
            localHostAddress,
            Self.localIPAddress() ?? ""
        ]
            .compactMap(Self.directedBroadcastAddress)

        var candidates = localBroadcasts
        if !configured.isEmpty {
            candidates.append(configured)
        }
        candidates.append("255.255.255.255")

        var seen = Set<String>()
        return candidates.filter { candidate in
            guard !candidate.isEmpty, seen.insert(candidate).inserted else { return false }
            return true
        }
    }

    private func wakePortCandidates(primary: UInt16) -> [UInt16] {
        var seen = Set<UInt16>()
        return [primary, 9, 7].filter { seen.insert($0).inserted }
    }

    private static func directedBroadcastAddress(for address: String) -> String? {
        let normalized = ClientNetworkAddressPolicy.normalized(address)
        guard ClientNetworkAddressPolicy.isPrivateOrLocalAddress(normalized),
              !ClientNetworkAddressPolicy.isTailscaleHost(normalized),
              let parts = ClientNetworkAddressPolicy.ipv4Octets(normalized),
              parts.count == 4 else {
            return nil
        }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }

    func send(_ event: ClientRemoteInputEvent) {
        guard prepareInputSenderForUserInput(reason: event.kind.rawValue) else { return }
        sender?.send(event)
        lastEvent = event.kind.rawValue
    }

    func sendText(_ text: String) {
        guard prepareInputSenderForUserInput(reason: "text") else { return }
        let strokes = ClientTextTyper.strokes(for: text)
        guard !strokes.isEmpty else { return }

        textTypingQueue.append(contentsOf: strokes)
        lastEvent = "typing \(text.count) chars"
        guard textTypingTask == nil else { return }

        textTypingTask = Task { [weak self] in
            await self?.drainTextTypingQueue()
        }
    }

    private func drainTextTypingQueue() async {
        while !textTypingQueue.isEmpty {
            let stroke = textTypingQueue.removeFirst()
            sender?.send(.key(.keyDown, keyCode: stroke.keyCode, modifiers: stroke.modifiers))
            try? await Task.sleep(nanoseconds: 6_000_000)
            sender?.send(.key(.keyUp, keyCode: stroke.keyCode, modifiers: stroke.modifiers))
            try? await Task.sleep(nanoseconds: 8_000_000)
        }

        textTypingTask = nil
        lastEvent = "typed text"
        if !textTypingQueue.isEmpty {
            textTypingTask = Task { [weak self] in
                await self?.drainTextTypingQueue()
            }
        }
    }

    func sendShortcut(keyCode: UInt16, modifiers: UInt64) {
        guard prepareInputSenderForUserInput(reason: "shortcut") else { return }

        sender?.send(.key(.keyDown, keyCode: keyCode, modifiers: modifiers))
        sender?.send(.key(.keyUp, keyCode: keyCode, modifiers: modifiers))
        lastEvent = "shortcut"
    }

    func sendKey(keyCode: UInt16, modifiers: UInt64 = 0) {
        guard prepareInputSenderForUserInput(reason: "key") else { return }

        sender?.send(.key(.keyDown, keyCode: keyCode, modifiers: modifiers))
        sender?.send(.key(.keyUp, keyCode: keyCode, modifiers: modifiers))
        lastEvent = "key \(keyCode)"
    }

    func scroll(deltaY: Double) {
        guard isInputReady else { return }
        scroll(deltaX: 0, deltaY: deltaY)
    }

    func scroll(deltaX: Double, deltaY: Double) {
        guard isInputReady else { return }
        send(.scroll(x: latestPointerPosition.x, y: latestPointerPosition.y, deltaX: deltaX, deltaY: deltaY))
    }

    func movePointer(to position: CGPoint) {
        let nextPosition = CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
        latestPointerPosition = nextPosition
        schedulePointerPublish()
        send(.pointer(.mouseMove, x: nextPosition.x, y: nextPosition.y, button: .left))
    }

    func movePointer(from startPosition: CGPoint, screenTranslation: CGSize, screenSize: CGSize) {
        guard screenSize.width > 0, screenSize.height > 0 else { return }
        movePointer(to: CGPoint(
            x: startPosition.x + (screenTranslation.width / screenSize.width),
            y: startPosition.y + (screenTranslation.height / screenSize.height)
        ))
    }

    private func schedulePointerPublish() {
        guard pointerPublishWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pointerPublishWork = nil
            self.pointerPosition = self.latestPointerPosition
        }
        pointerPublishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: work)
    }

    private func resetPointerPublishState() {
        pointerPublishWork?.cancel()
        pointerPublishWork = nil
        latestPointerPosition = CGPoint(x: 0.5, y: 0.5)
        pointerPosition = latestPointerPosition
    }

    func requestZoomRegion(_ regionInCurrentStream: CGRect?) {
        guard prepareInputSenderForUserInput(reason: "zoom") else { return }

        guard let regionInCurrentStream else {
            sender?.send(ClientZoomRegion(enabled: false, x: 0, y: 0, width: 1, height: 1))
            activeZoomRegion = nil
            isRegionZoomActive = false
            lastEvent = "zoom full display"
            return
        }

        let baseRegion = activeZoomRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let composedRegion = CGRect(
            x: baseRegion.minX + baseRegion.width * regionInCurrentStream.minX,
            y: baseRegion.minY + baseRegion.height * regionInCurrentStream.minY,
            width: baseRegion.width * regionInCurrentStream.width,
            height: baseRegion.height * regionInCurrentStream.height
        )
        let region = sanitizedZoomRegion(composedRegion)
        sender?.send(ClientZoomRegion(
            enabled: true,
            x: region.minX,
            y: region.minY,
            width: region.width,
            height: region.height
        ))
        activeZoomRegion = region
        isRegionZoomActive = true
        lastEvent = "zoom region"
    }

    func panActiveZoomRegion(by translation: CGSize, contentSize: CGSize) {
        guard prepareInputSenderForUserInput(reason: "zoom pan"),
              let activeZoomRegion,
              contentSize.width > 0,
              contentSize.height > 0 else {
            return
        }

        let deltaX = -(translation.width / contentSize.width) * activeZoomRegion.width
        let deltaY = -(translation.height / contentSize.height) * activeZoomRegion.height
        let nextRegion = CGRect(
            x: activeZoomRegion.minX + deltaX,
            y: activeZoomRegion.minY + deltaY,
            width: activeZoomRegion.width,
            height: activeZoomRegion.height
        )
        let region = sanitizedZoomRegion(nextRegion)
        sender?.send(ClientZoomRegion(
            enabled: true,
            x: region.minX,
            y: region.minY,
            width: region.width,
            height: region.height
        ))
        self.activeZoomRegion = region
        isRegionZoomActive = true
        lastEvent = "zoom pan"
    }

    func setRemoteAudioEnabled(_ enabled: Bool) {
        guard isConnected || sender != nil else { return }
        sender?.send(ClientAudioSetting(enabled: enabled))
        lastEvent = enabled ? "audio on" : "audio off"
    }

    private func sendViewerFeedback(_ stats: ClientVideoStats) {
        let observedFrames = stats.frames + stats.skippedFrames
        let lossPercent = observedFrames > 0 ? (Double(stats.skippedFrames) / Double(observedFrames)) * 100 : 0
        sender?.send(ClientViewerFeedback(
            fps: stats.fps,
            videoWidth: Int(stats.size.width),
            videoHeight: Int(stats.size.height),
            receivedChunks: stats.chunks,
            completedFrames: stats.frames,
            skippedFrames: stats.skippedFrames,
            estimatedLossPercent: lossPercent,
            keyframeRequested: stats.keyframeRequested,
            qualityProfile: advertisedStreamSettings.matchingPreset,
            maximumFrameRate: advertisedStreamSettings.maximumFrameRate,
            maximumBitrate: advertisedStreamSettings.maximumBitrate,
            maximumCaptureWidth: advertisedStreamSettings.maximumCaptureWidth
        ))
    }

    private func sendCurrentStreamQualityPreference(reason: String) {
        advertisedStreamSettings = streamSettings
        guard sender != nil else { return }
        Self.videoLogger.info("Sending stream quality preference. profile=\(self.streamQualityProfile.rawValue, privacy: .public) detail=\(self.streamDetailAmount, privacy: .public) fps=\(self.streamSettings.maximumFrameRate, privacy: .public) reason=\(reason, privacy: .public)")
        requestHostKeyframe()
    }

    private func requestHostKeyframe(skippedFrames: Int = 0, size: CGSize = .zero) {
        // The video path is intentionally UDP-first for latency. This tiny
        // feedback message gives us WebRTC-style decoder recovery without
        // waiting for the next scheduled IDR frame after a fresh connect.
        Self.videoLogger.info("Sending host keyframe request. skippedFrames=\(skippedFrames, privacy: .public) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public) host=\(self.activeInputHost, privacy: .private)")
        sender?.send(ClientViewerFeedback(
            fps: 0,
            videoWidth: Int(size.width),
            videoHeight: Int(size.height),
            receivedChunks: 0,
            completedFrames: 0,
            skippedFrames: 0,
            estimatedLossPercent: 0,
            keyframeRequested: true,
            qualityProfile: advertisedStreamSettings.matchingPreset,
            maximumFrameRate: advertisedStreamSettings.maximumFrameRate,
            maximumBitrate: advertisedStreamSettings.maximumBitrate,
            maximumCaptureWidth: advertisedStreamSettings.maximumCaptureWidth
        ))
    }

    func resetZoomRegion() {
        requestZoomRegion(nil)
    }

    private func updateFocusedWindowRegion(_ region: ClientFocusedWindowRegion?) {
        let nextRegion = region.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }

        if shouldSuppressNextFocusedWindowZoomAfterReconnect, nextRegion != nil {
            shouldSuppressNextFocusedWindowZoomAfterReconnect = false
            focusedWindowRegion = nextRegion
            lastEvent = "focused window zoom suppressed after reconnect"
            return
        }

        guard !normalizedRegionsAreEqual(focusedWindowRegion, nextRegion) else { return }
        focusedWindowRegion = nextRegion
        if autoZoomFocusedWindow, nextRegion != nil {
            guard !isFocusedWindowAutoZoomSuspended else {
                suppressedFocusedWindowZoomNeedsRefresh = true
                lastEvent = "focused window zoom deferred"
                return
            }

            focusedWindowZoomRevision &+= 1
            lastEvent = "focused window zoom"
        }
    }

    private func normalizedRegionsAreEqual(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.minX - rhs.minX) < 0.002 &&
                abs(lhs.minY - rhs.minY) < 0.002 &&
                abs(lhs.width - rhs.width) < 0.002 &&
                abs(lhs.height - rhs.height) < 0.002
        default:
            return false
        }
    }

    @discardableResult
    func applyPairingQRCode(_ scannedValue: String) -> ClientPairingQRCodeResult? {
        let trimmed = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           components.scheme == "pocketctrl",
           components.host == "pair" {
            let queryItems = components.queryItems ?? []
            if let requestCode = queryItems.first(where: { $0.name == "request" })?.value {
                if let expiration = queryItems.first(where: { $0.name == "expires" })?.value,
                   let expirationDate = ISO8601DateFormatter().date(from: expiration),
                   expirationDate <= Date() {
                    manualPairingStatus = "That pairing code expired. Generate a new one on the Mac."
                    status = manualPairingStatus
                    return nil
                }
                let normalizedCode = PairingInvitationCode.normalized(requestCode)
                guard (try? PairingInvitationCode.decode(normalizedCode)) != nil else {
                    return nil
                }
                prepareForNewPairingAttempt()
                applyPairingQueryItems(queryItems, savePairing: false)
                connectWithManualPairingCode(normalizedCode, updatesConnectionStatus: true)
                return .approvalRequested
            }

            manualPairingStatus = "Only a temporary PocketCtrl pairing invitation can be scanned."
            return nil
        }
        return nil
    }

    private func applyApprovedPairingResponse(_ scannedValue: String, connectedHost: String) -> Bool {
        pairingApplicationFailureMessage = nil
        guard let components = URLComponents(string: scannedValue),
              components.scheme == "pocketctrl",
              components.host == "paired" else { return false }
        let queryItems = components.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let secret = value("credentialSecret"), secret.count >= 32,
              let approvedCredentialID = value("credentialID"), !approvedCredentialID.isEmpty,
              let approvedHostID = value("id"), !approvedHostID.isEmpty else { return false }
        savedCredentialReadNeedsRetry = false
        pairingCode = secret
        credentialID = approvedCredentialID
        credentialAllowsInput = value("allowsInput") == "1"
        credentialAllowsClipboard = value("allowsClipboard") == "1"
        credentialAllowsAudio = value("allowsAudio") == "1"
        currentCredentialIsPersistent = value("persistent") == "1"
        shouldReconnectCurrentSession = true
        UserDefaults.standard.set(currentCredentialIsPersistent, forKey: Self.shouldAutoReconnectKey)
        let isNewSavedMac = currentCredentialIsPersistent && !savedMacs.contains { $0.id == approvedHostID }
        let requestedPersistentCredential = currentCredentialIsPersistent
        let didPersistCredential = applyPairingQueryItems(queryItems, savePairing: requestedPersistentCredential, connectedHost: connectedHost)
        if requestedPersistentCredential && !didPersistCredential {
            pendingNewSavedMacID = nil
            return false
        }
        pendingNewSavedMacID = didPersistCredential && isNewSavedMac ? approvedHostID : nil
        return true
    }

    func click(_ button: ClientRemoteMouseButton, clickCount: Int = 1) {
        let count = min(max(clickCount, 1), 3)
        send(.pointer(.mouseDown, x: latestPointerPosition.x, y: latestPointerPosition.y, button: button, clickCount: count))
        send(.pointer(.mouseUp, x: latestPointerPosition.x, y: latestPointerPosition.y, button: button, clickCount: count))
    }

    func mouseDown(_ button: ClientRemoteMouseButton) {
        activeMouseButtons.insert(button)
        updateFocusedWindowAutoZoomSuspension()
        send(.pointer(.mouseDown, x: latestPointerPosition.x, y: latestPointerPosition.y, button: button))
    }

    func mouseUp(_ button: ClientRemoteMouseButton) {
        send(.pointer(.mouseUp, x: latestPointerPosition.x, y: latestPointerPosition.y, button: button))
        activeMouseButtons.remove(button)
        updateFocusedWindowAutoZoomSuspension()
    }

    private func updateFocusedWindowAutoZoomSuspension() {
        let shouldSuspend = activeMouseButtons.contains(.left)
        guard shouldSuspend != isFocusedWindowAutoZoomSuspended else { return }

        isFocusedWindowAutoZoomSuspended = shouldSuspend
        if !shouldSuspend, suppressedFocusedWindowZoomNeedsRefresh {
            suppressedFocusedWindowZoomNeedsRefresh = false
            if autoZoomFocusedWindow, focusedWindowRegion != nil {
                focusedWindowZoomRevision &+= 1
                lastEvent = "focused window zoom after drag"
            }
        }
    }

    private func resetMouseInteractionState(clearReconnectZoomSuppression: Bool = true) {
        activeMouseButtons.removeAll()
        isFocusedWindowAutoZoomSuspended = false
        suppressedFocusedWindowZoomNeedsRefresh = false
        if clearReconnectZoomSuppression {
            shouldSuppressNextFocusedWindowZoomAfterReconnect = false
        }
    }

    private func routeInput(to detectedHost: String) {
        guard isConnected, !detectedHost.isEmpty, detectedHost != "0.0.0.0" else { return }
        // A multihomed Mac can send authenticated video from its VPN address.
        // Do not let that silently move this explicitly local input route to VPN.
        guard !isConnectingOverLocalWiFi || !ClientNetworkAddressPolicy.isTailscaleHost(detectedHost) else { return }
        guard let port = activeInputPort else { return }
        // ClientVideoReceiver invokes this callback only after authenticating
        // the encrypted stream with the paired credential. Accept a different
        // address on the same LAN so input follows a multihomed Mac when the
        // OS changes the source interface for outbound video.
        guard ClientNetworkAddressPolicy.shouldAcceptAuthenticatedStreamPeer(
            configuredHost: activeInputHost,
            sourceHost: detectedHost
        ) else {
            Self.routeLogger.warning("Ignored unexpected video peer. activeInputHost=\(self.activeInputHost, privacy: .private) detectedHost=\(detectedHost, privacy: .private)")
            inputTargetStatus = "Ignored unexpected video source \(detectedHost)"
            return
        }

        if activeInputHost == detectedHost {
            if sender == nil {
                recreateInputSenderIfPossible(reason: "video peer confirmed", force: true)
            }
            inputTargetStatus = "Input to \(detectedHost):\(port)"
            routeStatus = routeLabel(for: detectedHost)
            return
        }

        if ClientNetworkAddressPolicy.isTailscaleHost(activeInputHost) {
            if ClientNetworkAddressPolicy.isTailscaleAddress(detectedHost) {
                Self.routeLogger.info("Accepted Tailscale video peer while keeping configured input target. activeInputHost=\(self.activeInputHost, privacy: .private) detectedHost=\(detectedHost, privacy: .private)")
                inputTargetStatus = "Input to \(activeInputHost):\(port)"
                routeStatus = "Route: Tailscale"
            } else {
                Self.routeLogger.warning("Ignored non-Tailscale video peer while connected to Tailscale. activeInputHost=\(self.activeInputHost, privacy: .private) detectedHost=\(detectedHost, privacy: .private)")
                inputTargetStatus = "Ignored unexpected video source \(detectedHost)"
            }
            return
        }

        activeInputHost = detectedHost
        hostAddress = detectedHost
        sender = makeInputSender(host: detectedHost, port: port, reason: "video peer confirmed")
        Self.routeLogger.info("Auto-routed input to video peer. detectedHost=\(detectedHost, privacy: .private) route=\(self.shortRouteLabel(for: detectedHost), privacy: .public)")
        inputTargetStatus = "Input auto-routed to \(detectedHost):\(port)"
        routeStatus = routeLabel(for: detectedHost)
    }

    func attachRenderer(_ view: ClientPixelBufferRenderView) {
        renderView = view
    }

    func updateScrollRailSamplePoint(_ point: CGPoint?) {
        scrollRailSamplePoint = point
        guard point != nil else {
            scrollRailLineBrightness = 0.86
            return
        }
        updateScrollRailLineBrightnessIfNeeded(force: true)
    }

    private func updateScrollRailLineBrightnessIfNeeded(force: Bool = false) {
        guard let latestVideoPixelBuffer,
              let scrollRailSamplePoint,
              let luminance = sampleLuminance(in: latestVideoPixelBuffer, at: scrollRailSamplePoint) else {
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastScrollRailSampleAt) >= 0.08 else { return }
        lastScrollRailSampleAt = now

        let target = min(max(1 - luminance, 0.22), 0.90)
        let smoothing = force ? 0.46 : 0.24
        let next = (scrollRailLineBrightness * (1 - smoothing)) + (target * smoothing)
        guard abs(next - scrollRailLineBrightness) >= 0.012 else { return }
        scrollRailLineBrightness = next
    }

    private func sampleLuminance(in pixelBuffer: CVPixelBuffer, at normalizedPoint: CGPoint) -> Double? {
        guard normalizedPoint.x.isFinite,
              normalizedPoint.y.isFinite,
              normalizedPoint.x >= 0,
              normalizedPoint.x <= 1,
              normalizedPoint.y >= 0,
              normalizedPoint.y <= 1 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
           let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            return sampleLumaPlane(
                baseAddress: baseAddress,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                normalizedPoint: normalizedPoint
            )
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        guard pixelFormat == kCVPixelFormatType_32BGRA ||
              pixelFormat == kCVPixelFormatType_32RGBA else {
            return nil
        }

        return sampleRGBPlane(
            baseAddress: baseAddress,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat,
            normalizedPoint: normalizedPoint
        )
    }

    private func sampleLumaPlane(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        normalizedPoint: CGPoint
    ) -> Double? {
        guard width > 0, height > 0 else { return nil }

        let centerX = min(max(Int(normalizedPoint.x * CGFloat(width - 1)), 0), width - 1)
        let centerY = min(max(Int(normalizedPoint.y * CGFloat(height - 1)), 0), height - 1)
        let radius = 8
        let minX = max(centerX - radius, 0)
        let maxX = min(centerX + radius, width - 1)
        let minY = max(centerY - radius, 0)
        let maxY = min(centerY + radius, height - 1)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        var total = 0
        var count = 0
        for y in minY...maxY {
            let row = bytes + (y * bytesPerRow)
            for x in minX...maxX {
                total += Int(row[x])
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return Double(total) / Double(count * 255)
    }

    private func sampleRGBPlane(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: OSType,
        normalizedPoint: CGPoint
    ) -> Double? {
        guard width > 0, height > 0 else { return nil }

        let centerX = min(max(Int(normalizedPoint.x * CGFloat(width - 1)), 0), width - 1)
        let centerY = min(max(Int(normalizedPoint.y * CGFloat(height - 1)), 0), height - 1)
        let radius = 5
        let minX = max(centerX - radius, 0)
        let maxX = min(centerX + radius, width - 1)
        let minY = max(centerY - radius, 0)
        let maxY = min(centerY + radius, height - 1)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        var total = 0.0
        var count = 0
        for y in minY...maxY {
            let row = bytes + (y * bytesPerRow)
            for x in minX...maxX {
                let pixel = row + (x * 4)
                let red: UInt8
                let green: UInt8
                let blue: UInt8
                if pixelFormat == kCVPixelFormatType_32BGRA {
                    blue = pixel[0]
                    green = pixel[1]
                    red = pixel[2]
                } else {
                    red = pixel[0]
                    green = pixel[1]
                    blue = pixel[2]
                }
                total += (0.2126 * Double(red)) + (0.7152 * Double(green)) + (0.0722 * Double(blue))
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return total / Double(count * 255)
    }

    private func prepareInputSenderForUserInput(reason: String) -> Bool {
        guard isInputReady else { return false }
        if shouldRefreshInputSenderBeforeNextInput || sender == nil {
            recreateInputSenderIfPossible(reason: reason, force: true)
        }
        return sender != nil
    }

    private func makeInputSender(host: String, port: UInt16, reason: String) -> ClientInputSender {
        ClientInputSender(
            host: host,
            port: port,
            credentialID: credentialID,
            sharedSecret: sanitizedPairingCode,
            onReady: { [weak self] in
                Task { @MainActor in
                    guard let self,
                          self.isConnected || self.isConnectionAttemptInProgress,
                          self.activeInputHost == host else {
                        return
                    }
                    Self.routeLogger.info("Input UDP sender ready. reason=\(reason, privacy: .public) host=\(host, privacy: .private) port=\(port, privacy: .public)")
                    self.sendStartupRouteProbe(reason: "input UDP ready")
                }
            },
            onFailed: { error in
                Self.routeLogger.error("Input UDP sender failed. reason=\(reason, privacy: .public) host=\(host, privacy: .private) port=\(port, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            }
        )
    }

    private func sendStartupRouteProbe(reason: String) {
        guard sender != nil else { return }
        Self.routeLogger.info("Sending startup route probe. reason=\(reason, privacy: .public) host=\(self.activeInputHost, privacy: .private) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public)")
        requestHostKeyframe()
    }

    @discardableResult
    private func recreateInputSenderIfPossible(reason: String, force: Bool) -> Bool {
        guard isConnected,
              let port = activeInputPort else {
            return false
        }

        let host = ClientNetworkAddressPolicy.normalized(activeInputHost.isEmpty ? hostAddress : activeInputHost)
        guard !host.isEmpty else { return false }
        guard force || shouldRefreshInputSenderBeforeNextInput || sender == nil else { return true }

        sender = makeInputSender(host: host, port: port, reason: reason)
        activeInputHost = host
        inputTargetStatus = "Input to \(host):\(port)"
        shouldRefreshInputSenderBeforeNextInput = false
        Self.routeLogger.info("Refreshed input sender. reason=\(reason, privacy: .public) host=\(host, privacy: .private) port=\(port, privacy: .public)")
        return true
    }

    private func isCurrentVideoReceiver(_ receiver: ClientVideoReceiver?) -> Bool {
        guard let receiver, let currentReceiver = videoReceiver else { return false }
        return currentReceiver === receiver
    }

    func recordScenePhaseChange(_ phaseName: String) {
        logConnectionEvent("SwiftUI scenePhase changed to \(phaseName)")
    }

    private func logConnectionEvent(_ reason: String) {
        let now = Date()
        let lastFrameAge = lastDecodedFrameAt.map { now.timeIntervalSince($0) } ?? -1
        let connectedFor = connectionStartedAt == Date.distantPast ? -1 : now.timeIntervalSince(connectionStartedAt)
        let resumeGraceRemaining = max(0, ignoreConnectionHealthUntil.timeIntervalSince(now))
        let selectedHost = ClientNetworkAddressPolicy.normalized(hostAddress)
        let activeHost = ClientNetworkAddressPolicy.normalized(activeInputHost)
        let route = shortRouteLabel(for: activeInputHost.isEmpty ? hostAddress : activeInputHost)
        let visibleMode: String

        if hasDisplayedVideoFrame && (isConnectionAttemptInProgress || isAutomaticReconnectInProgress) {
            visibleMode = "blurred-reconnect"
        } else if isConnectionAttemptInProgress && !hasDisplayedVideoFrame {
            visibleMode = "initial-connecting"
        } else if isConnected {
            visibleMode = "live-video"
        } else {
            visibleMode = "disconnected"
        }

        Self.connectionLogger.info(
            """
            \(reason, privacy: .private) | \
            ui=\(visibleMode, privacy: .public) \
            connected=\(self.isConnected.description, privacy: .public) \
            connecting=\(self.isConnectionAttemptInProgress.description, privacy: .public) \
            autoReconnect=\(self.isAutomaticReconnectInProgress.description, privacy: .public) \
            hasFrame=\(self.hasDisplayedVideoFrame.description, privacy: .public) \
            sessionHasFrame=\(self.didReceiveVideoInCurrentSession.description, privacy: .public) \
            frames=\(self.decodedFramesInCurrentSession, privacy: .public) \
            lastFrameAge=\(lastFrameAge, privacy: .public) \
            connectedFor=\(connectedFor, privacy: .public) \
            foreground=\(self.isAppForeground.description, privacy: .public) \
            resumeGraceRemaining=\(resumeGraceRemaining, privacy: .public) \
            selectedHost=\(selectedHost, privacy: .private) \
            activeHost=\(activeHost, privacy: .private) \
            route=\(route, privacy: .public) \
            routeOverride=\(self.routeOverrideHost ?? "none", privacy: .private) \
            reconnectTask=\((self.reconnectTask != nil).description, privacy: .public) \
            watchdogTask=\((self.watchdogTask != nil).description, privacy: .public) \
            network=\(self.lastObservedNetworkInterfaces, privacy: .private) \
            device=\(self.deviceAddress, privacy: .private) \
            status=\(self.status, privacy: .private) \
            videoStatus=\(self.videoStatus, privacy: .private)
            """
        )
    }

    private func recordVideoFrame() {
        let wasFirstFrame = !didReceiveVideoInCurrentSession
        lastDecodedFrameAt = Date()
        didReceiveVideoInCurrentSession = true
        hasDisplayedVideoFrame = true
        initialNoVideoReconnectCount = 0
        decodedFramesInCurrentSession += 1

        if wasFirstFrame {
            ClientDiagnostics.connection("video.firstFrame localWiFiOnly=\(isConnectingOverLocalWiFi) expectedHost=\(ClientDiagnostics.identifierTag(pairedHostID)) credential=\(ClientDiagnostics.identifierTag(credentialID))")
            localWiFiSearchTask?.cancel()
            localWiFiSearchTask = nil
            initialRouteRefreshTask?.cancel()
            initialRouteRefreshTask = nil
            isConnectionAttemptInProgress = false
            isAutomaticReconnectInProgress = false
            let route = shortRouteLabel(for: activeInputHost.isEmpty ? hostAddress : activeInputHost)
            status = "Receiving video over \(route)"
            videoStatus = "First video frame received"
            Self.videoLogger.info("First decoded video frame received. route=\(route, privacy: .public) activeInputHost=\(self.activeInputHost, privacy: .private) elapsed=\(Date().timeIntervalSince(self.connectionStartedAt), privacy: .public)")
            logConnectionEvent("first decoded video frame received")
        } else if decodedFramesInCurrentSession % 300 == 0 {
            Self.videoLogger.info("Decoded video frame heartbeat. frames=\(self.decodedFramesInCurrentSession, privacy: .public) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public)")
            logConnectionEvent("decoded video heartbeat")
        }
    }

    private func startConnectionWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self?.checkConnectionHealth()
                }
            }
        }
    }

    private func startInitialRouteRefresh() {
        initialRouteRefreshTask?.cancel()
        initialRouteRefreshTask = Task { [weak self] in
            for attempt in 1...8 {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.isConnected,
                          !self.didReceiveVideoInCurrentSession else {
                        return
                    }
                    Self.routeLogger.info("Resending startup route probe. attempt=\(attempt, privacy: .public) host=\(self.activeInputHost, privacy: .private) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public)")
                    self.sendStartupRouteProbe(reason: "waiting for first video attempt \(attempt)")
                }
            }
        }
    }

    private func checkConnectionHealth() {
        guard isConnected else {
            logConnectionEvent("health check skipped: not connected")
            return
        }
        let now = Date()
        guard isAppForeground else {
            logConnectionEvent("health check skipped: app not foreground")
            return
        }
        guard now >= ignoreConnectionHealthUntil else {
            logConnectionEvent("health check skipped: foreground resume grace active")
            return
        }

        if didReceiveVideoInCurrentSession {
            guard let lastDecodedFrameAt,
                  now.timeIntervalSince(lastDecodedFrameAt) >= frozenVideoTimeout else {
                if now.timeIntervalSince(lastHealthLogAt) >= 10 {
                    lastHealthLogAt = now
                    Self.videoLogger.info("Video health ok. frames=\(self.decodedFramesInCurrentSession, privacy: .public) lastFrameAge=\(self.lastDecodedFrameAt.map { now.timeIntervalSince($0) } ?? -1, privacy: .public) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public)")
                }
                return
            }
            Self.videoLogger.warning("Video frozen. lastFrameAge=\(now.timeIntervalSince(lastDecodedFrameAt), privacy: .public) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public)")
            logConnectionEvent("health check detected frozen video; scheduling reconnect")
            scheduleReconnect(reason: reconnectReasonAfterRouteFailure(defaultReason: "Video froze. Reconnecting..."))
        } else if now.timeIntervalSince(connectionStartedAt) >= waitingTimeoutForCurrentRoute {
            let fallback = tailscaleFallbackHost(logSkip: true, requiresActiveVPN: false)
            Self.routeLogger.warning("Connection timed out waiting for first video frame. activeInputHost=\(self.activeInputHost, privacy: .private) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public) waited=\(now.timeIntervalSince(self.connectionStartedAt), privacy: .public) fallback=\(fallback ?? "none", privacy: .private)")
            routeDiagnostic = "Still waiting for Mac video over \(shortRouteLabel(for: activeInputHost)). Retrying quietly. Fallback: \(fallback ?? "none")"
            logConnectionEvent("health check timed out waiting for first video; scheduling reconnect")
            scheduleReconnect(reason: reconnectReasonAfterRouteFailure(defaultReason: "Still waiting for video. Reconnecting..."))
        }
    }

    /// `bypassCooldown` is for discovery-driven route switches: a fresh Bonjour
    /// result proves the network is live, so the health-check cooldown and the
    /// foreground-resume grace must not discard it.
    private func scheduleReconnect(reason: String, bypassCooldown: Bool = false) {
        logConnectionEvent("scheduleReconnect requested. reason=\(reason) bypassCooldown=\(bypassCooldown)")
        guard reconnectTask == nil else {
            logConnectionEvent("scheduleReconnect ignored: reconnect task already active. reason=\(reason)")
            return
        }
        let now = Date()
        guard isAppForeground else {
            Self.videoLogger.info("Skipped reconnect while app is not foregrounded. reason=\(reason, privacy: .public)")
            logConnectionEvent("scheduleReconnect skipped: app not foreground. reason=\(reason)")
            return
        }
        guard bypassCooldown || now >= ignoreConnectionHealthUntil else {
            Self.videoLogger.info("Skipped reconnect during foreground resume grace. reason=\(reason, privacy: .public)")
            logConnectionEvent("scheduleReconnect skipped: foreground resume grace. reason=\(reason)")
            return
        }
        guard bypassCooldown || now.timeIntervalSince(lastReconnectAttemptAt) >= reconnectCooldown else {
            logConnectionEvent("scheduleReconnect ignored: reconnect cooldown. reason=\(reason)")
            return
        }

        lastReconnectAttemptAt = now
        let selectedHost = ClientNetworkAddressPolicy.normalized(hostAddress)
        let currentHost = ClientNetworkAddressPolicy.normalized(activeInputHost.isEmpty ? hostAddress : activeInputHost)
        let isSameHostReconnect = selectedHost.isEmpty || currentHost.isEmpty || selectedHost == currentHost
        Self.videoLogger.warning("Scheduling reconnect. reason=\(reason, privacy: .public) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public) frames=\(self.decodedFramesInCurrentSession, privacy: .public) sameHost=\(isSameHostReconnect.description, privacy: .public)")
        let shouldPreserveDisplayedFrame = didReceiveVideoInCurrentSession || hasDisplayedVideoFrame

        if !shouldPreserveDisplayedFrame {
            guard initialNoVideoReconnectCount < maximumInitialNoVideoReconnects else {
                Self.videoLogger.error("Stopped initial connection after repeated attempts without video. attempts=\(self.initialNoVideoReconnectCount, privacy: .public) route=\(self.shortRouteLabel(for: self.activeInputHost), privacy: .public)")
                logConnectionEvent("initial connection retry limit reached; stopping")
                // Read the route before stopping clears it.
                let guidance = initialConnectionFailureGuidance()
                stopCurrentConnectionForManualSwitch()
                status = guidance.status
                videoStatus = "No video received"
                routeDiagnostic = guidance.diagnostic
                return
            }
            initialNoVideoReconnectCount += 1
            hasDisplayedVideoFrame = false
            renderView?.clear()
        }

        if shouldPreserveDisplayedFrame {
            status = reason
            videoStatus = "Reconnecting"
            shouldSuppressNextFocusedWindowZoomAfterReconnect = true
        } else {
            status = "Connecting"
            videoStatus = "Waiting for Mac video"
            shouldSuppressNextFocusedWindowZoomAfterReconnect = false
        }
        isConnectionAttemptInProgress = true
        isAutomaticReconnectInProgress = shouldPreserveDisplayedFrame
        logConnectionEvent("scheduleReconnect accepted. preserveDisplayedFrame=\(shouldPreserveDisplayedFrame) reason=\(reason)")
        reconnectTask = Task { [weak self] in
            await self?.restartConnectionPreservingAutoReconnect()
            await MainActor.run {
                self?.logConnectionEvent("reconnect task completed")
                self?.reconnectTask = nil
            }
        }
    }

    /// Chooses the give-up message from what actually blocked the attempt. No
    /// video usually means the Mac is asleep, on another network, or unreachable
    /// through the selected route; a stale credential is only one possibility.
    private func initialConnectionFailureGuidance() -> (status: String, diagnostic: String) {
        let routeHost = ClientNetworkAddressPolicy.normalized(activeInputHost.isEmpty ? hostAddress : activeInputHost)
        let route = shortRouteLabel(for: routeHost)
        let interfaces = Self.ipInterfaceSummary()
        if ClientNetworkAddressPolicy.isTailscaleHost(routeHost), !Self.hasTailscaleIPAddress() {
            return (
                "Tailscale is off on this iPhone. Turn it on, or connect both devices to the same Wi-Fi.",
                "No video arrived over \(route) and this iPhone has no active Tailscale tunnel. Interfaces: \(interfaces)"
            )
        }
        if localNetworkAccessDenied, !ClientNetworkAddressPolicy.isTailscaleHost(routeHost) {
            return (
                Self.localNetworkDeniedStatus,
                "iOS reported that Local Network access is denied for PocketCtrl, so \(route) traffic is blocked. Interfaces: \(interfaces)"
            )
        }
        return (
            "Couldn't reach your Mac. Make sure it's awake and hosting, and both devices share a Wi-Fi or Tailscale network.",
            "No authenticated video arrived over \(route). If the Mac shows this iPhone as not approved, pair it again. Interfaces: \(interfaces)"
        )
    }

    private func restartConnectionPreservingAutoReconnect() async {
        logConnectionEvent("restartConnectionPreservingAutoReconnect started")
        let shouldAutoReconnect = UserDefaults.standard.bool(forKey: Self.shouldAutoReconnectKey)
        stopCurrentConnectionForReconnect()
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else {
            logConnectionEvent("restartConnectionPreservingAutoReconnect cancelled before reconnect")
            return
        }
        UserDefaults.standard.set(shouldAutoReconnect, forKey: Self.shouldAutoReconnectKey)
        logConnectionEvent("restartConnectionPreservingAutoReconnect reconnecting now")
        connect()
    }

    private func stopCurrentConnectionForReconnect() {
        logConnectionEvent("stopCurrentConnectionForReconnect started")
        setRemoteAudioEnabled(false)
        requestZoomRegion(nil)
        videoReceiver?.stop()
        videoReceiver = nil
        stopAudio()
        sender = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        initialRouteRefreshTask?.cancel()
        initialRouteRefreshTask = nil
        activeInputHost = ""
        activeInputPort = nil
        activeZoomRegion = nil
        isRegionZoomActive = false
        resetMouseInteractionState(clearReconnectZoomSuppression: false)
        isConnected = false
        inputTargetStatus = "Input target not detected"
        lastDecodedFrameAt = nil
        didReceiveVideoInCurrentSession = false
        decodedFramesInCurrentSession = 0
        lastHealthLogAt = Date.distantPast
        logConnectionEvent("stopCurrentConnectionForReconnect finished")
    }

    private func stopCurrentConnectionForManualSwitch() {
        resetLocalWiFiAttempt()
        logConnectionEvent("stopCurrentConnectionForManualSwitch started")
        // A manual switch starts a fresh attempt; a discovery handoff that
        // arrives seconds later must not be held back by an older cooldown.
        lastReconnectAttemptAt = Date.distantPast
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectKey)
        shouldReconnectCurrentSession = false
        setRemoteAudioEnabled(false)
        requestZoomRegion(nil)
        videoReceiver?.stop()
        videoReceiver = nil
        stopAudio()
        sender = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        initialRouteRefreshTask?.cancel()
        initialRouteRefreshTask = nil
        activeInputHost = ""
        routeOverrideHost = nil
        activeInputPort = nil
        activeZoomRegion = nil
        isRegionZoomActive = false
        focusedWindowRegion = nil
        resetMouseInteractionState()
        resetPointerPublishState()
        isConnected = false
        isConnectionAttemptInProgress = false
        isAutomaticReconnectInProgress = false
        inputTargetStatus = "Input target not detected"
        lastDecodedFrameAt = nil
        didReceiveVideoInCurrentSession = false
        decodedFramesInCurrentSession = 0
        lastHealthLogAt = Date.distantPast
        hasDisplayedVideoFrame = false
        remoteVideoSize = CGSize(width: 16, height: 9)
        renderView?.clear()
        logConnectionEvent("stopCurrentConnectionForManualSwitch finished")
    }

    private func startAudioIfPossible() {
        guard audioEnabled else {
            audioStatus = "Audio off"
            return
        }
        guard isConnected || videoReceiver != nil else {
            audioStatus = "Audio waiting for connection"
            return
        }
        guard audioReceiver == nil else { return }
        guard let audioPortValue = UInt16(audioPort) else {
            audioStatus = "Audio port must be between 1 and 65535"
            setAudioEnabledWithoutHandling(false)
            return
        }

        do {
            let expectedHost = ClientNetworkAddressPolicy.normalized(activeInputHost.isEmpty ? hostAddress : activeInputHost)
            guard credentialAllowsAudio else {
                audioStatus = "Audio was not allowed for this device"
                setAudioEnabledWithoutHandling(false)
                return
            }
            let receiver = try ClientAudioReceiver(
                port: audioPortValue,
                expectedSourceHost: expectedHost,
                credentialID: credentialID,
                credentialSecret: sanitizedPairingCode
            )
            receiver.onStatus = { [weak self] status in
                Task { @MainActor in
                    self?.audioStatus = status
                }
            }
            audioReceiver = receiver
            receiver.start()
            audioStatus = "Waiting for UDP audio on \(audioPortValue)"
        } catch {
            audioReceiver = nil
            audioStatus = "Audio failed: \(error.localizedDescription)"
            setAudioEnabledWithoutHandling(false)
        }
    }

    private func stopAudio() {
        audioReceiver?.stop()
        audioReceiver = nil
        audioStatus = "Audio off"
    }

    private func setAudioEnabledWithoutHandling(_ value: Bool) {
        isUpdatingAudioEnabledInternally = true
        audioEnabled = value
        isUpdatingAudioEnabledInternally = false
    }

    private var sanitizedPairingCode: String {
        pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDeviceCredentialUsable: Bool {
        sanitizedPairingCode.count >= 32 && !credentialID.isEmpty
    }

    private static func loadSavedMacs() -> [ClientSavedMac] {
        guard let data = UserDefaults.standard.data(forKey: savedMacsKey) else { return [] }
        return (try? JSONDecoder().decode([ClientSavedMac].self, from: data)) ?? []
    }

    private func saveSavedMacs() {
        let orderedMacs = savedMacs.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
        savedMacs = orderedMacs
        if let data = try? JSONEncoder().encode(orderedMacs) {
            UserDefaults.standard.set(data, forKey: Self.savedMacsKey)
        }
    }

    private func credentialKeychainKey(for credentialID: String) -> String {
        Self.savedMacCredentialPrefix + credentialID
    }

    private func defaultMacName(for hostID: String) -> String {
        let suffix = hostID.prefix(6)
        return suffix.isEmpty ? "My Mac" : "Mac \(suffix)"
    }

    @discardableResult
    private func upsertSavedMacFromCurrent(
        name: String? = nil,
        updateLastConnected: Bool = true,
        persistCredential: Bool = false
    ) -> ClientSavedMac? {
        let id = pairedHostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let existing = savedMacs.first(where: { $0.id == id })
        if persistCredential {
            let credentialKey = credentialKeychainKey(for: credentialID)
            guard currentCredentialIsPersistent,
                  isDeviceCredentialUsable,
                  ClientKeychainStore.set(sanitizedPairingCode, forKey: credentialKey) else {
                if !credentialID.isEmpty {
                    ClientKeychainStore.delete(forKey: credentialKey)
                }
                credentialID = ""
                credentialAllowsInput = false
                credentialAllowsClipboard = false
                credentialAllowsAudio = false
                markCurrentCredentialPersistenceFailure()
                return nil
            }
        }

        let now = Date()
        if let index = savedMacs.firstIndex(where: { $0.id == id }) {
            savedMacs[index].name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? savedMacs[index].name
            savedMacs[index].localHostAddress = localHostAddress
            savedMacs[index].tailscaleHostAddress = tailscaleHostAddress
            savedMacs[index].videoPort = videoPort
            savedMacs[index].audioPort = audioPort
            savedMacs[index].inputPort = inputPort
            savedMacs[index].wakeMACAddress = wakeMACAddress
            savedMacs[index].credentialID = credentialID
            savedMacs[index].allowsRemoteInput = credentialAllowsInput
            savedMacs[index].allowsClipboard = credentialAllowsClipboard
            savedMacs[index].allowsAudio = credentialAllowsAudio
            if updateLastConnected {
                savedMacs[index].lastConnectedAt = now
            }
            saveSavedMacs()
            UserDefaults.standard.set(id, forKey: Self.selectedSavedMacIDKey)
            if persistCredential,
               let previousCredentialID = existing?.credentialID.nonEmpty,
               previousCredentialID != credentialID,
               !savedMacs.contains(where: { $0.credentialID == previousCredentialID }) {
                ClientKeychainStore.delete(forKey: credentialKeychainKey(for: previousCredentialID))
            }
            return savedMacs[index]
        }

        let savedMac = ClientSavedMac(
            id: id,
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaultMacName(for: id),
            localHostAddress: localHostAddress,
            tailscaleHostAddress: tailscaleHostAddress,
            videoPort: videoPort,
            audioPort: audioPort,
            inputPort: inputPort,
            wakeMACAddress: wakeMACAddress,
            credentialID: credentialID,
            allowsRemoteInput: credentialAllowsInput,
            allowsClipboard: credentialAllowsClipboard,
            allowsAudio: credentialAllowsAudio,
            lastConnectedAt: now
        )
        savedMacs.append(savedMac)
        saveSavedMacs()
        UserDefaults.standard.set(id, forKey: Self.selectedSavedMacIDKey)
        if persistCredential,
           let previousCredentialID = existing?.credentialID.nonEmpty,
           previousCredentialID != credentialID,
           !savedMacs.contains(where: { $0.credentialID == previousCredentialID }) {
            ClientKeychainStore.delete(forKey: credentialKeychainKey(for: previousCredentialID))
        }
        return savedMac
    }

    private func applySavedMac(_ savedMac: ClientSavedMac) {
        restoreSavedMac(savedMac, reason: "manual selection")
        startLocalDiscoveryIfPossible()
    }

    private func restoreSavedMac(_ savedMac: ClientSavedMac, reason: String) {
        resetLocalWiFiAttempt()
        pairedHostID = savedMac.id
        localHostAddress = savedMac.localHostAddress
        tailscaleHostAddress = savedMac.tailscaleHostAddress
        videoPort = savedMac.videoPort
        audioPort = savedMac.audioPort
        inputPort = savedMac.inputPort
        wakeMACAddress = savedMac.wakeMACAddress
        credentialID = savedMac.credentialID
        credentialAllowsInput = savedMac.allowsRemoteInput
        credentialAllowsClipboard = savedMac.allowsClipboard
        credentialAllowsAudio = savedMac.allowsAudio
        pairingCode = ""
        switch ClientKeychainStore.readString(forKey: credentialKeychainKey(for: savedMac.credentialID)) {
        case let .value(savedCredential) where savedCredential.count >= 32:
            ClientDiagnostics.connection("pairing.restore result=loaded expectedHost=\(ClientDiagnostics.identifierTag(savedMac.id)) credential=\(ClientDiagnostics.identifierTag(savedMac.credentialID))")
            pairingCode = savedCredential
            currentCredentialIsPersistent = true
            savedCredentialReadNeedsRetry = false
        case let .failure(status):
            ClientDiagnostics.connection("pairing.restore result=keychainError osStatus=\(status) expectedHost=\(ClientDiagnostics.identifierTag(savedMac.id))")
            savedCredentialReadNeedsRetry = true
            markSavedCredentialTemporarilyUnavailable()
        case .missing, .value(_):
            ClientDiagnostics.connection("pairing.restore result=missingOrInvalid expectedHost=\(ClientDiagnostics.identifierTag(savedMac.id))")
            savedCredentialReadNeedsRetry = false
            markSavedCredentialUnavailable()
        }
        ClientDiagnostics.write("saved Mac applied reason=\(reason) hasLocalHost=\(!savedMac.localHostAddress.isEmpty) hasTailscaleHost=\(!savedMac.tailscaleHostAddress.isEmpty)")
        routeOverrideHost = nil
        hostAddress = preferredConnectionHost()
        routeStatus = routeLabel(for: hostAddress)
        UserDefaults.standard.set(savedMac.id, forKey: Self.selectedSavedMacIDKey)
    }

    @discardableResult
    private func applyPairingQueryItems(_ queryItems: [URLQueryItem], savePairing: Bool = true, connectedHost: String? = nil) -> Bool {
        func value(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        localHostAddress = IPNetwork.pairingLocalHost(advertised: value("host"), connectedHost: connectedHost) ?? ""
        tailscaleHostAddress = IPNetwork.pairingTailscaleHost(advertised: value("tailscale"), connectedHost: connectedHost)
        if let id = value("id"), !id.isEmpty {
            pairedHostID = id
        }
        routeOverrideHost = nil
        startLocalDiscoveryIfPossible()
        let preferredHost = preferredConnectionHost()
        if !preferredHost.isEmpty {
            hostAddress = preferredHost
        } else {
            hostAddress = localHostAddress
        }
        if let video = value("video"), UInt16(video) != nil {
            videoPort = video
        } else {
            videoPort = "5555"
        }
        if let audio = value("audio"), UInt16(audio) != nil {
            audioPort = audio
        } else {
            audioPort = "5557"
        }
        if let input = value("input"), UInt16(input) != nil {
            inputPort = input
        } else {
            inputPort = "5556"
        }
        wakeMACAddress = value("mac") ?? ""
        if savePairing {
            guard upsertSavedMacFromCurrent(name: value("name"), persistCredential: true) != nil else {
                return false
            }
        }
        routeDiagnostic = "QR saved Mac \(pairedHostID.isEmpty ? "unknown" : pairedHostID), local \(localHostAddress.isEmpty ? "none" : localHostAddress), Tailscale \(tailscaleHostAddress.isEmpty ? "none" : tailscaleHostAddress). Interfaces: \(Self.ipInterfaceSummary())"
        Self.routeLogger.info("Applied pairing QR. pairedHostID=\(self.pairedHostID, privacy: .private) localHost=\(self.localHostAddress, privacy: .private) tailscaleHost=\(self.tailscaleHostAddress, privacy: .private) preferred=\(preferredHost, privacy: .private) deviceLocal=\(Self.localIPAddress() ?? "none", privacy: .private) tailscaleActive=\(Self.hasTailscaleIPAddress().description, privacy: .public) interfaces=\(Self.ipInterfaceSummary(), privacy: .private)")
        ClientDiagnostics.write("pairing QR applied hasName=\(value("name") != nil) hasLocalHost=\(!localHostAddress.isEmpty) hasTailscaleHost=\(!tailscaleHostAddress.isEmpty) videoPort=\(videoPort) inputPort=\(inputPort)")
        return true
    }

    private func cancelManualPairingAttempt() {
        manualPairingTask?.cancel()
        manualPairingTask = nil
        manualPairingAttemptID = UUID()
    }

    private func prepareForNewPairingAttempt() {
        resetLocalWiFiAttempt()
        pairingCode = ""
        credentialID = ""
        credentialAllowsInput = false
        credentialAllowsClipboard = false
        credentialAllowsAudio = false
        currentCredentialIsPersistent = false
        savedCredentialReadNeedsRetry = false
        shouldReconnectCurrentSession = false
        pairingApplicationFailureMessage = nil
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectKey)
    }

    private func markCurrentCredentialPersistenceFailure() {
        currentCredentialIsPersistent = false
        savedCredentialReadNeedsRetry = false
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectKey)
        pairingCode = ""
        shouldReconnectCurrentSession = false
        pairingApplicationFailureMessage = "PocketCtrl could not securely save this device. Check the app's signing or reinstall it, then pair again."
        manualPairingStatus = pairingApplicationFailureMessage ?? "Secure credential storage is unavailable"
        status = manualPairingStatus
        ClientDiagnostics.write("device credential could not be persisted securely")
    }

    private func markSavedCredentialUnavailable() {
        currentCredentialIsPersistent = false
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectKey)
        manualPairingStatus = "This Mac's saved credential could not be loaded securely. Pair this iPhone again."
        status = "Pair this iPhone with the Mac again"
        ClientDiagnostics.write("saved device credential was unavailable during restore")
    }

    private func markSavedCredentialTemporarilyUnavailable() {
        currentCredentialIsPersistent = false
        manualPairingStatus = "Unlock this iPhone and return to PocketCtrl. The saved credential has not been deleted."
        status = "Waiting for secure credential storage"
        ClientDiagnostics.write("saved device credential read will retry when the app becomes active")
    }

    @discardableResult
    private func retrySavedCredentialLoadIfNeeded() -> Bool {
        guard savedCredentialReadNeedsRetry,
              let selectedID = UserDefaults.standard.string(forKey: Self.selectedSavedMacIDKey),
              let savedMac = savedMacs.first(where: { $0.id == selectedID }) else {
            return false
        }

        switch ClientKeychainStore.readString(forKey: credentialKeychainKey(for: savedMac.credentialID)) {
        case let .value(savedCredential) where savedCredential.count >= 32:
            pairingCode = savedCredential
            credentialID = savedMac.credentialID
            credentialAllowsInput = savedMac.allowsRemoteInput
            credentialAllowsClipboard = savedMac.allowsClipboard
            credentialAllowsAudio = savedMac.allowsAudio
            currentCredentialIsPersistent = true
            savedCredentialReadNeedsRetry = false
            ClientDiagnostics.write("saved device credential restored after a temporary read failure")
            return true
        case .failure:
            return false
        case .missing, .value(_):
            savedCredentialReadNeedsRetry = false
            markSavedCredentialUnavailable()
            return false
        }
    }

    func refreshDeviceAddress() {
        deviceAddress = Self.localIPAddress() ?? "Unknown IP"
        routeStatus = routeLabel(for: preferredConnectionHost())
    }

    private func configureLocalDiscoveryCallbacks() {
        localDiscoveryBrowser.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.localDiscoveryStatus = status
            }
        }
        localDiscoveryBrowser.onLocalNetworkAccessDenied = { [weak self] denied in
            Task { @MainActor in
                self?.handleLocalNetworkAccessDenied(denied)
            }
        }
        localDiscoveryBrowser.onHostResolved = { [weak self] host in
            Task { @MainActor in
                guard let self else { return }
                if self.manualPairingDiscoveryActive {
                    self.manualPairingDiscoveredHosts[host.hostID] = host
                    self.manualPairingStatus = "Found \(host.hostName ?? "PocketCtrl host"). Waiting for approval..."
                } else {
                    self.applyDiscoveredHost(host)
                }
            }
        }
    }

    private func handleLocalNetworkAccessDenied(_ denied: Bool) {
        if localNetworkAccessDenied != denied {
            ClientDiagnostics.connection("discovery.localNetworkAccess denied=\(denied) localWiFiOnly=\(isConnectingOverLocalWiFi) attempting=\(isConnectionAttemptInProgress)")
        }
        localNetworkAccessDenied = denied
        guard denied else { return }
        // A local-only attempt cannot succeed while iOS blocks LAN traffic.
        // Fail now with Settings guidance instead of after the full timeout.
        if isConnectingOverLocalWiFi, isConnectionAttemptInProgress,
           !localWiFiSearchFailed, !didReceiveVideoInCurrentSession {
            failLocalWiFiAttempt(status: Self.localNetworkDeniedStatus)
        }
    }

    private func startLocalDiscoveryIfPossible() {
        let id = pairedHostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            ClientDiagnostics.connection("discovery.skipped reason=missingPairedHostIdentity credentialUsable=\(isDeviceCredentialUsable)")
            localDiscoveryBrowser.stop()
            if isDeviceCredentialUsable || !localHostAddress.isEmpty || !tailscaleHostAddress.isEmpty {
                localDiscoveryStatus = "Rescan the Mac QR to enable local Wi-Fi auto-detect."
                if routeDiagnostic == "No route decision yet" {
                    routeDiagnostic = "Saved pairing is missing the Mac ID added in the latest app version. Rescan the Mac QR once."
                }
            } else {
                localDiscoveryStatus = "Local discovery waiting for pairing."
            }
            return
        }

        localDiscoveryBrowser.start(targetHostID: id)
    }

    private func applyDiscoveredHost(_ host: ClientDiscoveredHost) {
        guard host.hostID == pairedHostID else { return }
        let discoveredLocal = ClientNetworkAddressPolicy.normalized(host.localAddress)
        guard ClientNetworkAddressPolicy.isPrivateOrLocalAddress(discoveredLocal),
              !ClientNetworkAddressPolicy.isTailscaleAddress(discoveredLocal),
              !IPNetwork.isLoopback(discoveredLocal) else {
            ClientDiagnostics.connection("discovery.routeRejected reason=nonLocalAddress host=\(ClientDiagnostics.identifierTag(host.hostID))")
            localDiscoveryStatus = "Ignored non-local discovery address \(host.localAddress)."
            return
        }

        let wasWaitingForTailscale = isWaitingForTailscaleVPN
        ClientDiagnostics.connection("discovery.pairedRoute host=\(ClientDiagnostics.identifierTag(host.hostID)) savedAddressChanged=\(localHostAddress != discoveredLocal) localWiFiOnly=\(isConnectingOverLocalWiFi) waitingForVPN=\(wasWaitingForTailscale)")
        discoveredLocalWiFiHost = discoveredLocal
        defer {
            // Even an unchanged Bonjour address can unblock a VPN attempt.
            // Previously the unchanged-address early return skipped this handoff.
            if (isConnectingOverLocalWiFi || wasWaitingForTailscale),
               isConnectionAttemptInProgress, !localWiFiSearchFailed {
                routeOverrideHost = discoveredLocal
                hostAddress = discoveredLocal
                if isConnected, activeInputHost != discoveredLocal {
                    scheduleReconnect(reason: "Found Mac on local Wi-Fi. Switching route...", bypassCooldown: true)
                } else if !isConnected, reconnectTask == nil {
                    connect()
                }
            }
        }

        let previousLocalHost = localHostAddress
        let discoveredTailscale = host.tailscaleAddress
            .map(ClientNetworkAddressPolicy.normalized)
            .flatMap { ClientNetworkAddressPolicy.isTailscaleHost($0) ? $0 : nil }
        let nextVideoPort = host.videoPort.flatMap { UInt16($0) == nil ? nil : $0 }
        let nextAudioPort = host.audioPort.flatMap { UInt16($0) == nil ? nil : $0 }
        let nextInputPort = host.inputPort.flatMap { UInt16($0) == nil ? nil : $0 }
        let hasRouteChange = previousLocalHost != discoveredLocal
            || (discoveredTailscale != nil && tailscaleHostAddress != discoveredTailscale)
            || (nextVideoPort != nil && videoPort != nextVideoPort)
            || (nextAudioPort != nil && audioPort != nextAudioPort)
            || (nextInputPort != nil && inputPort != nextInputPort)

        guard hasRouteChange else {
            localDiscoveryStatus = "Found paired Mac on local Wi-Fi: \(discoveredLocal)"
            return
        }

        localHostAddress = discoveredLocal
        if let tailscaleAddress = host.tailscaleAddress,
           ClientNetworkAddressPolicy.isTailscaleHost(tailscaleAddress) {
            tailscaleHostAddress = tailscaleAddress
        }
        if let videoPort = host.videoPort, UInt16(videoPort) != nil {
            self.videoPort = videoPort
        }
        if let audioPort = host.audioPort, UInt16(audioPort) != nil {
            self.audioPort = audioPort
        }
        if let inputPort = host.inputPort, UInt16(inputPort) != nil {
            self.inputPort = inputPort
        }

        routeOverrideHost = nil
        routeStatus = routeLabel(for: preferredConnectionHost())
        if currentCredentialIsPersistent {
            upsertSavedMacFromCurrent(updateLastConnected: false)
        }
        localDiscoveryStatus = "Found paired Mac on local Wi-Fi: \(discoveredLocal)"
        routeDiagnostic = "Local discovery found paired Mac \(host.hostID) at \(discoveredLocal). Interfaces: \(Self.ipInterfaceSummary())"
        Self.routeLogger.info("Local discovery resolved paired Mac. pairedHostID=\(host.hostID, privacy: .private) localHost=\(discoveredLocal, privacy: .private) previousLocalHost=\(previousLocalHost, privacy: .private)")

        // If the phone is already connected through a slower route, switch once
        // the paired Mac is proven to be reachable on the LAN. This mirrors the
        // RustDesk-style model: identity is stable, transport is replaceable.
        let deviceInterface = Self.localIPInterface(from: Self.ipInterfaceAddresses())
        if isConnected,
           activeInputHost != discoveredLocal,
           ClientNetworkAddressPolicy.shouldTryLocalRoute(localHost: discoveredLocal, deviceHost: deviceInterface?.address ?? "", deviceNetmask: deviceInterface?.netmask) {
            hostAddress = discoveredLocal
            scheduleReconnect(reason: "Found Mac on local Wi-Fi. Switching route...", bypassCooldown: true)
        } else if !isConnected, hostAddress != discoveredLocal {
            hostAddress = preferredConnectionHost()
        }
    }

    private struct ManualPairingCandidate: Hashable {
        let name: String
        let host: String
        let routeDescription: String
    }

    private struct ManualPairingRaceResult {
        let response: MobileManualPairingResponse
        let candidate: ManualPairingCandidate
    }

    private struct ManualPairingAttemptResult {
        let response: MobileManualPairingResponse?
        let candidate: ManualPairingCandidate
        let errorMessage: String?
    }

    private func manualPairingCandidates(invitation: DecodedPairingInvitationCode) -> [ManualPairingCandidate] {
        var candidates: [ManualPairingCandidate] = []

        func appendLocal(_ host: String?, name: String) {
            let normalized = ClientNetworkAddressPolicy.normalized(host ?? "")
            guard !normalized.isEmpty,
                  ClientNetworkAddressPolicy.isPrivateOrLocalAddress(normalized),
                  !IPNetwork.isLoopback(normalized),
                  !Self.ipInterfaceAddresses().contains(where: { $0.address == normalized }),
                  !ClientNetworkAddressPolicy.isTailscaleAddress(normalized) else {
                return
            }
            candidates.append(ManualPairingCandidate(name: name, host: normalized, routeDescription: "Local Wi-Fi"))
        }

        appendLocal(localHostAddress, name: "QR Mac")
        appendLocal(hostAddress, name: "Entered Mac")

        for savedMac in savedMacs {
            appendLocal(savedMac.localHostAddress, name: savedMac.name)
        }

        for host in manualPairingDiscoveredHosts.values {
            let name = host.hostName ?? "Nearby Mac"
            appendLocal(host.localAddress, name: name)
        }

        if Self.hasTailscaleIPAddress() {
            for tailscaleHost in IPNetwork.pairingTailscaleCandidates(codeHost: invitation.tailscaleAddress, advertisedHost: tailscaleHostAddress) {
                guard !Self.ipInterfaceAddresses().contains(where: { $0.address == tailscaleHost }) else { continue }
                candidates.append(
                    ManualPairingCandidate(name: "Tailscale Mac", host: tailscaleHost, routeDescription: "Tailscale")
                )
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.host).inserted }
    }

    private func raceManualPairingRequests(
        code: String,
        candidates: [ManualPairingCandidate]
    ) async throws -> ManualPairingRaceResult {
        try await withThrowingTaskGroup(of: ManualPairingAttemptResult.self) { group in
            for candidate in candidates {
                group.addTask {
                    if candidate.routeDescription == "Tailscale", candidates.contains(where: { $0.routeDescription == "Local Wi-Fi" }) {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    guard !Task.isCancelled else {
                        return ManualPairingAttemptResult(response: nil, candidate: candidate, errorMessage: nil)
                    }
                    do {
                        let response = try await MobileManualPairingTransport.request(
                            code: code,
                            viewerName: self.approvalViewerDeviceName,
                            host: candidate.host
                        )
                        return ManualPairingAttemptResult(response: response, candidate: candidate, errorMessage: nil)
                    } catch {
                        return ManualPairingAttemptResult(response: nil, candidate: candidate, errorMessage: error.localizedDescription)
                    }
                }
            }

            var failures: [ManualPairingAttemptResult] = []
            while let result = try await group.next() {
                if let response = result.response {
                    group.cancelAll()
                    return ManualPairingRaceResult(response: response, candidate: result.candidate)
                }
                if let errorMessage = result.errorMessage {
                    failures.append(
                        ManualPairingAttemptResult(
                            response: nil,
                            candidate: result.candidate,
                            errorMessage: errorMessage
                        )
                    )
                }
            }
            let messages = failures.compactMap(\.errorMessage)
            let message = messages.first(where: { $0.localizedCaseInsensitiveContains("denied") || $0.localizedCaseInsensitiveContains("did not approve") })
                ?? messages.first(where: { $0.localizedCaseInsensitiveContains("expired") })
                ?? messages.first(where: { $0.localizedCaseInsensitiveContains("incorrect") })
                    .map { _ in "That pairing code expired or is no longer active. Generate a new one on the Mac." }
                ?? (failures.contains(where: { $0.candidate.routeDescription == "Tailscale" })
                    ? "This Mac is not reachable through your current tailnet. Your Tailscale access rules may be blocking PocketCtrl on port 47778."
                    : messages.first ?? "No Mac approved the request.")
            throw MobileManualPairingClientError(message: message)
        }
    }

    private static func defaultViewerDeviceName() -> String {
        sanitizedViewerDeviceName(UIDevice.current.name) ?? "iPhone"
    }

    private static func sanitizedViewerDeviceName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(48))
    }

    private func preferredConnectionHost(logDecision: Bool = false) -> String {
        if isConnectingOverLocalWiFi {
            let device = Self.localIPInterface(from: Self.ipInterfaceAddresses())
            let localHost = ClientNetworkAddressPolicy.localWiFiHost(
                savedHost: localHostAddress,
                discoveredHost: discoveredLocalWiFiHost,
                deviceHost: device?.address ?? "",
                deviceNetmask: device?.netmask
            ) ?? ""
            if logDecision {
                routeDiagnostic = localHost.isEmpty
                    ? "Local Wi-Fi requested. Searching for the paired Mac; no usable local address yet."
                    : "Local Wi-Fi requested. Trying \(localHost); Tailscale fallback is disabled for this session."
                ClientDiagnostics.write("explicit local Wi-Fi route selected hasLocalHost=\(!localHost.isEmpty)")
            }
            return localHost
        }
        if let routeOverrideHost,
           !ClientNetworkAddressPolicy.normalized(routeOverrideHost).isEmpty {
            let selectedHost = ClientNetworkAddressPolicy.normalized(routeOverrideHost)
            logRouteDecisionIfNeeded(
                logDecision,
                reason: "override",
                selectedHost: selectedHost,
                deviceHost: Self.localIPAddress() ?? "",
                tailscaleActive: Self.hasTailscaleIPAddress()
            )
            return selectedHost
        }

        let interfaces = Self.ipInterfaceAddresses()
        let localHost = ClientNetworkAddressPolicy.normalized(localHostAddress)
        let tailscaleHost = ClientNetworkAddressPolicy.normalized(tailscaleHostAddress)
        let manualHost = ClientNetworkAddressPolicy.normalized(hostAddress)
        let deviceInterface = Self.localIPInterface(from: interfaces)
        let deviceHost = deviceInterface?.address ?? ""
        let tailscaleActive = Self.tailscaleIPAddress(from: interfaces) != nil

        let localRejection = ClientNetworkAddressPolicy.localRouteRejectionReason(
            localHost: localHost,
            deviceHost: deviceHost,
            deviceNetmask: deviceInterface?.netmask
        )

        if !localHost.isEmpty,
           ClientNetworkAddressPolicy.shouldTryLocalRoute(
               localHost: localHost,
               deviceHost: deviceHost,
               deviceNetmask: deviceInterface?.netmask
           ) {
            logRouteDecisionIfNeeded(
                logDecision,
                reason: "paired Mac is on the same local subnet",
                selectedHost: localHost,
                deviceHost: deviceHost,
                tailscaleActive: tailscaleActive,
                interfaces: interfaces
            )
            return localHost
        }

        if !tailscaleHost.isEmpty, tailscaleActive {
            logRouteDecisionIfNeeded(
                logDecision,
                reason: "local Wi-Fi is unavailable; Tailscale is active",
                selectedHost: tailscaleHost,
                deviceHost: deviceHost,
                tailscaleActive: tailscaleActive,
                interfaces: interfaces
            )
            return tailscaleHost
        }

        if !localHost.isEmpty, localRejection == nil {
            logRouteDecisionIfNeeded(
                logDecision,
                reason: "using saved local host",
                selectedHost: localHost,
                deviceHost: deviceHost,
                tailscaleActive: tailscaleActive,
                interfaces: interfaces
            )
            return localHost
        } else if !localHost.isEmpty {
            logRouteDecisionIfNeeded(
                logDecision,
                reason: localRejection.map { "not using saved local host because \($0)" } ?? "not using saved local host",
                selectedHost: manualHost,
                deviceHost: deviceHost,
                tailscaleActive: tailscaleActive,
                interfaces: interfaces
            )
        }

        let finalHost = !tailscaleHost.isEmpty ? tailscaleHost : manualHost
        logRouteDecisionIfNeeded(
            logDecision,
            reason: !tailscaleHost.isEmpty
                ? "Tailscale address is saved but its VPN interface is not currently visible"
                : "falling back to manual host",
            selectedHost: finalHost,
            deviceHost: deviceHost,
            tailscaleActive: tailscaleActive,
            interfaces: interfaces
        )
        return finalHost
    }

    private func reconnectReasonAfterRouteFailure(defaultReason: String) -> String {
        guard !isConnectingOverLocalWiFi else { return "Retrying local Wi-Fi..." }
        guard let fallback = tailscaleFallbackHost(logSkip: true),
              routeOverrideHost != fallback else {
            if tailscaleFallbackHost(logSkip: false, requiresActiveVPN: false) != nil,
               !Self.hasTailscaleIPAddress() {
                routeOverrideHost = nil
                let localHost = ClientNetworkAddressPolicy.normalized(localHostAddress)
                if !localHost.isEmpty {
                    hostAddress = localHost
                    routeStatus = routeLabel(for: localHost)
                }
                routeDiagnostic = "The local Wi-Fi stream stalled. Retrying LAN because Tailscale is off. Interfaces: \(Self.ipInterfaceSummary())"
                ClientDiagnostics.write("local route stalled; retrying lan because tailscale vpn is unavailable interfaces=\(Self.ipInterfaceSummary())")
                Self.routeLogger.warning("Local route stalled; keeping LAN because Tailscale VPN is unavailable. interfaces=\(Self.ipInterfaceSummary(), privacy: .private)")
                return "Video stalled. Retrying local Wi-Fi..."
            }
            return defaultReason
        }

        routeOverrideHost = fallback
        hostAddress = fallback
        routeStatus = routeLabel(for: fallback)
        Self.routeLogger.info("Local route failed; switching to Tailscale fallback. fallback=\(fallback, privacy: .private) interfaces=\(Self.ipInterfaceSummary(), privacy: .private)")
        return "Local Wi-Fi did not respond. Trying Tailscale..."
    }

    private func tailscaleFallbackHost(logSkip: Bool = false, requiresActiveVPN: Bool = true) -> String? {
        guard !isConnectingOverLocalWiFi else { return nil }
        let tailscaleHost = ClientNetworkAddressPolicy.normalized(tailscaleHostAddress)
        guard !tailscaleHost.isEmpty,
              ClientNetworkAddressPolicy.isTailscaleHost(tailscaleHost),
              activeInputHost != tailscaleHost else {
            return nil
        }

        let localHost = ClientNetworkAddressPolicy.normalized(localHostAddress)
        guard !localHost.isEmpty,
              activeInputHost == localHost else {
            return nil
        }
        guard Self.hasTailscaleIPAddress() || !requiresActiveVPN else {
            if logSkip {
                Self.routeLogger.warning("Skipped Tailscale fallback because iPhone has no active Tailscale address. tailscaleHost=\(tailscaleHost, privacy: .private) interfaces=\(Self.ipInterfaceSummary(), privacy: .private)")
                routeDiagnostic = "Skipped Tailscale fallback because VPN is off. Interfaces: \(Self.ipInterfaceSummary())"
            }
            return nil
        }

        return tailscaleHost
    }

    private func logRouteDecisionIfNeeded(
        _ shouldLog: Bool,
        reason: String,
        selectedHost: String,
        deviceHost: String,
        tailscaleActive: Bool,
        interfaces: [IPInterfaceAddress]? = nil
    ) {
        guard shouldLog else { return }
        let summary = interfaces.map(Self.ipInterfaceSummary(from:)) ?? Self.ipInterfaceSummary()
        routeDiagnostic = "\(reason). Selected \(shortRouteLabel(for: selectedHost)). iPhone \(deviceHost.isEmpty ? "no local IP" : deviceHost). Tailscale \(tailscaleActive ? "on" : "off"). Interfaces: \(summary)"
        ClientDiagnostics.write("route selected reason=\(reason) route=\(shortRouteLabel(for: selectedHost)) tailscaleActive=\(tailscaleActive) interfaces=\(summary)")
        Self.routeLogger.info("Route selected. reason=\(reason, privacy: .public) selected=\(selectedHost, privacy: .private) localHost=\(self.localHostAddress, privacy: .private) tailscaleHost=\(self.tailscaleHostAddress, privacy: .private) manualHost=\(self.hostAddress, privacy: .private) deviceLocal=\(deviceHost.isEmpty ? "none" : deviceHost, privacy: .private) tailscaleActive=\(tailscaleActive.description, privacy: .public) interfaces=\(summary, privacy: .private)")
    }

    private func routeLabel(for host: String) -> String {
        let normalized = ClientNetworkAddressPolicy.normalized(host)
        guard !normalized.isEmpty else { return "Route: automatic" }
        return "Route: \(shortRouteLabel(for: normalized))"
    }

    private func shortRouteLabel(for host: String) -> String {
        let normalized = ClientNetworkAddressPolicy.normalized(host)
        if !normalized.isEmpty, normalized == ClientNetworkAddressPolicy.normalized(localHostAddress) {
            return "local Wi-Fi"
        }
        if ClientNetworkAddressPolicy.isTailscaleHost(normalized) {
            return "Tailscale"
        }
        if ClientNetworkAddressPolicy.isPrivateOrLocalAddress(normalized) {
            return "local network"
        }
        return normalized
    }

    private var waitingTimeoutForCurrentRoute: TimeInterval {
        if tailscaleFallbackHost(requiresActiveVPN: false) != nil {
            return localRouteFallbackTimeout
        }
        return waitingVideoTimeout
    }

    private static func localIPAddress() -> String? {
        localIPInterface(from: ipInterfaceAddresses())?.address
    }

    private static func localIPAddress(from addresses: [IPInterfaceAddress]) -> String? {
        localIPInterface(from: addresses)?.address
    }

    private static func localIPInterface(from addresses: [IPInterfaceAddress]) -> IPInterfaceAddress? {
        if let primaryWiFi = addresses.first(where: { $0.name == "en0" }) {
            return primaryWiFi
        }

        if let secondary = addresses.first(where: { interface in
            interface.name == "en1" || interface.name.hasPrefix("bridge")
        }) {
            return secondary
        }

        return addresses.first {
            ClientNetworkAddressPolicy.isPrivateOrLocalAddress($0.address)
                && !ClientNetworkAddressPolicy.isTailscaleAddress($0.address)
                && !IPNetwork.isLoopback($0.address)
        }
    }

    private static func hasTailscaleIPAddress() -> Bool {
        tailscaleIPAddress(from: ipInterfaceAddresses()) != nil
    }

    private static func tailscaleIPAddress(from addresses: [IPInterfaceAddress]) -> String? {
        // Carrier CGNAT (100.64.0.0/10 on pdp_ip*) is not a Tailscale route.
        addresses.first { ClientNetworkAddressPolicy.isTailscaleInterface(name: $0.name, address: $0.address) }?.address
    }

    private static func normalizedMACAddress(_ address: String?) -> String {
        address?
            .filter { $0.isHexDigit }
            .lowercased() ?? ""
    }

    private static func ipInterfaceSummary() -> String {
        ipInterfaceSummary(from: ipInterfaceAddresses())
    }

    private static func ipInterfaceSummary(from addresses: [IPInterfaceAddress]) -> String {
        guard !addresses.isEmpty else { return "none" }
        return Set(addresses.map { interface in
            if ClientNetworkAddressPolicy.isTailscaleInterface(name: interface.name, address: interface.address) {
                return "tailscale"
            }
            if interface.name.hasPrefix("en") {
                return "local-network"
            }
            if interface.name.hasPrefix("pdp_ip") {
                return "cellular"
            }
            return "other-network"
        })
        .sorted()
        .joined(separator: ",")
    }

    private static func ipInterfaceAddresses() -> [IPInterfaceAddress] {
        IPNetwork.interfaces()
            .sorted { IPNetwork.preference($0.address) < IPNetwork.preference($1.address) }
            .map { IPInterfaceAddress(name: $0.name, address: $0.address, netmask: $0.netmask) }
    }

    private func sanitizedZoomRegion(_ region: CGRect) -> CGRect {
        let minimumSize: CGFloat = 0.12
        let width = min(max(region.width, minimumSize), 1)
        let height = min(max(region.height, minimumSize), 1)
        let x = min(max(region.minX, 0), 1 - width)
        let y = min(max(region.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

final class ClientInputSender {
    private static let logger = Logger(subsystem: "PocketCtrlMobile", category: "InputSender")
    private static let pointerFlushInterval: DispatchTimeInterval = .milliseconds(8)
    private var socketFD: Int32
    private var destination: sockaddr_in6
    private let sharedSecret: String
    private let credentialID: String
    private let encoder = JSONEncoder()
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "pocketctrl.mobile.input.sender", qos: .userInteractive)
    private var sendCounter = 0
    private var droppedSendCounter = 0
    private var pendingPointerMove: ClientRemoteInputEvent?
    private var pendingPointerFlush: DispatchWorkItem?

    init(
        host: String,
        port: UInt16,
        credentialID: String,
        sharedSecret: String,
        onReady: (() -> Void)? = nil,
        onFailed: ((NWError) -> Void)? = nil
    ) {
        self.credentialID = credentialID
        self.sharedSecret = sharedSecret
        self.host = host
        self.port = port
        ClientDiagnostics.write("input sender init port=\(port)")
        socketFD = IPNetwork.makeUDPSocket()
        guard socketFD >= 0 else {
            ClientDiagnostics.write("input sender socket creation failed port=\(port) errno=\(errno)")
            onFailed?(NWError.posix(POSIXErrorCode(rawValue: errno) ?? .EINVAL))
            destination = sockaddr_in6()
            return
        }

        guard let destination = Self.makeDestination(host: host, port: port) else {
            ClientDiagnostics.write("input sender invalid destination port=\(port)")
            close(socketFD)
            socketFD = -1
            onFailed?(NWError.posix(.EINVAL))
            self.destination = sockaddr_in6()
            return
        }
        self.destination = destination
        Self.configureLowLatency(socketFD)
        queue.async { onReady?() }
    }

    deinit {
        ClientDiagnostics.write("input sender deinit port=\(port) sends=\(sendCounter) dropped=\(droppedSendCounter)")
        pendingPointerFlush?.cancel()
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    func send(_ event: ClientRemoteInputEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            if event.kind == .mouseMove {
                self.enqueuePointerMove(event)
            } else {
                self.flushPendingPointerMove()
                self.sendControlNow(event, type: .input, label: "input.\(event.kind.rawValue)")
            }
        }
    }

    func send(_ zoomRegion: ClientZoomRegion) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingPointerMove()
            self.sendControlNow(zoomRegion, type: .zoomRegion, label: "zoomRegion")
        }
    }

    func send(_ audioSetting: ClientAudioSetting) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingPointerMove()
            self.sendControlNow(audioSetting, type: .audioSetting, label: "audioSetting.\(audioSetting.enabled)")
        }
    }

    func send(_ feedback: ClientViewerFeedback) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sendControlNow(feedback, type: .feedback, label: "feedback.keyframe=\(feedback.keyframeRequested).fps=\(feedback.fps)")
        }
    }

    private func enqueuePointerMove(_ event: ClientRemoteInputEvent) {
        pendingPointerMove = event
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
        guard let event = pendingPointerMove else { return }
        pendingPointerMove = nil
        sendControlNow(event, type: .input, label: "input.\(event.kind.rawValue).coalesced")
    }

    private func sendControlNow<T: Encodable>(_ value: T, type: ClientControlPayloadType, label: String) {
        guard let data = ClientAuthenticatedControlDatagram.seal(
            value,
            type: type,
            credentialID: credentialID,
            secret: sharedSecret,
            encoder: encoder
        ) else {
            ClientDiagnostics.write("input sender seal failed port=\(port) type=\(type.rawValue) label=\(label)")
            Self.logger.error("Input sender seal failed. host=\(self.host, privacy: .private) port=\(self.port, privacy: .public) type=\(type.rawValue, privacy: .public) label=\(label, privacy: .public)")
            return
        }

        sendCounter += 1
        let sequence = sendCounter
        if sequence <= 5 || type != .input || sequence % 200 == 0 {
            ClientDiagnostics.write("input sender send seq=\(sequence) port=\(port) type=\(type.rawValue) label=\(label) bytes=\(data.count)")
        }

        guard socketFD >= 0 else { return }
        var destinationCopy = destination
        let sent = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return withUnsafePointer(to: &destinationCopy) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(socketFD, base, data.count, MSG_DONTWAIT, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }

        guard sent == data.count else {
            droppedSendCounter += 1
            let errnoCode = errno
            if droppedSendCounter <= 5 || droppedSendCounter % 50 == 0 {
                ClientDiagnostics.write("input sender send dropped count=\(droppedSendCounter) seq=\(sequence) port=\(port) type=\(type.rawValue) errno=\(errnoCode) message=\(String(cString: strerror(errnoCode)))")
                Self.logger.warning("Input sender send dropped. count=\(self.droppedSendCounter, privacy: .public) seq=\(sequence, privacy: .public) type=\(type.rawValue, privacy: .public) errno=\(errnoCode, privacy: .public)")
            }
            return
        }
    }

    private static func makeDestination(host: String, port: UInt16) -> sockaddr_in6? {
        IPNetwork.destination(host: host, port: port)
    }

    private static func configureLowLatency(_ socketFD: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var sendBuffer: Int32 = 16 * 1024
        setsockopt(socketFD, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))

        var serviceType: Int32 = NET_SERVICE_TYPE_RD
        setsockopt(socketFD, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, socklen_t(MemoryLayout<Int32>.size))

        var tos: Int32 = IPTOS_LOWDELAY
        setsockopt(socketFD, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketFD, IPPROTO_IPV6, IPV6_TCLASS, &tos, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(socketFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        }
    }
}

struct ClientTextTyper {
    struct Stroke {
        let keyCode: UInt16
        let modifiers: UInt64
    }

    static let shiftModifier: UInt64 = 0x0002_0000
    static let controlModifier: UInt64 = 0x0004_0000
    static let optionModifier: UInt64 = 0x0008_0000
    static let commandModifier: UInt64 = 0x0010_0000

    static func strokes(for text: String) -> [Stroke] {
        text.compactMap(stroke(for:))
    }

    static func keyCode(for character: Character) -> UInt16? {
        keyCodes[character] ?? shiftedKeyCodes[character]
    }

    private static func stroke(for character: Character) -> Stroke? {
        if let lower = keyCodes[character] {
            return Stroke(keyCode: lower, modifiers: 0)
        }

        if let shifted = shiftedKeyCodes[character] {
            return Stroke(keyCode: shifted, modifiers: shiftModifier)
        }

        let string = String(character)
        if string.count == 1,
           let scalar = string.unicodeScalars.first,
           Character(String(scalar).lowercased()) != character,
           let keyCode = keyCodes[Character(String(scalar).lowercased())] {
            return Stroke(keyCode: keyCode, modifiers: shiftModifier)
        }

        return nil
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\n": 36,
        "\r": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49,
        "`": 50
    ]

    private static let shiftedKeyCodes: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24,
        "(": 25, "&": 26, "_": 27, "*": 28, ")": 29, "}": 30, "{": 33,
        "\"": 39, ":": 41, "|": 42, "<": 43, "?": 44, ">": 47, "~": 50
    ]
}
