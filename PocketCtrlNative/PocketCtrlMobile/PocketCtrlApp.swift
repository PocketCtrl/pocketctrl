// SPDX-License-Identifier: MPL-2.0

import SwiftUI

@main
struct PocketCtrlMobileApp: App {
    var body: some Scene {
        WindowGroup {
            ClientContentView()
                .preferredColorScheme(.dark)
        }
    }
}
