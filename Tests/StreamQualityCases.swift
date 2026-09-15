var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    checks += 1
    print("PASS: \(label)")
}
func feedback(_ settings: ClientStreamSettings, fps: Int = 0, loss: Double = 0) throws -> ViewerFeedback {
    let mobile = ClientViewerFeedback(
        fps: fps, videoWidth: 1600, videoHeight: 900, receivedChunks: fps * 10,
        completedFrames: fps, skippedFrames: 0, estimatedLossPercent: loss,
        keyframeRequested: true, qualityProfile: settings.matchingPreset,
        maximumFrameRate: settings.maximumFrameRate, maximumBitrate: settings.maximumBitrate,
        maximumCaptureWidth: settings.maximumCaptureWidth
    )
    return try JSONDecoder().decode(ViewerFeedback.self, from: JSONEncoder().encode(mobile))
}
for preset in ClientStreamQualityProfile.presets {
    let settings = preset.settings
    let decoded = try feedback(settings)
    let hostPreset = ViewerQualityProfile(rawValue: preset.rawValue)!
    check(settings.matchingPreset == preset, "\(preset.title) round-trips through slider values")
    check(decoded.streamLimits.maximumFrameRate == hostPreset.maximumFrameRate, "\(preset.title) agrees on fps across platforms")
    check(decoded.streamLimits.maximumBitrate == hostPreset.maximumBitrate, "\(preset.title) agrees on bitrate across platforms")
    check(decoded.streamLimits.maximumCaptureWidth == min(16_384, hostPreset.maximumCaptureWidth), "\(preset.title) agrees on resolution across platforms")
}
let custom = ClientStreamSettings(detail: .high, frameRate: 45)
let customFeedback = try feedback(custom)
check(custom.matchingPreset == .custom, "Non-preset values show Custom")
check(customFeedback.qualityProfile == .balanced && customFeedback.streamLimits.maximumFrameRate == 45, "Custom wire profile safely falls back while explicit caps survive")
check(custom.estimatedMegabytesPerMinute == 75, "10 Mbps video budget equals 75 MB/min")
check(ClientStreamSettings.megabytesPerMinute(megabitsPerSecond: 8) == 60, "Measured Mbps conversion uses decimal megabytes")
let oldJSON = Data(#"{"fps":30,"videoWidth":1600,"videoHeight":900,"receivedChunks":10,"completedFrames":30,"skippedFrames":0,"estimatedLossPercent":0,"qualityProfile":"max"}"#.utf8)
let oldFeedback = try JSONDecoder().decode(ViewerFeedback.self, from: oldJSON)
check(oldFeedback.streamLimits == ViewerQualityProfile.max.limits, "Old preset-only viewers keep working")
let emptyJSON = Data(#"{"fps":0,"videoWidth":0,"videoHeight":0,"receivedChunks":0,"completedFrames":0,"skippedFrames":0,"estimatedLossPercent":0}"#.utf8)
let emptyFeedback = try JSONDecoder().decode(ViewerFeedback.self, from: emptyJSON)
check(emptyFeedback.streamLimits == ViewerQualityProfile.balanced.limits, "Missing profile defaults to Balanced")
let hostile = ViewerStreamLimits.custom(maximumBitrate: Int.max, maximumFrameRate: Int.max, maximumCaptureWidth: Int.max)
check(hostile.maximumBitrate == 100_000_000 && hostile.maximumFrameRate == 240 && hostile.maximumCaptureWidth == 16_384, "Extreme peer caps are bounded without overflow")
let negative = ViewerStreamLimits.custom(maximumBitrate: -1, maximumFrameRate: 0, maximumCaptureWidth: -1)
check(negative.maximumBitrate == 100_000 && negative.maximumFrameRate == 1 && negative.maximumCaptureWidth == 320, "Invalid negative caps are clamped")
check(negative.minimumBitrate <= negative.maximumBitrate && negative.idleFrameRate <= negative.maximumFrameRate, "Floors and idle pacing never exceed caps")

let saver = try feedback(ClientStreamQualityProfile.dataSaver.settings, fps: 20)
let aggregate = FeedbackAggregationFixture.aggregate(feedbacks: [customFeedback, saver], fallback: customFeedback)
check(aggregate.streamLimits.maximumFrameRate == 20 && aggregate.streamLimits.maximumBitrate == 2_000_000 && aggregate.streamLimits.maximumCaptureWidth == 1280, "Mixed viewers use the strictest cap in each dimension")
let opposite = FeedbackAggregationFixture.aggregate(feedbacks: [saver, customFeedback], fallback: saver)
check(aggregate.streamLimits == opposite.streamLimits, "Aggregation is independent of viewer order")
let consumed = FeedbackAggregationFixture.consumingKeyframeRequest(aggregate)
check(consumed.keyframeRequested == false && consumed.streamLimits == aggregate.streamLimits, "Consuming a keyframe request preserves custom limits")
let restored = FeedbackAggregationFixture.aggregate(feedbacks: [customFeedback], fallback: customFeedback)
check(restored.streamLimits.maximumFrameRate == 45, "Remaining viewer recovers its cap after a constrained viewer leaves")
let encodedAggregate = try JSONSerialization.jsonObject(with: JSONEncoder().encode(aggregate)) as! [String: Any]
check(encodedAggregate["resolvedLimits"] == nil, "Internal aggregate state is not sent on the wire")

for rate in 3...60 {
    var pacer = StreamFramePacer()
    let sent = (0..<600).filter { pacer.shouldSend(at: Double($0) / 60, frameRate: rate) }.count
    check(sent == rate * 10, "Timestamp pacing produces \(rate) fps from a 60 fps source")
}
var pacer = StreamFramePacer()
check((0..<300).filter { pacer.shouldSend(at: Double($0) / 30, frameRate: 45) }.count == 300, "A slower 30 fps source is not divided down again")
check(pacer.shouldSend(at: 30, frameRate: 45), "Long capture pause resumes immediately")
check(!pacer.shouldSend(at: 30, frameRate: 45), "No catch-up burst after a pause")
check(pacer.shouldSend(at: 0, frameRate: 45), "Capture timestamp reset resumes immediately")
check(!pacer.shouldSend(at: .nan, frameRate: 45), "Invalid timestamps are ignored")
check(pacer.shouldSend(at: 0.01, frameRate: 60), "Changing frame rate applies immediately")

let suite = "PocketCtrlStreamQualityTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(ClientStreamSettings.load(from: defaults) == ClientStreamQualityProfile.balanced.settings, "Fresh installs start Balanced")
defaults.set("max", forKey: "PocketCtrlMobile.streamQualityProfile")
var saved = ClientStreamSettings.load(from: defaults)
check(saved == ClientStreamQualityProfile.max.settings, "Existing Max preset migrates")
saved.frameRate = 45
saved.save(to: defaults)
check(ClientStreamSettings.load(from: defaults) == saved, "Changing only fps preserves the migrated detail after relaunch")
saved.detail = .low
saved.save(to: defaults)
check(ClientStreamSettings.load(from: defaults) == saved, "Changing only detail preserves the custom fps after relaunch")
defaults.set(-100, forKey: "PocketCtrlMobile.streamFrameRate")
check(ClientStreamSettings.frameRateRange.contains(ClientStreamSettings.load(from: defaults).frameRate), "Invalid stored fps falls back to a supported value")
let continuous = ClientStreamSettings(detailAmount: 0.6137, frameRate: 37.42)
continuous.save(to: defaults)
check(ClientStreamSettings.load(from: defaults) == continuous, "Fractional slider positions survive relaunch without snapping")
check(continuous.maximumFrameRate == 37, "Continuous FPS is rounded only for the host protocol")
let detailSamples = (0...1000).map { ClientStreamSettings(detailAmount: Double($0) / 1000, frameRate: 37).maximumBitrate }
check(zip(detailSamples, detailSamples.dropFirst()).allSatisfy { $0 < $1 }, "Every detail position increases the video budget without preset steps")
let fpsSamples = (0...570).map { ClientStreamSettings(detailAmount: 0.5, frameRate: 3 + Double($0) / 10).maximumBitrate }
check(zip(fpsSamples, fpsSamples.dropFirst()).allSatisfy { $0 < $1 }, "Budget changes continuously across the FPS range")
check(ClientStreamSettings(detailAmount: 0.26, frameRate: 30).maximumCaptureWidth > 1280, "Resolution interpolates between legacy levels")
for (detail, fps, title) in [(0.1, 20.0, "Saver"), (0.5, 30.0, "Balanced"), (0.5, 60.0, "Smooth"), (1.0, 30.0, "Sharp"), (0.95, 59.0, "Max")] {
    check(ClientStreamSettings(detailAmount: detail, frameRate: fps).qualityTitle == title, "Automatic quality label identifies \(title)")
}
check(ClientStreamSettings(detailAmount: 0.899, frameRate: 60).qualityTitle != "Max", "Max requires both sliders near full")
let invalid = ClientStreamSettings(detailAmount: .nan, frameRate: .infinity)
check(invalid.detailAmount == 0.5 && invalid.maximumFrameRate == 30, "Non-finite settings are sanitized")
let migratedSuite = "PocketCtrlQualityMigration.\(UUID().uuidString)"
let legacyDefaults = UserDefaults(suiteName: migratedSuite)!
defer { legacyDefaults.removePersistentDomain(forName: migratedSuite) }
legacyDefaults.set(4, forKey: "PocketCtrlMobile.streamDetailLevel")
legacyDefaults.set(45, forKey: "PocketCtrlMobile.streamFrameRate")
check(ClientStreamSettings.load(from: legacyDefaults) == ClientStreamSettings(detailAmount: 0.75, frameRate: 45), "Old stepped slider values migrate to exact continuous positions")

for adaptive in [false, true] {
    let host = QualityHostHarness()
    host.configuration.adaptiveBitrateEnabled = adaptive
    let state = host.updateAdaptiveVideoState(feedback: customFeedback)
    check(state.expectedFrameRate == 45, "45 fps honored with adaptive=\(adaptive)")
    check(state.bitrate <= custom.maximumBitrate && state.bitrate <= host.configuration.bitrate, "Both bitrate caps honored with adaptive=\(adaptive)")
    check(state.shouldRestartStreamForQuality, "Detail change refreshes capture with adaptive=\(adaptive)")
    let fpsOnly = try feedback(ClientStreamSettings(detail: .high, frameRate: 60))
    let changed = host.updateAdaptiveVideoState(feedback: fpsOnly)
    check(!changed.shouldRestartStreamForQuality && changed.shouldUpdateEncoderRateControl && changed.expectedFrameRate == 60, "FPS-only change updates encoder without restarting capture, adaptive=\(adaptive)")
    host.configuration.bitrate = 1_000_000
    let capped = host.updateAdaptiveVideoState(feedback: customFeedback)
    check(capped.bitrate <= 1_000_000, "Host cap stays below the adaptive quality floor, adaptive=\(adaptive)")
    host.configuration.fps = 24
    check(host.updateAdaptiveVideoState(feedback: customFeedback).expectedFrameRate <= 24, "Host fps remains authoritative, adaptive=\(adaptive)")
}
let host = QualityHostHarness()
_ = host.updateAdaptiveVideoState(feedback: try feedback(.init(detail: .full, frameRate: 60)))
let reduced = host.updateAdaptiveVideoState(feedback: try feedback(.init(detail: .low, frameRate: 15), fps: 10, loss: 20))
check(reduced.bitrate <= 1_195_600 && reduced.expectedFrameRate <= 15, "Loss and simultaneous slider reduction never exceed the new caps")
host.activeVideoCodec = .hevc
check(host.updateAdaptiveVideoState(feedback: customFeedback).bitrate <= 6_000_000, "HEVC budget stays within its scaled cap")
let idleHost = QualityHostHarness()
idleHost.isIdlePacingActive = true
let smooth = ClientStreamQualityProfile.smooth.settings
for _ in 0..<10 {
    _ = idleHost.updateAdaptiveVideoState(feedback: try feedback(smooth, fps: 30))
}
check(idleHost.adaptiveFrameStride == 1, "Smooth's idle 30 fps is not misclassified as a poor network")
idleHost.isIdlePacingActive = false
let resumed = idleHost.updateAdaptiveVideoState(feedback: try feedback(smooth))
check(resumed.expectedFrameRate == 60, "Motion resumes at 60 fps after intentional idle pacing")
let parity = (0...100).allSatisfy { detail in
    (3...60).allSatisfy { fps in
        let phone = ClientStreamSettings(detailAmount: Double(detail) / 100, frameRate: Double(fps))
        let mac = ViewerStreamSettings(detailAmount: Double(detail) / 100, frameRate: Double(fps))
        return phone.maximumFrameRate == mac.maximumFrameRate && phone.maximumBitrate == mac.maximumBitrate && phone.maximumCaptureWidth == mac.maximumCaptureWidth && phone.qualityTitle == mac.qualityTitle && phone.estimatedUsageDescription == mac.estimatedUsageDescription
    }
}
check(parity, "Mac and phone quality settings match across all 5,858 sampled combinations")
check(ClientStreamSettings.usageDescription(megabitsPerSecond: 8) == "60 MB/min · 3.6 GB/hr", "Usage includes MB/min and GB/hr")
check(ViewerStreamSettings.usageDescription(megabitsPerSecond: 0) == "0 MB/min · 0.0 GB/hr", "Idle live video formats correctly")
let macSuite = "PocketCtrlMacQualityTests.\(UUID().uuidString)"
let macDefaults = UserDefaults(suiteName: macSuite)!
defer { macDefaults.removePersistentDomain(forName: macSuite) }
macDefaults.set("smooth", forKey: "PocketCtrl.viewerQualityProfile")
check(ViewerStreamSettings.load(from: macDefaults) == ViewerStreamPreset.smooth.settings, "Mac migrates its existing quality preset")
let macSelection = ViewerStreamSettings(detailAmount: 0.731, frameRate: 47.4)
macSelection.save(to: macDefaults)
check(ViewerStreamSettings.load(from: macDefaults) == macSelection, "Mac fractional slider positions persist")
check(macDefaults.object(forKey: "PocketCtrlMobile.streamFrameRate") == nil, "Mac preferences stay separate from phone preferences")
let viewer = ViewerQualityFeedbackHarness()
viewer.setStreamSettings(macSelection)
viewer.sendInitialFeedback()
viewer.requestKeyframe()
check(viewer.inputSender.feedbacks.count == 3, "Mac sends updated quality, startup and recovery feedback")
check(viewer.inputSender.feedbacks.allSatisfy { $0.maximumFrameRate == 47 && $0.maximumBitrate == macSelection.maximumBitrate && $0.maximumCaptureWidth == macSelection.maximumCaptureWidth }, "All Mac feedback paths retain explicit slider limits")
let lowRate = ClientStreamSettings(detailAmount: 0, frameRate: 3)
check(lowRate.maximumBitrate == 341_600 && lowRate.qualityTitle == "Saver", "Minimum detail at 3 fps matches the previous 10% budget")
check(ClientStreamSettings(detailAmount: 0, frameRate: 5).maximumBitrate == 569_333, "Minimum detail at 5 fps matches the previous 10% budget")
check(ClientStreamSettings(detailAmount: 0, frameRate: 0).maximumFrameRate == 3, "FPS below the new minimum clamps to 3")
check(lowRate.maximumCaptureWidth == 992, "Minimum detail uses a 992-pixel capture width")
check(abs(lowRate.estimatedMegabytesPerMinute - 2.562) < 0.00001, "3 fps minimum video budget converts to approximately 2.562 MB/min")
check(lowRate.estimatedUsageDescription == "3 MB/min · 0.2 GB/hr", "Minimum video budget uses the existing rounded readout")
check(ClientStreamSettings.usageDescription(megabitsPerSecond: 0.1) == "0.75 MB/min · 0.045 GB/hr", "Small live video budgets retain useful precision")
check(ViewerStreamSettings.usageDescription(megabitsPerSecond: 0.06) == "0.45 MB/min · 0.027 GB/hr", "Low live HEVC usage stays visible")
let lowDetailCurve = (0...25).map { ClientStreamSettings(detailAmount: Double($0) / 100, frameRate: 3) }
check(zip(lowDetailCurve, lowDetailCurve.dropFirst()).allSatisfy {
    $0.maximumBitrate < $1.maximumBitrate && $0.maximumCaptureWidth < $1.maximumCaptureWidth
}, "Low-detail range increases progressively without a dead zone")
let lowFeedback = try feedback(lowRate)
check(lowFeedback.streamLimits.maximumBitrate == 341_600 && lowFeedback.streamLimits.maximumCaptureWidth == 992, "Host decodes minimum detail without inflating the budget")
let lowAggregate = FeedbackAggregationFixture.aggregate(feedbacks: [customFeedback, lowFeedback], fallback: customFeedback)
check(lowAggregate.streamLimits.maximumBitrate == 341_600 && lowAggregate.streamLimits.maximumCaptureWidth == 992, "Multiple viewers preserve the lowest data budget")
lowRate.save(to: defaults)
check(ClientStreamSettings.load(from: defaults) == lowRate, "Phone remembers 3 fps after relaunch")
let macLowRate = ViewerStreamSettings(detailAmount: 0, frameRate: 3)
macLowRate.save(to: macDefaults)
check(ViewerStreamSettings.load(from: macDefaults) == macLowRate, "Mac remembers 3 fps after relaunch")
viewer.setStreamSettings(macLowRate)
check(viewer.inputSender.feedbacks.last?.maximumFrameRate == 3, "Mac sends 3 fps to the host")
for adaptive in [true, false] {
    let lowRateHost = QualityHostHarness()
    lowRateHost.configuration.adaptiveBitrateEnabled = adaptive
    for _ in 0..<10 {
        _ = lowRateHost.updateAdaptiveVideoState(feedback: try feedback(lowRate, fps: 3))
    }
    let lowRateState = lowRateHost.updateAdaptiveVideoState(feedback: try feedback(lowRate, fps: 3))
    check(lowRateState.expectedFrameRate == 3 && lowRateHost.adaptiveFrameStride == 1, "Healthy 3 fps is honored without false network backoff, adaptive=\(adaptive)")
    check(lowRateState.bitrate == 341_600, "Minimum data budget is honored, adaptive=\(adaptive)")
}
print("\(checks) stream-quality checks passed")
