// SPDX-License-Identifier: MPL-2.0

//
//  PocketCtrlApp.swift
//  PocketCtrl
//
//  Created by PocketCtrl contributors on 5/31/26.
//

import AppKit
import SwiftUI

@main
struct PocketCtrlApp: App {
    @StateObject private var model = RemoteDesktopModel()
    @StateObject private var updater = PocketCtrlUpdater()
    private let hostControlServer = PocketCtrlHostControlServer()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        Self.terminateOlderInstances()
    }

    var body: some Scene {
        Window("PocketCtrl", id: "main") {
            ContentView(model: model)
                .onAppear {
                    hostControlServer.start(model: model)
                }
        }
        .commands {
            PocketCtrlCommands(model: model)
            CommandGroup(after: .appInfo) {
                PocketCtrlUpdateButton(updater: updater)
            }
        }

        Settings {
            PocketCtrlSettingsView(model: model, updater: updater)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            HostMenuBarView(model: model)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
                .tint(.blue)
        } label: {
            menuBarIcon
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarIcon: some View {
        Image("MenuBar")
            .accessibilityLabel("PocketCtrl Host")
    }

    private static func terminateOlderInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            where app.processIdentifier != currentProcessIdentifier {
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if !app.isTerminated {
                    app.forceTerminate()
                }
            }
        }
    }
}
