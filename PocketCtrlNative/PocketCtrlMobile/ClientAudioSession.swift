// SPDX-License-Identifier: MPL-2.0

import AVFoundation
import Foundation

/// One owner for the process-wide audio session. Playback engines and session
/// transitions are serialized, so incoming packets cannot undo dictation's mode.
final class ClientAudioSession {
    static let shared = ClientAudioSession()
    static let recordingMustStop = Notification.Name("PocketCtrl.recordingMustStop")

    private let lock = NSRecursiveLock()
    private let session = AVAudioSession.sharedInstance()
    private var playbackClients: [UUID: () -> Void] = [:]
    private var recordingOwner: UUID?
    private var playbackConfigured = false
    private var interrupted = false
    private var playbackNeedsUserResume = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            self?.handleInterruption(began: type == AVAudioSession.InterruptionType.began.rawValue,
                                     shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            // Our own category changes are expected, not an interrupted recording.
            guard reason != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
            self?.resetForRouteChange()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.resetForRouteChange()
        })
    }

    /// Called from the audio receiver queue. While dictating, discard streamed
    /// audio instead of buffering it and playing stale sound after recording.
    func play(owner: UUID, pause: @escaping () -> Void, work: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let isNewClient = playbackClients[owner] == nil
        playbackClients[owner] = pause
        if isNewClient, !interrupted { playbackNeedsUserResume = false }
        guard recordingOwner == nil, !interrupted, !playbackNeedsUserResume else { return }
        do {
            try configurePlaybackIfNeeded()
            work()
        } catch {
            playbackConfigured = false
            ClientDiagnostics.write("Audio playback session failed: \(error.localizedDescription)")
        }
    }

    func stopPlayback(owner: UUID, work: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        playbackClients.removeValue(forKey: owner)
        work()
        if playbackClients.isEmpty, recordingOwner == nil {
            playbackConfigured = false
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func beginRecording(owner: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard recordingOwner == nil else { throw RecordingError.alreadyRecording }
        recordingOwner = owner
        playbackConfigured = false
        playbackClients.values.forEach { $0() }
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            interrupted = false
            playbackNeedsUserResume = false
        } catch {
            recordingOwner = nil
            restorePlaybackOrDeactivate()
            throw error
        }
    }

    func endRecording(owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard recordingOwner == owner else { return }
        recordingOwner = nil
        restorePlaybackOrDeactivate()
    }

    private func configurePlaybackIfNeeded() throws {
        guard !playbackConfigured else { return }
        try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try session.setActive(true)
        playbackConfigured = true
    }

    private func restorePlaybackOrDeactivate() {
        playbackConfigured = false
        guard !interrupted, !playbackNeedsUserResume else { return }
        do {
            if playbackClients.isEmpty {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } else {
                try configurePlaybackIfNeeded()
            }
        } catch {
            ClientDiagnostics.write("Audio session restore failed: \(error.localizedDescription)")
        }
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        lock.lock()
        interrupted = began
        playbackNeedsUserResume = began || !shouldResume
        playbackConfigured = false
        playbackClients.values.forEach { $0() }
        let owner = began ? recordingOwner : nil
        lock.unlock()
        if let owner { requestRecordingStop(owner: owner) }
    }

    private func resetForRouteChange() {
        lock.lock()
        playbackConfigured = false
        playbackClients.values.forEach { $0() }
        let owner = recordingOwner
        lock.unlock()
        if let owner { requestRecordingStop(owner: owner) }
    }

    private func requestRecordingStop(owner: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.recordingMustStop, object: owner)
        }
    }

    enum RecordingError: LocalizedError {
        case alreadyRecording
        var errorDescription: String? { "Voice input is already active in another PocketCtrl window." }
    }
}
