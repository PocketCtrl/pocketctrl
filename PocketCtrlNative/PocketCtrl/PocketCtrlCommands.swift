// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

struct PocketCtrlCommands: Commands {
    @ObservedObject private var model: RemoteDesktopModel
    @Environment(\.openWindow) private var openWindow

    init(model: RemoteDesktopModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Connection") {
            Button(model.isHostingRequested ? "Stop Hosting" : "Start Hosting") {
                model.isHostingRequested ? model.stopHost() : model.startHost()
            }
            .disabled(!hostSetupComplete && !model.isHostingRequested)

            Button("Pair a Device…") {
                showMainWindow()
                postWorkspaceCommand(.pocketCtrlShowHostingControls)
                model.beginPairingMode()
            }
            .disabled(!model.isHosting)

            if model.isPairingModeActive {
                Button("Close Pairing") {
                    model.endPairingMode()
                }
            }

            Divider()

            Button("Disconnect from Mac") {
                model.stopViewer()
            }
            .disabled(!model.isViewing)

            Divider()

            Button("Refresh Status") {
                refreshStatus()
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Show Viewer") {
                showMainWindow()
                postWorkspaceCommand(.pocketCtrlShowViewer)
            }

            Button("Show Hosting Controls") {
                showMainWindow()
                postWorkspaceCommand(.pocketCtrlShowHostingControls)
            }

            Toggle("Show Remote Pointer", isOn: $model.showRemotePointer)
                .disabled(!model.isViewing)
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy PocketCtrl Status") {
                copyStatusSummary()
            }
        }

        CommandGroup(before: .windowList) {
            Button("Show PocketCtrl") {
                showMainWindow()
            }
            .keyboardShortcut("1", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("PocketCtrl Help") {
                NSWorkspace.shared.open(MacHelpLinks.installGuide)
            }

            Button("View Source Code") {
                openURL("https://github.com/PocketCtrl/pocketctrl")
            }

            Link("Privacy Policy", destination: MacLegalLinks.privacyPolicy)
            Link("Downloads and Updates", destination: MacLegalLinks.downloads)

            Divider()

            Button("Report an Issue…") {
                openURL("https://github.com/PocketCtrl/pocketctrl/issues/new/choose")
            }

            Button("Report a Security Issue…") {
                openURL("https://github.com/PocketCtrl/pocketctrl/security/advisories/new")
            }
        }
    }

    private var hostSetupComplete: Bool {
        model.screenRecordingGranted &&
        (model.accessibilityGranted || !model.remoteInputEnabled)
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshStatus() {
        model.refreshNetworkAddresses()
        Task {
            await model.refreshSetupStatus()
        }
    }

    private func postWorkspaceCommand(_ name: Notification.Name) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    private func copyStatusSummary() {
        let viewerState = model.isViewing ? model.viewerStatus : "Disconnected"
        let hostingState = model.isHosting ? model.hostStatus : (model.isHostingRequested ? "Starting" : "Stopped")
        let summary = """
        PocketCtrl Status
        Hosting: \(hostingState)
        Connected devices: \(model.connectedViewers.count)
        Local Wi-Fi: \(model.localAddress)
        Tailscale: \(model.tailscaleAddress)
        Viewer: \(viewerState)
        Screen Recording: \(model.screenRecordingGranted ? "Allowed" : "Not allowed")
        Accessibility: \(model.accessibilityGranted ? "Allowed" : "Not allowed")
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    static let pocketCtrlShowViewer = Notification.Name("PocketCtrl.showViewer")
    static let pocketCtrlShowHostingControls = Notification.Name("PocketCtrl.showHostingControls")
}
