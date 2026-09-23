// SPDX-License-Identifier: MPL-2.0
import ApplicationServices

/// The keyboard owner can be an overlay (Spotlight, menus, a panel), not the
/// workspace's frontmost application. Never reads AXValue or field contents.
struct ComputerUseFocusResolver {
    var pid: pid_t?
    var application: AXUIElement?
    var element: AXUIElement?
    var window: AXUIElement?
    var usedSystemFocus: Bool

    static func reference(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, 0.12)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    static func process(_ element: AXUIElement?) -> pid_t? {
        guard let element else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }
    static func preferredPID(element: pid_t?, application: pid_t?, fallback: pid_t?) -> pid_t? {
        [element, application, fallback].compactMap { $0 }.first { $0 > 0 }
    }
    static func read(fallbackPID: pid_t?) -> Self {
        let system = AXUIElementCreateSystemWide()
        let systemElement = reference(system, kAXFocusedUIElementAttribute)
        let systemApplication = reference(system, kAXFocusedApplicationAttribute)
        let pid = preferredPID(element: process(systemElement), application: process(systemApplication), fallback: fallbackPID)
        let app = pid.map(AXUIElementCreateApplication)
        let focused = systemElement ?? app.flatMap { reference($0, kAXFocusedUIElementAttribute) }
        let window = focused.flatMap { reference($0, kAXWindowAttribute) }
            ?? app.flatMap { reference($0, kAXFocusedWindowAttribute) }
        return .init(pid: pid, application: app, element: focused, window: window,
                     usedSystemFocus: process(systemElement) != nil || process(systemApplication) != nil)
    }
}
