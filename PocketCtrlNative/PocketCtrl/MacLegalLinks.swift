// SPDX-License-Identifier: MPL-2.0

import Foundation

enum MacLegalLinks {
    static let privacyPolicy = URL(string: "https://www.pocketctrl.com/privacy")!
    static let downloads = URL(string: "https://www.pocketctrl.com/download")!
}

enum MacHelpLinks {
    static let installGuide = URL(string: "https://pocketctrl.com/tutorials/install-pocketctrl")!
    static let tailscaleGuide = URL(string: "https://pocketctrl.com/help/tailscale")!
    static let connectionHelp = URL(string: "https://pocketctrl.com/help/connecting")!
    static let sameNetworkHelp = URL(string: "https://pocketctrl.com/help/same-network")!
    static let pairingHelp = URL(string: "https://pocketctrl.com/help/pairing")!
    static let helpCenter = URL(string: "https://pocketctrl.com/help")!
    static let sameNetworkHint = "Devices must be on the same Wi-Fi network to connect locally. Away from home, turn on Tailscale on both devices."
}
