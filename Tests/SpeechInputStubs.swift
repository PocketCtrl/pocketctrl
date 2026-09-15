// SPDX-License-Identifier: MPL-2.0

import Foundation

final class SFSpeechRecognizer {
    enum Authorization { case authorized, denied }
    static var supported = true
    static var available = true
    static var authorization = Authorization.authorized
    static var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    static var callbacks: [(SpeechResult?, Error?) -> Void] = []
    var supportsOnDeviceRecognition: Bool { Self.supported }
    var isAvailable: Bool { Self.available }
    init?(locale: Locale) {}
    static func requestAuthorization(_ completion: @escaping (Authorization) -> Void) { completion(authorization) }
    func recognitionTask(with request: SFSpeechAudioBufferRecognitionRequest,
                         resultHandler: @escaping (SpeechResult?, Error?) -> Void) -> SFSpeechRecognitionTask {
        Self.requests.append(request)
        Self.callbacks.append(resultHandler)
        return SFSpeechRecognitionTask()
    }
}
struct SpeechResult {
    struct Transcription { let formattedString: String }
    let bestTranscription: Transcription
    let isFinal: Bool
}
final class SFSpeechAudioBufferRecognitionRequest {
    var shouldReportPartialResults = false
    var requiresOnDeviceRecognition = false
    func endAudio() {}
    func append(_ buffer: Int) {}
}
final class SFSpeechRecognitionTask { func cancel() {} }
enum AVAudioApplication {
    static var allowed = true
    static var deferResponse = false
    static var pendingResponse: ((Bool) -> Void)?
    static func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        if deferResponse { pendingResponse = completion } else { completion(allowed) }
    }
}
struct TestAudioFormat { let sampleRate = 48000.0; let channelCount = 1 }
final class TestInputNode {
    var hasTap = false
    func outputFormat(forBus: Int) -> TestAudioFormat { TestAudioFormat() }
    func removeTap(onBus: Int) { precondition(hasTap); hasTap = false }
    func installTap(onBus: Int, bufferSize: Int, format: TestAudioFormat, block: (Int, Int) -> Void) {
        precondition(!hasTap); hasTap = true
    }
}
final class AVAudioEngine {
    static var failStart = false
    let inputNode = TestInputNode()
    func prepare() {}
    func start() throws { if Self.failStart { throw AVAudioSession.Failure.activation } }
    func stop() {}
}
