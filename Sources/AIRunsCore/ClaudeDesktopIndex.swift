import Foundation

/// A Claude Code session as the Claude desktop app lists it in its sidebar.
public struct ClaudeDesktopSession: Equatable, Sendable {
    /// The desktop app's own ID (`local_…`).
    public var sessionId: String
    /// The Claude Code session ID that hooks report.
    public var cliSessionId: String?
    /// The name in the desktop sidebar.
    public var title: String?
    public var isArchived: Bool
    public var lastActivityAt: Date?

    public init(sessionId: String, cliSessionId: String?, title: String?, isArchived: Bool, lastActivityAt: Date?) {
        self.sessionId = sessionId
        self.cliSessionId = cliSessionId
        self.title = title
        self.isArchived = isArchived
        self.lastActivityAt = lastActivityAt
    }
}

/// Reads the Claude desktop app's session list:
/// `~/Library/Application Support/Claude/claude-code-sessions/<id>/<id>/local_<id>.json`.
///
/// This is the app's private storage, not an API, so only a few fields are
/// read and anything unexpected is skipped. Those files also hold prompts and
/// settings, which are never read into AI Runs.
public enum ClaudeDesktopIndex {
    public static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    public static func load(root: URL) -> [ClaudeDesktopSession] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { return [] }
        var sessions: [ClaudeDesktopSession] = []
        for case let url as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                  let session = parse(url: url) else { continue }
            sessions.append(session)
        }
        return sessions
    }

    /// The desktop entry for a Claude Code session ID, if the desktop app runs it.
    public static func session(forCLI cliSessionId: String, in sessions: [ClaudeDesktopSession]) -> ClaudeDesktopSession? {
        sessions.first { $0.cliSessionId == cliSessionId }
    }

    static func parse(url: URL) -> ClaudeDesktopSession? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(object: object)
    }

    public static func parse(object: [String: Any]) -> ClaudeDesktopSession? {
        guard let id = object["sessionId"] as? String, !id.isEmpty else { return nil }
        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastActivity: Date?
        if let ms = object["lastActivityAt"] as? Double { lastActivity = Date(timeIntervalSince1970: ms / 1000) }
        return ClaudeDesktopSession(sessionId: id,
                                    cliSessionId: object["cliSessionId"] as? String,
                                    title: (title?.isEmpty ?? true) ? nil : title,
                                    isArchived: object["isArchived"] as? Bool ?? false,
                                    lastActivityAt: lastActivity)
    }

    /// Fills `{id}` (desktop ID) and `{cli}` (Claude Code session ID) in a link template.
    public static func link(template: String, session: ClaudeDesktopSession) -> URL? {
        var text = template.replacingOccurrences(of: "{id}", with: session.sessionId)
        text = text.replacingOccurrences(of: "{cli}", with: session.cliSessionId ?? session.sessionId)
        return URL(string: text)
    }
}
