// SPDX-License-Identifier: MPL-2.0

import SwiftUI
import UIKit

private struct RemoteClickSequence {
    private static let interval: TimeInterval = 0.5

    private var lastClickTime: Date?
    private var clickCount = 0

    mutating func registerClick(at now: Date = Date()) -> Int {
        guard let lastClickTime,
              now.timeIntervalSince(lastClickTime) <= Self.interval else {
            self.lastClickTime = now
            clickCount = 1
            return clickCount
        }

        clickCount += 1
        if clickCount >= 3 {
            reset()
            return 3
        }

        self.lastClickTime = now
        return clickCount
    }

    mutating func reset() {
        lastClickTime = nil
        clickCount = 0
    }
}

struct RemotePointerSurface: View {
    @ObservedObject var model: ClientModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isHidden: Bool
    private var displayedPosition: CGPoint {
        if let pointer = model.computerUse.remotePointer { return CGPoint(x: pointer.x, y: pointer.y) }
        return model.pointerPosition
    }

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .overlay(alignment: .topLeading) {
                    if model.computerUse.showsPointer(manualEnabled: model.showRemotePointer, controlsHidden: isHidden) {
                        pointerReticle(in: proxy.size)
                    }
                }
                .accessibilityLabel("Remote pointer surface")
        }
    }

    private func pointerReticle(in size: CGSize) -> some View {
        Circle()
            .strokeBorder(.blue, lineWidth: 2)
            .background(Circle().fill(.blue.opacity(0.18)))
            .frame(width: 22, height: 22)
            .offset(
                x: size.width * displayedPosition.x - 11,
                y: size.height * displayedPosition.y - 11
            )
            .opacity(model.isConnected ? 1 : 0)
            .animation(model.computerUse.showsAIControls && !reduceMotion ? .easeOut(duration: 0.16) : nil,
                       value: displayedPosition)
            .allowsHitTesting(false)
    }
}

struct RemoteGestureLayer: UIViewRepresentable {
    @ObservedObject var model: ClientModel
    @Binding var zoomScale: CGFloat
    @Binding var zoomOffset: CGSize
    let viewportSize: CGSize
    let contentFrame: CGRect
    let isKeyboardInputActive: Bool

    func makeUIView(context: Context) -> UIView {
        let view = RemoteInputUIView(coordinator: context.coordinator)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pointerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePointerPan(_:)))
        pointerPan.minimumNumberOfTouches = 1
        pointerPan.maximumNumberOfTouches = 1
        pointerPan.cancelsTouchesInView = false

        let zoomPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleZoomPan(_:)))
        zoomPan.minimumNumberOfTouches = 2
        zoomPan.maximumNumberOfTouches = 2
        zoomPan.cancelsTouchesInView = false

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.cancelsTouchesInView = false

        let resetTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleResetTap(_:)))
        resetTap.numberOfTapsRequired = 2
        resetTap.numberOfTouchesRequired = 2
        resetTap.cancelsTouchesInView = false

        let pointerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePointerTap(_:)))
        pointerTap.numberOfTapsRequired = 1
        pointerTap.numberOfTouchesRequired = 1
        pointerTap.cancelsTouchesInView = false
        pointerTap.require(toFail: resetTap)

        view.addGestureRecognizer(pointerPan)
        view.addGestureRecognizer(zoomPan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(resetTap)
        view.addGestureRecognizer(pointerTap)

        if #available(iOS 13.4, *) {
            pointerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pointerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

            let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePointerHover(_:)))
            hover.cancelsTouchesInView = false

            let primaryClick = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePrimaryPointerClick(_:)))
            primaryClick.numberOfTapsRequired = 1
            primaryClick.numberOfTouchesRequired = 0
            primaryClick.buttonMaskRequired = .primary
            primaryClick.cancelsTouchesInView = false

            let secondaryClick = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSecondaryPointerClick(_:)))
            secondaryClick.numberOfTapsRequired = 1
            secondaryClick.numberOfTouchesRequired = 0
            secondaryClick.buttonMaskRequired = .secondary
            secondaryClick.cancelsTouchesInView = false

            let pointerDrag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleIndirectPointerDrag(_:)))
            pointerDrag.minimumNumberOfTouches = 1
            pointerDrag.maximumNumberOfTouches = 1
            pointerDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            pointerDrag.cancelsTouchesInView = false

            let indirectScroll = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleIndirectScroll(_:)))
            indirectScroll.minimumNumberOfTouches = 0
            indirectScroll.maximumNumberOfTouches = 0
            indirectScroll.allowedScrollTypesMask = [.continuous, .discrete]
            indirectScroll.cancelsTouchesInView = false

            view.addGestureRecognizer(hover)
            view.addGestureRecognizer(primaryClick)
            view.addGestureRecognizer(secondaryClick)
            view.addGestureRecognizer(pointerDrag)
            view.addGestureRecognizer(indirectScroll)
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        (uiView as? RemoteInputUIView)?.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: RemoteGestureLayer
        private var panStartOffset = CGSize.zero
        private var pinchStartScale: CGFloat = 1
        private var pinchAnchor = CGPoint.zero
        private var isPinching = false
        private var isIndirectPointerDragging = false
        private var lastScrollTranslation = CGPoint.zero
        private var primaryClickSequence = RemoteClickSequence()
        private var secondaryClickSequence = RemoteClickSequence()

        init(parent: RemoteGestureLayer) {
            self.parent = parent
        }

        @MainActor @objc func handlePointerPan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.model.isInputReady else { return }
            let location = recognizer.location(in: recognizer.view)
            parent.model.movePointer(to: normalizedRemotePoint(for: location))
        }

        @MainActor @objc func handlePointerTap(_ recognizer: UITapGestureRecognizer) {
            guard parent.model.isInputReady else { return }
            let location = recognizer.location(in: recognizer.view)
            parent.model.movePointer(to: normalizedRemotePoint(for: location))
        }

        @MainActor @objc func handlePointerHover(_ recognizer: UIHoverGestureRecognizer) {
            guard parent.model.isInputReady else { return }

            switch recognizer.state {
            case .began, .changed:
                let location = recognizer.location(in: recognizer.view)
                parent.model.movePointer(to: normalizedRemotePoint(for: location))
            default:
                break
            }
        }

        @MainActor @objc func handlePrimaryPointerClick(_ recognizer: UITapGestureRecognizer) {
            guard parent.model.isInputReady else { return }
            let location = recognizer.location(in: recognizer.view)
            parent.model.movePointer(to: normalizedRemotePoint(for: location))
            parent.model.click(.left, clickCount: primaryClickSequence.registerClick())
        }

        @MainActor @objc func handleSecondaryPointerClick(_ recognizer: UITapGestureRecognizer) {
            guard parent.model.isInputReady else { return }
            let location = recognizer.location(in: recognizer.view)
            parent.model.movePointer(to: normalizedRemotePoint(for: location))
            parent.model.click(.right, clickCount: secondaryClickSequence.registerClick())
        }

        @MainActor @objc func handleIndirectPointerDrag(_ recognizer: UIPanGestureRecognizer) {
            guard parent.model.isInputReady else {
                finishIndirectPointerDragIfNeeded()
                return
            }

            let location = recognizer.location(in: recognizer.view)
            let position = normalizedRemotePoint(for: location)

            switch recognizer.state {
            case .began:
                parent.model.movePointer(to: position)
                parent.model.mouseDown(.left)
                isIndirectPointerDragging = true
            case .changed:
                parent.model.movePointer(to: position)
            case .ended, .cancelled, .failed:
                parent.model.movePointer(to: position)
                finishIndirectPointerDragIfNeeded()
            default:
                break
            }
        }

        @MainActor @objc func handleIndirectScroll(_ recognizer: UIPanGestureRecognizer) {
            guard parent.model.isInputReady else { return }

            let translation = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                lastScrollTranslation = translation
            case .changed:
                let deltaX = translation.x - lastScrollTranslation.x
                let deltaY = translation.y - lastScrollTranslation.y
                lastScrollTranslation = translation
                parent.model.scroll(deltaX: Double(-deltaX), deltaY: Double(-deltaY))
            case .ended, .cancelled, .failed:
                lastScrollTranslation = .zero
            default:
                break
            }
        }

        @MainActor @objc func handleZoomPan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.zoomScale > 1, !isPinching else { return }

            switch recognizer.state {
            case .began:
                panStartOffset = parent.zoomOffset
            case .changed:
                let translation = recognizer.translation(in: recognizer.view)
                let next = CGSize(
                    width: panStartOffset.width + translation.x,
                    height: panStartOffset.height + translation.y
                )
                parent.zoomOffset = clamped(offset: next, scale: parent.zoomScale)
            case .ended, .cancelled, .failed:
                parent.zoomOffset = clamped(offset: parent.zoomOffset, scale: parent.zoomScale)
            default:
                break
            }
        }

        @MainActor @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard let location = twoTouchLocation(from: recognizer) else { return }
                isPinching = true
                pinchStartScale = parent.zoomScale
                pinchAnchor = contentPoint(for: location)
            case .changed:
                guard isPinching, let location = twoTouchLocation(from: recognizer) else { return }
                let nextScale = min(max(pinchStartScale * recognizer.scale, 1), 4)
                parent.zoomScale = nextScale
                parent.zoomOffset = clamped(offset: offsetKeeping(anchor: pinchAnchor, under: location, scale: nextScale), scale: nextScale)
            case .ended, .cancelled, .failed:
                isPinching = false
                if parent.zoomScale < 1.04 {
                    resetZoom()
                } else {
                    parent.zoomOffset = clamped(offset: parent.zoomOffset, scale: parent.zoomScale)
                }
            default:
                break
            }
        }

        @MainActor @objc func handleResetTap(_ recognizer: UITapGestureRecognizer) {
            resetZoom()
        }

        private func normalizedRemotePoint(for location: CGPoint) -> CGPoint {
            let point = contentPoint(for: location)
            guard parent.contentFrame.width > 0, parent.contentFrame.height > 0 else {
                return CGPoint(x: 0.5, y: 0.5)
            }

            return CGPoint(
                x: min(max(point.x / parent.contentFrame.width, 0), 1),
                y: min(max(point.y / parent.contentFrame.height, 0), 1)
            )
        }

        private func contentPoint(for location: CGPoint) -> CGPoint {
            let center = CGPoint(x: parent.contentFrame.midX, y: parent.contentFrame.midY)
            let contentCenter = CGPoint(x: parent.contentFrame.width / 2, y: parent.contentFrame.height / 2)
            let scale = max(parent.zoomScale, 1)
            return CGPoint(
                x: ((location.x - center.x - parent.zoomOffset.width) / scale) + contentCenter.x,
                y: ((location.y - center.y - parent.zoomOffset.height) / scale) + contentCenter.y
            )
        }

        private func offsetKeeping(anchor: CGPoint, under location: CGPoint, scale: CGFloat) -> CGSize {
            let center = CGPoint(x: parent.contentFrame.midX, y: parent.contentFrame.midY)
            let contentCenter = CGPoint(x: parent.contentFrame.width / 2, y: parent.contentFrame.height / 2)
            return CGSize(
                width: location.x - center.x - ((anchor.x - contentCenter.x) * scale),
                height: location.y - center.y - ((anchor.y - contentCenter.y) * scale)
            )
        }

        private func twoTouchLocation(from recognizer: UIPinchGestureRecognizer) -> CGPoint? {
            guard recognizer.numberOfTouches >= 2, let view = recognizer.view else { return nil }
            let first = recognizer.location(ofTouch: 0, in: view)
            let second = recognizer.location(ofTouch: 1, in: view)
            return CGPoint(
                x: (first.x + second.x) / 2,
                y: (first.y + second.y) / 2
            )
        }

        private func clamped(offset: CGSize, scale: CGFloat) -> CGSize {
            guard scale > 1 else { return .zero }
            let scaledWidth = parent.contentFrame.width * scale
            let scaledHeight = parent.contentFrame.height * scale
            let fittedFrameMaxX = (parent.contentFrame.width * (scale - 1)) / 2
            let fittedFrameMaxY = (parent.contentFrame.height * (scale - 1)) / 2
            let viewportMaxX = max((scaledWidth - parent.viewportSize.width) / 2, 0)
            let viewportMaxY = max((scaledHeight - parent.viewportSize.height) / 2, 0)
            let maxX = max(fittedFrameMaxX, viewportMaxX)
            let maxY = max(fittedFrameMaxY, viewportMaxY)
            return CGSize(
                width: min(max(offset.width, -maxX), maxX),
                height: min(max(offset.height, -maxY), maxY)
            )
        }

        @MainActor
        private func resetZoom() {
            parent.zoomScale = 1
            parent.zoomOffset = .zero
            parent.model.resetZoomRegion()
        }

        @MainActor
        private func finishIndirectPointerDragIfNeeded() {
            guard isIndirectPointerDragging else { return }
            parent.model.mouseUp(.left)
            isIndirectPointerDragging = false
        }

        @MainActor
        @available(iOS 13.4, *)
        func sendHardwareKey(_ key: UIKey, isDown: Bool) {
            guard parent.model.isInputReady,
                  let keyCode = MacHardwareKeyMapper.keyCode(for: key.keyCode) else {
                return
            }

            let modifiers = MacHardwareKeyMapper.modifiers(for: key.modifierFlags)
            parent.model.send(.key(isDown ? .keyDown : .keyUp, keyCode: keyCode, modifiers: modifiers))
        }
    }

    final class RemoteInputUIView: UIView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var canBecomeFirstResponder: Bool {
            // The canvas needs focus for hardware keys only when the typing
            // accessory isn't using it. Touch gestures work without focus.
            coordinator?.parent.isKeyboardInputActive == false
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, canBecomeFirstResponder {
                becomeFirstResponder()
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if canBecomeFirstResponder {
                becomeFirstResponder()
            }
            super.touchesBegan(touches, with: event)
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard handle(presses, isDown: true) else {
                super.pressesBegan(presses, with: event)
                return
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard handle(presses, isDown: false) else {
                super.pressesEnded(presses, with: event)
                return
            }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            _ = handle(presses, isDown: false)
            super.pressesCancelled(presses, with: event)
        }

        @MainActor
        private func handle(_ presses: Set<UIPress>, isDown: Bool) -> Bool {
            guard let coordinator else { return false }
            var didHandle = false

            if #available(iOS 13.4, *) {
                for press in presses {
                    guard let key = press.key else { continue }
                    coordinator.sendHardwareKey(key, isDown: isDown)
                    didHandle = true
                }
            }

            return didHandle
        }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        return CGPoint(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1)
        )
    }
}

@available(iOS 13.4, *)
private enum MacHardwareKeyMapper {
    static func modifiers(for flags: UIKeyModifierFlags) -> UInt64 {
        var modifiers: UInt64 = 0

        if flags.contains(.alphaShift) {
            modifiers |= 0x0001_0000
        }
        if flags.contains(.shift) {
            modifiers |= ClientTextTyper.shiftModifier
        }
        if flags.contains(.control) {
            modifiers |= ClientTextTyper.controlModifier
        }
        if flags.contains(.alternate) {
            modifiers |= ClientTextTyper.optionModifier
        }
        if flags.contains(.command) {
            modifiers |= ClientTextTyper.commandModifier
        }

        return modifiers
    }

    static func keyCode(for usage: UIKeyboardHIDUsage) -> UInt16? {
        keyCodes[usage]
    }

    private static let keyCodes: [UIKeyboardHIDUsage: UInt16] = [
        .keyboardA: 0,
        .keyboardS: 1,
        .keyboardD: 2,
        .keyboardF: 3,
        .keyboardH: 4,
        .keyboardG: 5,
        .keyboardZ: 6,
        .keyboardX: 7,
        .keyboardC: 8,
        .keyboardV: 9,
        .keyboardB: 11,
        .keyboardQ: 12,
        .keyboardW: 13,
        .keyboardE: 14,
        .keyboardR: 15,
        .keyboardY: 16,
        .keyboardT: 17,
        .keyboard1: 18,
        .keyboard2: 19,
        .keyboard3: 20,
        .keyboard4: 21,
        .keyboard6: 22,
        .keyboard5: 23,
        .keyboardEqualSign: 24,
        .keyboard9: 25,
        .keyboard7: 26,
        .keyboardHyphen: 27,
        .keyboard8: 28,
        .keyboard0: 29,
        .keyboardCloseBracket: 30,
        .keyboardO: 31,
        .keyboardU: 32,
        .keyboardOpenBracket: 33,
        .keyboardI: 34,
        .keyboardP: 35,
        .keyboardReturnOrEnter: 36,
        .keyboardL: 37,
        .keyboardJ: 38,
        .keyboardQuote: 39,
        .keyboardK: 40,
        .keyboardSemicolon: 41,
        .keyboardBackslash: 42,
        .keyboardComma: 43,
        .keyboardSlash: 44,
        .keyboardN: 45,
        .keyboardM: 46,
        .keyboardPeriod: 47,
        .keyboardTab: 48,
        .keyboardSpacebar: 49,
        .keyboardGraveAccentAndTilde: 50,
        .keyboardDeleteOrBackspace: 51,
        .keyboardEscape: 53,
        .keyboardCapsLock: 57,
        .keypadPeriod: 65,
        .keypadAsterisk: 67,
        .keypadPlus: 69,
        .keypadSlash: 75,
        .keypadEnter: 76,
        .keypadHyphen: 78,
        .keypadEqualSign: 81,
        .keypad0: 82,
        .keypad1: 83,
        .keypad2: 84,
        .keypad3: 85,
        .keypad4: 86,
        .keypad5: 87,
        .keypad6: 88,
        .keypad7: 89,
        .keypad8: 91,
        .keypad9: 92,
        .keyboardF5: 96,
        .keyboardF6: 97,
        .keyboardF7: 98,
        .keyboardF3: 99,
        .keyboardF8: 100,
        .keyboardF9: 101,
        .keyboardF11: 103,
        .keyboardF13: 105,
        .keyboardF16: 106,
        .keyboardF14: 107,
        .keyboardF10: 109,
        .keyboardF12: 111,
        .keyboardF15: 113,
        .keyboardHelp: 114,
        .keyboardHome: 115,
        .keyboardPageUp: 116,
        .keyboardDeleteForward: 117,
        .keyboardF4: 118,
        .keyboardEnd: 119,
        .keyboardF2: 120,
        .keyboardPageDown: 121,
        .keyboardF1: 122,
        .keyboardLeftArrow: 123,
        .keyboardRightArrow: 124,
        .keyboardDownArrow: 125,
        .keyboardUpArrow: 126
    ]
}

struct RemoteScrollRail: View {
    @ObservedObject var model: ClientModel
    @State private var lastY: CGFloat?

    var body: some View {
        let lineColor = Color(.sRGB, white: model.scrollRailLineBrightness, opacity: 1)

        Capsule()
            .fill(.white.opacity(0.12))
            .overlay {
                Capsule()
                    .strokeBorder(lineColor.opacity(0.58), lineWidth: 1)
            }
            .overlay {
                VStack(spacing: 5) {
                    Image(systemName: "chevron.up")
                    RoundedRectangle(cornerRadius: 2)
                        .fill(lineColor.opacity(0.70))
                        .frame(width: 4, height: 34)
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(lineColor.opacity(0.72))
            }
            .frame(width: 22, height: 156)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let lastY {
                            let delta = value.location.y - lastY
                            model.scroll(deltaY: Double(-delta * 8))
                        }
                        lastY = value.location.y
                    }
                    .onEnded { _ in
                        lastY = nil
                    }
            )
            .opacity(model.isInputReady ? 1 : 0.28)
            .disabled(!model.isInputReady)
            .accessibilityLabel("Remote scroll")
            .viewerHelpTarget(.scroll)
            .animation(.easeInOut(duration: 0.16), value: model.scrollRailLineBrightness)
    }
}

struct RemoteClickBar: View {
    @ObservedObject var model: ClientModel
    let isCompact: Bool

    var body: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            RemoteMouseButtonControl(
                model: model,
                systemImage: "cursorarrow.click",
                button: .left,
                label: "Left click",
                size: CGSize(width: isCompact ? 48 : 52, height: isCompact ? 38 : 46),
                supportsClickDrag: true
            )
            RemoteMouseButtonControl(
                model: model,
                systemImage: "cursorarrow.click.2",
                button: .right,
                label: "Right click",
                size: CGSize(width: isCompact ? 48 : 52, height: isCompact ? 38 : 46),
                supportsClickDrag: false
            )
        }
        .font(.system(size: isCompact ? 18 : 19, weight: .semibold))
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 8 : 10)
        .background(.black.opacity(0.58), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    static func dragExclusionRects(isCompact: Bool) -> [CGRect] {
        let buttonSize = CGSize(width: isCompact ? 48 : 52, height: isCompact ? 38 : 46)
        let spacing: CGFloat = isCompact ? 8 : 12
        let horizontalPadding: CGFloat = isCompact ? 8 : 10
        let verticalPadding: CGFloat = isCompact ? 8 : 10

        return [
            CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: buttonSize.width,
                height: buttonSize.height
            ),
            CGRect(
                x: horizontalPadding + buttonSize.width + spacing,
                y: verticalPadding,
                width: buttonSize.width,
                height: buttonSize.height
            )
        ]
    }
}

struct RemoteKeyboardClickRail: View {
    @ObservedObject var model: ClientModel

    var body: some View {
        VStack(spacing: 5) {
            RemoteMouseButtonControl(
                model: model,
                systemImage: "cursorarrow.click",
                button: .left,
                label: "Left click",
                size: CGSize(width: 36, height: 32),
                supportsClickDrag: true
            )
            RemoteMouseButtonControl(
                model: model,
                systemImage: "cursorarrow.click.2",
                button: .right,
                label: "Right click",
                size: CGSize(width: 36, height: 32),
                supportsClickDrag: false
            )
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(.black.opacity(0.58), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .opacity(model.isInputReady ? 1 : 0.28)
        .disabled(!model.isInputReady)
        .accessibilityElement(children: .contain)
    }

    static let dragExclusionRects: [CGRect] = {
        let buttonSize = CGSize(width: 36, height: 32)
        let spacing: CGFloat = 5
        let horizontalPadding: CGFloat = 5
        let verticalPadding: CGFloat = 5

        return [
            CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: buttonSize.width,
                height: buttonSize.height
            ),
            CGRect(
                x: horizontalPadding,
                y: verticalPadding + buttonSize.height + spacing,
                width: buttonSize.width,
                height: buttonSize.height
            )
        ]
    }()
}

struct RemoteMouseButtonControl: View {
    @ObservedObject var model: ClientModel
    let systemImage: String
    let button: ClientRemoteMouseButton
    let label: String
    let size: CGSize
    let supportsClickDrag: Bool

    @State private var isPressed = false
    @State private var isDraggingClick = false
    @State private var dragStartPointer = CGPoint(x: 0.5, y: 0.5)
    @State private var pressStartTime: Date?
    @State private var clickSequence = RemoteClickSequence()
    @State private var longPressTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .frame(width: size.width, height: size.height)
            .foregroundStyle(.white)
            .background(backgroundShape)
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(isDraggingClick ? 0.38 : 0.18), lineWidth: 1)
            )
            .scaleEffect(isPressed || isDraggingClick ? 0.96 : 1)
            .contentShape(Rectangle())
            .gesture(pressGesture)
            .opacity(model.isInputReady ? 1 : 0.35)
            .accessibilityLabel(supportsClickDrag ? "\(label), hold and drag to drag" : label)
            .viewerHelpTarget(button == .left ? .leftClick : .rightClick)
            .animation(.snappy(duration: 0.12), value: isPressed)
            .animation(.snappy(duration: 0.16), value: isDraggingClick)
    }

    private var backgroundShape: some View {
        Capsule()
            .fill(buttonColor.opacity(isDraggingClick ? 1 : (isPressed ? 0.82 : 0.68)))
    }

    private var buttonColor: Color {
        button == .left ? .blue : .indigo
    }

    private var activeScreenSize: CGSize {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
            .first ?? CGSize(width: 390, height: 844)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard model.isInputReady else { return }

                if pressStartTime == nil {
                    pressStartTime = Date()
                    dragStartPointer = model.currentPointerPosition
                    isPressed = true
                    armClickDragIfSupported()
                }

                if supportsClickDrag,
                   !isDraggingClick,
                   let pressStartTime,
                   Date().timeIntervalSince(pressStartTime) >= 0.22 {
                    beginClickDragIfNeeded()
                }

                if isDraggingClick {
                    model.movePointer(
                        from: dragStartPointer,
                        screenTranslation: value.translation,
                        screenSize: activeScreenSize
                    )
                }
            }
            .onEnded { _ in
                guard model.isInputReady else {
                    resetPressState()
                    return
                }

                if isDraggingClick {
                    finishClickDragIfNeeded()
                } else {
                    model.click(button, clickCount: clickSequence.registerClick())
                    resetPressState()
                }
            }
    }

    private func beginClickDragIfNeeded() {
        guard !isDraggingClick else { return }
        clickSequence.reset()
        isPressed = true
        isDraggingClick = true
        dragStartPointer = model.currentPointerPosition
        model.mouseDown(button)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finishClickDragIfNeeded() {
        guard isDraggingClick else {
            isPressed = false
            return
        }
        model.mouseUp(button)
        isDraggingClick = false
        resetPressState()
    }

    private func resetPressState() {
        longPressTask?.cancel()
        longPressTask = nil
        isPressed = false
        isDraggingClick = false
        pressStartTime = nil
    }

    private func armClickDragIfSupported() {
        guard supportsClickDrag else { return }
        longPressTask?.cancel()
        longPressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, model.isInputReady, pressStartTime != nil else { return }
            beginClickDragIfNeeded()
        }
    }
}
