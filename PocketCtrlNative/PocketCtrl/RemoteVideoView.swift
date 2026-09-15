// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreImage
import CoreGraphics
import SwiftUI

final class PixelBufferRenderView: NSView {
    private static let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    private let ciContext = CIContext(options: [
        .workingColorSpace: PixelBufferRenderView.displayColorSpace,
        .outputColorSpace: PixelBufferRenderView.displayColorSpace
    ])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: Self.displayColorSpace])
        guard let cgImage = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.displayColorSpace) else { return }

        DispatchQueue.main.async {
            self.layer?.contents = cgImage
        }
    }
}

struct RemoteVideoView: NSViewRepresentable {
    @ObservedObject var model: RemoteDesktopModel

    func makeNSView(context: Context) -> PixelBufferRenderView {
        let view = PixelBufferRenderView()
        model.attachRenderer(view)
        return view
    }

    func updateNSView(_ nsView: PixelBufferRenderView, context: Context) {
        model.attachRenderer(nsView)
    }
}

final class InputCaptureView: NSView {
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    private static let downArrowKeyCode: UInt16 = 125
    private static let upArrowKeyCode: UInt16 = 126

    var onInput: ((RemoteInputEvent) -> Void)?
    var onCaptureChange: ((Bool) -> Void)?
    var onPointerPositionChange: ((CGPoint) -> Void)?
    var remoteVideoSize = CGSize(width: 16, height: 9)
    var isMouseCaptured = false {
        didSet {
            guard isMouseCaptured != oldValue else { return }
            isMouseCaptured ? beginMouseCapture(at: nil, notify: false) : endMouseCapture(notify: false)
        }
    }

    private var remotePointer = CGPoint(x: 0.5, y: 0.5)
    private var hasRemotePointer = false
    private var cursorIsHidden = false
    private var cursorAssociationDisabled = false
    private var suppressedMouseUpButton: RemoteMouseButton?
    private var pendingWarpMoveSuppressions = 0
    private var lastRecenteredAt = Date.distantPast
    private var lastRecenteredLocalPoint: CGPoint?
    private var lastVisibleLocalCursorPoint: CGPoint?
    private var suppressUncapturedMouseMovesUntil = Date.distantPast
    private var suppressUncapturedMouseMovesNearPoint: CGPoint?
    private var suppressUncapturedMouseMovesUntilExit = false
    private var suppressEscapeKeyUp = false
    private var activeRemoteButtons: [RemoteMouseButton] = []
    private var localGestureMonitor: Any?
    private var isEndingMouseCapture = false
    private var debugCaptureID = 0
    private var debugCapturedMoveCount = 0
    private var debugSuppressedReleaseMoveCount = 0

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        allowedTouchTypes = [.indirect]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            endMouseCapture(notify: true)
            return
        }
        window?.makeFirstResponder(self)
    }

    deinit {
        endMouseCapture(notify: false)
        removeLocalGestureMonitor()
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(.mouseMove, event: event, button: .left)
    }

    override func mouseExited(with event: NSEvent) {
        if suppressUncapturedMouseMovesUntilExit {
            suppressUncapturedMouseMovesUntilExit = false
            suppressUncapturedMouseMovesNearPoint = nil
            logInputDebug("cleared uncaptured release suppression after mouse exit id=\(debugCaptureID) local=\(debugPoint(localPosition(for: event)))")
        }
        super.mouseExited(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(.mouseMove, event: event, button: .left)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(.mouseMove, event: event, button: .right)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(.mouseMove, event: event, button: .center)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isMouseCaptured else {
            let position = normalizedPosition(for: event)
            logInputDebug("focus mouseDown button=left normalized=\(debugPoint(position)) local=\(debugPoint(localPosition(for: event))) eventWindow=\(debugPoint(event.locationInWindow)) \(debugGeometryDescription())")
            suppressedMouseUpButton = .left
            beginMouseCapture(at: position, notify: true)
            onInput?(.pointer(.mouseMove, x: position.x, y: position.y, button: .left))
            logInputDebug("focus sent absolute mouseMove button=left normalized=\(debugPoint(position)) captureID=\(debugCaptureID)")
            return
        }
        sendPointer(.mouseDown, event: event, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        if consumeSuppressedMouseUp(.left) { return }
        sendPointer(.mouseUp, event: event, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isMouseCaptured else {
            let position = normalizedPosition(for: event)
            logInputDebug("focus mouseDown button=right normalized=\(debugPoint(position)) local=\(debugPoint(localPosition(for: event))) eventWindow=\(debugPoint(event.locationInWindow)) \(debugGeometryDescription())")
            suppressedMouseUpButton = .right
            beginMouseCapture(at: position, notify: true)
            onInput?(.pointer(.mouseMove, x: position.x, y: position.y, button: .right))
            logInputDebug("focus sent absolute mouseMove button=right normalized=\(debugPoint(position)) captureID=\(debugCaptureID)")
            return
        }
        sendPointer(.mouseDown, event: event, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        if consumeSuppressedMouseUp(.right) { return }
        sendPointer(.mouseUp, event: event, button: .right)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isMouseCaptured else {
            let position = normalizedPosition(for: event)
            logInputDebug("focus mouseDown button=center normalized=\(debugPoint(position)) local=\(debugPoint(localPosition(for: event))) eventWindow=\(debugPoint(event.locationInWindow)) \(debugGeometryDescription())")
            suppressedMouseUpButton = .center
            beginMouseCapture(at: position, notify: true)
            onInput?(.pointer(.mouseMove, x: position.x, y: position.y, button: .center))
            logInputDebug("focus sent absolute mouseMove button=center normalized=\(debugPoint(position)) captureID=\(debugCaptureID)")
            return
        }
        sendPointer(.mouseDown, event: event, button: .center)
    }

    override func otherMouseUp(with event: NSEvent) {
        if consumeSuppressedMouseUp(.center) { return }
        sendPointer(.mouseUp, event: event, button: .center)
    }

    override func scrollWheel(with event: NSEvent) {
        let position = pointerPosition(for: event)
        onInput?(.scroll(x: position.x, y: position.y, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY))
    }

    override func swipe(with event: NSEvent) {
        guard handleCapturedSwipe(event) else {
            super.swipe(with: event)
            return
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isMouseCaptured {
            suppressEscapeKeyUp = true
            endMouseCapture(notify: true, restoreCursorToRemotePointer: true)
            return
        }
        if event.keyCode == 53, window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
            return
        }
        onInput?(.key(.keyDown, keyCode: event.keyCode, modifiers: event.modifierFlags))
    }

    override func cancelOperation(_ sender: Any?) {
        guard isMouseCaptured else {
            super.cancelOperation(sender)
            return
        }
        suppressEscapeKeyUp = true
        endMouseCapture(notify: true, restoreCursorToRemotePointer: true)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 53, suppressEscapeKeyUp {
            suppressEscapeKeyUp = false
            logInputDebug("suppressed escape keyUp after capture release id=\(debugCaptureID)")
            return
        }
        onInput?(.key(.keyUp, keyCode: event.keyCode, modifiers: event.modifierFlags))
    }

    private func sendPointer(_ kind: RemoteInputKind, event: NSEvent, button: RemoteMouseButton) {
        if kind == .mouseMove, isMouseCaptured {
            if consumeWarpGeneratedMouseMove(event) {
                logCapturedMove(event: event, button: button, suppressedWarp: true, before: remotePointer, localDelta: .zero, remoteDelta: .zero, after: remotePointer)
                return
            }
            let before = remotePointer
            let localDelta = normalizedRelativeDelta(for: event)
            moveCapturedPointerLocally(delta: localDelta)
            let delta = remoteScaledRelativeDelta(for: event)
            logCapturedMove(event: event, button: button, suppressedWarp: false, before: before, localDelta: localDelta, remoteDelta: delta, after: remotePointer)
            notifyPointerPositionChanged()
            onInput?(.relativePointer(deltaX: delta.x, deltaY: delta.y, button: button))
            return
        }

        if isMouseCaptured, kind == .mouseDown || kind == .mouseUp {
            if kind == .mouseDown {
                rememberRemoteButtonDown(button)
            }
            onInput?(.currentPointerButton(kind, button: button, clickCount: event.clickCount))
            if kind == .mouseUp {
                rememberRemoteButtonUp(button)
            }
            return
        }

        if kind == .mouseMove, shouldSuppressUncapturedMouseMove(event) {
            return
        }

        let position = pointerPosition(for: event)
        if kind == .mouseDown {
            rememberRemoteButtonDown(button)
        }
        onInput?(.pointer(kind, x: position.x, y: position.y, button: button, clickCount: event.clickCount))
        if kind == .mouseUp {
            rememberRemoteButtonUp(button)
        }
    }

    private func pointerPosition(for event: NSEvent) -> CGPoint {
        guard isMouseCaptured else {
            let position = normalizedPosition(for: event)
            remotePointer = position
            hasRemotePointer = true
            rememberVisibleLocalCursorPoint(for: position, reason: "absolute pointer")
            notifyPointerPositionChanged()
            return position
        }
        moveCapturedPointerLocally(with: event)
        notifyPointerPositionChanged()
        return remotePointer
    }

    private func moveCapturedPointerLocally(with event: NSEvent) {
        moveCapturedPointerLocally(delta: normalizedRelativeDelta(for: event))
    }

    private func moveCapturedPointerLocally(delta: CGPoint) {
        guard videoContentRect.width > 0, videoContentRect.height > 0 else { return }

        let nextX = remotePointer.x + delta.x
        let nextY = remotePointer.y + delta.y
        remotePointer = CGPoint(
            x: min(max(nextX, 0), 1),
            y: min(max(nextY, 0), 1)
        )
        rememberVisibleLocalCursorPoint(for: remotePointer, reason: "captured move")
        if !cursorAssociationDisabled || localCursorIsNearEdge() {
            recenterLocalCursor()
        }
    }

    private func normalizedRelativeDelta(for event: NSEvent) -> CGPoint {
        let rect = videoContentRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: event.deltaX / rect.width,
            // Mouse deltas and the normalized overlay both increase downward.
            // Only absolute AppKit positions need the bottom-to-top conversion.
            y: event.deltaY / rect.height
        )
    }

    private func remoteScaledRelativeDelta(for event: NSEvent) -> CGPoint {
        let rect = videoContentRect
        guard rect.width > 0, rect.height > 0, remoteVideoSize.width > 0, remoteVideoSize.height > 0 else {
            return CGPoint(x: event.deltaX, y: event.deltaY)
        }
        return CGPoint(
            x: event.deltaX * remoteVideoSize.width / rect.width,
            y: event.deltaY * remoteVideoSize.height / rect.height
        )
    }

    private func beginMouseCapture(at position: CGPoint?, notify: Bool) {
        let wasCaptured = isMouseCaptured
        if !wasCaptured {
            debugCaptureID += 1
            debugCapturedMoveCount = 0
        }
        if let position {
            remotePointer = CGPoint(x: min(max(position.x, 0), 1), y: min(max(position.y, 0), 1))
            hasRemotePointer = true
        } else if !hasRemotePointer {
            remotePointer = CGPoint(x: 0.5, y: 0.5)
            hasRemotePointer = true
        }
        notifyPointerPositionChanged()
        rememberVisibleLocalCursorPoint(for: remotePointer, reason: "capture begin")

        logInputDebug("capture begin id=\(debugCaptureID) wasCaptured=\(wasCaptured) notify=\(notify) requestedPosition=\(position.map(debugPoint) ?? "nil") remotePointer=\(debugPoint(remotePointer)) \(debugGeometryDescription())")
        isMouseCaptured = true
        suppressUncapturedMouseMovesUntilExit = false
        suppressUncapturedMouseMovesNearPoint = nil
        debugSuppressedReleaseMoveCount = 0
        window?.makeFirstResponder(self)
        if !cursorIsHidden {
            NSCursor.hide()
            cursorIsHidden = true
        }
        if !cursorAssociationDisabled, CGAssociateMouseAndMouseCursorPosition(0) == .success {
            cursorAssociationDisabled = true
        }
        recenterLocalCursor()
        installLocalGestureMonitorIfNeeded()
        if notify {
            onCaptureChange?(true)
        }
    }

    private func endMouseCapture(notify: Bool, restoreCursorToRemotePointer: Bool = true) {
        guard !isEndingMouseCapture else { return }
        isEndingMouseCapture = true
        defer { isEndingMouseCapture = false }

        let releaseLocalPoint = lastVisibleLocalCursorPoint ?? localPoint(forRemotePointer: remotePointer)
        logInputDebug("capture end id=\(debugCaptureID) notify=\(notify) restoreCursorToRemotePointer=\(restoreCursorToRemotePointer) remotePointer=\(debugPoint(remotePointer)) releaseLocal=\(releaseLocalPoint.map(debugPoint) ?? "nil") activeButtons=\(activeRemoteButtons.map { $0.rawValue })")
        releaseActiveRemoteButtons()
        isMouseCaptured = false
        suppressedMouseUpButton = nil
        pendingWarpMoveSuppressions = 0
        lastRecenteredLocalPoint = nil
        if cursorAssociationDisabled {
            if restoreCursorToRemotePointer, let releaseLocalPoint {
                moveLocalCursor(toLocalPoint: releaseLocalPoint, reason: "capture release pre-associate")
            }
            CGAssociateMouseAndMouseCursorPosition(1)
            cursorAssociationDisabled = false
        }
        if cursorIsHidden {
            NSCursor.unhide()
            cursorIsHidden = false
        }
        if restoreCursorToRemotePointer, let releaseLocalPoint {
            suppressUncapturedMouseMovesUntil = Date().addingTimeInterval(0.22)
            suppressUncapturedMouseMovesNearPoint = releaseLocalPoint
            suppressUncapturedMouseMovesUntilExit = true
            debugSuppressedReleaseMoveCount = 0
            logCursorState("capture release before restore", target: releaseLocalPoint)
            moveLocalCursor(toLocalPoint: releaseLocalPoint, reason: "capture release")
            if let deferredQuartzPoint = quartzPoint(forLocalPoint: releaseLocalPoint) {
                DispatchQueue.main.async {
                    CGWarpMouseCursorPosition(deferredQuartzPoint)
                }
            } else {
                logInputDebug("capture release deferred restore skipped id=\(debugCaptureID) reason=no-window-or-screen")
            }
        }
        removeLocalGestureMonitor()
        if notify {
            onCaptureChange?(false)
        }
    }

    private func installLocalGestureMonitorIfNeeded() {
        guard localGestureMonitor == nil else { return }
        localGestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe]) { [weak self] event in
            guard let self, self.handleCapturedSwipe(event) else { return event }
            return nil
        }
    }

    private func removeLocalGestureMonitor() {
        guard let localGestureMonitor else { return }
        NSEvent.removeMonitor(localGestureMonitor)
        self.localGestureMonitor = nil
    }

    @discardableResult
    private func handleCapturedSwipe(_ event: NSEvent) -> Bool {
        guard isMouseCaptured else { return false }
        let absX = abs(event.deltaX)
        let absY = abs(event.deltaY)
        guard max(absX, absY) > 0 else { return false }

        if absY >= absX {
            sendControlArrowShortcut(keyCode: event.deltaY > 0 ? Self.upArrowKeyCode : Self.downArrowKeyCode)
        } else {
            sendControlArrowShortcut(keyCode: event.deltaX > 0 ? Self.leftArrowKeyCode : Self.rightArrowKeyCode)
        }
        return true
    }

    private func sendControlArrowShortcut(keyCode: UInt16) {
        onInput?(.key(.keyDown, keyCode: keyCode, modifiers: .control))
        onInput?(.key(.keyUp, keyCode: keyCode, modifiers: .control))
    }

    private func recenterLocalCursor() {
        let rect = videoContentRect
        guard isMouseCaptured, let window, let screen = window.screen, rect.width > 0, rect.height > 0 else { return }
        let centerInWindow = convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let centerInScreen = window.convertPoint(toScreen: centerInWindow)
        let quartzPoint = CGPoint(x: centerInScreen.x, y: screen.frame.maxY - centerInScreen.y)
        logInputDebug("recenter local cursor id=\(debugCaptureID) centerWindow=\(debugPoint(centerInWindow)) centerScreen=\(debugPoint(centerInScreen)) quartz=\(debugPoint(quartzPoint)) rect=\(debugRect(rect))")
        CGWarpMouseCursorPosition(quartzPoint)
        pendingWarpMoveSuppressions = max(pendingWarpMoveSuppressions, 1)
        lastRecenteredAt = Date()
        lastRecenteredLocalPoint = CGPoint(x: rect.midX, y: rect.midY)
    }

    private func consumeWarpGeneratedMouseMove(_ event: NSEvent) -> Bool {
        guard pendingWarpMoveSuppressions > 0 else { return false }
        let rect = videoContentRect
        let local = localPosition(for: event)
        let warpTarget = lastRecenteredLocalPoint ?? CGPoint(x: rect.midX, y: rect.midY)
        let distanceFromWarpTarget = hypot(local.x - warpTarget.x, local.y - warpTarget.y)
        let recentlyWarped = Date().timeIntervalSince(lastRecenteredAt) < 0.85
        let largeDeltaThreshold = min(max(min(rect.width, rect.height) * 0.12, 24), 160)
        let centerHitThreshold = max(6, min(max(min(rect.width, rect.height) * 0.015, 8), 18))
        let hasLargeWarpDelta = abs(event.deltaX) > largeDeltaThreshold || abs(event.deltaY) > largeDeltaThreshold
        let landedAtWarpTarget = distanceFromWarpTarget <= centerHitThreshold
        let looksLikeWarp = hasLargeWarpDelta && (recentlyWarped || landedAtWarpTarget)
        if looksLikeWarp {
            logInputDebug("consume warp move id=\(debugCaptureID) rawDelta=(\(debugNumber(event.deltaX)),\(debugNumber(event.deltaY))) threshold=\(debugNumber(largeDeltaThreshold)) local=\(debugPoint(local)) target=\(debugPoint(warpTarget)) targetDistance=\(debugNumber(distanceFromWarpTarget)) pendingBefore=\(pendingWarpMoveSuppressions)")
            pendingWarpMoveSuppressions -= 1
            return true
        }

        pendingWarpMoveSuppressions = 0
        return false
    }

    private func shouldSuppressUncapturedMouseMove(_ event: NSEvent) -> Bool {
        let local = localPosition(for: event)
        let target = suppressUncapturedMouseMovesNearPoint
        let distance = target.map { hypot(local.x - $0.x, local.y - $0.y) } ?? 0
        let isInsideVideo = videoContentRect.contains(local)
        let withinGraceWindow = Date() < suppressUncapturedMouseMovesUntil
        let untilExit = suppressUncapturedMouseMovesUntilExit && isInsideVideo

        guard withinGraceWindow || untilExit else {
            if !isInsideVideo {
                suppressUncapturedMouseMovesUntilExit = false
            }
            suppressUncapturedMouseMovesNearPoint = nil
            return false
        }

        debugSuppressedReleaseMoveCount += 1
        let reason = untilExit ? "until-exit" : "grace"
        let cursorState = debugSuppressedReleaseMoveCount <= 12 || debugSuppressedReleaseMoveCount.isMultiple(of: 25)
            ? " \(cursorStateDescription(target: target))"
            : ""
        logInputDebug("suppress uncaptured release move id=\(debugCaptureID) index=\(debugSuppressedReleaseMoveCount) reason=\(reason) local=\(debugPoint(local)) target=\(target.map(debugPoint) ?? "nil") distance=\(debugNumber(distance)) rawDelta=(\(debugNumber(event.deltaX)),\(debugNumber(event.deltaY)))\(cursorState)")
        return true
    }

    private func rememberVisibleLocalCursorPoint(for pointer: CGPoint, reason: String) {
        guard let point = localPoint(forRemotePointer: pointer) else { return }
        lastVisibleLocalCursorPoint = point
        if reason != "captured move" || debugCapturedMoveCount <= 40 {
            logInputDebug("remember visible cursor id=\(debugCaptureID) reason=\(reason) remotePointer=\(debugPoint(pointer)) local=\(debugPoint(point))")
        }
    }

    private func localPoint(forRemotePointer pointer: CGPoint) -> CGPoint? {
        let rect = videoContentRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = rect.minX + min(max(pointer.x, 0), 1) * rect.width
        let y = rect.minY + (1 - min(max(pointer.y, 0), 1)) * rect.height
        return CGPoint(x: x, y: y)
    }

    private func moveLocalCursor(toLocalPoint localPoint: CGPoint, reason: String) {
        guard let quartzPoint = quartzPoint(forLocalPoint: localPoint) else { return }
        let pointInWindow = convert(localPoint, to: nil)
        logInputDebug("restore local cursor id=\(debugCaptureID) reason=\(reason) local=\(debugPoint(localPoint)) windowPoint=\(debugPoint(pointInWindow)) quartz=\(debugPoint(quartzPoint)) before=\(cursorStateDescription(target: localPoint))")
        CGWarpMouseCursorPosition(quartzPoint)
        logInputDebug("restore local cursor id=\(debugCaptureID) reason=\(reason) after=\(cursorStateDescription(target: localPoint))")
    }

    private func quartzPoint(forLocalPoint localPoint: CGPoint) -> CGPoint? {
        guard let window, let screen = window.screen else { return nil }
        let pointInWindow = convert(localPoint, to: nil)
        let pointInScreen = window.convertPoint(toScreen: pointInWindow)
        return CGPoint(x: pointInScreen.x, y: screen.frame.maxY - pointInScreen.y)
    }

    private func logCursorState(_ reason: String, target: CGPoint?) {
        logInputDebug("cursor state id=\(debugCaptureID) reason=\(reason) \(cursorStateDescription(target: target))")
    }

    private func cursorStateDescription(target: CGPoint?) -> String {
        let targetText = target.map(debugPoint) ?? "nil"
        let streamLocal = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let cgQuartz = CGEvent(source: nil)?.location
        let cgLocal = localPointForQuartzCursor(cgQuartz)
        let streamDistance = zipDistance(streamLocal, target)
        let cgDistance = zipDistance(cgLocal, target)
        return "target=\(targetText) streamLocal=\(streamLocal.map(debugPoint) ?? "nil") streamDistance=\(streamDistance.map(debugNumber) ?? "nil") cgQuartz=\(cgQuartz.map(debugPoint) ?? "nil") cgLocal=\(cgLocal.map(debugPoint) ?? "nil") cgDistance=\(cgDistance.map(debugNumber) ?? "nil")"
    }

    private func localPointForQuartzCursor(_ quartzPoint: CGPoint?) -> CGPoint? {
        guard let quartzPoint, let window, let screen = window.screen else { return nil }
        let screenPoint = CGPoint(x: quartzPoint.x, y: screen.frame.maxY - quartzPoint.y)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return convert(windowPoint, from: nil)
    }

    private func zipDistance(_ point: CGPoint?, _ target: CGPoint?) -> CGFloat? {
        guard let point, let target else { return nil }
        return hypot(point.x - target.x, point.y - target.y)
    }

    private func localCursorIsNearEdge() -> Bool {
        let rect = videoContentRect
        guard let window, rect.width > 0, rect.height > 0 else { return false }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let threshold = min(max(min(rect.width, rect.height) * 0.10, 20), 100)
        return location.x < rect.minX + threshold ||
            location.x > rect.maxX - threshold ||
            location.y < rect.minY + threshold ||
            location.y > rect.maxY - threshold
    }

    private func consumeSuppressedMouseUp(_ button: RemoteMouseButton) -> Bool {
        guard suppressedMouseUpButton == button else { return false }
        suppressedMouseUpButton = nil
        return true
    }

    private func rememberRemoteButtonDown(_ button: RemoteMouseButton) {
        guard !activeRemoteButtons.contains(button) else { return }
        activeRemoteButtons.append(button)
    }

    private func rememberRemoteButtonUp(_ button: RemoteMouseButton) {
        activeRemoteButtons.removeAll { $0 == button }
    }

    private func releaseActiveRemoteButtons() {
        guard !activeRemoteButtons.isEmpty else { return }
        let buttons = activeRemoteButtons
        activeRemoteButtons.removeAll()
        for button in buttons {
            onInput?(.pointer(.mouseUp, x: remotePointer.x, y: remotePointer.y, button: button))
        }
    }

    private func normalizedPosition(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let rect = videoContentRect
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let clampedX = min(max(local.x, rect.minX), rect.maxX)
        let clampedY = min(max(local.y, rect.minY), rect.maxY)
        let x = min(max((clampedX - rect.minX) / rect.width, 0), 1)
        let y = min(max(1 - ((clampedY - rect.minY) / rect.height), 0), 1)
        return CGPoint(x: x, y: y)
    }

    private var videoContentRect: CGRect {
        guard bounds.width > 0, bounds.height > 0, remoteVideoSize.width > 0, remoteVideoSize.height > 0 else {
            return bounds
        }

        let videoAspect = remoteVideoSize.width / remoteVideoSize.height
        let boundsAspect = bounds.width / bounds.height
        if boundsAspect > videoAspect {
            let width = bounds.height * videoAspect
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        }

        let height = bounds.width / videoAspect
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    private func localPosition(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func logCapturedMove(
        event: NSEvent,
        button: RemoteMouseButton,
        suppressedWarp: Bool,
        before: CGPoint,
        localDelta: CGPoint,
        remoteDelta: CGPoint,
        after: CGPoint
    ) {
        debugCapturedMoveCount += 1
        let rawMagnitude = max(abs(event.deltaX), abs(event.deltaY))
        guard debugCapturedMoveCount <= 40 || suppressedWarp || rawMagnitude > 40 else { return }
        logInputDebug("captured move id=\(debugCaptureID) index=\(debugCapturedMoveCount) button=\(button.rawValue) suppressedWarp=\(suppressedWarp) rawDelta=(\(debugNumber(event.deltaX)),\(debugNumber(event.deltaY))) localDelta=\(debugPoint(localDelta)) remoteDeltaPx=\(debugPoint(remoteDelta)) pointerBefore=\(debugPoint(before)) pointerAfter=\(debugPoint(after)) local=\(debugPoint(localPosition(for: event))) \(debugGeometryDescription())")
    }

    private func debugGeometryDescription() -> String {
        let windowFrame = window?.frame ?? .zero
        let backingScale = window?.backingScaleFactor ?? 0
        return "bounds=\(debugRect(bounds)) videoRect=\(debugRect(videoContentRect)) remoteVideoSize=\(debugSize(remoteVideoSize)) windowFrame=\(debugRect(windowFrame)) backingScale=\(debugNumber(backingScale))"
    }

    private func logInputDebug(_ message: String) {
        #if DEBUG
        let line = "input viewer \(message)"
        NSLog("PocketCtrl \(line)")
        PocketCtrlHostDiagnostics.write(line)
        #endif
    }

    private func debugPoint(_ point: CGPoint) -> String {
        "(\(debugNumber(point.x)),\(debugNumber(point.y)))"
    }

    private func debugSize(_ size: CGSize) -> String {
        "(\(debugNumber(size.width))x\(debugNumber(size.height)))"
    }

    private func debugRect(_ rect: CGRect) -> String {
        "(x:\(debugNumber(rect.minX)) y:\(debugNumber(rect.minY)) w:\(debugNumber(rect.width)) h:\(debugNumber(rect.height)))"
    }

    private func notifyPointerPositionChanged() {
        onPointerPositionChange?(remotePointer)
    }

    private func debugNumber(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func debugNumber(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }
}

struct RemoteInputOverlay: NSViewRepresentable {
    @ObservedObject var model: RemoteDesktopModel

    func makeNSView(context: Context) -> InputCaptureView {
        let view = InputCaptureView()
        view.remoteVideoSize = model.remoteVideoSize
        view.onInput = { [weak model] event in
            model?.sendInput(event)
        }
        view.onCaptureChange = { [weak model] captured in
            model?.setViewerMouseCaptured(captured)
        }
        view.onPointerPositionChange = { [weak model] position in
            model?.updateViewerPointerPosition(position)
        }
        return view
    }

    func updateNSView(_ nsView: InputCaptureView, context: Context) {
        nsView.remoteVideoSize = model.remoteVideoSize
        nsView.isMouseCaptured = model.viewerMouseCaptured
        nsView.onInput = { [weak model] event in
            model?.sendInput(event)
        }
        nsView.onCaptureChange = { [weak model] captured in
            model?.setViewerMouseCaptured(captured)
        }
        nsView.onPointerPositionChange = { [weak model] position in
            model?.updateViewerPointerPosition(position)
        }
    }
}
