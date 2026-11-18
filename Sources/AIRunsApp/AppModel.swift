import AIRunsCore
import AppKit
import Combine

/// Holds the sessions and the pinned board, reads new hook events, and
/// performs every action the UI offers.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var store = SessionStore()
    @Published private(set) var board = PinBoard()
    @Published private(set) var now = Date()
    /// A short confirmation shown in the panel header or as a toast.
    @Published private(set) var message: String?

    let paths = AIRunsPaths()
    let installer = HookInstaller()
    /// The app that was in front when the panel opened, for "Pin Front AI Window".
    var frontAppAtOpen: NSRunningApplication?

    private let reader: EventLogReader
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var messageWork: DispatchWorkItem?

    private struct Cursor: Codable { var offset: UInt64 }

    /// The last app the user was in that "Pin Front AI Window" can pin
    /// (a browser, an AI app, a terminal or editor). Opening the panel through
    /// Bartender or the menu bar can leave Finder or Bartender in front.
    private var lastPinnableApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init() {
        try? paths.ensureRoot()
        let cursor = JSONFile.load(Cursor.self, from: paths.cursor)
        reader = EventLogReader(url: paths.events, offset: cursor?.offset ?? 0)
        store = JSONFile.load(SessionStore.self, from: paths.sessions) ?? SessionStore()
        board = JSONFile.load(PinBoard.self, from: paths.pins) ?? PinBoard()
        installHelper()
        upgradeHooks()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if FrontWindowCapture.isPinnable(app) { self?.lastPinnableApp = app }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, FrontWindowCapture.isPinnable(front) {
            lastPinnableApp = front
        }
    }

    func start() {
        readEvents()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readEvents() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func refresh() {
        readEvents()
        tick()
    }

    private func tick() {
        now = Date()
        var updated = store
        updated.pruneStale(now: now)
        if updated != store {
            store = updated
            saveSessions()
        }
    }

    // MARK: - Events

    func readEvents() {
        let lines = reader.readNewLines()
        guard !lines.isEmpty else { return }
        var updated = store
        for line in lines {
            if let event = EventParser.parse(line: line) { updated.apply(event) }
        }
        reader.compactIfNeeded()
        if updated != store {
            store = updated
            saveSessions()
        }
        try? JSONFile.save(Cursor(offset: reader.offset), to: paths.cursor)
        now = Date()
        suggestTitles()
        refineOutcomes()
    }

    /// The reply each session was last checked at, so names are looked at
    /// once per finished turn rather than on every event.
    private var checkedAtReply: [String: String] = [:]
    private var naming: Set<String> = []

    /// Names each session once, so the name keeps matching what the user
    /// remembers instead of chasing every reply:
    /// 1. the user's own name (never replaced);
    /// 2. the tool's own title, followed whenever the tool changes it;
    /// 3. otherwise one name chosen from what was asked (on-device model,
    ///    else the first request), kept from then on.
    /// Messages already given to the on-device model, per session.
    private var judged: [String: String] = [:]

    /// When the wording of a finished turn doesn't say whether the agent is
    /// done or needs the user, asks the on-device model (macOS 26). Without
    /// it the session stays "Replied", which claims neither.
    private func refineOutcomes() {
        for session in store.sessions.values where session.state == .yourTurn
            && session.outcome == .replied && session.outcomeSource == .message {
            guard let message = session.lastMessage, judged[session.id] != message else { continue }
            judged[session.id] = message
            let id = session.id
            Task { @MainActor [weak self] in
                guard let outcome = await TitleModel.judge(lastReply: message), let self else { return }
                self.store.setOutcome(id: id, outcome, source: .model, forMessage: message)
                self.saveSessions()
            }
        }
    }

    private func suggestTitles() {
        var desktop: [ClaudeDesktopSession]?
        for session in store.sessions.values where session.titleIsCustom != true {
            let reply = session.lastMessage ?? ""
            if checkedAtReply[session.id] == reply || naming.contains(session.id) { continue }
            checkedAtReply[session.id] = reply
            let transcript = session.transcriptPath.map { URL(fileURLWithPath: $0) }

            // The Claude desktop app's sidebar name, when the session runs there.
            var toolTitle: String?
            if session.tool == .codex,
               let thread = CodexThreadIndex.thread(id: session.sessionId, database: CodexThreadIndex.database()) {
                if thread.isInternal {
                    // Codex's own helpers (naming, reviews, subagents) aren't the user's threads.
                    store.ignore(id: session.id)
                    saveSessions()
                    continue
                }
                if thread.archived {
                    store.dismiss(id: session.id, at: now)
                    saveSessions()
                    continue
                }
                toolTitle = thread.name
            }
            if session.tool == .claudeCode {
                if desktop == nil { desktop = ClaudeDesktopIndex.load(root: ClaudeDesktopIndex.root()) }
                toolTitle = ClaudeDesktopIndex.session(forCLI: session.sessionId, in: desktop ?? [])?.title
            }
            if toolTitle == nil, let transcript { toolTitle = TranscriptReader.toolTitle(at: transcript) }

            if let toolTitle {
                if toolTitle != session.title || session.titleSettled != true {
                    store.settleTitle(id: session.id, to: toolTitle)
                    saveSessions()
                }
                continue
            }
            if session.titleSettled == true { continue }

            let first = session.firstPrompt ?? transcript.flatMap { TranscriptReader.firstUserPrompt(at: $0) }
            // Only fall back to a reply when nobody typed anything (a session
            // driven by another agent).
            let lastReply = first == nil ? session.lastMessage : nil
            guard first != nil || lastReply != nil else { continue }
            let id = session.id
            naming.insert(id)
            Task { @MainActor [weak self] in
                let suggestion = await TitleModel.suggest(firstPrompt: first, lastReply: lastReply)
                guard let self else { return }
                self.naming.remove(id)
                if let name = suggestion ?? first.map({ TextUtils.truncate($0, limit: 48) }) {
                    self.store.settleTitle(id: id, to: name)
                    self.saveSessions()
                }
            }
        }
    }

    private func saveSessions() { try? JSONFile.save(store, to: paths.sessions) }
    private func savePins() { try? JSONFile.save(board, to: paths.pins) }

    // MARK: - Hook helper and hooks

    private(set) var helperMissing = false

    /// Copies the bundled `airuns-hook` to `~/.airuns/bin` so hook commands
    /// keep working wherever the app is moved.
    private func installHelper() {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "airuns-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("airuns-hook"),
        ].compactMap { $0 }
        guard let source = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            helperMissing = !fm.isExecutableFile(atPath: paths.hookHelper.path)
            return
        }
        do {
            try fm.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true)
            let temporary = paths.binDirectory.appendingPathComponent("airuns-hook.new")
            try? fm.removeItem(at: temporary)
            try fm.copyItem(at: source, to: temporary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            if fm.fileExists(atPath: paths.hookHelper.path) { try fm.removeItem(at: paths.hookHelper) }
            try fm.moveItem(at: temporary, to: paths.hookHelper)
            helperMissing = false
        } catch {
            helperMissing = !fm.isExecutableFile(atPath: paths.hookHelper.path)
        }
    }

    /// When a new version listens to more Claude Code events (such as its
    /// "ask the user" tool), adds them to hooks the user already set up.
    /// Codex is left alone: it asks the user to approve every hook change.
    private func upgradeHooks() {
        guard installer.status(for: .claudeCode) == .partiallyInstalled else { return }
        try? installer.install(tool: .claudeCode, helper: paths.hookHelper)
    }

    func hookStatus(_ tool: AgentTool) -> HookInstaller.Status { installer.status(for: tool) }

    /// Tools whose hooks are set up but have never sent an event, usually
    /// because the tool still asks the user to approve them.
    var silentTools: [AgentTool] {
        AgentTool.allCases.filter { installer.status(for: $0) == .installed && store.lastSeen($0) == nil }
    }

    var needsHookSetup: Bool {
        AgentTool.allCases.contains {
            let status = installer.status(for: $0)
            return status == .notInstalled || status == .partiallyInstalled
        }
    }

    func installHooks(_ tool: AgentTool) throws {
        try installer.install(tool: tool, helper: paths.hookHelper)
    }

    func removeHooks(_ tool: AgentTool) throws {
        try installer.uninstall(tool: tool)
    }

    /// Open the settings window on the first launch when there are hooks to set up.
    func shouldOfferSetup() -> Bool {
        let key = "didOfferHookSetup"
        guard !UserDefaults.standard.bool(forKey: key), needsHookSetup else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    // MARK: - Messages

    func show(_ text: String) {
        messageWork?.cancel()
        message = text
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.message = nil }
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }

    // MARK: - Sessions

    func open(sessionId: String) {
        guard let session = store.sessions[sessionId] else { return }
        Jumper.open(session: session, show: show)
    }

    func resolve(sessionId: String) {
        let title = store.sessions[sessionId]?.title
        store.resolve(id: sessionId)
        saveSessions()
        if let title { show("Resolved: \(title)") }
    }

    /// Takes a session off the list until the user messages it again.
    func remove(sessionId: String) {
        guard store.sessions[sessionId] != nil else { return }
        store.dismiss(id: sessionId, at: Date())
        saveSessions()
        show("Removed. It comes back if you message it again.")
    }

    func rename(sessionId: String, to title: String) {
        store.rename(id: sessionId, to: title)
        saveSessions()
    }

    func pin(sessionId: String) {
        guard let session = store.sessions[sessionId] else { return }
        let card = board.pin(session: session, now: Date())
        savePins()
        show(card.nextIsSuggested ? "Pinned to \(card.group). Next step taken from the last reply." : "Pinned to \(card.group).")
    }

    // MARK: - Cards

    func open(card: PinCard) {
        board.touch(id: card.id)
        savePins()
        guard let link = card.link else {
            show("This note isn’t linked to a conversation.")
            return
        }
        Jumper.open(link: link, show: show)
    }

    func addNote(title: String, next: String = "", group: String = PinBoard.inbox) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        board.add(PinCard(title: trimmed, next: next, group: group))
        savePins()
        show("Added to \(group).")
    }

    func addDropped(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), !trimmed.contains(" ") {
            board.add(PinCard(title: url.host ?? trimmed, link: .url(trimmed)))
            savePins()
            show("Saved the link to Inbox.")
            return
        }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        board.add(PinCard(title: TextUtils.truncate(firstLine, limit: 60),
                          next: TextUtils.lastQuestion(in: trimmed) ?? "",
                          nextIsSuggested: TextUtils.lastQuestion(in: trimmed) != nil,
                          excerpt: TextUtils.truncate(trimmed, limit: 600)))
        savePins()
        show("Saved the text to Inbox.")
    }

    func update(cardId: UUID, title: String, next: String, group: String) {
        board.update(id: cardId, title: title, next: next, group: group)
        savePins()
    }

    func keep(cardId: UUID) {
        board.touch(id: cardId)
        savePins()
        if let card = board.card(id: cardId) { show("Kept: \(card.title)") }
    }

    func archive(cardId: UUID) {
        let title = board.card(id: cardId)?.title
        board.archive(id: cardId)
        savePins()
        if let title { show("Archived: \(title)") }
    }

    /// Copies a summary of the card and opens a fresh chat where possible, so
    /// one crowded conversation can be split into clean ones.
    func continueInNewChat(card: PinCard) {
        let handoff = PinBoard.handoff(for: card)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(handoff, forType: .string)
        board.touch(id: card.id)
        savePins()
        if case .url(let string) = card.link, let host = URL(string: string)?.host {
            let newChat: String?
            if host.hasSuffix("claude.ai") { newChat = "https://claude.ai/new" }
            else if host.hasSuffix("chatgpt.com") || host.hasSuffix("chat.openai.com") { newChat = "https://chatgpt.com/" }
            else if host.hasSuffix("gemini.google.com") { newChat = "https://gemini.google.com/app" }
            else { newChat = nil }
            if let newChat, let url = URL(string: newChat) {
                NSWorkspace.shared.open(url)
                show("Opened a new chat. The summary is on your clipboard — paste it in.")
                return
            }
        }
        show("Summary copied. Paste it into a new chat to continue there.")
    }

    // MARK: - Pin Front AI Window

    func pinFrontWindow() {
        let candidate = frontAppAtOpen.flatMap { FrontWindowCapture.isPinnable($0) ? $0 : nil } ?? lastPinnableApp
        guard let app = candidate, !app.isTerminated else {
            show("Open the AI chat, browser tab or terminal you want to pin, then use Pin Front AI Window.")
            return
        }
        // A terminal or editor running a tracked session: pin that session.
        if let bundle = app.bundleIdentifier,
           let session = store.ordered()
            .filter({ $0.terminal.bundleId == bundle || Jumper.bundleId(for: $0.terminal) == bundle })
            .max(by: { $0.lastEventAt < $1.lastEventAt }) {
            pin(sessionId: session.id)
            return
        }
        if let captured = FrontWindowCapture.capture(app: app) {
            board.add(PinCard(title: captured.title, link: captured.link))
            savePins()
            show("Pinned \(captured.title) to Inbox.")
        } else {
            show("Couldn’t read that window. Try again from the browser tab or app you want to pin.")
        }
    }
}
