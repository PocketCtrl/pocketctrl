// SPDX-License-Identifier: MPL-2.0
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import ScreenCaptureKit

@MainActor
final class ComputerUseDesktop {
    private let displayID: CGDirectDisplayID
    private let injector: MacInputInjector
    private let gate: ComputerUseExecutionGate
    private let boundsProvider: () -> CGRect
    private let displayIsActive: () -> Bool
    private let permissionsGranted: () -> Bool
    private let pointerLocation: () -> CGPoint?
    var onPointerMoved: ((ComputerUsePointer, UInt64, Bool) -> Void)?
    init(displayID: CGDirectDisplayID, injector: MacInputInjector, gate: ComputerUseExecutionGate,
         boundsProvider: (() -> CGRect)? = nil, displayIsActive: (() -> Bool)? = nil,
         permissionsGranted: @escaping () -> Bool = { MacPermissions.accessibilityGranted && MacPermissions.screenRecordingGranted },
         pointerLocation: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location }) {
        self.displayID = displayID; self.injector = injector; self.gate = gate
        self.boundsProvider = boundsProvider ?? { CGDisplayBounds(displayID) }
        self.displayIsActive = displayIsActive ?? { CGDisplayIsActive(displayID) != 0 }
        self.permissionsGranted = permissionsGranted
        self.pointerLocation = pointerLocation
    }
    /// Quartz uses the same top-left global coordinates as our injected events.
    /// Sampling never moves the cursor or sends input to the desktop.
    func currentPointer() -> ComputerUsePointer? {
        let bounds = boundsProvider()
        guard displayIsActive(), bounds.width > 0, bounds.height > 0,
              let location = pointerLocation(), bounds.contains(location) else { return nil }
        let pointer = ComputerUsePointer(x: (location.x - bounds.minX) / bounds.width,
                                         y: (location.y - bounds.minY) / bounds.height)
        return pointer.isValid ? pointer : nil
    }
    func capture() async throws -> ComputerUseObservation {
        let started = ProcessInfo.processInfo.systemUptime
        var metrics = ["observation": String(UUID().uuidString.prefix(8)),
                       "generation": "none",
                       "lane": "openai_screenshot", "stage": "permissions", "outcome": "in_progress"]
        ComputerUseDiagnostics.event("observation.begin", metrics)
        metrics["outcome"] = "failed"
        defer {
            metrics["ms"] = ComputerUseDiagnostics.milliseconds(since: started)
            if Task.isCancelled { metrics["outcome"] = "cancelled" }
            ComputerUseDiagnostics.event("observation.capture", metrics)
        }
        guard permissionsGranted() else {
            throw ComputerUseFailure("Screen Recording and Accessibility permissions are required on the Mac.")
        }
        metrics["stage"] = "display_lookup"
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }), CGDisplayIsActive(displayID) != 0 else {
            throw ComputerUseFailure("The selected display is no longer available. Stop and select a display on the Mac.")
        }
        let bounds = boundsProvider()
        let configuration = SCStreamConfiguration()
        configuration.width = min(1600, CGDisplayPixelsWide(displayID))
        configuration.height = max(1, Int(Double(configuration.width) * bounds.height / bounds.width))
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        metrics["stage"] = "screenshot"
        let captureStarted = ProcessInfo.processInfo.systemUptime
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        metrics["screenshotMs"] = ComputerUseDiagnostics.milliseconds(since: captureStarted)
        try Task.checkCancellation()
        metrics["stage"] = "png_encode"
        let encodeStarted = ProcessInfo.processInfo.systemUptime
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ComputerUseFailure("Could not capture the desktop.")
        }
        let geometry = "\(displayID):\(bounds.origin.x):\(bounds.origin.y):\(bounds.width):\(bounds.height):\(image.width):\(image.height)"
        let fingerprint = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        metrics["encodeMs"] = ComputerUseDiagnostics.milliseconds(since: encodeStarted)
        let finalFocus = ComputerUseFocusResolver.read(fallbackPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        metrics["stage"] = "complete"; metrics["outcome"] = "ready"
        return .init(png: png, width: image.width, height: image.height, geometry: geometry,
                     accessibilityContext: accessibilityContext(finalFocus), fingerprint: fingerprint,
                     visualSample: ComputerUseScreenSample(image: image),
                     focus: .init(applicationPID: finalFocus.pid, window: finalFocus.window, element: finalFocus.element),
                     focusedApplicationID: finalFocus.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
    }
    private func accessibilityContext(_ context: ComputerUseFocusResolver) -> String {
        guard let pid = context.pid else { return "Unavailable" }
        var parts = ["Focused app: \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown")"]
        if let focus = context.element {
            for attribute in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(focus, attribute as CFString, &value) == .success, let text = value as? String {
                    parts.append("\(attribute): \(String(text.prefix(300)))")
                }
            }
        }
        // Never inspect AXValue: it may contain a password or other input.
        return parts.joined(separator: "\n")
    }
    func execute(_ action: ComputerUseAction, observation: ComputerUseObservation, token: UInt64) async throws {
        try check(token)
        let bounds = boundsProvider()
        let geometry = "\(displayID):\(bounds.origin.x):\(bounds.origin.y):\(bounds.width):\(bounds.height):\(observation.width):\(observation.height)"
        guard geometry == observation.geometry, displayIsActive() else { throw ComputerUseFailure("Display geometry changed. Resume with a fresh screenshot.") }
        func point(_ x: Double?, _ y: Double?) throws -> CGPoint {
            guard let x, let y, x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(observation.width), y < Double(observation.height) else {
                throw ComputerUseFailure("The model requested a position outside the selected display.")
            }
            return CGPoint(x: bounds.minX + x / Double(observation.width) * bounds.width,
                           y: bounds.minY + y / Double(observation.height) * bounds.height)
        }
        func mouse(_ type: CGEventType, _ location: CGPoint, _ button: CGMouseButton = .left, count: Int = 1) async throws {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { throw ComputerUseFailure("Cannot create mouse event.") }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            try await injector.postComputerEvent(event, token: token)
            try check(token)
            onPointerMoved?(.init(x: (location.x - bounds.minX) / bounds.width,
                                 y: (location.y - bounds.minY) / bounds.height), token,
                            type != .leftMouseDragged)
        }
        switch action.type {
        case "screenshot": break
        case "wait": try await Task.sleep(nanoseconds: 500_000_000)
        case "move": try await mouse(.mouseMoved, point(action.x, action.y))
        case "click", "double_click":
            let location = try point(action.x, action.y)
            let button: CGMouseButton
            switch action.button ?? "left" {
            case "left": button = .left
            case "right": button = .right
            case "middle", "wheel": button = .center
            default: throw ComputerUseFailure("Unsupported mouse button.")
            }
            let down: CGEventType = button == .left ? .leftMouseDown : button == .right ? .rightMouseDown : .otherMouseDown
            let up: CGEventType = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp
            // Explicitly position the cursor as well as the click event. The
            // viewer follows this executed move, never an unapproved target.
            try await mouse(.mouseMoved, location)
            for count in 1...(action.type == "double_click" ? 2 : 1) {
                try await mouse(down, location, button, count: count)
                try await Task.sleep(nanoseconds: 30_000_000)
                try await mouse(up, location, button, count: count)
            }
        case "drag":
            guard let path = action.path, (2...1000).contains(path.count) else { throw ComputerUseFailure("Invalid drag path.") }
            let points = try path.map { try point($0.x, $0.y) }
            try await mouse(.leftMouseDown, points[0])
            for location in points.dropFirst() {
                try await mouse(.leftMouseDragged, location)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await mouse(.leftMouseUp, points.last!)
        case "scroll":
            guard let dx = action.scroll_x, let dy = action.scroll_y, dx.isFinite, dy.isFinite,
                  abs(dx) <= 10_000, abs(dy) <= 10_000 else { throw ComputerUseFailure("Invalid scroll distance.") }
            try await mouse(.mouseMoved, point(action.x, action.y))
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { throw ComputerUseFailure("Cannot create scroll event.") }
            try await injector.postComputerEvent(event, token: token)
        case "keypress":
            guard let keys = action.keys, !keys.isEmpty, keys.count <= 8 else { throw ComputerUseFailure("Invalid key combination.") }
            let codes = try keys.map { try Self.keyCode($0) }
            var flags: CGEventFlags = []
            for code in codes {
                flags.formUnion(Self.flag(code))
                try await key(code, down: true, flags: flags, token: token)
            }
            for code in codes.reversed() {
                flags.subtract(Self.flag(code))
                try await key(code, down: false, flags: flags, token: token)
            }
        case "type":
            guard let text = action.text, text.utf8.count <= 16_384 else { throw ComputerUseFailure("Requested text is too long.") }
            for character in text {
                let units = Array(String(character).utf16)
                guard units.count <= 128 else { throw ComputerUseFailure("Unsupported text character.") }
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { throw ComputerUseFailure("Cannot create typing event.") }
                    units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!) }
                    try await injector.postComputerEvent(event, token: token)
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        default: throw ComputerUseFailure("Unsupported computer action: \(action.type.prefix(40))")
        }
        try check(token)
    }
    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard gate.isValid(token) else { throw CancellationError() }
        guard permissionsGranted() else { throw ComputerUseFailure("Mac permissions were revoked.") }
    }
    private func key(_ code: UInt16, down: Bool, flags: CGEventFlags, token: UInt64) async throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw ComputerUseFailure("Cannot create keyboard event.") }
        event.flags = flags
        try await injector.postComputerEvent(event, token: token)
    }
    private static func flag(_ code: UInt16) -> CGEventFlags {
        switch Int(code) {
        case kVK_Command: return .maskCommand
        case kVK_Shift: return .maskShift
        case kVK_Option: return .maskAlternate
        case kVK_Control: return .maskControl
        default: return []
        }
    }
    static func keyCode(_ name: String) throws -> UInt16 {
        let keys: [String: Int] = [
            "CMD": kVK_Command, "COMMAND": kVK_Command, "META": kVK_Command, "SUPER": kVK_Command,
            "CTRL": kVK_Control, "CONTROL": kVK_Control, "ALT": kVK_Option, "OPTION": kVK_Option,
            "SHIFT": kVK_Shift, "ENTER": kVK_Return, "RETURN": kVK_Return, "TAB": kVK_Tab,
            "ESC": kVK_Escape, "ESCAPE": kVK_Escape, "SPACE": kVK_Space, "BACKSPACE": kVK_Delete,
            "DELETE": kVK_ForwardDelete, "ARROWLEFT": kVK_LeftArrow, "LEFT": kVK_LeftArrow,
            "ARROWRIGHT": kVK_RightArrow, "RIGHT": kVK_RightArrow, "ARROWUP": kVK_UpArrow,
            "UP": kVK_UpArrow, "ARROWDOWN": kVK_DownArrow, "DOWN": kVK_DownArrow,
            "HOME": kVK_Home, "END": kVK_End, "PAGEUP": kVK_PageUp, "PAGEDOWN": kVK_PageDown,
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
            "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
            "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
            "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
            "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5,
            "F6": kVK_F6, "F7": kVK_F7, "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10,
            "F11": kVK_F11, "F12": kVK_F12,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave
        ]
        guard let code = keys[name.uppercased()] else { throw ComputerUseFailure("Unsupported keyboard key: \(name.prefix(30))") }
        return UInt16(code)
    }
}
