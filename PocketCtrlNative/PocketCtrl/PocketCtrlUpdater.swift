// SPDX-License-Identifier: MPL-2.0

import Combine
import Sparkle
import SwiftUI

/// One updater for the entire app, shared by Settings and the application menu.
@MainActor
final class PocketCtrlUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    init() {
        // Updates are user initiated: never interrupt an active remote session
        // with an unattended installation or replace an Xcode development build.
        #if DEBUG
        let enabled = false
        #else
        let enabled = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: enabled, updaterDelegate: nil, userDriverDelegate: nil
        )
        if enabled {
            controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .assign(to: &$canCheckForUpdates)
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}

struct PocketCtrlUpdateButton: View {
    @ObservedObject var updater: PocketCtrlUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
