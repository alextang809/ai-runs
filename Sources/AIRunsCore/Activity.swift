import Foundation

/// How far an agent is through its own step list (Claude Code's todo list,
/// Codex's plan).
public struct RunProgress: Codable, Equatable, Sendable {
    public var done: Int
    public var total: Int
    /// The step in progress, or the next one to do.
    public var current: String?

    public init(done: Int, total: Int, current: String?) {
        self.done = done
        self.total = total
        self.current = current
    }

    public var isFinished: Bool { total > 0 && done >= total }

    /// "2/8 · Build the lens".
    public var summary: String {
        var text = "\(done)/\(total)"
        if let current, !current.isEmpty { text += " · \(current)" }
        return text
    }
}

/// Turns a tool call from a hook payload into a few words a person would use:
/// "Building", "Editing PanelViews.swift", "Running tests".
public enum ActivityDescriber {
    public static func describe(toolName: String?, input: [String: Any]?) -> String? {
        guard let toolName, !toolName.isEmpty else { return nil }
        let input = input ?? [:]
        let lower = toolName.lowercased()

        if lower.hasPrefix("mcp__") {
            // mcp__server__tool → "Using server"
            let parts = toolName.components(separatedBy: "__")
            if parts.count >= 2, !parts[1].isEmpty { return "Using \(parts[1])" }
            return "Using a connector"
        }

        switch lower {
        case "bash", "shell", "exec_command", "local_shell", "container.exec", "unified_exec":
            return describe(command: commandText(input["command"]))
        case "read", "view", "notebookread":
            return file(input).map { "Reading \($0)" } ?? "Reading files"
        case "edit", "multiedit", "write", "notebookedit", "str_replace_based_edit_tool":
            return file(input).map { "Editing \($0)" } ?? "Editing files"
        case "apply_patch":
            return patchedFile(input).map { "Editing \($0)" } ?? "Editing files"
        case "grep", "glob", "ls", "search":
            return "Searching the code"
        case "websearch", "web_search":
            return "Searching the web"
        case "webfetch", "web_fetch":
            return "Reading a web page"
        case "task", "agent":
            return "Working with a subagent"
        case "todowrite", "update_plan", "taskcreate", "taskupdate":
            return "Updating its plan"
        case "toolsearch":
            return "Looking up tools"
        case "askuserquestion":
            return "Asking you a question"
        default:
            return toolName
        }
    }

    /// Reads a step list from `TodoWrite` (Claude Code) or `update_plan` (Codex).
    public static func progress(toolName: String?, input: [String: Any]?) -> RunProgress? {
        guard let toolName = toolName?.lowercased(), let input else { return nil }
        let items: [[String: Any]]
        let textKeys: [String]
        switch toolName {
        case "todowrite":
            items = input["todos"] as? [[String: Any]] ?? []
            textKeys = ["activeForm", "content"]
        case "update_plan":
            items = input["plan"] as? [[String: Any]] ?? []
            textKeys = ["step"]
        default:
            return nil
        }
        guard !items.isEmpty else { return nil }
        func text(_ item: [String: Any]) -> String? {
            for key in textKeys {
                if let value = item[key] as? String, !value.isEmpty { return TextUtils.truncate(value, limit: 60) }
            }
            return nil
        }
        let done = items.filter { ($0["status"] as? String) == "completed" }.count
        let current = items.first { ($0["status"] as? String) == "in_progress" }
            ?? items.first { ($0["status"] as? String) != "completed" }
        return RunProgress(done: done, total: items.count, current: current.flatMap(text))
    }

    /// A shell command in words. Leading `cd …` steps are skipped.
    public static func describe(command: String?) -> String {
        guard let command, !command.isEmpty else { return "Running a command" }
        let steps = command
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("cd ") && !$0.hasPrefix("export ") && !$0.hasPrefix("#") }
        let step = steps.first ?? command.trimmingCharacters(in: .whitespaces)
        let text = " \(steps.joined(separator: " ").lowercased()) "

        let rules: [([String], String)] = [
            ([" test ", "pytest", "jest", "vitest", "go test", "cargo test", "swift test", "npm test", "rspec"], "Running tests"),
            (["xcodebuild", "swift build", "cargo build", "npm run build", "pnpm build", "yarn build",
              " make ", "gradle", "tsc ", "package_app"], "Building"),
            (["git commit"], "Committing"),
            (["git push"], "Pushing"),
            (["git merge", "git rebase", "git cherry-pick"], "Merging branches"),
            (["gh pr", "gh run", "gh api"], "Checking GitHub"),
            (["npm install", "pnpm install", "yarn add", "pip install", "brew install", "bundle install"], "Installing packages"),
            (["curl ", "wget "], "Fetching from the web"),
            (["open ", "killall "], "Opening an app"),
        ]
        for (needles, phrase) in rules where needles.contains(where: { text.contains($0) }) {
            return phrase
        }

        let program = step.split(separator: " ").first.map(String.init) ?? step
        let name = (program as NSString).lastPathComponent
        switch name {
        case "cat", "head", "tail", "less", "sed", "awk", "wc", "nl", "bat":
            return "Reading files"
        case "rg", "grep", "find", "fd", "ls", "tree":
            return "Searching the code"
        case "git":
            return "Using git"
        case "python", "python3", "node", "ruby", "swift", "bash", "sh", "zsh":
            return "Running a script"
        case "sleep":
            return "Waiting"
        default:
            return "Running \(TextUtils.truncate(name, limit: 24))"
        }
    }

    private static func commandText(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let parts = value as? [String] {
            // Codex passes ["bash", "-lc", "…"].
            if parts.count >= 3, ["bash", "sh", "zsh"].contains((parts[0] as NSString).lastPathComponent) {
                return parts[2]
            }
            return parts.joined(separator: " ")
        }
        return nil
    }

    private static func file(_ input: [String: Any]) -> String? {
        for key in ["file_path", "path", "notebook_path", "filePath"] {
            if let path = input[key] as? String, !path.isEmpty { return (path as NSString).lastPathComponent }
        }
        return nil
    }

    private static func patchedFile(_ input: [String: Any]) -> String? {
        let patch = (input["input"] as? String) ?? (input["patch"] as? String) ?? (input["command"] as? String) ?? ""
        for line in patch.components(separatedBy: .newlines) {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                return (String(line.dropFirst(prefix.count)) as NSString).lastPathComponent
            }
        }
        return nil
    }
}

extension TextUtils {
    /// Who sent a prompt when another agent drove the session, e.g.
    /// `<relay from="coordinator" …>` → "coordinator". Nil for prompts a person typed.
    public static func relaySource(in prompt: String?) -> String? {
        guard let prompt else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<relay") else { return nil }
        guard let range = trimmed.range(of: #"from="([^"]+)""#, options: .regularExpression) else { return "another agent" }
        let match = trimmed[range]
        return String(match.dropFirst(6).dropLast())
    }
}
