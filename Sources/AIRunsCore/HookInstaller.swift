import Foundation

/// Adds and removes AI Runs' hook entries in Claude Code's and Codex's
/// configuration. Only entries whose command runs `airuns-hook` are touched;
/// everything else in the file is kept. The original file is backed up once.
public struct HookInstaller {
    public enum Status: Equatable, Sendable {
        /// The tool's config folder does not exist: the tool is probably not installed.
        case toolNotFound
        case notInstalled
        case partiallyInstalled
        case installed
    }

    public static let marker = "airuns-hook"

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func configDirectory(for tool: AgentTool) -> URL {
        switch tool {
        case .claudeCode: return home.appendingPathComponent(".claude", isDirectory: true)
        case .chatgpt, .claudeWeb: return home.appendingPathComponent(".airuns/no-hooks", isDirectory: true)
        case .codex: return home.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    /// `~/.claude/settings.json` or `~/.codex/hooks.json`.
    public func configFile(for tool: AgentTool) -> URL {
        switch tool {
        case .claudeCode: return configDirectory(for: tool).appendingPathComponent("settings.json")
        case .chatgpt, .claudeWeb: return configDirectory(for: tool).appendingPathComponent("hooks.json")
        case .codex: return configDirectory(for: tool).appendingPathComponent("hooks.json")
        }
    }

    /// Hook events AI Runs listens to, with an optional matcher.
    public static func events(for tool: AgentTool) -> [(name: String, matcher: String?)] {
        switch tool {
        case .claudeCode:
            return [("UserPromptSubmit", nil), ("Stop", nil), ("PermissionRequest", nil),
                    ("Notification", "permission_prompt"), ("PostToolUse", nil), ("SessionEnd", nil),
                    ("PreToolUse", "AskUserQuestion")]
        case .codex:
            return [("UserPromptSubmit", nil), ("Stop", nil), ("PermissionRequest", nil), ("PostToolUse", nil)]
        case .chatgpt, .claudeWeb:
            return []
        }
    }

    public static func command(helper: URL, tool: AgentTool) -> String {
        let path = helper.path
        let quoted = path.contains(" ") ? "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'" : path
        return "\(quoted) \(tool.rawValue)"
    }

    public func status(for tool: AgentTool) -> Status {
        guard FileManager.default.fileExists(atPath: configDirectory(for: tool).path) else { return .toolNotFound }
        let hooks = (try? readConfig(for: tool))?["hooks"] as? [String: Any] ?? [:]
        let names = HookInstaller.events(for: tool).map { $0.name }
        let present = names.filter { name in
            guard let groups = hooks[name] as? [[String: Any]] else { return false }
            return groups.contains { HookInstaller.groupHasMarker($0) }
        }
        if present.isEmpty { return .notInstalled }
        return present.count == names.count ? .installed : .partiallyInstalled
    }

    public func install(tool: AgentTool, helper: URL) throws {
        var config = try readConfig(for: tool)
        try backupIfNeeded(for: tool)
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        let command = HookInstaller.command(helper: helper, tool: tool)
        for event in HookInstaller.events(for: tool) {
            var groups = HookInstaller.removingMarker(from: hooks[event.name] as? [[String: Any]] ?? [])
            var group: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if let matcher = event.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event.name] = groups
        }
        config["hooks"] = hooks
        try writeConfig(config, for: tool)
    }

    public func uninstall(tool: AgentTool) throws {
        guard FileManager.default.fileExists(atPath: configFile(for: tool).path) else { return }
        var config = try readConfig(for: tool)
        guard var hooks = config["hooks"] as? [String: Any] else { return }
        for (name, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = HookInstaller.removingMarker(from: groups)
            hooks[name] = kept.isEmpty ? nil : kept
        }
        config["hooks"] = hooks.isEmpty ? nil : hooks
        try writeConfig(config, for: tool)
    }

    // MARK: - Helpers

    static func groupHasMarker(_ group: [String: Any]) -> Bool {
        let handlers = group["hooks"] as? [[String: Any]] ?? []
        return handlers.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    /// Removes our handlers from each group; drops groups left empty.
    static func removingMarker(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
            handlers.removeAll { ($0["command"] as? String)?.contains(marker) == true }
            if handlers.isEmpty { return nil }
            var copy = group
            copy["hooks"] = handlers
            return copy
        }
    }

    func readConfig(for tool: AgentTool) throws -> [String: Any] {
        let url = configFile(for: tool)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.unreadableConfig(url.path)
        }
        return object
    }

    func writeConfig(_ config: [String: Any], for tool: AgentTool) throws {
        let url = configFile(for: tool)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    func backupIfNeeded(for tool: AgentTool) throws {
        let url = configFile(for: tool)
        let backup = url.appendingPathExtension("airuns-backup")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        try fm.copyItem(at: url, to: backup)
    }
}

public enum HookInstallerError: Error, LocalizedError {
    case unreadableConfig(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableConfig(let path):
            return "\(path) is not valid JSON, so AI Runs left it alone. Fix the file and try again."
        }
    }
}
