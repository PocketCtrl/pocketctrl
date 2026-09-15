// SPDX-License-Identifier: MPL-2.0

import AVFoundation
import SwiftUI
import UIKit

enum ViewerHelpTarget: Hashable {
    case desktop
    case settings
    case scroll
    case leftClick
    case rightClick
    case voice
    case keyboard
}

struct ViewerHelpAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [ViewerHelpTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ViewerHelpTarget: Anchor<CGRect>],
        nextValue: () -> [ViewerHelpTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

extension View {
    func viewerHelpTarget(_ target: ViewerHelpTarget) -> some View {
        anchorPreference(key: ViewerHelpAnchorPreferenceKey.self, value: .bounds) { anchor in
            [target: anchor]
        }
    }
}

struct ClientContentView: View {
    @StateObject private var model = ClientModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSettings = false
    @State private var isKeyboardBarVisible = false
    @State private var isShortcutComposerVisible = false
    @State private var zoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var keyboardFocusToken = 0
    @State private var shortcutCommandText = ""
    @State private var shortcutFocusToken = 0
    @State private var liveTypingText = ""
    @State private var isLiveTypingAllSelected = false
    @State private var areOnScreenControlsHidden = false
    @State private var scrollRailOffset = CGSize.zero
    @State private var scrollRailCenter: CGPoint?
    @State private var keyboardClickRailOffset = CGSize.zero
    @State private var clickBarOffset = CGSize.zero
    @State private var textToolBarOffset = CGSize.zero
    @State private var isShowingConnectNewMacFlow = false
    @State private var isShowingHomePairingScanner = false
    @State private var homePairingScanMessage: String?
    @State private var isShowingNewMacNameSheet = false
    @State private var newMacNameDraft = ""
    @State private var renameMacID: String?
    @State private var renameMacNameDraft = ""
    @State private var infoMacID: String?
    @State private var isShowingConnectionInfo = false
    @State private var isShowingConnectionHelp = false
    /// Set once a connection or pairing attempt has run for a while without success,
    /// so the connecting screen can offer help instead of a bare spinner.
    @State private var connectingHasBeenSlow = false
    @State private var isShowingConnectingHelp = false
    private static let slowConnectionHelpDelay: Duration = .seconds(20)
    @State private var isTailscaleAppInstalled = false
    @State private var isShowingViewerHelp = false
    @State private var viewerHelpStep = 0
    @AppStorage("PocketCtrlMobile.hasShownViewerHelp") private var hasShownViewerHelp = false

    private let tailscaleAppURL = URL(string: "tailscale://")!
    private let tailscaleAppStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            let isWaitingForFirstVideo = model.isConnectionAttemptInProgress && !model.hasDisplayedVideoFrame
            let isPairingOrWaitingForApproval = model.isPairingRequestInProgress
            let isPreservingVideoDuringReconnect = model.hasDisplayedVideoFrame && (model.isConnectionAttemptInProgress || model.isAutomaticReconnectInProgress)
            let shouldShowRemoteCanvas = model.hasDisplayedVideoFrame && (model.isConnected || model.isConnectionAttemptInProgress || model.isAutomaticReconnectInProgress)
            let shouldShowInteractiveControls = model.isConnected && !model.isConnectionAttemptInProgress && !model.isAutomaticReconnectInProgress

            ZStack {
                Color.black.ignoresSafeArea()

                if shouldShowRemoteCanvas {
                    remoteCanvas(isLandscape: isLandscape)
                        .blur(radius: isPreservingVideoDuringReconnect ? 9 : 0)
                        .scaleEffect(isPreservingVideoDuringReconnect ? 1.015 : 1)
                } else {
                    ConnectMeshBackground()
                        .transition(.opacity)
                }

                if isPreservingVideoDuringReconnect {
                    reconnectingState
                } else if !shouldShowRemoteCanvas {
                    if isWaitingForFirstVideo || isPairingOrWaitingForApproval {
                        connectingState
                    } else {
                        disconnectedState
                    }
                }
            }
            .animation(.easeInOut(duration: 0.34), value: shouldShowRemoteCanvas)
            .overlay(alignment: .topLeading) {
                settingsButton(isLandscape: isLandscape)
                    .padding(.leading, isLandscape ? 10 : 14)
                    .padding(.top, isLandscape ? 8 : 10)
            }
            .overlay(alignment: .topTrailing) {
                if shouldShowInteractiveControls, !areOnScreenControlsHidden {
                    viewerHelpButton(isLandscape: isLandscape)
                        .padding(.trailing, isLandscape ? 10 : 14)
                        .padding(.top, isLandscape ? 8 : 10)
                }
            }
            .overlay(alignment: .trailing) {
                if shouldShowInteractiveControls, !areOnScreenControlsHidden {
                    MovableControlIsland(
                        offset: $scrollRailOffset,
                        bounds: proxy.size,
                        approximateSize: CGSize(width: 34, height: 156),
                        home: .trailingCenter,
                        onCenterChange: { center in
                            scrollRailCenter = center
                            refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: true)
                        }
                    ) {
                        RemoteScrollRail(model: model)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if shouldShowInteractiveControls, !areOnScreenControlsHidden, !isKeyboardBarVisible {
                    MovableControlIsland(
                        offset: $clickBarOffset,
                        bounds: proxy.size,
                        approximateSize: CGSize(width: isLandscape ? 120 : 144, height: isLandscape ? 56 : 68),
                        home: .bottomTrailing(bottomInset: isLandscape ? 12 : 86),
                        dragExclusionRects: RemoteClickBar.dragExclusionRects(isCompact: isLandscape)
                    ) {
                        RemoteClickBar(model: model, isCompact: isLandscape)
                    }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if shouldShowInteractiveControls, !areOnScreenControlsHidden, isKeyboardBarVisible {
                    MovableControlIsland(
                        offset: $keyboardClickRailOffset,
                        bounds: proxy.size,
                        approximateSize: CGSize(width: 46, height: 82),
                        home: .bottomFreeTrailing(bottomInset: 6),
                        dragExclusionRects: RemoteKeyboardClickRail.dragExclusionRects
                    ) {
                        RemoteKeyboardClickRail(model: model)
                    }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if shouldShowInteractiveControls, !areOnScreenControlsHidden, !isKeyboardBarVisible {
                    MovableControlIsland(
                        offset: $textToolBarOffset,
                        bounds: proxy.size,
                        approximateSize: CGSize(width: isLandscape ? 118 : 144, height: isLandscape ? 56 : 68),
                        home: .bottomLeading(bottomInset: isLandscape ? 12 : 86)
                    ) {
                        RemoteTextToolBar(
                            model: model,
                            isKeyboardBarVisible: $isKeyboardBarVisible,
                            keyboardFocusToken: $keyboardFocusToken,
                            isCompact: isLandscape
                        )
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlayPreferenceValue(ViewerHelpAnchorPreferenceKey.self) { anchors in
                if isShowingViewerHelp {
                    ViewerHelpOverlay(
                        anchors: anchors,
                        safeAreaInsets: proxy.safeAreaInsets,
                        stepIndex: $viewerHelpStep,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                isShowingViewerHelp = false
                            }
                        }
                    )
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
            .onAppear {
                refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: shouldShowInteractiveControls && !areOnScreenControlsHidden)
            }
            .onChange(of: proxy.size) {
                refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: shouldShowInteractiveControls && !areOnScreenControlsHidden)
            }
            .onChange(of: scrollRailOffset) {
                refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: shouldShowInteractiveControls && !areOnScreenControlsHidden)
            }
            .onChange(of: zoomScale) {
                refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: shouldShowInteractiveControls && !areOnScreenControlsHidden)
            }
            .onChange(of: zoomOffset) {
                refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: shouldShowInteractiveControls && !areOnScreenControlsHidden)
            }
            .onChange(of: model.remoteVideoSize) {
                refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: shouldShowInteractiveControls && !areOnScreenControlsHidden)
            }
            .onChange(of: shouldShowInteractiveControls) {
                refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: shouldShowInteractiveControls && !areOnScreenControlsHidden)
            }
            .onChange(of: areOnScreenControlsHidden) {
                refreshScrollRailSamplePoint(viewportSize: proxy.size, controlsVisible: shouldShowInteractiveControls && !areOnScreenControlsHidden)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isConnected, !model.isAutomaticReconnectInProgress, isKeyboardBarVisible, !areOnScreenControlsHidden {
                VStack(spacing: 0) {
                    if isShortcutComposerVisible {
                        RemoteShortcutComposer(
                            model: model,
                            commandText: $shortcutCommandText,
                            liveTypingText: $liveTypingText,
                            isLiveTypingAllSelected: $isLiveTypingAllSelected,
                            shortcutFocusToken: $shortcutFocusToken
                        )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    RemoteKeyboardAccessory(
                        model: model,
                        isKeyboardBarVisible: $isKeyboardBarVisible,
                        isShortcutComposerVisible: $isShortcutComposerVisible,
                        keyboardFocusToken: $keyboardFocusToken,
                        commandText: $shortcutCommandText,
                        liveTypingText: $liveTypingText,
                        isLiveTypingAllSelected: $isLiveTypingAllSelected,
                        shortcutFocusToken: $shortcutFocusToken
                    )
                }
                .background(.black.opacity(0.72))
            }
        }
        .fullScreenCover(isPresented: $isShowingSettings) {
            ClientSettingsView(
                model: model,
                areOnScreenControlsHidden: $areOnScreenControlsHidden,
                onConnectNewMac: {
                    isShowingSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        showConnectNewMacFlow()
                    }
                }
            )
                .preferredColorScheme(.dark)
        }
        .onChange(of: isShowingSettings) {
            if !isShowingSettings {
                model.refreshInputSenderAfterInterfaceResume(reason: "settings dismissed")
            }
        }
        .fullScreenCover(isPresented: viewerDeviceNameOnboardingBinding) {
            ViewerDeviceOnboardingView(
                onFinish: { name in
                    model.completeViewerDeviceNameOnboarding(name: name)
                }
            )
            .interactiveDismissDisabled()
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isShowingConnectNewMacFlow) {
            ConnectNewMacFlowSheet(
                model: model,
                startsInManualMode: true,
                onScanQR: {
                    startPairingScannerAfterConnectFlow()
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingHomePairingScanner) {
            PairingCodeScannerSheet(
                message: $homePairingScanMessage,
                onManual: {
                    isShowingHomePairingScanner = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        isShowingConnectNewMacFlow = true
                    }
                },
                onCode: { value in
                    switch model.applyPairingQRCode(value) {
                    case .credentialApplied:
                        homePairingScanMessage = "Pairing code scanned."
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            isShowingHomePairingScanner = false
                            if let pendingMac = model.pendingNewSavedMac {
                                newMacNameDraft = pendingMac.name
                                isShowingNewMacNameSheet = true
                            } else {
                                model.connectToCurrentPairing(reason: "QR scanner")
                            }
                        }
                        return true
                    case .approvalRequested:
                        homePairingScanMessage = "QR recognized. Finding your Mac..."
                        DispatchQueue.main.async {
                            isShowingHomePairingScanner = false
                        }
                        return true
                    case nil:
                        homePairingScanMessage = "That QR code did not contain a pairing code."
                        return false
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingNewMacNameSheet) {
            NewMacNameSheet(
                name: $newMacNameDraft,
                onSkip: {
                    model.clearPendingNewSavedMacName()
                    isShowingNewMacNameSheet = false
                    model.connectToCurrentPairing(reason: "new Mac naming skipped")
                },
                onSave: {
                    if let pendingMac = model.pendingNewSavedMac {
                        model.renameSavedMac(id: pendingMac.id, to: newMacNameDraft)
                    }
                    model.clearPendingNewSavedMacName()
                    isShowingNewMacNameSheet = false
                    model.connectToCurrentPairing(reason: "new Mac naming saved")
                }
            )
            .presentationDetents([.height(250)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: renameSheetBinding) { item in
            RenameMacSheet(
                name: $renameMacNameDraft,
                onCancel: {
                    renameMacID = nil
                },
                onSave: {
                    model.renameSavedMac(id: item.id, to: renameMacNameDraft)
                    renameMacID = nil
                }
            )
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: infoSheetBinding) { item in
            if let mac = model.savedMacs.first(where: { $0.id == item.id }) {
                MacInfoSheet(
                    mac: mac
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground {
                    SettingsBackground()
                }
            }
        }
        .statusBarHidden(true)
        .animation(.snappy(duration: 0.22), value: isKeyboardBarVisible)
        .animation(.snappy(duration: 0.22), value: isShortcutComposerVisible)
        .animation(.snappy(duration: 0.22), value: areOnScreenControlsHidden)
        .onAppear {
            refreshTailscaleInstallState()
            model.retryPreviousConnectionIfNeeded()
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                refreshTailscaleInstallState()
                model.recordScenePhaseChange("active")
                model.refreshTailscaleConnectionAssist(reason: "scene active")
                model.resumeConnectionIfNeeded()
            case .inactive, .background:
                model.recordScenePhaseChange(scenePhase == .inactive ? "inactive" : "background")
                model.pauseConnectionHealthChecks()
            @unknown default:
                model.recordScenePhaseChange("unknown")
                break
            }
        }
        .onChange(of: model.isWaitingForTailscaleVPN) {
            refreshTailscaleInstallState()
        }
        .onChange(of: canAutomaticallyShowViewerHelp, initial: true) { _, canShow in
            if canShow {
                showViewerHelp()
            }
        }
        .onChange(of: areOnScreenControlsHidden) {
            if areOnScreenControlsHidden {
                isKeyboardBarVisible = false
                isShortcutComposerVisible = false
                shortcutCommandText = ""
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    private var renameSheetBinding: Binding<RenameMacSheetItem?> {
        Binding(
            get: {
                guard let renameMacID else { return nil }
                return RenameMacSheetItem(id: renameMacID)
            },
            set: { item in
                renameMacID = item?.id
            }
        )
    }

    private var infoSheetBinding: Binding<MacInfoSheetItem?> {
        Binding(
            get: {
                guard let infoMacID else { return nil }
                return MacInfoSheetItem(id: infoMacID)
            },
            set: { item in
                infoMacID = item?.id
            }
        )
    }

    private var viewerDeviceNameOnboardingBinding: Binding<Bool> {
        Binding(
            get: { model.shouldShowViewerDeviceNameOnboarding },
            set: { isPresented in
                if !isPresented, model.shouldShowViewerDeviceNameOnboarding {
                    model.completeViewerDeviceNameOnboarding(name: model.approvalViewerDeviceName)
                }
            }
        )
    }

    private func showRenameSheet(for mac: ClientSavedMac) {
        renameMacID = mac.id
        renameMacNameDraft = mac.name
    }

    private func showInfoSheet(for mac: ClientSavedMac) {
        infoMacID = mac.id
    }

    private func showConnectNewMacFlow() {
        homePairingScanMessage = nil
        isShowingHomePairingScanner = true
    }

    private func startPairingScannerAfterConnectFlow() {
        homePairingScanMessage = nil
        isShowingConnectNewMacFlow = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            isShowingHomePairingScanner = true
        }
    }

    private func remoteCanvas(isLandscape: Bool) -> some View {
        GeometryReader { proxy in
            let videoFrame = fittedVideoFrame(in: proxy.size)

            ZStack {
                ZStack {
                    ClientVideoView(model: model)
                    RemotePointerSurface(model: model, isHidden: areOnScreenControlsHidden)
                }
                .frame(width: videoFrame.width, height: videoFrame.height)
                .scaleEffect(zoomScale)
                .offset(zoomOffset)
                .position(x: videoFrame.midX, y: videoFrame.midY)

                RemoteGestureLayer(
                    model: model,
                    zoomScale: $zoomScale,
                    zoomOffset: $zoomOffset,
                    viewportSize: proxy.size,
                    contentFrame: videoFrame,
                    isKeyboardInputActive: isKeyboardBarVisible
                )
            }
            .clipped()
            .onChange(of: model.focusedWindowZoomRevision) {
                applyFocusedWindowZoom(viewportSize: proxy.size, contentFrame: videoFrame)
            }
            .onChange(of: model.autoZoomFocusedWindow) {
                guard model.autoZoomFocusedWindow else { return }
                applyFocusedWindowZoom(viewportSize: proxy.size, contentFrame: videoFrame)
            }
            .onChange(of: proxy.size) {
                guard model.autoZoomFocusedWindow else { return }
                applyFocusedWindowZoom(viewportSize: proxy.size, contentFrame: videoFrame)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: isLandscape ? .all : [])
        .viewerHelpTarget(.desktop)
    }

    private func refreshScrollRailSamplePoint(viewportSize: CGSize, controlsVisible: Bool) {
        guard controlsVisible else {
            model.updateScrollRailSamplePoint(nil)
            return
        }

        let railCenter = scrollRailCenter ?? CGPoint(
            x: viewportSize.width - 20 + scrollRailOffset.width,
            y: (viewportSize.height / 2) + scrollRailOffset.height
        )
        model.updateScrollRailSamplePoint(
            normalizedVideoPoint(for: railCenter, viewportSize: viewportSize)
        )
    }

    private func normalizedVideoPoint(for viewportPoint: CGPoint, viewportSize: CGSize) -> CGPoint? {
        let videoFrame = fittedVideoFrame(in: viewportSize)
        guard videoFrame.width > 0, videoFrame.height > 0 else { return nil }

        let scale = max(zoomScale, 1)
        let frameCenter = CGPoint(x: videoFrame.midX, y: videoFrame.midY)
        let contentPoint = CGPoint(
            x: ((viewportPoint.x - frameCenter.x - zoomOffset.width) / scale) + (videoFrame.width / 2),
            y: ((viewportPoint.y - frameCenter.y - zoomOffset.height) / scale) + (videoFrame.height / 2)
        )

        guard contentPoint.x >= 0,
              contentPoint.x <= videoFrame.width,
              contentPoint.y >= 0,
              contentPoint.y <= videoFrame.height else {
            return nil
        }

        return CGPoint(x: contentPoint.x / videoFrame.width, y: contentPoint.y / videoFrame.height)
    }

    private func applyFocusedWindowZoom(viewportSize: CGSize, contentFrame: CGRect) {
        guard model.autoZoomFocusedWindow,
              !model.isAutomaticReconnectInProgress,
              !model.isFocusedWindowAutoZoomSuspended,
              let region = model.focusedWindowRegion,
              viewportSize.width > 0,
              viewportSize.height > 0,
              contentFrame.width > 0,
              contentFrame.height > 0,
              region.width > 0.02,
              region.height > 0.02 else {
            return
        }

        let horizontalScale = (viewportSize.width * 0.92) / (contentFrame.width * region.width)
        let verticalScale = (viewportSize.height * 0.92) / (contentFrame.height * region.height)
        let fittingScale = min(horizontalScale, verticalScale)
        guard fittingScale > 1.08 else {
            withAnimation(.snappy(duration: 0.24)) {
                zoomScale = 1
                zoomOffset = .zero
            }
            return
        }

        let scale = min(fittingScale, 4)
        let viewportCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let contentCenter = CGPoint(x: contentFrame.width / 2, y: contentFrame.height / 2)
        let focusedCenter = CGPoint(
            x: contentFrame.width * region.midX,
            y: contentFrame.height * region.midY
        )
        let targetOffset = CGSize(
            width: viewportCenter.x - contentFrame.midX - ((focusedCenter.x - contentCenter.x) * scale),
            height: viewportCenter.y - contentFrame.midY - ((focusedCenter.y - contentCenter.y) * scale)
        )

        withAnimation(.snappy(duration: 0.24)) {
            zoomScale = scale
            zoomOffset = clampedZoomOffset(targetOffset, scale: scale, viewportSize: viewportSize, contentFrame: contentFrame)
        }
    }

    private func clampedZoomOffset(_ offset: CGSize, scale: CGFloat, viewportSize: CGSize, contentFrame: CGRect) -> CGSize {
        guard scale > 1 else { return .zero }
        let scaledWidth = contentFrame.width * scale
        let scaledHeight = contentFrame.height * scale
        let fittedFrameMaxX = (contentFrame.width * (scale - 1)) / 2
        let fittedFrameMaxY = (contentFrame.height * (scale - 1)) / 2
        let viewportMaxX = max((scaledWidth - viewportSize.width) / 2, 0)
        let viewportMaxY = max((scaledHeight - viewportSize.height) / 2, 0)
        let maxX = max(fittedFrameMaxX, viewportMaxX)
        let maxY = max(fittedFrameMaxY, viewportMaxY)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func fittedVideoFrame(in viewport: CGSize) -> CGRect {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let remoteWidth = max(model.remoteVideoSize.width, 1)
        let remoteHeight = max(model.remoteVideoSize.height, 1)
        let remoteAspect = remoteWidth / remoteHeight
        let viewportAspect = viewport.width / viewport.height

        let size: CGSize
        if remoteAspect > viewportAspect {
            size = CGSize(width: viewport.width, height: viewport.width / remoteAspect)
        } else {
            size = CGSize(width: viewport.height * remoteAspect, height: viewport.height)
        }

        return CGRect(
            x: (viewport.width - size.width) / 2,
            y: (viewport.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func settingsButton(isLandscape: Bool) -> some View {
        Button {
            isShowingSettings = true
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.52))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .frame(width: isLandscape ? 44 : 52, height: isLandscape ? 44 : 52)

                Image(systemName: "gearshape.fill")
                    .font(.system(size: isLandscape ? 16 : 19, weight: .semibold))
            }
            .frame(width: isLandscape ? 60 : 64, height: isLandscape ? 60 : 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .zIndex(20)
        .accessibilityLabel("Connection settings")
        .viewerHelpTarget(.settings)
    }

    private var canAutomaticallyShowViewerHelp: Bool {
        // Socket setup alone isn't success: wait for video and the visible viewer.
        !hasShownViewerHelp
            && model.hasDisplayedVideoFrame
            && model.isConnected
            && !model.isConnectionAttemptInProgress
            && !model.isAutomaticReconnectInProgress
            && scenePhase == .active
            && !areOnScreenControlsHidden
            && !model.shouldShowViewerDeviceNameOnboarding
            && !isShowingSettings
            && !isShowingConnectNewMacFlow
            && !isShowingHomePairingScanner
            && !isShowingNewMacNameSheet
            && renameMacID == nil
            && infoMacID == nil
            && !isShowingConnectionInfo
            && !isShowingConnectionHelp
    }

    private func showViewerHelp() {
        isKeyboardBarVisible = false
        isShortcutComposerVisible = false
        shortcutCommandText = ""
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        viewerHelpStep = 0
        hasShownViewerHelp = true
        withAnimation(.easeIn(duration: 0.18)) {
            isShowingViewerHelp = true
        }
    }

    private func viewerHelpButton(isLandscape: Bool) -> some View {
        Button {
            showViewerHelp()
        } label: {
            Image(systemName: "questionmark")
                .font(.system(size: isLandscape ? 16 : 18, weight: .bold, design: .rounded))
                .frame(width: isLandscape ? 38 : 42, height: isLandscape ? 38 : 42)
                .background(.black.opacity(0.52), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .contentShape(Circle())
        .accessibilityLabel("How to use the remote controls")
        .accessibilityHint("Starts a guided tour of the controls on this screen")
    }

    private var disconnectedState: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: isLandscape ? 18 : 26) {
                    Text("Connect to Your Mac")
                        .font(.system(size: isLandscape ? 30 : 34, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    if model.savedMacs.isEmpty {
                        VStack(spacing: 14) {
                            Button {
                                showConnectNewMacFlow()
                            } label: {
                                Label("Connect a new Mac", systemImage: "qrcode.viewfinder")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ConnectPrimaryButtonStyle())
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(model.savedMacs) { mac in
                                SavedMacRow(
                                    mac: mac,
                                    onConnect: {
                                        model.connect(to: mac)
                                    },
                                    onInfo: {
                                        showInfoSheet(for: mac)
                                    },
                                    onRename: {
                                        showRenameSheet(for: mac)
                                    },
                                    onRemove: {
                                        model.removeSavedMac(id: mac.id)
                                    }
                                )
                            }
                        }
                        .padding(10)
                        .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.11), lineWidth: 1))
                        .shadow(color: .black.opacity(0.22), radius: 22, y: 16)

                        Button {
                            showConnectNewMacFlow()
                        } label: {
                            Label("Connect a new Mac", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ConnectSecondaryButtonStyle())
                    }

                    VStack(spacing: 8) {
                        if let homePairingScanMessage {
                            Text(homePairingScanMessage)
                                .foregroundStyle(.white.opacity(0.78))
                        } else if model.status != "Enter your Mac host settings, then connect." {
                            Text(model.status)
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(2)
                        }

                        Button("Need help?") {
                            isShowingConnectionHelp = true
                        }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .accessibilityHint("Shows simple steps for connecting your Mac")
                        .sheet(isPresented: $isShowingConnectionHelp) {
                            MacConnectionHelpSheet()
                                .presentationDetents([.large])
                                .presentationDragIndicator(.visible)
                        }
                    }
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                }
                .padding(.horizontal, isLandscape ? 18 : 22)
                .padding(.vertical, isLandscape ? 28 : 48)
                .frame(maxWidth: isLandscape ? 560 : 430)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea()
    }

    private var connectingState: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if model.isWaitingForTailscaleVPN {
                        TailscaleConnectionAssist(
                            isTailscaleInstalled: isTailscaleAppInstalled,
                            action: openTailscaleOrAppStore,
                            localWiFiAction: model.connectOverLocalWiFi
                        )
                    } else if model.localWiFiSearchFailed {
                        Image(systemName: model.localNetworkAccessDenied ? "lock.slash" : "wifi.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.white)
                        Text(model.localNetworkAccessDenied ? "Local Network access is off" : "Mac not reachable over Wi-Fi")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text(model.localNetworkAccessDenied
                             ? "iOS is blocking PocketCtrl from reaching devices on your Wi-Fi. Open Settings, choose PocketCtrl, turn on Local Network, then try again."
                             : "Your iPhone and Mac must be on the same Wi-Fi network. Make sure your Mac is hosting with Nearby Wi-Fi Discovery on, and allow PocketCtrl's Local Network access in Settings on both devices. Away from home, use Tailscale on both devices instead.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.68))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        Button(action: model.connectOverLocalWiFi) {
                            Text("Try Again")
                                .padding(.horizontal, 32)
                        }
                        .buttonStyle(ConnectPrimaryButtonStyle())
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(ConnectSecondaryButtonStyle())
                        ConnectionHelpLink(
                            title: model.localNetworkAccessDenied ? "View the connection guide" : "Set up Tailscale for remote access",
                            url: model.localNetworkAccessDenied ? ClientHelpLinks.installGuide : ClientHelpLinks.tailscaleGuide
                        )
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

                        Text(model.isPairingRequestInProgress ? "Pairing" : model.isConnectingOverLocalWiFi ? "Connecting over Wi-Fi" : "Connecting")
                            .font(.system(size: 28, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(model.isPairingRequestInProgress ? model.manualPairingStatus : model.isConnectingOverLocalWiFi ? "Looking for your Mac and waiting for video over local Wi-Fi..." : "Waiting for video from your Mac...")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.68))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)

                        if model.isConnectingOverLocalWiFi, !model.isPairingRequestInProgress {
                            Text(ClientHelpLinks.sameNetworkHint)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.58))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)
                            ConnectionHelpLink(title: "Set up Tailscale for remote access", url: ClientHelpLinks.tailscaleGuide)
                        } else if model.isPairingRequestInProgress {
                            ConnectionHelpLink(title: "View the connection guide", url: ClientHelpLinks.installGuide)
                        }

                        if model.localNetworkAccessDenied, !model.isPairingRequestInProgress, model.isAttemptingLocalRoute {
                            // Surface the denial immediately instead of after the timeout.
                            Label("Local Network access is off for PocketCtrl", systemImage: "lock.slash")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .multilineTextAlignment(.center)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(ConnectSecondaryButtonStyle())
                        }
                    }

                    if connectingHasBeenSlow, !model.isWaitingForTailscaleVPN, !model.localWiFiSearchFailed {
                        SlowConnectionAssist(
                            isWaitingForApproval: model.isPairingRequestInProgress,
                            onShowHelp: { isShowingConnectingHelp = true }
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            isShowingConnectionInfo.toggle()
                        }
                    } label: {
                        Label(isShowingConnectionInfo ? "Hide Info" : "More Info", systemImage: isShowingConnectionInfo ? "chevron.up" : "info.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.78))

                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            isShowingConnectionInfo = false
                            model.disconnect()
                        }
                    } label: {
                        Text("Stop")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.82))
                    .background(.black.opacity(0.22), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

                    if isShowingConnectionInfo {
                        VStack(alignment: .leading, spacing: 8) {
                            ConnectionDetailLine(title: "Status", value: connectionInfoStatus)
                            ConnectionDetailLine(title: "Video", value: connectionInfoVideoStatus)
                            ConnectionDetailLine(title: "Route", value: model.routeStatus)
                            ConnectionDetailLine(title: "Discovery", value: model.localDiscoveryStatus)
                            ConnectionDetailLine(title: "Details", value: connectionInfoDetails)
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(14)
                        .frame(maxWidth: 420, alignment: .leading)
                        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.snappy(duration: 0.24), value: connectingHasBeenSlow)
        .task {
            // Runs while the connecting screen is visible and is cancelled when it goes away.
            connectingHasBeenSlow = false
            do { try await Task.sleep(for: Self.slowConnectionHelpDelay) } catch { return }
            connectingHasBeenSlow = true
        }
        .sheet(isPresented: $isShowingConnectingHelp) {
            MacConnectionHelpSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var isWaitingForInitialVideo: Bool {
        model.isConnectionAttemptInProgress && !model.hasDisplayedVideoFrame
    }

    private var connectionInfoStatus: String {
        if model.localWiFiSearchFailed {
            return model.localNetworkAccessDenied ? "Local Network access off" : "Local Wi-Fi did not respond"
        }
        if model.isPairingRequestInProgress {
            return "Waiting for Mac approval"
        }
        if model.isWaitingForTailscaleVPN {
            return "Tailscale VPN off"
        }
        return isWaitingForInitialVideo ? "Connecting" : model.status
    }

    private var connectionInfoVideoStatus: String {
        if model.localWiFiSearchFailed { return "No video received" }
        if model.isPairingRequestInProgress {
            return "Starts after approval"
        }
        if model.isWaitingForTailscaleVPN {
            return "Waiting for Tailscale"
        }
        return isWaitingForInitialVideo ? "Waiting for Mac video" : model.videoStatus
    }

    private var connectionInfoDetails: String {
        if model.localNetworkAccessDenied, model.isConnectingOverLocalWiFi || model.isAttemptingLocalRoute {
            return "iOS reported that Local Network access is denied for PocketCtrl. Settings > Apps > PocketCtrl > Local Network."
        }
        if model.isConnectingOverLocalWiFi {
            return "This attempt uses local Wi-Fi only. Tailscale is not required."
        }
        if model.isPairingRequestInProgress {
            return "Trying local Wi-Fi and Tailscale automatically. Check the Mac and approve this iPhone to continue."
        }
        if model.isWaitingForTailscaleVPN {
            return model.routeDiagnostic
        }
        guard isWaitingForInitialVideo else {
            return model.routeDiagnostic
        }

        return "Trying the selected route and retrying quietly until video arrives. Press Stop to choose another Mac."
    }

    private func refreshTailscaleInstallState() {
        isTailscaleAppInstalled = UIApplication.shared.canOpenURL(tailscaleAppURL)
    }

    private func openTailscaleOrAppStore() {
        refreshTailscaleInstallState()
        let targetURL = isTailscaleAppInstalled ? tailscaleAppURL : tailscaleAppStoreURL
        UIApplication.shared.open(targetURL) { didOpen in
            DispatchQueue.main.async {
                if !didOpen, targetURL != tailscaleAppStoreURL {
                    UIApplication.shared.open(tailscaleAppStoreURL)
                }
                model.refreshTailscaleConnectionAssist(reason: "tailscale action tapped")
            }
        }
    }

    private var reconnectingState: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()

            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .accessibilityLabel("Reconnecting")
        }
        .transition(.opacity)
    }
}

private struct ViewerHelpTopic {
    let target: ViewerHelpTarget
    let title: String
    let detail: String
    let systemImage: String

    static let all: [ViewerHelpTopic] = [
        ViewerHelpTopic(
            target: .desktop,
            title: "Move around the Mac",
            detail: "Drag or tap anywhere on the Mac image to place the pointer. Pinch to zoom, then use two fingers to pan.",
            systemImage: "hand.draw.fill"
        ),
        ViewerHelpTopic(
            target: .leftClick,
            title: "Left click",
            detail: "Tap for a normal click. Press and hold, then drag to move windows, files, or selections.",
            systemImage: "cursorarrow.click"
        ),
        ViewerHelpTopic(
            target: .rightClick,
            title: "Right click",
            detail: "Tap this button to right-click and open the Mac's contextual menus.",
            systemImage: "cursorarrow.click.2"
        ),
        ViewerHelpTopic(
            target: .scroll,
            title: "Scroll",
            detail: "Drag up or down on this rail to scroll. Press and hold outside its arrows to move the control.",
            systemImage: "arrow.up.and.down"
        ),
        ViewerHelpTopic(
            target: .keyboard,
            title: "Keyboard",
            detail: "Open the iPhone keyboard to type on the Mac and send Mac keyboard shortcuts.",
            systemImage: "keyboard"
        ),
        ViewerHelpTopic(
            target: .voice,
            title: "Voice typing",
            detail: "Tap the microphone and speak. PocketCtrl types the recognized words on your Mac.",
            systemImage: "mic.fill"
        ),
        ViewerHelpTopic(
            target: .settings,
            title: "Connection settings",
            detail: "Choose or reconnect a Mac and adjust the controls shown over the viewer.",
            systemImage: "gearshape.fill"
        )
    ]
}

private struct ViewerHelpOverlay: View {
    let anchors: [ViewerHelpTarget: Anchor<CGRect>]
    let safeAreaInsets: EdgeInsets
    @Binding var stepIndex: Int
    let onDismiss: () -> Void

    private var topic: ViewerHelpTopic {
        ViewerHelpTopic.all[min(max(stepIndex, 0), ViewerHelpTopic.all.count - 1)]
    }

    var body: some View {
        GeometryReader { proxy in
            let targetFrame = resolvedTargetFrame(in: proxy)
            let safeWidth = proxy.size.width - safeAreaInsets.leading - safeAreaInsets.trailing
            let safeHeight = proxy.size.height - safeAreaInsets.top - safeAreaInsets.bottom
            let cardVisualClearance: CGFloat = 28
            let cardSize = CGSize(
                width: min(312, max(safeWidth - cardVisualClearance * 2, 220)),
                height: min(164, max(safeHeight - cardVisualClearance * 2, 146))
            )
            let cardFrame = resolvedCardFrame(
                targetFrame: targetFrame,
                cardSize: cardSize,
                containerSize: proxy.size,
                safeAreaInsets: safeAreaInsets,
                visualClearance: cardVisualClearance
            )

            ZStack(alignment: .topLeading) {
                spotlight(targetFrame: targetFrame)

                connector(from: cardFrame, to: targetFrame)
                    .stroke(
                        .white.opacity(0.92),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: .black.opacity(0.65), radius: 3)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: targetFrame.width + 12, height: targetFrame.height + 12)
                    .position(x: targetFrame.midX, y: targetFrame.midY)
                    .shadow(color: .blue.opacity(0.75), radius: 9)

                helpCard
                    .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
                    .position(x: cardFrame.midX, y: cardFrame.midY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            announceCurrentTopic()
        }
        .onChange(of: stepIndex) {
            announceCurrentTopic()
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: topic.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.blue, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("\(stepIndex + 1) of \(ViewerHelpTopic.all.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.58))
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close control tour")
            }

            Text(topic.detail)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(3)
                .minimumScaleFactor(0.88)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Button("Back") {
                    move(to: stepIndex - 1)
                }
                .buttonStyle(.plain)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .disabled(stepIndex == 0)
                .opacity(stepIndex == 0 ? 0 : 1)

                Spacer()

                Button {
                    if stepIndex == ViewerHelpTopic.all.count - 1 {
                        onDismiss()
                    } else {
                        move(to: stepIndex + 1)
                    }
                } label: {
                    Label(
                        stepIndex == ViewerHelpTopic.all.count - 1 ? "Done" : "Next",
                        systemImage: stepIndex == ViewerHelpTopic.all.count - 1 ? "checkmark" : "arrow.right"
                    )
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(.blue, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.20), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 9)
    }

    private func spotlight(targetFrame: CGRect) -> some View {
        ZStack {
            Color.black.opacity(0.70)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black)
                .frame(width: targetFrame.width + 12, height: targetFrame.height + 12)
                .position(x: targetFrame.midX, y: targetFrame.midY)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    private func resolvedTargetFrame(in proxy: GeometryProxy) -> CGRect {
        if topic.target == .desktop {
            let width = min(proxy.size.width * 0.28, 110)
            return CGRect(
                x: (proxy.size.width - width) / 2,
                y: (proxy.size.height * 0.40) - (width / 2),
                width: width,
                height: width
            )
        }

        if let anchor = anchors[topic.target] {
            return proxy[anchor]
        }

        return fallbackTargetFrame(for: topic.target, in: proxy.size)
    }

    private func fallbackTargetFrame(for target: ViewerHelpTarget, in size: CGSize) -> CGRect {
        let controlSize = CGSize(width: 52, height: 52)
        let origin: CGPoint

        switch target {
        case .desktop:
            origin = CGPoint(x: size.width / 2 - 26, y: size.height * 0.40 - 26)
        case .settings:
            origin = CGPoint(x: 14, y: 10)
        case .scroll:
            return CGRect(x: size.width - 32, y: size.height / 2 - 78, width: 22, height: 156)
        case .leftClick:
            origin = CGPoint(x: size.width - 138, y: size.height - 142)
        case .rightClick:
            origin = CGPoint(x: size.width - 74, y: size.height - 142)
        case .voice:
            origin = CGPoint(x: 20, y: size.height - 142)
        case .keyboard:
            origin = CGPoint(x: 76, y: size.height - 142)
        }

        return CGRect(origin: origin, size: controlSize)
    }

    private func resolvedCardFrame(
        targetFrame: CGRect,
        cardSize: CGSize,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets,
        visualClearance: CGFloat
    ) -> CGRect {
        let gap: CGFloat = 18
        var center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)

        if topic.target == .desktop {
            center.y = containerSize.height - safeAreaInsets.bottom - visualClearance - cardSize.height / 2
        } else if topic.target == .scroll, containerSize.width > 600 {
            center.x = targetFrame.minX - gap - cardSize.width / 2
        } else if targetFrame.midY < containerSize.height * 0.38 {
            center.y = targetFrame.maxY + gap + cardSize.height / 2
        } else {
            center.y = targetFrame.minY - gap - cardSize.height / 2
        }

        let minimumCenterX = safeAreaInsets.leading + visualClearance + cardSize.width / 2
        let maximumCenterX = containerSize.width - safeAreaInsets.trailing - visualClearance - cardSize.width / 2
        let minimumCenterY = safeAreaInsets.top + visualClearance + cardSize.height / 2
        let maximumCenterY = containerSize.height - safeAreaInsets.bottom - visualClearance - cardSize.height / 2

        center.x = minimumCenterX <= maximumCenterX
            ? min(max(center.x, minimumCenterX), maximumCenterX)
            : containerSize.width / 2
        center.y = minimumCenterY <= maximumCenterY
            ? min(max(center.y, minimumCenterY), maximumCenterY)
            : containerSize.height / 2

        return CGRect(
            x: center.x - cardSize.width / 2,
            y: center.y - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height
        )
    }

    private func connector(from cardFrame: CGRect, to targetFrame: CGRect) -> Path {
        let target = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let start: CGPoint

        if target.y < cardFrame.minY {
            start = CGPoint(x: min(max(target.x, cardFrame.minX + 24), cardFrame.maxX - 24), y: cardFrame.minY)
        } else if target.y > cardFrame.maxY {
            start = CGPoint(x: min(max(target.x, cardFrame.minX + 24), cardFrame.maxX - 24), y: cardFrame.maxY)
        } else if target.x < cardFrame.midX {
            start = CGPoint(x: cardFrame.minX, y: min(max(target.y, cardFrame.minY + 24), cardFrame.maxY - 24))
        } else {
            start = CGPoint(x: cardFrame.maxX, y: min(max(target.y, cardFrame.minY + 24), cardFrame.maxY - 24))
        }

        let angle = atan2(target.y - start.y, target.x - start.x)
        let arrowLength: CGFloat = 13
        let arrowSpread: CGFloat = 0.52

        return Path { path in
            path.move(to: start)
            path.addLine(to: target)
            path.move(to: target)
            path.addLine(to: CGPoint(
                x: target.x - arrowLength * cos(angle - arrowSpread),
                y: target.y - arrowLength * sin(angle - arrowSpread)
            ))
            path.move(to: target)
            path.addLine(to: CGPoint(
                x: target.x - arrowLength * cos(angle + arrowSpread),
                y: target.y - arrowLength * sin(angle + arrowSpread)
            ))
        }
    }

    private func move(to index: Int) {
        withAnimation(.snappy(duration: 0.24)) {
            stepIndex = min(max(index, 0), ViewerHelpTopic.all.count - 1)
        }
    }

    private func announceCurrentTopic() {
        UIAccessibility.post(notification: .screenChanged, argument: "\(topic.title). \(topic.detail)")
    }
}

#Preview("Viewer Help — Pointer") {
    Color.black
        .ignoresSafeArea()
        .overlay {
            ViewerHelpOverlay(
                anchors: [:],
                safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                stepIndex: .constant(0),
                onDismiss: {}
            )
        }
        .preferredColorScheme(.dark)
}

#Preview("Viewer Help — Scroll") {
    Color.black
        .ignoresSafeArea()
        .overlay {
            ViewerHelpOverlay(
                anchors: [:],
                safeAreaInsets: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59),
                stepIndex: .constant(3),
                onDismiss: {}
            )
        }
        .preferredColorScheme(.dark)
}

private struct ConnectionDetailLine: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.48))
                .textCase(.uppercase)
            Text(value.isEmpty ? "-" : value)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown after a connection or pairing attempt has run for a while. Tells the user
/// what is probably happening and gives them a way to get help without giving up.
private struct SlowConnectionAssist: View {
    let isWaitingForApproval: Bool
    let onShowHelp: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Label(
                isWaitingForApproval ? "Still waiting for the Mac to approve" : "Taking longer than usual",
                systemImage: isWaitingForApproval ? "person.badge.clock" : "clock.badge.questionmark"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))

            Text(isWaitingForApproval
                 ? "On the Mac, look for the New Device Request window and choose Authenticate and Approve. If the request expires, start pairing again."
                 : "Make sure the Mac is awake and hosting, and that both devices are on the same Wi-Fi network or both have Tailscale turned on.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: onShowHelp) {
                    Label("Need help?", systemImage: "questionmark.circle")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(ConnectSecondaryButtonStyle())

                ConnectionHelpLink(
                    title: "Online guide",
                    url: isWaitingForApproval ? ClientHelpLinks.approvalHelp : ClientHelpLinks.connectionHelp
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

/// Small inline link to a pocketctrl.com guide, used wherever a connection state
/// needs a "what do I do now" path (Tailscale off, local Wi-Fi not reachable).
struct ConnectionHelpLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the guide on pocketctrl.com")
    }
}

private struct TailscaleConnectionAssist: View {
    let isTailscaleInstalled: Bool
    let action: () -> Void
    let localWiFiAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isTailscaleInstalled ? "power.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

            VStack(spacing: 6) {
                Text("Tailscale is Off")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("The saved address uses Tailscale. If you're near your Mac, try local Wi-Fi instead.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.82)
            }

            Button(action: action) {
                Label(isTailscaleInstalled ? "Turn On Tailscale" : "Get Tailscale", systemImage: isTailscaleInstalled ? "power" : "arrow.down.app.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: 270)
            }
            .buttonStyle(ConnectPrimaryButtonStyle())
            .padding(.top, 2)

            Button(action: localWiFiAction) {
                Label("Connect over local Wi-Fi", systemImage: "wifi")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: 270)
            }
            .buttonStyle(ConnectSecondaryButtonStyle())

            Text(isTailscaleInstalled ? "Come back here after it connects." : "Install it once, then connect to this Mac over Tailscale.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            ConnectionHelpLink(title: "View the Tailscale setup guide", url: ClientHelpLinks.tailscaleGuide)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

struct ConnectMeshBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.96 + (sin(time * 0.95) * 0.035)

            ZStack {
                Color(red: 0.018, green: 0.018, blue: 0.034)

                GeometryReader { proxy in
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: points(at: time),
                        colors: [
                            Color(red: 0.018, green: 0.018, blue: 0.034),
                            Color(red: 0.11, green: 0.05, blue: 0.24),
                            Color(red: 0.03, green: 0.13, blue: 0.34),
                            Color(red: 0.08, green: 0.04, blue: 0.19),
                            Color(red: 0.23, green: 0.12, blue: 0.48),
                            Color(red: 0.10, green: 0.30, blue: 0.68),
                            Color(red: 0.035, green: 0.05, blue: 0.12),
                            Color(red: 0.34, green: 0.10, blue: 0.40),
                            Color(red: 0.95, green: 0.26, blue: 0.62)
                        ],
                        background: Color(red: 0.018, green: 0.018, blue: 0.034),
                        smoothsColors: true
                    )
                    .frame(
                        width: min(proxy.size.width * 1.35, 840),
                        height: min(proxy.size.height * 0.48, 430)
                    )
                    .blur(radius: 46)
                    .scaleEffect(pulse)
                    .opacity(0.36 + (sin(time * 0.95 + 0.7) * 0.045))
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
                }

                LinearGradient(
                    colors: [
                        .black.opacity(0.58),
                        .clear,
                        Color(red: 0.02, green: 0.025, blue: 0.055).opacity(0.70)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [.clear, .black.opacity(0.28)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .ignoresSafeArea()
        }
    }

    private func points(at time: TimeInterval) -> [SIMD2<Float>] {
        [
            SIMD2<Float>(0.00, 0.00),
            SIMD2<Float>(wave(0.50, amplitude: 0.045, time: time, speed: 0.33, phase: 0.0), 0.00),
            SIMD2<Float>(1.00, 0.00),
            SIMD2<Float>(0.00, wave(0.46, amplitude: 0.060, time: time, speed: 0.26, phase: 1.2)),
            SIMD2<Float>(wave(0.52, amplitude: 0.070, time: time, speed: 0.18, phase: 2.1), wave(0.52, amplitude: 0.065, time: time, speed: 0.24, phase: 0.8)),
            SIMD2<Float>(1.00, wave(0.55, amplitude: 0.060, time: time, speed: 0.22, phase: 2.8)),
            SIMD2<Float>(0.00, 1.00),
            SIMD2<Float>(wave(0.46, amplitude: 0.050, time: time, speed: 0.28, phase: 3.4), 1.00),
            SIMD2<Float>(1.00, 1.00)
        ]
    }

    private func wave(_ base: Double, amplitude: Double, time: TimeInterval, speed: Double, phase: Double) -> Float {
        Float(base + sin(time * speed + phase) * amplitude)
    }
}

private struct MacConnectionHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let steps = [
        ConnectionHelpStep(
            number: 1,
            text: "Install and open PocketCtrl on your Mac.",
            guideTitle: "View the Mac installation guide",
            guideURL: ClientHelpLinks.installGuide
        ),
        ConnectionHelpStep(
            number: 2,
            text: "On the Mac, start Hosting and choose Pair New Device. Keep the pairing screen open."
        ),
        ConnectionHelpStep(
            number: 3,
            text: "Scan its QR code, or enter the 12-character Computer Code. PocketCtrl immediately looks over local Wi-Fi and Tailscale."
        ),
        ConnectionHelpStep(
            number: 4,
            text: "A New Device Request window appears on the Mac. Check the iPhone name and requested controls, then choose Authenticate and Approve. If the request expires, start pairing again. Turn on Allow future unattended access only if you want reconnection after hosting or the Mac app restarts.",
            guideTitle: "The approval request is not appearing",
            guideURL: ClientHelpLinks.approvalHelp
        ),
        ConnectionHelpStep(
            number: 5,
            text: "Your iPhone and Mac must be on the same Wi-Fi network, or both must have Tailscale turned on. Guest networks, hotel Wi-Fi, and cellular data are not the same network as your Mac.",
            guideTitle: "Are my devices on the same network?",
            guideURL: ClientHelpLinks.sameNetworkHelp
        ),
        ConnectionHelpStep(
            number: 6,
            text: "Tailscale is optional on the same Wi-Fi. For remote access, install it on both devices and join the same tailnet.",
            guideTitle: "Tailscale setup and troubleshooting",
            guideURL: ClientHelpLinks.tailscaleGuide
        ),
        ConnectionHelpStep(
            number: 7,
            text: "Still stuck? The online help center explains every message PocketCtrl can show and what to do about it.",
            guideTitle: "Fix connection problems",
            guideURL: ClientHelpLinks.connectionHelp
        )
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ConnectMeshBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Text("Connect Your Mac")
                                .font(.system(size: 30, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)

                            Text("It only takes a minute.")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.68))
                        }

                        VStack(spacing: 12) {
                            ForEach(steps) { step in
                                HStack(alignment: .top, spacing: 13) {
                                    Text("\(step.number)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(.white.opacity(0.10), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))

                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(step.text)
                                            .font(.callout)
                                            .foregroundStyle(.white.opacity(0.82))
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)

                                        if let guideTitle = step.guideTitle,
                                           let guideURL = step.guideURL {
                                            Link(destination: guideURL) {
                                                HStack(spacing: 5) {
                                                    Text(guideTitle)
                                                    Image(systemName: "arrow.up.right")
                                                        .font(.caption2.weight(.bold))
                                                }
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.blue)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityHint("Opens the detailed guide on pocketctrl.com")
                                        }
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)

                        Button {
                            dismiss()
                        } label: {
                            Label("Got it", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ConnectPrimaryButtonStyle())
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 540)
                    .frame(minHeight: proxy.size.height)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
    }
}

private struct ConnectionHelpStep: Identifiable {
    let number: Int
    let text: String
    var guideTitle: String? = nil
    var guideURL: URL? = nil

    var id: Int { number }
}

struct RenameMacSheetItem: Identifiable {
    let id: String
}

struct MacInfoSheetItem: Identifiable {
    let id: String
}

struct SavedMacRow: View {
    let mac: ClientSavedMac
    let onConnect: () -> Void
    let onInfo: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onConnect) {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(mac.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(mac.routeSummary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Menu {
                Button {
                    onInfo()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }

                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove from List", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mac options")
        }
        .padding(.horizontal, 14)
        .frame(height: 68)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct MacInfoSheet: View {
    let mac: ClientSavedMac
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SettingsBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        SettingsHeroRow(
                            title: mac.name,
                            subtitle: mac.routeSummary,
                            status: "Saved",
                            isActive: false
                        )

                        SettingsSection(title: "Connection", systemImage: "point.3.connected.trianglepath.dotted") {
                            SettingsValueRow(
                                title: "Tailscale address",
                                value: mac.tailscaleHostAddress.emptyDash,
                                systemImage: "lock.shield",
                                infoTitle: "Tailscale Address",
                                infoMessage: MobilePairingHelpText.tailscaleIP
                            )
                            SettingsValueRow(title: "Local Wi-Fi address", value: mac.localHostAddress.emptyDash, systemImage: "wifi")
                            SettingsValueRow(title: "Video port", value: mac.videoPort.emptyDash, systemImage: "play.rectangle")
                            SettingsValueRow(title: "Input port", value: mac.inputPort.emptyDash, systemImage: "cursorarrow.motionlines")
                            SettingsValueRow(title: "Audio port", value: mac.audioPort.emptyDash, systemImage: "speaker.wave.2")
                        }

                        SettingsSection(title: "Trust", systemImage: "checkmark.shield.fill") {
                            SettingsValueRow(title: "Host ID", value: mac.id.emptyDash, systemImage: "number")
                            SettingsValueRow(
                                title: "Device credential",
                                value: "Protected in Keychain",
                                systemImage: "checkmark.shield",
                                infoTitle: "Device Credential",
                                infoMessage: "This private credential belongs only to this device. The Mac owner can revoke it without affecting other devices."
                            )
                            SettingsValueRow(title: "Last connected", value: mac.lastConnectedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Mac Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

struct RenameMacSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TextField("Mac name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)

                Button {
                    onSave()
                } label: {
                    Label("Save Name", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(22)
            .navigationTitle("Rename Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
        .onAppear {
            isNameFocused = true
        }
    }
}

struct ConnectNewMacFlowSheet: View {
    @ObservedObject var model: ClientModel
    let onScanQR: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingManualCodeFields: Bool
    @State private var manualPairingCode = ""

    init(
        model: ClientModel,
        startsInManualMode: Bool = false,
        onScanQR: @escaping () -> Void
    ) {
        self.model = model
        self.onScanQR = onScanQR
        _isShowingManualCodeFields = State(initialValue: startsInManualMode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Text("Connect a New Mac")
                        .font(.title2.weight(.semibold))

                    HStack(spacing: 6) {
                        Text("Scan the QR code, or use its Computer Code.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        MobilePairingInfoButton(
                            title: "Pairing",
                            message: MobilePairingHelpText.pairing
                        )
                    }
                    .multilineTextAlignment(.center)
                }
                .padding(.top, 4)

                Button {
                    onScanQR()
                } label: {
                    ConnectionTypeRow(
                        title: "Scan Pairing QR",
                        subtitle: "Starts immediately and asks the Mac owner to approve this iPhone.",
                        systemImage: "qrcode.viewfinder",
                        isPrimary: true
                    )
                }
                .buttonStyle(.plain)

                if !isShowingManualCodeFields {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            isShowingManualCodeFields = true
                        }
                    } label: {
                        Text("Connect manually")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }

                if isShowingManualCodeFields {
                    VStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text("Computer Code")
                                .font(.subheadline.weight(.semibold))

                            MobilePairingInfoButton(
                                title: "Computer Code",
                                message: MobilePairingHelpText.computerCode
                            )

                            Spacer()
                        }

                        TextField("ABCD-EFGH-JKLM", text: $manualPairingCode)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textInputAutocapitalization(.characters)
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: manualPairingCode) { _, value in
                                let normalized = String(
                                    value.uppercased()
                                        .filter { $0.isLetter || $0.isNumber }
                                        .prefix(PairingInvitationCode.encodedCharacterCount)
                                )
                                let grouped = stride(from: 0, to: normalized.count, by: 4).map { offset in
                                    let start = normalized.index(normalized.startIndex, offsetBy: offset)
                                    let end = normalized.index(start, offsetBy: min(4, normalized.count - offset))
                                    return String(normalized[start..<end])
                                }.joined(separator: "-")
                                if grouped != value {
                                    manualPairingCode = grouped
                                }
                            }

                        Button {
                            model.connectWithManualPairingCode(manualPairingCode)
                        } label: {
                            Label("Send Approval Request", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualPairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Text(model.manualPairingStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 0)
            }
            .padding(22)
            .navigationTitle("New Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onChange(of: model.isPairingRequestInProgress) { _, isInProgress in
                if isInProgress {
                    dismiss()
                }
            }
        }
    }
}

struct ConnectionTypeRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isPrimary = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 24 : 19, weight: .semibold))
                .foregroundStyle(isPrimary ? .white : .blue)
                .frame(width: isPrimary ? 54 : 42, height: isPrimary ? 54 : 42)
                .background(.blue.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(isPrimary ? .title3.weight(.semibold) : .headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(isPrimary ? 18 : 14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct NewMacNameSheet: View {
    @Binding var name: String
    let onSkip: () -> Void
    let onSave: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TextField("Mac name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)

                Button {
                    onSave()
                } label: {
                    Label("Save and Connect", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Skip") {
                    onSkip()
                }
                .buttonStyle(.borderless)
            }
            .padding(22)
            .navigationTitle("Name This Mac")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            isNameFocused = true
        }
    }
}

struct ConnectInputRow<Content: View>: View {
    let systemImage: String
    let placeholder: String
    let content: Content

    init(systemImage: String, placeholder: String, @ViewBuilder content: () -> Content) {
        self.systemImage = systemImage
        self.placeholder = placeholder
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 22)

            content
                .font(.body.weight(.medium))
                .textFieldStyle(.plain)
                .tint(.white)
                .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

struct ConnectPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.62))
            .padding(.vertical, 15)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.20, green: 0.46, blue: 1.00),
                        Color(red: 0.45, green: 0.22, blue: 0.96),
                        Color(red: 0.95, green: 0.25, blue: 0.62)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.34),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct ConnectSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.88 : 0.52))
            .padding(.vertical, 13)
            .padding(.horizontal, 12)
            .background(.white.opacity(configuration.isPressed ? 0.15 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

enum MovableControlHome {
    case trailingCenter
    case bottomLeading(bottomInset: CGFloat)
    case bottomTrailing(bottomInset: CGFloat)
    case bottomFreeTrailing(bottomInset: CGFloat)
}

struct MovableControlIsland<Content: View>: View {
    @Binding var offset: CGSize
    let bounds: CGSize
    let approximateSize: CGSize
    let home: MovableControlHome
    let dragExclusionRects: [CGRect]
    let onCenterChange: ((CGPoint) -> Void)?
    let content: Content
    @State private var dragStartOffset = CGSize.zero
    @State private var dragTranslation = CGSize.zero
    @State private var isMoving = false

    init(
        offset: Binding<CGSize>,
        bounds: CGSize,
        approximateSize: CGSize,
        home: MovableControlHome,
        dragExclusionRects: [CGRect] = [],
        onCenterChange: ((CGPoint) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self._offset = offset
        self.bounds = bounds
        self.approximateSize = approximateSize
        self.home = home
        self.dragExclusionRects = dragExclusionRects
        self.onCenterChange = onCenterChange
        self.content = content()
    }

    var body: some View {
        let base = basePoint()
        let center = CGPoint(x: base.x + offset.width, y: base.y + offset.height)
        let visualCenter = CGPoint(x: center.x + dragTranslation.width, y: center.y + dragTranslation.height)

        content
            .offset(dragTranslation)
            .scaleEffect(isMoving ? 1.04 : 1)
            .shadow(color: .black.opacity(isMoving ? 0.32 : 0), radius: 14, y: 8)
            .contentShape(Rectangle())
            .background {
                PressureUnlockDragLayer(
                    excludedRects: dragExclusionRects,
                    onBegin: beginMoveIfNeeded,
                    onChange: updateMove,
                    onEnd: finishMove
                )
            }
            .position(center)
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .onChange(of: bounds) {
                offset = clamped(offset)
            }
            .onAppear {
                onCenterChange?(visualCenter)
            }
            .onChange(of: visualCenter) {
                onCenterChange?(visualCenter)
            }
            .animation(.snappy(duration: 0.18), value: isMoving)
    }

    private func beginMoveIfNeeded() {
        guard !isMoving else { return }
        dragStartOffset = offset
        dragTranslation = .zero
        isMoving = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func updateMove(_ translation: CGSize) {
        beginMoveIfNeeded()
        let proposed = CGSize(
            width: dragStartOffset.width + translation.width,
            height: dragStartOffset.height + translation.height
        )
        let nextOffset = clamped(proposed)
        dragTranslation = CGSize(
            width: nextOffset.width - dragStartOffset.width,
            height: nextOffset.height - dragStartOffset.height
        )
    }

    private func finishMove() {
        guard isMoving else { return }
        offset = clamped(CGSize(
            width: dragStartOffset.width + dragTranslation.width,
            height: dragStartOffset.height + dragTranslation.height
        ))
        dragTranslation = .zero
        isMoving = false
    }

    private func clamped(_ proposed: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return proposed }
        let margin = edgeMargin
        let base = basePoint()
        let halfWidth = approximateSize.width / 2
        let halfHeight = approximateSize.height / 2
        let minX = margin + halfWidth - base.x
        let maxX = bounds.width - margin - halfWidth - base.x
        let minY = margin + halfHeight - base.y
        let maxY = bounds.height - margin - halfHeight - base.y

        switch home {
        case .trailingCenter:
            return CGSize(
                width: min(max(proposed.width, minX), maxX),
                height: min(max(proposed.height, minY), maxY)
            )
        case .bottomLeading:
            let laneMaxX = min(maxX, max((bounds.width / 2) - halfWidth - 1 - base.x, minX))
            return CGSize(
                width: min(max(proposed.width, minX), laneMaxX),
                height: min(max(proposed.height, minY), maxY)
            )
        case .bottomTrailing:
            let laneMinX = max(minX, min((bounds.width / 2) + halfWidth + 1 - base.x, maxX))
            return CGSize(
                width: min(max(proposed.width, laneMinX), maxX),
                height: min(max(proposed.height, minY), maxY)
            )
        case .bottomFreeTrailing:
            return CGSize(
                width: min(max(proposed.width, minX), maxX),
                height: min(max(proposed.height, minY), maxY)
            )
        }
    }

    private func basePoint() -> CGPoint {
        let margin = edgeMargin
        let trailingMargin: CGFloat = 3

        switch home {
        case .trailingCenter:
            return CGPoint(
                x: bounds.width - (approximateSize.width / 2) - trailingMargin,
                y: bounds.height / 2
            )
        case .bottomLeading(let bottomInset):
            return CGPoint(
                x: margin + (approximateSize.width / 2),
                y: bounds.height - bottomInset - (approximateSize.height / 2)
            )
        case .bottomTrailing(let bottomInset), .bottomFreeTrailing(let bottomInset):
            return CGPoint(
                x: bounds.width - margin - (approximateSize.width / 2),
                y: bounds.height - bottomInset - (approximateSize.height / 2)
            )
        }
    }

    private var edgeMargin: CGFloat {
        switch home {
        case .bottomLeading, .bottomTrailing:
            return bounds.width > bounds.height ? 10 : 16
        case .trailingCenter, .bottomFreeTrailing:
            return 10
        }
    }
}

private struct PressureUnlockDragLayer: UIViewRepresentable {
    let excludedRects: [CGRect]
    let onBegin: () -> Void
    let onChange: (CGSize) -> Void
    let onEnd: () -> Void

    func makeUIView(context: Context) -> PressureUnlockDragView {
        let view = PressureUnlockDragView()
        view.excludedRects = excludedRects
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
        return view
    }

    func updateUIView(_ uiView: PressureUnlockDragView, context: Context) {
        uiView.excludedRects = excludedRects
        uiView.onBegin = onBegin
        uiView.onChange = onChange
        uiView.onEnd = onEnd
    }
}

private final class PressureUnlockDragView: UIView {
    var excludedRects: [CGRect] = [] {
        didSet {
            forceDragRecognizer.excludedRects = excludedRects
        }
    }
    var onBegin: (() -> Void)?
    var onChange: ((CGSize) -> Void)?
    var onEnd: (() -> Void)?

    private let forceDragRecognizer = PressureUnlockDragRecognizer()
    private weak var attachedWindow: UIWindow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        forceDragRecognizer.targetView = self
        forceDragRecognizer.excludedRects = excludedRects
        forceDragRecognizer.onBegin = { [weak self] in self?.onBegin?() }
        forceDragRecognizer.onChange = { [weak self] translation in self?.onChange?(translation) }
        forceDragRecognizer.onEnd = { [weak self] in self?.onEnd?() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if attachedWindow !== window {
            attachedWindow?.removeGestureRecognizer(forceDragRecognizer)
            attachedWindow = window
            window?.addGestureRecognizer(forceDragRecognizer)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }

    deinit {
        attachedWindow?.removeGestureRecognizer(forceDragRecognizer)
    }
}

private final class PressureUnlockDragRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var targetView: UIView?
    var excludedRects: [CGRect] = []
    var onBegin: (() -> Void)?
    var onChange: ((CGSize) -> Void)?
    var onEnd: (() -> Void)?

    private weak var trackingTouch: UITouch?
    private var startLocation = CGPoint.zero
    private var latestLocation = CGPoint.zero
    private var isUnlocked = false
    private var fallbackUnlockWorkItem: DispatchWorkItem?
    private let forceThreshold: CGFloat = 0.56
    private let hapticTouchDuration: TimeInterval = 0.42
    private let hapticTouchMaximumDrift: CGFloat = 16

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackingTouch == nil,
              let touch = touches.first,
              touchIsInsideTarget(touch),
              !touchIsInsideExcludedRegion(touch) else {
            state = .failed
            return
        }

        trackingTouch = touch
        startLocation = touch.location(in: view)
        latestLocation = startLocation

        if hasForceTouch(for: touch) {
            unlockIfNeeded(using: touch)
        } else {
            scheduleHapticTouchFallback()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackingTouch, touches.contains(touch) else { return }

        latestLocation = touch.location(in: view)
        if !isUnlocked {
            unlockIfNeeded(using: touch)
        }

        if isUnlocked {
            state = .changed
            onChange?(translation(from: latestLocation))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackingTouch, touches.contains(touch) else { return }
        completeGesture()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackingTouch, touches.contains(touch) else { return }
        completeGesture()
    }

    override func reset() {
        fallbackUnlockWorkItem?.cancel()
        fallbackUnlockWorkItem = nil
        trackingTouch = nil
        isUnlocked = false
        startLocation = .zero
        latestLocation = .zero
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        !isUnlocked
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        isUnlocked
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        !isUnlocked
    }

    private func unlockIfNeeded(using touch: UITouch) {
        guard !isUnlocked, hasForceTouch(for: touch), touch.maximumPossibleForce > 0 else { return }
        let normalizedForce = touch.force / touch.maximumPossibleForce
        guard normalizedForce >= forceThreshold else { return }
        unlock()
    }

    private func scheduleHapticTouchFallback() {
        fallbackUnlockWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.trackingTouch != nil, !self.isUnlocked else { return }
            let drift = hypot(self.latestLocation.x - self.startLocation.x, self.latestLocation.y - self.startLocation.y)
            guard drift <= self.hapticTouchMaximumDrift else { return }
            self.unlock()
        }
        fallbackUnlockWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hapticTouchDuration, execute: workItem)
    }

    private func unlock() {
        guard !isUnlocked else { return }
        isUnlocked = true
        state = .began
        onBegin?()
        onChange?(translation(from: latestLocation))
    }

    private func completeGesture() {
        fallbackUnlockWorkItem?.cancel()
        fallbackUnlockWorkItem = nil
        if isUnlocked {
            state = .ended
            onEnd?()
        } else {
            state = .failed
        }
    }

    private func hasForceTouch(for touch: UITouch) -> Bool {
        touch.maximumPossibleForce > 0 && view?.traitCollection.forceTouchCapability == .available
    }

    private func touchIsInsideTarget(_ touch: UITouch) -> Bool {
        guard let targetView, let view else { return false }
        let targetFrame = targetView.convert(targetView.bounds, to: view)
        return targetFrame.insetBy(dx: -8, dy: -8).contains(touch.location(in: view))
    }

    private func touchIsInsideExcludedRegion(_ touch: UITouch) -> Bool {
        guard let targetView, let view else { return false }
        let location = touch.location(in: view)
        return excludedRects.contains { rect in
            targetView.convert(rect, to: view).contains(location)
        }
    }

    private func translation(from location: CGPoint) -> CGSize {
        CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
    }
}

struct RemoteTextToolBar: View {
    @ObservedObject var model: ClientModel
    @Binding var isKeyboardBarVisible: Bool
    @Binding var keyboardFocusToken: Int
    let isCompact: Bool
    @StateObject private var speech = ClientSpeechInput()
    @State private var streamedVoiceTranscript = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: isCompact ? 8 : 10) {
            Button {
                toggleVoice()
            } label: {
                Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                    .frame(width: isCompact ? 38 : 44, height: isCompact ? 36 : 44)
            }
            .buttonStyle(KeyboardControlButtonStyle(isSelected: speech.isRecording, color: speech.isRecording ? .red : .blue))
            .accessibilityLabel(speech.isRecording ? "Stop and type voice input" : "Start voice typing")
            .disabled(speech.isStarting)
            .viewerHelpTarget(.voice)

            Button {
                isKeyboardBarVisible = true
                keyboardFocusToken += 1
            } label: {
                Image(systemName: "keyboard")
                    .frame(width: isCompact ? 38 : 44, height: isCompact ? 36 : 44)
            }
            .buttonStyle(KeyboardControlButtonStyle(isSelected: false, color: .blue))
            .accessibilityLabel("Keyboard typing")
            .viewerHelpTarget(.keyboard)
        }
        .font(.system(size: isCompact ? 17 : 19, weight: .semibold))
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 8 : 10)
        .background(.black.opacity(0.58), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .opacity(model.isInputReady ? 1 : 0.35)
        .disabled(!model.isInputReady)
        .onChange(of: speech.transcript) {
            guard model.isInputReady else { return }
            streamRecognizedVoiceText(speech.transcript)
        }
        .onChange(of: model.isInputReady) {
            if !model.isInputReady { speech.interrupt() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { speech.interrupt() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ClientAudioSession.recordingMustStop)) { notification in
            guard let owner = notification.object as? UUID else { return }
            speech.interrupt(recordingOwner: owner)
        }
        .onDisappear { speech.stop() }
        .alert("Voice Input", isPresented: Binding(
            get: { speech.alertMessage != nil },
            set: { if !$0 { speech.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
            if speech.shouldOfferSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } message: {
            Text(speech.alertMessage ?? "")
        }
    }

    private func toggleVoice() {
        if speech.isRecording {
            let transcript = speech.stop()
            streamRecognizedVoiceText(transcript)
            streamedVoiceTranscript = ""
        } else {
            streamedVoiceTranscript = ""
            speech.start()
        }
    }

    private func streamRecognizedVoiceText(_ transcript: String) {
        guard !transcript.isEmpty else { return }

        if transcript.hasPrefix(streamedVoiceTranscript) {
            let addedText = String(transcript.dropFirst(streamedVoiceTranscript.count))
            if !addedText.isEmpty {
                model.sendText(addedText)
            }
            streamedVoiceTranscript = transcript
        } else if streamedVoiceTranscript.isEmpty {
            model.sendText(transcript)
            streamedVoiceTranscript = transcript
        }
    }
}

struct RemoteKeyboardAccessory: View {
    @ObservedObject var model: ClientModel
    @Binding var isKeyboardBarVisible: Bool
    @Binding var isShortcutComposerVisible: Bool
    @Binding var keyboardFocusToken: Int
    @Binding var commandText: String
    @Binding var liveTypingText: String
    @Binding var isLiveTypingAllSelected: Bool
    @Binding var shortcutFocusToken: Int

    private var parsedShortcut: MacParsedShortcut? {
        MacShortcutParser.parse(commandText)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isShortcutComposerVisible.toggle()
                if !isShortcutComposerVisible {
                    commandText = ""
                }
                shortcutFocusToken += 1
            } label: {
                Image(systemName: "command")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(KeyboardControlButtonStyle(isSelected: isShortcutComposerVisible, color: .blue))
            .accessibilityLabel("Mac shortcuts")

            KeyboardAccessoryInput(
                model: model,
                isCommandMode: isShortcutComposerVisible,
                commandText: $commandText,
                liveTypingText: $liveTypingText,
                isLiveTypingAllSelected: $isLiveTypingAllSelected,
                focusToken: keyboardFocusToken + shortcutFocusToken,
                onSubmitCommand: sendShortcut,
                onEditingEnded: {
                    isKeyboardBarVisible = false
                    isShortcutComposerVisible = false
                    commandText = ""
                }
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 38)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                dismissKeyboardBar()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(KeyboardControlButtonStyle(isSelected: false, color: .blue))
            .accessibilityLabel("Dismiss keyboard")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func sendShortcut() {
        guard let parsedShortcut else { return }
        model.sendShortcut(keyCode: parsedShortcut.keyCode, modifiers: parsedShortcut.modifiers)
        MacShortcutMirror.apply(parsedShortcut, liveTypingText: $liveTypingText, isLiveTypingAllSelected: $isLiveTypingAllSelected)
        commandText = ""
        shortcutFocusToken += 1
    }

    private func dismissKeyboardBar() {
        isShortcutComposerVisible = false
        isKeyboardBarVisible = false
        commandText = ""
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct KeyboardControlButtonStyle: ButtonStyle {
    let isSelected: Bool
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(isSelected ? .white : color)
            .background(
                Capsule()
                    .fill(isSelected ? color : color.opacity(configuration.isPressed ? 0.26 : 0.14))
            )
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(isSelected ? 0 : 0.55), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
            .animation(.snappy(duration: 0.16), value: isSelected)
    }
}

struct KeyboardAccessoryInput: UIViewRepresentable {
    @ObservedObject var model: ClientModel
    let isCommandMode: Bool
    @Binding var commandText: String
    @Binding var liveTypingText: String
    @Binding var isLiveTypingAllSelected: Bool
    let focusToken: Int
    let onSubmitCommand: () -> Void
    let onEditingEnded: () -> Void

    func makeUIView(context: Context) -> KeyboardAccessoryTextField {
        let textField = KeyboardAccessoryTextField()
        textField.backgroundColor = .clear
        textField.textColor = .label
        textField.tintColor = .systemBlue
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.keyboardType = .default
        textField.returnKeyType = .send
        textField.borderStyle = .none
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        textField.leftViewMode = .always
        textField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        textField.rightViewMode = .always
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.delegate = context.coordinator
        return textField
    }

    func updateUIView(_ uiView: KeyboardAccessoryTextField, context: Context) {
        context.coordinator.model = model
        context.coordinator.isCommandMode = isCommandMode
        context.coordinator.commandText = $commandText
        context.coordinator.liveTypingText = $liveTypingText
        context.coordinator.isLiveTypingAllSelected = $isLiveTypingAllSelected
        context.coordinator.focusToken = focusToken
        context.coordinator.onSubmitCommand = onSubmitCommand
        context.coordinator.onEditingEnded = onEditingEnded

        uiView.placeholder = isCommandMode ? "cmd + shift + 4" : "Typing straight into computer"
        uiView.onDeleteWhenEmpty = {
            context.coordinator.deleteBackwardAtEmptyBuffer()
        }

        let displayedText = isCommandMode ? commandText : liveTypingText
        if uiView.text != displayedText {
            let cursorOffset = isCommandMode ? nil : context.coordinator.remoteCursorOffset(for: displayedText)
            context.coordinator.setText(displayedText, in: uiView, cursorOffset: cursorOffset)
        }

        if !isCommandMode, isLiveTypingAllSelected {
            context.coordinator.selectAllText(in: uiView)
        }

        if focusToken > 0, focusToken != context.coordinator.lastAppliedFocusToken {
            context.coordinator.lastAppliedFocusToken = focusToken
            DispatchQueue.main.async {
                guard uiView.window != nil,
                      !context.coordinator.isDismantled,
                      context.coordinator.focusToken == focusToken else { return }
                uiView.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: KeyboardAccessoryTextField, coordinator: Coordinator) {
        coordinator.isDismantled = true
        uiView.delegate = nil
        uiView.onDeleteWhenEmpty = nil
        uiView.resignFirstResponder()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            isCommandMode: isCommandMode,
            commandText: $commandText,
            liveTypingText: $liveTypingText,
            isLiveTypingAllSelected: $isLiveTypingAllSelected,
            onSubmitCommand: onSubmitCommand,
            onEditingEnded: onEditingEnded
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var model: ClientModel
        var isCommandMode: Bool
        var commandText: Binding<String>
        var liveTypingText: Binding<String>
        var isLiveTypingAllSelected: Binding<Bool>
        var focusToken = 0
        var lastAppliedFocusToken = 0
        var onSubmitCommand: () -> Void
        var onEditingEnded: () -> Void
        var isDismantled = false
        private var remoteCursorIndex: Int?
        private var isSettingTextProgrammatically = false

        init(
            model: ClientModel,
            isCommandMode: Bool,
            commandText: Binding<String>,
            liveTypingText: Binding<String>,
            isLiveTypingAllSelected: Binding<Bool>,
            onSubmitCommand: @escaping () -> Void,
            onEditingEnded: @escaping () -> Void
        ) {
            self.model = model
            self.isCommandMode = isCommandMode
            self.commandText = commandText
            self.liveTypingText = liveTypingText
            self.isLiveTypingAllSelected = isLiveTypingAllSelected
            self.onSubmitCommand = onSubmitCommand
            self.onEditingEnded = onEditingEnded
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            let endedFocusToken = focusToken
            // Defer SwiftUI state changes out of UIKit's responder transition.
            // Ignore stale callbacks after a new focus request or teardown.
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self, let textField,
                      !self.isDismantled,
                      !textField.isFirstResponder,
                      self.focusToken == endedFocusToken else { return }
                self.onEditingEnded()
            }
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if isCommandMode {
                let currentText = textField.text ?? ""
                let normalized = MacShortcutParser.normalizedInput(
                    afterEditing: currentText,
                    range: range,
                    replacementString: string
                )
                commandText.wrappedValue = normalized
                setText(normalized, in: textField, cursorOffset: (normalized as NSString).length)
            } else {
                applyLiveTypingEdit(in: textField, range: range, replacementString: string)
            }

            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if isCommandMode {
                onSubmitCommand()
            } else {
                model.sendKey(keyCode: 36)
                liveTypingText.wrappedValue = ""
                isLiveTypingAllSelected.wrappedValue = false
                remoteCursorIndex = 0
                setText("", in: textField, cursorOffset: 0)
            }
            return false
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            guard !isCommandMode, !isSettingTextProgrammatically else { return }
            guard let selection = textField.selectedTextRange else { return }

            let startOffset = textField.offset(from: textField.beginningOfDocument, to: selection.start)
            let endOffset = textField.offset(from: textField.beginningOfDocument, to: selection.end)
            guard startOffset == endOffset else { return }

            let textLength = ((textField.text ?? "") as NSString).length
            moveRemoteCursor(to: startOffset, fallbackCurrentIndex: textLength, textLength: textLength)
        }

        func setText(_ text: String, in textField: UITextField, cursorOffset: Int?) {
            isSettingTextProgrammatically = true
            textField.text = text

            if let cursorOffset,
               let position = textField.position(from: textField.beginningOfDocument, offset: cursorOffset) {
                textField.selectedTextRange = textField.textRange(from: position, to: position)
            }

            DispatchQueue.main.async { [weak self] in
                self?.isSettingTextProgrammatically = false
            }
        }

        func selectAllText(in textField: UITextField) {
            guard !isSettingTextProgrammatically else { return }
            isSettingTextProgrammatically = true
            DispatchQueue.main.async {
                textField.selectedTextRange = textField.textRange(
                    from: textField.beginningOfDocument,
                    to: textField.endOfDocument
                )
                self.isSettingTextProgrammatically = false
            }
        }

        func remoteCursorOffset(for text: String) -> Int {
            let textLength = (text as NSString).length
            guard let remoteCursorIndex else { return textLength }
            return min(max(remoteCursorIndex, 0), textLength)
        }

        func deleteBackwardAtEmptyBuffer() {
            guard !isCommandMode else { return }
            model.sendKey(keyCode: 51)
            remoteCursorIndex = 0
        }

        private func applyLiveTypingEdit(in textField: UITextField, range: NSRange, replacementString string: String) {
            if isLiveTypingAllSelected.wrappedValue {
                applyEditReplacingAllSelectedText(in: textField, replacementString: string)
                return
            }

            let currentText = textField.text ?? liveTypingText.wrappedValue
            let currentLength = (currentText as NSString).length
            guard range.location >= 0, range.location + range.length <= currentLength else { return }

            let deletionEnd = range.location + range.length
            moveRemoteCursor(to: deletionEnd, fallbackCurrentIndex: currentLength, textLength: currentLength)

            if range.length > 0 {
                sendRepeatedKey(keyCode: 51, count: range.length)
            }

            if !string.isEmpty {
                model.sendText(string)
            }

            let nextText = (currentText as NSString).replacingCharacters(in: range, with: string)
            let nextCursorIndex = range.location + (string as NSString).length

            liveTypingText.wrappedValue = nextText
            remoteCursorIndex = nextCursorIndex
            setText(nextText, in: textField, cursorOffset: nextCursorIndex)
        }

        private func applyEditReplacingAllSelectedText(in textField: UITextField, replacementString string: String) {
            if string.isEmpty {
                model.sendKey(keyCode: 51)
                liveTypingText.wrappedValue = ""
                remoteCursorIndex = 0
                isLiveTypingAllSelected.wrappedValue = false
                setText("", in: textField, cursorOffset: 0)
                return
            }

            model.sendText(string)
            liveTypingText.wrappedValue = string
            remoteCursorIndex = (string as NSString).length
            isLiveTypingAllSelected.wrappedValue = false
            setText(string, in: textField, cursorOffset: remoteCursorIndex)
        }

        private func moveRemoteCursor(to targetIndex: Int, fallbackCurrentIndex: Int, textLength: Int) {
            let targetIndex = min(max(targetIndex, 0), textLength)
            let currentIndex = min(max(remoteCursorIndex ?? fallbackCurrentIndex, 0), textLength)
            let delta = targetIndex - currentIndex

            if delta < 0 {
                sendRepeatedKey(keyCode: 123, count: abs(delta))
            } else if delta > 0 {
                sendRepeatedKey(keyCode: 124, count: delta)
            }

            remoteCursorIndex = targetIndex
        }

        private func sendRepeatedKey(keyCode: UInt16, count: Int) {
            guard count > 0 else { return }
            for _ in 0..<count {
                model.sendKey(keyCode: keyCode)
            }
        }
    }
}

final class KeyboardAccessoryTextField: UITextField {
    var onDeleteWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        if (text ?? "").isEmpty {
            onDeleteWhenEmpty?()
            return
        }
        super.deleteBackward()
    }

    override var hasText: Bool {
        true
    }

    override var canBecomeFirstResponder: Bool {
        true
    }
}

struct RemoteShortcutComposer: View {
    @ObservedObject var model: ClientModel
    @Binding var commandText: String
    @Binding var liveTypingText: String
    @Binding var isLiveTypingAllSelected: Bool
    @Binding var shortcutFocusToken: Int

    private let quickTokens: [MacShortcutToken] = [
        MacShortcutToken(label: "cmd", insertedText: "cmd"),
        MacShortcutToken(label: "shift", insertedText: "shift"),
        MacShortcutToken(label: "option", insertedText: "option"),
        MacShortcutToken(label: "control", insertedText: "control"),
        MacShortcutToken(label: "tab", insertedText: "tab"),
        MacShortcutToken(label: "esc", insertedText: "esc"),
        MacShortcutToken(label: "return", insertedText: "return"),
        MacShortcutToken(label: "delete", insertedText: "delete"),
        MacShortcutToken(label: "space", insertedText: "space"),
        MacShortcutToken(label: "up", insertedText: "up"),
        MacShortcutToken(label: "down", insertedText: "down"),
        MacShortcutToken(label: "left", insertedText: "left"),
        MacShortcutToken(label: "right", insertedText: "right")
    ]

    private var parsedShortcut: MacParsedShortcut? {
        MacShortcutParser.parse(commandText)
    }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickTokens) { token in
                        Button {
                            append(token)
                        } label: {
                            Text(token.label)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(minWidth: token.label.count > 4 ? 68 : 48, minHeight: 32)
                        }
                        .buttonStyle(ShortcutTokenButtonStyle())
                    }
                }
            }

            Button {
                sendShortcut()
            } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: 42, height: 32)
            }
            .buttonStyle(ShortcutSendButtonStyle(isEnabled: parsedShortcut != nil && model.isInputReady))
            .disabled(parsedShortcut == nil || !model.isInputReady)
            .accessibilityLabel("Send shortcut")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func append(_ token: MacShortcutToken) {
        commandText = MacShortcutParser.appending(token.insertedText, to: commandText)
        shortcutFocusToken += 1
    }

    private func sendShortcut() {
        guard let parsedShortcut else { return }
        model.sendShortcut(keyCode: parsedShortcut.keyCode, modifiers: parsedShortcut.modifiers)
        MacShortcutMirror.apply(parsedShortcut, liveTypingText: $liveTypingText, isLiveTypingAllSelected: $isLiveTypingAllSelected)
        commandText = ""
        shortcutFocusToken += 1
    }
}

struct MacShortcutToken: Identifiable {
    let label: String
    let insertedText: String
    var id: String { insertedText }
}

struct ShortcutTokenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.82 : 0.96))
            .background(
                Capsule()
                    .fill(Color.blue.opacity(configuration.isPressed ? 0.26 : 0.18))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.blue.opacity(0.62), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

struct ShortcutSendButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.7))
            .background(
                Capsule()
                    .fill(Color.blue.opacity(isEnabled ? (configuration.isPressed ? 0.72 : 0.92) : 0.28))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(isEnabled ? 0.22 : 0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .animation(.snappy(duration: 0.16), value: isEnabled)
    }
}

struct MacParsedShortcut {
    let keyCode: UInt16
    let modifiers: UInt64
}

enum MacShortcutMirror {
    static func apply(
        _ shortcut: MacParsedShortcut,
        liveTypingText: Binding<String>,
        isLiveTypingAllSelected: Binding<Bool>
    ) {
        if isSelectAll(shortcut) {
            isLiveTypingAllSelected.wrappedValue = !liveTypingText.wrappedValue.isEmpty
            return
        }

        if isDelete(shortcut), isLiveTypingAllSelected.wrappedValue {
            liveTypingText.wrappedValue = ""
            isLiveTypingAllSelected.wrappedValue = false
            return
        }

        isLiveTypingAllSelected.wrappedValue = false
    }

    private static func isSelectAll(_ shortcut: MacParsedShortcut) -> Bool {
        shortcut.keyCode == 0 && shortcut.modifiers == MacShortcutModifier.command.rawValue
    }

    private static func isDelete(_ shortcut: MacParsedShortcut) -> Bool {
        shortcut.keyCode == 51 && shortcut.modifiers == 0
    }
}

enum MacShortcutParser {
    static func normalizedInput(afterEditing currentText: String, range: NSRange, replacementString string: String) -> String {
        let nsCurrent = currentText as NSString
        guard range.location >= 0, range.location + range.length <= nsCurrent.length else {
            return normalizedInput(currentText)
        }

        let nextText = nsCurrent.replacingCharacters(in: range, with: string)
        let isDeletingAtEnd = string.isEmpty && range.length > 0 && range.location + range.length == nsCurrent.length

        if isDeletingAtEnd {
            if currentText.hasSuffix(" + "), range.length == 1, range.location == nsCurrent.length - 1 {
                return String(currentText.dropLast(3))
            }

            if nextText.hasSuffix(" +") {
                return String(nextText.dropLast(2))
            }
        }

        return normalizedInput(nextText)
    }

    static func normalizedInput(_ text: String) -> String {
        var tokens: [String] = []
        var current = ""
        var endedWithSeparator = false

        for character in text {
            if character == "+" || character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                endedWithSeparator = true
            } else {
                current.append(character)
                endedWithSeparator = false
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        var normalized = tokens.joined(separator: " + ")
        if endedWithSeparator, !normalized.isEmpty {
            normalized += " + "
        }
        return normalized
    }

    static func appending(_ token: String, to text: String) -> String {
        let trimmed = normalizedInput(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return token }
        return "\(trimmed) + \(token)"
    }

    static func parse(_ text: String) -> MacParsedShortcut? {
        let tokens = normalizedInput(text)
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        var modifiers: UInt64 = 0
        var keyCode: UInt16?

        for token in tokens {
            if let modifier = modifierValue(for: token) {
                modifiers |= modifier
                continue
            }

            guard keyCode == nil, let key = keyValue(for: token) else {
                return nil
            }
            modifiers |= key.modifiers
            keyCode = key.keyCode
        }

        guard let keyCode else { return nil }
        return MacParsedShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private static func modifierValue(for token: String) -> UInt64? {
        switch token {
        case "cmd", "command", "⌘":
            return MacShortcutModifier.command.rawValue
        case "shift", "⇧":
            return MacShortcutModifier.shift.rawValue
        case "option", "opt", "alt", "⌥":
            return MacShortcutModifier.option.rawValue
        case "control", "ctrl", "ctl", "⌃", "^":
            return MacShortcutModifier.control.rawValue
        default:
            return nil
        }
    }

    private static func keyValue(for token: String) -> (keyCode: UInt16, modifiers: UInt64)? {
        switch token {
        case "tab":
            return (48, 0)
        case "return", "enter":
            return (36, 0)
        case "esc", "escape":
            return (53, 0)
        case "delete", "backspace", "del":
            return (51, 0)
        case "space", "spacebar":
            return (49, 0)
        case "up", "uparrow", "arrowup", "↑":
            return (126, 0)
        case "down", "downarrow", "arrowdown", "↓":
            return (125, 0)
        case "left", "leftarrow", "arrowleft", "←":
            return (123, 0)
        case "right", "rightarrow", "arrowright", "→":
            return (124, 0)
        case "plus":
            return (24, ClientTextTyper.shiftModifier)
        default:
            guard token.count == 1,
                  let character = token.first,
                  let keyCode = ClientTextTyper.keyCode(for: character) else {
                return nil
            }
            return (keyCode, 0)
        }
    }
}

enum MacShortcutModifier: UInt64, CaseIterable, Identifiable {
    case command = 0x0010_0000
    case shift = 0x0002_0000
    case option = 0x0008_0000
    case control = 0x0004_0000

    var id: UInt64 { rawValue }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
}

struct ClientSettingsView: View {
    @ObservedObject var model: ClientModel
    @Binding var areOnScreenControlsHidden: Bool
    let onConnectNewMac: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isAdvancedVisible = false
    @State private var infoMacID: String?
    @State private var renameMacID: String?
    @State private var renameMacNameDraft = ""

    var body: some View {
        NavigationStack {
            ZStack {
                SettingsBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        SettingsSavedMacsSection(
                            model: model,
                            selectedMacID: model.pairedHostID,
                            isConnectionActive: isConnectionActive,
                            connectionStatus: connectionDisplayStatus,
                            onSelect: { mac in
                                if mac.id != model.pairedHostID || !isConnectionActive {
                                    model.connect(to: mac)
                                }
                                dismiss()
                            },
                            onDisconnect: {
                                model.disconnect()
                            },
                            onInfo: { mac in
                                infoMacID = mac.id
                            },
                            onRename: { mac in
                                renameMacID = mac.id
                                renameMacNameDraft = mac.name
                            },
                            onConnectNewMac: {
                                onConnectNewMac()
                            }
                        )

                        SettingsSection(title: "This Device", systemImage: "iphone") {
                            SettingsTextFieldRow(
                                title: "Name",
                                systemImage: "person.text.rectangle",
                                text: $model.viewerDeviceName,
                                placeholder: "My iPhone",
                                textInputAutocapitalization: .words
                            )
                        }

                        SettingsSection(title: "Stream", systemImage: "sparkles.tv") {
                            SettingsStreamQualityRow(model: model)
                        }

                        SettingsSection(title: "Controls", systemImage: "slider.horizontal.3") {
                            SettingsToggleRow(title: "Auto zoom focused window", subtitle: "Zooms locally when the focused Mac window changes. Pinch or two-finger double-tap to view the full screen.", systemImage: "macwindow.on.rectangle", isOn: $model.autoZoomFocusedWindow)
                            SettingsToggleRow(title: "Show remote pointer", subtitle: "Show the blue pointer circle over the Mac screen.", systemImage: "cursorarrow.rays", isOn: $model.showRemotePointer)
                            SettingsToggleRow(title: "Stream Mac audio", subtitle: model.audioStatus, systemImage: "speaker.wave.2.fill", isOn: $model.audioEnabled)
                            SettingsToggleRow(title: "Hide on-screen controls", subtitle: "Hide the floating buttons while connected.", systemImage: "rectangle.dashed", isOn: $areOnScreenControlsHidden)
                        }

                        SettingsSection(title: "Privacy", systemImage: "hand.raised") {
                            Link(destination: ClientLegalLinks.privacyPolicy) {
                                HStack(spacing: 12) {
                                    Text("Privacy Policy")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .accessibilityHidden(true)
                                }
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.86))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the PocketCtrl privacy policy in your browser")
                        }

                        SettingsSection(title: "Diagnostics", systemImage: "wrench.and.screwdriver") {
                            DisclosureGroup(isExpanded: $isAdvancedVisible) {
                                VStack(spacing: 12) {
                                    SettingsValueRow(title: "Connection", value: connectionDisplayStatus, systemImage: "circle.fill")
                                    SettingsValueRow(title: "Selected route", value: selectedRoute, systemImage: "location.fill")
                                    SettingsValueRow(title: "Local discovery", value: model.localDiscoveryStatus, systemImage: "dot.radiowaves.left.and.right")
                                    SettingsValueRow(title: "This iPhone address", value: model.deviceAddress, systemImage: "iphone")
                                    SettingsValueRow(title: "Video", value: videoDisplayStatus, systemImage: "display")
                                    SettingsValueRow(title: "Input", value: model.inputTargetStatus, systemImage: "cursorarrow")
                                    SettingsValueRow(title: "Last input", value: model.lastEvent, systemImage: "hand.tap")
                                    SettingsDiagnosticBox(text: diagnosticDisplayText)
                                }
                                .padding(.top, 12)
                            } label: {
                                SettingsDisclosureLabel(title: "Live status and route logs")
                            }
                            .tint(.white.opacity(0.86))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Settings")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .sheet(item: renameSheetBinding) { item in
                RenameMacSheet(
                    name: $renameMacNameDraft,
                    onCancel: {
                        renameMacID = nil
                    },
                    onSave: {
                        model.renameSavedMac(id: item.id, to: renameMacNameDraft)
                        renameMacID = nil
                    }
                )
                .presentationDetents([.height(230)])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: infoSheetBinding) { item in
                if let mac = model.savedMacs.first(where: { $0.id == item.id }) {
                    MacInfoSheet(
                        mac: mac
                    )
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground {
                        SettingsBackground()
                    }
                }
            }
        }
        .background(SettingsBackground())
        .preferredColorScheme(.dark)
    }

    private var infoSheetBinding: Binding<MacInfoSheetItem?> {
        Binding(
            get: {
                guard let infoMacID else { return nil }
                return MacInfoSheetItem(id: infoMacID)
            },
            set: { item in
                infoMacID = item?.id
            }
        )
    }

    private var renameSheetBinding: Binding<MacInfoSheetItem?> {
        Binding(
            get: {
                guard let renameMacID else { return nil }
                return MacInfoSheetItem(id: renameMacID)
            },
            set: { item in
                renameMacID = item?.id
            }
        )
    }

    private var selectedRoute: String {
        model.routeStatus.replacingOccurrences(of: "Route: ", with: "").emptyDash
    }

    private var isConnectionActive: Bool {
        model.isConnected || model.isConnectionAttemptInProgress || model.isAutomaticReconnectInProgress
    }

    private var connectionDisplayStatus: String {
        if model.isAutomaticReconnectInProgress || model.isConnectionAttemptInProgress {
            return "Connecting"
        }
        return model.isConnected ? "Connected" : "Idle"
    }

    private var videoDisplayStatus: String {
        if model.isConnectionAttemptInProgress && !model.hasDisplayedVideoFrame {
            return "Waiting for Mac video"
        }
        if model.isConnectionAttemptInProgress || model.isAutomaticReconnectInProgress {
            return "Reconnecting"
        }
        return model.videoStatus
    }

    private var diagnosticDisplayText: String {
        if model.isConnectionAttemptInProgress && !model.hasDisplayedVideoFrame {
            return "Trying the selected route and retrying quietly until video arrives. Use Stop if you want to choose another Mac."
        }
        return model.routeDiagnostic
    }

}

private extension String {
    var emptyDash: String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : self
    }
}

struct SettingsBackground: View {
    var body: some View {
        Color(red: 0.035, green: 0.038, blue: 0.045)
            .ignoresSafeArea()
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
                .textCase(.uppercase)

            VStack(spacing: 10) {
                content
            }
            .padding(12)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
    }
}

struct SettingsHeroRow: View {
    let title: String
    let subtitle: String
    let status: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .green : .white.opacity(0.52))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((isActive ? Color.green : Color.white).opacity(isActive ? 0.16 : 0.08), in: Capsule())
        }
    }
}

struct SettingsSavedMacsSection: View {
    @ObservedObject var model: ClientModel
    let selectedMacID: String
    let isConnectionActive: Bool
    let connectionStatus: String
    let onSelect: (ClientSavedMac) -> Void
    let onDisconnect: () -> Void
    let onInfo: (ClientSavedMac) -> Void
    let onRename: (ClientSavedMac) -> Void
    let onConnectNewMac: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Macs", systemImage: "desktopcomputer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
                .textCase(.uppercase)

            if model.savedMacs.isEmpty {
                SettingsEmptyRow(
                    title: "No saved Macs yet",
                    subtitle: "Connect a new Mac from the home screen or scan a pairing QR below."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(model.savedMacs) { mac in
                        SettingsSavedMacPickerRow(
                            mac: mac,
                            isSelected: mac.id == selectedMacID,
                            isActive: isConnectionActive && mac.id == selectedMacID,
                            status: mac.id == selectedMacID ? connectionStatus : "Saved",
                            onSelect: {
                                onSelect(mac)
                            },
                            onDisconnect: onDisconnect,
                            onInfo: {
                                onInfo(mac)
                            },
                            onRename: {
                                onRename(mac)
                            },
                            onRemove: {
                                model.removeSavedMac(id: mac.id)
                            }
                        )
                    }
                }
            }

            Button {
                onConnectNewMac()
            } label: {
                Label("Connect a new Mac", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ConnectSecondaryButtonStyle())
        }
    }
}

struct SettingsSavedMacPickerRow: View {
    let mac: ClientSavedMac
    let isSelected: Bool
    let isActive: Bool
    let status: String
    let onSelect: () -> Void
    let onDisconnect: () -> Void
    let onInfo: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: isSelected ? 12 : 0) {
            HStack(spacing: 12) {
                Button(action: onSelect) {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(mac.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            Text(mac.routeSummary)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                Menu {
                    Button {
                        onInfo()
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }

                    Button {
                        onRename()
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove from List", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if isSelected {
                HStack(spacing: 10) {
                    Label(status, systemImage: isActive ? "checkmark.circle.fill" : "circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isActive ? .green : .white.opacity(0.64))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background((isActive ? Color.green : Color.white).opacity(isActive ? 0.16 : 0.08), in: Capsule())

                    Spacer(minLength: 0)

                    if isActive {
                        Button(action: onDisconnect) {
                            Label("Disconnect", systemImage: "xmark.circle.fill")
                                .lineLimit(1)
                                .frame(minWidth: 118)
                        }
                        .buttonStyle(SettingsInlineActionButtonStyle(tint: .white, isProminent: false))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        Button(action: onSelect) {
                            Label("Connect", systemImage: "play.fill")
                                .lineLimit(1)
                                .frame(minWidth: 104)
                        }
                        .buttonStyle(SettingsInlineActionButtonStyle(tint: .blue, isProminent: true))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(minHeight: isSelected ? 104 : 72)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(.white.opacity(isSelected ? 0.105 : 0.075), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(isSelected ? 0.16 : 0.11), lineWidth: 1))
        .animation(.snappy(duration: 0.22), value: isSelected)
        .animation(.snappy(duration: 0.22), value: isActive)
    }
}

struct SettingsEmptyRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private enum MobilePairingHelpText {
    static let pairing = "Scanning immediately starts looking for the Mac over local Wi-Fi and Tailscale. The Mac owner must approve before control begins. A session-only approval must be paired again after hosting or the Mac app restarts."
    static let computerCode = "Enter the code shown on the Mac. PocketCtrl automatically tries local Wi-Fi and Tailscale, then the Mac asks someone there to approve the request."
    static let tailscaleIP = "PocketCtrl prefers local Wi-Fi when the devices share a subnet and otherwise uses Tailscale automatically."
}

struct MobilePairingInfoButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .alert(title, isPresented: $isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String
    let systemImage: String
    var infoTitle: String? = nil
    var infoMessage: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: 24)

            Text(title)
                .foregroundStyle(.white.opacity(0.76))

            if let infoTitle, let infoMessage {
                MobilePairingInfoButton(title: infoTitle, message: infoMessage)
            }

            Spacer(minLength: 12)

            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .foregroundStyle(.white.opacity(0.52))
                .font(value.count > 18 ? .caption.monospacedDigit() : .subheadline.monospacedDigit())
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}

struct SettingsTextFieldRow: View {
    let title: String
    let systemImage: String
    @Binding var text: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var textInputAutocapitalization: TextInputAutocapitalization = .never

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: 24)

            Text(title)
                .foregroundStyle(.white.opacity(0.76))

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(textInputAutocapitalization)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
                .textFieldStyle(.plain)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}

struct SettingsSecureFieldRow: View {
    let title: String
    let systemImage: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: 24)

            Text(title)
                .foregroundStyle(.white.opacity(0.76))

            SecureField(placeholder, text: $text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
                .textFieldStyle(.plain)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.white.opacity(0.86))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.blue)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}

struct SettingsStreamQualityRow: View {
    @ObservedObject var model: ClientModel

    private var settings: ClientStreamSettings { model.streamSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Stream Quality")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(settings.qualityTitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }

            SettingsStreamSliderRow(
                title: "Detail",
                value: "\(Int((settings.detailAmount * 100).rounded()))%",
                binding: $model.streamDetailAmount,
                range: 0...1
            )

            SettingsStreamSliderRow(
                title: "FPS",
                value: "\(settings.maximumFrameRate)",
                binding: $model.streamFrameRate,
                range: ClientStreamSettings.frameRateRange
            )

            VStack(spacing: 6) {
                HStack {
                    Text("Video budget")
                    Spacer(minLength: 8)
                    Text(settings.estimatedUsageDescription)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }
                HStack {
                    Text("Live video")
                    Spacer(minLength: 8)
                    Text(model.isConnected ? ClientStreamSettings.usageDescription(megabitsPerSecond: model.latestReceivedMbps) : "—")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.vertical, 2)
    }
}

struct SettingsStreamSliderRow: View {
    let title: String
    let value: String
    let binding: Binding<Double>
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .foregroundStyle(.white.opacity(0.76))
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(.white.opacity(0.62))
                    .monospacedDigit()
            }
            .font(.subheadline)

            Slider(value: binding, in: range)
                .tint(.blue)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
        .padding(.vertical, 2)
    }
}

struct SettingsDisclosureLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
    }
}

struct SettingsDiagnosticBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.white.opacity(0.58))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SettingsPrimaryButtonStyle: ButtonStyle {
    var isDestructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.58))
            .padding(.vertical, 12)
            .background(fill(configuration: configuration), in: Capsule())
            .overlay(Capsule().strokeBorder(strokeColor.opacity(isEnabled ? 1 : 0.35), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private func fill(configuration: Configuration) -> Color {
        if isDestructive {
            return .white.opacity(isEnabled ? (configuration.isPressed ? 0.10 : 0.14) : 0.05)
        }
        return .blue.opacity(isEnabled ? (configuration.isPressed ? 0.70 : 0.92) : 0.30)
    }

    private var strokeColor: Color {
        isDestructive ? .white.opacity(0.18) : .white.opacity(0.16)
    }
}

struct SettingsInlineActionButtonStyle: ButtonStyle {
    var tint: Color
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.94 : 0.50))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .background(fillOpacity(configuration: configuration), in: Capsule())
            .overlay(Capsule().strokeBorder(strokeOpacity, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private func fillOpacity(configuration: Configuration) -> Color {
        if isProminent {
            return tint.opacity(isEnabled ? (configuration.isPressed ? 0.62 : 0.82) : 0.24)
        }
        return Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.14 : 0.10) : 0.05)
    }

    private var strokeOpacity: Color {
        if isProminent {
            return Color.white.opacity(isEnabled ? 0.18 : 0.08)
        }
        return Color.white.opacity(isEnabled ? 0.18 : 0.08)
    }
}

struct SettingsSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.88 : 0.50))
            .padding(.vertical, 12)
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

struct PairingCodeScannerSheet: View {
    @Binding var message: String?
    var onManual: (() -> Void)? = nil
    let onCode: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessingScan = false
    @State private var scannerID = UUID()

    var body: some View {
        NavigationStack {
            ZStack {
                QRCodeScannerView(
                    onCode: handleScannedCode,
                    onStatus: { message = $0 }
                )
                .id(scannerID)
                .ignoresSafeArea(edges: .bottom)

                if let onManual {
                    VStack {
                        Spacer()

                        Button {
                            onManual()
                        } label: {
                            Text("Connect manually")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(.black.opacity(0.42), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessingScan)
                        .padding(.bottom, 26)
                    }
                }

                if isProcessingScan {
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.large)

                        Text("Finding Your Mac...")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text("Trying local Wi-Fi and Tailscale. You'll approve the request on your Mac.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center)

                        Text("Use the same Wi-Fi network as your Mac, or turn on Tailscale on both devices.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .padding(.horizontal, 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.snappy(duration: 0.18), value: isProcessingScan)
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isProcessingScan)
                }
            }
        }
    }

    private func handleScannedCode(_ value: String) {
        guard !isProcessingScan else { return }
        isProcessingScan = true
        let accepted = onCode(value)
        if !accepted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isProcessingScan = false
                scannerID = UUID()
            }
        }
    }
}

struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onStatus: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(onCode: onCode, onStatus: onStatus)
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private let onStatus: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScanCode = false

    init(onCode: @escaping (String) -> Void, onStatus: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onStatus = onStatus
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    private func configureCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configureSession() : self?.showStatus("Camera access is needed to scan the pairing code.")
                }
            }
        default:
            showStatus("Camera access is needed to scan the pairing code.")
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showStatus("This device cannot open the camera scanner.")
            return
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showStatus("This device cannot scan QR codes.")
            return
        }

        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer

        addScannerOverlay()

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    private func addScannerOverlay() {
        let frameView = UIView()
        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.layer.borderColor = UIColor.systemBlue.cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 18
        frameView.backgroundColor = UIColor.clear
        view.addSubview(frameView)

        NSLayoutConstraint.activate([
            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frameView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.68),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor)
        ])
    }

    private func showStatus(_ status: String) {
        onStatus(status)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = status
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScanCode,
              let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadata.type == .qr,
              let value = metadata.stringValue else {
            return
        }

        didScanCode = true
        session.stopRunning()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCode(value)
    }
}

#Preview {
    ClientContentView()
}
