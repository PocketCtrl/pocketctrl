// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Identity belongs to this PocketCtrl installation, not to a network interface.
/// Private Wi-Fi addresses, IP changes, and adapter changes must not invalidate
/// viewers' saved discovery identities. Authentication still requires a credential.
enum PersistentHostIdentity {
    static let defaultsKey = "PocketCtrl.hostID"

    static func loadOrCreate(in defaults: UserDefaults = .standard) -> String {
        let saved = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty {
            return saved
        }

        let created = "PCTRL-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        defaults.set(created, forKey: defaultsKey)
        return created
    }
}
