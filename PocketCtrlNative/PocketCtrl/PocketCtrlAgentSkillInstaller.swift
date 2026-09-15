// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

@MainActor
final class PocketCtrlAgentSkillInstaller: ObservableObject {
    enum AgentTarget: String, CaseIterable, Hashable, Identifiable {
        case codex
        case claudeCode

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .codex:
                return "Codex"
            case .claudeCode:
                return "Claude Code"
            }
        }

        var systemImage: String {
            switch self {
            case .codex:
                return "terminal.fill"
            case .claudeCode:
                return "chevron.left.forwardslash.chevron.right"
            }
        }

        var abbreviatedInstallationPath: String {
            switch self {
            case .codex:
                return "~/.agents/skills/pocketctrl"
            case .claudeCode:
                return "~/.claude/skills/pocketctrl"
            }
        }
    }

    enum InstallationState: Equatable {
        case checking
        case notInstalled
        case installed
        case updateAvailable
        case conflict
        case resourceUnavailable
    }

    @Published private(set) var states: [AgentTarget: InstallationState] = [:]
    @Published private(set) var workingTargets: Set<AgentTarget> = []
    @Published var errorMessage: String?

    private let fileManager: FileManager
    private let bundle: Bundle
    private let homeDirectory: URL
    private let managementMarker = "PocketCtrl managed Agent Skill v1\n"

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.homeDirectory = homeDirectory
        refresh()
    }

    func state(for target: AgentTarget) -> InstallationState {
        states[target] ?? .checking
    }

    func isWorking(_ target: AgentTarget) -> Bool {
        workingTargets.contains(target)
    }

    func statusText(for target: AgentTarget) -> String {
        switch state(for: target) {
        case .checking:
            return "Checking " + target.abbreviatedInstallationPath + "…"
        case .notInstalled:
            return "Make PocketCtrl available in " + target.displayName + "."
        case .installed:
            return "Installed at " + target.abbreviatedInstallationPath + "."
        case .updateAvailable:
            return "A newer PocketCtrl skill is available."
        case .conflict:
            return "Another skill already exists at " + target.abbreviatedInstallationPath + "."
        case .resourceUnavailable:
            return "The PocketCtrl skill is missing from this app build."
        }
    }

    func primaryActionTitle(for target: AgentTarget) -> String {
        switch state(for: target) {
        case .installed:
            return "Reinstall"
        case .updateAvailable:
            return "Update"
        case .conflict:
            return "Replace…"
        case .checking, .notInstalled, .resourceUnavailable:
            return "Install"
        }
    }

    func canUninstall(_ target: AgentTarget) -> Bool {
        isManagedLink(installationURL(for: target))
    }

    func refresh() {
        states = Dictionary(uniqueKeysWithValues: AgentTarget.allCases.map { target in
            (target, currentInstallationState(for: target))
        })
    }

    func install(_ target: AgentTarget, replacingConflict: Bool = false) {
        guard !isWorking(target) else { return }
        workingTargets.insert(target)
        errorMessage = nil
        defer {
            workingTargets.remove(target)
            refresh()
        }

        do {
            let skillContents = try bundledSkillContents()
            try prepareManagedSkill(contents: skillContents)

            let destination = installationURL(for: target)
            if itemExists(at: destination), !isManagedLink(destination) {
                guard replacingConflict else {
                    throw AgentSkillInstallerError("Another skill already exists at " + target.abbreviatedInstallationPath + ".")
                }
                try backUpConflictingItem(at: destination)
            }

            if !isManagedLink(destination) {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.createSymbolicLink(
                    at: destination,
                    withDestinationURL: managedSkillURL
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uninstall(_ target: AgentTarget) {
        guard !isWorking(target) else { return }
        workingTargets.insert(target)
        errorMessage = nil
        defer {
            workingTargets.remove(target)
            refresh()
        }

        do {
            let destination = installationURL(for: target)
            guard isManagedLink(destination) else {
                throw AgentSkillInstallerError("The skill at " + target.abbreviatedInstallationPath + " is not managed by PocketCtrl.")
            }

            try fileManager.removeItem(at: destination)
            let hasRemainingInstall = AgentTarget.allCases.contains { otherTarget in
                isManagedLink(installationURL(for: otherTarget))
            }
            if !hasRemainingInstall, isManagedSkillDirectory {
                try fileManager.removeItem(at: managedSkillURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var managedSkillURL: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/PocketCtrl/Agent Skills", isDirectory: true)
            .appendingPathComponent("pocketctrl", isDirectory: true)
    }

    private var managementMarkerURL: URL {
        managedSkillURL.appendingPathComponent(".pocketctrl-managed", isDirectory: false)
    }

    private var installedSkillFileURL: URL {
        managedSkillURL.appendingPathComponent("SKILL.md", isDirectory: false)
    }

    private var isManagedSkillDirectory: Bool {
        guard itemExists(at: managementMarkerURL),
              let marker = try? String(contentsOf: managementMarkerURL, encoding: .utf8) else {
            return false
        }
        return marker == managementMarker
    }

    private func installationURL(for target: AgentTarget) -> URL {
        switch target {
        case .codex:
            return homeDirectory
                .appendingPathComponent(".agents/skills", isDirectory: true)
                .appendingPathComponent("pocketctrl", isDirectory: true)
        case .claudeCode:
            return homeDirectory
                .appendingPathComponent(".claude/skills", isDirectory: true)
                .appendingPathComponent("pocketctrl", isDirectory: true)
        }
    }

    private func currentInstallationState(for target: AgentTarget) -> InstallationState {
        guard (try? bundledSkillContents()) != nil else {
            return .resourceUnavailable
        }

        let destination = installationURL(for: target)
        guard itemExists(at: destination) else {
            return .notInstalled
        }
        guard isManagedLink(destination) else {
            return .conflict
        }

        guard let installedContents = try? String(contentsOf: installedSkillFileURL, encoding: .utf8),
              let bundledContents = try? bundledSkillContents() else {
            return .updateAvailable
        }
        return installedContents == bundledContents ? .installed : .updateAvailable
    }

    private func prepareManagedSkill(contents: String) throws {
        if itemExists(at: managedSkillURL), !isManagedSkillDirectory {
            throw AgentSkillInstallerError(
                "PocketCtrl cannot use its Agent Skills support folder because it contains files not managed by PocketCtrl."
            )
        }

        try fileManager.createDirectory(at: managedSkillURL, withIntermediateDirectories: true)
        try Data(managementMarker.utf8).write(to: managementMarkerURL, options: .atomic)
        try Data(contents.utf8).write(to: installedSkillFileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installedSkillFileURL.path)
    }

    private func bundledSkillContents() throws -> String {
        let candidates = [
            bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "AgentSkills/pocketctrl"),
            bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "pocketctrl"),
            bundle.url(forResource: "SKILL", withExtension: "md")
        ]

        guard let skillURL = candidates.compactMap({ $0 }).first else {
            throw AgentSkillInstallerError("The PocketCtrl Agent Skill is missing from this app build.")
        }
        return try String(contentsOf: skillURL, encoding: .utf8)
    }

    private func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isManagedLink(_ url: URL) -> Bool {
        guard let rawDestination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }

        let destination: URL
        if rawDestination.hasPrefix("/") {
            destination = URL(fileURLWithPath: rawDestination)
        } else {
            destination = url.deletingLastPathComponent().appendingPathComponent(rawDestination)
        }
        return destination.standardizedFileURL.path == managedSkillURL.standardizedFileURL.path
    }

    private func backUpConflictingItem(at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let timestamp = Int(Date().timeIntervalSince1970)
        var backupURL = parent.appendingPathComponent("pocketctrl.backup-" + String(timestamp), isDirectory: true)
        if itemExists(at: backupURL) {
            backupURL = parent.appendingPathComponent(
                "pocketctrl.backup-" + String(timestamp) + "-" + UUID().uuidString,
                isDirectory: true
            )
        }
        try fileManager.moveItem(at: url, to: backupURL)
    }
}

private struct AgentSkillInstallerError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
