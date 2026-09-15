let coordinator = ClientAudioSession.shared
let system = AVAudioSession.sharedInstance()
let viewer = UUID()
let recording = UUID()
var frames = 0
var pauses = 0
func play() {
    coordinator.play(owner: viewer, pause: { pauses += 1 }) { frames += 1 }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    print("PASS: \(message)")
}

play()
check(frames == 1 && system.category == .playback && system.active, "initial playback activates the playback session")
try coordinator.beginRecording(owner: recording)
check(pauses == 1 && system.category == .record, "dictation stops playback before switching the session")
play()
check(frames == 1 && system.category == .record, "incoming audio cannot change the recording category or accumulate playback")
do {
    try coordinator.beginRecording(owner: UUID())
    fatalError("Second recorder was accepted")
} catch {}
coordinator.endRecording(owner: UUID())
play()
check(frames == 1, "a second window and stale stop cannot steal or release the recording session")
coordinator.endRecording(owner: recording)
play()
check(frames == 2 && system.category == .playback, "stopping dictation restores playback")

system.failNextRecordingActivation = true
do {
    try coordinator.beginRecording(owner: UUID())
    fatalError("Injected activation failure did not propagate")
} catch {}
play()
check(frames == 3 && system.category == .playback, "recording startup failure restores playback and releases ownership")

NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: system,
    userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue)])
play()
check(frames == 3, "playback stays paused during a system interruption")
NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: system,
    userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
               AVAudioSessionInterruptionOptionKey: NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue)])
play()
check(frames == 4, "playback resumes only when the interruption allows it")

NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: system,
    userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue)])
play()
check(frames == 4, "an interruption without shouldResume does not restart audio automatically")
coordinator.stopPlayback(owner: viewer) {}
play()
check(frames == 5, "a new playback request can resume after the interruption has ended")

let pausesBefore = pauses
NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: system,
    userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.categoryChange.rawValue)])
check(pauses == pausesBefore, "our own category-change notification does not interrupt dictation")
NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: system,
    userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)])
check(pauses == pausesBefore + 1, "headphone route changes reset the playback engine")

try coordinator.beginRecording(owner: recording)
coordinator.stopPlayback(owner: viewer) {}
coordinator.endRecording(owner: recording)
check(!system.active, "disconnect during dictation does not resurrect the old audio stream")
coordinator.endRecording(owner: recording)
check(!system.active, "repeated cleanup is harmless")
