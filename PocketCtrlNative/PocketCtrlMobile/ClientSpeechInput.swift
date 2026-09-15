// SPDX-License-Identifier: MPL-2.0

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class ClientSpeechInput: ObservableObject {
    @Published var transcript = ""
    @Published var status = "Tap Start and speak."
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published var alertMessage: String?
    @Published private(set) var shouldOfferSettings = false

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pendingStart: Task<Void, Never>?
    private var attemptID: UUID?
    private var recordingID: UUID?
    private var hasInputTap = false

    func start() {
        guard !isRecording, !isStarting else { return }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            showError("On-device dictation isn’t available for this device or language. You can still use the keyboard. PocketCtrl never falls back to sending speech audio to a server.")
            return
        }
        guard recognizer.isAvailable else {
            showError("Speech recognition is temporarily unavailable. Please try again or use the keyboard.")
            return
        }

        let id = UUID()
        attemptID = id
        isStarting = true
        status = "Preparing on-device dictation…"
        pendingStart = Task { [weak self] in
            guard let self else { return }
            let allowed = await self.requestPermissions()
            guard !Task.isCancelled, self.attemptID == id else { return }
            self.isStarting = false
            self.pendingStart = nil
            self.attemptID = nil
            guard allowed else {
                self.showError("Allow Microphone and Speech Recognition for PocketCtrl in Settings to use dictation. Keyboard input still works.", offerSettings: true)
                return
            }
            do {
                try self.startRecording(recognizer: recognizer)
            } catch {
                self.stop()
                self.showError("Voice input couldn’t start: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func stop() -> String {
        attemptID = nil
        pendingStart?.cancel()
        pendingStart = nil
        isStarting = false
        let owner = recordingID
        recordingID = nil // Ignore callbacks from the recognition task being cancelled.
        audioEngine.stop()
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if let owner {
            audioEngine = AVAudioEngine()
            ClientAudioSession.shared.endRecording(owner: owner)
        }
        isRecording = false
        status = transcript.isEmpty ? "No speech captured." : "Voice input finished."
        return transcript
    }

    func interrupt(recordingOwner: UUID? = nil) {
        if let recordingOwner, recordingOwner != recordingID { return }
        guard isStarting || isRecording else { return }
        stop()
        status = "Voice input stopped because the audio route or app state changed."
    }

    private func showError(_ message: String, offerSettings: Bool = false) {
        status = message
        shouldOfferSettings = offerSettings
        alertMessage = message
    }

    private func requestPermissions() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAllowed, !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func startRecording(recognizer: SFSpeechRecognizer) throws {
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw SpeechError.unavailable
        }
        let id = UUID()
        try ClientAudioSession.shared.beginRecording(owner: id)
        recordingID = id

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.noMicrophone }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        hasInputTap = true

        transcript = ""
        status = "Listening on device. Mac audio is paused."
        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recordingID == id else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if let error {
                    self.stop()
                    self.showError("Voice input stopped: \(error.localizedDescription)")
                } else if result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    private enum SpeechError: LocalizedError {
        case unavailable, noMicrophone
        var errorDescription: String? {
            switch self {
            case .unavailable: return "On-device speech recognition is unavailable."
            case .noMicrophone: return "No usable microphone is available."
            }
        }
    }
}
