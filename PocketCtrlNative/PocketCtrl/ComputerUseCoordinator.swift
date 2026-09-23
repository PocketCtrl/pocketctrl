// SPDX-License-Identifier: MPL-2.0
import Combine
import Foundation

struct ComputerUseLimits {
    var supervisionTimeout: TimeInterval = 3
    var pausedRetention: TimeInterval = 1800
    var activeRuntime: TimeInterval = 600
    var actions = 100
    var turns = 100
}

@MainActor
final class ComputerUseCoordinator: ObservableObject {
    static let keyAccount = "PocketCtrl.computerUse.openAIKey.v1"
    let gate = ComputerUseExecutionGate()
    let modelCatalog: OpenAIModelCatalogStore
    private(set) var taskOpenAIOptions: OpenAIComputerUseOptions?
    private(set) var taskMode: ComputerUseMode?
    private var configuredModes = Set<ComputerUseMode>()
    var defaultMode: ComputerUseMode { .openAI }
    private var runtimeMode: ComputerUseMode { .openAI }
    var dataNotice: String { ComputerUseMode.openAI.dataNotice }
    @Published private(set) var snapshot = ComputerUseSnapshot()
    private var lastDiagnosticState = ""
    @Published var settingsMessage = ""
    @Published private(set) var hasKey = false
    @Published var isTesting = false
    @Published var openAIModel = OpenAIComputerUseModel(rawValue: UserDefaults.standard.string(forKey: "PocketCtrl.computerUse.openAIModel") ?? "") ?? .luna {
        didSet {
            guard oldValue != openAIModel else { return }
            stop(reason: "OpenAI model changed")
            UserDefaults.standard.set(openAIModel.rawValue, forKey: "PocketCtrl.computerUse.openAIModel")
            if !openAIModel.efforts.contains(openAIThinking) { openAIThinking = .automatic }
            settingsMessage = ""; publish()
        }
    }
    @Published var openAIThinking = OpenAIThinkingEffort(rawValue: UserDefaults.standard.string(forKey: "PocketCtrl.computerUse.openAIThinking") ?? "") ?? .automatic {
        didSet {
            guard oldValue != openAIThinking else { return }
            stop(reason: "OpenAI thinking setting changed")
            UserDefaults.standard.set(openAIThinking.rawValue, forKey: "PocketCtrl.computerUse.openAIThinking")
            settingsMessage = ""; publish()
        }
    }
    var openAIOptions: OpenAIComputerUseOptions {
        .init(model: openAIModel, effort: openAIThinking, catalogEntry: modelCatalog.catalog.entry(openAIModel),
              pricingVerifiedAt: modelCatalog.catalog.verifiedAt)
    }
    private func requestedOptions(_ command: ComputerUseCommand) -> OpenAIComputerUseOptions? {
        guard let model = command.model.flatMap(OpenAIComputerUseModel.init(rawValue:)) ?? (command.model == nil ? openAIModel : nil),
              let effort = command.thinking.flatMap(OpenAIThinkingEffort.init(rawValue:)) ?? (command.thinking == nil ? openAIThinking : nil),
              let entry = modelCatalog.catalog.entry(model), entry.enabled,
              entry.efforts.contains(effort) else { return nil }
        return .init(model: model, effort: effort, catalogEntry: entry, pricingVerifiedAt: modelCatalog.catalog.verifiedAt)
    }
    func refreshModels(force: Bool = false) async {
        let key = KeychainStore.string(forKey: Self.keyAccount)
        await modelCatalog.refresh(key: key, force: force)
        // A key replacement may occur while the request is in flight.
        if key != KeychainStore.string(forKey: Self.keyAccount) {
            await modelCatalog.refresh(key: KeychainStore.string(forKey: Self.keyAccount), force: true)
        }
        publish()
    }
    @Published var enabled = UserDefaults.standard.bool(forKey: "PocketCtrl.computerUse.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "PocketCtrl.computerUse.enabled")
            if !enabled { stop(reason: "Computer Use disabled on the Mac") }
            publish()
        }
    }
    var permissionError: (String) -> String? = { _ in "Start hosting on the Mac first." }
    var canStop: (String) -> Bool = { _ in false }
    var reserveControl: (String) -> Bool = { _ in false }
    var observe: (() async throws -> ComputerUseObservation)?
    var readPointer: (() -> ComputerUsePointer?)?
    var execute: ((ComputerUseAction, ComputerUseObservation, UInt64) async throws -> Void)?
    var releaseInputs: (() async -> Void)?
    var releaseInputsBeforeExit: (() -> Void)?
    var sendSnapshot: ((ComputerUseSnapshot, String?) -> Void)?
    // Test injection only. Production selection is fixed to the supported provider endpoints.
    var providerFactory: ((String) -> any ComputerUseProvider)?
    private var subscribers = Set<String>()
    func isSubscriber(_ id: String) -> Bool { subscribers.contains(id) }
    private var owner: String?
    private var prompt = ""
    private var runner: Task<Void, Never>?
    private var inFlightInput: Task<Void, Error>?
    private var timer: Task<Void, Never>?
    private var lastSupervision = Date.distantPast
    private var lastPublish = Date.distantPast
    private var pausedAt: Date?
    private var segmentStarted = Date()
    private var activeSeconds: TimeInterval = 0
    private var segmentActions = 0
    private var cleaningUp = false
    private var stoppedRuns: [UUID: Date] = [:]
    private var transitionID = UUID()
    private var processed: [UUID: (Date, String?)] = [:]
    private var fragments: [String: ComputerUseReassembler] = [:]
    private enum ApprovalResponse { case allow, decline, retry }
    private var approvalContinuation: CheckedContinuation<ApprovalResponse, Never>?
    private var lastPointerPublish: TimeInterval = 0

    func updatePointer(_ pointer: ComputerUsePointer, token: UInt64, flush: Bool) {
        guard gate.isValid(token), snapshot.phase == .running, pointer.isValid else { return }
        snapshot.pointer = pointer
        let now = ProcessInfo.processInfo.systemUptime
        // Bound drag updates, but always flush the final mouse-up position.
        if flush || now - lastPointerPublish >= 0.08 {
            lastPointerPublish = now
            publish()
        }
    }

    private let limits: ComputerUseLimits
    init(limits: ComputerUseLimits = ComputerUseLimits(), modelCatalog: OpenAIModelCatalogStore? = nil) {
        self.limits = limits
        self.modelCatalog = modelCatalog ?? OpenAIModelCatalogStore()
        if !openAIModel.efforts.contains(openAIThinking) { openAIThinking = .automatic }
        refreshKeyStatus()
    }
    func refreshKeyStatus() {
        configuredModes = []
        if KeychainStore.string(forKey: Self.keyAccount) != nil { configuredModes.insert(.openAI) }
        switch KeychainStore.readString(forKey: Self.keyAccount) {
        case .value: hasKey = true
        case .missing: hasKey = false
        case .failure: hasKey = false; settingsMessage = "Keychain is unavailable. Unlock this Mac and try again."
        }
    }
    func saveKey(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { settingsMessage = "Enter an OpenAI API key."; return }
        stop(reason: "API key changed")
        guard KeychainStore.set(value, forKey: Self.keyAccount) else { settingsMessage = "Could not securely save the API key."; return }
        modelCatalog.invalidateKey()
        refreshKeyStatus(); settingsMessage = "API key saved securely on this Mac."; publish()
    }
    func deleteKey() {
        stop(reason: "API key removed")
        guard KeychainStore.delete(forKey: Self.keyAccount) else { settingsMessage = "Could not delete the API key from Keychain."; return }
        modelCatalog.invalidateKey()
        refreshKeyStatus(); settingsMessage = "API key deleted."; publish()
    }
    func testConnection() async {
        guard !isTesting, let key = KeychainStore.string(forKey: Self.keyAccount) else { return }
        let options = openAIOptions
        isTesting = true; defer { isTesting = false }
        do {
            try await OpenAIComputerUseProvider(key: key, options: options).testConnection()
            if openAIOptions == options { settingsMessage = "OpenAI model access verified. No screen content was sent." }
        } catch { if openAIOptions == options { settingsMessage = error.localizedDescription } }
    }
    func hostingStarted() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }
    func shutdownImmediately() {
        gate.invalidate(release: false)
        runner?.cancel(); timer?.cancel()
        releaseInputsBeforeExit?()
        gate.invalidate(release: true)
    }
    func hostingStopped() {
        stop(reason: "Hosting stopped")
        timer?.cancel(); timer = nil
        fragments.removeAll(); subscribers.removeAll()
    }
    func deviceRevoked(_ id: String) {
        if owner == id { stop(reason: "Device access revoked") }
    }
    var ownsControl: Bool { gate.ownsControl }

    func receive(_ fragment: ComputerUseFragment, deviceID: String) {
        if fragments[deviceID] == nil {
            guard fragments.count < 8 else { return }
            fragments[deviceID] = ComputerUseReassembler()
        }
        guard let data = fragments[deviceID]?.push(fragment),
              let command = try? JSONDecoder().decode(ComputerUseCommand.self, from: data),
              abs(command.sentAt.timeIntervalSinceNow) < 15 else { return }
        if let prior = processed[command.id] {
            respond(to: deviceID, command: command.id, error: prior.1); return
        }
        if command.kind == .capabilities { subscribers.insert(deviceID); respond(to: deviceID, command: command.id); return }
        guard command.epoch == snapshot.epoch else {
            if command.kind != .heartbeat { ComputerUseDiagnostics.event("host.command_rejected", run: command.runID, ["kind": command.kind.rawValue, "cause": "stale_host_epoch"]) }
            respond(to: deviceID, command: command.id, error: "Reconnect to refresh Computer Use status."); return
        }
        if command.kind != .heartbeat {
            ComputerUseDiagnostics.event("host.command", run: command.runID, ["kind": command.kind.rawValue, "owner": String(deviceID == owner), "approvalMatches": String(command.approvalID != nil && command.approvalID == snapshot.approval?.id)])
        }
        var error: String?
        switch command.kind {
        case .start:
            let requestedMode = command.mode.flatMap(ComputerUseMode.init(rawValue:)) ?? defaultMode
            let options = requestedOptions(command)
            if let runID = command.runID, stoppedRuns[runID] != nil { error = "This task was already stopped." }
            else if snapshot.phase.ownsControl { error = "Another task already owns this Mac. Stop it first." }
            else if command.mode != nil && ComputerUseMode(rawValue: command.mode!) == nil { error = "Unsupported Computer Use provider. Update both apps." }
            else if let reason = readinessError(deviceID, mode: requestedMode) { error = reason }
            else if options == nil { error = "Unsupported model or thinking setting. Refresh Computer Use settings and try again." }
            else if !modelCatalog.permits(options!.model) {
                error = "The selected OpenAI model is unavailable. Refresh or choose a compatible model in Mac settings."
            }
            else if command.runID == nil || (command.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (command.text?.utf8.count ?? 0) > 16_384 { error = "Enter a task of at most 16 KB." }
            else if !reserveControl(deviceID) { error = "Another viewer is controlling this Mac." }
            else {
                owner = deviceID; prompt = command.text!
                taskMode = requestedMode; snapshot.taskMode = requestedMode
                snapshot.runID = command.runID; snapshot.messages = []; snapshot.actions = 0
                snapshot.pointer = nil
                ComputerUseDiagnostics.event("task.accepted", run: command.runID, ["mode": requestedMode.rawValue])
                snapshot.inputTokens = 0; snapshot.outputTokens = 0
                snapshot.openAICostUSD = requestedMode.usesOpenAI ? 0 : nil
                snapshot.costEstimateIncomplete = false
                taskOpenAIOptions = options!
                snapshot.taskModel = options!.model.rawValue
                snapshot.taskThinking = options!.effectiveEffort.rawValue
                snapshot.pricingVerifiedAt = options!.pricingVerifiedAt
                snapshot.modelDescription = options!.label
                append(role: "user", text: prompt)
                lastSupervision = Date(); activeSeconds = 0; segmentActions = 0
                launch()
            }
        case .stop:
            if !canStop(deviceID) { error = "This device does not have control permission." }
            else if let runID = command.runID {
                // A Stop may overtake Start on UDP. Tombstone its run before acknowledging.
                stoppedRuns[runID] = Date()
                if runID == snapshot.runID { stop() }
            } else { error = "No task was specified." }
        case .heartbeat:
            if deviceID == owner, command.runID == snapshot.runID { lastSupervision = Date() }
        case .pause:
            if deviceID == owner, command.runID == snapshot.runID { pause(reason: command.text == nil ? "Paused because the viewer is no longer supervising" : "Paused for new instructions.", diagnosticCause: command.text == nil ? "viewer_left" : "user_pause") }
            else if let runID = command.runID, canStop(deviceID) {
                // Leaving the viewer can overtake an unacknowledged Start as well.
                stoppedRuns[runID] = Date()
            }
        case .resume, .reply:
            if deviceID != owner || command.runID != snapshot.runID { error = "Only the initiating device can resume this task." }
            else if let mode = command.mode, mode != taskMode?.rawValue { error = "Stop this task before changing providers." }
            else if let model = command.model, model != taskOpenAIOptions?.model.rawValue { error = "Stop this task before changing models." }
            else if let effort = command.thinking, effort != taskOpenAIOptions?.effectiveEffort.rawValue { error = "Stop this task before changing thinking." }
            else if let reason = readinessError(deviceID) { error = reason }
            else if cleaningUp { error = "Inputs are being released. Try Resume again." }
            else if ![.paused, .awaitingUser].contains(snapshot.phase) { error = "Pause or wait for a question before replying." }
            else {
                if let text = command.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    guard text.utf8.count <= 16_384 else { respond(to: deviceID, command: command.id, error: "Reply is too long."); return }
                    append(role: "user", text: text)
                }
                lastSupervision = Date(); activeSeconds = 0; segmentActions = 0
                launch()
            }
        case .approve, .retryApproval:
            if deviceID != owner || command.runID != snapshot.runID || snapshot.approval == nil || command.approvalID != snapshot.approval?.id || snapshot.phase != .awaitingApproval || approvalContinuation == nil { error = "This approval expired. Review the current task." }
            else {
                let continuation = approvalContinuation; approvalContinuation = nil
                ComputerUseDiagnostics.event("approval.answer", run: snapshot.runID, ["approved": String(command.approved == true), "continuationPresent": String(continuation != nil)])
                snapshot.approval = nil
                continuation?.resume(returning: command.kind == .retryApproval ? .retry : command.approved == true ? .allow : .decline)
            }
        case .capabilities: break
        }
        if command.kind != .heartbeat {
            ComputerUseDiagnostics.event("host.command_result", run: command.runID, ["kind": command.kind.rawValue, "accepted": String(error == nil), "cause": diagnosticCause(for: error)])
            processed[command.id] = (Date(), error)
            processed = processed.filter { Date().timeIntervalSince($0.value.0) < 60 }
            if processed.count > 512 { processed.removeValue(forKey: processed.min { $0.value.0 < $1.value.0 }!.key) }
            respond(to: deviceID, command: command.id, error: error)
        }
    }
    func snapshotForDevice(_ deviceID: String) -> ComputerUseSnapshot {
        var result = snapshot
        result.supportsApprovalRetry = true
        result.providerName = runtimeMode.title
        result.dataNotice = runtimeMode.dataNotice
        let models = modelCatalog.selectableModels
        let modes = ComputerUseMode.allCases.filter { readinessError(deviceID, mode: $0) == nil && !models.isEmpty }
        result.availableModels = modes.isEmpty ? [] : models.map { model in
            .init(id: model.rawValue, title: model.title, efforts: (modelCatalog.catalog.entry(model)?.efforts ?? model.efforts).map(\.rawValue))
        }
        result.defaultModel = openAIModel.rawValue
        result.defaultThinking = openAIOptions.effectiveEffort.rawValue
        result.availableModes = modes
        result.defaultMode = defaultMode
        result.available = !modes.isEmpty
        result.ownsTask = owner == deviceID
        result.canAcceptReply = owner == deviceID && !cleaningUp && [.paused, .awaitingUser].contains(snapshot.phase)
        result.sentAt = Date()
        let idleReason = modes.isEmpty ? (readinessError(deviceID) ?? "Choose an available OpenAI model in Mac settings.") : nil
        if owner != deviceID {
            result.messages = []; result.approval = nil
            result.openAICostUSD = nil; result.costEstimateIncomplete = nil
            result.status = snapshot.phase.ownsControl ? "AI is controlling this Mac" : (idleReason ?? "Ready")
        } else if !snapshot.phase.ownsControl, let reason = idleReason { result.status = reason }
        return result
    }
    private func readinessError(_ deviceID: String, mode: ComputerUseMode? = nil) -> String? {
        let mode = mode ?? runtimeMode
        if !enabled { return "Enable Computer Use in PocketCtrl settings on the Mac." }
        if !configuredModes.contains(mode) {
            return "Add the API key(s) for \(mode.title) in PocketCtrl settings on the Mac."
        }
        if observe == nil || execute == nil { return "Start hosting on the Mac first." }
        return permissionError(deviceID)
    }
    /// Classify only known local messages. Never emit the original string: a
    /// caller can supply user/model text to pause, stop, and failure paths.
    private func diagnosticCause(for reason: String?) -> String {
        guard let reason else { return "none" }
        switch reason {
        case "Enable Computer Use in PocketCtrl settings on the Mac.", "Computer Use disabled on the Mac": return "disabled"
        case "Start hosting on the Mac first.", "Hosting stopped": return "not_hosting"
        case "This task was already stopped.": return "stopped_run"
        case "Another task already owns this Mac. Stop it first.", "Another viewer is controlling this Mac.": return "control_busy"
        case "Unsupported Computer Use provider. Update both apps.": return "unsupported_mode"
        case "The selected OpenAI model is unavailable. Refresh or choose a compatible model in Mac settings.": return "model_unavailable"
        case "Enter a task of at most 16 KB.": return "invalid_task"
        case "This approval expired. Review the current task.": return "approval_owner_run_or_id_mismatch"
        case "Only the initiating device can resume this task.": return "not_owner"
        case "Stop this task before changing providers.": return "mode_changed"
        case "Inputs are being released. Try Resume again.": return "input_cleanup"
        case "Pause or wait for a question before replying.": return "not_paused"
        case "This device does not have control permission.", "Device access revoked": return "permission"
        case "No task was specified.": return "missing_run"
        case "Paused task expired": return "paused_expired"
        case "OpenAI model changed", "OpenAI thinking setting changed", "Computer Use provider changed", "Computer Use writing settings changed": return "settings_changed"
        case "API key changed", "API key removed": return "key_changed"
        case "The API key is unavailable. Unlock the Mac and check settings.", "The OpenAI text-help key is unavailable. Check Mac settings.": return "key_unavailable"
        case "Stopped. You have control.": return "user_stop"
        default:
            if ComputerUseMode.allCases.contains(where: { reason == "Add the API key(s) for \($0.title) in PocketCtrl settings on the Mac." }) { return "key_missing" }
            return "other_local_condition"
        }
    }
    private func respond(to deviceID: String, command: UUID, error: String? = nil) {
        var result = snapshotForDevice(deviceID)
        result.acknowledgedCommand = command; result.commandError = error
        sendSnapshot?(result, deviceID)
    }
    private func publish() {
        refreshPointer()
        let diagnosticState = "\(snapshot.runID?.uuidString ?? "none")|\(snapshot.phase.rawValue)|\(snapshot.approval?.id.uuidString ?? "none")"
        if diagnosticState != lastDiagnosticState {
            lastDiagnosticState = diagnosticState
            ComputerUseDiagnostics.event("host.state", run: snapshot.runID, ["phase": snapshot.phase.rawValue, "hasApproval": String(snapshot.approval != nil), "actions": String(snapshot.actions)])
        }
        snapshot.providerName = runtimeMode.title
        snapshot.dataNotice = runtimeMode.dataNotice
        snapshot.revision &+= 1
        snapshot.sentAt = Date()
        sendSnapshot?(snapshot, nil)
    }
    private func append(role: String, text: String) {
        snapshot.messages.append(.init(role: role, text: String(text.prefix(3000))))
        // UTF-8 bound keeps each snapshot within the fragmentation budget.
        while snapshot.messages.count > 20 || snapshot.messages.reduce(0, { $0 + $1.text.utf8.count }) > 24_000 { snapshot.messages.removeFirst() }
    }
    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard gate.isValid(token) else { throw CancellationError() }
        if let owner, let reason = readinessError(owner) {
            ComputerUseDiagnostics.event("task.readiness_lost", run: snapshot.runID, ["cause": diagnosticCause(for: reason)])
            throw ComputerUseFailure(reason)
        }
        guard Date().timeIntervalSince(lastSupervision) < limits.supervisionTimeout else {
            ComputerUseDiagnostics.event("task.supervision_lost", run: snapshot.runID)
            throw ComputerUseFailure("Supervision connection lost")
        }
    }
    private func tick() {
        stoppedRuns = stoppedRuns.filter { Date().timeIntervalSince($0.value) < 60 }
        if snapshot.phase.ownsControl && snapshot.phase != .stopping {
            if let owner, let reason = readinessError(owner) { stop(reason: reason) }
            else if snapshot.phase == .paused || snapshot.phase == .awaitingUser {
                if let pausedAt, Date().timeIntervalSince(pausedAt) >= limits.pausedRetention { stop(reason: "Paused task expired") }
            } else if Date().timeIntervalSince(lastSupervision) >= limits.supervisionTimeout { pause(reason: "Connection or live video lost. Reconnect and Resume.", diagnosticCause: "supervision_lost") }
            else if snapshot.phase == .running, activeSeconds + Date().timeIntervalSince(segmentStarted) >= limits.activeRuntime { pause(reason: "10-minute limit reached. Resume to continue.", diagnosticCause: "runtime_limit") }
        }
        if refreshPointer() || Date().timeIntervalSince(lastPublish) >= 1 { lastPublish = Date(); publish() }
    }
    @discardableResult private func refreshPointer() -> Bool {
        // Immediate event feedback owns the position while input is executing.
        // Between actions, track actual cursor movement, including while the
        // model is thinking or waiting for approval. Do not track idle sessions.
        guard snapshot.phase.ownsControl, snapshot.phase != .stopping, inFlightInput == nil,
              let pointer = readPointer?(), pointer.isValid, snapshot.pointer != pointer else { return false }
        snapshot.pointer = pointer
        return true
    }
    private func launch(after previousRunner: Task<Void, Never>? = nil) {
        let mode = taskMode ?? defaultMode
        let keyAccount = Self.keyAccount
        guard let key = KeychainStore.string(forKey: keyAccount), let capture = observe, let execute else { fail("The API key is unavailable. Unlock the Mac and check settings."); return }
        runner?.cancel()
        transitionID = UUID()
        pausedAt = nil
        let token = gate.acquire()
        segmentStarted = Date()
        snapshot.phase = .starting; snapshot.status = "Inspecting the desktop"; snapshot.approval = nil; publish()
        let provider: any ComputerUseProvider
        let options = taskOpenAIOptions ?? openAIOptions
        let runID = snapshot.runID
        ComputerUseDiagnostics.event("task.segment_begin", run: runID, ["mode": mode.rawValue, "generation": String(transitionID.uuidString.prefix(8))])
        var observationCount = 0
        let observe: () async throws -> ComputerUseObservation = {
            observationCount += 1
            let started = ProcessInfo.processInfo.systemUptime
            ComputerUseDiagnostics.event("observation.requested", run: runID, ["sequence": String(observationCount)])
            do {
                let observation = try await capture()
                ComputerUseDiagnostics.event("observation.ready", run: runID, ["sequence": String(observationCount), "ms": ComputerUseDiagnostics.milliseconds(since: started), "hasScreenshot": String(!observation.png.isEmpty)])
                return observation
            } catch {
                ComputerUseDiagnostics.event("observation.failed", run: runID, ["error": ComputerUseDiagnostics.errorCode(error), "ms": ComputerUseDiagnostics.milliseconds(since: started)])
                throw error
            }
        }
        if let providerFactory { provider = providerFactory(key) }
        else { provider = OpenAIComputerUseProvider(key: key, options: options) }
        if let openAI = provider as? OpenAIComputerUseProvider {
            openAI.diagnosticRunID = runID
            configureCostReporting(openAI)
            openAI.onReviewUsage = { [weak self] input, output in
                guard let self, self.gate.isValid(token) else { return }
                self.snapshot.inputTokens += input; self.snapshot.outputTokens += output
            }
        }
        let context = snapshot.messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let instruction = "Original task: \(prompt)\nCurrent task conversation:\n\(context)\nInspect the current screenshot before continuing. Previously completed actions may already have changed the desktop. Do not repeat completed submissions."
        runner = Task { [weak self] in
            guard let self else { return }
            var stage = "observe"
            var automaticReobservations = 0
            do {
                // A cancelled input may still be unwinding on the event queue.
                // Do not inspect or plan the amended goal until it has settled.
                await previousRunner?.value
                try self.check(token)
                await self.releaseInputs?()
                try self.check(token)
                var observation = try await observe()
                try self.check(token)
                self.segmentStarted = Date(); self.snapshot.phase = .running; self.snapshot.status = "Planning next action"; self.publish()
                stage = "provider_begin"
                var turn = try await provider.begin(prompt: instruction, observation: observation)
                var turns = 0
                decisionLoop: while true {
                    try self.check(token)
                    turns += 1
                    ComputerUseDiagnostics.event("provider.turn", run: runID, ["turn": String(turns), "calls": String(turn.calls.count), "actions": String(turn.calls.reduce(0) { $0 + $1.actions.count }), "hasQuestion": String(turn.question != nil), "inputTokens": String(turn.inputTokens), "outputTokens": String(turn.outputTokens)])
                    self.snapshot.inputTokens += turn.inputTokens; self.snapshot.outputTokens += turn.outputTokens
                    if !turn.message.isEmpty { self.append(role: "assistant", text: turn.message) }
                    if let question = turn.question {
                        self.append(role: "assistant", text: question)
                        self.pause(reason: question, phase: .awaitingUser, diagnosticCause: "provider_question"); return
                    }
                    if turn.calls.isEmpty {
                        self.snapshot.phase = .stopping
                        await self.finish(phase: .completed, reason: turn.message.isEmpty ? "Task finished" : String(turn.message.prefix(160)), transition: self.transitionID, release: self.releaseInputs)
                        return
                    }
                    if turns > self.limits.turns { self.pause(reason: "Model turn limit reached. Resume to continue.", diagnosticCause: "turn_limit"); return }
                    var results: [ComputerUseCallResult] = []
                    var recovery: (cause: String, screen: ComputerUseObservation, call: Int, action: Int)?
                    callLoop: for (callIndex, call) in turn.calls.enumerated() {
                        for (actionIndex, action) in call.actions.enumerated() {
                            try self.check(token)
                            if self.segmentActions >= self.limits.actions { self.pause(reason: "100-action limit reached. Resume to continue.", diagnosticCause: "action_limit"); return }
                            stage = "observe_before_review"
                            let fresh = try await observe()
                            try self.check(token)
                            guard fresh.geometry == observation.geometry else { self.pause(reason: "Display geometry changed. Resume to inspect the desktop again.", diagnosticCause: "geometry_changed"); return }
                            observation = fresh
                            var explicitlyApproved = false
                            if action.isMutation {
                                self.snapshot.status = "Next: \(action.summary)"; self.publish()
                                stage = "review"
                                let reviewStarted = ProcessInfo.processInfo.systemUptime
                                let review = try await provider.review(action: action, observation: observation, intent: instruction)
                                ComputerUseDiagnostics.event("action.review", run: runID, ["action": ComputerUseDiagnostics.actionType(action.type), "decision": review.decision.rawValue, "ms": ComputerUseDiagnostics.milliseconds(since: reviewStarted)])
                                try self.check(token)
                                if review.decision == .handoff { self.append(role: "assistant", text: review.explanation); self.pause(reason: "Take control: \(review.explanation)", phase: .awaitingUser, diagnosticCause: "review_handoff"); return }
                                if review.decision == .confirm {
                                    self.activeSeconds += Date().timeIntervalSince(self.segmentStarted)
                                    self.snapshot.phase = .awaitingApproval; self.snapshot.status = "Approval needed"
                                    self.snapshot.approval = .init(id: UUID(), explanation: String(review.explanation.prefix(2000)))
                                    ComputerUseDiagnostics.event("approval.requested", run: runID, ["action": ComputerUseDiagnostics.actionType(action.type), "ownerOnly": "true"])
                                    self.publish()
                                    stage = "approval"
                                    let approvalStarted = ProcessInfo.processInfo.systemUptime
                                    let response = await withCheckedContinuation { self.approvalContinuation = $0 }
                                    ComputerUseDiagnostics.event("approval.wait_ended", run: runID, ["approved": String(response == .allow), "retry": String(response == .retry), "generationValid": String(self.gate.isValid(token)), "ms": ComputerUseDiagnostics.milliseconds(since: approvalStarted)])
                                    try self.check(token)
                                    if response == .retry {
                                        self.snapshot.status = "Reconsidering the next action"; self.publish()
                                        let current = try await observe()
                                        try self.check(token)
                                        recovery = ("user_requested_retry", current, callIndex, actionIndex)
                                        break callLoop
                                    }
                                    guard response == .allow else { self.append(role: "user", text: "Declined the proposed action."); self.pause(reason: "Action declined. Reply with new instructions.", phase: .awaitingUser, diagnosticCause: "approval_declined"); return }
                                    let current = try await observe()
                                    try self.check(token)
                                    if let cause = current.compatibilityFailure(with: observation, for: action, requireStableContext: true) {
                                        ComputerUseDiagnostics.event("observation.incompatible", run: runID, ["stage": "after_approval", "cause": cause, "action": ComputerUseDiagnostics.actionType(action.type)])
                                        if ["display_geometry", "sample_unavailable"].contains(cause) {
                                            self.pause(reason: "Could not validate the current screen. Resume to inspect it again.", diagnosticCause: cause); return
                                        }
                                        recovery = (cause, current, callIndex, actionIndex)
                                        break callLoop
                                    }
                                    observation = current
                                    explicitlyApproved = true
                                    self.segmentStarted = Date()
                                    self.snapshot.phase = .running
                                }
                            }
                            try self.check(token)
                            if action.isMutation {
                                let current = try await observe()
                                try self.check(token)
                                if let cause = current.compatibilityFailure(with: observation, for: action, requireStableContext: explicitlyApproved) {
                                    ComputerUseDiagnostics.event("observation.incompatible", run: runID, ["stage": "before_execution", "cause": cause, "action": ComputerUseDiagnostics.actionType(action.type)])
                                    if ["display_geometry", "sample_unavailable"].contains(cause) {
                                        self.pause(reason: "Could not validate the current screen. Resume to inspect it again.", diagnosticCause: cause); return
                                    }
                                    recovery = (cause, current, callIndex, actionIndex)
                                    break callLoop
                                }
                                observation = current
                            }
                            self.snapshot.status = action.summary; self.publish()
                            stage = "execute"
                            let started = ProcessInfo.processInfo.systemUptime
                            ComputerUseDiagnostics.event("action.begin", run: runID, ["action": ComputerUseDiagnostics.actionType(action.type), "approved": String(explicitlyApproved)])
                            let actionObservation = observation
                            let input = Task { try self.check(token); try await execute(action, actionObservation, token) }
                            self.inFlightInput = input
                            do {
                                try await withTaskCancellationHandler(operation: { try await input.value }, onCancel: { input.cancel() })
                                self.inFlightInput = nil
                            } catch {
                                self.inFlightInput = nil
                                ComputerUseDiagnostics.event("action.failed", run: runID, ["action": ComputerUseDiagnostics.actionType(action.type), "error": ComputerUseDiagnostics.errorCode(error), "ms": ComputerUseDiagnostics.milliseconds(since: started)])
                                throw error
                            }
                            // Record successful input before any fallible capture
                            // or cancellation check can discard its history.
                            provider.recordExecution(action)
                            ComputerUseDiagnostics.event("action.end", run: runID, ["action": ComputerUseDiagnostics.actionType(action.type), "ms": ComputerUseDiagnostics.milliseconds(since: started)])
                            try self.check(token)
                            self.segmentActions += 1; self.snapshot.actions += 1
                            self.append(role: "action", text: action.summary)
                        }
                        stage = "observe_after_action"
                        let before = observation
                        observation = try await observe()
                        try self.check(token)
                        ComputerUseDiagnostics.event("action.observed", run: runID, ["semanticChanged": String(before.semanticSignature != observation.semanticSignature), "pixelsChanged": String(before.fingerprint != observation.fingerprint), "focusAppChanged": String(before.focusedApplicationID != observation.focusedApplicationID)])
                        results.append(.init(id: call.id, observation: observation))
                    }
                    if let recovery {
                        // Discard the stale batch; never replay its earlier actions.
                        // Return every outstanding call ID and explicitly describe
                        // partial execution so the model can replan in this run.
                        if recovery.cause != "user_requested_retry" {
                            guard automaticReobservations < 3 else {
                                self.pause(reason: "The target is still changing after three automatic retries. Let the screen settle, then Resume.", diagnosticCause: "reobserve_limit"); return
                            }
                            automaticReobservations += 1
                        }
                        observation = recovery.screen
                        for (index, call) in turn.calls.enumerated() where index >= recovery.call {
                            results.append(.init(id: call.id, observation: observation,
                                executedActions: index == recovery.call ? recovery.action : 0,
                                skippedReason: recovery.cause))
                        }
                        if self.snapshot.phase == .awaitingApproval { self.segmentStarted = Date() }
                        self.snapshot.approval = nil
                        self.snapshot.phase = .running
                        ComputerUseDiagnostics.event("observation.replanning", run: runID,
                            ["cause": recovery.cause, "attempt": String(automaticReobservations), "completedActions": String(self.snapshot.actions)])
                    }
                    self.snapshot.status = recovery?.cause == "user_requested_retry" ? "Reconsidering the next action" : recovery == nil ? "Planning next action" : "Screen updated · Replanning"; self.publish()
                    stage = "provider_next"
                    turn = try await provider.next(results: results)
                }
            } catch is CancellationError {
                ComputerUseDiagnostics.event("task.segment_cancelled", run: runID, ["stage": stage])
            }
            catch {
                ComputerUseDiagnostics.event("task.error", run: runID, ["stage": stage, "error": ComputerUseDiagnostics.errorCode(error)])
                guard self.gate.isValid(token) else { return }
                self.pause(reason: error.localizedDescription, diagnosticCause: "stage_error")
            }
        }
    }
    private func configureCostReporting(_ provider: OpenAIComputerUseProvider?) {
        let runID = snapshot.runID
        provider?.onUsageCost = { [weak self] cost in
            // A late response can update the same stopped task's estimate, never a new task.
            guard let self, let runID, self.snapshot.runID == runID else { return }
            if let cost { self.snapshot.openAICostUSD = (self.snapshot.openAICostUSD ?? 0) + cost }
            else { self.snapshot.costEstimateIncomplete = true }
            self.publish()
        }
    }
    func pause(reason: String, phase: ComputerUsePhase = .paused, diagnosticCause: String = "external_request") {
        guard snapshot.phase.ownsControl, ![.stopping, .paused, .awaitingUser].contains(snapshot.phase) else { return }
        ComputerUseDiagnostics.event("task.paused", run: snapshot.runID, ["cause": diagnosticCause, "phase": phase.rawValue, "actions": String(snapshot.actions), "supervisionAgeMs": String(Int(max(0, Date().timeIntervalSince(lastSupervision)) * 1000))])
        gate.invalidate(release: false); runner?.cancel(); runner = nil
        approvalContinuation?.resume(returning: .decline); approvalContinuation = nil
        snapshot.approval = nil
        if snapshot.phase == .running || snapshot.phase == .starting { activeSeconds += Date().timeIntervalSince(segmentStarted) }
        snapshot.phase = phase; snapshot.status = reason; pausedAt = Date()
        cleaningUp = true; publish()
        transitionID = UUID()
        let transition = transitionID, release = releaseInputs, input = inFlightInput
        Task { [weak self] in
            await release?()
            _ = await input?.result
            guard let self, self.transitionID == transition else { return }
            self.cleaningUp = false
            self.publish()
        }
    }
    func stop(reason: String = "Stopped. You have control.") {
        guard snapshot.phase.ownsControl, snapshot.phase != .stopping else { return }
        ComputerUseDiagnostics.event("task.stop", run: snapshot.runID, ["phase": snapshot.phase.rawValue, "cause": diagnosticCause(for: reason)])
        gate.invalidate(release: false); runner?.cancel(); runner = nil
        if let runID = snapshot.runID { stoppedRuns[runID] = Date() }
        approvalContinuation?.resume(returning: .decline); approvalContinuation = nil
        snapshot.approval = nil; snapshot.phase = .stopping; snapshot.status = "Stopping"; publish()
        transitionID = UUID()
        let transition = transitionID, release = releaseInputs, input = inFlightInput
        Task { [weak self] in
            await release?()
            _ = await input?.result
            await self?.finish(phase: .cancelled, reason: reason, transition: transition, release: release)
        }
    }
    private func fail(_ reason: String) {
        ComputerUseDiagnostics.event("task.failed", run: snapshot.runID, ["cause": diagnosticCause(for: reason)])
        transitionID = UUID()
        let transition = transitionID, release = releaseInputs
        Task { [weak self] in await self?.finish(phase: .failed, reason: reason, transition: transition, release: release) }
    }
    private func finish(phase: ComputerUsePhase, reason: String, transition: UUID, release: (() async -> Void)?) async {
        guard transitionID == transition else { return }
        gate.invalidate(release: false)
        await release?()
        guard transitionID == transition else { return }
        gate.invalidate(release: true)
        ComputerUseDiagnostics.event("task.finished", run: snapshot.runID, ["phase": phase.rawValue, "actions": String(snapshot.actions), "inputTokens": String(snapshot.inputTokens), "outputTokens": String(snapshot.outputTokens)])
        snapshot.phase = phase; snapshot.status = reason; snapshot.approval = nil
        cleaningUp = false; pausedAt = nil; publish()
    }
}
