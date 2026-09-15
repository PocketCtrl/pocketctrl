// SPDX-License-Identifier: MPL-2.0

import Foundation

enum ClientLegalLinks {
    static let privacyPolicy = URL(string: "https://www.pocketctrl.com/privacy")!
}

enum ClientHelpLinks {
    static let installGuide = URL(string: "https://pocketctrl.com/tutorials/install-pocketctrl")!
    static let tailscaleGuide = URL(string: "https://pocketctrl.com/help/tailscale")!
    static let connectionHelp = URL(string: "https://pocketctrl.com/help/connecting")!
    static let sameNetworkHelp = URL(string: "https://pocketctrl.com/help/same-network")!
    static let pairingHelp = URL(string: "https://pocketctrl.com/help/pairing")!
    static let approvalHelp = URL(string: "https://pocketctrl.com/help/connecting#approval")!
    static let sameNetworkHint = "Your iPhone and Mac must be on the same Wi-Fi network to connect locally. Away from home, turn on Tailscale on both devices."
}
