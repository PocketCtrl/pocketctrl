// SPDX-License-Identifier: MPL-2.0
import Foundation

enum ComputerUseMode: String, Codable, CaseIterable, Identifiable {
    case openAI
    var id: String { rawValue }
    var usesOpenAI: Bool { true }
    var title: String { "OpenAI" }
    var dataNotice: String { "Instructions, desktop screenshots, and limited Accessibility context are sent to OpenAI. API charges apply." }
}
struct ComputerUseModelChoice: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var efforts: [String]
}

enum ComputerUsePhase: String, Codable {
    case starting, running, awaitingApproval, awaitingUser, paused, stopping, completed, cancelled, failed
    var ownsControl: Bool { ![.completed, .cancelled, .failed].contains(self) }
}
struct ComputerUseMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String
    var text: String
}
struct ComputerUseApproval: Codable, Equatable {
    var id: UUID
    var explanation: String
}
/// Coordinates relative to the selected display, with a top-left origin.
struct ComputerUsePointer: Codable, Equatable {
    var x: Double
    var y: Double
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}
struct ComputerUseSnapshot: Codable, Equatable {
    var epoch = UUID()
    var revision: UInt64 = 0
    var runID: UUID?
    var phase: ComputerUsePhase = .completed
    var status = "Ready"
    var available = false
    var ownsTask = false
    var canAcceptReply: Bool?
    var approval: ComputerUseApproval?
    var messages: [ComputerUseMessage] = []
    var inputTokens = 0
    var outputTokens = 0
    var actions = 0
    var acknowledgedCommand: UUID?
    var commandError: String?
    var sentAt = Date()
    // Optional for compatibility with older viewers and hosts.
    var providerName: String?
    var dataNotice: String?
    var modelDescription: String?
    var pricingVerifiedAt: String?
    var availableModes: [ComputerUseMode]?
    var defaultMode: ComputerUseMode?
    var taskMode: ComputerUseMode?
    var openAICostUSD: Double?
    var costEstimateIncomplete: Bool?
    var availableModels: [ComputerUseModelChoice]?
    var defaultModel: String?
    var defaultThinking: String?
    var taskModel: String?
    var taskThinking: String?
    var pointer: ComputerUsePointer?
    var supportsApprovalRetry: Bool?
    var openAICostText: String? {
        guard let cost = openAICostUSD, cost.isFinite, cost >= 0 else { return nil }
        if cost > 0 && cost < 0.0001 { return "< US$0.0001" }
        return "US$" + cost.formatted(.number.precision(.fractionLength(cost < 0.01 ? 4 : 2)))
    }
}
struct ComputerUseCommand: Codable {
    enum Kind: String, Codable { case capabilities, start, pause, resume, stop, approve, retryApproval, reply, heartbeat }
    var id = UUID()
    var kind: Kind
    var epoch: UUID?
    var runID: UUID?
    var text: String?
    var approvalID: UUID?
    var approved: Bool?
    // String at the trust boundary so unknown modes receive an explicit rejection.
    var mode: String?
    var model: String?
    var thinking: String?
    var sentAt = Date()
}

/// A datagram carries one authenticated fragment. Bound memory before allocating.
struct ComputerUseFragment: Codable {
    var messageID: UUID
    var index: Int
    var count: Int
    var data: Data
    static let payloadBytes = 384
    static let maximumBytes = 64 * 1024
    static let maximumFragments = 171
    static func encode<T: Encodable>(_ value: T) -> [ComputerUseFragment] {
        guard let data = try? JSONEncoder().encode(value), data.count <= maximumBytes else { return [] }
        let id = UUID()
        let count = max(1, (data.count + payloadBytes - 1) / payloadBytes)
        return (0..<count).map { index in
            let start = index * payloadBytes
            return Self(messageID: id, index: index, count: count,
                        data: data.subdata(in: start..<min(start + payloadBytes, data.count)))
        }
    }
}
struct ComputerUseReassembler {
    private struct Partial { var count: Int; var created: Date; var parts: [Int: Data] = [:] }
    private var pending: [UUID: Partial] = [:]
    mutating func push(_ fragment: ComputerUseFragment, now: Date = Date()) -> Data? {
        pending = pending.filter { now.timeIntervalSince($0.value.created) < 5 }
        guard fragment.count > 0, fragment.count <= ComputerUseFragment.maximumFragments,
              fragment.index >= 0, fragment.index < fragment.count,
              fragment.data.count <= ComputerUseFragment.payloadBytes else { return nil }
        if pending[fragment.messageID] == nil {
            guard pending.count < 8 else { return nil }
            pending[fragment.messageID] = Partial(count: fragment.count, created: now)
        }
        guard var partial = pending[fragment.messageID], partial.count == fragment.count else { return nil }
        if let old = partial.parts[fragment.index], old != fragment.data {
            pending.removeValue(forKey: fragment.messageID)
            return nil
        }
        partial.parts[fragment.index] = fragment.data
        pending[fragment.messageID] = partial
        guard partial.parts.count == partial.count else { return nil }
        pending.removeValue(forKey: fragment.messageID)
        let data = (0..<partial.count).reduce(into: Data()) { $0.append(partial.parts[$1]!) }
        return data.count <= ComputerUseFragment.maximumBytes ? data : nil
    }
}

/// Serializes cancellation with event posting, including already-enqueued blocks.
/// Use a separate gate per host; a generation can never become valid again.
final class ComputerUseExecutionGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var owned = false
    var ownsControl: Bool { lock.lock(); defer { lock.unlock() }; return owned }
    @discardableResult func acquire() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; owned = true; return generation
    }
    func invalidate(release: Bool) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        if release { owned = false }
    }
    func isValid(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return owned && token == generation
    }
    @discardableResult func perform(_ token: UInt64, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owned && token == generation else { return false }
        body(); return true
    }
    func performManual(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !owned else { return }; body()
    }
}
