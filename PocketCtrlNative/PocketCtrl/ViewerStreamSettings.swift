// SPDX-License-Identifier: MPL-2.0

import Foundation

// Keep the quality curve aligned with ClientStreamSettings; parity is tested.
enum ViewerStreamPreset: String, Codable, CaseIterable, Identifiable {
    case dataSaver
    case balanced
    case smooth
    case max
    case custom

    var id: String { rawValue }

    /// Legacy presets retained for saved-setting migration and wire compatibility.
    static let presets: [ViewerStreamPreset] = [.dataSaver, .balanced, .smooth, .max]

    var title: String {
        switch self {
        case .dataSaver: return "Saver"
        case .balanced: return "Balanced"
        case .smooth: return "Smooth"
        case .max: return "Max"
        case .custom: return "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .dataSaver:
            return "Lowest data use for cellular."
        case .balanced:
            return "Lower data with clear screen detail."
        case .smooth:
            return "Highest frame rate for motion, moderate detail."
        case .max:
            return "Best picture. The app can still back off if needed."
        case .custom:
            return "Your own detail and frame rate."
        }
    }

    var settings: ViewerStreamSettings {
        switch self {
        case .dataSaver: return ViewerStreamSettings(detail: .reduced, frameRate: 20)
        case .balanced, .custom: return ViewerStreamSettings(detail: .standard, frameRate: 30)
        case .smooth: return ViewerStreamSettings(detail: .standard, frameRate: 60)
        case .max: return ViewerStreamSettings(detail: .full, frameRate: 60)
        }
    }
}

/// Screen detail: the capture width cap and the bitrate budget at 30 fps.
enum ViewerStreamDetailLevel: Int, CaseIterable, Identifiable {
    case low = 1
    case reduced
    case standard
    case high
    case full

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .reduced: return "Reduced"
        case .standard: return "Standard"
        case .high: return "High"
        case .full: return "Full"
        }
    }

    /// "Full" leaves resolution to the host, within the protocol's safety cap.
    var maximumCaptureWidth: Int {
        switch self {
        case .low: return 992
        case .reduced: return 1_280
        case .standard: return 1_600
        case .high: return 1_920
        case .full: return 16_384
        }
    }

    var widthDescription: String {
        self == .full ? "Mac's capture limit" : "up to \(maximumCaptureWidth) px"
    }

    /// Bitrate budget at 30 fps. The frame-rate factor scales it.
    var baseBitrate: Int {
        switch self {
        case .low: return 1_708_000
        case .reduced: return 2_500_000
        case .standard: return 6_000_000
        case .high: return 8_000_000
        case .full: return 20_000_000
        }
    }
}

struct ViewerStreamSettings: Equatable {
    static let frameRateRange = 3.0...60.0
    private static let profileKey = "PocketCtrl.viewerQualityProfile"
    private static let detailKey = "PocketCtrl.viewerStreamDetailLevel"
    private static let detailAmountKey = "PocketCtrl.viewerStreamDetailAmount"
    private static let frameRateKey = "PocketCtrl.viewerStreamFrameRate"

    var detailAmount: Double
    var frameRate: Double

    init(detailAmount: Double, frameRate: Double) {
        self.detailAmount = Self.clamp(detailAmount, to: 0...1, fallback: 0.5)
        self.frameRate = Self.clamp(frameRate, to: Self.frameRateRange, fallback: 30)
    }

    init(detail: ViewerStreamDetailLevel, frameRate: Double) {
        self.init(detailAmount: Double(detail.rawValue - 1) / 4, frameRate: frameRate)
    }

    // Compatibility with preset-based callers; the sliders never snap to this.
    var detail: ViewerStreamDetailLevel {
        get { ViewerStreamDetailLevel(rawValue: Int((normalizedDetail * 4).rounded()) + 1) ?? .standard }
        set { detailAmount = Double(newValue.rawValue - 1) / 4 }
    }

    private var normalizedDetail: Double { Self.clamp(detailAmount, to: 0...1, fallback: 0.5) }
    private var normalizedFPS: Double { (Self.clamp(frameRate, to: Self.frameRateRange, fallback: 30) - Self.frameRateRange.lowerBound) / (Self.frameRateRange.upperBound - Self.frameRateRange.lowerBound) }
    var maximumFrameRate: Int { Int(Self.clamp(frameRate, to: Self.frameRateRange, fallback: 30).rounded()) }
    var maximumCaptureWidth: Int {
        let width = Self.interpolate(normalizedDetail * 4, points: [0, 1, 2, 3, 4], values: [992, 1280, 1600, 1920, 16384])
        return Int(width.rounded()) / 2 * 2
    }

    var qualityTitle: String {
        let detail = normalizedDetail
        let fps = normalizedFPS
        if detail >= 0.9 && fps >= 0.9 { return "Max" }
        if fps - detail >= 0.2 { return "Smooth" }
        if detail - fps >= 0.2 { return "Sharp" }
        if (detail + fps) / 2 < 1.0 / 3 { return "Saver" }
        return "Balanced"
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private static func interpolate(_ value: Double, points: [Double], values: [Double]) -> Double {
        if value <= points[0] { return values[0] }
        for index in 1..<points.count where value <= points[index] {
            let fraction = (value - points[index - 1]) / (points[index] - points[index - 1])
            return values[index - 1] + (values[index] - values[index - 1]) * fraction
        }
        return values.last!
    }

    static func load(from defaults: UserDefaults) -> Self {
        let preset = defaults.string(forKey: profileKey).flatMap(ViewerStreamPreset.init(rawValue:)) ?? .balanced
        let savedDetail = defaults.object(forKey: detailKey) as? Int
        let savedRate = defaults.object(forKey: frameRateKey) as? Double
        let savedAmount = defaults.object(forKey: detailAmountKey) as? Double
        let legacyDetail = savedDetail.flatMap(ViewerStreamDetailLevel.init(rawValue:)) ?? preset.settings.detail
        return Self(
            detailAmount: savedAmount ?? Double(legacyDetail.rawValue - 1) / 4,
            frameRate: savedRate.flatMap { frameRateRange.contains($0) ? $0 : nil } ?? preset.settings.frameRate
        )
    }

    func save(to defaults: UserDefaults) {
        // Save the whole selection, even if only one slider changed. This also
        // migrates preset-only installs without losing the untouched slider.
        defaults.set(detail.rawValue, forKey: Self.detailKey)
        defaults.set(normalizedDetail, forKey: Self.detailAmountKey)
        defaults.set(frameRate, forKey: Self.frameRateKey)
        defaults.set(matchingPreset.rawValue, forKey: Self.profileKey)
    }

    /// More frames need more bits for the same per-frame quality, so the
    /// budget grows with frame rate. 30 fps is the reference point.
    var maximumBitrate: Int {
        let base = Self.interpolate(normalizedDetail * 4, points: [0, 1, 2, 3, 4], values: [1_708_000, 2_500_000, 6_000_000, 8_000_000, 20_000_000])
        let factor = Self.interpolate(Self.clamp(frameRate, to: Self.frameRateRange, fallback: 30), points: [3, 5, 10, 15, 20, 30, 45, 60], values: [0.2, 1.0 / 3, 0.5, 0.7, 0.8, 1.0, 1.25, 1.5])
        return Int((base * factor).rounded())
    }

    /// The preset these sliders correspond to, if any.
    var matchingPreset: ViewerStreamPreset {
        ViewerStreamPreset.presets.first { $0.settings == self } ?? .custom
    }

    /// Nominal video budget, excluding audio and transport overhead.
    /// Static screens can use less; encoder peaks can use more.
    var estimatedMegabytesPerMinute: Double {
        Double(maximumBitrate) / 8 / 1_000_000 * 60
    }

    var estimatedUsageDescription: String {
        Self.usageDescription(megabitsPerSecond: Double(maximumBitrate) / 1_000_000)
    }

    static func usageDescription(megabitsPerSecond: Double) -> String {
        let perMinute = megabytesPerMinute(megabitsPerSecond: max(0, megabitsPerSecond))
        let perHour = perMinute * 60 / 1_000
        // Keep small budgets visible instead of rounding them to zero.
        let minuteText = perMinute > 0 && perMinute < 1
            ? String(format: "%.2f", perMinute)
            : String(Int(perMinute.rounded()))
        let hourText = String(format: perHour > 0 && perHour < 0.1 ? "%.3f" : "%.1f", perHour)
        return "\(minuteText) MB/min · \(hourText) GB/hr"
    }

    static func megabytesPerMinute(megabitsPerSecond: Double) -> Double {
        megabitsPerSecond / 8 * 60
    }
}
