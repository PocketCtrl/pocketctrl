// SPDX-License-Identifier: MPL-2.0
import ApplicationServices
import CoreGraphics
import Foundation

/// Local-only focus references. No field values are read or sent to the provider.
struct ComputerUseFocus {
    var applicationPID: pid_t?
    var window: AXUIElement?
    var element: AXUIElement?

    func matches(_ other: Self, includingElement: Bool = true) -> Bool {
        func same(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case let (lhs?, rhs?): return CFEqual(lhs, rhs)
            default: return false
            }
        }
        return applicationPID == other.applicationPID
            && same(window, other.window) && (!includingElement || same(element, other.element))
    }
}

/// Compare a small RGB image rather than requiring identical encoded PNG bytes.
/// These thresholds detect visual changes, not the semantic meaning of a control.
struct ComputerUseScreenSample {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(image: CGImage) {
        let scale = min(1, 320.0 / Double(max(image.width, image.height)))
        let sampleWidth = max(1, Int(Double(image.width) * scale))
        let sampleHeight = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: sampleWidth, height: sampleHeight,
                bitsPerComponent: 8, bytesPerRow: sampleWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard rendered else { return nil }
        width = sampleWidth
        height = sampleHeight
        pixels = bytes
    }

    func isSimilar(to other: Self, action: ComputerUseAction, screenshotWidth: Int, screenshotHeight: Int, targetOnly: Bool = false, targetBounds: CGRect? = nil) -> Bool {
        guard width == other.width, height == other.height, screenshotWidth > 0, screenshotHeight > 0 else { return false }
        // Ignore small color/rendering noise and changes covering up to 3% of the screen.
        if !targetOnly, changedFraction(other, xRange: 0..<width, yRange: 0..<height) > 0.03 { return false }
        var targets: [ComputerUseAction.Point] = []
        if let x = action.x, let y = action.y { targets.append(.init(x: x, y: y)) }
        if action.type == "drag" { targets += action.path ?? [] }
        for target in targets {
            guard target.x.isFinite, target.y.isFinite, target.x >= 0, target.y >= 0,
                  target.x < Double(screenshotWidth), target.y < Double(screenshotHeight) else { return false }
            let x = Int(target.x * Double(width) / Double(screenshotWidth))
            let y = Int(target.y * Double(height) / Double(screenshotHeight))
            // Watch the area around a click/scroll/drag even when the rest is unchanged.
            // A thin blinking caret may change; a replaced/covered target should not.
            var left = max(0, x - 6), right = min(width, x + 7)
            var top = max(0, y - 6), bottom = min(height, y + 7)
            if targetOnly, let bounds = targetBounds {
                // Do not let a neighboring result row count as this button's
                // pixels. Stay inside the observed control as well as the hit area.
                left = max(left, Int(ceil(bounds.minX * Double(width) / Double(screenshotWidth))))
                right = min(right, Int(floor(bounds.maxX * Double(width) / Double(screenshotWidth))))
                top = max(top, Int(ceil(bounds.minY * Double(height) / Double(screenshotHeight))))
                bottom = min(bottom, Int(floor(bounds.maxY * Double(height) / Double(screenshotHeight))))
            }
            guard left < right, top < bottom else { return false }
            let xs = left..<right, ys = top..<bottom
            guard changedFraction(other, xRange: xs, yRange: ys) <= 0.15 else { return false }
        }
        return true
    }

    private func changedFraction(_ other: Self, xRange: Range<Int>, yRange: Range<Int>) -> Double {
        var changed = 0
        for y in yRange {
            for x in xRange {
                let offset = (y * width + x) * 4
                if (0..<3).contains(where: { abs(Int(pixels[offset + $0]) - Int(other.pixels[offset + $0])) > 24 }) {
                    changed += 1
                }
            }
        }
        return Double(changed) / Double(max(1, xRange.count * yRange.count))
    }
}

extension ComputerUseObservation {
    func isCompatible(with previous: Self, for action: ComputerUseAction) -> Bool {
        compatibilityFailure(with: previous, for: action) == nil
    }
    /// Fixed diagnostic reasons only; never exposes labels, IDs or screen text.
    func compatibilityFailure(with previous: Self, for action: ComputerUseAction, requireStableContext: Bool = false) -> String? {
        guard geometry == previous.geometry, width == previous.width, height == previous.height else { return "display_geometry" }
        guard focusedApplicationID == previous.focusedApplicationID else { return "focused_application" }
        let keyboardAction = ["type", "keypress"].contains(action.type)
        switch (focus, previous.focus) {
        case let (current?, old?): guard current.matches(old, includingElement: keyboardAction) else { return "focus_context" }
        case (nil, nil): break
        default: return "focus_unavailable"
        }
        // Typing belongs to the keyboard owner, not every animated pixel in its
        // window. Keep app/window/element identity strict, but do not reject a
        // stable keyboard destination because album art or results repainted.
        if !requireStableContext, keyboardAction, let focus, focus.applicationPID != nil,
           focus.window != nil, focus.element != nil { return nil }
        guard let visualSample, let previousSample = previous.visualSample else {
            // If sampling fails, never silently disable the stale-observation check.
            return fingerprint == previous.fingerprint ? nil : "sample_unavailable"
        }
        let hasPointerTarget = (action.x != nil && action.y != nil)
            || (action.type == "drag" && !(action.path ?? []).isEmpty)
        // Coordinate actions validate the actual hit area/path. Unrelated UI
        // updates elsewhere no longer invalidate an otherwise stable target.
        return visualSample.isSimilar(to: previousSample, action: action, screenshotWidth: width, screenshotHeight: height,
                                      targetOnly: hasPointerTarget && !requireStableContext)
            ? nil : (hasPointerTarget ? "target_pixels" : "screen_pixels")
    }
}
