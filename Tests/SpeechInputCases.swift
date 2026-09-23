// SPDX-License-Identifier: MPL-2.0

@MainActor
func runSpeechTests() async throws {
    func settle() async { for _ in 0..<8 { await Task.yield() } }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        print("PASS: \(message)")
    }
    let speech = ClientSpeechInput()
    SFSpeechRecognizer.supported = false
    speech.start()
    check(speech.alertMessage != nil && !speech.isStarting && SFSpeechRecognizer.requests.isEmpty,
          "unsupported on-device recognition never starts a cloud request")
    SFSpeechRecognizer.supported = true
    speech.alertMessage = nil
    SFSpeechRecognizer.authorization = .denied
    speech.start()
    await settle()
    check(!speech.isRecording && speech.shouldOfferSettings, "denied permission explains how to open Settings")
    SFSpeechRecognizer.authorization = .authorized
    AVAudioApplication.deferResponse = true
    speech.start()
    speech.start()
    await settle()
    check(speech.isStarting && SFSpeechRecognizer.requests.isEmpty, "repeated Start taps do not create a second permission/start flow")
    speech.stop()
    AVAudioApplication.pendingResponse?(true)
    AVAudioApplication.pendingResponse = nil
    await settle()
    check(!speech.isRecording && SFSpeechRecognizer.requests.isEmpty, "cancelled permission response cannot start recording later")
    AVAudioApplication.deferResponse = false
    speech.start()
    await settle()
    check(speech.isRecording && SFSpeechRecognizer.requests.last?.requiresOnDeviceRecognition == true,
          "recognition request explicitly requires on-device processing")
    let oldCallback = SFSpeechRecognizer.callbacks.last!
    speech.stop()
    speech.stop()
    speech.start()
    await settle()
    oldCallback(SpeechResult(bestTranscription: .init(formattedString: "stale"), isFinal: true), nil)
    await settle()
    check(speech.isRecording && speech.transcript.isEmpty, "stale callbacks cannot type text or stop a new recording")
    SFSpeechRecognizer.callbacks.last?(SpeechResult(bestTranscription: .init(formattedString: "finished"), isFinal: true), nil)
    await settle()
    check(!speech.isRecording && speech.transcript == "finished", "final recognition result retains text and releases microphone/audio ownership")
    AVAudioEngine.failStart = true
    speech.start()
    await settle()
    check(!speech.isRecording && speech.alertMessage != nil, "audio-engine failure cleans up the input tap and recording session")
    AVAudioEngine.failStart = false
    speech.start()
    await settle()
    check(speech.isRecording, "recording can start again after engine failure")
    speech.interrupt()
    check(!speech.isRecording, "background/disconnect interruption stops recording")
    speech.start()
    await settle()
    let callback = SFSpeechRecognizer.callbacks.last!
    callback(SpeechResult(bestTranscription: .init(formattedString: "open"), isFinal: false), nil)
    await settle()
    let finish = Task { await speech.finish() }
    await settle()
    check(speech.isFinishing, "release waits for trailing recognition results")
    callback(SpeechResult(bestTranscription: .init(formattedString: "open Safari"), isFinal: true), nil)
    let result = await finish.value
    check(result == "open Safari" && !speech.isRecording && !speech.isFinishing,
          "release captures final words and releases the microphone exactly once")
    speech.start()
    await settle()
    let cancelled = Task { await speech.finish() }
    await settle()
    speech.interrupt()
    let cancelledResult = await cancelled.value
    check(cancelledResult == nil, "cancelled hold cannot submit stale speech")
    AVAudioApplication.deferResponse = true
    speech.start()
    await settle()
    let early = await speech.finish()
    AVAudioApplication.pendingResponse?(true)
    await settle()
    check(early == nil && !speech.isRecording, "release during permission prompt never starts recording later")
}
try await runSpeechTests()
