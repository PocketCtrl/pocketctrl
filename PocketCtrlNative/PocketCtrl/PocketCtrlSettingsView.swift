// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct PocketCtrlSettingsView: View {
    @ObservedObject var model: RemoteDesktopModel
    @ObservedObject var updater: PocketCtrlUpdater
    @AppStorage("PocketCtrl.selectedSettingsPane") private var selectedPane = SettingsPane.general.rawValue

    var body: some View {
        TabView(selection: $selectedPane) {
            PocketCtrlGeneralSettingsPane(model: model, updater: updater)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsPane.general.rawValue)

            PocketCtrlCommandLineSettingsPane(controlToken: model.hostControlToken)
                .tabItem {
                    Label("Command Line", systemImage: "terminal")
                }
                .tag(SettingsPane.commandLine.rawValue)
        }
        .frame(width: 640, height: 430)
        .preferredColorScheme(.dark)
    }
}

private enum SettingsPane: String {
    case general
    case commandLine
}

private struct PocketCtrlGeneralSettingsPane: View {
    @ObservedObject var model: RemoteDesktopModel
    @ObservedObject var updater: PocketCtrlUpdater
    #if POCKETCTRL_NETWORK_DIAGNOSTICS
    @AppStorage(MacDiagnosticTransport.preference) private var diagnosticTransport = MacDiagnosticTransport.dualStack.rawValue
    #endif

    var body: some View {
        ZStack {
            MacSettingsBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsPaneHeader(
                        title: "General",
                        subtitle: "Choose how PocketCtrl behaves when this Mac starts and while it is available to your devices."
                    )

                    MacSettingsSection(title: "Startup", systemImage: "power") {
                        MacSettingsToggleRow(
                            title: "Launch at login",
                            subtitle: model.launchAtLoginStatus,
                            systemImage: "person.crop.circle.badge.checkmark",
                            isOn: $model.launchAtLoginEnabled
                        )

                        settingsDivider

                        MacSettingsToggleRow(
                            title: "Start hosting when opened",
                            subtitle: model.autoStartHosting
                                ? "Hosting starts automatically when PocketCtrl opens."
                                : "PocketCtrl opens without starting the host.",
                            systemImage: "play.circle.fill",
                            isOn: $model.autoStartHosting
                        )

                        settingsDivider

                        MacSettingsToggleRow(
                            title: "Keep Mac awake while hosting",
                            subtitle: sleepPreventionSubtitle,
                            systemImage: model.isSleepPreventionActive ? "sun.max.fill" : "moon.zzz.fill",
                            isOn: $model.keepAwakeWhileHosting
                        )
                    }

                    MacSettingsSection(title: "Nearby Connections", systemImage: "wifi") {
                        MacSettingsToggleRow(
                            title: "Discover on local Wi-Fi",
                            subtitle: model.allowLocalDiscovery
                                ? "Nearby paired devices can find this Mac automatically."
                                : "Nearby discovery is off; saved direct connections still work.",
                            systemImage: "bonjour",
                            isOn: $model.allowLocalDiscovery
                        )
                    }

                    #if POCKETCTRL_NETWORK_DIAGNOSTICS
                    MacSettingsSection(title: "Local Network Test — build 4", systemImage: "network") {
                        Picker("Video transport", selection: $diagnosticTransport) {
                            ForEach(MacDiagnosticTransport.allCases) { transport in
                                Text(transport.title).tag(transport.rawValue)
                            }
                        }
                        .disabled(model.isHostingRequested)
                        Text("Stop hosting before changing the method, then start hosting and connect your iPhone. Leave Local Network permission unchanged between tests. Native IPv4 requires an IPv4 connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Test each method for 20 seconds. Report whether video appears; a successful send alone does not prove delivery. Automatic socket recovery is disabled for this comparison.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    #endif

                    MacSettingsSection(title: "About", systemImage: "info.circle") {
                        HStack {
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                            Spacer()
                            PocketCtrlUpdateButton(updater: updater)
                        }
                        #if POCKETCTRL_NETWORK_DIAGNOSTICS
                        Text("Local diagnostic build 4. Updates are disabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #elseif DEBUG
                        Text("Updates are available in the installed release app, not Xcode builds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #else
                        Text("Install and relaunch when ready. Active connections will disconnect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #endif
                        settingsDivider
                        Link("Privacy Policy", destination: MacLegalLinks.privacyPolicy)
                        settingsDivider
                        Link("Downloads and Updates", destination: MacLegalLinks.downloads)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            model.refreshLaunchAtLoginStatus()
        }
    }

    private var settingsDivider: some View {
        Divider()
            .overlay(.white.opacity(0.10))
            .padding(.leading, 34)
    }

    private var sleepPreventionSubtitle: String {
        guard model.keepAwakeWhileHosting else {
            return "Allow the Mac to follow its normal sleep settings."
        }
        if model.isSleepPreventionActive {
            return "Active while hosting. The display may still turn off."
        }
        if model.isHostingRequested {
            return "Preparing sleep prevention for the active host."
        }
        return "Activates when hosting starts."
    }
}

private struct PocketCtrlCommandLineSettingsPane: View {
    let controlToken: String
    @StateObject private var agentSkillInstaller = PocketCtrlAgentSkillInstaller()

    var body: some View {
        ZStack {
            MacSettingsBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsPaneHeader(
                        title: "Command Line",
                        subtitle: "Install the optional pocketctrl command so you can manage the host from any Terminal session."
                    )

                    MacSettingsSection(title: "PocketCtrl CLI", systemImage: "chevron.left.forwardslash.chevron.right") {
                        PocketCtrlCLIInstallationRow(controlToken: controlToken)
                    }

                    MacSettingsSection(title: "AI Agents", systemImage: "sparkles") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Install a portable PocketCtrl skill so local coding agents can use the CLI safely. Install the CLI above first.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.52))
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(PocketCtrlAgentSkillInstaller.AgentTarget.allCases) { target in
                                Divider()
                                    .overlay(.white.opacity(0.10))

                                PocketCtrlAgentSkillInstallationRow(
                                    target: target,
                                    installer: agentSkillInstaller
                                )
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("QUICK START")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.58))

                        VStack(alignment: .leading, spacing: 7) {
                            Text("pocketctrl status")
                            Text("pocketctrl start")
                            Text("pocketctrl pairing")
                        }
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
        }
        .alert(
            "Agent Skill",
            isPresented: Binding(
                get: { agentSkillInstaller.errorMessage != nil },
                set: { if !$0 { agentSkillInstaller.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                agentSkillInstaller.errorMessage = nil
            }
        } message: {
            Text(agentSkillInstaller.errorMessage ?? "The operation could not be completed.")
        }
    }
}

private struct PocketCtrlAgentSkillInstallationRow: View {
    let target: PocketCtrlAgentSkillInstaller.AgentTarget
    @ObservedObject var installer: PocketCtrlAgentSkillInstaller
    @State private var isReplaceConfirmationPresented = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(statusTint.opacity(0.14))

                Image(systemName: target.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusTint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(target.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.90))

                    Circle()
                        .fill(statusTint)
                        .frame(width: 6, height: 6)
                }

                Text(installer.statusText(for: target))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if installer.isWorking(target) {
                ProgressView()
                    .controlSize(.small)
            }

            if installer.canUninstall(target) {
                Button("Uninstall") {
                    installer.uninstall(target)
                }
                .buttonStyle(MacSettingsInlineActionButtonStyle(tint: .white))
                .disabled(installer.isWorking(target))
            }

            Button(installer.primaryActionTitle(for: target)) {
                if installer.state(for: target) == .conflict {
                    isReplaceConfirmationPresented = true
                } else {
                    installer.install(target)
                }
            }
            .buttonStyle(MacSettingsInlineActionButtonStyle(tint: .blue, isProminent: true))
            .disabled(
                installer.isWorking(target)
                    || installer.state(for: target) == .checking
                    || installer.state(for: target) == .resourceUnavailable
            )
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Replace the existing " + target.displayName + " skill?",
            isPresented: $isReplaceConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Back Up and Replace") {
                installer.install(target, replacingConflict: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PocketCtrl will move the existing skill to a timestamped backup in the same folder before installing its own.")
        }
    }

    private var statusTint: Color {
        switch installer.state(for: target) {
        case .checking:
            return .secondary
        case .notInstalled:
            return .blue
        case .installed:
            return .green
        case .updateAvailable:
            return .orange
        case .conflict, .resourceUnavailable:
            return .red
        }
    }
}

private struct SettingsPaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PocketCtrlCLIInstallationRow: View {
    let controlToken: String
    @StateObject private var installer = PocketCtrlCLIInstaller()
    @State private var isReplaceConfirmationPresented = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(statusTint.opacity(0.14))

                Image(systemName: installer.isWorking ? "arrow.triangle.2.circlepath" : "terminal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusTint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("Terminal command")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.90))

                    Circle()
                        .fill(statusTint)
                        .frame(width: 6, height: 6)
                }

                Text(installer.statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if installer.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if installer.canUninstall {
                Button("Uninstall") {
                    Task { await installer.uninstall() }
                }
                .buttonStyle(MacSettingsInlineActionButtonStyle(tint: .white))
                .disabled(installer.isWorking)
            }

            Button(installer.primaryActionTitle) {
                if installer.installationState == .conflict {
                    isReplaceConfirmationPresented = true
                } else {
                    install()
                }
            }
            .buttonStyle(MacSettingsInlineActionButtonStyle(tint: .blue, isProminent: true))
            .disabled(installer.isWorking || installer.installationState == .checking)
        }
        .padding(.vertical, 4)
        .onAppear {
            installer.refresh()
        }
        .confirmationDialog(
            "Replace the existing pocketctrl command?",
            isPresented: $isReplaceConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Replace Command", role: .destructive) {
                install()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A command not managed by PocketCtrl already exists at /usr/local/bin/pocketctrl.")
        }
        .alert(
            "Command Line Tool",
            isPresented: Binding(
                get: { installer.errorMessage != nil },
                set: { if !$0 { installer.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                installer.errorMessage = nil
            }
        } message: {
            Text(installer.errorMessage ?? "The operation could not be completed.")
        }
    }

    private var statusTint: Color {
        switch installer.installationState {
        case .checking:
            return .secondary
        case .notInstalled:
            return .blue
        case .installed:
            return .green
        case .updateAvailable:
            return .orange
        case .conflict:
            return .red
        }
    }

    private func install() {
        Task {
            await installer.install(controlToken: controlToken)
        }
    }
}
