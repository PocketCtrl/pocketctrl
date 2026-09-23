// SPDX-License-Identifier: MPL-2.0
import Foundation
import OSLog

/// Content-free diagnostics only. Never pass task text, UI labels, provider messages,
/// credentials, URLs, device identities, screenshots, or action payloads to `event`.
@MainActor
enum ComputerUseDiagnostics {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.pocketctrl", category: "ComputerUse")
    /// Internal test hook; nil in the app. Tests exercise the same rendered log lines.
    static var testSink: ((String) -> Void)?

    static func event(_ name: String, run: UUID? = nil, _ fields: [String: String] = [:]) {
        let details = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
        let line = "[ComputerUse v1] \(name) run=\(run.map { String($0.uuidString.prefix(8)) } ?? "none") \(details)"
        logger.notice("\(line, privacy: .public)")
        testSink?(line)
    }

    static func milliseconds(since start: TimeInterval) -> String {
        String(Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1000))
    }

    static func errorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError { return "url_\(error.code.rawValue)" }
        return "validation_or_runtime" // Error descriptions can contain model/UI content.
    }

    static func actionType(_ value: String) -> String {
        ["click", "double_click", "move", "drag", "scroll", "keypress", "type", "wait", "screenshot"].contains(value) ? value : "unknown"
    }

    /// Logs only metadata, never the URL, headers, body, or server error text.
    static func data(for request: URLRequest, session: URLSession, provider: String, purpose: String,
                     run: UUID?, requestID: UUID, attempt: Int) async throws -> (Data, URLResponse) {
        var fields = ["provider": provider, "purpose": purpose, "request": String(requestID.uuidString.prefix(8)), "attempt": String(attempt + 1)]
        let start = ProcessInfo.processInfo.systemUptime
        event("request.begin", run: run, fields)
        do {
            let result = try await session.data(for: request)
            fields["ms"] = milliseconds(since: start)
            fields["http"] = String((result.1 as? HTTPURLResponse)?.statusCode ?? 0)
            event("request.response", run: run, fields)
            return result
        } catch {
            fields["ms"] = milliseconds(since: start)
            fields["error"] = errorCode(error)
            event("request.error", run: run, fields)
            throw error
        }
    }
}
