// SPDX-License-Identifier: MPL-2.0

import Foundation

@main
enum PocketCtrlHostCLI {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("pocketctrl: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "status":
            try await request("GET", "/status")
        case "pairing", "qr", "code":
            try await request("GET", "/pairing")
        case "start":
            try await request("POST", "/start")
        case "stop":
            try await request("POST", "/stop")
        case "restart":
            try await request("POST", "/restart")
        case "regenerate-pairing", "new-key":
            try await request("POST", "/pairing/regenerate")
        case "set":
            let settings = try settingsPayload(from: Array(arguments.dropFirst()))
            try await request("POST", "/settings", body: settings)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError("Unknown command '\(command)'")
        }
    }

    private static func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        let baseURL = try configuredBaseURL()
        let token = try controlToken()
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CLIError("No HTTP response from PocketCtrl host app")
        }
        FileHandle.standardOutput.write(data)
        if data.last != UInt8(ascii: "\n") {
            print()
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CLIError("Request failed with HTTP \(httpResponse.statusCode)")
        }
    }

    private static func configuredBaseURL() throws -> URL {
        let value = ProcessInfo.processInfo.environment["POCKETCTRL_HOST_URL"] ?? "http://127.0.0.1:47777"
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? ""),
              url.user == nil,
              url.password == nil else {
            throw CLIError("POCKETCTRL_HOST_URL must use HTTP on 127.0.0.1 or localhost")
        }
        return url
    }

    private static func controlToken() throws -> String {
        let environmentToken = ProcessInfo.processInfo.environment["POCKETCTRL_CONTROL_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = environmentToken.isEmpty ? installedControlToken() : environmentToken
        guard !token.isEmpty else {
            throw CLIError("PocketCtrl CLI is not configured. Open PocketCtrl Settings and install the command-line tool again")
        }
        return token
    }

    private static func installedControlToken() -> String {
        let tokenURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PocketCtrl/cli-control-token", isDirectory: false)
        return (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func settingsPayload(from arguments: [String]) throws -> [String: Any] {
        guard !arguments.isEmpty, arguments.count.isMultiple(of: 2) else {
            throw CLIError("Use: pocketctrl set fps 60 bitrate 12 remote-input on")
        }

        var payload: [String: Any] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            payload[jsonKey(for: key)] = try jsonValue(for: key, value: value)
            index += 2
        }
        return payload
    }

    private static func jsonKey(for key: String) -> String {
        switch key {
        case "destination", "destination-address", "viewer", "viewer-ip":
            return "destinationAddress"
        case "video-port":
            return "videoPort"
        case "audio-port":
            return "audioPort"
        case "input-port":
            return "inputPort"
        case "width", "capture-width":
            return "captureWidth"
        case "bitrate":
            return "bitrateMbps"
        case "adaptive-bitrate":
            return "adaptiveBitrateEnabled"
        case "audio":
            return "audioEnabled"
        case "remote-input", "mouse", "keyboard":
            return "remoteInputEnabled"
        case "keep-awake":
            return "keepAwakeWhileHosting"
        case "auto-start":
            return "autoStartHosting"
        case "launch-at-login":
            return "launchAtLoginEnabled"
        case "local-discovery":
            return "localDiscoveryEnabled"
        case "display":
            return "displayID"
        default:
            return key
        }
    }

    private static func jsonValue(for key: String, value: String) throws -> Any {
        let normalizedKey = jsonKey(for: key)
        switch normalizedKey {
        case "captureWidth", "fps", "bitrateMbps":
            guard let number = Double(value) else { throw CLIError("\(key) must be a number") }
            return number
        case "displayID":
            guard let number = UInt32(value) else { throw CLIError("\(key) must be a display id") }
            return number
        case "adaptiveBitrateEnabled", "audioEnabled", "remoteInputEnabled", "keepAwakeWhileHosting", "autoStartHosting", "launchAtLoginEnabled", "localDiscoveryEnabled":
            return try boolValue(value, key: key)
        default:
            return value
        }
    }

    private static func boolValue(_ value: String, key: String) throws -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        case "0", "false", "no", "off", "disabled":
            return false
        default:
            throw CLIError("\(key) must be on/off or true/false")
        }
    }

    private static func printUsage() {
        print(
            """
            Usage:
              pocketctrl status
              pocketctrl pairing
              pocketctrl start
              pocketctrl stop
              pocketctrl restart
              pocketctrl regenerate-pairing
              pocketctrl set fps 60 bitrate 12 remote-input on audio off

            Optional environment overrides:
              POCKETCTRL_CONTROL_TOKEN=<PocketCtrl host control token>
              POCKETCTRL_HOST_URL=http://127.0.0.1:47777
            """
        )
    }
}

struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
