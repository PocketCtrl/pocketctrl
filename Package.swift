// swift-tools-version: 5.9
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let package = Package(
    name: "PocketCtrl",
    platforms: [
        .macOS("15.6")
    ],
    products: [
        .executable(name: "pocketctrl", targets: ["PocketCtrlHostCLI"])
    ],
    targets: [
        .executableTarget(
            name: "PocketCtrlHostCLI"
        )
    ]
)
