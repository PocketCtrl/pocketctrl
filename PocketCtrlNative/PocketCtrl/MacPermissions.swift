// SPDX-License-Identifier: MPL-2.0

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum MacPermissions {
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestScreenRecordingPrompt() {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    static func openLocalNetworkSettings() {
        openPrivacyPane(anchor: "Privacy_LocalNetwork")
    }

    private static func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
