// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct ComputerUseSettingsView: View {
    @ObservedObject var model: RemoteDesktopModel
    @ObservedObject var coordinator: ComputerUseCoordinator
    @State private var keyDraft = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Computer Use").font(.title2.bold())
                Text("Give a task to your Mac from the robot button in the iPhone viewer. Keep the viewer open to supervise.")
                    .foregroundStyle(.secondary)
                Toggle("Enable Computer Use", isOn: $coordinator.enabled)
                GroupBox("OpenAI") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(coordinator.hasKey ? "API key saved on this Mac" : "No API key configured").font(.caption)
                        SecureField("OpenAI API key", text: $keyDraft)
                            .textContentType(.password)
                        HStack {
                            Button(coordinator.hasKey ? "Replace Key" : "Save Key") {
                                coordinator.saveKey(keyDraft); keyDraft = ""
                                Task { await coordinator.refreshModels(force: true) }
                            }.disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Delete Key", role: .destructive) { coordinator.deleteKey() }.disabled(!coordinator.hasKey)
                            Button(coordinator.isTesting ? "Testing…" : "Test Connection") {
                                Task { await coordinator.testConnection() }
                            }.disabled(!coordinator.hasKey || coordinator.isTesting)
                        }
                        Text(coordinator.dataNotice + " API usage is billed to your OpenAI account. Your key stays in this Mac’s Keychain. Task history stays in memory; OpenAI’s data policies still apply.")
                            .font(.caption).foregroundStyle(.secondary)
                        OpenAIModelSettings(coordinator: coordinator, catalog: coordinator.modelCatalog)
                        Text("Thinking applies to actions and reviews. More thinking can take longer and cost more. Changing these settings stops the current task.")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("OpenAI pricing", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!).font(.caption)
                    }.padding(6)
                }
                HStack {
                    Button("Screen Recording") { MacPermissions.requestScreenRecordingPrompt() }
                    Button("Accessibility") { MacPermissions.requestAccessibilityPrompt() }
                }
                GroupBox("Device permissions") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Only devices explicitly approved for Computer Use can spend API credits or send screen content to OpenAI.").font(.caption)
                        if model.computerUseDevices.isEmpty { Text("Pair a device to grant permission.").foregroundStyle(.secondary) }
                        ForEach(model.computerUseDevices) { device in
                            HStack {
                                Text(device.name)
                                Spacer()
                                Button(device.allowsComputerUse ? "Revoke" : "Grant") {
                                    Task { await model.setComputerUsePermission(deviceID: device.id, allowed: !device.allowsComputerUse) }
                                }
                            }
                        }
                        Text("Session-only permissions last until the hosting session ends.").font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                if !coordinator.settingsMessage.isEmpty { Text(coordinator.settingsMessage).font(.callout).textSelection(.enabled) }
                if let cost = coordinator.snapshot.openAICostText {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Task OpenAI estimate: \(cost)").font(.headline).monospacedDigit()
                        if let model = coordinator.snapshot.modelDescription { Text(model).font(.caption).foregroundStyle(.secondary) }
                        Text("Reported token usage, including reviews and reasoning. Not a quote or spending limit. Missing/cancelled requests, taxes and non-token charges may differ.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let date = coordinator.snapshot.pricingVerifiedAt { Text("Task rates verified \(date)").font(.caption).foregroundStyle(.secondary) }
                        if coordinator.snapshot.costEstimateIncomplete == true { Text("Some API usage was unavailable; the estimate is partial.").font(.caption).foregroundStyle(.orange) }
                    }
                }
                ComputerUseHostStatus(coordinator: coordinator)
            }.padding(24)
        }
        .onAppear { coordinator.refreshKeyStatus() }
    }
}

private struct OpenAIModelSettings: View {
    @ObservedObject var coordinator: ComputerUseCoordinator
    @ObservedObject var catalog: OpenAIModelCatalogStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("OpenAI model", selection: $coordinator.openAIModel) {
                ForEach(catalog.selectableModels) { model in Text(model.title).tag(model) }
                if !catalog.permits(coordinator.openAIModel) {
                    Text("\(coordinator.openAIModel.title) (unavailable)").tag(coordinator.openAIModel).disabled(true)
                }
            }
            Picker("Thinking", selection: $coordinator.openAIThinking) {
                ForEach(coordinator.openAIOptions.catalogEntry?.efforts ?? coordinator.openAIModel.efforts) { effort in
                    Text(effort.title).tag(effort)
                }
                if !(coordinator.openAIOptions.catalogEntry?.efforts ?? coordinator.openAIModel.efforts).contains(coordinator.openAIThinking) {
                    Text("\(coordinator.openAIThinking.title) (uses model default)").tag(coordinator.openAIThinking)
                }
            }
            Text(coordinator.openAIOptions.rates.priceSummary).font(.caption.monospaced())
            HStack {
                Text("Rates verified \(catalog.catalog.verifiedAt) · \(catalog.source)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(catalog.isRefreshing ? "Refreshing…" : "Refresh") { Task { await coordinator.refreshModels(force: true) } }
                    .disabled(catalog.isRefreshing)
            }
            Text(catalog.availabilityMessage).font(.caption).foregroundStyle(.secondary)
            if !catalog.catalogMessage.isEmpty { Text(catalog.catalogMessage).font(.caption).foregroundStyle(.secondary) }
            if !catalog.permits(coordinator.openAIModel) {
                Text("Choose an available model or refresh access before starting a new task.").font(.caption).foregroundStyle(.orange)
            }
        }.task { await coordinator.refreshModels() }
    }
}
struct ComputerUseHostStatus: View {
    @ObservedObject var coordinator: ComputerUseCoordinator
    var body: some View {
        if coordinator.snapshot.phase.ownsControl {
            HStack {
                Image(systemName: "desktopcomputer")
                VStack(alignment: .leading) {
                    Text("Computer Use").font(.headline)
                    Text(coordinator.snapshot.status).font(.caption).lineLimit(2)
                }
                Spacer()
                Button("Stop", role: .destructive) { coordinator.stop() }
                    .buttonStyle(.borderedProminent).tint(.red)
            }.padding(12)
        }
    }
}
