import Foundation

public enum SessionState: String, Codable, Sendable {
    case working
    case needsApproval
    case yourTurn

    /// True when the session is waiting on the user.
    public var needsUser: Bool { self != .working }
}

/// One AI conversation that is still open in the panel.
///
/// Usually one local session. For a Claude project thread it is the thread,
/// and `sessionId` is the local session that worked for it most recently.
public struct Session: Codable, Equatable, Identifiable, Sendable {
    public var id: String { thread.map { Session.key(tool: tool, thread: $0) } ?? Session.key(tool: tool, sessionId: sessionId) }
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
    /// What the last finished turn means: needs input, done, or just replied.
    public var outcome: TurnOutcome?
    /// How AI Runs knows `outcome`.
    public var outcomeSource: OutcomeSource?
    /// Wake-ups it scheduled for itself; it continues on its own.
    public var scheduled: Int?
    /// The page of a web chat, to bring its tab back.
    public var webURL: String?
    /// Set while the agent waits on its own background tasks; it continues by itself.
    public var backgroundTasks: Int?
    /// The first thing the user typed (tags removed), for naming the session.
    public var firstPrompt: String?
    /// True once the user renamed the session; automatic names then leave it alone.
    public var titleIsCustom: Bool?
    /// True once the automatic name was chosen; it then stays put instead of
    /// following every reply, so it keeps matching what the user remembers.
    public var titleSettled: Bool?
    /// What it is doing right now, in words. Cleared when the turn ends.
    public var activity: String?
    /// Its own step list, when it keeps one.
    public var progress: RunProgress?
    /// Another agent that sends this session its prompts, e.g. "coordinator".
    public var drivenBy: String?
    /// The last full step list from Claude desktop's plan tool, so a later
    /// "advance" call can move it on.
    public var planSteps: [PlanStep]?
    /// Set when this row is a Claude project thread rather than one local session.
    public var thread: ProjectThread?

    public var isInBackground: Bool { state == .working && ((backgroundTasks ?? 0) > 0 || (scheduled ?? 0) > 0) }
    /// Finished its work: shown, but not counted as needing the user.
    public var isDone: Bool { state == .yourTurn && outcome == .done }
    /// Waiting on the user: approval, a question, or a reply AI Runs can't classify.
    public var needsUser: Bool { state.needsUser && !isDone }

    public var project: String { TextUtils.projectName(fromPath: cwd) }

    public static func key(tool: AgentTool, sessionId: String) -> String { "\(tool.rawValue):\(sessionId)" }

    /// The row of a project thread, whichever local session works for it.
    public static func key(tool: AgentTool, thread: ProjectThread) -> String {
        "\(tool.rawValue):project:\(thread.projectId):\(thread.threadId)"
    }

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

/// A local session working for a conversation that has its own row (a Claude
/// project thread). One thread can have several over time; the newest one
/// it woke speaks for the row.
public struct ExecutorLink: Codable, Equatable, Sendable {
    /// The row's key.
    public var conversation: String
    public var thread: ProjectThread
    /// When the thread last woke this session.
    public var linkedAt: Date
    /// How the link was learned: "wake" (the prompt's wrapper).
    public var source: String
}

/// All open sessions, driven by hook events. Pure value type so it is easy to test.
public struct SessionStore: Codable, Equatable, Sendable {
    /// Rows by `Session.id`.
    public private(set) var sessions: [String: Session] = [:]
    /// When each tool last sent any event, keyed by `AgentTool.rawValue`.
    /// Lets the app tell "nothing running" apart from "hooks not firing".
    public private(set) var toolLastSeen: [String: Date]? = nil
    /// Each session's lifeline (working / waiting / background spans), kept for a
    /// day even after the session is resolved, for the lifelines and the header stats.
    public internal(set) var history: [String: [ActivitySpan]]? = nil
    /// Sessions the user removed. They stay out until the user sends them a
    /// new prompt, even while the agent keeps sending events.
    public private(set) var dismissed: Set<String>? = nil
    /// The tools' own internal threads (Codex naming and review helpers).
    /// Never shown.
    public private(set) var ignored: Set<String>? = nil
    /// Local sessions (by `Session.key(tool:sessionId:)`) that work for a project
    /// thread. A session without a link is its own row.
    public private(set) var executors: [String: ExecutorLink]? = nil

    public func lastSeen(_ tool: AgentTool) -> Date? { toolLastSeen?[tool.rawValue] }

    public init() {}

    public mutating func apply(_ event: AgentEvent) {
        let executor = Session.key(tool: event.tool, sessionId: event.sessionId)
        var seen = toolLastSeen ?? [:]
        seen[event.tool.rawValue] = max(seen[event.tool.rawValue] ?? event.at, event.at)
        toolLastSeen = seen

        if ignored?.contains(executor) == true { return }
        if event.kind == .promptStart, let thread = event.thread {
            link(executor: executor, event: event, to: thread)
        }
        let linked = executors?[executor]
        let key = linked?.conversation ?? executor
        if linked != nil, let row = sessions[key], row.sessionId != event.sessionId {
            if event.kind == .needsApproval || event.kind == .question {
                // Another session of this thread is blocked on the user: that
                // matters more than what the newest one is doing, so it takes the row.
                sessions[key]?.sessionId = event.sessionId
            } else {
                // An earlier session of this thread; the newest one speaks for the row.
                if event.kind == .sessionEnd { executors?[executor] = nil }
                return
            }
        }
        var session = sessions[key]
        if event.kind == .titleUpdate {
            // Only for chats AI Runs already follows; opening a page isn't a session.
            guard var session = sessions[key] else { return }
            if let url = event.url { session.webURL = url }
            if let title = event.toolTitle, session.titleIsCustom != true {
                session.title = TextUtils.truncate(title, limit: 60)
                session.titleSettled = true
            }
            sessions[key] = session
            return
        }
        if sessions[key] == nil, Self.isToolHelper(event) {
            ignore(id: key)
            return
        }
        if event.kind == .sessionEnd {
            sessions[key] = nil
            dismissed?.remove(key)
            executors?[executor] = nil
            record(nil, for: key, at: event.at)
            return
        }
        if dismissed?.contains(key) == true {
            // Only the user talking to it again, or it asking the user for
            // approval, brings a removed session back.
            let userPrompt = event.kind == .promptStart && event.drivenBy == nil
            guard userPrompt || event.kind == .needsApproval else { return }
            dismissed?.remove(key)
        }
        if session == nil {
            // Any event creates the session, so sessions that started before
            // the hooks were installed still show up. The app replaces the
            // generic title from the transcript when it can.
            let title = event.prompt.flatMap { TextUtils.cleanPrompt($0) }.map { TextUtils.truncate($0, limit: 48) }
                ?? Session.genericTitle(for: event.tool)
            session = Session(tool: event.tool, sessionId: event.sessionId, title: title, cwd: event.cwd,
                              state: .working, startedAt: event.at, turnStartedAt: event.at,
                              waitingSince: nil, lastEventAt: event.at, lastMessage: nil,
                              approvalDetail: nil, transcriptPath: event.transcriptPath,
                              terminal: event.terminal, backgroundTasks: nil, firstPrompt: nil, titleIsCustom: nil,
                              thread: linked?.thread)
        }
        guard var current = session else { return }

        current.lastEventAt = max(current.lastEventAt, event.at)
        if let cwd = event.cwd { current.cwd = cwd }
        if let path = event.transcriptPath { current.transcriptPath = path }
        if event.terminal != TerminalContext() { current.terminal = event.terminal }

        if let url = event.url { current.webURL = url }
        if let title = event.toolTitle, current.titleIsCustom != true {
            current.title = TextUtils.truncate(title, limit: 60)
            current.titleSettled = true
        }
        switch event.kind {
        case .promptStart:
            current.state = .working
            current.turnStartedAt = event.at
            current.waitingSince = nil
            current.approvalDetail = nil
            current.backgroundTasks = nil
            current.scheduled = nil
            current.outcome = nil
            current.outcomeSource = nil
            current.activity = event.tool.isWeb ? "Writing a reply" : "Thinking"
            if let driver = event.drivenBy { current.drivenBy = driver }
            if current.firstPrompt == nil, let prompt = event.prompt, let cleaned = TextUtils.cleanPrompt(prompt) {
                current.firstPrompt = TextUtils.truncate(cleaned, limit: 600)
                if current.hasGenericTitle || current.title == "Untitled session" {
                    current.title = TextUtils.truncate(cleaned, limit: 48)
                }
            }
        case .needsApproval:
            current.state = .needsApproval
            current.waitingSince = event.at
            current.approvalDetail = event.approvalDetail ?? current.approvalDetail
        case .toolActivity:
            if let activity = event.activity { current.activity = activity }
            switch event.plan {
            case .list(let steps)?:
                current.planSteps = steps
                current.progress = RunProgress(steps: steps)
            case .advance?:
                // Without a list there is nothing to move on.
                if let steps = current.planSteps {
                    let next = ActivityDescriber.advance(steps)
                    current.planSteps = next
                    current.progress = RunProgress(steps: next)
                }
            case nil:
                if let progress = event.progress {
                    current.progress = progress
                    // Another kind of list (TodoWrite) replaces the desktop plan.
                    current.planSteps = nil
                }
            }
            if current.state != .working {
                // A tool ran, so the approval or question was answered.
                current.state = .working
                current.waitingSince = nil
                current.approvalDetail = nil
                current.outcome = nil
                current.outcomeSource = nil
            }
        case .question:
            current.state = .yourTurn
            current.waitingSince = event.at
            current.approvalDetail = event.question
            current.outcome = .needsInput
            current.outcomeSource = .asked
        case .turnEnd:
            current.approvalDetail = nil
            current.activity = nil
            if let message = event.lastMessage, !message.isEmpty { current.lastMessage = message }
            if event.backgroundTasks > 0 || event.scheduled > 0 {
                // Still busy: it resumes on its own when its background tasks
                // finish or its scheduled wake-up fires.
                current.state = .working
                current.waitingSince = nil
                current.backgroundTasks = event.backgroundTasks > 0 ? event.backgroundTasks : nil
                current.scheduled = event.scheduled > 0 ? event.scheduled : nil
                current.outcome = nil
                current.outcomeSource = nil
            } else {
                current.state = .yourTurn
                current.waitingSince = event.at
                current.backgroundTasks = nil
                current.scheduled = nil
                let (outcome, source) = TurnClassifier.classify(message: event.lastMessage, progress: current.progress)
                current.outcome = outcome
                current.outcomeSource = source
                if outcome == .needsInput { current.approvalDetail = TurnClassifier.lastQuestion(in: event.lastMessage) }
            }
            if current.progress?.isFinished == true {
                current.progress = nil
                current.planSteps = nil
            }
        case .sessionEnd, .titleUpdate:
            break
        }
        sessions[key] = current
        record(SpanKind(current), for: key, at: event.at)
    }

    /// The thread woke this local session: from now on the session works for
    /// the thread's row, and as the newest one it speaks for it.
    private mutating func link(executor: String, event: AgentEvent, to thread: ProjectThread) {
        let key = Session.key(tool: event.tool, thread: thread)
        var links = executors ?? [:]
        let wasLinked = links[executor] != nil
        links[executor] = ExecutorLink(conversation: key, thread: thread, linkedAt: event.at, source: "wake")
        if links.count > 500 {
            let newest = links.sorted { $0.value.linkedAt > $1.value.linkedAt }.prefix(250)
            links = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        executors = links

        // The session's own row, from before AI Runs knew it works for a thread,
        // becomes the thread's row (or goes, when the thread already has one).
        if !wasLinked, var own = sessions.removeValue(forKey: executor) {
            if sessions[key] == nil, dismissed?.contains(key) != true {
                own.thread = thread
                sessions[key] = own
                if history?[key] == nil, let spans = history?[executor] { history?[key] = spans }
                history?[executor] = nil
            } else {
                record(nil, for: executor, at: event.at)
            }
        }
        sessions[key]?.sessionId = event.sessionId
    }

    /// The user is done with this session; it leaves the panel until the next prompt.
    public mutating func resolve(id: String, at: Date = Date()) {
        sessions[id] = nil
        record(nil, for: id, at: at)
    }

    /// Removes a session from the list until the user prompts it again.
    public mutating func dismiss(id: String, at: Date = Date()) {
        guard sessions[id] != nil else { return }
        resolve(id: id, at: at)
        var set = dismissed ?? []
        set.insert(id)
        dismissed = set
    }

    /// Codex starts short-lived helper threads (suggested next message, naming)
    /// that it never saves: they have no transcript, and their prompt says so.
    static func isToolHelper(_ event: AgentEvent) -> Bool {
        guard event.tool == .codex else { return false }
        if let prompt = event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           prompt.hasPrefix("This is an app-generated request") || prompt.hasPrefix("User: This is an app-generated") {
            return true
        }
        return event.kind == .promptStart && (event.transcriptPath ?? "").isEmpty
    }

    /// Run after loading: hides helper threads saved by older versions and
    /// judges finished turns that ended before outcomes existed.
    public mutating func tidy() {
        for (key, session) in sessions {
            if session.tool == .codex, (session.transcriptPath ?? "").isEmpty {
                ignore(id: key)
                continue
            }
            if session.state == .yourTurn, session.outcome == nil {
                let (outcome, source) = TurnClassifier.classify(message: session.lastMessage, progress: session.progress)
                sessions[key]?.outcome = outcome
                sessions[key]?.outcomeSource = source
            }
        }
    }

    /// Undoes `dismiss`.
    public mutating func restore(_ session: Session) {
        dismissed?.remove(session.id)
        sessions[session.id] = session
    }

    /// Hides a tool's internal thread for good, along with its history.
    public mutating func ignore(id: String) {
        sessions[id] = nil
        history?[id] = nil
        var set = ignored ?? []
        set.insert(id)
        if set.count > 2000 { set = Set(set.suffix(1000)) }
        ignored = set
    }

    /// The user's own name for the session. Automatic names never replace it.
    public mutating func rename(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[id]?.title = trimmed
        sessions[id]?.titleIsCustom = true
    }

    /// A suggested name, applied only while the user has not renamed the session.
    public mutating func setSuggestedTitle(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sessions[id] != nil, sessions[id]?.titleIsCustom != true else { return }
        sessions[id]?.title = TextUtils.truncate(trimmed, limit: 60)
    }

    /// The automatic name, chosen once. Ignored after the user renamed the session.
    public mutating func settleTitle(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sessions[id] != nil, sessions[id]?.titleIsCustom != true else { return }
        sessions[id]?.title = TextUtils.truncate(trimmed, limit: 60)
        sessions[id]?.titleSettled = true
    }

    /// Drops sessions nobody has touched for a long time (closed windows that
    /// never sent SessionEnd).
    public mutating func pruneStale(now: Date, olderThan age: TimeInterval = 24 * 3600) {
        let gone = sessions.filter { now.timeIntervalSince($0.value.lastEventAt) >= age }.map(\.key)
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastEventAt) < age }
        for key in gone { record(nil, for: key, at: now) }
        if let links = executors {
            let kept = links.filter { now.timeIntervalSince($0.value.linkedAt) < age || sessions[$0.value.conversation] != nil }
            executors = kept.isEmpty ? nil : kept
        }
        if var all = history {
            all = all.filter { _, spans in spans.contains { $0.end(or: now) > now.addingTimeInterval(-24 * 3600) } }
            history = all.isEmpty ? nil : all
        }
    }

    /// Sessions that need the user first, longest-waiting first; then working
    /// sessions, most recently started first.
    public func ordered() -> [Session] {
        func rank(_ session: Session) -> Int {
            switch session.state {
            case .needsApproval: return 0
            case .yourTurn:
                switch session.outcome {
                case .needsInput: return 1
                case .done: return 4
                default: return 2
                }
            case .working: return 3
            }
        }
        return sessions.values.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.needsUser {
                return (a.waitingSince ?? a.lastEventAt) < (b.waitingSince ?? b.lastEventAt)
            }
            if a.isDone { return (a.waitingSince ?? a.lastEventAt) > (b.waitingSince ?? b.lastEventAt) }
            return a.turnStartedAt > b.turnStartedAt
        }
    }

    /// Records a better judgement of a finished turn (from the on-device model),
    /// unless the turn has moved on since.
    public mutating func setOutcome(id: String, _ outcome: TurnOutcome, source: OutcomeSource, forMessage message: String?) {
        guard var session = sessions[id], session.state == .yourTurn, session.lastMessage == message,
              session.outcomeSource != .asked else { return }
        session.outcome = outcome
        session.outcomeSource = source
        if outcome == .needsInput, session.approvalDetail == nil {
            session.approvalDetail = TurnClassifier.lastQuestion(in: message)
        }
        sessions[id] = session
    }

    public var needsUserCount: Int { sessions.values.filter { $0.needsUser }.count }
    public var doneCount: Int { sessions.values.filter { $0.isDone }.count }
    public var workingCount: Int { sessions.values.filter { $0.state == .working }.count }
}
