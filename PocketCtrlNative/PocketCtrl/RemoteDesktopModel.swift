// SPDX-License-Identifier: MPL-2.0

import Combine
import Darwin
import Foundation
import AppKit
import LocalAuthentication
import Network
import os
import ScreenCaptureKit
import Security
import SwiftUI

struct ViewerSavedComputer: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var hostAddress: String
    var localHostAddress: String
    var tailscaleHostAddress: String
    var listenPort: String
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
        if !hostAddress.isEmpty {
            return hostAddress
        }
        return "Saved Mac"
    }
}

struct ViewerUserFacingIssue: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

struct ConnectedViewer: Identifiable, Equatable {
    let id: String
    let name: String
    let route: String
    let lastSeen: Date
}

struct ManualPairingApprovalError: Error {
    let statusCode: Int
    let message: String

    static let hostingRequired = ManualPairingApprovalError(statusCode: 409, message: "Start hosting on that Mac before approving computer-code pairing.")
    static let codeExpired = ManualPairingApprovalError(statusCode: 410, message: "That computer code expired. Generate a new code on the host Mac.")
    static let invalidCode = ManualPairingApprovalError(statusCode: 401, message: "That computer code is incorrect.")
    static let requestAlreadyPending = ManualPairingApprovalError(statusCode: 409, message: "A pairing request is already waiting for approval on the host Mac.")
    static let denied = ManualPairingApprovalError(statusCode: 403, message: "The host Mac denied the pairing request.")
    static let timedOut = ManualPairingApprovalError(statusCode: 408, message: "The host Mac did not approve the request in time.")
    static let credentialStorageFailed = ManualPairingApprovalError(statusCode: 500, message: "This Mac could not securely save the device credential. Check the app's code signing, then try pairing again.")
}

struct ManualPairingClientError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@MainActor
final class RemoteDesktopModel: ObservableObject {
    @Published var displays: [DisplayOption] = []
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()

    @Published var hostDestinationAddress = "127.0.0.1"
    @Published var hostVideoPort = "5555"
    @Published var hostAudioPort = "5557"
    @Published var hostInputPort = "5556"
    var hostControlToken = ""
    @Published var viewerPairingSecret = ""
    @Published var viewerCredentialID = ""
    @Published private(set) var viewerAllowsRemoteInput = false
    @Published private(set) var viewerAllowsClipboard = false
    @Published private(set) var viewerAllowsAudio = false
    @Published var captureWidth = 1920.0
    @Published var fps = 60.0
    @Published var bitrateMbps = 12.0
    @Published var adaptiveBitrateEnabled = true
    @Published var hostAudioEnabled = UserDefaults.standard.object(forKey: "PocketCtrl.hostAudioEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(hostAudioEnabled, forKey: Self.hostAudioEnabledKey)
        }
    }
    @Published var hostClipboardEnabled = UserDefaults.standard.object(forKey: "PocketCtrl.hostClipboardEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(hostClipboardEnabled, forKey: Self.hostClipboardEnabledKey)
        }
    }
    @Published var autoStartHosting = UserDefaults.standard.bool(forKey: "PocketCtrl.autoStartHosting") {
        didSet {
            UserDefaults.standard.set(autoStartHosting, forKey: Self.autoStartHostingKey)
        }
    }
    @Published var keepAwakeWhileHosting = UserDefaults.standard.object(forKey: "PocketCtrl.keepAwakeWhileHosting") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAwakeWhileHosting, forKey: Self.keepAwakeWhileHostingKey)
            updateSleepActivity()
        }
    }
    @Published var remoteInputEnabled = UserDefaults.standard.object(forKey: "PocketCtrl.remoteInputEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(remoteInputEnabled, forKey: Self.remoteInputEnabledKey)
            host?.setRemoteInputEnabled(remoteInputEnabled)
            hostInputStatus = remoteInputEnabled
                ? (accessibilityGranted ? "Waiting for input" : "Accessibility required")
                : "Remote input off"
        }
    }
    @Published private(set) var isHostingRequested = false {
        didSet {
            guard isHostingRequested != oldValue else { return }
            updateSleepActivity()
        }
    }
    @Published private(set) var isSleepPreventionActive = false
    @Published var isHosting = false
    @Published var hostStatus = "Host idle"
    @Published var hostFPS = 0
    @Published var hostBitrateMbps = 0.0
    @Published var launchAtLoginEnabled = LoginItemManager.isLaunchAtLoginEnabled {
        didSet {
            guard !isApplyingLaunchAtLoginState, launchAtLoginEnabled != oldValue else { return }
            syncLaunchAtLoginSetting()
        }
    }
    @Published var launchAtLoginStatus = "Launch at login not checked"
    @Published var viewerFeedbackStatus = "No viewer feedback yet"
    @Published var hostActivityStatus = "No host traffic yet"
    @Published var hostInputStatus = "No input received yet"
    @Published var hostNetworkWarning: String?
    @Published var localAddress = "Not detected"
    @Published var tailscaleAddress = "Not detected"
    @Published var hostID: String {
        didSet {
            UserDefaults.standard.set(hostID, forKey: Self.hostIDKey)
        }
    }
    @Published var allowLocalDiscovery = UserDefaults.standard.object(forKey: "PocketCtrl.allowLocalDiscovery") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(allowLocalDiscovery, forKey: Self.allowLocalDiscoveryKey)
            updateLocalDiscoveryAdvertisement()
        }
    }
    @Published var localDiscoveryStatus = "Local Network not checked"
    @Published private(set) var manualPairingCode = ""
    @Published private(set) var manualPairingExpiresAt = Date.distantPast
    @Published private(set) var manualPairingStatus = "Computer code not ready"
    @Published private(set) var isPairingModeActive = false
    @Published var pendingManualPairingRequest: PendingManualPairingRequest?
    @Published private(set) var trustedDevices: [TrustedDeviceRecord] = []
    @Published private(set) var trustedDeviceStorageWarning: String?
    @Published private(set) var activeControllerName: String?
    @Published private(set) var activeControllerID: String?
    @Published private(set) var activeControllerRoute: String?
    @Published private(set) var activeControllerLastSeen: Date?
    @Published private(set) var connectedViewers: [ConnectedViewer] = []
    @Published private(set) var approvalAuthenticationInProgress = false
    // Legacy CLI field: discovery availability only, not a system permission query
    // or proof that authenticated video has reached a viewer.
    @Published var localNetworkApproved = false
    @Published var directCaptureApproved = false
    @Published var directCaptureStatus = "Direct screen access not checked"

    @Published var viewerListenPort = "5555" {
        didSet { UserDefaults.standard.set(viewerListenPort, forKey: Self.viewerListenPortKey) }
    }
    @Published var viewerAudioPort = "5557" {
        didSet { UserDefaults.standard.set(viewerAudioPort, forKey: Self.viewerAudioPortKey) }
    }
    @Published var viewerHostAddress = "127.0.0.1" {
        didSet {
            UserDefaults.standard.set(viewerHostAddress, forKey: Self.viewerHostAddressKey)
            viewerHostWarning = viewerAddressWarning(for: viewerHostAddress)
        }
    }
    @Published var viewerHostInputPort = "5556" {
        didSet { UserDefaults.standard.set(viewerHostInputPort, forKey: Self.viewerHostInputPortKey) }
    }
    @Published var viewerHostWarning: String?
    @Published private(set) var viewerSavedComputers: [ViewerSavedComputer] = []
    @Published private(set) var selectedViewerSavedComputerID: String?
    @Published var isViewing = false
    @Published var remoteControlEnabled = false
    @Published var viewerMouseCaptured = false
    @Published var viewerStatus = "Viewer idle"
    @Published var viewerUserFacingIssue: ViewerUserFacingIssue?
    @Published var viewerAudioStatus = "Audio off"
    @Published var viewerAudioEnabled = false {
        didSet {
            UserDefaults.standard.set(viewerAudioEnabled, forKey: Self.viewerAudioEnabledKey)
            guard !isUpdatingViewerAudioInternally else { return }
            guard viewerAudioEnabled != oldValue else { return }
            let shouldEnable = viewerAudioEnabled && viewerAllowsAudio
            viewer?.setAudioEnabled(shouldEnable)
            viewerAudioStatus = shouldEnable
                ? "Audio starting..."
                : (viewerAudioEnabled ? "Audio was not allowed for this device" : "Audio off")
        }
    }
    @Published var viewerDetailAmount = 0.5 {
        didSet {
            guard viewerDetailAmount != oldValue else { return }
            viewerStreamSettingsChanged()
        }
    }
    @Published var viewerFrameRate = 30.0 {
        didSet {
            guard viewerFrameRate != oldValue else { return }
            viewerStreamSettingsChanged()
        }
    }
    private var viewerQualitySendTask: Task<Void, Never>?

    var viewerStreamSettings: ViewerStreamSettings {
        ViewerStreamSettings(detailAmount: viewerDetailAmount, frameRate: viewerFrameRate)
    }

    private func viewerStreamSettingsChanged() {
        viewerStreamSettings.save(to: .standard)
        viewerQualitySendTask?.cancel()
        viewerQualitySendTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            self.viewer?.setStreamSettings(self.viewerStreamSettings)
        }
    }
    @Published var showRemotePointer = true {
        didSet {
            UserDefaults.standard.set(showRemotePointer, forKey: Self.showRemotePointerKey)
        }
    }
    @Published var viewerFPS = 0
    @Published var viewerBitrateMbps = 0.0
    @Published var viewerLossPercent = 0.0
    @Published var viewerActivityStatus = "No viewer traffic yet"
    @Published var viewerInputStatus = "No input sent yet"
    @Published var remoteVideoSize = CGSize(width: 16, height: 9)
    @Published var viewerPointerPosition = CGPoint(x: 0.5, y: 0.5)
    @Published var accessibilityGranted = false
    @Published var accessibilityStatus = "Accessibility not checked"
    @Published var screenRecordingGranted = false
    @Published var screenRecordingStatus = "Screen Recording not checked"

    private var host: ScreenCaptureHost?
    private var viewer: VideoViewerEngine?
    private weak var renderView: PixelBufferRenderView?
    private let localDiscoveryAdvertiser = LocalDiscoveryAdvertiser()
    private let localNetworkPermissionProbe = LocalDiscoveryAdvertiser()
    private let manualPairingBrowser = LocalDiscoveryBrowser()
    private let manualPairingServer = ManualPairingRequestServer()
    let trustedCredentialStore = TrustedDeviceCredentialStore()
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "pocketctrl.mac.network.monitor", qos: .utility)
    private var sleepActivity: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var localNetworkProbeTask: Task<Void, Never>?
    private var didWarnAboutLocalNetworkAccess = false
    private let localNetworkAccessWarningController = LocalNetworkAccessWarningController()
    private var viewerConnectionWatchdogTask: Task<Void, Never>?
    private var hostRecoveryTask: Task<Void, Never>?
    private var hostRecoveryAttempt = 0
    private var isMacSleeping = false
    private var shouldPresentViewerConnectionErrors = false
    private var lastNetworkRefreshAt = Date.distantPast
    private var shouldRestartHostAfterWake = false
    private var shouldRefreshSetupOnActivation = false
    private var shouldRetryMediaOnActivation = false
    private var hasAttemptedViewerAutoReconnect = false
    private var isUpdatingViewerAudioInternally = false
    private var isApplyingLaunchAtLoginState = false
    private var manualPairingApprovalCompletions: [UUID: (Result<ManualPairingResponse, ManualPairingApprovalError>) -> Void] = [:]
    private var pendingPersistentPairingCredentials: [String: TrustedDeviceCredential] = [:]
    private var manualPairingDiscoveredHosts: [String: DiscoveredPocketCtrlHost] = [:]
    private var manualPairingConnectionTask: Task<Void, Never>?
    private var manualPairingRefreshTask: Task<Void, Never>?
    private var manualPairingDiscoveryActive = false
    private var storedTrustedDeviceRecords: [TrustedDeviceRecord] = []
    private var trustedDeviceCredentialReadNeedsRetry = false
    private var viewerCredentialIsPersistent = false
    private var viewerCredentialReadNeedsRetry = false
    private var viewerPairedHostID = ""
    private var viewerLocalHostAddress = ""
    private var viewerTailscaleHostAddress = ""
    private var viewerLastFrameAt: Date?
    private var viewerConnectionStartedAt: Date?
    private let permissionLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.pocketctrl.mac", category: "Permissions")
    private let hostLifecycleLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.pocketctrl.mac", category: "HostingLifecycle")
    private let powerManagementLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.pocketctrl.mac", category: "PowerManagement")
    private static let hostControlTokenKey = "PocketCtrl.hostControlToken.v1"
    private static let trustedDevicesKey = "PocketCtrl.trustedDevices.v1"
    private static let trustedDeviceSecretPrefix = "PocketCtrl.trustedDeviceSecret.v1."
    private static let autoStartHostingKey = "PocketCtrl.autoStartHosting"
    private static let keepAwakeWhileHostingKey = "PocketCtrl.keepAwakeWhileHosting"
    private static let remoteInputEnabledKey = "PocketCtrl.remoteInputEnabled"
    private static let hostAudioEnabledKey = "PocketCtrl.hostAudioEnabled"
    private static let hostClipboardEnabledKey = "PocketCtrl.hostClipboardEnabled"
    private static let hostIDKey = PersistentHostIdentity.defaultsKey
    private static let allowLocalDiscoveryKey = "PocketCtrl.allowLocalDiscovery"
    private static let viewerHostAddressKey = "PocketCtrl.viewerHostAddress"
    private static let viewerListenPortKey = "PocketCtrl.viewerListenPort"
    private static let viewerAudioPortKey = "PocketCtrl.viewerAudioPort"
    private static let viewerHostInputPortKey = "PocketCtrl.viewerHostInputPort"
    private static let viewerAudioEnabledKey = "PocketCtrl.viewerAudioEnabled"
    private static let showRemotePointerKey = "PocketCtrl.showRemotePointer"
    private static let shouldAutoReconnectViewerKey = "PocketCtrl.shouldAutoReconnectViewer"
    private static let viewerSavedComputersKey = "PocketCtrl.viewerSavedComputers"
    private static let selectedViewerSavedComputerIDKey = "PocketCtrl.selectedViewerSavedComputerID"
    private static let viewerSavedComputerCredentialPrefix = "PocketCtrl.viewerSavedComputerCredential.v1."
    private static let manualPairingCodeLifetime: TimeInterval = 2 * 60
    /// How long a pairing request waits for the Mac owner to approve or deny it.
    static let manualPairingApprovalWindow: TimeInterval = 3 * 60
    private static let viewerRouteStabilityInterval: TimeInterval = 5

    init() {
        KeychainStore.deleteLegacy(forKey: "PocketCtrl.pairingKey")
        KeychainStore.deleteLegacy(forKey: "PocketCtrl.viewerPairingKey")
        KeychainStore.deleteLegacyKeys(withPrefix: "PocketCtrl.viewerSavedComputerPairingKey.")
        UserDefaults.standard.removeObject(forKey: "PocketCtrl.lanSharedSecret")
        let initialControlToken = KeychainStore.string(forKey: Self.hostControlTokenKey) ?? PocketCtrlCredentialGenerator.secret()
        hostControlToken = initialControlToken
        KeychainStore.set(initialControlToken, forKey: Self.hostControlTokenKey)
        let savedHostID = UserDefaults.standard.string(forKey: Self.hostIDKey)?.trimmedNonEmpty
        // Do not infer a different computer from a different interface address:
        // macOS private Wi-Fi addressing can change it on the same Mac. Preserve
        // the existing ID on upgrade, including IDs generated by older builds.
        let initialHostID = PersistentHostIdentity.loadOrCreate()
        PocketCtrlHostDiagnostics.connection("host.identityCheck previousHost=\(PocketCtrlHostDiagnostics.identifierTag(savedHostID)) policy=persistentInstallation networkIndependent=true willRegenerate=\(savedHostID == nil)")
        PocketCtrlCLIInstaller.refreshCredentialIfInstalled(hostControlToken)
        hostID = initialHostID
        PocketCtrlHostDiagnostics.connection("host.start version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") host=\(PocketCtrlHostDiagnostics.identifierTag(initialHostID)) identityDecision=\(savedHostID == nil ? "firstIdentity" : "preserved")")
        UserDefaults.standard.set(initialHostID, forKey: Self.hostIDKey)
        viewerHostAddress = UserDefaults.standard.string(forKey: Self.viewerHostAddressKey) ?? "127.0.0.1"
        viewerListenPort = UserDefaults.standard.string(forKey: Self.viewerListenPortKey) ?? "5555"
        viewerAudioPort = UserDefaults.standard.string(forKey: Self.viewerAudioPortKey) ?? "5557"
        viewerHostInputPort = UserDefaults.standard.string(forKey: Self.viewerHostInputPortKey) ?? "5556"
        viewerAudioEnabled = UserDefaults.standard.bool(forKey: Self.viewerAudioEnabledKey)
        let savedStreamSettings = ViewerStreamSettings.load(from: .standard)
        viewerDetailAmount = savedStreamSettings.detailAmount
        viewerFrameRate = savedStreamSettings.frameRate
        savedStreamSettings.save(to: .standard)
        showRemotePointer = UserDefaults.standard.object(forKey: Self.showRemotePointerKey) as? Bool ?? true
        selectedViewerSavedComputerID = UserDefaults.standard.string(forKey: Self.selectedViewerSavedComputerIDKey)
        viewerSavedComputers = Self.loadViewerSavedComputers()
        if let selectedID = selectedViewerSavedComputerID,
           let selected = viewerSavedComputers.first(where: { $0.id == selectedID }) {
            restoreViewerSavedComputer(selected, reason: "launch")
        }
        let savedTrustedDevices = Self.loadTrustedDeviceRecords()
        storedTrustedDeviceRecords = savedTrustedDevices
        var restoredTrustedDevices: [TrustedDeviceRecord] = []
        var restoredCredentials: [TrustedDeviceCredential] = []
        var missingCredentialCount = 0
        var unreadableCredentialCount = 0
        for record in savedTrustedDevices {
            switch KeychainStore.readString(forKey: Self.trustedDeviceSecretPrefix + record.id) {
            case let .value(secret) where secret.count >= 32:
                PocketCtrlHostDiagnostics.connection("trust.restore result=loaded credential=\(PocketCtrlHostDiagnostics.identifierTag(record.id))")
                restoredTrustedDevices.append(record)
                restoredCredentials.append(TrustedDeviceCredential(record: record, secret: secret))
            case .missing, .value(_):
                PocketCtrlHostDiagnostics.connection("trust.restore result=missingOrInvalid credential=\(PocketCtrlHostDiagnostics.identifierTag(record.id))")
                missingCredentialCount += 1
            case let .failure(status):
                PocketCtrlHostDiagnostics.connection("trust.restore result=keychainError osStatus=\(status) credential=\(PocketCtrlHostDiagnostics.identifierTag(record.id))")
                unreadableCredentialCount += 1
            }
        }
        trustedDevices = restoredTrustedDevices
        PocketCtrlHostDiagnostics.connection("trust.summary saved=\(savedTrustedDevices.count) restored=\(restoredTrustedDevices.count) missing=\(missingCredentialCount) unreadable=\(unreadableCredentialCount)")
        trustedCredentialStore.replace(with: restoredCredentials)
        trustedDeviceCredentialReadNeedsRetry = unreadableCredentialCount > 0
        if missingCredentialCount > 0 || unreadableCredentialCount > 0 {
            trustedDeviceStorageWarning = "One or more saved devices could not be loaded securely. Pair those devices again."
            PocketCtrlHostDiagnostics.write("trusted device restore skipped missing=\(missingCredentialCount) unreadable=\(unreadableCredentialCount)")
            if unreadableCredentialCount == 0 {
                storedTrustedDeviceRecords = restoredTrustedDevices
                saveTrustedDevices()
            }
        }
        configureLocalDiscoveryCallbacks()
        configureManualPairingDiscoveryCallbacks()
        startViewerLocalDiscoveryIfPossible()
        refreshNetworkAddresses()
        manualPairingCode = ""
        manualPairingStatus = "Pairing is closed"
        observeWakeEvents()
        observeSetupPermissionRefreshEvents()
        startNetworkMonitoring()
        refreshLaunchAtLoginStatus()
        Task {
            await refreshPermissions()
            await refreshDisplays()
            refreshNetworkAddresses()
            if autoStartHosting {
                startHost()
            }
        }
    }

    deinit {
        viewerQualitySendTask?.cancel()
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
        }
        localNetworkProbeTask?.cancel()
        hostRecoveryTask?.cancel()
        localNetworkPermissionProbe.stop()
        localDiscoveryAdvertiser.stop()
        manualPairingServer.stop()
        manualPairingBrowser.stop()
        manualPairingConnectionTask?.cancel()
        manualPairingRefreshTask?.cancel()
        networkMonitor.cancel()
    }

    func refreshPermissions() async {
        accessibilityGranted = MacPermissions.accessibilityGranted
        screenRecordingGranted = MacPermissions.screenRecordingGranted
        logPermissionSnapshot(reason: "refreshPermissions")
        accessibilityStatus = accessibilityGranted
            ? "Accessibility allowed"
            : "macOS still reports Accessibility denied for this running app. If Settings already shows it enabled, quit and reopen PocketCtrl."
        screenRecordingStatus = screenRecordingGranted
            ? "Screen Recording allowed"
            : "macOS still reports Screen Recording denied for this running app. If Settings already shows it enabled, quit and reopen PocketCtrl."
    }

    func refreshSetupStatus(probeDirectCapture: Bool = true) async {
        await refreshPermissions()
        // A passive setup refresh must not trigger a second permission prompt.
        // Local Network is requested explicitly, or when hosting/pairing starts.
        if probeDirectCapture {
            if screenRecordingGranted {
                await refreshDisplayAccessStatus()
            } else {
                directCaptureApproved = false
                directCaptureStatus = "Allow Screen Recording before direct screen access can be checked."
            }
        }
        refreshLaunchAtLoginStatus()
    }

    func requestAccessibilityPermission() {
        shouldRefreshSetupOnActivation = true
        accessibilityStatus = "Checking Accessibility approval..."
        permissionLogger.info("Checking Accessibility before prompting. path=\(Bundle.main.bundleURL.path, privacy: .private)")
        Task {
            await refreshPermissions()
            guard !accessibilityGranted else {
                permissionLogger.info("Accessibility was already approved; no prompt opened.")
                return
            }

            permissionLogger.info("Accessibility not approved after live check; requesting prompt.")
            MacPermissions.requestAccessibilityPrompt()
            await refreshSetupStatus(probeDirectCapture: false)
            scheduleSetupStatusRefresh(reason: "accessibility request")
        }
    }

    func requestScreenRecordingPermission() {
        shouldRefreshSetupOnActivation = true
        screenRecordingStatus = "Checking Screen Recording approval..."
        directCaptureStatus = "Checking direct screen access..."
        permissionLogger.info("Checking Screen Recording before prompting. path=\(Bundle.main.bundleURL.path, privacy: .private)")
        Task {
            await refreshSetupStatus(probeDirectCapture: true)
            guard !(screenRecordingGranted && directCaptureApproved) else {
                permissionLogger.info("Screen Recording and direct capture were already approved; no prompt opened.")
                return
            }

            permissionLogger.info("Screen Recording/direct capture not approved after live check; requesting prompt.")
            MacPermissions.requestScreenRecordingPrompt()
            await refreshSetupStatus(probeDirectCapture: true)
            scheduleSetupStatusRefresh(reason: "screen recording request")
        }
    }

    func requestLocalNetworkPermission() {
        allowLocalDiscovery = true
        localDiscoveryStatus = "Checking Local Network approval..."
        refreshNetworkAddresses()
        probeLocalNetworkPermission()
    }

    func requestDirectCapturePermission() {
        shouldRefreshSetupOnActivation = true
        directCaptureStatus = "Checking direct screen access..."
        permissionLogger.info("Checking direct screen access via ScreenCaptureKit for path=\(Bundle.main.bundleURL.path, privacy: .private)")
        Task {
            await refreshSetupStatus(probeDirectCapture: true)
            guard !directCaptureApproved else {
                permissionLogger.info("Direct capture was already approved; no settings opened.")
                return
            }

            permissionLogger.info("Direct capture is still unavailable after live check; leaving Settings closed.")
        }
    }

    func openLocalNetworkSettings() {
        shouldRefreshSetupOnActivation = true
        shouldRetryMediaOnActivation = true
        permissionLogger.info("Opening Local Network settings from path=\(Bundle.main.bundleURL.path, privacy: .private)")
        MacPermissions.openLocalNetworkSettings()
    }

    func openAccessibilitySettings() {
        shouldRefreshSetupOnActivation = true
        permissionLogger.info("Opening Accessibility settings from path=\(Bundle.main.bundleURL.path, privacy: .private)")
        MacPermissions.openAccessibilitySettings()
    }

    func openDirectCaptureSettings() {
        shouldRefreshSetupOnActivation = true
        permissionLogger.info("Opening Screen Recording settings for direct capture from path=\(Bundle.main.bundleURL.path, privacy: .private)")
        MacPermissions.openScreenRecordingSettings()
    }

    func openScreenRecordingSettings() {
        shouldRefreshSetupOnActivation = true
        permissionLogger.info("Opening Screen Recording settings from path=\(Bundle.main.bundleURL.path, privacy: .private)")
        MacPermissions.openScreenRecordingSettings()
    }

    func refreshDisplays() async {
        await refreshPermissions()
        guard screenRecordingGranted else {
            displays = []
            directCaptureApproved = false
            directCaptureStatus = "Allow Screen Recording before direct screen access can be checked."
            hostStatus = "Screen Recording approval is required before displays can be loaded."
            return
        }

        await refreshDisplayAccessStatus()
    }

    private func refreshDisplayAccessStatus() async {
        do {
            permissionLogger.info("Probing ScreenCaptureKit display access")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let options = content.displays.enumerated().map { index, display in
                DisplayOption(
                    id: display.displayID,
                    name: "Display \(index + 1)",
                    width: display.width,
                    height: display.height
                )
            }
            displays = options
            screenRecordingGranted = true
            screenRecordingStatus = "Screen capture works"
            directCaptureApproved = true
            directCaptureStatus = "Direct screen access allowed"
            permissionLogger.info("ScreenCaptureKit display probe succeeded. displays=\(options.count, privacy: .public)")
            if !options.contains(where: { $0.id == selectedDisplayID }), let first = options.first {
                selectedDisplayID = first.id
            }
        } catch {
            directCaptureApproved = false
            hostStatus = "Display refresh failed: \(error.localizedDescription)"
            directCaptureStatus = "macOS still reports direct screen access unavailable for this running app. If Settings already shows it enabled, quit and reopen PocketCtrl. \(error.localizedDescription)"
            permissionLogger.error("ScreenCaptureKit display probe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startHost() {
        isHostingRequested = true
        shouldRestartHostAfterWake = false
        hostRecoveryTask?.cancel()
        hostRecoveryTask = nil
        hostRecoveryAttempt = 0
        hostLifecycleLogger.info("Hosting requested by user or startup policy")
        startHostIfPossible()
    }

    private func startHostIfPossible() {
        guard isHostingRequested, !isMacSleeping, !isHosting else { return }
        trustedCredentialStore.clearSuspensions()
        NSLog("PocketCtrl model startHost requested videoPort=\(hostVideoPort) inputPort=\(hostInputPort) audioPort=\(hostAudioPort) localNetwork=\(localNetworkApproved) directCapture=\(directCaptureApproved) screenRecording=\(screenRecordingGranted) accessibility=\(accessibilityGranted)")
        refreshNetworkAddresses()
        refreshHostNetworkWarning()
        guard screenRecordingGranted,
              accessibilityGranted || !remoteInputEnabled else {
            hostStatus = "Setup required"
            NSLog("PocketCtrl model startHost blocked by setup directCapture=\(directCaptureApproved) screenRecording=\(screenRecordingGranted) accessibility=\(accessibilityGranted) remoteInput=\(remoteInputEnabled)")
            Task { await refreshSetupStatus() }
            return
        }
        guard directCaptureApproved else {
            hostStatus = "Checking screen access..."
            NSLog("PocketCtrl model startHost probing direct capture after required setup")
            Task {
                await refreshSetupStatus()
                guard isHostingRequested, !isMacSleeping else { return }
                if directCaptureApproved {
                    startHostIfPossible()
                } else {
                    hostStatus = "Screen access is still unavailable. If you just enabled Screen Recording, quit and reopen PocketCtrl."
                }
            }
            return
        }
        let destinationAddress = NetworkAddressPolicy.normalized(hostDestinationAddress)
        if hostDestinationAddress != destinationAddress {
            hostDestinationAddress = destinationAddress
        }
        guard let videoPort = UInt16(hostVideoPort),
              let audioPort = UInt16(hostAudioPort),
              let inputPort = UInt16(hostInputPort) else {
            hostStatus = "Ports must be between 1 and 65535"
            return
        }

        let configuration = HostConfiguration(
            destinationAddress: destinationAddress,
            videoPort: videoPort,
            audioPort: audioPort,
            inputPort: inputPort,
            credentialStore: trustedCredentialStore,
            displayID: selectedDisplayID,
            captureWidth: Int(captureWidth),
            fps: Int(fps),
            bitrate: Int(bitrateMbps * 1_000_000),
            adaptiveBitrateEnabled: adaptiveBitrateEnabled,
            audioEnabled: hostAudioEnabled,
            clipboardEnabled: hostClipboardEnabled,
            remoteInputEnabled: remoteInputEnabled
        )

        do {
            let host = try ScreenCaptureHost(configuration: configuration)
            host.onStats = { [weak self] fps, bitrate, _, activity in
                Task { @MainActor in
                    self?.hostFPS = fps
                    self?.hostBitrateMbps = Double(bitrate) / 1_000_000
                    self?.hostActivityStatus = "\(activity.encodedFrames) frames, \(activity.sentDatagrams) packets, \(Self.formatBytes(activity.sentBytes))/s"
                    self?.hostStatus = self?.hostStreamingStatus(configuration) ?? "Streaming"
                }
            }
            host.onFeedback = { [weak self] feedback, targetBitrate in
                Task { @MainActor in
                    let quality = (feedback.qualityProfile ?? .balanced).rawValue
                    if feedback.completedFrames > 0 {
                        self?.viewerFeedbackStatus = "Video received · \(feedback.fps) fps viewer, \(String(format: "%.1f", feedback.estimatedLossPercent))% estimated loss, quality \(quality), target \(String(format: "%.1f", Double(targetBitrate) / 1_000_000)) Mbps"
                    } else if feedback.receivedChunks > 0 {
                        self?.viewerFeedbackStatus = "Video packets received · waiting for a complete frame"
                    } else {
                        self?.viewerFeedbackStatus = "Device connected · waiting for video delivery"
                    }
                    self?.hostBitrateMbps = Double(targetBitrate) / 1_000_000
                }
            }
            host.onInputStats = { [weak self] stats in
                Task { @MainActor in
                    self?.hostInputStatus = Self.formatInputStats(prefix: "Received", stats: stats)
                }
            }
            host.onAudioSetting = { [weak self] enabled in
                Task { @MainActor in
                    self?.hostAudioEnabled = enabled
                    self?.hostStatus = enabled ? "Audio enabled by viewer" : "Audio disabled by viewer"
                }
            }
            host.onPeerAddress = { [weak self] address in
                Task { @MainActor in
                    guard self?.hostDestinationAddress != address else { return }
                    self?.hostDestinationAddress = address
                    self?.hostStatus = "Routed stream to viewer \(address)"
                }
            }
            host.onAuthenticatedDevice = { [weak self] credential, sourceHost in
                Task { @MainActor in
                    let route = sourceHost.map(NetworkAddressPolicy.isTailscaleAddress) == true ? "Tailscale" : "Local Wi-Fi"
                    self?.recordAuthenticatedViewer(credential, route: route)
                }
            }
            host.onLocalNetworkSendFailure = { [weak self, weak host] code in
                Task { @MainActor in
                    guard let self, let host else { return }
                    let skipReason: String?
                    if self.host !== host || !self.isHostingRequested {
                        skipReason = "hosting stopped or host replaced"
                    } else if self.didWarnAboutLocalNetworkAccess {
                        skipReason = "warning already shown this hosting session"
                    } else {
                        skipReason = nil
                    }
                    if let skipReason {
                        NSLog("PocketCtrl Local Network warning skipped: %@", skipReason)
                        PocketCtrlHostDiagnostics.write("Local Network warning skipped: \(skipReason)")
                        return
                    }
                    // The sender has already restricted this to a failed LAN
                    // reply to an authenticated viewer. Bonjour's cached success
                    // and the in-app discovery toggle don't establish current
                    // permission to send video. Keep the warning tentative:
                    // unreachable can also mean a genuine network problem.
                    let didShow = self.localNetworkAccessWarningController.showWarning { [weak self] in
                        self?.shouldRetryMediaOnActivation = true
                    }
                    self.didWarnAboutLocalNetworkAccess = didShow
                    NSLog("PocketCtrl Local Network warning presentation visible=%@ errno=%d", didShow.description, code)
                    PocketCtrlHostDiagnostics.write("Local Network warning presentation visible=\(didShow) errno=\(code)")
                }
            }
            host.onActiveControllerChanged = { [weak self] credential, sourceHost in
                Task { @MainActor in
                    guard let credential else {
                        self?.clearActiveController()
                        return
                    }
                    let route = sourceHost.map(NetworkAddressPolicy.isTailscaleAddress) == true ? "Tailscale" : "Local Wi-Fi"
                    self?.recordAuthenticatedController(credential, route: route)
                }
            }
            host.onConnectedViewersChanged = { [weak self] sessions in
                Task { @MainActor in
                    self?.connectedViewers = sessions.map {
                        ConnectedViewer(
                            id: $0.credential.record.id,
                            name: $0.credential.record.name,
                            route: NetworkAddressPolicy.isTailscaleAddress($0.sourceHost) ? "Tailscale" : "Local Wi-Fi",
                            lastSeen: $0.lastSeen
                        )
                    }
                }
            }
            host.onStreamStopped = { [weak self, weak host] error in
                Task { @MainActor in
                    guard let host else { return }
                    self?.handleHostStreamStopped(error, from: host)
                }
            }
            self.host = host
            isHosting = true
            refreshHostNetworkWarning()
            updateSleepActivity()
            updateLocalDiscoveryAdvertisement()
            hostStatus = "Starting capture..."
            NSLog("PocketCtrl model host created")

            Task {
                do {
                    try await host.start()
                    await MainActor.run {
                        guard self.host === host, self.isHosting, self.isHostingRequested else {
                            self.hostLifecycleLogger.info("Ignored completion from superseded host startup")
                            return
                        }
                        self.hostRecoveryAttempt = 0
                        self.hostStatus = self.hostStreamingStatus(configuration)
                        self.hostLifecycleLogger.info("Host capture started successfully")
                        NSLog("PocketCtrl model host async start completed")
                    }
                } catch {
                    await MainActor.run {
                        self.handleHostStartFailure(error, from: host)
                    }
                }
            }
        } catch {
            let nsError = error as NSError
            hostLifecycleLogger.error("Host initialization failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .private)")
            hostStatus = "Host interrupted: \(error.localizedDescription)"
            NSLog("PocketCtrl model host init failed")
            scheduleHostRecovery(reason: "initialization failure")
        }
    }

    func stopHost() {
        isHostingRequested = false
        didWarnAboutLocalNetworkAccess = false
        shouldRestartHostAfterWake = false
        hostRecoveryTask?.cancel()
        hostRecoveryTask = nil
        hostRecoveryAttempt = 0
        hostLifecycleLogger.info("Hosting stopped by user or control request")
        stopHostRuntime(resetStatus: true, revokeSessionCredentials: true)
    }

    private func stopHostRuntime(resetStatus: Bool, revokeSessionCredentials: Bool) {
        NSLog("PocketCtrl model stopHost requested resetStatus=\(resetStatus)")
        host?.stop()
        endPairingMode()
        if revokeSessionCredentials {
            trustedCredentialStore.removeSessionOnlyCredentials()
        }
        clearActiveController()
        connectedViewers = []
        host = nil
        isHosting = false
        updateSleepActivity()
        updateLocalDiscoveryAdvertisement()
        refreshHostNetworkWarning()
        hostFPS = 0
        hostBitrateMbps = 0
        viewerFeedbackStatus = "No viewer feedback yet"
        hostActivityStatus = "No host traffic yet"
        hostInputStatus = "No input received yet"
        if resetStatus {
            hostStatus = "Host idle"
        }
    }

    func restartHostWithCurrentSettings() {
        isHostingRequested = true
        hostRecoveryTask?.cancel()
        hostRecoveryTask = nil
        guard isHosting else {
            startHostIfPossible()
            return
        }

        hostLifecycleLogger.info("Restarting host to apply settings or recover after wake")
        stopHostRuntime(resetStatus: false, revokeSessionCredentials: false)
        hostStatus = "Restarting host..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isHostingRequested, !self.isMacSleeping else { return }
            self.startHostIfPossible()
        }
    }

    func applyHostSettingsIfRunning() {
        guard isHosting else { return }

        var validationStatus = hostStatus
        guard validateHostSettingsForRestart(status: &validationStatus) else {
            hostStatus = validationStatus
            return
        }

        restartHostWithCurrentSettings()
    }

    func startViewer(presentsUserFacingErrors: Bool = false) {
        guard viewer == nil else { return }
        shouldPresentViewerConnectionErrors = presentsUserFacingErrors
        if presentsUserFacingErrors {
            viewerUserFacingIssue = nil
        }
        let hostAddress = NetworkAddressPolicy.normalized(viewerHostAddress)
        NSLog("PocketCtrl model startViewer requested listenPort=\(viewerListenPort) inputPort=\(viewerHostInputPort) audioPort=\(viewerAudioPort)")
        if viewerHostAddress != hostAddress {
            viewerHostAddress = hostAddress
        }
        refreshNetworkAddresses()
        viewerHostWarning = viewerAddressWarning(for: hostAddress)
        guard let listenPort = UInt16(viewerListenPort),
              let audioPort = UInt16(viewerAudioPort),
              let inputPort = UInt16(viewerHostInputPort) else {
            reportViewerConnectionFailure(
                "Ports must be between 1 and 65535.",
                presentsUserFacingErrors: presentsUserFacingErrors
            )
            NSLog("PocketCtrl model startViewer validation failed: invalid ports listen=\(viewerListenPort) input=\(viewerHostInputPort) audio=\(viewerAudioPort)")
            return
        }
        guard !hostAddress.isEmpty else {
            reportViewerConnectionFailure(
                "Enter the Mac host address before connecting.",
                presentsUserFacingErrors: presentsUserFacingErrors
            )
            NSLog("PocketCtrl model startViewer validation failed: empty host")
            return
        }
        guard !NetworkAddressPolicy.isTailscaleAddress(hostAddress) || tailscaleAddress != "Not detected" else {
            reportViewerConnectionFailure(
                "Tailscale is not active on this Mac. Turn on Tailscale, wait for it to connect, then try again.",
                title: "Tailscale Is Off",
                presentsUserFacingErrors: presentsUserFacingErrors
            )
            NSLog("PocketCtrl model startViewer validation failed: Tailscale host entered but this Mac has no Tailscale address")
            return
        }
        guard !isCurrentMacAddress(hostAddress) else {
            reportViewerConnectionFailure(
                "That pairing points back to this Mac. Pair with the other Mac again using Computer Code or a full pairing link.",
                presentsUserFacingErrors: presentsUserFacingErrors
            )
            NSLog("PocketCtrl model startViewer validation failed: host is this Mac")
            return
        }
        guard validateViewerSettings(status: &viewerStatus) else {
            reportViewerConnectionFailure(
                viewerStatus,
                presentsUserFacingErrors: presentsUserFacingErrors
            )
            NSLog("PocketCtrl model startViewer validation failed: \(viewerStatus)")
            return
        }

        let configuration = ViewerConfiguration(
            listenPort: listenPort,
            audioPort: audioPort,
            hostAddress: hostAddress,
            hostInputPort: inputPort,
            controlSecret: viewerPairingSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialID: viewerCredentialID,
            allowsClipboard: viewerAllowsClipboard,
            allowsAudio: viewerAllowsAudio
        )

        do {
            let viewer = try VideoViewerEngine(configuration: configuration)
            viewer.renderer = { [weak self, weak viewer] pixelBuffer in
                DispatchQueue.main.async {
                    guard let self, let viewer, self.viewer === viewer else { return }
                    self.renderView?.display(pixelBuffer)
                }
            }
            viewer.onStats = { [weak self, weak viewer] fps, size, lossPercent, activity in
                Task { @MainActor in
                    guard let self, let viewer, self.viewer === viewer else { return }
                    self.viewerLastFrameAt = Date()
                    self.viewerFPS = fps
                    self.viewerBitrateMbps = activity.receivedMbps
                    self.remoteVideoSize = size
                    self.viewerLossPercent = lossPercent
                    self.viewerActivityStatus = "\(activity.receivedChunks) chunks, \(activity.completedFrames) frames, \(activity.skippedFrames) skipped"
                    self.viewerStatus = self.viewerStreamingStatus(configuration)
                    self.shouldPresentViewerConnectionErrors = false
                    self.viewerUserFacingIssue = nil
                }
            }
            viewer.onInputSent = { [weak self, weak viewer] stats in
                Task { @MainActor in
                    guard let self, let viewer, self.viewer === viewer else { return }
                    self.viewerInputStatus = Self.formatInputStats(prefix: "Sent", stats: stats)
                }
            }
            viewer.onAudioStatus = { [weak self, weak viewer] status in
                Task { @MainActor in
                    guard let self, let viewer, self.viewer === viewer else { return }
                    self.viewerAudioStatus = status
                }
            }
            self.viewer = viewer
            isViewing = true
            remoteControlEnabled = viewerAllowsRemoteInput
            viewerStatus = "Waiting for video from \(configuration.hostAddress)..."
            NSLog("PocketCtrl model viewer created")
            viewer.setStreamSettings(viewerStreamSettings)
            viewer.start()
            UserDefaults.standard.set(viewerCredentialIsPersistent, forKey: Self.shouldAutoReconnectViewerKey)
            viewer.setAudioEnabled(viewerAudioEnabled && viewerAllowsAudio)
            viewerLastFrameAt = nil
            viewerConnectionStartedAt = Date()
            scheduleViewerConnectionWatchdog(for: configuration)
            if viewerCredentialIsPersistent {
                upsertViewerSavedComputerForCurrentConnection(updateLastConnected: true)
            }
        } catch {
            reportViewerConnectionFailure(
                "PocketCtrl could not start the viewer: \(error.localizedDescription)",
                presentsUserFacingErrors: presentsUserFacingErrors
            )
            NSLog("PocketCtrl model viewer init failed")
        }
    }

    func stopViewer() {
        NSLog("PocketCtrl model stopViewer requested")
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectViewerKey)
        stopViewerRuntime(preservePresentation: false)
    }

    private func stopViewerRuntime(preservePresentation: Bool) {
        viewerConnectionWatchdogTask?.cancel()
        viewerConnectionWatchdogTask = nil
        shouldPresentViewerConnectionErrors = false
        viewerUserFacingIssue = nil
        viewerMouseCaptured = false
        viewer?.setAudioEnabled(false)
        viewer?.stop()
        viewer = nil
        remoteControlEnabled = false
        viewerLastFrameAt = nil
        viewerConnectionStartedAt = nil

        guard !preservePresentation else { return }

        isViewing = false
        viewerFPS = 0
        viewerBitrateMbps = 0
        viewerLossPercent = 0
        viewerActivityStatus = "No viewer traffic yet"
        viewerInputStatus = "No input sent yet"
        viewerAudioStatus = viewerAudioEnabled ? "Audio waiting for connection" : "Audio off"
        viewerStatus = "Viewer idle"
    }

    private func scheduleViewerConnectionWatchdog(for configuration: ViewerConfiguration) {
        viewerConnectionWatchdogTask?.cancel()
        viewerConnectionWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                let shouldStop = await MainActor.run {
                    guard let self, self.isViewing else { return true }
                    if let viewerLastFrameAt = self.viewerLastFrameAt,
                       Date().timeIntervalSince(viewerLastFrameAt) < 5 {
                        return false
                    }
                    if let viewerConnectionStartedAt = self.viewerConnectionStartedAt,
                       Date().timeIntervalSince(viewerConnectionStartedAt) < Self.viewerRouteStabilityInterval {
                        return false
                    }
                    if self.tryViewerAlternateRoute(afterFailureAt: configuration.hostAddress) {
                        return true
                    }
                    let route = NetworkAddressPolicy.isTailscaleAddress(configuration.hostAddress) ? "Tailscale" : "local Wi-Fi"
                    self.viewerStatus = "No video from \(configuration.hostAddress) over \(route). Make sure that Mac is hosting and this device is still trusted."
                    if self.shouldPresentViewerConnectionErrors {
                        self.viewerUserFacingIssue = ViewerUserFacingIssue(
                            title: "Connection Taking Too Long",
                            message: self.viewerStatus
                        )
                        self.shouldPresentViewerConnectionErrors = false
                    }
                    return false
                }
                if shouldStop { return }
            }
        }
    }

    func restartViewerWithCurrentSettings() {
        guard isViewing else {
            startViewer()
            return
        }

        let handoffStatus = viewerStatus == "Viewer idle" ? "Switching connection route..." : viewerStatus
        PocketCtrlHostDiagnostics.write("viewer route handoff started from=\(Self.viewerRouteDescription(viewerHostAddress))")
        stopViewerRuntime(preservePresentation: true)
        viewerStatus = handoffStatus
        startViewer()
        if viewer == nil {
            isViewing = false
        }
    }

    func sendInput(_ event: RemoteInputEvent) {
        guard isViewing, remoteControlEnabled else { return }
        viewer?.sendInput(event)
    }

    func updateViewerPointerPosition(_ position: CGPoint) {
        viewerPointerPosition = CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
    }

    func setViewerMouseCaptured(_ captured: Bool) {
        guard isViewing, remoteControlEnabled else {
            viewerMouseCaptured = false
            return
        }
        viewerMouseCaptured = captured
    }

    func retryPreviousViewerConnectionIfNeeded() {
        guard !hasAttemptedViewerAutoReconnect, !isViewing else { return }
        retryViewerCredentialLoadIfNeeded()
        hasAttemptedViewerAutoReconnect = true
        guard UserDefaults.standard.bool(forKey: Self.shouldAutoReconnectViewerKey),
              !viewerHostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              viewerPairingSecret.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 else {
            return
        }

        viewerStatus = "Reconnecting to saved Mac..."
        startViewer()
    }

    func connectToViewerSavedComputer(_ computer: ViewerSavedComputer) {
        if isViewing {
            stopViewer()
        }
        restoreViewerSavedComputer(computer, reason: "manual selection")
        viewerStatus = "Connecting to \(computer.name)..."
        startViewer(presentsUserFacingErrors: true)
    }

    func renameViewerSavedComputer(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = viewerSavedComputers.firstIndex(where: { $0.id == id }) else {
            return
        }
        viewerSavedComputers[index].name = trimmed
        saveViewerSavedComputers()
    }

    func removeViewerSavedComputer(id: String) {
        removeViewerSavedComputers(ids: [id])
    }

    private func removeViewerSavedComputers(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let removedComputers = viewerSavedComputers.filter { ids.contains($0.id) }
        viewerSavedComputers.removeAll { ids.contains($0.id) }
        let retainedCredentialIDs = Set(viewerSavedComputers.map(\.credentialID))
        Set(removedComputers.map(\.credentialID))
            .filter { !$0.isEmpty && !retainedCredentialIDs.contains($0) }
            .forEach { KeychainStore.delete(forKey: viewerSavedComputerCredentialKey(for: $0)) }
        if let selectedID = selectedViewerSavedComputerID, ids.contains(selectedID) {
            selectedViewerSavedComputerID = nil
            UserDefaults.standard.removeObject(forKey: Self.selectedViewerSavedComputerIDKey)
        }
        saveViewerSavedComputers()
    }

    func refreshNetworkAddresses() {
        let nextLocalAddress = Self.localIPAddress() ?? "Not detected"
        let nextTailscaleAddress = Self.tailscaleIPAddress() ?? "Not detected"
        let invitationRouteChanged = localAddress != nextLocalAddress || tailscaleAddress != nextTailscaleAddress
        localAddress = nextLocalAddress
        tailscaleAddress = nextTailscaleAddress
        refreshHostNetworkWarning()
        viewerHostWarning = viewerAddressWarning(for: viewerHostAddress)
        updateLocalDiscoveryAdvertisement()
        if invitationRouteChanged, isPairingModeActive {
            regenerateManualPairingCode()
        }
    }

    private func refreshHostNetworkWarning() {
        guard isHosting, tailscaleAddress == "Not detected" else {
            hostNetworkWarning = nil
            return
        }

        hostNetworkWarning = "Tailscale is not detected. Hosting is still running, but remote pairing over Tailscale will not work until Tailscale is on. Use a trusted local network only if you intentionally need local access."
    }

    func refreshLaunchAtLoginStatus() {
        isApplyingLaunchAtLoginState = true
        launchAtLoginEnabled = LoginItemManager.isLaunchAtLoginEnabled
        isApplyingLaunchAtLoginState = false
        launchAtLoginStatus = LoginItemManager.statusDescription()
    }

    func enableLaunchAtLoginAndAutoStart() {
        launchAtLoginEnabled = true
        autoStartHosting = true
        refreshLaunchAtLoginStatus()
    }

    @discardableResult
    private func applyApprovedPairingPayloadToViewer(_ scannedValue: String, connectedHost: String) -> Bool {
        let trimmed = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "pocketctrl",
              components.host == "paired",
              let secret = components.queryItems?.first(where: { $0.name == "credentialSecret" })?.value?.trimmedNonEmpty,
              let credentialID = components.queryItems?.first(where: { $0.name == "credentialID" })?.value?.trimmedNonEmpty,
              components.queryItems?.first(where: { $0.name == "id" })?.value?.trimmedNonEmpty != nil else {
            return false
        }
        viewerCredentialReadNeedsRetry = false
        viewerPairingSecret = secret
        viewerCredentialID = credentialID
        let queryItems = components.queryItems ?? []
        func enabled(_ name: String) -> Bool {
            queryItems.first(where: { $0.name == name })?.value == "1"
        }
        viewerAllowsRemoteInput = enabled("allowsInput")
        viewerAllowsClipboard = enabled("allowsClipboard")
        viewerAllowsAudio = enabled("allowsAudio")
        viewerCredentialIsPersistent = enabled("persistent")
        UserDefaults.standard.set(viewerCredentialIsPersistent, forKey: Self.shouldAutoReconnectViewerKey)
        let savedCredential = applyPairingQueryItemsToViewer(queryItems, savePairing: viewerCredentialIsPersistent, connectedHost: connectedHost)
        if enabled("persistent") && !savedCredential {
            return false
        }
        return true
    }

    @discardableResult
    func connectToViewerPairingPayload(_ scannedValue: String) -> Bool {
        let trimmed = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "pocketctrl",
              components.host == "pair" else {
            viewerStatus = "Paste a PocketCtrl pairing link or upload the Mac QR."
            return false
        }

        let queryItems = components.queryItems ?? []
        if let requestCode = queryItems.first(where: { $0.name == "request" })?.value {
            if let expiration = queryItems.first(where: { $0.name == "expires" })?.value,
               let expirationDate = ISO8601DateFormatter().date(from: expiration),
               expirationDate <= Date() {
                viewerStatus = "That pairing code expired. Generate a new one on the host Mac."
                return false
            }
            let normalizedCode = PairingInvitationCode.normalized(requestCode)
            guard (try? PairingInvitationCode.decode(normalizedCode)) != nil else {
                viewerStatus = "That pairing QR has an invalid request code. Refresh it on the host Mac."
                return false
            }

            prepareViewerForNewPairingAttempt()
            applyPairingQueryItemsToViewer(queryItems, savePairing: false)
            // An IPv6 link-local-only host is located by Bonjour. Its remote
            // interface index cannot be used on this Mac.

            viewerStatus = "Approve the pairing request on the host Mac."
            connectToViewerManualPairingCode(normalizedCode, updatesViewerStatus: true)
            return true
        }

        viewerStatus = "Only a temporary PocketCtrl pairing invitation can be scanned."
        return false
    }

    @discardableResult
    private func connectToViewerApprovedPairingPayload(_ payload: String, connectedHost: String) -> Bool {
        let statusBeforeApplying = viewerStatus
        guard applyApprovedPairingPayloadToViewer(payload, connectedHost: connectedHost) else {
            if viewerStatus == statusBeforeApplying {
                viewerStatus = "The approved pairing response was invalid."
            }
            return false
        }
        if isViewing { stopViewer() }
        viewerStatus = "Connecting to approved Mac..."
        startViewer(presentsUserFacingErrors: true)
        return isViewing
    }

    var lanPairingQRCodePayload: String {
        pairingPayload(
            credentialName: "request",
            credentialValue: PairingInvitationCode.normalized(manualPairingCode),
            expiresAt: manualPairingExpiresAt
        )
    }

    private func pairingCredentialPayload(for credential: TrustedDeviceCredential) -> String {
        var components = pairingURLComponents()
        components.host = "paired"
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "credentialID", value: credential.record.id),
            URLQueryItem(name: "credentialSecret", value: credential.secret),
            URLQueryItem(name: "persistent", value: credential.record.accessMode == .unattended ? "1" : "0"),
            URLQueryItem(name: "allowsInput", value: credential.record.allowsRemoteInput ? "1" : "0"),
            URLQueryItem(name: "allowsClipboard", value: credential.record.allowsClipboard ? "1" : "0"),
            URLQueryItem(name: "allowsAudio", value: credential.record.allowsAudio ? "1" : "0")
        ]
        return components.url?.absoluteString ?? ""
    }

    private func pairingPayload(
        credentialName: String,
        credentialValue: String,
        expiresAt: Date?
    ) -> String {
        var components = pairingURLComponents()
        var queryItems = [URLQueryItem(name: credentialName, value: credentialValue)] + (components.queryItems ?? [])
        if let expiresAt {
            queryItems.append(URLQueryItem(name: "expires", value: ISO8601DateFormatter().string(from: expiresAt)))
        }
        components.queryItems = queryItems.filter { $0.value?.isEmpty == false }
        return components.url?.absoluteString ?? "pocketctrl://pair"
    }

    private func pairingURLComponents() -> URLComponents {
        var components = URLComponents()
        components.scheme = "pocketctrl"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "id", value: hostID),
            URLQueryItem(name: "name", value: Self.hostDisplayName),
            URLQueryItem(name: "host", value: localAddress == "Not detected" ? nil : IPNetwork.pairingLocalHost(advertised: localAddress)),
            URLQueryItem(name: "tailscale", value: tailscaleAddress == "Not detected" ? nil : tailscaleAddress),
            URLQueryItem(name: "video", value: hostVideoPort),
            URLQueryItem(name: "audio", value: hostAudioPort),
            URLQueryItem(name: "input", value: hostInputPort),
            URLQueryItem(name: "mac", value: Self.localMACAddress())
        ].filter { $0.value?.isEmpty == false }
        return components
    }

    func attachRenderer(_ view: PixelBufferRenderView) {
        renderView = view
    }

    private func hostStreamingStatus(_ configuration: HostConfiguration) -> String {
        let audio = hostAudioEnabled ? ", audio \(configuration.audioPort)" : ""
        return "Streaming to \(hostDestinationAddress):\(configuration.videoPort)\(audio)"
    }

    private func viewerStreamingStatus(_ configuration: ViewerConfiguration) -> String {
        "Connected to \(configuration.hostAddress)"
    }

    private func viewerAddressWarning(for address: String) -> String? {
        let address = NetworkAddressPolicy.normalized(address)
        guard !address.isEmpty else { return nil }
        if isCurrentMacAddress(address) {
            return "This pairing points back to this Mac. Pair with the other Mac again."
        }
        if NetworkAddressPolicy.isTailscaleAddress(address), tailscaleAddress == "Not detected" {
            return "Tailscale is not active on this Mac."
        }
        return nil
    }

    private func reportViewerConnectionFailure(
        _ message: String,
        title: String = "Unable to Connect",
        presentsUserFacingErrors: Bool
    ) {
        viewerStatus = message
        shouldPresentViewerConnectionErrors = false
        if presentsUserFacingErrors {
            viewerUserFacingIssue = ViewerUserFacingIssue(title: title, message: message)
        }
    }

    private func isCurrentMacAddress(_ address: String) -> Bool {
        let address = NetworkAddressPolicy.normalized(address)
        guard !address.isEmpty else { return false }
        if address == "127.0.0.1" || address.lowercased() == "localhost" { return true }
        if tailscaleAddress != "Not detected", address == tailscaleAddress { return true }
        if localAddress != "Not detected", address == localAddress { return true }
        return false
    }

    private func validateViewerSettings(status: inout String) -> Bool {
        guard viewerPairingSecret.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32,
              !viewerCredentialID.isEmpty else {
            status = "Pair this device again to obtain its encrypted device credential"
            return false
        }
        return true
    }

    private func validateHostSettingsForRestart(status: inout String) -> Bool {
        guard screenRecordingGranted,
              accessibilityGranted || !remoteInputEnabled else {
            status = "Setup required before hosting changes can apply."
            return false
        }

        guard directCaptureApproved else {
            status = "Screen access is still unavailable. If you just enabled Screen Recording, quit and reopen PocketCtrl."
            return false
        }

        let destinationAddress = NetworkAddressPolicy.normalized(hostDestinationAddress)
        if destinationAddress.isEmpty {
            status = "Viewer IP is required before hosting changes can apply."
            return false
        }

        guard UInt16(hostVideoPort) != nil,
              UInt16(hostAudioPort) != nil,
              UInt16(hostInputPort) != nil else {
            status = "Ports must be between 1 and 65535 before hosting changes can apply."
            return false
        }

        return true
    }

    private func observeWakeEvents() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleMacWillSleep()
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleMacWake()
                }
            }
            .store(in: &cancellables)
    }

    private func observeSetupPermissionRefreshEvents() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.shouldRetryMediaOnActivation {
                        self.shouldRetryMediaOnActivation = false
                        self.host?.retryFailedMediaConnections()
                    }
                    self.retryTrustedDeviceCredentialLoadsIfNeeded()
                    let restoredCredential = self.retryViewerCredentialLoadIfNeeded()
                    if restoredCredential,
                       self.hasAttemptedViewerAutoReconnect,
                       !self.isViewing,
                       UserDefaults.standard.bool(forKey: Self.shouldAutoReconnectViewerKey) {
                        self.viewerStatus = "Reconnecting to saved Mac..."
                        self.startViewer()
                    }
                    guard self.shouldRefreshSetupOnActivation else { return }
                    self.shouldRefreshSetupOnActivation = false
                    await self.refreshSetupStatus(probeDirectCapture: true)
                }
            }
            .store(in: &cancellables)
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkPathChange(path)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func handleNetworkPathChange(_ path: NWPath) {
        let now = Date()
        guard now.timeIntervalSince(lastNetworkRefreshAt) >= 1 else { return }
        lastNetworkRefreshAt = now

        let oldLocalAddress = localAddress
        let oldTailscaleAddress = tailscaleAddress
        refreshNetworkAddresses()
        updateLocalDiscoveryAdvertisement()
        updateViewerRouteAfterNetworkChange()

        guard oldLocalAddress != localAddress || oldTailscaleAddress != tailscaleAddress || path.status != .satisfied else {
            return
        }

        if path.status == .satisfied {
            if isHosting {
                hostStatus = "Network changed. Host is ready on \(localAddress). Reconnect or rescan if the phone saved the old Wi-Fi IP."
            }
        } else if isHosting {
            hostStatus = "Network unavailable. Hosting will recover when Wi-Fi returns."
        }
    }

    private func configureLocalDiscoveryCallbacks() {
        localDiscoveryAdvertiser.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.handleLocalDiscoveryStatus(status, isPermissionProbe: false)
            }
        }

        localNetworkPermissionProbe.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.handleLocalDiscoveryStatus(status, isPermissionProbe: true)
            }
        }
    }

    private func configureManualPairingDiscoveryCallbacks() {
        manualPairingBrowser.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self, self.manualPairingDiscoveryActive else { return }
                self.manualPairingStatus = status
            }
        }

        manualPairingBrowser.onHostResolved = { [weak self] host in
            Task { @MainActor in
                guard let self else { return }
                if self.manualPairingDiscoveryActive {
                    self.manualPairingDiscoveredHosts[host.hostID] = host
                    self.manualPairingStatus = "Found \(host.hostName ?? "PocketCtrl host")."
                } else {
                    self.applyViewerDiscoveredHost(host)
                }
            }
        }
    }

    private func startViewerLocalDiscoveryIfPossible() {
        guard !manualPairingDiscoveryActive else { return }
        let hostID = viewerPairedHostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostID.isEmpty else {
            manualPairingBrowser.stop()
            return
        }
        manualPairingBrowser.start(targetHostID: hostID)
    }

    private func applyViewerDiscoveredHost(_ host: DiscoveredPocketCtrlHost) {
        guard host.hostID == viewerPairedHostID else { return }
        let discoveredLocal = NetworkAddressPolicy.normalized(host.localAddress)
        guard NetworkAddressPolicy.isPrivateOrLocalAddress(discoveredLocal),
              !NetworkAddressPolicy.isTailscaleAddress(discoveredLocal),
              !isCurrentMacAddress(discoveredLocal) else {
            return
        }

        viewerLocalHostAddress = discoveredLocal
        if let discoveredTailscale = host.tailscaleAddress.map(NetworkAddressPolicy.normalized),
           NetworkAddressPolicy.isTailscaleAddress(discoveredTailscale) {
            viewerTailscaleHostAddress = discoveredTailscale
        }
        if let videoPort = host.videoPort, UInt16(videoPort) != nil {
            viewerListenPort = videoPort
        }
        if let audioPort = host.audioPort, UInt16(audioPort) != nil {
            viewerAudioPort = audioPort
        }
        if let inputPort = host.inputPort, UInt16(inputPort) != nil {
            viewerHostInputPort = inputPort
        }

        let nextHost = preferredViewerHost(
            localHost: viewerLocalHostAddress,
            tailscaleHost: viewerTailscaleHostAddress,
            fallbackHost: viewerHostAddress
        )
        if viewerCredentialIsPersistent {
            upsertViewerSavedComputerFromCurrent(
                name: host.hostName,
                hostID: host.hostID,
                localHostAddress: viewerLocalHostAddress,
                tailscaleHostAddress: viewerTailscaleHostAddress,
                wakeMACAddress: host.macAddress,
                updateLastConnected: false
            )
        }

        guard !nextHost.isEmpty,
              nextHost != NetworkAddressPolicy.normalized(viewerHostAddress) else {
            return
        }

        if shouldKeepCurrentViewerRoute {
            PocketCtrlHostDiagnostics.write("viewer discovery retained healthy route current=\(Self.viewerRouteDescription(viewerHostAddress)) candidate=\(Self.viewerRouteDescription(nextHost))")
            return
        }

        viewerHostAddress = nextHost
        if isViewing {
            viewerStatus = "Found the paired Mac at \(nextHost). Switching route..."
            restartViewerWithCurrentSettings()
        }
    }

    func beginPairingMode() {
        guard isHosting else {
            manualPairingStatus = "Start hosting before pairing a device"
            return
        }
        isPairingModeActive = true
        manualPairingServer.start(model: self)
        regenerateManualPairingCode()
    }

    func endPairingMode(allowPendingResponseToFinish: Bool = false) {
        isPairingModeActive = false
        manualPairingRefreshTask?.cancel()
        manualPairingRefreshTask = nil
        manualPairingCode = ""
        manualPairingExpiresAt = .distantPast
        manualPairingStatus = "Pairing is closed"
        let hadPendingRequest = pendingManualPairingRequest != nil
        if hadPendingRequest {
            denyManualPairingRequest(reason: .timedOut)
        }
        manualPairingServer.stop(
            allowActiveConnectionsToFinish: allowPendingResponseToFinish || hadPendingRequest
        )
    }

    func regenerateManualPairingCode() {
        guard isPairingModeActive else {
            beginPairingMode()
            return
        }
        let tailscale = NetworkAddressPolicy.isTailscaleAddress(tailscaleAddress) ? tailscaleAddress : nil
        manualPairingCode = PairingInvitationCode.generate(tailscaleAddress: tailscale)
        manualPairingExpiresAt = Date().addingTimeInterval(Self.manualPairingCodeLifetime)
        manualPairingStatus = "Computer code active"
        scheduleManualPairingCodeRefresh(expiresAt: manualPairingExpiresAt)
    }

    private func scheduleManualPairingCodeRefresh(expiresAt: Date) {
        manualPairingRefreshTask?.cancel()
        manualPairingRefreshTask = Task { [weak self] in
            let delay = max(0, expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.manualPairingExpiresAt == expiresAt else { return }
                self.endPairingMode()
            }
        }
    }

    func connectToViewerManualPairingCode(_ rawCode: String, updatesViewerStatus: Bool = false) {
        let code = PairingInvitationCode.normalized(rawCode)
        let invitation: DecodedPairingInvitationCode
        do {
            invitation = try PairingInvitationCode.decode(code)
        } catch {
            manualPairingStatus = error.localizedDescription
            if updatesViewerStatus {
                viewerStatus = manualPairingStatus
            }
            return
        }

        prepareViewerForNewPairingAttempt()
        manualPairingConnectionTask?.cancel()
        manualPairingDiscoveredHosts.removeAll()
        manualPairingDiscoveryActive = true
        manualPairingBrowser.start(targetHostID: nil)
        manualPairingStatus = "Looking for your Mac nearby and through Tailscale..."
        if updatesViewerStatus {
            viewerStatus = manualPairingStatus
        }

        manualPairingConnectionTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            let candidates = await MainActor.run { self.manualPairingCandidates(invitation: invitation) }
            guard !candidates.isEmpty else {
                await MainActor.run {
                    self.manualPairingDiscoveryActive = false
                    self.startViewerLocalDiscoveryIfPossible()
                    self.manualPairingStatus = invitation.tailscaleAddress == nil
                        ? "Connect both devices to the same Wi-Fi, then try again."
                        : "Turn on Tailscale or connect both devices to the same Wi-Fi."
                    if updatesViewerStatus {
                        self.viewerStatus = self.manualPairingStatus
                    }
                }
                return
            }

            do {
                let result = try await self.raceManualPairingRequests(code: code, candidates: candidates)
                await MainActor.run {
                    self.manualPairingDiscoveryActive = false
                    self.manualPairingStatus = "Approved by \(result.response.hostName) through \(result.candidate.routeDescription). Connecting..."
                    _ = self.connectToViewerApprovedPairingPayload(result.response.pairingURL, connectedHost: result.candidate.host)
                    self.startViewerLocalDiscoveryIfPossible()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.manualPairingDiscoveryActive = false
                    self.startViewerLocalDiscoveryIfPossible()
                }
                return
            } catch {
                await MainActor.run {
                    self.manualPairingDiscoveryActive = false
                    self.startViewerLocalDiscoveryIfPossible()
                    self.manualPairingStatus = error.localizedDescription
                    if updatesViewerStatus {
                        self.viewerStatus = self.manualPairingStatus
                    }
                }
            }
        }
    }

    func handleManualPairingRequest(
        code: String,
        viewerName: String?,
        sourceAddress: String,
        routeDescription: String,
        deviceFingerprint: String,
        completion: @escaping (Result<ManualPairingResponse, ManualPairingApprovalError>) -> Void
    ) {
        guard isHosting else {
            completion(.failure(.hostingRequired))
            return
        }
        guard isPairingModeActive else {
            completion(.failure(.codeExpired))
            return
        }
        if Date() >= manualPairingExpiresAt {
            regenerateManualPairingCode()
            completion(.failure(.codeExpired))
            return
        }
        guard PairingInvitationCode.normalized(code) == PairingInvitationCode.normalized(manualPairingCode) else {
            completion(.failure(.invalidCode))
            return
        }
        guard pendingManualPairingRequest == nil else {
            completion(.failure(.requestAlreadyPending))
            return
        }

        let request = PendingManualPairingRequest(
            id: UUID(),
            viewerName: viewerName?.trimmedNonEmpty ?? "Another Mac",
            sourceAddress: sourceAddress,
            routeDescription: routeDescription,
            deviceFingerprint: deviceFingerprint,
            requestedAt: Date()
        )
        pendingManualPairingRequest = request
        manualPairingApprovalCompletions[request.id] = completion

        // Give the Mac owner time to notice the request, read it, and authenticate.
        // The requesting device waits slightly longer than this before giving up.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.manualPairingApprovalWindow))
            await MainActor.run {
                guard self?.pendingManualPairingRequest?.id == request.id else { return }
                self?.denyManualPairingRequest(reason: .timedOut)
            }
        }
    }

    func approveManualPairingRequest(_ request: PendingManualPairingRequest, options: PairingApprovalOptions) async {
        guard pendingManualPairingRequest?.id == request.id,
              manualPairingApprovalCompletions[request.id] != nil,
              !approvalAuthenticationInProgress else {
            return
        }

        approvalAuthenticationInProgress = true
        defer { approvalAuthenticationInProgress = false }
        let context = LAContext()
        context.localizedCancelTitle = "Do Not Pair"
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Approve a new device that may view and control this Mac"
            )
        } catch {
            manualPairingStatus = "Pairing was not approved by the Mac owner"
            return
        }

        guard pendingManualPairingRequest?.id == request.id,
              let completion = manualPairingApprovalCompletions.removeValue(forKey: request.id) else {
            return
        }

        let credentialID = UUID().uuidString.lowercased()
        let record = TrustedDeviceRecord(
            id: credentialID,
            name: request.viewerName,
            createdAt: Date(),
            lastConnectedAt: nil,
            allowsRemoteInput: options.allowsRemoteInput,
            allowsClipboard: options.allowsClipboard,
            allowsAudio: options.allowsAudio,
            accessMode: options.accessMode
        )
        let credential = TrustedDeviceCredential(record: record, secret: PocketCtrlCredentialGenerator.secret())
        if options.accessMode == .unattended {
            let credentialKey = Self.trustedDeviceSecretPrefix + credentialID
            guard KeychainStore.set(credential.secret, forKey: credentialKey) else {
                KeychainStore.delete(forKey: credentialKey)
                pendingManualPairingRequest = nil
                completion(.failure(.credentialStorageFailed))
                endPairingMode(allowPendingResponseToFinish: true)
                trustedDeviceStorageWarning = ManualPairingApprovalError.credentialStorageFailed.message
                manualPairingStatus = ManualPairingApprovalError.credentialStorageFailed.message
                PocketCtrlHostDiagnostics.write("pairing approval failed because secure credential storage was unavailable")
                return
            }
            pendingPersistentPairingCredentials[credentialID] = credential
        }
        trustedCredentialStore.insert(credential)
        if options.allowsRemoteInput {
            remoteInputEnabled = true
        }

        let response = ManualPairingResponse(
            pairingURL: pairingCredentialPayload(for: credential),
            hostName: Self.hostDisplayName,
            expiresAt: ISO8601DateFormatter().string(from: manualPairingExpiresAt),
            credentialID: credentialID
        )
        pendingManualPairingRequest = nil
        completion(.success(response))
        endPairingMode(allowPendingResponseToFinish: true)
    }

    func finalizeIssuedPairingCredential(id: String) {
        guard let credential = pendingPersistentPairingCredentials.removeValue(forKey: id),
              credential.record.accessMode == .unattended else {
            return
        }
        let credentialKey = Self.trustedDeviceSecretPrefix + id
        guard case let .value(savedSecret) = KeychainStore.readString(forKey: credentialKey),
              savedSecret == credential.secret else {
            discardIssuedPairingCredential(id: id)
            trustedDeviceStorageWarning = ManualPairingApprovalError.credentialStorageFailed.message
            PocketCtrlHostDiagnostics.write("did not persist trusted device because its secure credential could not be reverified")
            return
        }
        if !trustedDevices.contains(where: { $0.id == id }) {
            trustedDevices.append(credential.record)
        }
        if let index = storedTrustedDeviceRecords.firstIndex(where: { $0.id == id }) {
            storedTrustedDeviceRecords[index] = credential.record
        } else {
            storedTrustedDeviceRecords.append(credential.record)
        }
        saveTrustedDevices()
        trustedDeviceStorageWarning = nil
        PocketCtrlHostDiagnostics.write("persisted trusted device after pairing response delivery")
    }

    func discardIssuedPairingCredential(id: String) {
        pendingPersistentPairingCredentials.removeValue(forKey: id)
        trustedCredentialStore.remove(deviceID: id)
        KeychainStore.delete(forKey: Self.trustedDeviceSecretPrefix + id)
        trustedDevices.removeAll { $0.id == id }
        storedTrustedDeviceRecords.removeAll { $0.id == id }
        saveTrustedDevices()
        PocketCtrlHostDiagnostics.write("discarded pairing credential after response delivery failed")
    }

    func denyManualPairingRequest(_ request: PendingManualPairingRequest) {
        guard pendingManualPairingRequest?.id == request.id else { return }
        denyManualPairingRequest(reason: .denied)
    }

    private func denyManualPairingRequest(reason: ManualPairingApprovalError) {
        guard let request = pendingManualPairingRequest else { return }
        pendingManualPairingRequest = nil
        manualPairingApprovalCompletions.removeValue(forKey: request.id)?(.failure(reason))
    }

    func revokeTrustedDevice(_ device: TrustedDeviceRecord) {
        host?.disconnectViewer(deviceID: device.id)
        trustedCredentialStore.remove(deviceID: device.id)
        KeychainStore.delete(forKey: Self.trustedDeviceSecretPrefix + device.id)
        trustedDevices.removeAll { $0.id == device.id }
        storedTrustedDeviceRecords.removeAll { $0.id == device.id }
        saveTrustedDevices()
        if activeControllerID == device.id {
            clearActiveController()
        }
    }

    func disconnectActiveController(revoke: Bool) {
        guard let deviceID = activeControllerID else { return }
        disconnectViewer(deviceID: deviceID, revoke: revoke)
    }

    func disconnectViewer(deviceID: String, revoke: Bool) {
        if revoke, let record = trustedDevices.first(where: { $0.id == deviceID }) {
            revokeTrustedDevice(record)
            return
        } else {
            host?.disconnectViewer(deviceID: deviceID)
            trustedCredentialStore.suspend(deviceID: deviceID)
        }
        connectedViewers.removeAll { $0.id == deviceID }
        if activeControllerID == deviceID {
            clearActiveController()
        }
    }

    func recordAuthenticatedViewer(_ credential: TrustedDeviceCredential, route: String) {
        let seenAt = Date()
        guard let storedIndex = storedTrustedDeviceRecords.firstIndex(where: { $0.id == credential.record.id }) else { return }
        let previousSeenAt = storedTrustedDeviceRecords[storedIndex].lastConnectedAt ?? .distantPast
        guard seenAt.timeIntervalSince(previousSeenAt) >= 30 else { return }
        if let index = trustedDevices.firstIndex(where: { $0.id == credential.record.id }) {
            trustedDevices[index].lastConnectedAt = seenAt
        }
        storedTrustedDeviceRecords[storedIndex].lastConnectedAt = seenAt
        saveTrustedDevices()
    }

    func recordAuthenticatedController(_ credential: TrustedDeviceCredential, route: String) {
        let seenAt = Date()
        activeControllerID = credential.record.id
        activeControllerName = credential.record.name
        activeControllerRoute = route
        activeControllerLastSeen = seenAt
        recordAuthenticatedViewer(credential, route: route)
    }

    private func clearActiveController() {
        activeControllerID = nil
        activeControllerName = nil
        activeControllerRoute = nil
        activeControllerLastSeen = nil
    }

    private func handleLocalDiscoveryStatus(_ status: String, isPermissionProbe: Bool) {
        // These publisher statuses contain fixed labels and numeric Bonjour errors,
        // not service names or device addresses. Success is not a TCC API result.
        PocketCtrlHostDiagnostics.connection("discovery.publisherStatus probe=\(isPermissionProbe) status=\(status)")
        if status == "Local discovery on" {
            localNetworkApproved = true
            localDiscoveryStatus = isPermissionProbe ? "Discovery available · video is checked when a device connects" : status
            if isPermissionProbe {
                localNetworkProbeTask?.cancel()
                localNetworkProbeTask = nil
                localNetworkPermissionProbe.stop()
            }
            return
        }

        if status.hasPrefix("Local discovery failed") {
            localNetworkApproved = false
            localDiscoveryStatus = isPermissionProbe ? "Local Network not allowed: \(status)" : status
            return
        }

        localDiscoveryStatus = isPermissionProbe ? "Checking Local Network approval..." : status
    }

    private func probeLocalNetworkPermission() {
        guard !isHosting else {
            updateLocalDiscoveryAdvertisement()
            return
        }

        localNetworkProbeTask?.cancel()
        localNetworkPermissionProbe.stop()
        localNetworkPermissionProbe.publish(localDiscoveryAdvertisement)
        localNetworkProbeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !localNetworkApproved {
                    localNetworkPermissionProbe.stop()
                    localDiscoveryStatus = "Local Network not confirmed yet. If you just enabled it, click Recheck Setup."
                }
            }
        }
    }

    private func updateLocalDiscoveryAdvertisement() {
        PocketCtrlHostDiagnostics.connection("discovery.advertiseDecision enabled=\(allowLocalDiscovery) hosting=\(isHosting) publisherPreviouslySucceeded=\(localNetworkApproved) host=\(PocketCtrlHostDiagnostics.identifierTag(hostID))")
        guard allowLocalDiscovery else {
            localDiscoveryAdvertiser.stop()
            localDiscoveryStatus = "Local discovery off"
            return
        }

        guard isHosting else {
            localDiscoveryAdvertiser.stop()
            localDiscoveryStatus = "Local discovery idle"
            return
        }

        // Bonjour gives an already-authorized device a current LAN route. The
        // advertised address is never sufficient to authenticate a session.
        localDiscoveryAdvertiser.publish(localDiscoveryAdvertisement)
    }

    private var localDiscoveryAdvertisement: LocalDiscoveryAdvertisement {
        LocalDiscoveryAdvertisement(
            hostID: hostID,
            hostName: Self.hostDisplayName,
            videoPort: hostVideoPort,
            audioPort: hostAudioPort,
            inputPort: hostInputPort,
            localAddress: localAddress,
            tailscaleAddress: tailscaleAddress,
            macAddress: Self.localMACAddress() ?? ""
        )
    }

    private struct ManualPairingCandidate: Hashable {
        let name: String
        let host: String
        let routeDescription: String
    }

    private struct ManualPairingRaceResult {
        let response: ManualPairingResponse
        let candidate: ManualPairingCandidate
    }

    private struct ManualPairingAttemptResult {
        let response: ManualPairingResponse?
        let candidate: ManualPairingCandidate
        let errorMessage: String?
    }

    private func manualPairingCandidates(invitation: DecodedPairingInvitationCode) -> [ManualPairingCandidate] {
        var candidates: [ManualPairingCandidate] = []

        func appendLocal(_ host: String?, name: String) {
            let normalized = NetworkAddressPolicy.normalized(host ?? "")
            guard !normalized.isEmpty,
                  NetworkAddressPolicy.isPrivateOrLocalAddress(normalized),
                  !IPNetwork.isLoopback(normalized),
                  !Self.interfaceIPAddresses().contains(where: { $0.address == normalized }),
                  !NetworkAddressPolicy.isTailscaleAddress(normalized) else {
                return
            }
            candidates.append(ManualPairingCandidate(name: name, host: normalized, routeDescription: "Local Wi-Fi"))
        }

        if let selectedID = selectedViewerSavedComputerID,
           let selected = viewerSavedComputers.first(where: { $0.id == selectedID }) {
            appendLocal(selected.localHostAddress, name: selected.name)
            appendLocal(selected.hostAddress, name: selected.name)
        }

        appendLocal(viewerLocalHostAddress, name: "Paired Mac")
        appendLocal(viewerHostAddress, name: "Entered Mac")

        for computer in viewerSavedComputers {
            appendLocal(computer.localHostAddress, name: computer.name)
            appendLocal(computer.hostAddress, name: computer.name)
        }

        for host in manualPairingDiscoveredHosts.values {
            let name = host.hostName ?? "Nearby Mac"
            appendLocal(host.localAddress, name: name)
        }

        if Self.tailscaleIPAddress() != nil {
            for tailscaleHost in IPNetwork.pairingTailscaleCandidates(codeHost: invitation.tailscaleAddress, advertisedHost: viewerTailscaleHostAddress) {
                guard !Self.interfaceIPAddresses().contains(where: { $0.address == tailscaleHost }) else { continue }
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
                        let response = try await ManualPairingTransport.request(
                            code: code,
                            viewerName: Self.hostDisplayName,
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
                    .map { _ in "That pairing code expired or is no longer active. Generate a new one on the host Mac." }
                ?? (failures.contains(where: { $0.candidate.routeDescription == "Tailscale" })
                    ? "This Mac is not reachable through your current tailnet. Your Tailscale access rules may be blocking PocketCtrl on port 47778."
                    : messages.first ?? "No Mac approved the request.")
            throw ManualPairingClientError(message)
        }
    }

    private func handleMacWillSleep() {
        isMacSleeping = true
        hostRecoveryTask?.cancel()
        hostRecoveryTask = nil
        guard isHostingRequested || isHosting else { return }

        shouldRestartHostAfterWake = true
        hostLifecycleLogger.info("Mac will sleep; pausing requested host")
        if isHosting {
            stopHostRuntime(resetStatus: false, revokeSessionCredentials: false)
        }
        hostStatus = "Host paused while this Mac sleeps."
        hostActivityStatus = "Waiting for Mac wake"
    }

    private func handleMacWake() {
        isMacSleeping = false
        refreshNetworkAddresses()
        hostLifecycleLogger.info("Mac woke; hostingRequested=\(self.isHostingRequested, privacy: .public) runtimeHosting=\(self.isHosting, privacy: .public) restartPending=\(self.shouldRestartHostAfterWake, privacy: .public)")
        if isHosting {
            hostStatus = "Mac woke. Restarting host..."
            restartHostWithCurrentSettings()
            return
        }

        guard isHostingRequested || shouldRestartHostAfterWake else { return }
        isHostingRequested = true
        shouldRestartHostAfterWake = false
        Task {
            await refreshSetupStatus()
            guard isHostingRequested, !isMacSleeping else { return }
            startHostIfPossible()
        }
    }

    private func handleHostStreamStopped(_ error: Error, from stoppedHost: ScreenCaptureHost) {
        guard host === stoppedHost, isHosting else {
            hostLifecycleLogger.info("Ignored stop event from superseded host instance")
            return
        }

        let nsError = error as NSError
        hostLifecycleLogger.error("Active host stream stopped domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) sleeping=\(self.isMacSleeping, privacy: .public) description=\(nsError.localizedDescription, privacy: .private)")
        stopHostRuntime(resetStatus: false, revokeSessionCredentials: false)
        hostActivityStatus = "Stream stopped: \(error.localizedDescription)"

        if isMacSleeping {
            shouldRestartHostAfterWake = true
            hostStatus = "Host paused while this Mac sleeps."
        } else {
            hostStatus = "Host interrupted. Preparing to recover..."
            scheduleHostRecovery(reason: "capture stream stopped")
        }
    }

    private func handleHostStartFailure(_ error: Error, from failedHost: ScreenCaptureHost) {
        guard host === failedHost else {
            hostLifecycleLogger.info("Ignored failure from superseded host startup")
            return
        }

        let nsError = error as NSError
        hostLifecycleLogger.error("Host startup failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .private)")
        NSLog("PocketCtrl model host async start failed")
        stopHostRuntime(resetStatus: false, revokeSessionCredentials: false)
        hostStatus = "Host interrupted: \(error.localizedDescription)"
        scheduleHostRecovery(reason: "capture startup failure")
    }

    private func scheduleHostRecovery(reason: String) {
        guard isHostingRequested, !isMacSleeping, hostRecoveryTask == nil else { return }

        hostRecoveryAttempt += 1
        let exponent = min(max(hostRecoveryAttempt - 1, 0), 5)
        let delay = min(pow(2.0, Double(exponent)), 30)
        hostStatus = "Host interrupted. Retrying in \(Int(delay))s..."
        hostLifecycleLogger.warning("Scheduled host recovery attempt=\(self.hostRecoveryAttempt, privacy: .public) delaySeconds=\(delay, privacy: .public) reason=\(reason, privacy: .public)")
        PocketCtrlHostDiagnostics.write("scheduled host recovery attempt=\(hostRecoveryAttempt) delaySeconds=\(delay) reason=\(reason)")

        hostRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.hostRecoveryTask = nil
            guard self.isHostingRequested, !self.isMacSleeping, !self.isHosting else { return }
            self.hostLifecycleLogger.info("Attempting automatic host recovery attempt=\(self.hostRecoveryAttempt, privacy: .public)")
            self.startHostIfPossible()
        }
    }

    private func updateSleepActivity() {
        let shouldPreventIdleSleep = isHostingRequested && keepAwakeWhileHosting

        if shouldPreventIdleSleep {
            guard sleepActivity == nil else { return }
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "PocketCtrl is hosting remote access"
            )
            isSleepPreventionActive = true
            powerManagementLogger.info("Idle system sleep prevention activated hostingRequested=\(self.isHostingRequested, privacy: .public) runtimeHosting=\(self.isHosting, privacy: .public)")
            PocketCtrlHostDiagnostics.write("idle system sleep prevention activated")
        } else if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
            self.sleepActivity = nil
            isSleepPreventionActive = false
            powerManagementLogger.info("Idle system sleep prevention released hostingRequested=\(self.isHostingRequested, privacy: .public) keepAwakeEnabled=\(self.keepAwakeWhileHosting, privacy: .public)")
            PocketCtrlHostDiagnostics.write("idle system sleep prevention released")
        } else {
            isSleepPreventionActive = false
        }
    }

    private func syncLaunchAtLoginSetting() {
        launchAtLoginStatus = LoginItemManager.syncLaunchAtLogin(enabled: launchAtLoginEnabled)
        let actualEnabled = LoginItemManager.isLaunchAtLoginEnabled
        guard actualEnabled != launchAtLoginEnabled else { return }
        isApplyingLaunchAtLoginState = true
        launchAtLoginEnabled = actualEnabled
        isApplyingLaunchAtLoginState = false
    }

    private func scheduleSetupStatusRefresh(reason: String) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refreshSetupStatus()
            permissionLogger.info(
                "Delayed permission refresh after \(reason, privacy: .public): accessibility=\(self.accessibilityGranted, privacy: .public), screenRecording=\(self.screenRecordingGranted, privacy: .public), directCapture=\(self.directCaptureApproved, privacy: .public), localNetwork=\(self.localNetworkApproved, privacy: .public)"
            )
            refreshLaunchAtLoginStatus()
        }
    }

    private func logPermissionSnapshot(reason: String) {
        permissionLogger.info(
            """
            Permission snapshot (\(reason, privacy: .public)): \
            bundleID=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public), \
            path=\(Bundle.main.bundleURL.path, privacy: .private), \
            accessibility=\(self.accessibilityGranted, privacy: .public), \
            screenRecording=\(self.screenRecordingGranted, privacy: .public), \
            directCapture=\(self.directCaptureApproved, privacy: .public), \
            localNetwork=\(self.localNetworkApproved, privacy: .public)
            """
        )
    }

    private static var hostDisplayName: String {
        let localizedName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let localizedName, !localizedName.isEmpty {
            return localizedName
        }

        let hostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? "Mac" : hostName
    }

    private static func loadViewerSavedComputers() -> [ViewerSavedComputer] {
        guard let data = UserDefaults.standard.data(forKey: viewerSavedComputersKey) else { return [] }
        return (try? JSONDecoder().decode([ViewerSavedComputer].self, from: data)) ?? []
    }

    private static func loadTrustedDeviceRecords() -> [TrustedDeviceRecord] {
        guard let data = UserDefaults.standard.data(forKey: trustedDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([TrustedDeviceRecord].self, from: data)) ?? []
    }

    private func saveTrustedDevices() {
        trustedDevices.sort { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
        storedTrustedDeviceRecords.sort { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
        if let data = try? JSONEncoder().encode(storedTrustedDeviceRecords) {
            UserDefaults.standard.set(data, forKey: Self.trustedDevicesKey)
        }
    }

    @discardableResult
    private func retryTrustedDeviceCredentialLoadsIfNeeded() -> Bool {
        guard trustedDeviceCredentialReadNeedsRetry else { return false }

        let savedRecords = storedTrustedDeviceRecords
        var restoredRecords: [TrustedDeviceRecord] = []
        var restoredCredentials: [TrustedDeviceCredential] = []
        var hasUnreadableCredential = false
        for record in savedRecords {
            switch KeychainStore.readString(forKey: Self.trustedDeviceSecretPrefix + record.id) {
            case let .value(secret) where secret.count >= 32:
                restoredRecords.append(record)
                restoredCredentials.append(TrustedDeviceCredential(record: record, secret: secret))
            case .failure:
                hasUnreadableCredential = true
            case .missing, .value(_):
                break
            }
        }

        guard !hasUnreadableCredential else { return false }
        storedTrustedDeviceRecords = restoredRecords
        trustedDevices = restoredRecords
        trustedCredentialStore.replace(with: restoredCredentials)
        trustedDeviceCredentialReadNeedsRetry = false
        trustedDeviceStorageWarning = nil
        saveTrustedDevices()
        PocketCtrlHostDiagnostics.write("trusted device credentials restored after a temporary read failure")
        return true
    }

    private func prepareViewerForNewPairingAttempt() {
        viewerPairingSecret = ""
        viewerCredentialID = ""
        viewerAllowsRemoteInput = false
        viewerAllowsClipboard = false
        viewerAllowsAudio = false
        viewerCredentialIsPersistent = false
        viewerCredentialReadNeedsRetry = false
        viewerUserFacingIssue = nil
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectViewerKey)
    }

    private func saveViewerSavedComputers() {
        let orderedComputers = viewerSavedComputers.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
        viewerSavedComputers = orderedComputers
        if let data = try? JSONEncoder().encode(orderedComputers) {
            UserDefaults.standard.set(data, forKey: Self.viewerSavedComputersKey)
        }
    }

    private func viewerSavedComputerCredentialKey(for credentialID: String) -> String {
        Self.viewerSavedComputerCredentialPrefix + credentialID
    }

    private func defaultViewerComputerName(hostID: String?, hostAddress: String) -> String {
        if let hostID = hostID?.trimmedNonEmpty {
            let suffix = hostID.prefix(6)
            return suffix.isEmpty ? "Saved Mac" : "Mac \(suffix)"
        }
        return hostAddress.trimmedNonEmpty ?? "Saved Mac"
    }

    private func viewerSavedComputerID(hostID: String?, hostAddress: String) -> String {
        if let hostID = hostID?.trimmedNonEmpty {
            return hostID
        }

        let normalizedHost = NetworkAddressPolicy.normalized(hostAddress)
        let safeHost = normalizedHost
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
        return safeHost.isEmpty ? "manual-\(UUID().uuidString)" : "manual-\(safeHost)"
    }

    private func viewerSavedComputerMatchesCurrentRoute(_ computer: ViewerSavedComputer) -> Bool {
        let hostAddress = NetworkAddressPolicy.normalized(viewerHostAddress)
        guard !hostAddress.isEmpty else { return false }

        if NetworkAddressPolicy.normalized(computer.hostAddress) == hostAddress {
            return true
        }

        if NetworkAddressPolicy.isTailscaleAddress(hostAddress),
           NetworkAddressPolicy.normalized(computer.tailscaleHostAddress) == hostAddress {
            return true
        }

        if NetworkAddressPolicy.isPrivateOrLocalAddress(hostAddress),
           NetworkAddressPolicy.normalized(computer.localHostAddress) == hostAddress {
            return true
        }

        return false
    }

    @discardableResult
    private func upsertViewerSavedComputerForCurrentConnection(updateLastConnected: Bool) -> ViewerSavedComputer? {
        if let selectedID = selectedViewerSavedComputerID,
           let selectedComputer = viewerSavedComputers.first(where: { $0.id == selectedID }),
           viewerSavedComputerMatchesCurrentRoute(selectedComputer) {
            return upsertViewerSavedComputerFromCurrent(
                name: selectedComputer.name,
                hostID: selectedComputer.id,
                localHostAddress: selectedComputer.localHostAddress,
                tailscaleHostAddress: selectedComputer.tailscaleHostAddress,
                wakeMACAddress: selectedComputer.wakeMACAddress,
                updateLastConnected: updateLastConnected
            )
        }

        return upsertViewerSavedComputerFromCurrent(updateLastConnected: updateLastConnected)
    }

    @discardableResult
    private func upsertViewerSavedComputerFromCurrent(
        name: String? = nil,
        hostID: String? = nil,
        localHostAddress: String? = nil,
        tailscaleHostAddress: String? = nil,
        wakeMACAddress: String? = nil,
        updateLastConnected: Bool = true,
        persistCredential: Bool = false
    ) -> ViewerSavedComputer? {
        let hostAddress = NetworkAddressPolicy.normalized(viewerHostAddress)
        guard !hostAddress.isEmpty,
              hostAddress != "127.0.0.1",
              hostAddress.lowercased() != "localhost" else {
            return nil
        }

        let id = viewerSavedComputerID(hostID: hostID, hostAddress: hostAddress)
        let normalizedLocal = NetworkAddressPolicy.normalized(
            localHostAddress ?? (NetworkAddressPolicy.isPrivateOrLocalAddress(hostAddress) && !NetworkAddressPolicy.isTailscaleAddress(hostAddress) ? hostAddress : "")
        )
        let normalizedTailscale = NetworkAddressPolicy.normalized(
            tailscaleHostAddress ?? (NetworkAddressPolicy.isTailscaleAddress(hostAddress) ? hostAddress : "")
        )
        let normalizedMAC = wakeMACAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let now = Date()
        let resolvedName = name?.trimmedNonEmpty
        let existing = viewerSavedComputers.first { $0.id == id }
        let currentComputer = ViewerSavedComputer(
            id: id,
            name: resolvedName ?? existing?.name ?? defaultViewerComputerName(hostID: hostID, hostAddress: hostAddress),
            hostAddress: hostAddress,
            localHostAddress: normalizedLocal,
            tailscaleHostAddress: normalizedTailscale,
            listenPort: viewerListenPort,
            audioPort: viewerAudioPort,
            inputPort: viewerHostInputPort,
            wakeMACAddress: normalizedMAC.isEmpty ? (existing?.wakeMACAddress ?? "") : normalizedMAC,
            credentialID: viewerCredentialID,
            allowsRemoteInput: viewerAllowsRemoteInput,
            allowsClipboard: viewerAllowsClipboard,
            allowsAudio: viewerAllowsAudio,
            lastConnectedAt: updateLastConnected ? now : (existing?.lastConnectedAt ?? now)
        )
        let sanitizedSecret = viewerPairingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if persistCredential {
            let credentialKey = viewerSavedComputerCredentialKey(for: viewerCredentialID)
            guard viewerCredentialIsPersistent,
                  !viewerCredentialID.isEmpty,
                  sanitizedSecret.count >= 32,
                  KeychainStore.set(sanitizedSecret, forKey: credentialKey) else {
                if !viewerCredentialID.isEmpty {
                    KeychainStore.delete(forKey: credentialKey)
                }
                viewerPairingSecret = ""
                viewerCredentialID = ""
                viewerAllowsRemoteInput = false
                viewerAllowsClipboard = false
                viewerAllowsAudio = false
                markViewerCredentialPersistenceFailure()
                return nil
            }
        }

        if let index = viewerSavedComputers.firstIndex(where: { $0.id == id }) {
            viewerSavedComputers[index] = currentComputer
        } else {
            viewerSavedComputers.append(currentComputer)
        }

        selectedViewerSavedComputerID = id
        UserDefaults.standard.set(id, forKey: Self.selectedViewerSavedComputerIDKey)
        saveViewerSavedComputers()
        if persistCredential,
           let previousCredentialID = existing?.credentialID.trimmedNonEmpty,
           previousCredentialID != currentComputer.credentialID,
           !viewerSavedComputers.contains(where: { $0.credentialID == previousCredentialID }) {
            KeychainStore.delete(forKey: viewerSavedComputerCredentialKey(for: previousCredentialID))
        }
        return currentComputer
    }

    private func restoreViewerSavedComputer(_ computer: ViewerSavedComputer, reason: String) {
        viewerPairedHostID = computer.id
        viewerLocalHostAddress = computer.localHostAddress
        viewerTailscaleHostAddress = computer.tailscaleHostAddress
        viewerHostAddress = preferredViewerHost(
            localHost: computer.localHostAddress,
            tailscaleHost: computer.tailscaleHostAddress,
            fallbackHost: computer.hostAddress
        )
        viewerListenPort = computer.listenPort
        viewerAudioPort = computer.audioPort
        viewerHostInputPort = computer.inputPort
        viewerPairingSecret = ""
        switch KeychainStore.readString(forKey: viewerSavedComputerCredentialKey(for: computer.credentialID)) {
        case let .value(savedCredential) where savedCredential.count >= 32:
            viewerPairingSecret = savedCredential
            viewerCredentialIsPersistent = true
            viewerCredentialReadNeedsRetry = false
        case .failure:
            viewerCredentialReadNeedsRetry = true
            markViewerStoredCredentialTemporarilyUnavailable()
        case .missing, .value(_):
            viewerCredentialReadNeedsRetry = false
            markViewerStoredCredentialUnavailable()
        }
        viewerCredentialID = computer.credentialID
        viewerAllowsRemoteInput = computer.allowsRemoteInput
        viewerAllowsClipboard = computer.allowsClipboard
        viewerAllowsAudio = computer.allowsAudio
        selectedViewerSavedComputerID = computer.id
        UserDefaults.standard.set(computer.id, forKey: Self.selectedViewerSavedComputerIDKey)
        startViewerLocalDiscoveryIfPossible()
        PocketCtrlHostDiagnostics.write("viewer saved computer applied reason=\(reason) hasLocalHost=\(!computer.localHostAddress.isEmpty) hasTailscaleHost=\(!computer.tailscaleHostAddress.isEmpty)")
    }

    @discardableResult
    private func applyPairingQueryItemsToViewer(_ queryItems: [URLQueryItem], savePairing: Bool = true, connectedHost: String? = nil) -> Bool {
        func value(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let localHost = IPNetwork.pairingLocalHost(advertised: value("host"), connectedHost: connectedHost) ?? ""
        let tailscaleHost = IPNetwork.pairingTailscaleHost(advertised: value("tailscale"), connectedHost: connectedHost)
        viewerPairedHostID = value("id") ?? ""
        viewerLocalHostAddress = localHost
        viewerTailscaleHostAddress = tailscaleHost
        let fallbackHost = tailscaleHost.isEmpty ? localHost : tailscaleHost
        viewerHostAddress = preferredViewerHost(
            localHost: localHost,
            tailscaleHost: tailscaleHost,
            fallbackHost: fallbackHost
        )
        if let video = value("video"), UInt16(video) != nil {
            viewerListenPort = video
        }
        if let audio = value("audio"), UInt16(audio) != nil {
            viewerAudioPort = audio
        }
        if let input = value("input"), UInt16(input) != nil {
            viewerHostInputPort = input
        }
        if savePairing {
            guard upsertViewerSavedComputerFromCurrent(
                name: value("name"),
                hostID: value("id"),
                localHostAddress: localHost,
                tailscaleHostAddress: tailscaleHost,
                wakeMACAddress: value("mac"),
                updateLastConnected: false,
                persistCredential: true
            ) != nil else {
                startViewerLocalDiscoveryIfPossible()
                return false
            }
        }
        startViewerLocalDiscoveryIfPossible()
        return true
    }

    private func markViewerCredentialPersistenceFailure() {
        viewerCredentialIsPersistent = false
        viewerCredentialReadNeedsRetry = false
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectViewerKey)
        viewerUserFacingIssue = ViewerUserFacingIssue(
            title: "Couldn’t Save This Device",
            message: "PocketCtrl could not securely save this device. Check the app's code signing, then pair again."
        )
        viewerStatus = "Secure credential storage is unavailable"
        PocketCtrlHostDiagnostics.write("viewer credential could not be persisted securely")
    }

    private func markViewerStoredCredentialUnavailable() {
        viewerCredentialIsPersistent = false
        UserDefaults.standard.set(false, forKey: Self.shouldAutoReconnectViewerKey)
        viewerUserFacingIssue = ViewerUserFacingIssue(
            title: "Pair This Mac Again",
            message: "PocketCtrl could not load this Mac's saved credential securely. Pair it again before connecting."
        )
        viewerStatus = "Saved credential is unavailable"
        PocketCtrlHostDiagnostics.write("viewer saved credential was unavailable during restore")
    }

    private func markViewerStoredCredentialTemporarilyUnavailable() {
        viewerCredentialIsPersistent = false
        viewerUserFacingIssue = ViewerUserFacingIssue(
            title: "Saved Credential Temporarily Unavailable",
            message: "Unlock this Mac and return to PocketCtrl. The saved credential has not been deleted."
        )
        viewerStatus = "Waiting for secure credential storage"
        PocketCtrlHostDiagnostics.write("viewer saved credential read will retry when the app becomes active")
    }

    @discardableResult
    private func retryViewerCredentialLoadIfNeeded() -> Bool {
        guard viewerCredentialReadNeedsRetry,
              let selectedID = selectedViewerSavedComputerID,
              let computer = viewerSavedComputers.first(where: { $0.id == selectedID }) else {
            return false
        }

        switch KeychainStore.readString(forKey: viewerSavedComputerCredentialKey(for: computer.credentialID)) {
        case let .value(savedCredential) where savedCredential.count >= 32:
            viewerPairingSecret = savedCredential
            viewerPairedHostID = computer.id
            viewerCredentialID = computer.credentialID
            viewerAllowsRemoteInput = computer.allowsRemoteInput
            viewerAllowsClipboard = computer.allowsClipboard
            viewerAllowsAudio = computer.allowsAudio
            viewerCredentialIsPersistent = true
            viewerCredentialReadNeedsRetry = false
            viewerUserFacingIssue = nil
            PocketCtrlHostDiagnostics.write("viewer saved credential restored after a temporary read failure")
            return true
        case .failure:
            return false
        case .missing, .value(_):
            viewerCredentialReadNeedsRetry = false
            markViewerStoredCredentialUnavailable()
            return false
        }
    }

    private func preferredViewerHost(localHost: String, tailscaleHost: String, fallbackHost: String) -> String {
        let local = NetworkAddressPolicy.normalized(localHost)
        let tailscale = NetworkAddressPolicy.normalized(tailscaleHost)
        let interfaces = Self.interfaceIPAddresses()

        if !local.isEmpty,
           interfaces.contains(where: {
               !NetworkAddressPolicy.isTailscaleAddress($0.address)
                   && NetworkAddressPolicy.isOnSameSubnet(
                       peerAddress: local,
                       interfaceAddress: $0.address,
                       netmask: $0.netmask
                   )
           }) {
            return local
        }
        if NetworkAddressPolicy.isTailscaleAddress(tailscale), Self.tailscaleIPAddress() != nil {
            return tailscale
        }
        if !local.isEmpty {
            return local
        }
        return NetworkAddressPolicy.normalized(fallbackHost)
    }

    private func updateViewerRouteAfterNetworkChange() {
        let nextHost = preferredViewerHost(
            localHost: viewerLocalHostAddress,
            tailscaleHost: viewerTailscaleHostAddress,
            fallbackHost: viewerHostAddress
        )
        guard !nextHost.isEmpty,
              nextHost != NetworkAddressPolicy.normalized(viewerHostAddress) else {
            return
        }

        if shouldKeepCurrentViewerRoute {
            PocketCtrlHostDiagnostics.write("viewer network update retained healthy route current=\(Self.viewerRouteDescription(viewerHostAddress)) candidate=\(Self.viewerRouteDescription(nextHost))")
            return
        }

        viewerHostAddress = nextHost
        if isViewing {
            viewerStatus = NetworkAddressPolicy.isTailscaleAddress(nextHost)
                ? "Local Wi-Fi changed. Switching to Tailscale..."
                : "Found the paired Mac on local Wi-Fi. Switching route..."
            restartViewerWithCurrentSettings()
        }
    }

    @discardableResult
    private func tryViewerAlternateRoute(afterFailureAt failedHost: String) -> Bool {
        let local = NetworkAddressPolicy.normalized(viewerLocalHostAddress)
        let tailscale = NetworkAddressPolicy.normalized(viewerTailscaleHostAddress)
        let failedHost = NetworkAddressPolicy.normalized(failedHost)

        let nextHost: String
        let status: String
        if failedHost == local,
           NetworkAddressPolicy.isTailscaleAddress(tailscale),
           Self.tailscaleIPAddress() != nil {
            nextHost = tailscale
            status = "Local Wi-Fi did not respond. Trying Tailscale..."
        } else if failedHost == tailscale,
                  NetworkAddressPolicy.isPrivateOrLocalAddress(local),
                  !NetworkAddressPolicy.isTailscaleAddress(local) {
            nextHost = local
            status = "Tailscale did not respond. Trying local Wi-Fi..."
        } else {
            return false
        }

        guard nextHost != NetworkAddressPolicy.normalized(viewerHostAddress) else { return false }
        PocketCtrlHostDiagnostics.write("viewer watchdog switching route from=\(Self.viewerRouteDescription(failedHost)) to=\(Self.viewerRouteDescription(nextHost))")
        viewerHostAddress = nextHost
        viewerStatus = status
        restartViewerWithCurrentSettings()
        return true
    }

    private var shouldKeepCurrentViewerRoute: Bool {
        guard isViewing else { return false }
        let now = Date()
        if let viewerLastFrameAt,
           now.timeIntervalSince(viewerLastFrameAt) < Self.viewerRouteStabilityInterval {
            return true
        }
        if let viewerConnectionStartedAt,
           now.timeIntervalSince(viewerConnectionStartedAt) < Self.viewerRouteStabilityInterval {
            return true
        }
        return false
    }

    private static func viewerRouteDescription(_ host: String) -> String {
        isTailscaleRoute(host) ? "tailscale" : "local"
    }

    private static func isTailscaleRoute(_ host: String) -> Bool {
        let host = NetworkAddressPolicy.normalized(host)
        return NetworkAddressPolicy.isTailscaleAddress(host) || host.lowercased().hasSuffix(".ts.net")
    }

    private static func tailscaleIPAddress() -> String? {
        interfaceIPAddresses().first { NetworkAddressPolicy.isTailscaleAddress($0.address) }?.address
    }

    private static func localIPAddress() -> String? {
        let addresses = interfaceIPAddresses()
        if let primary = addresses.first(where: { $0.name == "en0" }) {
            return primary.address
        }
        if let secondary = addresses.first(where: { $0.name == "en1" }) {
            return secondary.address
        }
        return addresses.first {
            NetworkAddressPolicy.isPrivateOrLocalAddress($0.address)
                && !NetworkAddressPolicy.isTailscaleAddress($0.address)
                && !IPNetwork.isLoopback($0.address)
        }?.address
    }

    private struct MacIPInterfaceAddress {
        let name: String
        let address: String
        let netmask: String
    }

    private static func interfaceIPAddresses() -> [MacIPInterfaceAddress] {
        IPNetwork.interfaces()
            .sorted { IPNetwork.preference($0.address) < IPNetwork.preference($1.address) }
            .map { MacIPInterfaceAddress(name: $0.name, address: $0.address, netmask: $0.netmask ?? "") }
    }

    private static func localMACAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var candidate: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let interface = current.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            let linkAddress = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) {
                $0.pointee
            }
            guard linkAddress.sdl_alen == 6 else { continue }

            let byteOffset = 8 + Int(linkAddress.sdl_nlen)
            let addressBytes = UnsafeRawPointer(address).assumingMemoryBound(to: UInt8.self)
            let bytes = (0..<Int(linkAddress.sdl_alen)).map { addressBytes[byteOffset + $0] }
            let formatted = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")

            if name == "en0" { return formatted }
            candidate = candidate ?? formatted
        }

        return candidate
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        if bytes >= 1_000 {
            return String(format: "%.1f KB", Double(bytes) / 1_000)
        }
        return "\(bytes) B"
    }

    private static func formatInputStats(prefix: String, stats: InputActivityStats) -> String {
        let eventName = stats.lastEventKind?.rawValue ?? "none"
        return "\(prefix) \(stats.totalEvents) input events, \(stats.eventsPerSecond)/s, last \(eventName)"
    }
}

private extension StringProtocol {
    func chunked(every size: Int) -> [SubSequence] {
        stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return self[start..<end]
        }
    }

    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
