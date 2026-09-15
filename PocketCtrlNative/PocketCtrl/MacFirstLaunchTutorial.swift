// SPDX-License-Identifier: MPL-2.0

import SwiftUI

enum MacTutorialTarget: Hashable {
    case host
    case connect
}

struct MacTutorialTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [MacTutorialTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [MacTutorialTarget: Anchor<CGRect>],
        nextValue: () -> [MacTutorialTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct MacFirstLaunchTutorialOverlay: View {
    let hostFrame: CGRect
    let connectFrame: CGRect
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = TutorialLayout(
                size: proxy.size,
                hostFrame: hostFrame,
                connectFrame: connectFrame
            )

            ZStack {
                MacTutorialScrim(
                    cutouts: [
                        hostFrame.insetBy(dx: -8, dy: -7),
                        connectFrame.insetBy(dx: -9, dy: -8)
                    ]
                )
                .fill(.black.opacity(0.72), style: FillStyle(eoFill: true))

                spotlight(frame: hostFrame, cornerRadius: 13)
                spotlight(frame: connectFrame, cornerRadius: 24)

                MacTutorialArrow(
                    start: layout.hostArrowStart,
                    end: CGPoint(x: hostFrame.midX, y: hostFrame.maxY + 2),
                    isCurved: false
                )

                MacTutorialArrow(
                    start: layout.connectArrowStart,
                    end: layout.connectArrowEnd,
                    isCurved: true
                )

                MacTutorialCallout(
                    step: 1,
                    title: "Host this Mac",
                    message: "Choose Host to let another device view and control this Mac."
                )
                .frame(width: 300)
                .position(layout.hostCalloutCenter)

                MacTutorialCallout(
                    step: 2,
                    title: "Connect to another Mac",
                    message: "Choose Connect a new Mac to view and control another computer from here."
                )
                .frame(width: 340)
                .position(layout.connectCalloutCenter)

                VStack(spacing: 10) {
                    Text("Choose how you want to use PocketCtrl")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("You can switch between hosting and connecting at any time.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))

                    Button("Got it", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.38), radius: 24, y: 12)
                .position(x: proxy.size.width / 2, y: proxy.size.height - 100)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func spotlight(frame: CGRect, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(.blue, lineWidth: 3)
            .shadow(color: .blue.opacity(0.85), radius: 12)
            .frame(width: frame.width + 16, height: frame.height + 14)
            .position(x: frame.midX, y: frame.midY)
    }
}

private struct TutorialLayout {
    let size: CGSize
    let hostFrame: CGRect
    let connectFrame: CGRect

    private let hostCalloutSize = CGSize(width: 300, height: 94)
    private let connectCalloutSize = CGSize(width: 340, height: 94)

    var hostCalloutCenter: CGPoint {
        CGPoint(
            x: clamped(
                hostFrame.midX - 110,
                minimum: hostCalloutSize.width / 2 + 20,
                maximum: size.width - hostCalloutSize.width / 2 - 20
            ),
            y: min(hostFrame.maxY + 92, 175)
        )
    }

    var connectCalloutCenter: CGPoint {
        CGPoint(
            x: clamped(
                connectFrame.midX,
                minimum: connectCalloutSize.width / 2 + 20,
                maximum: size.width - connectCalloutSize.width / 2 - 20
            ),
            y: connectCalloutIsBelow
                ? connectFrame.maxY + 88
                : connectFrame.minY - 88
        )
    }

    var hostArrowStart: CGPoint {
        CGPoint(
            x: hostCalloutCenter.x + hostCalloutSize.width * 0.31,
            y: hostCalloutCenter.y - hostCalloutSize.height / 2 + 2
        )
    }

    var connectArrowStart: CGPoint {
        CGPoint(
            x: connectCalloutCenter.x,
            y: connectCalloutCenter.y + (connectCalloutIsBelow ? -connectCalloutSize.height / 2 : connectCalloutSize.height / 2)
        )
    }

    var connectArrowEnd: CGPoint {
        CGPoint(
            x: connectFrame.midX,
            y: connectCalloutIsBelow ? connectFrame.maxY + 2 : connectFrame.minY - 2
        )
    }

    private var connectCalloutIsBelow: Bool {
        connectFrame.maxY + 190 < size.height - 205
    }

    private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

private struct MacTutorialCallout: View {
    let step: Int
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step)")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.blue, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 18, y: 9)
    }
}

private struct MacTutorialArrow: View {
    let start: CGPoint
    let end: CGPoint
    let isCurved: Bool

    var body: some View {
        Canvas { context, _ in
            let midpointY = (start.y + end.y) / 2
            let control1 = CGPoint(x: start.x, y: midpointY)
            let control2 = CGPoint(x: end.x, y: midpointY)

            var shaft = Path()
            shaft.move(to: start)
            if isCurved {
                shaft.addCurve(to: end, control1: control1, control2: control2)
            } else {
                shaft.addLine(to: end)
            }

            context.stroke(
                shaft,
                with: .color(.white.opacity(0.94)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [8, 6])
            )

            let fallback = CGVector(dx: end.x - start.x, dy: end.y - start.y)
            let curvedTangent = CGVector(dx: end.x - control2.x, dy: end.y - control2.y)
            let direction = normalized(isCurved ? curvedTangent : fallback)
            let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
            let arrowBase = CGPoint(x: end.x - direction.dx * 15, y: end.y - direction.dy * 15)

            var head = Path()
            head.move(to: CGPoint(x: arrowBase.x + perpendicular.dx * 7, y: arrowBase.y + perpendicular.dy * 7))
            head.addLine(to: end)
            head.addLine(to: CGPoint(x: arrowBase.x - perpendicular.dx * 7, y: arrowBase.y - perpendicular.dy * 7))

            context.stroke(
                head,
                with: .color(.white),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }

    private func normalized(_ vector: CGVector) -> CGVector {
        let length = max(hypot(vector.dx, vector.dy), 0.001)
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }
}

private struct MacTutorialScrim: Shape {
    let cutouts: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)

        for cutout in cutouts {
            path.addRoundedRect(
                in: cutout,
                cornerSize: CGSize(width: 18, height: 18)
            )
        }

        return path
    }
}
