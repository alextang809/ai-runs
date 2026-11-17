import Foundation

/// The AI tools AI Runs can follow automatically through their hooks.
public enum AgentTool: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex = "codex"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Command that reopens a session in a terminal, used when we cannot
    /// bring the original window back.
    public func resumeCommand(sessionId: String) -> String {
        switch self {
        case .claudeCode: return "claude --resume \(sessionId)"
        case .codex: return "codex resume \(sessionId)"
        }
    }
}

/// Where a session is running, captured by the hook helper from its environment.
public struct TerminalContext: Codable, Equatable, Sendable {
    /// `TERM_PROGRAM`, e.g. `Apple_Terminal`, `iTerm.app`, `vscode`.
    public var termProgram: String?
    /// `__CFBundleIdentifier` of the app that launched the shell, e.g. `com.googlecode.iterm2`.
    public var bundleId: String?
    /// `ITERM_SESSION_ID`, e.g. `w0t1p0:6B3F…`.
    public var itermSessionId: String?
    /// `TERM_SESSION_ID` (Terminal.app).
    public var termSessionId: String?
    /// The controlling terminal of the agent process, e.g. `/dev/ttys004`.
    public var tty: String?

    public init(termProgram: String? = nil, bundleId: String? = nil, itermSessionId: String? = nil,
                termSessionId: String? = nil, tty: String? = nil) {
        self.termProgram = termProgram
        self.bundleId = bundleId
        self.itermSessionId = itermSessionId
        self.termSessionId = termSessionId
        self.tty = tty
    }

    /// Human name of the app hosting the session.
    public var appName: String {
        switch (bundleId ?? "", termProgram ?? "") {
        case ("com.anthropic.claudefordesktop", _): return "Claude"
        case ("com.openai.codex", _): return "Codex"
        case ("com.googlecode.iterm2", _), (_, "iTerm.app"): return "iTerm2"
        case ("com.apple.Terminal", _), (_, "Apple_Terminal"): return "Terminal"
        case ("com.todesktop.230313mzl4w4u92", _): return "Cursor"
        case ("com.microsoft.VSCode", _), (_, "vscode"): return "VS Code"
        case ("com.mitchellh.ghostty", _), (_, "ghostty"): return "Ghostty"
        case ("dev.warp.Warp-Stable", _), (_, "WarpTerminal"): return "Warp"
        case (_, let program) where !program.isEmpty: return program
        default: return "Terminal"
        }
    }
}

/// What a hook event means for the timeline.
public enum EventKind: String, Codable, Sendable {
    /// The user sent a prompt: the AI starts working.
    case promptStart
    /// The AI is blocked on a permission prompt.
    case needsApproval
    /// The AI ran a tool, so any pending approval was answered.
    case toolActivity
    /// The AI finished its turn: it is the user's turn.
    case turnEnd
    /// The session was closed.
    case sessionEnd
}

/// One hook event, translated from the tool-specific payload.
public struct AgentEvent: Equatable, Sendable {
    public var tool: AgentTool
    public var kind: EventKind
    public var sessionId: String
    public var at: Date
    public var prompt: String?
    public var lastMessage: String?
    public var approvalDetail: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var terminal: TerminalContext

    public init(tool: AgentTool, kind: EventKind, sessionId: String, at: Date, prompt: String? = nil,
                lastMessage: String? = nil, approvalDetail: String? = nil, cwd: String? = nil,
                transcriptPath: String? = nil, terminal: TerminalContext = TerminalContext()) {
        self.tool = tool
        self.kind = kind
        self.sessionId = sessionId
        self.at = at
        self.prompt = prompt
        self.lastMessage = lastMessage
        self.approvalDetail = approvalDetail
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.terminal = terminal
    }
}
