// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: RemoteDesktopModel
    @AppStorage("PocketCtrl.hasCompletedMacFirstLaunchTutorial") private var hasCompletedFirstLaunchTutorial = false
    @State private var selectedMode: MacWorkspaceMode = .viewer
    @State private var isHostSidebarPresented = false
    @State private var isControllerActionsPresented = false

    var body: some View {
        ZStack {
            MacMeshBackground()

            VStack(spacing: 0) {
                topBar

                ZStack(alignment: .trailing) {
                    ViewerWorkspaceView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isHostSidebarPresented {
                        Rectangle()
                            .fill(.black.opacity(0.18))
                            .ignoresSafeArea()
                            .transition(.opacity)
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.24)) {
                                    isHostSidebarPresented = false
                                }
                            }

                        HostSidebarView(model: model, isPresented: $isHostSidebarPresented)
                            .frame(width: 410)
                            .frame(maxHeight: .infinity)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.26), value: isHostSidebarPresented)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 1080, minHeight: 680)
        .overlayPreferenceValue(MacTutorialTargetPreferenceKey.self) { targets in
            GeometryReader { proxy in
                if !hasCompletedFirstLaunchTutorial,
                   let hostAnchor = targets[.host],
                   let connectAnchor = targets[.connect] {
                    MacFirstLaunchTutorialOverlay(
                        hostFrame: proxy[hostAnchor],
                        connectFrame: proxy[connectAnchor]
                    ) {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            hasCompletedFirstLaunchTutorial = true
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pocketCtrlShowViewer)) { _ in
            withAnimation(.snappy(duration: 0.24)) {
                isHostSidebarPresented = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pocketCtrlShowHostingControls)) { _ in
            withAnimation(.snappy(duration: 0.24)) {
                isHostSidebarPresented = true
            }
        }
        .sheet(item: pendingManualPairingBinding) { request in
            ManualPairingApprovalSheet(
                request: request,
                code: model.manualPairingCode,
                onApprove: { options in
                    Task {
                        await model.approveManualPairingRequest(request, options: options)
                    }
                },
                onDeny: {
                    model.denyManualPairingRequest(request)
                }
            )
        }
        .alert(item: $model.viewerUserFacingIssue) { issue in
            if let helpURL = connectionHelpURL(for: issue) {
                return Alert(
                    title: Text(issue.title),
                    message: Text(issue.message + "\n\n" + MacHelpLinks.sameNetworkHint),
                    primaryButton: .default(Text("Connection Help")) {
                        NSWorkspace.shared.open(helpURL)
                    },
                    secondaryButton: .cancel(Text("OK"))
                )
            }
            return Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// Network-related viewer failures get a help button; credential and storage
    /// issues do not, since a guide would not help there.
    private func connectionHelpURL(for issue: ViewerUserFacingIssue) -> URL? {
        let text = (issue.title + " " + issue.message).lowercased()
        if text.contains("tailscale") { return MacHelpLinks.tailscaleGuide }
        if text.contains("wi-fi") || text.contains("no video") || text.contains("connection") {
            return MacHelpLinks.connectionHelp
        }
        return nil
    }

    private var pendingManualPairingBinding: Binding<PendingManualPairingRequest?> {
        Binding(
            get: { model.pendingManualPairingRequest },
            set: { value in
                if value == nil, let request = model.pendingManualPairingRequest {
                    model.denyManualPairingRequest(request)
                }
            }
        )
    }

    private var topBar: some View {
        compactTopBar
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MacTopBarBackground())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(height: 1)
            }
    }

    private var compactTopBar: some View {
        ViewThatFits(in: .horizontal) {
            compactTopBarLayout(showViewerStats: true, showHostStats: true, showEscapeHint: true)
            compactTopBarLayout(showViewerStats: true, showHostStats: true, showEscapeHint: false)
            compactTopBarLayout(showViewerStats: false, showHostStats: false, showEscapeHint: false)
        }
    }

    private func compactTopBarLayout(showViewerStats: Bool, showHostStats: Bool, showEscapeHint: Bool) -> some View {
        HStack(spacing: 10) {
            viewerTopBarCluster(showStats: showViewerStats, showEscapeHint: showEscapeHint)

            Spacer(minLength: 36)

            hostTopBarSection(showStats: showHostStats)
                .frame(minWidth: 230, alignment: .trailing)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func viewerTopBarCluster(showStats: Bool, showEscapeHint: Bool) -> some View {
        HStack(spacing: 9) {
            viewerTopBarMachineSection
                .layoutPriority(4)

            MacViewerTopBarQualityMenu(model: model)
                .help("Stream Quality")
                .layoutPriority(3)

            compactTopBarActions
                .layoutPriority(3)

            if showStats {
                MacViewerTopBarDivider(horizontalPadding: 4)

                viewerTopBarStats(showEscapeHint: showEscapeHint)
                    .layoutPriority(-1)
                    .transition(.opacity)
            }
        }
    }

    private func hostTopBarSection(showStats: Bool) -> some View {
        HStack(spacing: 10) {
            if !model.connectedViewers.isEmpty {
                Button {
                    isControllerActionsPresented = true
                } label: {
                    Label(
                        model.connectedViewers.count == 1 ? model.connectedViewers[0].name : "\(model.connectedViewers.count) devices",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(MacViewerTopBarPillButtonStyle(isActive: true))
                .tint(.green)
                .help(model.activeControllerName.map { "\($0) currently has control." } ?? "Viewers connected. Any approved controller can take control by interacting.")
                .confirmationDialog(
                    "Manage Connected Devices",
                    isPresented: $isControllerActionsPresented,
                    titleVisibility: .visible
                ) {
                    ForEach(model.connectedViewers) { viewer in
                        Button("Disconnect \(viewer.name)") {
                            model.disconnectViewer(deviceID: viewer.id, revoke: false)
                        }
                    }

                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("A disconnected device is blocked until hosting restarts. You can revoke saved access in Trusted Devices.")
                }
            }

            if showStats {
                hostTopBarStats
                    .layoutPriority(-1)
                    .transition(.opacity)

                MacViewerTopBarDivider(horizontalPadding: 0)
            }

            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    isHostSidebarPresented.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    HostingLiveDot(isActive: model.isHosting, size: 7)
                    Text("Host")
                }
            }
            .buttonStyle(MacViewerTopBarPillButtonStyle(isActive: isHostSidebarPresented || model.isHosting))
            .help(model.isHosting ? model.hostStatus : "Open hosting controls")
            .anchorPreference(key: MacTutorialTargetPreferenceKey.self, value: .bounds) {
                [.host: $0]
            }
            .layoutPriority(4)
        }
    }

    private var viewerTopBarMachineSection: some View {
        MacViewerTopBarMachineInfo(
            name: viewerTopBarDisplayName,
            status: model.viewerStatus,
            isConnected: model.isViewing,
            usesAppIcon: !model.isViewing
        )
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func viewerTopBarStats(showEscapeHint: Bool) -> some View {
        HStack(spacing: 20) {
            MacViewerTopBarStatItem(
                systemImage: "video",
                value: model.viewerFPS > 0 ? "\(model.viewerFPS)" : "--",
                label: "fps"
            )

            MacViewerTopBarStatItem(
                systemImage: "wifi",
                value: model.isViewing ? String(format: "%.1f", model.viewerBitrateMbps) : "--",
                label: "Mbps"
            )

            if model.viewerMouseCaptured && showEscapeHint {
                Text("Press Esc to release mouse")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 138, alignment: .trailing)
        .animation(.easeInOut(duration: 0.18), value: model.viewerMouseCaptured)
    }

    private var hostTopBarStats: some View {
        HStack(spacing: 12) {
            MacViewerTopBarStatItem(
                systemImage: "video",
                value: model.hostFPS > 0 ? "\(model.hostFPS)" : "--",
                label: "fps"
            )
            MacViewerTopBarStatItem(
                systemImage: "wifi",
                value: model.hostBitrateMbps > 0 ? String(format: "%.1f", model.hostBitrateMbps) : "--",
                label: "Mbps"
            )
        }
    }

    @ViewBuilder
    private var compactTopBarActions: some View {
        HStack(spacing: 7) {
            Toggle(isOn: $model.viewerAudioEnabled) {
                Label(model.viewerAudioEnabled ? "Mute" : "Audio", systemImage: model.viewerAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .toggleStyle(.button)
            .buttonStyle(MacViewerTopBarPillButtonStyle(isActive: model.viewerAudioEnabled))
            .disabled(!model.viewerAllowsAudio)
            .disabled(!model.isViewing)
            .help(model.viewerAudioStatus)

            if model.isViewing {
                Button {
                    model.stopViewer()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .buttonStyle(MacViewerTopBarDisconnectButtonStyle())
                .help("Disconnect")
            }
        }
    }

    private var hostTopBarStatusText: String {
        if model.isHosting {
            return model.hostStatus.emptyDash
        }
        return hostSetupComplete ? "Stopped" : "Setup needed"
    }

    private var topBarIdentity: some View {
        HStack(spacing: 12) {
            Image(systemName: selectedMode.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(activeStatusColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(activeTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(activeSubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Circle()
                .fill(activeStatusColor.opacity(isActiveStatusDimmed ? 0.45 : 1))
                .frame(width: 9, height: 9)
        }
        .frame(minWidth: 230, alignment: .leading)
    }

    @ViewBuilder
    private var topBarPrimaryAction: some View {
        switch selectedMode {
        case .host:
            Button {
                model.isHostingRequested ? model.stopHost() : model.startHost()
            } label: {
                Label(model.isHostingRequested ? "Stop Hosting" : "Start Hosting", systemImage: model.isHostingRequested ? "stop.fill" : "play.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(MacTopBarPrimaryButtonStyle(tint: model.isHostingRequested ? .red : .blue))
            .disabled(!hostSetupComplete && !model.isHostingRequested)
            .help(hostSetupComplete ? "Start or stop hosting" : "Finish setup before hosting")

        case .viewer:
            if model.isViewing {
                Button {
                    model.stopViewer()
                } label: {
                    Label("Disconnect", systemImage: "stop.fill")
                        .frame(minWidth: 138)
                }
                .buttonStyle(MacTopBarPrimaryButtonStyle(tint: .red))
            } else {
                MacTopBarStatusPill(systemImage: "sidebar.left", title: "Choose a Mac", value: "Use sidebar", tint: .blue)
            }
        }
    }

    private var topBarPriorityStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                switch selectedMode {
                case .host:
                    MacTopBarStatusPill(systemImage: "power", title: "Status", value: model.hostStatus, tint: model.isHosting ? .green : .secondary)
                    if !hostSetupComplete {
                        MacTopBarStatusPill(systemImage: "checkmark.shield", title: "Setup", value: "Needs attention", tint: .orange)
                    }
                    MacTopBarStatusPill(systemImage: "point.3.connected.trianglepath.dotted", title: "Tailscale", value: model.tailscaleAddress, tint: model.tailscaleAddress == "Not detected" ? .secondary : .blue)
                    MacTopBarStatusPill(systemImage: "wifi", title: "Local", value: model.localAddress, tint: model.localAddress == "Not detected" ? .secondary : .mint)
                    if model.isHosting {
                        MacTopBarStatusPill(systemImage: "speedometer", title: "Video", value: "\(model.hostFPS) fps", tint: .green)
                        MacTopBarStatusPill(systemImage: "network", title: "Bitrate", value: String(format: "%.1f Mbps", model.hostBitrateMbps), tint: .mint)
                    }

                case .viewer:
                    MacTopBarStatusPill(systemImage: "display", title: "Status", value: model.viewerStatus, tint: model.isViewing ? .blue : .secondary)
                    MacTopBarStatusPill(systemImage: "location.fill", title: "Route", value: currentViewerRoute, tint: currentViewerRoute == "-" ? .secondary : .mint)
                    if model.isViewing {
                        MacTopBarStatusPill(systemImage: "speedometer", title: "Video", value: model.viewerFPS > 0 ? "\(model.viewerFPS) fps" : "Waiting", tint: model.viewerFPS > 0 ? .green : .orange)
                        MacTopBarStatusPill(systemImage: "network", title: "Bitrate", value: String(format: "%.1f Mbps", model.viewerBitrateMbps), tint: .mint)
                        viewerQuickControls
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 48)
    }

    private var viewerQuickControls: some View {
        HStack(spacing: 8) {
            Button {
                model.setViewerMouseCaptured(!model.viewerMouseCaptured)
            } label: {
                Label(model.viewerMouseCaptured ? "Release Mouse" : "Capture Mouse", systemImage: model.viewerMouseCaptured ? "cursorarrow.slash" : "cursorarrow.rays")
            }
            .buttonStyle(MacTopBarUtilityButtonStyle(isActive: model.viewerMouseCaptured))
            .disabled(!model.isViewing)
            .help(model.viewerMouseCaptured ? "Release mouse control" : "Capture mouse control")

            Toggle(isOn: $model.viewerAudioEnabled) {
                Label(model.viewerAudioEnabled ? "Audio On" : "Audio Off", systemImage: model.viewerAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .toggleStyle(.button)
            .buttonStyle(MacTopBarUtilityButtonStyle(isActive: model.viewerAudioEnabled))
            .disabled(!model.viewerAllowsAudio)
            .help(model.viewerAudioStatus)

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(MacTopBarUtilityButtonStyle())
            .help("Full Screen")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
    }

    private var hostSetupComplete: Bool {
        model.screenRecordingGranted &&
        (model.accessibilityGranted || !model.remoteInputEnabled)
    }

    private var activeTitle: String {
        switch selectedMode {
        case .host:
            return "Mac Hosting"
        case .viewer:
            return "Mac Viewer"
        }
    }

    private var activeSubtitle: String {
        switch selectedMode {
        case .host:
            return model.isHosting ? "Ready for iPhone" : (hostSetupComplete ? "Stopped" : "Setup needed")
        case .viewer:
            if model.isViewing { return currentViewerName }
            return model.viewerSavedComputers.isEmpty ? "Add a Mac to connect" : "Choose a saved Mac"
        }
    }

    private var activeStatusColor: Color {
        switch selectedMode {
        case .host:
            return model.isHosting ? .green : (hostSetupComplete ? .secondary : .orange)
        case .viewer:
            return model.isViewing ? .blue : .secondary
        }
    }

    private var isActiveStatusDimmed: Bool {
        switch selectedMode {
        case .host:
            return !model.isHosting && hostSetupComplete
        case .viewer:
            return !model.isViewing
        }
    }

    private var currentViewerName: String {
        guard let selectedID = model.selectedViewerSavedComputerID,
              let computer = model.viewerSavedComputers.first(where: { $0.id == selectedID }) else {
            return model.viewerHostAddress.emptyDash
        }
        return computer.name
    }

    private var viewerTopBarDisplayName: String {
        model.isViewing ? currentViewerName : "PocketCtrl"
    }

    private var currentViewerRoute: String {
        guard let selectedID = model.selectedViewerSavedComputerID,
              let computer = model.viewerSavedComputers.first(where: { $0.id == selectedID }) else {
            return model.viewerHostAddress.emptyDash
        }
        return computer.routeSummary.emptyDash
    }

    private var compactTopBarTitle: String {
        switch selectedMode {
        case .host:
            return "Mac Hosting"
        case .viewer:
            return currentViewerName
        }
    }

    private var compactTopBarSubtitle: String {
        switch selectedMode {
        case .host:
            return model.isHosting ? model.hostStatus : (hostSetupComplete ? "Stopped" : "Setup needed")
        case .viewer:
            return viewerTopBarRouteText
        }
    }

    private var compactTopBarStatus: String {
        switch selectedMode {
        case .host:
            return model.hostStatus
        case .viewer:
            return model.viewerStatus
        }
    }

    private var compactTopBarIsActive: Bool {
        switch selectedMode {
        case .host:
            return model.isHosting
        case .viewer:
            return model.isViewing
        }
    }

    private var compactTopBarFPSValue: String {
        switch selectedMode {
        case .host:
            return model.hostFPS > 0 ? "\(model.hostFPS)" : "--"
        case .viewer:
            return model.viewerFPS > 0 ? "\(model.viewerFPS)" : "--"
        }
    }

    private var compactTopBarBitrateValue: String {
        switch selectedMode {
        case .host:
            return model.hostBitrateMbps > 0 ? String(format: "%.1f", model.hostBitrateMbps) : "--"
        case .viewer:
            return model.isViewing ? String(format: "%.1f", model.viewerBitrateMbps) : "--"
        }
    }

    private var viewerTopBarRouteText: String {
        let route = currentViewerRoute.emptyDash
        if route != "-" { return route }
        return model.viewerSavedComputers.isEmpty ? "Add a Mac below" : "Choose a Mac below"
    }

    private var viewerTopBarSurfaceColor: Color {
        Color(red: 0.10, green: 0.10, blue: 0.18)
    }
}

struct HostMenuBarView: View {
    @ObservedObject var model: RemoteDesktopModel
    @Environment(\.openWindow) private var openWindow
    @State private var hostApplyTask: Task<Void, Never>?
    @State private var isManualDetailsVisible = false
    @State private var isHostingVisible = false
    @State private var isStreamVisible = false
    @State private var isNetworkVisible = false
    @State private var isDiagnosticsVisible = false

    private var setupComplete: Bool {
        model.screenRecordingGranted &&
        (model.accessibilityGranted || !model.remoteInputEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    actionSection
                    if setupComplete {
                        pairingSection
                    } else {
                        setupSection
                    }
                    hostingSettingsSection
                    streamSection
                    networkSection
                    diagnosticsSection
                    appSection
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .frame(width: 390, height: 660)
        }
        .hostControlsSurface()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .tint(.blue)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("PocketCtrl")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Text(model.isHosting ? "This Mac is hosting" : "Hosting is stopped")
                .font(.caption)
                .foregroundStyle(model.isHosting ? .green : .white.opacity(0.52))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.isHostingRequested ? model.stopHost() : model.startHost()
            } label: {
                Label(model.isHostingRequested ? "Stop Hosting" : "Start Hosting", systemImage: model.isHostingRequested ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HostSidebarPrimaryButtonStyle(tint: model.isHostingRequested ? .red : .blue))
            .disabled(!setupComplete && !model.isHostingRequested)

            if !setupComplete && !model.isHosting {
                Label("Finish setup before hosting.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if let warning = model.hostNetworkWarning {
                HostNetworkWarningBanner(message: warning, helpTitle: "Set up Tailscale", helpURL: MacHelpLinks.tailscaleGuide)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var setupSection: some View {
        MenuBarPanel(title: "Setup", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                if model.remoteInputEnabled {
                    PermissionRow(
                        title: "Accessibility",
                        granted: model.accessibilityGranted,
                        settingsHint: PermissionSetupText.accessibilityHint,
                        request: {
                            model.requestAccessibilityPermission()
                        },
                        openSettings: {
                            model.openAccessibilitySettings()
                        }
                    )
                }

                PermissionRow(
                    title: "Screen Recording",
                    granted: model.screenRecordingGranted,
                    settingsHint: PermissionSetupText.screenRecordingHint,
                    request: {
                        model.requestScreenRecordingPermission()
                    },
                    openSettings: {
                        model.openScreenRecordingSettings()
                    }
                )

            }
        }
    }

    private var pairingSection: some View {
        MenuBarPanel(title: "Pair", systemImage: "qrcode") {
            SecurePairingContent(model: model, qrSize: 150)
            manualDetails
        }
    }

    private var manualDetails: some View {
        VStack(alignment: .leading, spacing: isManualDetailsVisible ? 10 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isManualDetailsVisible.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label("Manual Details", systemImage: "info.circle")
                    Spacer()
                    Image(systemName: isManualDetailsVisible ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isManualDetailsVisible {
                VStack(spacing: 8) {
                    MenuBarValueRow(title: "Local Wi-Fi", value: model.localAddress, systemImage: "wifi") {
                        copyToPasteboard(model.localAddress)
                    }
                    MenuBarValueRow(title: "Tailscale", value: model.tailscaleAddress, systemImage: "point.3.connected.trianglepath.dotted") {
                        copyToPasteboard(model.tailscaleAddress)
                    }
                    MenuBarValueRow(title: "Mac ID", value: model.hostID, systemImage: "display") {
                        copyToPasteboard(model.hostID)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hostingSettingsSection: some View {
        HostSidebarDisclosurePanel(title: "Hosting", systemImage: "switch.2", isExpanded: $isHostingVisible) {
            HostReleaseSettingsSection(
                model: model,
                launchAtLoginEnabled: $model.launchAtLoginEnabled,
                autoStartHosting: $model.autoStartHosting,
                keepAwakeWhileHosting: $model.keepAwakeWhileHosting,
                remoteInputEnabled: $model.remoteInputEnabled,
                clipboardEnabled: liveHostBinding(\.hostClipboardEnabled),
                audioEnabled: liveHostBinding(\.hostAudioEnabled)
            )
        }
    }

    private var streamSection: some View {
        HostSidebarDisclosurePanel(title: "Stream", systemImage: "slider.horizontal.3", isExpanded: $isStreamVisible) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Display", selection: liveHostBinding(\.selectedDisplayID)) {
                    ForEach(model.displays) { display in
                        Text("\(display.name)  \(display.width)x\(display.height)").tag(display.id)
                    }
                }

                SliderRow(title: "Width", value: liveHostBinding(\.captureWidth), range: 960...3840, step: 160, suffix: "px")
                SliderRow(title: "FPS", value: liveHostBinding(\.fps), range: 24...60, step: 1, suffix: "")
                SliderRow(title: "Bitrate", value: liveHostBinding(\.bitrateMbps), range: 1...30, step: 1, suffix: "Mbps")

                Toggle("Adaptive bitrate", isOn: liveHostBinding(\.adaptiveBitrateEnabled))
                    .toggleStyle(.switch)
            }
        }
    }

    private var networkSection: some View {
        HostSidebarDisclosurePanel(title: "Network", systemImage: "network", isExpanded: $isNetworkVisible) {
            VStack(alignment: .leading, spacing: 12) {
                MenuBarValueRow(title: "Local Wi-Fi", value: model.localAddress, systemImage: "wifi") {
                    copyToPasteboard(model.localAddress)
                }
                MenuBarValueRow(title: "Tailscale", value: model.tailscaleAddress, systemImage: "point.3.connected.trianglepath.dotted") {
                    copyToPasteboard(model.tailscaleAddress)
                }

                Text(MacHelpLinks.sameNetworkHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.tailscaleAddress == "Not detected" {
                    MacHelpLinkButton(title: "Tailscale is off. Set it up for remote access", url: MacHelpLinks.tailscaleGuide)
                }

                HStack(spacing: 10) {
                    PortField(title: "Video", text: liveHostBinding(\.hostVideoPort))
                    PortField(title: "Audio", text: liveHostBinding(\.hostAudioPort))
                    PortField(title: "Input", text: liveHostBinding(\.hostInputPort))
                }

                Divider()
                    .overlay(.white.opacity(0.12))

                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Nearby Wi-Fi discovery", isOn: localDiscoveryBinding)
                        .toggleStyle(.switch)

                    Text(model.allowLocalDiscovery ? model.localDiscoveryStatus : "Off. Tailscale and manual pairing still work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var localDiscoveryBinding: Binding<Bool> {
        Binding(
            get: { model.allowLocalDiscovery },
            set: { enabled in
                if enabled {
                    model.requestLocalNetworkPermission()
                } else {
                    model.allowLocalDiscovery = false
                }
            }
        )
    }

    private var diagnosticsSection: some View {
        HostSidebarDisclosurePanel(title: "Diagnostics", systemImage: "wrench.and.screwdriver", isExpanded: $isDiagnosticsVisible) {
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(text: model.hostStatus, fps: model.hostFPS, bitrate: model.hostBitrateMbps)
                Text(model.localDiscoveryStatus)
                Text(model.hostActivityStatus)
                Text(model.hostInputStatus)
                Text(model.viewerFeedbackStatus)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var appSection: some View {
        HostSidebarStaticPanel(title: "App", systemImage: "macwindow") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        openMainWindow()
                    } label: {
                        Label("Open App", systemImage: "macwindow")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MacSecondaryButtonStyle())

                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MacSecondaryButtonStyle())
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await model.refreshSetupStatus()
                            model.refreshNetworkAddresses()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MacSecondaryButtonStyle())

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit", systemImage: "power")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MacSecondaryButtonStyle())
                }
            }
        }
    }

    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)

        if let existingWindow = NSApp.windows.first(where: { $0.canBecomeMain && $0.title == "PocketCtrl" }) {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        openWindow(id: "main")
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func liveHostBinding<Value>(_ keyPath: ReferenceWritableKeyPath<RemoteDesktopModel, Value>) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { newValue in
                model[keyPath: keyPath] = newValue
                scheduleHostingApply()
            }
        )
    }

    private func scheduleHostingApply() {
        guard model.isHosting else { return }
        hostApplyTask?.cancel()
        hostApplyTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                model.applyHostSettingsIfRunning()
            }
        }
    }
}

struct MenuBarPanel<Content: View>: View {
    let title: String?
    let systemImage: String?
    private let content: Content

    init(title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title, let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .textCase(.uppercase)
            }

            VStack(spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuBarValueRow: View {
    let title: String
    let value: String
    let systemImage: String
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)

            Button {
                copy()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(title)")
        }
    }
}

struct HostReleaseSettingsSection: View {
    @ObservedObject var model: RemoteDesktopModel
    @Binding var launchAtLoginEnabled: Bool
    @Binding var autoStartHosting: Bool
    @Binding var keepAwakeWhileHosting: Bool
    @Binding var remoteInputEnabled: Bool
    @Binding var clipboardEnabled: Bool
    @Binding var audioEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HostSettingsInfoRow(
                title: "Pairing required",
                subtitle: "New viewers need this Mac's QR code or pairing link.",
                systemImage: "key.fill",
                tint: .green
            )

            MacSettingsToggleRow(
                title: "Allow keyboard and mouse",
                subtitle: remoteInputEnabled ? "Viewers can control this Mac." : "Screen sharing only.",
                systemImage: "cursorarrow",
                isOn: $remoteInputEnabled
            )

            MacSettingsToggleRow(
                title: "Clipboard sync",
                subtitle: clipboardEnabled ? "Allow text copy and paste with paired viewers." : "Do not share clipboard text.",
                systemImage: "clipboard",
                isOn: $clipboardEnabled
            )

            MacSettingsToggleRow(
                title: "Stream Mac audio",
                subtitle: audioEnabled ? "Send this Mac's audio with the screen." : "Video only.",
                systemImage: audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                isOn: $audioEnabled
            )

            Divider()
                .overlay(.white.opacity(0.12))

            MacSettingsToggleRow(
                title: "Launch at login",
                subtitle: model.launchAtLoginStatus,
                systemImage: "power",
                isOn: $launchAtLoginEnabled
            )

            MacSettingsToggleRow(
                title: "Start hosting when opened",
                subtitle: autoStartHosting ? "Hosting starts whenever PocketCtrl opens." : "PocketCtrl opens without hosting.",
                systemImage: "play.circle.fill",
                isOn: $autoStartHosting
            )

            MacSettingsToggleRow(
                title: "Keep Mac awake while hosting",
                subtitle: sleepPreventionSubtitle,
                systemImage: model.isSleepPreventionActive ? "checkmark.circle.fill" : "moon.zzz.fill",
                isOn: $keepAwakeWhileHosting
            )
        }
    }

    private var sleepPreventionSubtitle: String {
        guard keepAwakeWhileHosting else {
            return "Allow normal sleep behavior."
        }
        if model.isSleepPreventionActive {
            return "Active. The display can still turn off."
        }
        if model.isHostingRequested {
            return "Activating sleep prevention..."
        }
        return "Activates when hosting starts."
    }
}

struct HostSettingsInfoRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
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
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}

struct HostSidebarView: View {
    @ObservedObject var model: RemoteDesktopModel
    @Binding var isPresented: Bool
    @State private var hostApplyTask: Task<Void, Never>?
    @State private var isManualDetailsVisible = false
    @State private var isHostingVisible = false
    @State private var isStreamVisible = false
    @State private var isNetworkVisible = false
    @State private var isDiagnosticsVisible = false

    private var setupComplete: Bool {
        model.screenRecordingGranted &&
        (model.accessibilityGranted || !model.remoteInputEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    controlSection

                    if setupComplete {
                        pairingSection
                    } else {
                        setupSection
                    }

                    hostingSettingsSection
                    streamSection
                    networkSection
                    diagnosticsSection
                    appSection
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .hostControlsSurface()
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 24, x: -10, y: 0)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Host")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.62))
            .background(.white.opacity(0.07), in: Circle())
            .help("Close hosting sidebar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.isHostingRequested ? model.stopHost() : model.startHost()
            } label: {
                Label(model.isHostingRequested ? "Stop Hosting" : "Start Hosting", systemImage: model.isHostingRequested ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HostSidebarPrimaryButtonStyle(tint: model.isHostingRequested ? .red : .blue))
            .disabled(!setupComplete && !model.isHostingRequested)

            if !setupComplete && !model.isHosting {
                Label("Finish setup before hosting.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if let warning = model.hostNetworkWarning {
                HostNetworkWarningBanner(message: warning, helpTitle: "Set up Tailscale", helpURL: MacHelpLinks.tailscaleGuide)
            }
        }
    }

    private var setupSection: some View {
        MenuBarPanel(title: "Setup", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                if model.remoteInputEnabled {
                    PermissionRow(
                        title: "Accessibility",
                        granted: model.accessibilityGranted,
                        settingsHint: PermissionSetupText.accessibilityHint,
                        request: { model.requestAccessibilityPermission() },
                        openSettings: { model.openAccessibilitySettings() }
                    )
                }

                PermissionRow(
                    title: "Screen Recording",
                    granted: model.screenRecordingGranted,
                    settingsHint: PermissionSetupText.screenRecordingHint,
                    request: { model.requestScreenRecordingPermission() },
                    openSettings: { model.openScreenRecordingSettings() }
                )

                Button {
                    Task {
                        await model.refreshSetupStatus()
                    }
                } label: {
                    Label("Recheck Setup", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle())
            }
        }
    }

    private var pairingSection: some View {
        MenuBarPanel(title: "Pair", systemImage: "qrcode") {
            SecurePairingContent(model: model, qrSize: 172)
            manualDetails
        }
    }

    private var manualDetails: some View {
        VStack(alignment: .leading, spacing: isManualDetailsVisible ? 10 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isManualDetailsVisible.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label("Manual Details", systemImage: "info.circle")
                    Spacer()
                    Image(systemName: isManualDetailsVisible ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isManualDetailsVisible {
                VStack(spacing: 8) {
                    MenuBarValueRow(title: "Local Wi-Fi", value: model.localAddress, systemImage: "wifi") {
                        copyToPasteboard(model.localAddress)
                    }
                    MenuBarValueRow(title: "Tailscale", value: model.tailscaleAddress, systemImage: "point.3.connected.trianglepath.dotted") {
                        copyToPasteboard(model.tailscaleAddress)
                    }
                    MenuBarValueRow(title: "Mac ID", value: model.hostID, systemImage: "display") {
                        copyToPasteboard(model.hostID)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hostingSettingsSection: some View {
        HostSidebarDisclosurePanel(title: "Hosting", systemImage: "switch.2", isExpanded: $isHostingVisible) {
            HostReleaseSettingsSection(
                model: model,
                launchAtLoginEnabled: $model.launchAtLoginEnabled,
                autoStartHosting: $model.autoStartHosting,
                keepAwakeWhileHosting: $model.keepAwakeWhileHosting,
                remoteInputEnabled: $model.remoteInputEnabled,
                clipboardEnabled: liveHostBinding(\.hostClipboardEnabled),
                audioEnabled: liveHostBinding(\.hostAudioEnabled)
            )
        }
    }

    private var streamSection: some View {
        HostSidebarDisclosurePanel(title: "Stream", systemImage: "slider.horizontal.3", isExpanded: $isStreamVisible) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    HostingLiveDot(isActive: model.isHosting, size: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isHosting ? "Streaming" : "Stream")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.84))

                        Text(model.isHosting ? model.hostStatus : (setupComplete ? "Ready to start" : "Setup needed"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Picker("Display", selection: liveHostBinding(\.selectedDisplayID)) {
                    ForEach(model.displays) { display in
                        Text("\(display.name)  \(display.width)x\(display.height)").tag(display.id)
                    }
                }

                SliderRow(title: "Width", value: liveHostBinding(\.captureWidth), range: 960...3840, step: 160, suffix: "px")
                SliderRow(title: "FPS", value: liveHostBinding(\.fps), range: 24...60, step: 1, suffix: "")
                SliderRow(title: "Bitrate", value: liveHostBinding(\.bitrateMbps), range: 1...30, step: 1, suffix: "Mbps")

                Toggle("Adaptive bitrate", isOn: liveHostBinding(\.adaptiveBitrateEnabled))
                    .toggleStyle(.switch)
            }
        }
    }

    private var networkSection: some View {
        HostSidebarDisclosurePanel(title: "Network", systemImage: "network", isExpanded: $isNetworkVisible) {
            VStack(alignment: .leading, spacing: 12) {
                MenuBarValueRow(title: "Local Wi-Fi", value: model.localAddress, systemImage: "wifi") {
                    copyToPasteboard(model.localAddress)
                }
                MenuBarValueRow(title: "Tailscale", value: model.tailscaleAddress, systemImage: "point.3.connected.trianglepath.dotted") {
                    copyToPasteboard(model.tailscaleAddress)
                }

                LabeledContent("Viewer IP") {
                    TextField("192.0.2.10", text: liveHostBinding(\.hostDestinationAddress))
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    PortField(title: "Video", text: liveHostBinding(\.hostVideoPort))
                    PortField(title: "Audio", text: liveHostBinding(\.hostAudioPort))
                    PortField(title: "Input", text: liveHostBinding(\.hostInputPort))
                }

                Divider()
                    .overlay(.white.opacity(0.12))

                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Nearby Wi-Fi discovery", isOn: localDiscoveryBinding)
                        .toggleStyle(.switch)

                    Text(model.allowLocalDiscovery ? model.localDiscoveryStatus : "Off. Tailscale and manual pairing still work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var localDiscoveryBinding: Binding<Bool> {
        Binding(
            get: { model.allowLocalDiscovery },
            set: { enabled in
                if enabled {
                    model.requestLocalNetworkPermission()
                } else {
                    model.allowLocalDiscovery = false
                }
            }
        )
    }

    private var diagnosticsSection: some View {
        HostSidebarDisclosurePanel(title: "Diagnostics", systemImage: "wrench.and.screwdriver", isExpanded: $isDiagnosticsVisible) {
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(text: model.hostStatus, fps: model.hostFPS, bitrate: model.hostBitrateMbps)
                Text(model.localDiscoveryStatus)
                Text(model.hostActivityStatus)
                Text(model.hostInputStatus)
                Text(model.viewerFeedbackStatus)

                Button {
                    Task {
                        await model.refreshSetupStatus()
                        model.refreshNetworkAddresses()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle())
                .padding(.top, 4)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var appSection: some View {
        HostSidebarStaticPanel(title: "App", systemImage: "macwindow") {
            HStack(spacing: 10) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle())

                Button {
                    Task {
                        await model.refreshSetupStatus()
                        model.refreshNetworkAddresses()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacSecondaryButtonStyle())

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(MacSecondaryButtonStyle())
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func liveHostBinding<Value>(_ keyPath: ReferenceWritableKeyPath<RemoteDesktopModel, Value>) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { newValue in
                model[keyPath: keyPath] = newValue
                scheduleHostingApply()
            }
        )
    }

    private func scheduleHostingApply() {
        guard model.isHosting else { return }
        hostApplyTask?.cancel()
        hostApplyTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                model.applyHostSettingsIfRunning()
            }
        }
    }
}

struct HostSidebarDisclosurePanel<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    private let content: Content

    init(title: String, systemImage: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Label(title, systemImage: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .textCase(.uppercase)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 10) {
                    content
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

struct HostSidebarStaticPanel<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            VStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

struct HostingLiveDot: View {
    let isActive: Bool
    var size: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.55)) { timeline in
            let pulse = isActive ? (0.48 + 0.52 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 3.2))) : 0

            Circle()
                .fill(isActive ? Color.red : Color.white.opacity(0.34))
                .frame(width: size, height: size)
                .overlay {
                    if isActive {
                        Circle()
                            .stroke(Color.red.opacity(0.28 + 0.36 * pulse), lineWidth: 2)
                            .frame(width: size + 8 + (pulse * 5), height: size + 8 + (pulse * 5))
                    }
                }
                .shadow(color: isActive ? Color.red.opacity(0.52) : .clear, radius: isActive ? 7 : 0)
        }
        .frame(width: size + 14, height: size + 14)
    }
}

struct HostSidebarPrimaryButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.98 : 0.48))
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                LinearGradient(
                    colors: [
                        tint.opacity(isEnabled ? (configuration.isPressed ? 0.72 : 0.96) : 0.28),
                        tint.opacity(isEnabled ? (configuration.isPressed ? 0.58 : 0.78) : 0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1))
            .shadow(color: tint.opacity(isEnabled ? 0.28 : 0), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

private struct HostControlsSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Color(red: 0.045, green: 0.048, blue: 0.075)
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.07, blue: 0.13).opacity(0.44),
                            Color(red: 0.035, green: 0.04, blue: 0.065).opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .ignoresSafeArea()
            }
    }
}

private extension View {
    func hostControlsSurface() -> some View {
        modifier(HostControlsSurfaceModifier())
    }
}

enum MacWorkspaceMode: String, CaseIterable, Identifiable {
    case host
    case viewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host: return "Host"
        case .viewer: return "Viewer"
        }
    }

    var systemImage: String {
        switch self {
        case .host: return "display.and.arrow.down"
        case .viewer: return "rectangle.inset.filled.and.person.filled"
        }
    }
}

struct MacTopBarStatusPill: View {
    let systemImage: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.07), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.46))
                    .textCase(.uppercase)
                Text(value.emptyDash)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

struct MacTopBarPrimaryButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.48))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .background(tint.opacity(isEnabled ? (configuration.isPressed ? 0.58 : 0.78) : 0.20), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

struct MacTopBarUtilityButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.90 : 0.42))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .background(fill(configuration: configuration), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isEnabled ? 0.16 : 0.07), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private func fill(configuration: Configuration) -> Color {
        if isActive {
            return Color.blue.opacity(isEnabled ? (configuration.isPressed ? 0.48 : 0.68) : 0.20)
        }
        return Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.13 : 0.075) : 0.04)
    }
}

struct MacViewerTopBarMachineInfo: View {
    let name: String
    let status: String
    let isConnected: Bool
    var systemImage = "desktopcomputer"
    var usesAppIcon = false

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name.emptyDash)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)

                    Circle()
                        .fill(isConnected ? Color.green : Color.red.opacity(0.70))
                        .frame(width: 6, height: 6)
                        .help(status)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if usesAppIcon {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
        }
    }
}

struct MacViewerTopBarStatItem: View {
    let systemImage: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.30))
                .frame(width: 14)

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()

                Text(label)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

struct MacViewerTopBarDivider: View {
    var horizontalPadding: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 18)
            .padding(.horizontal, horizontalPadding)
    }
}

struct MacTopBarBackground: View {
    var body: some View {
        ZStack {
            Color.black

            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.018, blue: 0.026),
                    Color(red: 0.025, green: 0.022, blue: 0.042),
                    Color(red: 0.010, green: 0.012, blue: 0.020)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.05, blue: 0.20).opacity(0.18),
                    .clear,
                    Color(red: 0.03, green: 0.08, blue: 0.18).opacity(0.16)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

struct MacViewerTopBarModeToggle: View {
    @Binding var selection: MacWorkspaceMode
    @Namespace private var selectedBackground

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MacWorkspaceMode.allCases) { mode in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selection = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 12, weight: selection == mode ? .medium : .regular))
                        .foregroundStyle(.white.opacity(selection == mode ? 0.90 : 0.45))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if selection == mode {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "selectedMode", in: selectedBackground)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 4)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.snappy(duration: 0.22), value: selection)
    }
}


struct MacViewerTopBarPillButtonStyle: ButtonStyle {
    var isActive = false
    var tint = Color(red: 0.36, green: 0.34, blue: 0.97)
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(isEnabled ? (isActive ? 0.94 : 0.74) : 0.34))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill(configuration: configuration), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(stroke, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private func fill(configuration: Configuration) -> Color {
        if isActive {
            return tint.opacity(isEnabled ? (configuration.isPressed ? 0.30 : 0.24) : 0.08)
        }
        return Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.12 : 0.070) : 0.030)
    }

    private var stroke: Color {
        if isActive {
            return tint.opacity(isEnabled ? 0.28 : 0.08)
        }
        return Color.white.opacity(isEnabled ? 0.10 : 0.04)
    }
}

struct MacViewerTopBarDisconnectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(red: 1.00, green: 0.70, blue: 0.70))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(red: 0.86, green: 0.24, blue: 0.24).opacity(configuration.isPressed ? 0.36 : 0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.red.opacity(0.16), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

struct HostWorkspaceView: View {
    @ObservedObject var model: RemoteDesktopModel
    @State private var isAdvancedVisible = false
    @State private var isManualDetailsVisible = false

    private var setupComplete: Bool {
        model.screenRecordingGranted &&
        (model.accessibilityGranted || !model.remoteInputEnabled)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    hostActionPanel
                    advancedPanel
                }
                .padding(18)
            }
            .frame(width: 320)
            .background(.black.opacity(0.26))
            .background(.ultraThinMaterial)

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)

            hostPairingPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var hostActionPanel: some View {
        CleanPanel {
            VStack(alignment: .leading, spacing: 14) {
                Label(model.isHosting ? "Hosting" : "Stopped", systemImage: model.isHosting ? "dot.radiowaves.left.and.right" : "power")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(model.isHosting ? .green : .white.opacity(0.88))

                Button {
                    model.isHostingRequested ? model.stopHost() : model.startHost()
                } label: {
                    Label(model.isHostingRequested ? "Stop Hosting" : "Start Hosting", systemImage: model.isHostingRequested ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacGradientButtonStyle())
                .controlSize(.large)
                .disabled(!setupComplete && !model.isHostingRequested)

                Text(model.hostStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let warning = model.hostNetworkWarning {
                    HostNetworkWarningBanner(message: warning, helpTitle: "Set up Tailscale", helpURL: MacHelpLinks.tailscaleGuide)
                }
            }
        }
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: isAdvancedVisible ? 16 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isAdvancedVisible.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Advanced")
                        .font(.headline)
                    Spacer()
                    Image(systemName: isAdvancedVisible ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            if isAdvancedVisible {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Startup")
                            .font(.subheadline.weight(.semibold))

                        Toggle(isOn: $model.launchAtLoginEnabled) {
                            Text("Launch at login")
                        }
                        .toggleStyle(.switch)

                        Text(model.launchAtLoginStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle(isOn: $model.autoStartHosting) {
                            Text("Start hosting when opened")
                        }
                        .toggleStyle(.switch)

                        Text(model.autoStartHosting ? "Hosting starts whenever PocketCtrl opens." : "PocketCtrl opens without hosting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle(isOn: $model.keepAwakeWhileHosting) {
                            Text("Keep Mac awake while hosting")
                        }
                        .toggleStyle(.switch)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Security")
                            .font(.subheadline.weight(.semibold))

                        Toggle(isOn: $model.remoteInputEnabled) {
                            Text("Allow remote keyboard and mouse")
                        }
                        .toggleStyle(.switch)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Stream")
                            .font(.subheadline.weight(.semibold))

                        Picker("Display", selection: $model.selectedDisplayID) {
                            ForEach(model.displays) { display in
                                Text("\(display.name)  \(display.width)x\(display.height)").tag(display.id)
                            }
                        }

                        SliderRow(title: "Width", value: $model.captureWidth, range: 960...3840, step: 160, suffix: "px")
                        SliderRow(title: "FPS", value: $model.fps, range: 24...60, step: 1, suffix: "")
                        SliderRow(title: "Bitrate", value: $model.bitrateMbps, range: 1...30, step: 1, suffix: "Mbps")

                        Toggle(isOn: $model.adaptiveBitrateEnabled) {
                            Text("Adaptive bitrate")
                        }
                        .toggleStyle(.switch)

                        Toggle(isOn: $model.hostAudioEnabled) {
                            Text("Stream Mac audio")
                        }
                        .toggleStyle(.switch)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Network")
                            .font(.subheadline.weight(.semibold))

                        Toggle(isOn: localDiscoveryBinding) {
                            Text("Nearby Wi-Fi discovery")
                        }
                        .toggleStyle(.switch)

                        LabeledContent("Viewer IP") {
                            TextField("192.0.2.10", text: $model.hostDestinationAddress)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 10) {
                            PortField(title: "Video", text: $model.hostVideoPort)
                            PortField(title: "Audio", text: $model.hostAudioPort)
                            PortField(title: "Input", text: $model.hostInputPort)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Activity")
                            .font(.subheadline.weight(.semibold))
                        StatusRow(text: model.hostStatus, fps: model.hostFPS, bitrate: model.hostBitrateMbps)
                        Text(model.localDiscoveryStatus)
                        Text(model.hostActivityStatus)
                        Text(model.hostInputStatus)
                        Text(model.viewerFeedbackStatus)
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button {
                        Task {
                            await model.refreshSetupStatus()
                            model.refreshNetworkAddresses()
                        }
                    } label: {
                        Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(MacSecondaryButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 20, opacity: 0.065)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var hostPairingPane: some View {
        ZStack {
            VStack(spacing: 18) {
                Spacer(minLength: 20)

                if setupComplete {
                    hostPairingContent
                } else {
                    hostSetupContent
                }

                if setupComplete {
                    HostStatsStrip(model: model)
                }

                Spacer(minLength: 20)
            }
            .padding(42)
        }
    }

    private var hostPairingContent: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: model.isHosting ? "dot.radiowaves.left.and.right" : "display.and.arrow.down")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(model.isHosting ? .green : .white.opacity(0.58))

                HStack(spacing: 7) {
                    Text(model.isHosting ? "Ready to Pair" : "Stopped")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    MacPairingInfoButton(
                        title: "Pairing",
                        message: PairingHelpText.hostPairing
                    )
                }

                Text("Pair once. PocketCtrl prefers local Wi-Fi and uses Tailscale when needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("The other device must be on the same Wi-Fi network as this Mac, or both devices need Tailscale turned on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                MacHelpLinkButton(title: "Tailscale setup guide", url: MacHelpLinks.tailscaleGuide)
            }

            if let warning = model.hostNetworkWarning {
                HostNetworkWarningBanner(message: warning, helpTitle: "Set up Tailscale", helpURL: MacHelpLinks.tailscaleGuide)
            }

            SecurePairingContent(model: model, qrSize: 248)
            manualDetails
        }
        .padding(28)
        .frame(width: 520)
        .glassPanel(cornerRadius: 30, opacity: 0.075)
    }

    private var hostSetupContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Finish Mac Setup")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Complete these once so your iPhone can view and control this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(hostOnboardingItems) { item in
                        HostOnboardingStepRow(item: item)
                    }

                    Button {
                        Task {
                            await model.refreshSetupStatus()
                        }
                    } label: {
                        Label("Recheck Setup", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MacSecondaryButtonStyle())
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .frame(width: 520)
            .frame(maxHeight: 430)
        }
        .padding(28)
        .glassPanel(cornerRadius: 30, opacity: 0.055)
    }

    private var localDiscoveryBinding: Binding<Bool> {
        Binding(
            get: { model.allowLocalDiscovery },
            set: { enabled in
                if enabled {
                    model.requestLocalNetworkPermission()
                } else {
                    model.allowLocalDiscovery = false
                }
            }
        )
    }

    private var hostOnboardingItems: [HostOnboardingItem] {
        var items: [HostOnboardingItem] = []

        if model.remoteInputEnabled {
            items.append(HostOnboardingItem(
                title: "Accessibility",
                badge: "Required",
                systemImage: "cursorarrow.motionlines",
                isComplete: model.accessibilityGranted,
                explanation: PermissionSetupText.accessibilityExplanation,
                detail: model.accessibilityStatus,
                actionTitle: "Allow Accessibility",
                action: {
                    model.requestAccessibilityPermission()
                },
                settingsTitle: "Open Settings",
                settingsAction: {
                    model.openAccessibilitySettings()
                }
            ))
        }

        items.append(HostOnboardingItem(
            title: "Screen Recording",
            badge: "Required",
            systemImage: "rectangle.dashed",
            isComplete: model.screenRecordingGranted,
            explanation: PermissionSetupText.screenRecordingExplanation,
            detail: model.screenRecordingStatus,
            actionTitle: "Allow Screen Recording",
            action: {
                model.requestScreenRecordingPermission()
            },
            settingsTitle: "Open Settings",
            settingsAction: {
                model.openScreenRecordingSettings()
            }
        ))

        items.append(HostOnboardingItem(
            title: "Launch at Login",
            badge: "Recommended",
            systemImage: "power.circle",
            isComplete: model.launchAtLoginEnabled,
            explanation: "Opens PocketCtrl automatically after you sign in. Enable hosting on open too for unattended access.",
            detail: model.launchAtLoginStatus,
            actionTitle: "Enable Both",
            action: {
                model.enableLaunchAtLoginAndAutoStart()
            },
            settingsTitle: nil,
            settingsAction: nil
        ))

        return items
    }

    private var manualDetails: some View {
        VStack(alignment: .leading, spacing: isManualDetailsVisible ? 12 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isManualDetailsVisible.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Label("Manual Details", systemImage: "info.circle")
                        .font(.headline)
                    Spacer()
                    Image(systemName: isManualDetailsVisible ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            if isManualDetailsVisible {
            VStack(spacing: 10) {
                ManualDetailRow(title: "Tailscale IP", value: model.tailscaleAddress, systemImage: "network") {
                    copyToPasteboard(model.tailscaleAddress)
                }

                ManualDetailRow(title: "Local Wi-Fi IP", value: model.localAddress, systemImage: "wifi") {
                    copyToPasteboard(model.localAddress)
                }

                ManualDetailRow(title: "Mac ID", value: model.hostID, systemImage: "display") {
                    copyToPasteboard(model.hostID)
                }

            }
            .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 420)
        .padding(16)
        .glassPanel(cornerRadius: 18, opacity: 0.065)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct ViewerWorkspaceView: View {
    @ObservedObject var model: RemoteDesktopModel
    @State private var isAdvancedVisible = false
    @State private var isAdvancedConnectionVisible = false
    @State private var pastedPairingPayload = ""
    @State private var computerPairingCode = ""
    @State private var pairingMessage: String?
    @State private var hasSubmittedComputerPairingCode = false
    @State private var isOtherPairingOptionsVisible = false
    @State private var renameSavedComputerID: String?
    @State private var renameSavedComputerDraft = ""
    @State private var isAddMacSheetPresented = false
    @State private var isComputerPairingCodeFocused = false
    @State private var computerPairingCodeFocusRequest = 0

    var body: some View {
        ZStack {
            if model.isViewing {
                viewerCanvas
            } else {
                connectPane
            }
        }
        .onAppear {
            model.retryPreviousViewerConnectionIfNeeded()
        }
        .sheet(isPresented: renameSavedComputerSheetBinding) {
            renameSavedComputerSheet
        }
        .sheet(isPresented: $isAddMacSheetPresented) {
            addNewMacSheet
        }
    }

    private var viewerCanvas: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            ZStack {
                RemoteVideoView(model: model)
                RemoteInputOverlay(model: model)
            }
            .aspectRatio(model.remoteVideoSize.width / max(model.remoteVideoSize.height, 1), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var connectPane: some View {
        ZStack {
            MacViewerHomeBackground()

            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 22) {
                        Text("Connect to Your Mac")
                            .font(.system(size: proxy.size.width > 900 ? 42 : 34, weight: .regular, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        if !model.viewerSavedComputers.isEmpty {
                            VStack(spacing: 12) {
                                ForEach(model.viewerSavedComputers) { computer in
                                    MacViewerHomeSavedComputerRow(
                                        computer: computer,
                                        onConnect: {
                                            model.connectToViewerSavedComputer(computer)
                                        },
                                        onRename: {
                                            beginRenameSavedComputer(computer)
                                        },
                                        onRemove: {
                                            model.removeViewerSavedComputer(id: computer.id)
                                        }
                                    )
                                }
                            }
                            .padding(10)
                            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                            .shadow(color: .black.opacity(0.22), radius: 18, y: 12)
                        }

                        Button {
                            NotificationCenter.default.post(name: .pocketCtrlShowHostingControls, object: nil)
                        } label: {
                            Label("Start hosting on this device", systemImage: "dot.radiowaves.left.and.right")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MacViewerHomeConnectButtonStyle())
                        .help("Open the hosting controls for this Mac")

                        Button {
                            isAddMacSheetPresented = true
                        } label: {
                            Label("Connect a new Mac", systemImage: "keyboard")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MacViewerHomeConnectButtonStyle())
                        .anchorPreference(key: MacTutorialTargetPreferenceKey.self, value: .bounds) {
                            [.connect: $0]
                        }

                        Text(viewerDisconnectedStatusText)
                            .font(.title3.weight(.regular))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        MacHelpLinkButton(
                            title: viewerDisconnectedStatusText.localizedCaseInsensitiveContains("tailscale") ? "Tailscale setup guide" : "Need help connecting?",
                            url: viewerDisconnectedStatusText.localizedCaseInsensitiveContains("tailscale") ? MacHelpLinks.tailscaleGuide : MacHelpLinks.connectionHelp
                        )
                    }
                    .padding(.horizontal, 42)
                    .padding(.vertical, 52)
                    .frame(maxWidth: 640)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var viewerDisconnectedStatusText: String {
        let status = model.viewerStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty || status == "Viewer idle" ? "Disconnected" : status
    }

    private func applyPastedPairingPayload() {
        let payload = pastedPairingPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.connectToViewerPairingPayload(payload) {
            pairingMessage = nil
            pastedPairingPayload = ""
            isAddMacSheetPresented = false
        } else {
            pairingMessage = "That pairing link was not recognized."
        }
    }

    private func importPairingQRCodeImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a screenshot or image containing the Mac pairing QR code."

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let image = CIImage(contentsOf: url) else {
                pairingMessage = "Could not read that image."
                return
            }

            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
            let codes = detector?
                .features(in: image)
                .compactMap { feature -> String? in
                    guard let message = (feature as? CIQRCodeFeature)?.messageString else { return nil }
                    return message.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty } ?? []

            guard let code = codes.first else {
                pairingMessage = "No QR code found in that image."
                return
            }

            if model.connectToViewerPairingPayload(code) {
                pairingMessage = nil
                pastedPairingPayload = ""
                isAddMacSheetPresented = false
            } else {
                pairingMessage = "That QR code was not a PocketCtrl pairing code."
            }
        }
    }

    private var renameSavedComputerSheetBinding: Binding<Bool> {
        Binding(
            get: { renameSavedComputerID != nil },
            set: { isPresented in
                if !isPresented {
                    renameSavedComputerID = nil
                    renameSavedComputerDraft = ""
                }
            }
        )
    }

    private var renameSavedComputerSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Rename Mac", systemImage: "pencil")
                .font(.title3.weight(.semibold))

            TextField("Mac name", text: $renameSavedComputerDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()

                Button("Cancel") {
                    renameSavedComputerID = nil
                    renameSavedComputerDraft = ""
                }

                Button("Save") {
                    if let renameSavedComputerID {
                        model.renameViewerSavedComputer(id: renameSavedComputerID, to: renameSavedComputerDraft)
                    }
                    renameSavedComputerID = nil
                    renameSavedComputerDraft = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameSavedComputerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }

    private var addNewMacSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add a Mac")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))

                    Text(
                        isOtherPairingOptionsVisible
                            ? "Use a pairing link or QR screenshot."
                            : "Enter the 12-character code shown on the other Mac."
                    )
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.52))
                }

                Spacer(minLength: 12)

                Button {
                    isAddMacSheetPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.055), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }

            if isOtherPairingOptionsVisible {
                pairingModeButton(
                    title: "Computer Code",
                    systemImage: "chevron.left",
                    action: showComputerCodePairing
                )

                otherPairingOptions
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                computerCodePairingOptions
                    .transition(.opacity.combined(with: .move(edge: .leading)))

                pairingModeButton(
                    title: "Use QR or pairing link",
                    systemImage: "qrcode",
                    showsForwardIndicator: true,
                    action: showOtherPairingOptions
                )
            }
        }
        .padding(24)
        .frame(width: 500)
        .background { MacViewerHomeBackground() }
        .preferredColorScheme(.dark)
        .onAppear {
            computerPairingCode = ""
            pairingMessage = nil
            hasSubmittedComputerPairingCode = false
            isOtherPairingOptionsVisible = false
            requestComputerCodeFocus(after: 0.12)
        }
        .onDisappear {
            isComputerPairingCodeFocused = false
        }
        .onReceive(model.$isViewing) { isViewing in
            if isViewing {
                isAddMacSheetPresented = false
            }
        }
    }

    private var computerCodePairingOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Computer Code")
                    .font(.callout.weight(.semibold))

                MacPairingInfoButton(
                    title: "Computer Code",
                    message: PairingHelpText.computerCode,
                    compact: true
                )

                Spacer(minLength: 0)
            }

            MacManualPairingCodeEntry(
                code: $computerPairingCode,
                isFocused: $isComputerPairingCodeFocused,
                focusRequestID: computerPairingCodeFocusRequest
            )
                .onChange(of: computerPairingCode) { _, _ in
                    hasSubmittedComputerPairingCode = false
                }

            Button {
                hasSubmittedComputerPairingCode = true
                model.connectToViewerManualPairingCode(computerPairingCode)
            } label: {
                Label("Send Pairing Request", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MacAddDevicePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(PairingInvitationCode.normalized(computerPairingCode).count != PairingInvitationCode.encodedCharacterCount)

            if hasSubmittedComputerPairingCode {
                Text(model.manualPairingStatus)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private func pairingModeButton(
        title: String,
        systemImage: String,
        showsForwardIndicator: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.callout.weight(.semibold))

                Spacer()

                if showsForwardIndicator {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func showOtherPairingOptions() {
        isComputerPairingCodeFocused = false
        withAnimation(.snappy(duration: 0.18)) {
            isOtherPairingOptionsVisible = true
        }
    }

    private func showComputerCodePairing() {
        withAnimation(.snappy(duration: 0.18)) {
            isOtherPairingOptionsVisible = false
        }
        requestComputerCodeFocus(after: 0.2)
    }

    private func requestComputerCodeFocus(after delay: TimeInterval = 0) {
        // AppKit can leave the mode-switch button as first responder after the
        // code field is recreated. Issue a new responder request once it exists.
        isComputerPairingCodeFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isAddMacSheetPresented, !isOtherPairingOptionsVisible else { return }
            computerPairingCodeFocusRequest &+= 1
        }
    }

    private var otherPairingOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Button {
                    importPairingQRCodeImage()
                } label: {
                    Label("Upload QR Screenshot", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacAddDeviceSecondaryButtonStyle())

                Button {
                    applyPastedPairingPayload()
                } label: {
                    Label("Use Pairing Link", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacAddDeviceSecondaryButtonStyle())
                .disabled(pastedPairingPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            MacViewerConnectInputField(
                title: "Pairing Link",
                systemImage: "link",
                text: $pastedPairingPayload,
                placeholder: "Paste pocketctrl:// pairing link",
                infoTitle: "Pairing Links",
                infoMessage: PairingHelpText.pairingLink
            )

            Divider()

            DisclosureGroup("Advanced", isExpanded: $isAdvancedConnectionVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        PortField(title: "Video", text: $model.viewerListenPort)
                        PortField(title: "Audio", text: $model.viewerAudioPort)
                        PortField(title: "Input", text: $model.viewerHostInputPort)
                    }
                }
                .padding(.top, 8)
            }

            if let pairingMessage {
                Text(pairingMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }

    private func beginRenameSavedComputer(_ computer: ViewerSavedComputer) {
        renameSavedComputerID = computer.id
        renameSavedComputerDraft = computer.name
    }
}

struct MacViewerSavedComputersSection: View {
    let computers: [ViewerSavedComputer]
    let selectedID: String?
    let isConnectionActive: Bool
    let connectionStatus: String
    let onConnect: (ViewerSavedComputer) -> Void
    let onDisconnect: () -> Void
    let onAdd: () -> Void
    let onRename: (ViewerSavedComputer) -> Void
    let onRemove: (ViewerSavedComputer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Macs", systemImage: "desktopcomputer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
                .textCase(.uppercase)

            if computers.isEmpty {
                MacSettingsEmptyRow(
                    title: "No saved Macs yet",
                    subtitle: "Connect a new Mac below or paste a pairing QR link. Both Macs must share a Wi-Fi network or have Tailscale on."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(computers) { computer in
                        MacViewerSavedComputerRow(
                            computer: computer,
                            isSelected: computer.id == selectedID,
                            isActive: isConnectionActive && computer.id == selectedID,
                            status: computer.id == selectedID ? connectionStatus : "Saved",
                            onConnect: {
                                onConnect(computer)
                            },
                            onDisconnect: onDisconnect,
                            onRename: {
                                onRename(computer)
                            },
                            onRemove: {
                                onRemove(computer)
                            }
                        )
                    }
                }
            }

            Button(action: onAdd) {
                Label("Add New Mac", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MacSettingsPrimaryButtonStyle())
        }
    }
}

struct MacViewerHomeBackground: View {
    var body: some View {
        ZStack {
            Color.black

            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.018, blue: 0.026),
                    Color(red: 0.025, green: 0.022, blue: 0.042),
                    Color(red: 0.010, green: 0.012, blue: 0.020)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    .clear,
                    Color(red: 0.18, green: 0.05, blue: 0.20).opacity(0.22),
                    Color(red: 0.03, green: 0.08, blue: 0.18).opacity(0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct MacViewerHomeSavedComputerRow: View {
    let computer: ViewerSavedComputer
    let onConnect: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onConnect) {
                HStack(spacing: 13) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(computer.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        Text(computer.routeSummary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive, action: onRemove) {
                    Label("Remove from List", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mac options")
        }
        .padding(.horizontal, 14)
        .frame(height: 70)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MacViewerHomeConnectButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(isEnabled ? 0.90 : 0.40))
            .padding(.vertical, 14)
            .background(.white.opacity(isEnabled ? (configuration.isPressed ? 0.10 : 0.07) : 0.035), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isEnabled ? 0.14 : 0.07), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

struct MacAddDevicePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.42))
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.17, green: 0.42, blue: 0.86).opacity(isEnabled ? 1 : 0.32),
                        Color(red: 0.30, green: 0.22, blue: 0.68).opacity(isEnabled ? 1 : 0.24)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(.white.opacity(isEnabled ? 0.16 : 0.08), lineWidth: 1))
            .shadow(color: Color(red: 0.10, green: 0.22, blue: 0.48).opacity(isEnabled ? 0.24 : 0), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

struct MacAddDeviceSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary.opacity(isEnabled ? 0.86 : 0.34))
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.075 : 0.045) : 0.025), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(isEnabled ? 0.10 : 0.05), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

struct MacManualPairingCodeEntry: View {
    @Binding var code: String
    @Binding var isFocused: Bool
    let focusRequestID: Int

    private static let charactersPerGroup = 4
    private static let groupCount = (PairingInvitationCode.encodedCharacterCount + charactersPerGroup - 1) / charactersPerGroup

    private var normalizedCode: String {
        Self.normalized(code)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(0..<Self.groupCount, id: \.self) { groupIndex in
                    if groupIndex > 0 {
                        Text("-")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                    codeGroup(at: groupIndex)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(.white.opacity(isFocused ? 0.085 : 0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(isFocused ? Color.blue.opacity(0.72) : Color.white.opacity(0.11), lineWidth: 1)
            )

            MacPairingCodeTextField(
                text: $code,
                isFocused: $isFocused,
                focusRequestID: focusRequestID
            )
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .contentShape(Rectangle())
                .opacity(0.02)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: code) { _, value in
            let next = Self.grouped(Self.normalized(value))
            if next != value {
                code = next
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Computer code")
        .accessibilityValue(Self.grouped(normalizedCode))
        .accessibilityHint("Enter the 12-character code shown on the other Mac")
        .animation(.easeInOut(duration: 0.14), value: isFocused)
    }

    private func codeGroup(at groupIndex: Int) -> some View {
        let value = group(at: groupIndex)
        return Text(value.isEmpty ? "••••" : value)
            .font(.system(size: 17, weight: .semibold, design: .monospaced))
            .foregroundStyle(value.isEmpty ? Color.white.opacity(0.18) : Color.white)
            .kerning(1.6)
            .frame(width: 64, height: 50)
    }

    private func group(at groupIndex: Int) -> String {
        let startOffset = groupIndex * Self.charactersPerGroup
        guard startOffset < normalizedCode.count else { return "" }
        let start = normalizedCode.index(normalizedCode.startIndex, offsetBy: startOffset)
        let end = normalizedCode.index(start, offsetBy: min(Self.charactersPerGroup, normalizedCode.count - startOffset))
        return String(normalizedCode[start..<end])
    }

    private static func normalized(_ value: String) -> String {
        String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(PairingInvitationCode.encodedCharacterCount))
    }

    private static func grouped(_ value: String) -> String {
        stride(from: 0, to: value.count, by: Self.charactersPerGroup).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(Self.charactersPerGroup, value.count - offset))
            return String(value[start..<end])
        }.joined(separator: "-")
    }

}

private struct MacPairingCodeTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusRequestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> FocusRequestTextField {
        let textField = FocusRequestTextField()
        textField.delegate = context.coordinator
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 1)
        textField.textColor = .clear
        textField.stringValue = text
        textField.focusRequestID = focusRequestID
        return textField
    }

    func updateNSView(_ textField: FocusRequestTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused

        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.focusRequestID = focusRequestID
    }

    static func dismantleNSView(_ textField: FocusRequestTextField, coordinator: Coordinator) {
        coordinator.setFocused(false)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            setFocused(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            setFocused(false)
        }

        func setFocused(_ focused: Bool) {
            guard isFocused.wrappedValue != focused else { return }
            isFocused.wrappedValue = focused
        }
    }
}

private final class FocusRequestTextField: NSTextField {
    var focusRequestID = 0 {
        didSet {
            requestFocusIfNeeded()
        }
    }

    private var fulfilledFocusRequestID: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocusIfNeeded()
    }

    private func requestFocusIfNeeded() {
        let requestedID = focusRequestID
        guard fulfilledFocusRequestID != requestedID else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.focusRequestID == requestedID,
                  self.fulfilledFocusRequestID != requestedID,
                  let window = self.window,
                  window.makeFirstResponder(self) else { return }
            self.fulfilledFocusRequestID = requestedID
        }
    }
}

struct MacViewerConnectInputField: View {
    let title: String
    let systemImage: String
    @Binding var text: String
    let placeholder: String
    var isSecure = false
    var infoTitle: String? = nil
    var infoMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let infoTitle, let infoMessage {
                    MacPairingInfoButton(title: infoTitle, message: infoMessage, compact: true)
                }
            }

            field
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

private enum PairingHelpText {
    static let hostPairing = "Open pairing briefly, then scan the QR code from a device you control. Every request still requires approval from the Mac owner."
    static let computerCode = "Enter this code on another device. PocketCtrl automatically looks on local Wi-Fi and through Tailscale; the code is only an expiring invitation, and this Mac still requires approval."
    static let pairingLink = "A PocketCtrl pairing link is a short-lived invitation with connection details. It cannot grant access without approval on the host Mac."
}

struct SecurePairingContent: View {
    @ObservedObject var model: RemoteDesktopModel
    let qrSize: CGFloat
    @State private var devicePendingRevocation: TrustedDeviceRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let storageWarning = model.trustedDeviceStorageWarning {
                Label(storageWarning, systemImage: "exclamationmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !model.connectedViewers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        model.connectedViewers.count == 1 ? "1 device connected" : "\(model.connectedViewers.count) devices connected",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.green)
                    ForEach(model.connectedViewers) { viewer in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewer.name)
                                    .font(.caption.weight(.semibold))
                                Text("\(viewer.route) · \(model.activeControllerID == viewer.id ? "Controlling" : "Viewing")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") {
                                model.disconnectViewer(deviceID: viewer.id, revoke: false)
                            }
                            .buttonStyle(MacSecondaryButtonStyle())
                            if model.trustedDevices.contains(where: { $0.id == viewer.id }) {
                                Button("Revoke", role: .destructive) {
                                    model.disconnectViewer(deviceID: viewer.id, revoke: true)
                                }
                                .buttonStyle(MacSecondaryButtonStyle())
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if model.isPairingModeActive {
                Label("Only pair a device you physically control. Never approve a request prompted by a caller or support agent.", systemImage: "exclamationmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                PairingQRCodeView(payload: model.lanPairingQRCodePayload)
                    .frame(width: qrSize, height: qrSize)
                    .frame(maxWidth: .infinity)

                ManualPairingCodeCard(
                    code: model.manualPairingCode,
                    expiresAt: model.manualPairingExpiresAt,
                    status: model.manualPairingStatus,
                    isEnabled: true,
                    onCopy: { copy(model.manualPairingCode) },
                    onRefresh: { model.regenerateManualPairingCode() }
                )

                HStack(spacing: 8) {
                    Button {
                        copy(model.lanPairingQRCodePayload)
                    } label: {
                        Label("Copy Invite", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MacSecondaryButtonStyle())

                    Button(role: .cancel) {
                        model.endPairingMode()
                    } label: {
                        Label("Close Pairing", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MacSecondaryButtonStyle())
                }
            } else {
                Text(model.isHosting
                     ? "Pairing is closed. Existing trusted devices can still connect."
                     : "Start hosting, then briefly open pairing when your other device is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    model.beginPairingMode()
                } label: {
                    Label("Pair New Device", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HostSidebarPrimaryButtonStyle(tint: .blue))
                .disabled(!model.isHosting)
            }

            if !model.trustedDevices.isEmpty {
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Trusted Devices")
                        .font(.callout.weight(.semibold))
                    ForEach(model.trustedDevices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone.gen3")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.caption.weight(.semibold))
                                Text(scopeSummary(device))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                devicePendingRevocation = device
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .help("Revoke this device")
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Revoke this trusted device?",
            isPresented: Binding(
                get: { devicePendingRevocation != nil },
                set: { if !$0 { devicePendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke Device", role: .destructive) {
                if let devicePendingRevocation {
                    model.revokeTrustedDevice(devicePendingRevocation)
                }
                devicePendingRevocation = nil
            }
            Button("Cancel", role: .cancel) { devicePendingRevocation = nil }
        }
    }

    private var routeSuffix: String {
        model.activeControllerRoute.map { " through \($0)" } ?? ""
    }

    private func scopeSummary(_ device: TrustedDeviceRecord) -> String {
        var scopes = ["View screen"]
        if device.allowsRemoteInput { scopes.append("Control") }
        if device.allowsClipboard { scopes.append("Clipboard") }
        if device.allowsAudio { scopes.append("Audio") }
        return scopes.joined(separator: " · ")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct ManualPairingCodeCard: View {
    let code: String
    let expiresAt: Date
    let status: String
    let isEnabled: Bool
    let onCopy: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Computer Code", systemImage: "keyboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                MacPairingInfoButton(title: "Computer Code", message: PairingHelpText.computerCode, compact: true)

                Spacer()
            }

            HStack(spacing: 8) {
                Text(code.isEmpty ? "---- ---- ----" : code)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(isEnabled ? .white : .white.opacity(0.34))
                    .kerning(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(MacSecondaryButtonStyle())
                .controlSize(.small)
                .disabled(!isEnabled)
                .help("Copy code")

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(MacSecondaryButtonStyle())
                .controlSize(.small)
                .disabled(!isEnabled)
                .help("New code")
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(isEnabled ? countdownText(now: context.date) : "Start hosting before using a computer code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 16, opacity: 0.055)
    }

    private func countdownText(now: Date) -> String {
        let remaining = max(0, Int(ceil(expiresAt.timeIntervalSince(now))))
        let minutes = remaining / 60
        let seconds = remaining % 60
        return "\(status). Expires in \(minutes):\(String(format: "%02d", seconds))."
    }
}

struct ManualPairingApprovalSheet: View {
    let request: PendingManualPairingRequest
    let code: String
    let onApprove: (PairingApprovalOptions) -> Void
    let onDeny: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var allowRemoteInput = false
    @State private var allowClipboard = false
    @State private var allowAudio = false
    @State private var allowUnattendedAccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .background(.blue.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("New Device Request")
                        .font(.title3.weight(.semibold))
                    Text("The name “\(request.viewerName)” was supplied by the requesting device.")
                        .foregroundStyle(.secondary)
                    Text("Approve while the other device is waiting. If the request expires, start pairing again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Computer code", value: code)
                LabeledContent("Connected through", value: request.routeDescription)
                LabeledContent("From", value: request.sourceAddress)
                LabeledContent("Device fingerprint", value: request.deviceFingerprint)
            }
            .font(.callout.monospacedDigit())
            .padding(12)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Label(
                "Only approve a device physically in your possession. A caller or support agent should never ask you to approve this.",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Allow mouse and keyboard control", isOn: $allowRemoteInput)
                Toggle("Allow clipboard access", isOn: $allowClipboard)
                Toggle("Allow Mac audio", isOn: $allowAudio)
                Toggle("Allow future unattended access", isOn: $allowUnattendedAccess)
            }
            .toggleStyle(.switch)

            Text(allowUnattendedAccess
                 ? "This device can reconnect later until you revoke it in Trusted Devices."
                 : "Session only: access ends when hosting stops and is not saved on this Mac.")
                .font(.callout)
                .foregroundStyle(allowUnattendedAccess ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Deny") {
                    onDeny()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    onApprove(PairingApprovalOptions(
                        accessMode: allowUnattendedAccess ? .unattended : .sessionOnly,
                        allowsRemoteInput: allowRemoteInput,
                        allowsClipboard: allowClipboard,
                        allowsAudio: allowAudio
                    ))
                } label: {
                    Label("Authenticate and Approve", systemImage: "touchid")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct MacPairingInfoButton: View {
    let title: String
    let message: String
    var compact = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: compact ? 11 : 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 16 : 20, height: compact ? 16 : 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
        }
    }
}

struct MacViewerSavedComputerRow: View {
    let computer: ViewerSavedComputer
    let isSelected: Bool
    let isActive: Bool
    let status: String
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: isSelected ? 12 : 0) {
            HStack(spacing: 12) {
                Button(action: onConnect) {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(computer.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            Text(computer.routeSummary)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                    }
                }
                .buttonStyle(.plain)

                Menu {
                    Button(action: onRename) {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button(role: .destructive, action: onRemove) {
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
                .accessibilityLabel("Mac options")
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
                        .buttonStyle(MacSettingsInlineActionButtonStyle(tint: .white, isProminent: false))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        Button(action: onConnect) {
                            Label("Connect", systemImage: "play.fill")
                                .lineLimit(1)
                                .frame(minWidth: 104)
                        }
                        .buttonStyle(MacSettingsInlineActionButtonStyle(tint: .blue, isProminent: true))
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

struct MacSettingsBackground: View {
    var body: some View {
        Color(red: 0.035, green: 0.038, blue: 0.045)
            .ignoresSafeArea()
    }
}

struct MacSettingsSection<Content: View>: View {
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

struct MacSettingsEmptyRow: View {
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
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MacSettingsValueRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: 24)

            Text(title)
                .foregroundStyle(.white.opacity(0.76))

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

struct MacSettingsTextFieldRow: View {
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

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}

struct MacSettingsSecureFieldRow: View {
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
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}

struct MacSettingsToggleRow: View {
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
                .toggleStyle(.switch)
                .tint(.blue)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}

struct MacSettingsQualityPickerRow: View {
    @Binding var selection: ViewerQualityProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Stream Quality")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(selection.subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            Picker("Stream Quality", selection: $selection) {
                ForEach(ViewerQualityProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 2)
    }
}

struct MacSettingsDiagnosticBox: View {
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

struct MacSettingsPrimaryButtonStyle: ButtonStyle {
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

struct MacSettingsInlineActionButtonStyle: ButtonStyle {
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
            .background(fillColor(configuration: configuration), in: Capsule())
            .overlay(Capsule().strokeBorder(strokeColor, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private func fillColor(configuration: Configuration) -> Color {
        if isProminent {
            return tint.opacity(isEnabled ? (configuration.isPressed ? 0.62 : 0.82) : 0.24)
        }
        return Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.14 : 0.10) : 0.05)
    }

    private var strokeColor: Color {
        Color.white.opacity(isEnabled ? 0.18 : 0.08)
    }
}

struct MacViewerQualityPicker: View {
    @Binding var selection: ViewerQualityProfile

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(ViewerQualityProfile.allCases) { profile in
                Text(profile.title).tag(profile)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

struct MacViewerStreamControls: View {
    @Binding var quality: ViewerQualityProfile
    @Binding var audioEnabled: Bool
    let audioStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.075), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Stream")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))

                    Text(quality.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                MacViewerQualityPicker(selection: $quality)
                    .frame(minWidth: 210, maxWidth: .infinity)

                Toggle(isOn: $audioEnabled) {
                    Label("Audio", systemImage: audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .frame(width: 116)
                }
                .toggleStyle(.button)
                .buttonStyle(MacSecondaryButtonStyle())
                .help(audioStatus)
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 18, opacity: 0.055)
    }
}

struct MacViewerStatusChip: View {
    let systemImage: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

struct StatusCapsule: View {
    let systemImage: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

struct MacMeshBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.97 + (sin(time * 0.72) * 0.035)

            ZStack {
                Color(red: 0.018, green: 0.018, blue: 0.034)

                GeometryReader { proxy in
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: meshPoints(at: time),
                        colors: [
                            Color(red: 0.018, green: 0.018, blue: 0.034),
                            Color(red: 0.10, green: 0.04, blue: 0.22),
                            Color(red: 0.03, green: 0.12, blue: 0.32),
                            Color(red: 0.07, green: 0.04, blue: 0.18),
                            Color(red: 0.22, green: 0.11, blue: 0.46),
                            Color(red: 0.10, green: 0.30, blue: 0.68),
                            Color(red: 0.03, green: 0.05, blue: 0.12),
                            Color(red: 0.32, green: 0.10, blue: 0.38),
                            Color(red: 0.95, green: 0.26, blue: 0.62)
                        ],
                        background: Color(red: 0.018, green: 0.018, blue: 0.034),
                        smoothsColors: true
                    )
                    .frame(
                        width: min(proxy.size.width * 0.92, 920),
                        height: min(proxy.size.height * 0.55, 460)
                    )
                    .blur(radius: 50)
                    .scaleEffect(pulse)
                    .opacity(0.34 + (sin(time * 0.72 + 0.8) * 0.04))
                    .position(x: proxy.size.width * 0.58, y: proxy.size.height * 0.46)
                }

                LinearGradient(
                    colors: [
                        .black.opacity(0.58),
                        .clear,
                        Color(red: 0.02, green: 0.025, blue: 0.055).opacity(0.72)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [.black.opacity(0.18), .clear, .black.opacity(0.30)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .ignoresSafeArea()
        }
    }

    private func meshPoints(at time: TimeInterval) -> [SIMD2<Float>] {
        [
            SIMD2<Float>(0.00, 0.00),
            SIMD2<Float>(wave(0.50, amplitude: 0.04, time: time, speed: 0.28, phase: 0.0), 0.00),
            SIMD2<Float>(1.00, 0.00),
            SIMD2<Float>(0.00, wave(0.46, amplitude: 0.055, time: time, speed: 0.22, phase: 1.2)),
            SIMD2<Float>(wave(0.52, amplitude: 0.065, time: time, speed: 0.16, phase: 2.1), wave(0.52, amplitude: 0.06, time: time, speed: 0.20, phase: 0.8)),
            SIMD2<Float>(1.00, wave(0.55, amplitude: 0.055, time: time, speed: 0.18, phase: 2.8)),
            SIMD2<Float>(0.00, 1.00),
            SIMD2<Float>(wave(0.46, amplitude: 0.045, time: time, speed: 0.24, phase: 3.4), 1.00),
            SIMD2<Float>(1.00, 1.00)
        ]
    }

    private func wave(_ base: Double, amplitude: Double, time: TimeInterval, speed: Double, phase: Double) -> Float {
        Float(base + sin(time * speed + phase) * amplitude)
    }
}

struct MacGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(.white.opacity(opacity), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 12)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat, opacity: Double = 0.075) -> some View {
        modifier(MacGlassPanelModifier(cornerRadius: cornerRadius, opacity: opacity))
    }
}

struct MacGradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.56))
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.blue.opacity(isEnabled ? (configuration.isPressed ? 0.62 : 0.88) : 0.28), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1))
            .shadow(color: Color.blue.opacity(isEnabled ? 0.18 : 0), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct MacSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 0.88 : 0.50))
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.white.opacity(configuration.isPressed ? 0.15 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct HostStatsStrip: View {
    @ObservedObject var model: RemoteDesktopModel

    var body: some View {
        HStack(spacing: 12) {
            StatTile(title: "Video", value: model.hostFPS > 0 ? "\(model.hostFPS) fps" : "--")
            StatTile(title: "Bitrate", value: model.hostBitrateMbps > 0 ? String(format: "%.1f Mbps", model.hostBitrateMbps) : "--")
            StatTile(title: "Input", value: model.hostInputStatus == "No input received yet" ? "Waiting" : "Active")
        }
        .frame(maxWidth: 560)
    }
}

struct ManualDetailRow: View {
    let title: String
    let value: String
    let systemImage: String
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)

            Button {
                copy()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(MacSecondaryButtonStyle())
            .controlSize(.small)
            .help("Copy \(title)")
        }
        .padding(10)
        .glassPanel(cornerRadius: 14, opacity: 0.055)
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 16, opacity: 0.06)
    }
}

struct PairingQRCodeView: View {
    let payload: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Group {
            if let image = makeImage() {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.24), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
        .accessibilityLabel("Pairing QR code")
    }

    private func makeImage() -> NSImage? {
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: transformed.extent.width, height: transformed.extent.height))
    }
}

struct CleanPanel<Content: View>: View {
    let title: String?
    let systemImage: String?
    private let content: Content

    init(title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title, let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 20, opacity: 0.065)
    }
}

struct PortField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
            TextField("5555", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundStyle(.white.opacity(0.84))
                Spacer()
                Text("\(Int(value.rounded()))\(suffix.isEmpty ? "" : " \(suffix)")")
                    .foregroundStyle(.white.opacity(0.58))
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct StatusRow: View {
    let text: String
    let fps: Int
    let bitrate: Double?

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if fps > 0 {
                Text("\(fps) fps")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let bitrate, bitrate > 0 {
                Text(String(format: "%.1f Mbps", bitrate))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .font(.callout)
    }
}

/// Inline link to a pocketctrl.com guide for connection and Tailscale help.
struct MacHelpLinkButton: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle")
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .help("Opens the guide on pocketctrl.com")
    }
}

struct HostNetworkWarningBanner: View {
    let message: String
    var helpTitle: String? = nil
    var helpURL: URL? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)

                if let helpTitle, let helpURL {
                    Link(destination: helpURL) {
                        HStack(spacing: 4) {
                            Text(helpTitle)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Opens the Tailscale setup guide on pocketctrl.com")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.orange.opacity(0.26), lineWidth: 1)
        )
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    var settingsHint: String? = nil
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.86))

                if !granted, let settingsHint {
                    Text(settingsHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
            if granted {
                Text("Granted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.12), in: Capsule())
            } else {
                HStack(spacing: 6) {
                    Button("Allow") {
                        request()
                    }
                    .controlSize(.small)
                    .buttonStyle(MacGradientButtonStyle())

                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .controlSize(.small)
                    .buttonStyle(MacSecondaryButtonStyle())
                    .help("Open \(title) settings")
                }
            }
        }
        .padding(10)
        .glassPanel(cornerRadius: 14, opacity: granted ? 0.04 : 0.065)
    }
}

private enum PermissionSetupText {
    static let accessibilityHint = "Settings: Privacy & Security > Accessibility > turn on PocketCtrl."
    static let screenRecordingHint = "Settings: Privacy & Security > Screen & System Audio Recording > turn on PocketCtrl."

    static let accessibilityExplanation = "In System Settings > Privacy & Security > Accessibility, turn on PocketCtrl. This lets the iPhone send mouse, keyboard, and scroll input to this Mac."
    static let screenRecordingExplanation = "In System Settings > Privacy & Security > Screen & System Audio Recording, turn on PocketCtrl. This lets PocketCtrl capture your Mac display for the live video stream. If macOS asks, quit and reopen PocketCtrl after enabling it."
}

struct HostOnboardingItem: Identifiable {
    let id = UUID()
    let title: String
    let badge: String
    let systemImage: String
    let isComplete: Bool
    let explanation: String
    let detail: String
    let actionTitle: String
    let action: () -> Void
    let settingsTitle: String?
    let settingsAction: (() -> Void)?
}

struct HostOnboardingStepRow: View {
    let item: HostOnboardingItem

    var body: some View {
        VStack(alignment: .leading, spacing: item.isComplete ? 0 : 12) {
            HStack(spacing: 10) {
                Image(systemName: item.isComplete ? "checkmark.circle.fill" : item.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(item.isComplete ? .green : .orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(item.badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.badge == "Required" ? .orange : .blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background((item.badge == "Required" ? Color.orange : Color.blue).opacity(0.16), in: Capsule())
                    }

                    if item.isComplete {
                        Text("Completed")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Spacer(minLength: 0)

                if item.isComplete, let settingsAction = item.settingsAction {
                    Button {
                        settingsAction()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(MacSecondaryButtonStyle())
                    .controlSize(.small)
                    .help("Open \(item.title) settings")
                }
            }

            if !item.isComplete {
                Text(item.explanation)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        item.action()
                    } label: {
                        Label(item.actionTitle, systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MacGradientButtonStyle())
                    .controlSize(.large)

                    if let settingsTitle = item.settingsTitle, let settingsAction = item.settingsAction {
                        Button {
                            settingsAction()
                        } label: {
                            Label(settingsTitle, systemImage: "gearshape")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MacSecondaryButtonStyle())
                        .controlSize(.large)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.white.opacity(item.isComplete ? 0.045 : 0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(item.isComplete ? .green.opacity(0.24) : .white.opacity(0.14), lineWidth: 1)
        )
    }
}

private extension String {
    var emptyDash: String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "-" : self
    }
}

#Preview {
    ContentView(model: RemoteDesktopModel())
}
