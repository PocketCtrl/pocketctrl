// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// Shared treatment for the floating viewer HUD, not the remote video itself.
struct ViewerGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.12), in: shape)
                .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 0.5))
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.12)).interactive(interactive), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

struct ViewerGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 4) { content() }
        } else {
            content()
        }
    }
}

struct ComputerUseActivityBubble: View {
    @ObservedObject var session: ClientComputerUseSession
    @Binding var isExpanded: Bool
    var maximumHeight: CGFloat = 300
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let message = session.activityText {
            Group {
                if isExpanded {
                    // Grow to fit normal messages. Exceptionally long messages
                    // scroll rather than extending beyond the viewer's safe area.
                    ViewThatFits(in: .vertical) {
                        messageText(message).fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            messageText(message).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: max(44, maximumHeight - 24))
                    }
                    .frame(maxHeight: max(44, maximumHeight - 24))
                } else {
                    messageText(message).lineLimit(2)
                }
            }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: isExpanded ? .infinity : 340, minHeight: 44)
                .modifier(ViewerGlassSurface(shape: RoundedRectangle(cornerRadius: 14), interactive: true))
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture { toggle() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Computer Use: \(message)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isExpanded ? "Double-tap to collapse" : "Double-tap to show the full message")
                .accessibilityAction { toggle() }
                .accessibilityIdentifier("computer-use-activity")
        }
    }
    private func messageText(_ message: String) -> some View {
        Text(message)
            .font(.caption.weight(.medium))
            .foregroundStyle(session.attentionMessage == nil ? Color.white.opacity(0.8) : .orange)
            .multilineTextAlignment(.center)
    }
    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { isExpanded.toggle() }
    }
}

/// Symmetric space around the status keeps it screen-centered, not merely
/// centered in the space left over by differently sized controls.
struct ViewerTopControlRow<Leading: View, Trailing: View>: View {
    @ObservedObject var session: ClientComputerUseSession
    let isCompact: Bool
    let showsActivity: Bool
    let reservesHelp: Bool
    var availableHeight: CGFloat = 600
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activityExpanded = false
    private var controlHeight: CGFloat { isCompact ? 60 : 64 }
    private var expandedTop: CGFloat { controlHeight + 34 }
    var body: some View {
        ViewerGlassGroup {
            ZStack(alignment: .top) {
                if showsActivity {
                    ComputerUseActivityBubble(session: session, isExpanded: $activityExpanded,
                                             maximumHeight: max(68, availableHeight - expandedTop - (isCompact ? 100 : 190)))
                        .padding(.horizontal, activityExpanded ? 0 : (reservesHelp ? 122 : 88))
                        .padding(.top, activityExpanded ? expandedTop : 8)
                        .frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 8) {
                    leading().fixedSize()
                    Spacer(minLength: 8)
                    trailing().fixedSize()
                }
            }
            .frame(minHeight: controlHeight, alignment: .top)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: isCompact)
        .onChange(of: session.snapshot?.runID) { _, _ in activityExpanded = false }
        .onChange(of: session.activityText == nil || !showsActivity) { _, hidden in
            if hidden { activityExpanded = false }
        }
    }
}

struct ComputerUseRobotIcon: View {
    var body: some View {
        VStack(spacing: 1) {
            Circle().frame(width: 4, height: 4)
            RoundedRectangle(cornerRadius: 5)
                .stroke(lineWidth: 1.7)
                .overlay {
                    VStack(spacing: 3) {
                        HStack(spacing: 6) { Circle().frame(width: 3, height: 3); Circle().frame(width: 3, height: 3) }
                        Capsule().frame(width: 7, height: 2)
                    }
                }.frame(width: 21, height: 17)
        }.frame(width: 26, height: 26)
    }
}
struct ComputerUseViewerButton: View {
    @ObservedObject var session: ClientComputerUseSession
    var isCompact = false
    @State private var showingTask = false
    @StateObject private var speech = ClientSpeechInput()
    @Environment(\.scenePhase) private var scenePhase
    @State private var holding = false
    @State private var finishing: Task<Void, Never>?
    @State private var voiceID: UUID?
    var body: some View {
        Group {
            Group {
                if holding || speech.isFinishing { Image(systemName: "mic.fill").foregroundStyle(.red) }
                else { ComputerUseRobotIcon().foregroundStyle(.white) }
            }
                .frame(width: isCompact ? 44 : 52, height: isCompact ? 44 : 52)
                .modifier(ViewerGlassSurface(shape: Circle(), interactive: true))
                .frame(width: isCompact ? 60 : 64, height: isCompact ? 60 : 64)
                .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openTask() }
        .accessibilityLabel("Computer Use")
        .accessibilityHint("Tap to type or change instructions. Hold to speak, then release to send.")
        .overlay {
            RobotPressSurface(tap: openTask, began: beginVoice, ended: finishVoice, cancelled: cancelVoice)
                .accessibilityHidden(true)
        }
        .accessibilityAction(named: holding ? "Send spoken instruction" : "Speak an instruction") {
            if holding { finishVoice() } else { beginVoice() }
        }
        .overlay(alignment: .bottomTrailing) {
            if holding || speech.isFinishing {
                Text(speech.isFinishing ? "Finishing…" : speech.isStarting ? "Preparing mic…" : "Release to send")
                    .font(.caption2).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.8), in: Capsule())
                    .fixedSize().offset(y: -64).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if let cost = session.liveCostText {
                Text(cost)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.horizontal, 7).padding(.vertical, 6)
                    .frame(width: 80)
                    .modifier(ViewerGlassSurface(shape: Capsule()))
                    .offset(y: isCompact ? 60 : 64)
                    .accessibilityLabel("Estimated task cost in US dollars: \(cost)")
                    .accessibilityHint("Updates after API responses. Open the robot button for estimate details.")
                    .accessibilityIdentifier("computer-use-live-cost")
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showingTask) { ComputerUseTaskSheet(session: session) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancelVoice() } }
        .onChange(of: session.isReconnecting) { _, lost in if lost { cancelVoice() } }
        .onChange(of: session.stopping) { _, stopped in if stopped { cancelVoice() } }
        .onReceive(NotificationCenter.default.publisher(for: ClientAudioSession.recordingMustStop)) { _ in cancelVoice() }
        .onDisappear { cancelVoice() }
        .alert("Voice Input", isPresented: Binding(get: { speech.alertMessage != nil }, set: { if !$0 { speech.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
            if speech.shouldOfferSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } message: { Text(speech.alertMessage ?? "") }
    }
    private func openTask() {
        cancelVoice(); session.beginEditingInstruction(); showingTask = true
    }
    private func beginVoice() {
        guard !holding, finishing == nil, session.canEditInstruction else { return }
        session.beginEditingInstruction()
        voiceID = UUID(); holding = true
        speech.start()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func finishVoice() {
        guard holding, let id = voiceID else { return }
        holding = false
        finishing = Task { @MainActor in
            let text = await speech.finish()
            guard !Task.isCancelled, voiceID == id else { return }
            finishing = nil; voiceID = nil
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            session.instructionDraft = text
            if !session.submitInstruction() { showingTask = true }
        }
    }
    private func cancelVoice() {
        voiceID = nil; holding = false
        finishing?.cancel(); finishing = nil; speech.stop()
    }
}

/// UIKit distinguishes release from gesture cancellation; a cancelled hold must
/// never submit speech. A short tap and a hold are mutually exclusive.
private struct RobotPressSurface: UIViewRepresentable {
    var tap: () -> Void
    var began: () -> Void
    var ended: () -> Void
    var cancelled: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.3; hold.allowableMovement = 60
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold); view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject {
        var parent: RobotPressSurface
        init(_ parent: RobotPressSurface) { self.parent = parent }
        @objc func tap() { parent.tap() }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began: parent.began()
            case .ended: parent.ended()
            case .cancelled, .failed: parent.cancelled()
            default: break
            }
        }
    }
}

/// Replaces manual input islands while AI owns the viewer. Long approval text
/// scrolls inside the safe-area canvas instead of truncating the request.
struct ComputerUseViewerControls: View {
    @ObservedObject var session: ClientComputerUseSession
    let isCompact: Bool
    @State private var showingTask = false
    private var buttonWidth: CGFloat { isCompact ? 120 : 144 }
    private var buttonHeight: CGFloat { isCompact ? 56 : 68 }
    var body: some View {
        if session.showsAIControls {
            VStack(spacing: 10) {
                if let approval = session.visibleApproval {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Allow this action?").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button { showingTask = true } label: {
                                Image(systemName: "ellipsis").frame(width: 44, height: 28)
                                    .contentShape(Rectangle())
                            }.accessibilityLabel("Computer Use details")
                        }
                        ScrollView {
                            Text(approval.explanation)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: isCompact ? 58 : 100)
                        .id(approval.id)
                        .accessibilityIdentifier("computer-use-approval-explanation")
                        HStack {
                            Spacer()
                            if session.snapshot?.supportsApprovalRetry == true {
                                ComputerUseRetryButton(session: session, approvalID: approval.id)
                            }
                            Button("Make changes") { session.beginEditingInstruction(); showingTask = true }
                                .font(.caption.weight(.semibold)).frame(minHeight: 44)
                                .disabled(!session.canEditInstruction)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.18), lineWidth: 1))
                }
                HStack {
                    controlButton(session.stopping ? "Stopping…" : "Stop", symbol: "stop.fill", color: .red) {
                        session.stop()
                    }
                    .disabled(session.stopping)
                    .accessibilityIdentifier("computer-use-stop")
                    Spacer(minLength: 12)
                    if let approval = session.visibleApproval, session.submittedApprovalID != approval.id {
                        controlButton("Allow", symbol: "checkmark", color: .blue) {
                            session.approve(true, approvalID: approval.id)
                        }
                        .accessibilityHint("Allow only the action described above")
                        .accessibilityIdentifier("computer-use-allow")
                    } else if session.showsResumeControl {
                        controlButton("Resume", symbol: "play.fill", color: .blue) {
                            if session.snapshot?.phase == .awaitingUser {
                                showingTask = true
                            } else {
                                session.resume()
                            }
                        }
                        .accessibilityHint(session.snapshot?.phase == .awaitingUser
                            ? "Open the task to answer the Mac’s question"
                            : "Inspect the screen again and continue the paused task")
                        .accessibilityIdentifier("computer-use-resume")
                    } else {
                        controlButton(session.progressControlTitle, symbol: "", color: .blue, isLoading: true) {}
                            .disabled(true)
                            .accessibilityLabel("Computer Use \(session.progressControlTitle)")
                            .accessibilityIdentifier("computer-use-working")
                    }
                }
            }
            .sheet(isPresented: $showingTask) { ComputerUseTaskSheet(session: session) }
        }
    }
    private func controlButton(_ title: String, symbol: String, color: Color, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(color)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
            }
                .font(.system(size: isCompact ? 15 : 17, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: buttonWidth, height: buttonHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(ComputerUseControlButtonStyle(color: color))
    }
}

private struct ComputerUseControlButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .background(Capsule().inset(by: 8).fill(color.opacity(configuration.isPressed ? 0.26 : 0.14)))
            .overlay(Capsule().inset(by: 8).strokeBorder(color.opacity(0.55), lineWidth: 1))
            .background(.black.opacity(0.58), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}/// Composer stays pinned above the conversation; the transcript scrolls beneath
/// it newest-first so the latest reply is always beside the input.
struct ComputerUseTaskSheet: View {
    @ObservedObject var session: ClientComputerUseSession
    @Environment(\.dismiss) private var dismiss
    private var draft: String {
        get { session.instructionDraft }
        nonmutating set { session.instructionDraft = newValue }
    }
    @State private var confirmingNewChat = false
    @State private var showingCostDetails = false
    @FocusState private var focused: Bool

    private var waitingForReply: Bool { session.showsResumeControl }
    private var composerEnabled: Bool { session.canEditInstruction || session.queuedInstruction }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmedDraft.isEmpty && session.canEditInstruction }

    var body: some View {
        NavigationStack {
            ZStack {
                SettingsBackground()
                VStack(spacing: 12) {
                    VStack(spacing: 10) {
                        if composerEnabled {
                            composer
                            if session.isEditingTask {
                                Text("Make changes to this task. Send to continue with your new instructions.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if waitingForReply { replyActions }
                            else if session.blocksInput { workingActions }
                        } else if session.blocksInput {
                            workingActions
                        }
                        HStack(spacing: 8) {
                            ComputerUseOptionsRow(session: session)
                            ComputerUseCostButton(session: session) { showingCostDetails = true }
                        }
                    }
                    .padding(.horizontal, 18)

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            if let approval = session.visibleApproval {
                                ComputerUseApprovalCard(session: session, approval: approval) {
                                    session.beginEditingInstruction(); focused = true
                                }
                            }
                            if let notice = session.sheetNotice {
                                ComputerUseMessageRow(message: .init(role: notice.isWarning ? "warning" : "status", text: notice.text))
                                    .accessibilityIdentifier("computer-use-sheet-notice")
                            }
                            ComputerUseTranscript(messages: session.visibleMessages,
                                                  warningMessageID: session.sheetWarningMessageID)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 2)
                        .padding(.bottom, 32)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .padding(.top, 6)
            }
            .navigationTitle("Computer Use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: requestNewChat) {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(!session.canStartNewChat)
                    .accessibilityLabel("New chat")
                    .accessibilityHint(session.newChatStopsTask ? "Stops the current task and clears the conversation" : "Clears the conversation")
                    .accessibilityIdentifier("computer-use-new-chat")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .confirmationDialog("Start a new chat?", isPresented: $confirmingNewChat, titleVisibility: .visible) {
                Button("Stop Task and Start New", role: .destructive) { session.newChat(); draft = "" }
            } message: {
                Text("The current task will be stopped.")
            }
            .alert("Estimated Cost", isPresented: $showingCostDetails) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(costDetails)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground { SettingsBackground() }
        .preferredColorScheme(.dark)
        .onAppear { session.beginEditingInstruction(); focused = composerEnabled }
        .onChange(of: composerEnabled) { _, enabled in
            if enabled { focused = true }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(session.isEditingTask ? "Make changes to this task…" : "What should your Mac do?", text: $session.instructionDraft, axis: .vertical)
                .lineLimit(1...5)
                .foregroundStyle(.white)
                .tint(.white)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.vertical, 9)
                .accessibilityIdentifier("computer-use-task-field")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.blue : Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.bottom, 4)
            .accessibilityLabel(waitingForReply ? "Send reply" : "Send task")
            .accessibilityIdentifier("computer-use-send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(focused ? 0.22 : 0.12), lineWidth: 1))
        .animation(.easeInOut(duration: 0.15), value: focused)
    }

    private var replyActions: some View {
        HStack(spacing: 10) {
            Button { session.resume(); dismiss() } label: {
                Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(ComputerUseSheetButtonStyle(tint: .white))
            .accessibilityHint("Continue without new instructions")
            .accessibilityIdentifier("computer-use-sheet-resume")
            stopButton
        }
    }

    private var workingActions: some View {
        HStack(spacing: 10) {
            if session.canPause {
                Button { session.pause() } label: {
                    Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(ComputerUseSheetButtonStyle(tint: .white))
                .accessibilityHint("Pause the task to give new instructions")
                .accessibilityIdentifier("computer-use-pause")
            }
            stopButton
        }
    }

    private var stopButton: some View {
        Button { session.stop() } label: {
            Label(session.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(ComputerUseSheetButtonStyle(tint: .red))
        .disabled(session.stopping)
        .accessibilityIdentifier("computer-use-sheet-stop")
    }

    private var costDetails: String {
        guard let snapshot = session.snapshot, let cost = snapshot.openAICostText else { return "No usage reported yet." }
        var lines = ["\(cost) so far, from usage reported by OpenAI."]
        if let date = snapshot.pricingVerifiedAt { lines.append("Rates verified \(date).") }
        lines.append(snapshot.costEstimateIncomplete == true
            ? "Some usage was unavailable, so this is a partial estimate."
            : "Includes safety reviews.")
        lines.append("Not a spending limit. Actual charges may differ.")
        return lines.joined(separator: "\n")
    }

    private func requestNewChat() {
        if session.newChatStopsTask {
            confirmingNewChat = true
        } else {
            session.newChat(); draft = ""; focused = true
        }
    }

    private func send() {
        guard canSend else { return }
        if session.submitInstruction() { focused = false; dismiss() }
    }
}

private struct ComputerUseCostButton: View {
    @ObservedObject var session: ClientComputerUseSession
    let onCostTap: () -> Void
    var body: some View {
        if let cost = session.costText {
            Button(action: onCostTap) {
                Text(cost)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Estimated cost \(cost)")
            .accessibilityHint("Shows how the estimate is calculated")
            .accessibilityIdentifier("computer-use-cost")
        }
    }
}

/// Model and thinking chips while idle; a one-line summary once a task has frozen them.
private struct ComputerUseOptionsRow: View {
    @ObservedObject var session: ClientComputerUseSession
    private var models: [ComputerUseModelChoice] { session.snapshot?.availableModels ?? [] }
    private var selected: ComputerUseModelChoice? { models.first { $0.id == session.selectedModel } }
    private var efforts: [String] { selected?.efforts ?? ["automatic"] }
    private var modelTitle: String { selected?.title ?? (session.selectedModel.isEmpty ? "Mac default" : session.selectedModel) }
    private var thinkingTitle: String { Self.effortTitle(session.selectedThinking) }
    var body: some View {
        HStack(spacing: 8) {
            if session.blocksInput {
                if session.snapshot?.ownsTask == true {
                    Text(session.snapshot?.modelDescription ?? "\(modelTitle) · \(thinkingTitle)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            } else if !models.isEmpty {
                Menu {
                    Picker("Model", selection: $session.selectedModel) {
                        ForEach(models) { model in Text(model.title).tag(model.id) }
                        if selected == nil {
                            Text(modelTitle + " (unavailable)").tag(session.selectedModel)
                        }
                    }
                } label: {
                    chip("cpu", modelTitle)
                }
                .accessibilityLabel("Model: \(modelTitle)")
                .accessibilityIdentifier("computer-use-model")
                Menu {
                    Picker("Thinking", selection: $session.selectedThinking) {
                        ForEach(efforts, id: \.self) { effort in Text(Self.effortTitle(effort)).tag(effort) }
                    }
                } label: {
                    chip("brain", thinkingTitle)
                }
                .accessibilityLabel("Thinking: \(thinkingTitle)")
                .accessibilityIdentifier("computer-use-thinking")
            }
            Spacer(minLength: 0)
        }
        .onChange(of: session.selectedModel) { _, _ in
            if !efforts.contains(session.selectedThinking) { session.selectedThinking = "automatic" }
        }
    }
    private func chip(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption2.weight(.semibold))
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
    static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "automatic": return "Default thinking"
        case "xhigh": return "Extra high thinking"
        case "max": return "Maximum thinking"
        default: return effort.capitalized + " thinking"
        }
    }
}

private struct ComputerUseApprovalCard: View {
    @ObservedObject var session: ClientComputerUseSession
    let approval: ComputerUseApproval
    let makeChanges: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow this action?", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(approval.explanation)
                .font(.callout)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("computer-use-sheet-approval-explanation")
            HStack(spacing: 10) {
                Button { session.approve(false, approvalID: approval.id) } label: {
                    Label("Decline", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(ComputerUseSheetButtonStyle(tint: .white))
                .accessibilityIdentifier("computer-use-decline")
                Button { session.approve(true, approvalID: approval.id); dismiss() } label: {
                    Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(ComputerUseSheetButtonStyle(tint: .blue, isProminent: true))
                .accessibilityHint("Allow only the action described above")
                .accessibilityIdentifier("computer-use-sheet-allow")
            }
            .disabled(session.submittedApprovalID == approval.id || session.stopping)
            HStack {
                Spacer()
                if session.snapshot?.supportsApprovalRetry == true {
                    ComputerUseRetryButton(session: session, approvalID: approval.id)
                }
                Button("Make changes", action: makeChanges)
                    .font(.caption.weight(.semibold)).frame(minHeight: 44)
                    .disabled(!session.canEditInstruction)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.yellow.opacity(0.65), lineWidth: 1))
        .id(approval.id)
    }
}

private struct ComputerUseTranscript: View {
    let messages: [ComputerUseMessage]
    var warningMessageID: UUID?
    var body: some View {
        if messages.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.28))
                    .accessibilityHidden(true)
                Text(ComputerUseMode.openAI.dataNotice)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.horizontal, 12)
        } else {
            // Newest first, so the latest reply sits directly under the composer.
            ForEach(Array(messages.reversed())) { message in
                ComputerUseMessageRow(message: message, isWarning: message.id == warningMessageID)
            }
        }
    }
}

private struct ComputerUseMessageRow: View {
    let message: ComputerUseMessage
    var isWarning = false
    private var warning: Bool { isWarning || ["warning", "error"].contains(message.role) }
    var body: some View {
        Group {
            if warning {
                HStack { bubble(fill: .white.opacity(0.08), stroke: .yellow.opacity(0.75)); Spacer(minLength: 44) }
            } else {
                switch message.role {
                case "user":
                    HStack { Spacer(minLength: 44); bubble(fill: Color.blue.opacity(0.80), stroke: .clear) }
                case "action":
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "cursorarrow.click.2").font(.caption2)
                        Text(message.text).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                default:
                    HStack { bubble(fill: .white.opacity(0.08), stroke: .white.opacity(0.10)); Spacer(minLength: 44) }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(warning ? "Needs attention" : roleName): \(message.text)")
    }
    private var roleName: String {
        switch message.role {
        case "user": return "You"
        case "assistant": return "Mac"
        case "action": return "Action"
        default: return message.role.capitalized
        }
    }
    private func bubble(fill: Color, stroke: Color) -> some View {
        Text(message.text)
            .font(.callout)
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

private struct ComputerUseSheetButtonStyle: ButtonStyle {
    var tint: Color
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(isProminent ? Color.white : tint)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(fill(configuration), in: Capsule())
            .overlay(Capsule().strokeBorder((isProminent ? Color.white : tint).opacity(isProminent ? 0.16 : 0.22), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
    private func fill(_ configuration: Configuration) -> Color {
        if isProminent { return tint.opacity(configuration.isPressed ? 0.70 : 0.92) }
        return tint.opacity(configuration.isPressed ? 0.20 : 0.10)
    }
}

private struct ComputerUseRetryButton: View {
    @ObservedObject var session: ClientComputerUseSession
    let approvalID: UUID
    var body: some View {
        Button("Try again") { session.retryApproval(approvalID) }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(session.submittedApprovalID == approvalID || session.stopping)
            .accessibilityHint("Ask the model to reconsider without allowing this action")
            .accessibilityIdentifier("computer-use-retry-approval")
    }
}

#if DEBUG
/// Local snapshot fixtures only: no connection, microphone or provider requests.
enum ComputerUseSheetFixture {
    enum State: String, CaseIterable { case idle, running, question, approval }
    @MainActor static func session(_ state: State) -> ClientComputerUseSession {
        let session = ClientComputerUseSession()
        session.canSupervise = { true }
        for fragment in ComputerUseFragment.encode(snapshot(state)) { session.receive(fragment) }
        return session
    }
    static func snapshot(_ state: State) -> ComputerUseSnapshot {
        var snapshot = ComputerUseSnapshot()
        snapshot.available = true; snapshot.supportsApprovalRetry = true
        snapshot.availableModels = [
            .init(id: "gpt-6-luna", title: "GPT-6 Luna", efforts: ["automatic", "none", "low", "medium", "high"]),
            .init(id: "gpt-6-sol", title: "GPT-6 Sol", efforts: ["automatic", "low", "medium", "high", "xhigh"])
        ]
        snapshot.defaultModel = "gpt-6-luna"; snapshot.defaultThinking = "automatic"
        if state != .idle {
            snapshot.runID = UUID(); snapshot.ownsTask = true
            snapshot.taskModel = "gpt-6-luna"; snapshot.taskThinking = "medium"
            snapshot.modelDescription = "GPT-6 Luna · Medium thinking"
            snapshot.pricingVerifiedAt = "2026-09-22"
            snapshot.openAICostUSD = 0.0123
            snapshot.messages = [
                .init(role: "user", text: "Open Safari and check tomorrow's weather in Seattle."),
                .init(role: "action", text: "Click Safari in the Dock"),
                .init(role: "action", text: "Type “Seattle weather tomorrow”"),
                .init(role: "assistant", text: "Tomorrow in Seattle looks like light rain with a high of 61°F. Do you want me to add it to Notes?")
            ]
        }
        switch state {
        case .idle: break
        case .running:
            snapshot.phase = .running; snapshot.status = "Next: Press keyboard shortcut"
        case .question:
            snapshot.phase = .awaitingUser; snapshot.status = "Do you want me to add it to Notes?"
        case .approval:
            snapshot.phase = .awaitingApproval; snapshot.status = "Approval needed"
            snapshot.approval = .init(id: UUID(), explanation: "Send the drafted email to alex@example.com with the weather summary.")
        }
        return snapshot
    }
}

private struct ComputerUseHUDPreview: View {
    let compact: Bool
    @StateObject private var session: ClientComputerUseSession
    init(compact: Bool, paused: Bool = false) {
        self.compact = compact
        let session = ClientComputerUseSession()
        var snapshot = ComputerUseSnapshot()
        snapshot.runID = UUID(); snapshot.ownsTask = true
        snapshot.phase = paused ? .paused : .running
        snapshot.status = paused ? "Connection lost. Reconnect and Resume." : "Next: Press keyboard shortcut"
        snapshot.openAICostUSD = 0.0123
        for fragment in ComputerUseFragment.encode(snapshot) { session.receive(fragment) }
        _session = StateObject(wrappedValue: session)
    }
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.indigo, .black, .gray], startPoint: .topLeading, endPoint: .bottomTrailing)
            ViewerTopControlRow(session: session, isCompact: compact, showsActivity: true, reservesHelp: false) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.white)
                    .frame(width: compact ? 44 : 52, height: compact ? 44 : 52)
                    .modifier(ViewerGlassSurface(shape: Circle(), interactive: true))
                    .frame(width: compact ? 60 : 64, height: compact ? 60 : 64)
            } trailing: {
                ComputerUseViewerButton(session: session, isCompact: compact)
            }
            .padding(.horizontal, compact ? 10 : 14).padding(.top, 10)
        }
        .frame(width: compact ? 740 : 375, height: 180)
        .preferredColorScheme(.dark)
    }
}

#Preview("AI HUD · Portrait", traits: .sizeThatFitsLayout) {
    ComputerUseHUDPreview(compact: false)
}
#Preview("AI HUD · Landscape", traits: .sizeThatFitsLayout) {
    ComputerUseHUDPreview(compact: true)
}
#Preview("AI HUD · Needs attention", traits: .sizeThatFitsLayout) {
    ComputerUseHUDPreview(compact: false, paused: true)
}
#Preview("AI status · Expanded", traits: .sizeThatFitsLayout) {
    @Previewable @State var expanded = true
    ComputerUseActivityBubble(session: ComputerUseSheetFixture.session(.question), isExpanded: $expanded,
                             maximumHeight: 240)
        .frame(width: 347).padding().background(.black).preferredColorScheme(.dark)
}
#Preview("AI status · Large text", traits: .sizeThatFitsLayout) {
    @Previewable @State var expanded = true
    ComputerUseActivityBubble(session: ComputerUseSheetFixture.session(.question), isExpanded: $expanded,
                             maximumHeight: 120)
        .frame(width: 347).padding().background(.black).preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#Preview("Task sheet · Idle") {
    ComputerUseTaskSheet(session: ComputerUseSheetFixture.session(.idle))
}
#Preview("Task sheet · Running") {
    ComputerUseTaskSheet(session: ComputerUseSheetFixture.session(.running))
}
#Preview("Task sheet · Question") {
    ComputerUseTaskSheet(session: ComputerUseSheetFixture.session(.question))
}
#Preview("Task sheet · Approval") {
    ComputerUseTaskSheet(session: ComputerUseSheetFixture.session(.approval))
}
#endif
