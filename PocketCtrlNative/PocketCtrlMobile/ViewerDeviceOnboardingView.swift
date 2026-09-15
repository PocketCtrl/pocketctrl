// SPDX-License-Identifier: MPL-2.0

import SwiftUI
import UIKit

struct ViewerDeviceOnboardingView: View {
    let onFinish: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var page = 0
    @State private var name = ""

    private let pageCount = 2

    var body: some View {
        ZStack {
            ConnectMeshBackground()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    OnboardingPage(
                        title: "Your Mac\nin your pocket.",
                        subtitle: "PocketCtrl is free and open source. View the code, learn from it, or help improve it.",
                        accessibilityLabel: "PocketCtrl is free and open source. View its source code on GitHub.",
                        maximumContentWidth: .infinity
                    ) {
                        PocketCtrlOpenSourceGraphic()
                    }
                    .tag(0)

                    OnboardingPage(
                        title: "Name this \(defaultDeviceName)",
                        subtitle: nil,
                        accessibilityLabel: "Choose the name your Mac will show for this \(defaultDeviceName)."
                    ) {
                        TextField(exampleDeviceName, text: $name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                            .tint(.white)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($isNameFocused)
                            .onSubmit(finish)
                            .accessibilityLabel("Device name")
                            .accessibilityHint("Leave blank to use \(defaultDeviceName)")
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .background(.black.opacity(0.28), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    }
                    .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : .snappy(duration: 0.38), value: page)

                onboardingFooter
            }
        }
        .statusBarHidden(true)
        .onChange(of: page) { _, newPage in
            guard newPage == pageCount - 1 else {
                isNameFocused = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.38)) {
                isNameFocused = true
            }
        }
    }

    private var onboardingFooter: some View {
        VStack(spacing: 2) {
            Button(action: advance) {
                Label(
                    page == pageCount - 1 ? "Finish Setup" : "Continue",
                    systemImage: page == pageCount - 1 ? "checkmark.circle.fill" : "arrow.right"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ConnectPrimaryButtonStyle())

            Link("Privacy Policy", destination: ClientLegalLinks.privacyPolicy)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .frame(minHeight: 44)
                .accessibilityHint("Opens the PocketCtrl privacy policy in your browser")
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var sanitizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var defaultDeviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private var exampleDeviceName: String {
        "My \(defaultDeviceName)"
    }

    private var resolvedName: String {
        sanitizedName.isEmpty ? defaultDeviceName : sanitizedName
    }

    private func advance() {
        if page < pageCount - 1 {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.38)) {
                page += 1
            }
        } else {
            finish()
        }
    }

    private func finish() {
        isNameFocused = false
        onFinish(resolvedName)
        dismiss()
    }
}

private struct PocketCtrlOpenSourceGraphic: View {
    private let repositoryURL = URL(string: "https://github.com/PocketCtrl/pocketctrl")!

    var body: some View {
        VStack(spacing: 28) {
            Image("demo_img")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                // Slightly enlarge the artwork within the page bounds.
                .scaleEffect(1.08)
                .clipped()
                .accessibilityHidden(true)

            Link(destination: repositoryURL) {
                Label("View on GitHub", systemImage: "arrow.up.right")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .accessibilityHint("Opens the PocketCtrl source code in your browser")
        }
        .frame(minHeight: 172)
    }
}

private struct OnboardingPage<Content: View>: View {
    let title: String
    let subtitle: String?
    let accessibilityLabel: String
    var maximumContentWidth: CGFloat = 540
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 36)

                    VStack(spacing: 10) {
                        Text(title)
                            .font(.system(size: 36, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.78)

                        if let subtitle {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.68))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 36)

                    VStack(spacing: 16) {
                        content()
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessibilityLabel)

                    Spacer(minLength: 36)
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: maximumContentWidth)
                .frame(minHeight: proxy.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct PocketCtrlTrafficDiagram: View {
    var body: some View {
        HStack(spacing: 12) {
            OnboardingDeviceNode(icon: "iphone.gen3", label: "iPhone")

            VStack(spacing: 15) {
                AnimatedSignalLane(label: "Controls", systemImage: "hand.tap.fill", direction: .forward)
                AnimatedSignalLane(label: "Screen + audio", systemImage: "display", direction: .reverse)
            }
            .frame(maxWidth: .infinity)

            OnboardingDeviceNode(icon: "desktopcomputer", label: "Mac")
        }
        .frame(minHeight: 166)
    }
}

private struct PocketCtrlPairingDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { timeline in
            let phase = reduceMotion ? 0.5 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8

            HStack(spacing: 10) {
                OnboardingDeviceNode(icon: "iphone.gen3", label: "iPhone")

                GeometryReader { proxy in
                    let centerX = proxy.size.width / 2
                    let lineWidth = max(proxy.size.width - 38, 1)

                    ZStack {
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .frame(height: 2)

                        Circle()
                            .fill(.white)
                            .frame(width: 7, height: 7)
                            .shadow(color: .blue.opacity(0.9), radius: 7)
                            .position(x: 19 + lineWidth * phase, y: proxy.size.height / 2)

                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .purple.opacity(0.62), radius: 10)
                            .scaleEffect(reduceMotion ? 1 : 1 + (sin(phase * .pi * 2) * 0.04))
                            .position(x: centerX, y: proxy.size.height / 2)
                    }
                }
                .frame(height: 70)

                OnboardingDeviceNode(icon: "desktopcomputer", label: "Mac")
            }
            .frame(minHeight: 132)
        }
    }
}

private struct OnboardingDeviceNode: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 78, height: 78)

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}

private struct AnimatedSignalLane: View {
    enum Direction: Equatable {
        case forward
        case reverse
    }

    let label: String
    let systemImage: String
    let direction: Direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { timeline in
            let rawPhase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let phase = reduceMotion ? 0.5 : (direction == .forward ? rawPhase : 1 - rawPhase)

            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage)
                    Text(label)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.15))
                            .frame(height: 2)

                        Image(systemName: direction == .forward ? "chevron.right" : "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.44))
                            .position(
                                x: direction == .forward ? proxy.size.width - 4 : 4,
                                y: proxy.size.height / 2
                            )

                        Circle()
                            .fill(.white)
                            .frame(width: 7, height: 7)
                            .shadow(color: direction == .forward ? .pink.opacity(0.9) : .blue.opacity(0.9), radius: 6)
                            .position(x: 5 + max(proxy.size.width - 10, 1) * phase, y: proxy.size.height / 2)
                    }
                }
                .frame(height: 12)
            }
        }
    }
}

#Preview {
    ViewerDeviceOnboardingView { _ in }
        .preferredColorScheme(.dark)
}
