// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

// Owned by the app's model, not a SwiftUI view lifecycle. This can present
// while both the main window and menu-bar popover are closed.
@MainActor
final class LocalNetworkAccessWarningController {
    private var windowController: NSWindowController?

    func showWarning() -> Bool {
        if windowController == nil {
            let content = NSHostingController(rootView: LocalNetworkAccessWarningView(onDismiss: { [weak self] in
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
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Check Local Network Access", systemImage: "wifi.exclamationmark")
                .font(.headline)

            Text("A nearby device is trying to connect, but PocketCtrl couldn’t send data back over local Wi-Fi. Local Network access may be turned off in macOS.")
                .fixedSize(horizontal: false, vertical: true)

            Text("In System Settings → Privacy & Security → Local Network, turn on PocketCtrl, then try connecting again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Not Now") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Settings") {
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
