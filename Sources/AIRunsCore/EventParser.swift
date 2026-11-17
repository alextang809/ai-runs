import Foundation

/// One line of `events.jsonl`, as written by `airuns-hook`.
///
/// The helper stores the hook payload untouched so that a change in a tool's
/// payload never breaks the helper itself; all interpretation happens here.
public enum HookRecord {
    public static let version = 1

    /// Environment variables the helper copies into each record.
    public static let capturedEnvironment = [
        "TERM_PROGRAM", "__CFBundleIdentifier", "ITERM_SESSION_ID", "TERM_SESSION_ID",
    ]

    /// Builds one JSON line (without the trailing newline).
    public static func makeLine(tool: String, payload: Data, environment: [String: String],
                                tty: String?, receivedAt: Date = Date()) -> Data {
        var env: [String: String] = [:]
        for key in capturedEnvironment {
            if let value = environment[key], !value.isEmpty { env[key] = value }
        }
        let payloadObject: Any
        if let parsed = try? JSONSerialization.jsonObject(with: payload) {
            payloadObject = parsed
        } else {
            payloadObject = ["raw": String(decoding: payload, as: UTF8.self)]
        }
        var record: [String: Any] = [
            "v": version,
            "tool": tool,
            "receivedAt": ISO8601DateFormatter().string(from: receivedAt),
            "env": env,
            "payload": payloadObject,
        ]
        if let tty, !tty.isEmpty { record["tty"] = tty }
        return (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
    }
}

/// Turns a record line into an `AgentEvent`. Returns nil for lines that are
/// malformed or carry events the timeline does not use.
public enum EventParser {
    public static func parse(line: Data) -> AgentEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let toolName = object["tool"] as? String,
              let tool = AgentTool(rawValue: toolName),
              let payload = object["payload"] as? [String: Any]
        else { return nil }

        let env = object["env"] as? [String: String] ?? [:]
        let terminal = TerminalContext(
            termProgram: env["TERM_PROGRAM"],
            bundleId: env["__CFBundleIdentifier"],
            itermSessionId: env["ITERM_SESSION_ID"],
            termSessionId: env["TERM_SESSION_ID"],
            tty: object["tty"] as? String
        )
        let at = (object["receivedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return parse(tool: tool, payload: payload, at: at, terminal: terminal)
    }

    /// Interprets a payload. Claude Code and Codex use the same event names
    /// and field names for everything AI Runs reads.
    public static func parse(tool: AgentTool, payload: [String: Any], at: Date,
                             terminal: TerminalContext) -> AgentEvent? {
        guard let sessionId = payload["session_id"] as? String, !sessionId.isEmpty,
              let eventName = payload["hook_event_name"] as? String
        else { return nil }

        var event = AgentEvent(tool: tool, kind: .promptStart, sessionId: sessionId, at: at,
                               cwd: payload["cwd"] as? String,
                               transcriptPath: payload["transcript_path"] as? String,
                               terminal: terminal)
        switch eventName {
        case "UserPromptSubmit":
            event.kind = .promptStart
            event.prompt = payload["prompt"] as? String
        case "Stop":
            event.kind = .turnEnd
            event.lastMessage = payload["last_assistant_message"] as? String
        case "PermissionRequest":
            event.kind = .needsApproval
            event.approvalDetail = approvalDetail(from: payload)
        case "Notification":
            guard (payload["notification_type"] as? String) == "permission_prompt" else { return nil }
            event.kind = .needsApproval
            event.approvalDetail = payload["message"] as? String
        case "PostToolUse":
            event.kind = .toolActivity
        case "SessionEnd":
            event.kind = .sessionEnd
        default:
            return nil
        }
        return event
    }

    private static func approvalDetail(from payload: [String: Any]) -> String? {
        let toolName = payload["tool_name"] as? String
        let input = payload["tool_input"] as? [String: Any]
        if let command = input?["command"] as? String, !command.isEmpty { return command }
        if let path = input?["file_path"] as? String, let toolName { return "\(toolName) \(path)" }
        return toolName
    }
}
