// SPDX-License-Identifier: MPL-2.0

import Foundation
import ServiceManagement

enum LoginItemManager {
    static var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func syncLaunchAtLogin(enabled: Bool) -> String {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            return statusDescription()
        } catch {
            let action = enabled ? "enable" : "disable"
            return "Could not \(action) launch at login: \(error.localizedDescription)"
        }
    }

    static func statusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Launch at login is on."
        case .requiresApproval:
            return "macOS needs approval in Login Items before this can launch at login."
        case .notRegistered:
            return "Launch at login is off."
        case .notFound:
            return "Launch at login is unavailable for this app build."
        @unknown default:
            return "Launch at login status is unknown."
        }
    }
}
