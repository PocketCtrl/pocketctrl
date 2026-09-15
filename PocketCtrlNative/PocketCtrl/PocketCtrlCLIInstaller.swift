// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

@MainActor
final class PocketCtrlCLIInstaller: ObservableObject {
    enum InstallationState: Equatable {
        case checking
        case notInstalled
        case installed
        case updateAvailable
        case conflict
    }

    @Published private(set) var installationState: InstallationState = .checking
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    static let installationPath = "/usr/local/bin/pocketctrl"
    private static let installationMarker = "# PocketCtrl installed CLI v1"

    static var controlTokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PocketCtrl/cli-control-token", isDirectory: false)
    }

    var statusText: String {
        switch installationState {
        case .checking:
            return "Checking /usr/local/bin…"
        case .notInstalled:
            return "Install the pocketctrl command for every Terminal session."
        case .installed:
            return "Installed at \(Self.installationPath)."
        case .updateAvailable:
            return "An older PocketCtrl CLI is installed."
        case .conflict:
            return "Another command already exists at \(Self.installationPath)."
        }
    }

    var primaryActionTitle: String {
        switch installationState {
        case .installed:
            return "Reinstall"
        case .updateAvailable:
            return "Update CLI"
        case .conflict:
            return "Replace…"
        case .checking, .notInstalled:
            return "Install CLI"
        }
    }

    var canUninstall: Bool {
        installationState == .installed || installationState == .updateAvailable
    }

    init() {
        refresh()
    }

    func refresh() {
        installationState = Self.currentInstallationState()
    }

    func install(controlToken: String) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            refresh()
        }

        do {
            let encodedScript = Data(Self.installedScript.utf8).base64EncodedString()
            let temporaryPath = "/usr/local/bin/.pocketctrl.install.$$"
            let command = """
            set -e; \
            /bin/mkdir -p /usr/local/bin; \
            /usr/bin/printf %s \(Self.shellQuote(encodedScript)) | /usr/bin/base64 -D > \(temporaryPath); \
            /usr/sbin/chown root:wheel \(temporaryPath); \
            /bin/chmod 0755 \(temporaryPath); \
            /bin/mv -f \(temporaryPath) \(Self.shellQuote(Self.installationPath))
            """
            try await Self.runWithAdministratorPrivileges(command)
            try Self.writeControlToken(controlToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uninstall() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            refresh()
        }

        do {
            let path = Self.shellQuote(Self.installationPath)
            let marker = Self.shellQuote(Self.installationMarker)
            let command = """
            set -e; \
            if [ ! -f \(path) ] || ! /usr/bin/grep -Fq \(marker) \(path); then \
              echo 'The installed command is not managed by PocketCtrl.' >&2; exit 64; \
            fi; \
            /bin/rm -f \(path)
            """
            try await Self.runWithAdministratorPrivileges(command)
            try? FileManager.default.removeItem(at: Self.controlTokenURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func refreshCredentialIfInstalled(_ controlToken: String) {
        switch currentInstallationState() {
        case .installed, .updateAvailable:
            do {
                try writeControlToken(controlToken)
            } catch {
                NSLog("PocketCtrl could not refresh the CLI credential: %@", error.localizedDescription)
            }
        case .checking, .notInstalled, .conflict:
            break
        }
    }

    private static func currentInstallationState() -> InstallationState {
        let url = URL(fileURLWithPath: installationPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notInstalled
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              contents.contains(installationMarker) else {
            return .conflict
        }
        return contents == installedScript ? .installed : .updateAvailable
    }

    private static func writeControlToken(_ token: String) throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw CLIInstallerError("PocketCtrl has not created its host-control credential yet.")
        }

        let directory = controlTokenURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data((trimmedToken + "\n").utf8).write(to: controlTokenURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: controlTokenURL.path)
    }

    nonisolated private static func runWithAdministratorPrivileges(_ command: String) async throws {
        let script = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: errorData, as: UTF8.self))
        }.value

        guard result.0 == 0 else {
            let message = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("User canceled") || message.contains("-128") {
                throw CLIInstallerError("Installation was canceled.")
            }
            throw CLIInstallerError(message.isEmpty ? "The command-line tool could not be installed." : message)
        }
    }

    nonisolated private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let installedScript = #"""
#!/bin/zsh
# PocketCtrl installed CLI v1

set -eu

show_usage() {
  /usr/bin/printf '%s\n' \
    'Usage:' \
    '  pocketctrl status' \
    '  pocketctrl pairing' \
    '  pocketctrl start' \
    '  pocketctrl stop' \
    '  pocketctrl restart' \
    '  pocketctrl regenerate-pairing' \
    '  pocketctrl set fps 60 bitrate 12 remote-input on audio off'
}

command="${1:-help}"
if (( $# > 0 )); then shift; fi

case "$command" in
  help|--help|-h)
    show_usage
    exit 0
    ;;
esac

token="${POCKETCTRL_CONTROL_TOKEN:-}"
token_file="${POCKETCTRL_CONTROL_TOKEN_FILE:-$HOME/Library/Application Support/PocketCtrl/cli-control-token}"
if [[ -z "$token" && -r "$token_file" ]]; then
  token="$(/bin/cat "$token_file")"
fi
token="${token//$'\n'/}"
token="${token//$'\r'/}"
if [[ -z "$token" ]]; then
  /usr/bin/printf '%s\n' 'pocketctrl: CLI credential missing. Reinstall it from PocketCtrl Settings.' >&2
  exit 1
fi

base_url="${POCKETCTRL_HOST_URL:-http://127.0.0.1:47777}"
if ! /usr/bin/printf '%s\n' "$base_url" | /usr/bin/grep -Eq '^http://(127[.]0[.]0[.]1|localhost):[0-9]+$'; then
  /usr/bin/printf '%s\n' 'pocketctrl: POCKETCTRL_HOST_URL must use HTTP on 127.0.0.1 or localhost.' >&2
  exit 1
fi

request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local -a arguments
  arguments=(
    --silent
    --show-error
    --fail-with-body
    --request "$method"
    --header 'Accept: application/json'
    --header "Authorization: Bearer $token"
  )
  if [[ -n "$body" ]]; then
    arguments+=(--header 'Content-Type: application/json' --data "$body")
  fi
  /usr/bin/curl "${arguments[@]}" "${base_url}${path}"
  /usr/bin/printf '\n'
}

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  /usr/bin/printf '"%s"' "$value"
}

json_key() {
  case "$1" in
    destination|destination-address|viewer|viewer-ip) echo destinationAddress ;;
    video-port) echo videoPort ;;
    audio-port) echo audioPort ;;
    input-port) echo inputPort ;;
    width|capture-width) echo captureWidth ;;
    bitrate) echo bitrateMbps ;;
    adaptive-bitrate) echo adaptiveBitrateEnabled ;;
    audio) echo audioEnabled ;;
    remote-input|mouse|keyboard) echo remoteInputEnabled ;;
    keep-awake) echo keepAwakeWhileHosting ;;
    auto-start) echo autoStartHosting ;;
    launch-at-login) echo launchAtLoginEnabled ;;
    local-discovery) echo localDiscoveryEnabled ;;
    display) echo displayID ;;
    *) echo "$1" ;;
  esac
}

json_value() {
  local key="$1"
  local value="$2"
  case "$key" in
    captureWidth|fps|bitrateMbps)
      if ! /usr/bin/printf '%s\n' "$value" | /usr/bin/grep -Eq '^[0-9]+([.][0-9]+)?$'; then
        /usr/bin/printf 'pocketctrl: %s must be a number\n' "$key" >&2
        return 1
      fi
      /usr/bin/printf '%s' "$value"
      ;;
    displayID)
      if ! /usr/bin/printf '%s\n' "$value" | /usr/bin/grep -Eq '^[0-9]+$'; then
        /usr/bin/printf '%s\n' 'pocketctrl: display must be a display id' >&2
        return 1
      fi
      /usr/bin/printf '%s' "$value"
      ;;
    adaptiveBitrateEnabled|audioEnabled|remoteInputEnabled|keepAwakeWhileHosting|autoStartHosting|launchAtLoginEnabled|localDiscoveryEnabled)
      case "${value:l}" in
        1|true|yes|on|enabled) /usr/bin/printf 'true' ;;
        0|false|no|off|disabled) /usr/bin/printf 'false' ;;
        *) /usr/bin/printf 'pocketctrl: %s must be on/off or true/false\n' "$key" >&2; return 1 ;;
      esac
      ;;
    *) json_string "$value" ;;
  esac
}

case "$command" in
  status) request GET /status ;;
  pairing|qr|code) request GET /pairing ;;
  start) request POST /start ;;
  stop) request POST /stop ;;
  restart) request POST /restart ;;
  regenerate-pairing|new-key) request POST /pairing/regenerate ;;
  set)
    if (( $# == 0 || $# % 2 != 0 )); then
      /usr/bin/printf '%s\n' 'pocketctrl: Use: pocketctrl set fps 60 bitrate 12 remote-input on' >&2
      exit 1
    fi
    body='{'
    separator=''
    while (( $# > 0 )); do
      key="$(json_key "$1")"
      value="$(json_value "$key" "$2")"
      body+="${separator}$(json_string "$key"):${value}"
      separator=','
      shift 2
    done
    body+='}'
    request POST /settings "$body"
    ;;
  *)
    /usr/bin/printf "pocketctrl: Unknown command '%s'\n" "$command" >&2
    show_usage >&2
    exit 1
    ;;
esac
"""#
}

private struct CLIInstallerError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
