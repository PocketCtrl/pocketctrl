// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

// Owned by the app's model, not a SwiftUI view lifecycle. This can present
// while both the main window and menu-bar popover are closed.
@MainActor
final class LocalNetworkAccessWarningController {
    private var windowController: NSWindowController?

    func showWarning(onOpenSettings: @escaping () -> Void = {}) -> Bool {
        if windowController == nil {
            let content = NSHostingController(rootView: LocalNetworkAccessWarningView(onOpenSettings: onOpenSettings, onDismiss: { [weak self] in
                self?.windowController?.close()
            }))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Local Network Access"
            window.identifier = NSUserInterfaceItemIdentifier("local-network-access-warning")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.tabbingMode = .disallowed
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentViewController = content
            window.setContentSize(content.view.fittingSize)
            window.center()
            windowController = NSWindowController(window: window)
        }

        guard let window = windowController?.window else { return false }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return window.isVisible
    }
}

struct LocalNetworkAccessWarningView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Check Local Network Access", systemImage: "wifi.exclamationmark")
                .font(.headline)

            Text("A nearby device connected, but PocketCtrl couldn’t send media over local Wi-Fi. macOS may be blocking the connection even if Local Network access is already enabled. The network may also be unreachable.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Open System Settings → Privacy & Security → Local Network. Turn PocketCtrl off, then back on, and try connecting again. This may refresh macOS’s permission state. If it still doesn’t connect, quit and reopen PocketCtrl. Restarting your Mac may also help.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Not Now") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Settings") {
                    onOpenSettings()
                    MacPermissions.openLocalNetworkSettings()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .preferredColorScheme(.dark)
    }
}
