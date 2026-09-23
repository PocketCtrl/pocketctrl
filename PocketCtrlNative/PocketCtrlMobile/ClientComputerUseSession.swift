// SPDX-License-Identifier: MPL-2.0
import Combine
import Foundation

@MainActor
final class ClientComputerUseSession: ObservableObject {
    private let now: () -> Date
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    @Published private(set) var snapshot: ComputerUseSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var waitingForStart = false
    @Published private(set) var stopping = false
    @Published private(set) var submittedApprovalID: UUID?
    @Published private(set) var supportTimedOut = false
    /// Run hidden by New Chat. The host clears its transcript on the next Start,
    /// so this only masks the finished run until a different run replaces it.
    @Published private(set) var clearedRunID: UUID?
    @Published var selectedModel = ""
    @Published var selectedThinking = "automatic"
    @Published var instructionDraft = ""
    @Published private(set) var queuedInstruction = false
    private var editingTask: (epoch: UUID, run: UUID)?
    private var instructionQueuedAt: Date?
    var isEditingTask: Bool { editingTask != nil }
    var canEditInstruction: Bool {
        !stopping && !waitingForStart && !isReconnecting && !queuedInstruction
            && !pending.values.contains { [.reply, .resume, .approve, .retryApproval].contains($0.kind) }
            && (canStart || (snapshot?.ownsTask == true && snapshot?.phase.ownsControl == true))
    }
    /// Capture the task being edited. Never redirect these words to another run.
    func beginEditingInstruction() {
        guard canEditInstruction else { return }
        if editingTask == nil, let state = snapshot, state.ownsTask, state.phase.ownsControl,
           let run = state.runID {
            editingTask = (state.epoch, run)
        }
        if snapshot?.ownsTask == true, [.starting, .running, .awaitingApproval].contains(snapshot?.phase ?? .completed),
           !hasPendingTransition {
            var value = command(.pause); value.text = "Paused for new instructions."
            enqueue(value)
        }
        objectWillChange.send(); onChange?()
    }
    @discardableResult
    func submitInstruction() -> Bool {
        guard canEditInstruction else { return false }
        let text = instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384 else { error = "Enter an instruction of at most 16 KB."; return false }
        error = nil
        beginEditingInstruction()
        if editingTask != nil {
            queuedInstruction = true; instructionQueuedAt = now()
            ComputerUseDiagnostics.event("client.instruction_queued", run: editingTask?.run)
            flushInstruction()
        } else {
            start(text)
            if waitingForStart { instructionDraft = "" }
        }
        return error == nil
    }
    private func flushInstruction() {
        guard queuedInstruction, let target = editingTask, let state = snapshot else { return }
        guard state.epoch == target.epoch, state.runID == target.run, state.ownsTask, state.phase.ownsControl,
              !stopping, !isReconnecting else {
            cancelQueuedInstruction(); return
        }
        guard state.canAcceptReply == true, showsResumeControl else { return }
        let text = instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        queuedInstruction = false; instructionQueuedAt = nil
        ComputerUseDiagnostics.event("client.instruction_ready", run: target.run)
        resume(reply: text)
        // Keep the draft until acknowledgement; a lost connection must not lose it.
    }
    private func cancelQueuedInstruction() {
        ComputerUseDiagnostics.event("client.instruction_cancelled", run: editingTask?.run)
        queuedInstruction = false; instructionQueuedAt = nil
        error = "Changes weren’t sent. Your draft is saved; reconnect and review the task."
    }
    var showsAIControls: Bool { blocksInput }
    var remotePointer: ComputerUsePointer? {
        guard snapshot?.phase.ownsControl == true, let pointer = snapshot?.pointer, pointer.isValid else { return nil }
        return pointer
    }
    func showsPointer(manualEnabled: Bool, controlsHidden: Bool) -> Bool {
        showsAIControls || (manualEnabled && !controlsHidden)
    }
    /// Public execution status only, never the provider's private reasoning.
    var activityText: String? {
        if let attentionMessage { return attentionMessage }
        guard showsAIControls else { return nil }
        return status
    }
    /// Estimated cost of the visible run, in the same short form as the viewer badge.
    var costText: String? {
        guard !isClearedRun, snapshot?.ownsTask == true,
              let cost = snapshot?.openAICostText else { return nil }
        return "~" + cost.replacingOccurrences(of: "US$", with: "$")
            + (snapshot?.costEstimateIncomplete == true ? "*" : "")
    }
    var liveCostText: String? {
        // Do not momentarily show the previous run's total when starting again.
        if waitingForStart { return "~$0.0000" }
        guard showsAIControls else { return nil }
        return costText
    }
    /// Transcript of the visible run, oldest first. Empty for other viewers' tasks.
    var visibleMessages: [ComputerUseMessage] {
        guard let snapshot, !isClearedRun else { return [] }
        return snapshot.messages
    }
    /// Render attention once in the conversation, rather than repeating it
    /// above the composer. Match the host's handoff prefix to its transcript.
    private func sheetMessageKey(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("Take control: ") ? String(text.dropFirst("Take control: ".count)) : text
    }
    var sheetWarningMessageID: UUID? {
        guard let attentionMessage else { return nil }
        return visibleMessages.last {
            $0.role != "user" && sheetMessageKey($0.text) == sheetMessageKey(attentionMessage)
        }?.id
    }
    var sheetNotice: (text: String, isWarning: Bool)? {
        guard visibleApproval == nil, sheetWarningMessageID == nil else { return nil }
        let text: String
        let warning: Bool
        if let attentionMessage { text = attentionMessage; warning = true }
        else if snapshot?.available == false || visibleMessages.isEmpty {
            text = status; warning = snapshot?.available == false || supportTimedOut
        } else { return nil }
        guard !visibleMessages.contains(where: { $0.role != "user" && sheetMessageKey($0.text) == sheetMessageKey(text) }) else { return nil }
        return (text, warning)
    }
    var canPause: Bool {
        !stopping && !waitingForStart && !isReconnecting && !hasPendingTransition && snapshot?.ownsTask == true
            && [.starting, .running].contains(snapshot?.phase ?? .completed)
    }
    var canStartNewChat: Bool {
        if error != nil || waitingForStart { return true }
        guard let snapshot, snapshot.ownsTask, snapshot.runID != nil else { return false }
        return !isClearedRun
    }
    /// New Chat only ends a task this viewer started (or is starting).
    var newChatStopsTask: Bool { blocksInput && !stopping && (waitingForStart || snapshot?.ownsTask == true) }
    private var isClearedRun: Bool { clearedRunID != nil && snapshot?.runID == clearedRunID }
    private var isClearedIdleRun: Bool { isClearedRun && snapshot?.phase.ownsControl == false }
    var showsResumeControl: Bool {
        !stopping && !waitingForStart && !isReconnecting && !hasPendingTransition && snapshot?.ownsTask == true
            && [.paused, .awaitingUser].contains(snapshot?.phase ?? .completed)
    }
    var attentionMessage: String? {
        if isReconnecting { return stopping ? "Connection lost · Stop pending" : "Connection lost · Reconnecting" }
        if let error { return error }
        if stopping || waitingForStart { return nil }
        if let state = snapshot, state.ownsTask, !isClearedRun,
           [.failed, .awaitingUser].contains(state.phase) { return state.status }
        if let state = snapshot, state.ownsTask, state.phase == .paused { return state.status }
        return nil
    }
    var send: ((ComputerUseFragment) -> Void)?
    var canSupervise: () -> Bool = { false }
    var onChange: (() -> Void)?
    private var pending: [UUID: ComputerUseCommand] = [:]
    // Stop is intent, not a ten-second UI request. Keep its original epoch/run
    // across reconnects until the host confirms that exact task has ended.
    private var stopIntent: ComputerUseCommand?
    private var lastStopTransmission = Date.distantPast
    private var awaitingFreshState = false
    private var pauseAfterReconnect = false
    private var wasReconnecting = false
    private var hasPendingTransition: Bool { pending.values.contains { [.pause, .resume, .reply].contains($0.kind) } }
    var isReconnecting: Bool {
        blocksInput && (awaitingFreshState || now().timeIntervalSince(lastSnapshotAt) >= 3 || !canSupervise())
    }
    var progressControlTitle: String {
        if isReconnecting { return "Reconnecting" }
        if stopping { return "Stopping" }
        if pending.values.contains(where: { [.resume, .reply].contains($0.kind) }) { return "Resuming" }
        if pending.values.contains(where: { $0.kind == .pause }) { return "Pausing" }
        if queuedInstruction { return "Updating" }
        if waitingForStart { return "Starting" }
        return "Working"
    }
    private var assembly = ComputerUseReassembler()
    private var timer: Task<Void, Never>?
    private var credentialID = ""
    private var lastHeartbeat = Date.distantPast
    private var startedAt = Date()
    private var pendingRunID: UUID?
    private var lastSnapshotAt = Date.distantPast
    private var supervisionSuspended = false
    private var lastDiagnosticState = ""
    private var lastDiagnosticSupervision: Bool?
    var blocksInput: Bool { waitingForStart || stopping || snapshot?.phase.ownsControl == true }
    var visibleApproval: ComputerUseApproval? {
        guard !stopping, !isReconnecting, snapshot?.ownsTask == true, snapshot?.phase == .awaitingApproval else { return nil }
        return snapshot?.approval
    }
    var canStart: Bool { snapshot?.available == true && !blocksInput && !awaitingFreshState && canSupervise() && now().timeIntervalSince(lastSnapshotAt) < 3 }
    var status: String {
        if isReconnecting { return stopping ? "Connection lost · Stop pending" : "Connection lost · Reconnecting" }
        if stopping { return "Stopping…" }
        if waitingForStart { return "Starting…" }
        if let error { return error }
        // Idle reasons replace the run status on the host, so an unavailable
        // feature still explains itself after New Chat.
        if isClearedIdleRun, snapshot?.available == true { return "Ready" }
        return snapshot?.status ?? (supportTimedOut ? "Update PocketCtrl on this Mac to use Computer Use." : "Checking Computer Use support…")
    }
    /// Hides the finished run's transcript, status, and cost. An owned task that
    /// is still running is stopped first; the composer unlocks once the host confirms.
    func newChat() {
        editingTask = nil; queuedInstruction = false; instructionQueuedAt = nil; instructionDraft = ""
        clearedRunID = pendingRunID ?? snapshot?.runID
        error = nil
        ComputerUseDiagnostics.event("client.new_chat", run: clearedRunID, ["stops": String(newChatStopsTask)])
        if newChatStopsTask { stop() } else { onChange?() }
    }
    func activate(credentialID: String) {
        if queuedInstruction { cancelQueuedInstruction() }
        submittedApprovalID = nil
        lastDiagnosticState = ""
        lastDiagnosticSupervision = nil
        ComputerUseDiagnostics.event("client.activate")
        if self.credentialID != credentialID {
            editingTask = nil; instructionDraft = ""
            snapshot = nil; pendingRunID = nil; waitingForStart = false; stopping = false
            stopIntent = nil; supervisionSuspended = false; clearedRunID = nil; wasReconnecting = false
        } else if waitingForStart && stopIntent == nil {
            // Start may have arrived without its acknowledgement. Never replay
            // it after reconnect: cancel that uncertain run instead.
            stop()
        }
        self.credentialID = credentialID
        pauseAfterReconnect = snapshot?.ownsTask == true && snapshot?.phase.ownsControl == true && !stopping
        if pauseAfterReconnect || stopping { supervisionSuspended = true }
        awaitingFreshState = true; lastSnapshotAt = .distantPast
        lastStopTransmission = .distantPast
        pending.removeAll(); assembly = ComputerUseReassembler(); error = nil; supportTimedOut = false
        startedAt = now(); timer?.cancel()
        enqueue(.init(kind: .capabilities))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }
    func leaveViewer(disconnect: Bool = false) {
        if queuedInstruction { cancelQueuedInstruction() }
        ComputerUseDiagnostics.event("client.leave", run: pendingRunID ?? snapshot?.runID, ["disconnect": String(disconnect), "ownsTask": String(snapshot?.ownsTask == true)])
        supervisionSuspended = true
        if !stopping && (waitingForStart || (snapshot?.ownsTask == true && snapshot?.phase.ownsControl == true)) {
            pending = pending.filter { ![.start, .approve, .retryApproval, .resume, .reply].contains($0.value.kind) }
            if !pending.values.contains(where: { $0.kind == .pause }) { enqueue(command(.pause)) }
        }
        if disconnect { awaitingFreshState = true; timer?.cancel(); timer = nil }
        onChange?()
    }
    func start(_ text: String) {
        guard canStart else {
            ComputerUseDiagnostics.event("client.start_blocked", ["available": String(snapshot?.available == true), "blocksInput": String(blocksInput), "canSupervise": String(canSupervise()), "freshState": String(Date().timeIntervalSince(lastSnapshotAt) < 3)])
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16_384 else { error = "Enter a task of at most 16 KB."; return }
        let id = UUID(); pendingRunID = id
        supervisionSuspended = false
        var value = command(.start); value.runID = id; value.text = trimmed
        value.mode = ComputerUseMode.openAI.rawValue
        value.model = selectedModel.isEmpty ? nil : selectedModel
        value.thinking = selectedThinking
        waitingForStart = true; error = nil; enqueue(value); onChange?()
    }
    func stop() {
        guard blocksInput, stopIntent == nil else { return }
        guard let runID = pendingRunID ?? snapshot?.runID, snapshot?.epoch != nil else { return }
        queuedInstruction = false; instructionQueuedAt = nil; editingTask = nil
        stopping = true; error = nil
        supervisionSuspended = true; pauseAfterReconnect = false
        var value = command(.stop); value.runID = runID
        // Stop can race an unacknowledged Start. Remove retries; retain Stop until host state resolves it.
        pending.removeAll()
        stopIntent = value
        ComputerUseDiagnostics.event("client.stop_queued", run: runID)
        transmitStop(); onChange?()
    }
    func pause() {
        guard canPause else { return }
        var value = command(.pause); value.text = "Paused for new instructions."
        enqueue(value)
    }
    func resume(reply: String? = nil) {
        guard showsResumeControl else { return }
        supervisionSuspended = false
        var value = command(reply == nil ? .resume : .reply); value.text = reply
        error = nil; enqueue(value)
    }
    func approve(_ allowed: Bool, approvalID: UUID? = nil) {
        guard snapshot?.ownsTask == true, let approval = snapshot?.approval, canSupervise() else {
            ComputerUseDiagnostics.event("client.approval_blocked", run: snapshot?.runID, ["ownsTask": String(snapshot?.ownsTask == true), "hasApproval": String(snapshot?.approval != nil), "canSupervise": String(canSupervise())])
            return
        }
        // A tap authorizes only the request actually displayed, never a newer
        // request that arrived while SwiftUI was processing the gesture.
        guard !stopping, !isReconnecting, approvalID == nil || approvalID == approval.id,
              submittedApprovalID != approval.id else { return }
        submittedApprovalID = approval.id; error = nil
        ComputerUseDiagnostics.event("client.approval_answer", run: snapshot?.runID, ["approved": String(allowed)])
        var value = command(.approve); value.approvalID = approval.id; value.approved = allowed
        enqueue(value)
        onChange?()
    }
    func retryApproval(_ approvalID: UUID) {
        guard snapshot?.supportsApprovalRetry == true, snapshot?.ownsTask == true,
              snapshot?.phase == .awaitingApproval, snapshot?.approval?.id == approvalID,
              submittedApprovalID != approvalID, !stopping, !isReconnecting, canSupervise() else { return }
        submittedApprovalID = approvalID; error = nil
        ComputerUseDiagnostics.event("client.approval_retry", run: snapshot?.runID)
        var value = command(.retryApproval); value.approvalID = approvalID
        enqueue(value)
        onChange?()
    }
    func receive(_ fragment: ComputerUseFragment) {
        guard let data = assembly.push(fragment), let state = try? JSONDecoder().decode(ComputerUseSnapshot.self, from: data),
              abs(state.sentAt.timeIntervalSince(now())) < 15 else { return }
        var confirmedStop = false
        if let id = state.acknowledgedCommand,
           let acknowledged = pending.removeValue(forKey: id) ?? (stopIntent?.id == id ? stopIntent : nil) {
            ComputerUseDiagnostics.event("client.ack", run: acknowledged.runID, ["kind": acknowledged.kind.rawValue, "accepted": String(state.commandError == nil), "ms": String(Int(max(0, Date().timeIntervalSince(acknowledged.sentAt)) * 1000))])
            confirmedStop = acknowledged.kind == .stop && state.commandError == nil && state.epoch == acknowledged.epoch
                && (state.runID != acknowledged.runID || !state.phase.ownsControl)
            if let reason = state.commandError {
                error = reason
                if [.approve, .retryApproval].contains(acknowledged.kind) { submittedApprovalID = nil }
                if acknowledged.kind == .start { waitingForStart = false; pendingRunID = nil }
            } else if acknowledged.kind == .reply, acknowledged.text == instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines) {
                instructionDraft = ""; editingTask = nil
            }
        }
        if waitingForStart, stopIntent == nil, state.runID != pendingRunID, state.epoch == snapshot?.epoch, !confirmedStop {
            onChange?(); return
        }
        if let current = snapshot {
            guard (state.epoch == current.epoch && (state.revision > current.revision || (state.revision == current.revision && state.sentAt > current.sentAt)))
                    || (state.epoch != current.epoch && state.sentAt > current.sentAt) else { onChange?(); return }
        }
        if confirmedStop { waitingForStart = false }
        let isNewHost = snapshot?.epoch != state.epoch
        let diagnosticState = "\(state.epoch)|\(state.runID?.uuidString ?? "none")|\(state.phase.rawValue)|\(state.approval?.id.uuidString ?? "none")|\(state.ownsTask)|\(state.available)"
        if diagnosticState != lastDiagnosticState {
            lastDiagnosticState = diagnosticState
            ComputerUseDiagnostics.event("client.state", run: state.runID, ["phase": state.phase.rawValue, "ownsTask": String(state.ownsTask), "hasApproval": String(state.approval != nil), "available": String(state.available)])
        }
        snapshot = state; lastSnapshotAt = now(); supportTimedOut = false; awaitingFreshState = false
        if error == "No acknowledgement from Mac. Reconnect to check the task." { error = nil }
        if let stop = stopIntent {
            let ended = state.epoch != stop.epoch || (state.runID == stop.runID && !state.phase.ownsControl)
            let replaced = state.runID != nil && state.runID != stop.runID && state.phase.ownsControl
            if confirmedStop || ended || replaced {
                ComputerUseDiagnostics.event("client.stop_resolved", run: stop.runID, ["sameEpoch": String(state.epoch == stop.epoch)])
                stopIntent = nil; stopping = false; waitingForStart = false; pendingRunID = nil
            }
        }
        if isNewHost { pending.removeAll(); waitingForStart = false; pendingRunID = nil }
        // Host state can settle a transition even if its acknowledgement was lost.
        pending = pending.filter { _, command in
            guard command.epoch == state.epoch, command.runID == state.runID else { return true }
            if command.kind == .pause && [.paused, .awaitingUser].contains(state.phase) { return false }
            // A Starting snapshot can precede a reply's acknowledgement. Keep
            // that command for deduplicated acknowledgement retries so the draft
            // is only cleared once the host confirms receipt.
            if command.kind == .resume && ![.paused, .awaitingUser].contains(state.phase) { return false }
            return true
        }
        if isNewHost || selectedModel.isEmpty {
            selectedModel = state.defaultModel ?? ""
            selectedThinking = state.defaultThinking ?? "automatic"
        }
        if state.phase.ownsControl, state.ownsTask {
            selectedModel = state.taskModel ?? selectedModel
            selectedThinking = state.taskThinking ?? selectedThinking
        }
        if !state.phase.ownsControl, let finishedRun = state.runID {
            // A fresh terminal snapshot settles commands for that exact run,
            // even if its individual acknowledgement datagram was lost.
            pending = pending.filter { $0.value.kind == .reply || $0.value.runID != finishedRun || $0.value.epoch != state.epoch }
        }
        if state.approval?.id != submittedApprovalID { submittedApprovalID = nil }
        if state.runID == pendingRunID { waitingForStart = false; pendingRunID = nil }
        if !state.phase.ownsControl { waitingForStart = false }
        if !state.phase.ownsControl && stopIntent == nil { stopping = false; pendingRunID = nil }
        if pauseAfterReconnect {
            pauseAfterReconnect = false
            if !stopping, state.ownsTask, [.starting, .running, .awaitingApproval].contains(state.phase) {
                enqueue(command(.pause))
            }
        }
        if stopIntent != nil, now().timeIntervalSince(lastStopTransmission) >= 1 { transmitStop() }
        flushInstruction()
        onChange?()
    }
    private func command(_ kind: ComputerUseCommand.Kind) -> ComputerUseCommand {
        ComputerUseCommand(kind: kind, epoch: snapshot?.epoch, runID: pendingRunID ?? snapshot?.runID, sentAt: now())
    }
    private func enqueue(_ value: ComputerUseCommand) {
        var value = value; value.sentAt = now()
        if value.kind != .heartbeat {
            pending[value.id] = value
            ComputerUseDiagnostics.event("client.command", run: value.runID, ["kind": value.kind.rawValue])
        }
        transmit(value)
    }
    private func transmit(_ value: ComputerUseCommand) {
        for fragment in ComputerUseFragment.encode(value) { send?(fragment) }
    }
    private func transmitStop() {
        guard var value = stopIntent else { return }
        // Same command identity for deduplication, fresh envelope for the host's
        // replay window. Never change its task or host epoch.
        value.sentAt = now(); lastStopTransmission = now()
        ComputerUseDiagnostics.event("client.stop_retry", run: value.runID)
        transmit(value)
    }
    // Internal clock-driven entry point also used by deterministic loss tests.
    func tick() {
        if isReconnecting && !wasReconnecting {
            if queuedInstruction { cancelQueuedInstruction() }
            supervisionSuspended = true
            ComputerUseDiagnostics.event("client.connection_lost", run: pendingRunID ?? snapshot?.runID)
            if waitingForStart { stop() }
            pending = pending.filter { ![.start, .approve, .retryApproval, .resume, .reply].contains($0.value.kind) }
            submittedApprovalID = nil
            pauseAfterReconnect = !stopping && snapshot?.ownsTask == true && snapshot?.phase.ownsControl == true
        }
        wasReconnecting = isReconnecting
        if let queuedAt = instructionQueuedAt, now().timeIntervalSince(queuedAt) >= 10 { cancelQueuedInstruction() }
        for (id, command) in pending {
            if now().timeIntervalSince(command.sentAt) >= 10 {
                ComputerUseDiagnostics.event("client.ack_timeout", run: command.runID, ["kind": command.kind.rawValue])
                pending.removeValue(forKey: id)
                if command.kind == .capabilities, snapshot == nil { supportTimedOut = true }
                else if command.kind != .capabilities { error = "No acknowledgement from Mac. Reconnect to check the task." }
            } else { transmit(command) }
        }
        if stopIntent != nil, !awaitingFreshState, now().timeIntervalSince(lastStopTransmission) >= 1 { transmitStop() }
        // Poll stale active state too: a lost final update must not strand Stop
        // or leave an old Running snapshot on screen forever.
        if (canSupervise() || blocksInput), now().timeIntervalSince(lastSnapshotAt) >= 1,
           !pending.values.contains(where: { $0.kind == .capabilities }) {
            enqueue(.init(kind: .capabilities))
        }
        if snapshot == nil, now().timeIntervalSince(startedAt) >= 10 { supportTimedOut = true }
        let supervising = snapshot?.ownsTask == true && snapshot?.phase.ownsControl == true && !isReconnecting && canSupervise() && !stopping && !supervisionSuspended
        if snapshot?.ownsTask == true, snapshot?.phase.ownsControl == true {
            if lastDiagnosticSupervision != supervising {
                lastDiagnosticSupervision = supervising
                ComputerUseDiagnostics.event("client.supervision", run: snapshot?.runID, ["ready": String(supervising), "viewerSuspended": String(supervisionSuspended), "stopping": String(stopping)])
            }
        } else { lastDiagnosticSupervision = nil }
        if snapshot?.ownsTask == true, snapshot?.phase.ownsControl == true, supervising,
           now().timeIntervalSince(lastHeartbeat) >= 1 {
            lastHeartbeat = now(); transmit(command(.heartbeat))
        }
        onChange?()
    }
}
