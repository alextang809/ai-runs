import Foundation

public enum SessionState: String, Codable, Sendable {
    case working
    case needsApproval
    case yourTurn
    /// A conversation is identified, but its current state has not been observed.
    case unknown

    /// True only when there is evidence the session is waiting on the user.
    public var needsUser: Bool { self == .needsApproval || self == .yourTurn }
}

/// One AI conversation that is still open in the panel.
///
/// Usually one local session. For a Claude project thread it is the thread,
/// and `sessionId` is the local session that worked for it most recently.
public struct Session: Codable, Equatable, Identifiable, Sendable {
    public var id: String {
        if let thread { return Session.key(tool: tool, thread: thread) }
        if let projectMainId { return Session.key(tool: tool, projectMainId: projectMainId) }
        return Session.key(tool: tool, sessionId: sessionId)
    }
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
    /// The time of the reply itself. Tool activity and opening the conversation do not move it.
    public internal(set) var lastReplyAt: Date?
    public internal(set) var pinnedAt: Date?
    var unreadPinnedReply: Bool?
    public var isPinned: Bool { pinnedAt != nil }
    public var hasUnreadReply: Bool { isPinned && unreadPinnedReply == true }
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
    /// Locally observed user prompts can change the displayed topic independently of the tool title.
    var topic: SessionTopic?
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
    /// When a hook last reported on this row.
    public var lastHookAt: Date?
    /// Set while the row's state comes from Claude's own Threads list rather
    /// than from hooks (a thread working in the cloud).
    public var native: NativeSighting?
    /// Set by "Ignore for Now" in earlier versions; see `isIgnored`. New
    /// actions use `hold`; rows already ignored keep this until they move on.
    public var ignored: Bool?
    /// Set by "Hold until…"; see `isHeld` and `isBackFromHold`.
    public internal(set) var hold: SessionHold?
    /// The project's main conversation has its own identity, separate from child threads.
    public var projectMainId: String?
    /// Identity evidence from an open page; this never refreshes native state evidence.
    public var nativeView: NativeViewSighting?

    public var claudeConversation: ClaudeConversation? {
        if let thread { return ClaudeConversation(projectId: thread.projectId, threadId: thread.threadId) }
        return projectMainId.map { ClaudeConversation(projectId: $0) }
    }
    public var claudeAppLink: URL? { claudeConversation?.appLink }
    public var isProjectConversation: Bool { claudeConversation != nil }

    public var isInBackground: Bool { state == .working && ((backgroundTasks ?? 0) > 0 || (scheduled ?? 0) > 0) }
    /// Finished its work: shown, but not counted as needing the user.
    public var isDone: Bool { state == .yourTurn && outcome == .done }
    /// Waiting on the user: approval, a question, or a reply AI Runs can't classify.
    public var needsUser: Bool {
        // A hold decides on its own: hidden until due, then back until opened.
        if hold != nil { return isBackFromHold || state == .needsApproval }
        guard waitsOnUser, !isIgnored else { return false }
        if isPinned, state == .yourTurn, outcome == .replied, native?.state != .readyForReview { return false }
        return true
    }
    /// The same, whether or not the user chose to ignore it.
    public var waitsOnUser: Bool { state.needsUser && !isDone }
    /// The user said "I know" to this wait: it stays in sight but no longer
    /// counts or reminds. Ends by itself when the run moves on.
    public var isIgnored: Bool { ignored == true && state == .yourTurn && !isDone }

    public var project: String { TextUtils.projectName(fromPath: cwd) }

    public static func key(tool: AgentTool, sessionId: String) -> String { "\(tool.rawValue):\(sessionId)" }

    /// The row of a project thread, whichever local session works for it.
    public static func key(tool: AgentTool, thread: ProjectThread) -> String {
        "\(tool.rawValue):project:\(thread.projectId):\(thread.threadId)"
    }

    /// A main conversation cannot collide with a validated child thread's cmsg address.
    public static func key(tool: AgentTool, projectMainId: String) -> String {
        "\(tool.rawValue):project:\(projectMainId):main"
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

/// What Claude's Threads list said about a thread, and when.
public struct NativeSighting: Codable, Equatable, Sendable {
    public var state: NativeThreadState
    public var seenAt: Date
    /// True once the sighting is too old to claim a state.
    public var stale: Bool?

    public init(state: NativeThreadState, seenAt: Date, stale: Bool? = nil) {
        self.state = state
        self.seenAt = seenAt
        self.stale = stale
    }

    /// A state other than "Waiting on you" is only claimed this long after it was seen.
    public static let freshFor: TimeInterval = 10 * 60
}

/// When the conversation's identity was seen in an open Claude page, not its state.
public struct NativeViewSighting: Codable, Equatable, Sendable {
    public let seenAt: Date
    public let isOpen: Bool

    public init(seenAt: Date, isOpen: Bool = true) {
        self.seenAt = seenAt
        self.isOpen = isOpen
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
    /// Removed thread rows that were waiting on the user when removed; seeing
    /// them still waiting doesn't bring them back.
    public private(set) var dismissedWaiting: Set<String>? = nil

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
            if var pinned = session, pinned.isPinned || pinned.hold != nil {
                guard event.at >= pinned.lastEventAt else { return }
                pinned.lastEventAt = event.at
                if !pinned.isDone { pinned.clearObservedState() }
                sessions[key] = pinned
            } else {
                sessions[key] = nil
            }
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
        let userPrompt = event.kind == .promptStart && event.drivenBy == nil
            ? event.prompt.flatMap(UserTopicPrompt.init) : nil
        if session == nil {
            // Any event creates the session, so sessions that started before
            // the hooks were installed still show up. The app replaces the
            // generic title from the transcript when it can.
            let title = userPrompt.map { TextUtils.truncate($0.cleaned, limit: 48) }
                ?? Session.genericTitle(for: event.tool)
            session = Session(tool: event.tool, sessionId: event.sessionId, title: title, cwd: event.cwd,
                              state: .working, startedAt: event.at, turnStartedAt: event.at,
                              waitingSince: nil, lastEventAt: event.at, lastMessage: nil,
                              approvalDetail: nil, transcriptPath: event.transcriptPath,
                              terminal: event.terminal, backgroundTasks: nil, firstPrompt: nil, titleIsCustom: nil,
                              thread: linked?.thread)
        }
        guard var current = session else { return }

        // Preserve a stable best-known date for replies from older versions before a new turn moves it.
        if current.lastMessage != nil, current.lastReplyAt == nil {
            current.lastReplyAt = current.waitingSince ?? current.lastEventAt
        }
        if event.kind == .turnEnd, let replyAt = current.lastReplyAt, event.at < replyAt { return }
        current.lastEventAt = max(current.lastEventAt, event.at)
        // A hook knows more than a look at Claude's window.
        current.lastHookAt = event.at
        current.native = nil
        // Whatever it reports next is a new moment.
        current.ignored = nil
        // Approval never waits. A returned hold is over once the user talks to it.
        if event.kind == .needsApproval || (userPrompt != nil && current.isBackFromHold) { current.hold = nil }
        if let cwd = event.cwd { current.cwd = cwd }
        if let path = event.transcriptPath { current.transcriptPath = path }
        if event.terminal != TerminalContext() { current.terminal = event.terminal }

        if let url = event.url { current.webURL = url }
        if let title = event.toolTitle, current.titleIsCustom != true {
            current.title = TextUtils.truncate(title, limit: 60)
            current.titleSettled = true
        }
        // A delayed event from a previous topic must not supply the new topic's saved excerpt.
        if let topicStart = current.topic?.startedAt, event.at < topicStart { return }
        switch event.kind {
        case .promptStart:
            if let userPrompt {
                current.observeTopic(prompt: userPrompt, at: event.at)
                if current.lastMessage == nil {
                    current.lastReplyAt = nil
                    current.unreadPinnedReply = nil
                }
            }
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
            if current.firstPrompt == nil, let cleaned = userPrompt?.cleaned {
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
            if let message = event.lastMessage, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if current.isPinned, current.lastReplyAt != event.at || current.lastMessage != message {
                    current.unreadPinnedReply = true
                }
                current.lastReplyAt = event.at
                current.lastMessage = message
            }
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
                if own.isPinned, sessions[key]?.isPinned == false {
                    sessions[key]?.pinnedAt = own.pinnedAt
                }
                if let hold = own.hold, sessions[key]?.hold == nil {
                    sessions[key]?.hold = hold
                }
                record(nil, for: executor, at: event.at)
            }
        }
        sessions[key]?.sessionId = event.sessionId
    }

    // MARK: - Claude's Threads list

    /// How long after a hook event the hooks alone speak for a row.
    static let hookGrace: TimeInterval = 120

    /// Folds in what Claude's Threads list showed at `at`. This is how threads
    /// that work only in the cloud get a row.
    ///
    /// - A thread with no row gets one when it is working or wants the user;
    ///   idle threads AI Runs never saw active stay out.
    /// - A row hooks reported on in the last two minutes keeps its hook state.
    /// - Threads missing from `sightings` are untouched: the list is often
    ///   only partly drawn, so absence means nothing.
    public mutating func observe(_ sightings: [ThreadSighting], at: Date, tool: AgentTool = .claudeCode) {
        for sighting in sightings {
            let key = Session.key(tool: tool, thread: sighting.thread)
            if let state = sighting.state, state != .waitingOnYou { dismissedWaiting?.remove(key) }

            guard var row = sessions[key] else {
                guard let state = sighting.state, state != .idle else { continue }
                if dismissed?.contains(key) == true {
                    // Like an approval request: only wanting the user brings a removed row back.
                    guard state == .waitingOnYou, dismissedWaiting?.contains(key) != true else { continue }
                    dismissed?.remove(key)
                }
                var created = Session(tool: tool, sessionId: "", title: sighting.title ?? "Claude thread", cwd: nil,
                                      state: .working, startedAt: at, turnStartedAt: at, waitingSince: nil,
                                      lastEventAt: at, lastMessage: nil, approvalDetail: nil, transcriptPath: nil,
                                      terminal: TerminalContext(bundleId: "com.anthropic.claudefordesktop"),
                                      backgroundTasks: nil, firstPrompt: nil, titleIsCustom: nil,
                                      titleSettled: sighting.title == nil ? nil : true, thread: sighting.thread)
                Self.drive(&created, to: state, at: at)
                sessions[key] = created
                record(SpanKind(created), for: key, at: at)
                continue
            }

            // Claude's own name for the thread beats one made from a request.
            if let title = sighting.title, row.titleIsCustom != true {
                row.title = title
                row.titleSettled = true
            }
            if let state = sighting.state {
                let hookIsFresh = at.timeIntervalSince(row.lastHookAt ?? row.lastEventAt) < Self.hookGrace
                if row.state == .unknown || row.native != nil || !(hookIsFresh || Self.agrees(row, with: state)) {
                    Self.drive(&row, to: state, at: at)
                    record(SpanKind(row), for: key, at: at)
                }
            }
            sessions[key] = row
        }
        expireSightings(now: at)
    }

    /// Identifies current pages without inferring state from their conversation content.
    public mutating func observeCurrentViews(_ views: [CurrentClaudeView], at: Date,
                                            tool: AgentTool = .claudeCode, complete: Bool = true) {
        if complete { retireCurrentViews(for: tool) }
        for view in views {
            let conversation = view.conversation
            guard conversation.appLink != nil else { continue }
            let key = conversation.thread.map { Session.key(tool: tool, thread: $0) }
                ?? Session.key(tool: tool, projectMainId: conversation.projectId)
            guard dismissed?.contains(key) != true, ignored?.contains(key) != true else { continue }
            var row = sessions[key] ?? Self.currentRow(for: conversation, tool: tool, at: at)
            if let title = view.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
               row.titleIsCustom != true, row.titleSettled != true {
                row.title = TextUtils.truncate(title, limit: 60)
                row.titleSettled = true
            }
            row.nativeView = NativeViewSighting(seenAt: at)
            sessions[key] = row
        }
        expireSightings(now: at)
    }

    private mutating func retireCurrentViews(for tool: AgentTool) {
        sessions = sessions.mapValues { row in
            guard row.tool == tool, let view = row.nativeView, view.isOpen else { return row }
            var closed = row
            closed.nativeView = NativeViewSighting(seenAt: view.seenAt, isOpen: false)
            return closed
        }
    }

    private static func currentRow(for conversation: ClaudeConversation, tool: AgentTool, at: Date) -> Session {
        Session(tool: tool, sessionId: "", title: conversation.thread == nil ? "Claude project conversation" : "Claude thread",
                cwd: nil, state: .unknown, startedAt: at, turnStartedAt: at, waitingSince: nil,
                lastEventAt: at, lastMessage: nil, approvalDetail: nil, transcriptPath: nil,
                terminal: TerminalContext(bundleId: "com.anthropic.claudefordesktop"),
                thread: conversation.thread, projectMainId: conversation.thread == nil ? conversation.projectId : nil)
    }

    /// Rows whose last look at Claude's list is too old stop claiming a state.
    /// "Waiting on you" is kept: it stays true until the user answers.
    public mutating func expireSightings(now: Date) {
        for (key, row) in sessions {
            guard let native = row.native, native.stale != true, native.state != .waitingOnYou,
                  now.timeIntervalSince(native.seenAt) > NativeSighting.freshFor else { continue }
            sessions[key]?.native?.stale = true
            sessions[key]?.state = .unknown
            sessions[key]?.outcome = nil
            sessions[key]?.outcomeSource = nil
            sessions[key]?.waitingSince = nil
            record(nil, for: key, at: now)
        }
    }

    private static func target(_ state: NativeThreadState) -> (state: SessionState, outcome: TurnOutcome?) {
        switch state {
        case .working: return (.working, nil)
        case .waitingOnYou: return (.yourTurn, .needsInput)
        case .readyForReview: return (.yourTurn, .replied)
        case .idle: return (.yourTurn, .done)
        }
    }

    /// True when the hooks already say what Claude's list says.
    private static func agrees(_ row: Session, with state: NativeThreadState) -> Bool {
        if state == .waitingOnYou, row.state == .needsApproval { return true }
        let wanted = target(state)
        return row.state == wanted.state && row.outcome == wanted.outcome
    }

    /// Claude's list now speaks for the row.
    private static func drive(_ row: inout Session, to state: NativeThreadState, at: Date) {
        let wanted = target(state)
        let changed = row.native?.stale == true || row.state != wanted.state || row.outcome != wanted.outcome
        row.native = NativeSighting(state: state, seenAt: at)
        row.lastEventAt = max(row.lastEventAt, at)
        guard changed else { return }
        row.ignored = nil
        row.state = wanted.state
        row.outcome = wanted.outcome
        row.outcomeSource = nil
        row.approvalDetail = nil
        row.activity = nil
        row.backgroundTasks = nil
        row.scheduled = nil
        if wanted.state == .working {
            row.turnStartedAt = at
            row.waitingSince = nil
        } else {
            row.waitingSince = at
        }
    }

    /// The user is done with this session; it leaves the panel until the next prompt.
    public mutating func resolve(id: String, at: Date = Date()) {
        sessions[id] = nil
        record(nil, for: id, at: at)
    }

    /// Removes a session from the list until the user prompts it again.
    public mutating func dismiss(id: String, at: Date = Date()) {
        guard let session = sessions[id] else { return }
        if session.thread != nil, session.waitsOnUser {
            var waiting = dismissedWaiting ?? []
            waiting.insert(id)
            dismissedWaiting = waiting
        }
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
        retireCurrentViews(for: .claudeCode)
        for (key, session) in sessions {
            if session.native?.stale == true {
                var unknown = session
                unknown.state = .unknown
                unknown.outcome = nil
                unknown.outcomeSource = nil
                unknown.waitingSince = nil
                sessions[key] = unknown
                continue
            }
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

    /// Older versions mistook voice and app-created conversations for helpers. Replay only
    /// their retained hook events, without reviving archived or user-removed rows.
    public func recoveringCodexConversations(_ threads: [CodexThread], events: [AgentEvent]) -> SessionStore {
        let keys = Set(threads.filter {
            $0.wasMisclassifiedAsInternal && !$0.archived
        }.map { Session.key(tool: .codex, sessionId: $0.id) })
            .intersection(ignored ?? [])
            .subtracting(dismissed ?? [])
        guard !keys.isEmpty else { return self }
        var recovered = self
        recovered.ignored = ignored?.subtracting(keys)
        for event in events where event.tool == .codex
            && keys.contains(Session.key(tool: event.tool, sessionId: event.sessionId)) {
            recovered.apply(event)
        }
        for thread in threads where keys.contains(Session.key(tool: .codex, sessionId: thread.id)) {
            if let name = thread.name {
                recovered.settleTitle(id: Session.key(tool: .codex, sessionId: thread.id), to: name)
            }
        }
        return recovered
    }

    /// "Ignore for Now" and "Stop Ignoring". Only a question or a reply can be
    /// ignored: an approval request blocks the agent until it is answered.
    public mutating func setIgnored(id: String, _ ignored: Bool, at: Date = Date()) {
        guard var session = sessions[id], session.state == .yourTurn, session.waitsOnUser else { return }
        session.ignored = ignored ? true : nil
        sessions[id] = session
        record(SpanKind(session), for: id, at: at)
    }

    // MARK: - Hold

    /// "Hold until…": out of Needs you and the count until `until`, or, with
    /// `waitingOn`, until the user checks back. Refused for a session waiting
    /// for approval, and for a time that has already passed. Replaces an old
    /// "Ignore for Now" on the same row.
    @discardableResult
    public mutating func hold(id: String, until: Date, waitingOn: String? = nil, at now: Date) -> Bool {
        guard var session = sessions[id], session.canHold, until > now else { return false }
        session.hold = SessionHold(until: until, waitingOn: waitingOn.map(Self.cleanName), heldAt: now)
        session.ignored = nil
        sessions[id] = session
        record(SpanKind(session), for: id, at: now)
        return true
    }

    /// Moves a hold to another time and keeps whether it waits on someone and their name.
    @discardableResult
    public mutating func reschedule(id: String, until: Date, at now: Date) -> Bool {
        guard let current = sessions[id]?.hold else { return hold(id: id, until: until, at: now) }
        return hold(id: id, until: until, waitingOn: current.waitingOn, at: now)
    }

    /// Names who the user waits on; an empty name means nobody in particular.
    public mutating func setWaitingName(id: String, _ name: String) {
        guard sessions[id]?.hold?.isWaiting == true else { return }
        sessions[id]?.hold?.waitingOn = Self.cleanName(name)
    }

    /// "Bring back now": the hold ends and the session shows as it really is.
    public mutating func bringBack(id: String, at now: Date = Date()) {
        guard sessions[id]?.hold != nil else { return }
        sessions[id]?.hold = nil
        if let session = sessions[id] { record(SpanKind(session), for: id, at: now) }
    }

    /// The user opened a session that came back: its "Back from hold" is done.
    /// Opening before it is due keeps the hold. Pass the hold that was showing
    /// when the user clicked, so a slow open can't clear a newer hold.
    public mutating func acknowledgeReturn(id: String, of opened: SessionHold? = nil) {
        guard let hold = sessions[id]?.hold, hold.returnedAt != nil else { return }
        if let opened, opened != hold { return }
        sessions[id]?.hold = nil
    }

    /// Undo of a hold command: puts back the hold and the old "Ignore for Now"
    /// exactly as they were. A hold that came due in the meantime stays due.
    public mutating func restoreHold(id: String, hold: SessionHold?, ignored: Bool?, at now: Date) {
        guard var session = sessions[id] else { return }
        session.hold = hold
        session.ignored = ignored
        sessions[id] = session
        reconcileHolds(now: now)
        if let session = sessions[id] { record(SpanKind(session), for: id, at: now) }
    }

    /// Brings back every hold whose time has come, including ones missed while
    /// the Mac slept or the app was closed. Returns true when anything changed.
    @discardableResult
    public mutating func reconcileHolds(now: Date) -> Bool {
        var changed = false
        for (key, session) in sessions {
            guard let hold = session.hold, hold.returnedAt == nil, hold.until <= now else { continue }
            sessions[key]?.hold?.returnedAt = now
            // From here on the agent waits on the user again.
            if let back = sessions[key] { record(SpanKind(back), for: key, at: now) }
            changed = true
        }
        return changed
    }

    /// Held sessions, soonest back first.
    public var held: [Session] {
        sessions.values.filter(\.isHeld).sorted {
            let a = $0.hold?.until ?? .distantFuture, b = $1.hold?.until ?? .distantFuture
            return a == b ? $0.id < $1.id : a < b
        }
    }

    private static func cleanName(_ name: String) -> String {
        TextUtils.truncate(name.trimmingCharacters(in: .whitespacesAndNewlines), limit: 40)
    }

    public mutating func setPinned(id: String, _ pinned: Bool, at date: Date = Date()) {
        guard var session = sessions[id], session.isPinned != pinned else { return }
        session.pinnedAt = pinned ? date : nil
        session.unreadPinnedReply = nil
        sessions[id] = session
    }

    public mutating func markReplyRead(id: String) {
        guard sessions[id]?.hasUnreadReply == true else { return }
        sessions[id]?.unreadPinnedReply = nil
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
        for (key, session) in sessions {
            let lastSeen = max(session.lastEventAt, session.nativeView?.seenAt ?? .distantPast)
            guard now.timeIntervalSince(lastSeen) >= age else { continue }
            if session.isPinned || session.hold != nil {
                guard session.state == .working else { continue }
                sessions[key]?.clearObservedState()
            } else {
                sessions[key] = nil
            }
            record(nil, for: key, at: now)
        }
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
            if session.isBackFromHold, session.state != .needsApproval { return 1 }
            switch session.state {
            case .needsApproval: return 0
            case .yourTurn:
                switch session.outcome {
                case .needsInput: return session.isIgnored ? 6 : 1
                case .done: return 5
                default: return session.isIgnored ? 6 : 2
                }
            case .working: return 3
            case .unknown: return 4
            }
        }
        return sessions.values.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.needsUser {
                return (a.waitingSince ?? a.lastEventAt) < (b.waitingSince ?? b.lastEventAt)
            }
            if a.isDone || a.isIgnored { return (a.waitingSince ?? a.lastEventAt) > (b.waitingSince ?? b.lastEventAt) }
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
