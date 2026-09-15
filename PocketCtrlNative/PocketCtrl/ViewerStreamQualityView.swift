// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct MacViewerTopBarQualityMenu: View {
    @ObservedObject var model: RemoteDesktopModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(model.viewerStreamSettings.qualityTitle)
                    .lineLimit(1)
                    // The popover tracks this button's bounds. Reserve space
                    // for every quality name so slider changes cannot move it.
                    .frame(width: 60, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.070), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Stream Quality")
        .accessibilityLabel("Stream Quality")
        .accessibilityValue(model.viewerStreamSettings.qualityTitle)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MacViewerStreamQualityView(model: model)
                .padding(18)
                .frame(width: 340)
                .background(Color(red: 0.035, green: 0.035, blue: 0.045))
                .preferredColorScheme(.dark)
        }
        .fixedSize()
    }
}

struct MacViewerStreamQualityView: View {
    @ObservedObject var model: RemoteDesktopModel

    private var settings: ViewerStreamSettings { model.viewerStreamSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Stream Quality")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(settings.qualityTitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .frame(width: 70, alignment: .trailing)
            }

            MacStreamSliderRow(title: "Detail", value: "\(Int((settings.detailAmount * 100).rounded()))%", selection: $model.viewerDetailAmount, range: 0...1)
            MacStreamSliderRow(title: "FPS", value: "\(settings.maximumFrameRate)", selection: $model.viewerFrameRate, range: ViewerStreamSettings.frameRateRange)

            VStack(spacing: 6) {
                usageRow("Video budget", value: settings.estimatedUsageDescription)
                usageRow("Live video", value: model.isViewing ? ViewerStreamSettings.usageDescription(megabitsPerSecond: model.viewerBitrateMbps) : "—")
            }
            .font(.caption)
        }
    }

    private func usageRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
        }
    }
}

private struct MacStreamSliderRow: View {
    let title: String
    let value: String
    @Binding var selection: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .foregroundStyle(.white.opacity(0.76))
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(.white.opacity(0.62))
                    .monospacedDigit()
            }
            .font(.subheadline)

            Slider(value: $selection, in: range)
                .tint(.blue)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
        .padding(.vertical, 2)
    }
}
