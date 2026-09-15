// SPDX-License-Identifier: MPL-2.0

// Compiles the real Mac viewer setting, startup, and keyframe send methods
// with a recording sender instead of a live network connection.
final class QualityRecordingSender {
    var feedbacks: [ViewerFeedback] = []
    func send(_ feedback: ViewerFeedback) { feedbacks.append(feedback) }
}
struct QualityViewerConfiguration { let hostInputPort = 5556 }
final class ViewerQualityFeedbackHarness {
    let keepaliveStateLock = NSLock()
    var streamSettings = ViewerStreamPreset.balanced.settings
    var videoSize = CGSize(width: 1600, height: 900)
    let inputSender = QualityRecordingSender()
    let configuration = QualityViewerConfiguration()
}
