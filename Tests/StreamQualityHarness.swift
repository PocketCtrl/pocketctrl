// SPDX-License-Identifier: MPL-2.0

// State-only harness; script/test_stream_quality.sh inserts the production
// host adaptation methods here, without starting capture or accessing TCC.
enum StreamVideoCodec { case h264, hevc }
struct QualityHostConfiguration {
    var fps = 60
    var bitrate = 12_000_000
    var adaptiveBitrateEnabled = true
}
final class QualityHostHarness {
    var configuration = QualityHostConfiguration()
    let adaptiveStateLock = NSLock()
    var adaptiveBitrate = 6_000_000
    var minimumAdaptiveBitrate = 750_000
    var adaptiveFrameStride = 1
    var consecutivePoorFeedback = 0
    var consecutiveHealthyFeedback = 0
    var adaptiveQualityProfile: ViewerQualityProfile = .balanced
    var adaptiveLimits = ViewerQualityProfile.balanced.limits
    var activeVideoCodec: StreamVideoCodec = .h264
    var isIdlePacingActive = false
}
