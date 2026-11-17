import Foundation

public enum SessionState: String, Codable, Sendable {
    case working
    case needsApproval
    case yourTurn

    /// True when the session is waiting on the user.
    public var needsUser: Bool { self != .working }
}

/// One AI conversation that is still open in the panel.
public struct Session: Codable, Equatable, Identifiable, Sendable {
    public var id: String { Session.key(tool: tool, sessionId: sessionId) }
    public var tool: AgentTool
    public var sessionId: String
    public var title: String
    public var cwd: String?
    public var state: SessionState
    public var startedAt: Date
    /// When the current (or last) turn started.
    public var turnStartedAt: Date
    /// When the session started waiting on the user; nil while working.
    public var waitingSince: Date?
    public var lastEventAt: Date
    public var lastMessage: String?
    public var approvalDetail: String?
    public var transcriptPath: String?
    public var terminal: TerminalContext

    public var project: String { TextUtils.projectName(fromPath: cwd) }

    public static func key(tool: AgentTool, sessionId: String) -> String { "\(tool.rawValue):\(sessionId)" }

    public static func genericTitle(for tool: AgentTool) -> String { "\(tool.displayName) session" }

    /// True while the session still has the placeholder title.
    public var hasGenericTitle: Bool { title == Session.genericTitle(for: tool) }

    /// A working session that has sent nothing for this long may have been
    /// interrupted (Ctrl-C, closed window) without a Stop event.
    public static let quietThreshold: TimeInterval = 30 * 60

    public func isQuiet(now: Date) -> Bool {
        state == .working && now.timeIntervalSince(lastEventAt) > Session.quietThreshold
    }
}

/// All open sessions, driven by hook events. Pure value type so it is easy to test.
public struct SessionStore: Codable, Equatable, Sendable {
    public private(set) var sessions: [String: Session] = [:]

    public init() {}

    public mutating func apply(_ event: AgentEvent) {
        let key = Session.key(tool: event.tool, sessionId: event.sessionId)
        var session = sessions[key]

        if event.kind == .sessionEnd {
            sessions[key] = nil
            return
        }
        if session == nil {
            // Any event creates the session, so sessions that started before
            // the hooks were installed still show up. The app replaces the
            // generic title from the transcript when it can.
            let title = event.prompt.map { TextUtils.title(fromPrompt: $0) }
                ?? Session.genericTitle(for: event.tool)
            session = Session(tool: event.tool, sessionId: event.sessionId, title: title, cwd: event.cwd,
                              state: .working, startedAt: event.at, turnStartedAt: event.at,
                              waitingSince: nil, lastEventAt: event.at, lastMessage: nil,
                              approvalDetail: nil, transcriptPath: event.transcriptPath,
                              terminal: event.terminal)
        }
        guard var current = session else { return }

        current.lastEventAt = max(current.lastEventAt, event.at)
        if let cwd = event.cwd { current.cwd = cwd }
        if let path = event.transcriptPath { current.transcriptPath = path }
        if event.terminal != TerminalContext() { current.terminal = event.terminal }

        switch event.kind {
        case .promptStart:
            current.state = .working
            current.turnStartedAt = event.at
            current.waitingSince = nil
            current.approvalDetail = nil
        case .needsApproval:
            current.state = .needsApproval
            current.waitingSince = event.at
            current.approvalDetail = event.approvalDetail ?? current.approvalDetail
        case .toolActivity:
            if current.state == .needsApproval {
                current.state = .working
                current.waitingSince = nil
                current.approvalDetail = nil
            }
        case .turnEnd:
            current.state = .yourTurn
            current.waitingSince = event.at
            current.approvalDetail = nil
            if let message = event.lastMessage, !message.isEmpty { current.lastMessage = message }
        case .sessionEnd:
            break
        }
        sessions[key] = current
    }

    /// The user is done with this session; it leaves the panel until the next prompt.
    public mutating func resolve(id: String) {
        sessions[id] = nil
    }

    public mutating func rename(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[id]?.title = trimmed
    }

    /// Drops sessions nobody has touched for a long time (closed windows that
    /// never sent SessionEnd).
    public mutating func pruneStale(now: Date, olderThan age: TimeInterval = 24 * 3600) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastEventAt) < age }
    }

    /// Sessions that need the user first, longest-waiting first; then working
    /// sessions, most recently started first.
    public func ordered() -> [Session] {
        func rank(_ state: SessionState) -> Int {
            switch state {
            case .needsApproval: return 0
            case .yourTurn: return 1
            case .working: return 2
            }
        }
        return sessions.values.sorted { a, b in
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            if a.state.needsUser {
                return (a.waitingSince ?? a.lastEventAt) < (b.waitingSince ?? b.lastEventAt)
            }
            return a.turnStartedAt > b.turnStartedAt
        }
    }

    public var needsUserCount: Int { sessions.values.filter { $0.state.needsUser }.count }
    public var workingCount: Int { sessions.values.filter { $0.state == .working }.count }
}
