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
    /// Where `message` belongs: the header, or next to the On hold line when
    /// it answers something the user just did there.
    enum MessagePlace { case header, hold }
    @Published private(set) var messagePlace: MessagePlace = .header
    /// Offered next to `message` for a few seconds after removing something.
    @Published private(set) var undo: (() -> Void)?

    let paths: AIRunsPaths
    let installer: HookInstaller
    let usage = UsageMonitor()
    let accounts = AccountManager()
    /// The app that was in front when the panel opened, for "Pin Front AI Window".
    var frontAppAtOpen: NSRunningApplication?

    private let usesSystemServices: Bool
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
    private var wakeObserver: NSObjectProtocol?

    /// Isolated state for native UI tests; no hooks, observers, or polling start.
    init(testingRoot: URL, store: SessionStore = SessionStore(), board: PinBoard = PinBoard()) {
        usesSystemServices = false
        paths = AIRunsPaths(root: testingRoot)
        installer = HookInstaller(home: testingRoot)
        reader = EventLogReader(url: paths.events, offset: 0)
        self.store = store
        self.board = board
    }
    init() {
        usesSystemServices = true
        paths = AIRunsPaths()
        installer = HookInstaller()
        try? paths.ensureRoot()
        let cursor = JSONFile.load(Cursor.self, from: paths.cursor)
        reader = EventLogReader(url: paths.events, offset: cursor?.offset ?? 0)
        store = JSONFile.load(SessionStore.self, from: paths.sessions) ?? SessionStore()
        store.tidy()
        store.reconcileHolds(now: Date())
        board = JSONFile.load(PinBoard.self, from: paths.pins) ?? PinBoard()
        recoverCodexConversations()
        installHelper()
        upgradeHooks()
        Notifier.shared.open = { [weak self] id in self?.open(sessionId: id) }
        Notifier.shared.hold = { [weak self] id in
            guard let self else { return }
            // Later today, or tomorrow morning when it is already late.
            self.hold(sessionId: id, until: HoldPlan(now: Date()).date(for: .later))
        }
        Notifier.shared.update(sessions: Array(store.sessions.values))
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if FrontWindowCapture.isPinnable(app) { self?.lastPinnableApp = app }
            }
        }
        // Holds that came due while the Mac slept come back as soon as it wakes.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let front = NSWorkspace.shared.frontmostApplication, FrontWindowCapture.isPinnable(front) {
            lastPinnableApp = front
        }
    }

    /// Migrate the old internal-thread filter once, using a separate reader so
    /// the normal event cursor and unrelated sessions stay untouched.
    private func recoverCodexConversations() {
        let threads = (store.ignored ?? []).compactMap { key -> CodexThread? in
            guard key.hasPrefix("codex:"), store.dismissed?.contains(key) != true else { return nil }
            let id = String(key.dropFirst("codex:".count))
            guard let thread = CodexThreadIndex.thread(id: id, database: CodexThreadIndex.database()),
                  thread.wasMisclassifiedAsInternal, !thread.archived else { return nil }
            return thread
        }
        guard !threads.isEmpty else { return }
        let events = EventLogReader(url: paths.events).readNewLines(upTo: reader.offset)
            .compactMap { EventParser.parse(line: $0) }
        store = store.recoveringCodexConversations(threads, events: events)
        try? JSONFile.save(store, to: paths.sessions)
    }

    func start() {
        accounts.onProfilesChanged = { [weak usage] roots in usage?.includeManagedRoots(roots) }
        accounts.start()
        readEvents()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readEvents() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        threadsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readClaudeThreads() }
        }
    }

    // MARK: - Claude's Threads list

    private var threadsTimer: Timer?
    private var threadReads = ThreadReadQueue()

    /// Whether Claude's Threads list can be read, and what the last look found.
    enum ThreadsStatus: Equatable {
        case off
        case claudeNotRunning
        case needsPermission
        case read(found: Int, complete: Bool)
    }

    @Published private(set) var threadsStatus: ThreadsStatus = .off

    /// Looks at the Claude app's window for project threads, which is the only
    /// way to see the ones that work in the cloud.
    private func readClaudeThreads(request: ThreadReadQueue.Request = .regular) {
        let wasIdle = threadReads.active == nil
        threadReads = threadReads.requesting(request)
        if wasIdle, let active = threadReads.active { startThreadRead(active) }
    }

    private func startThreadRead(_ request: ThreadReadQueue.Request) {
        let pid: pid_t
        switch ClaudeThreadsReader.availability() {
        case .off: completeThreadRead(.off)
            return
        case .claudeNotRunning: completeThreadRead(.claudeNotRunning)
            return
        case .needsPermission: completeThreadRead(.needsPermission)
            return
        case .ready(let id): pid = id
        }
        let budget = request == .refresh ? ClaudeThreadsReader.refreshBudget : ClaudeThreadsReader.regularBudget
        ClaudeThreadsReader.read(pid: pid, budget: budget) { [weak self] reading in
            MainActor.assumeIsolated {
                let listed = reading.sightings.map {
                    ClaudeConversation(projectId: $0.thread.projectId, threadId: $0.thread.threadId)
                }
                let conversations = Set(listed).union(reading.currentViews.map(\.conversation))
                self?.completeThreadRead(.read(found: conversations.count, complete: reading.complete), reading: reading)
            }
        }
    }

    private func completeThreadRead(_ status: ThreadsStatus, reading: ClaudeThreadsReader.Reading? = nil) {
        let announce = threadReads.shouldAnnounce
        threadReads = threadReads.completing()
        if threadsStatus != status { threadsStatus = status }
        if announce { show(Self.refreshText(status)) }
        if let reading {
            apply(reading)
        } else {
            // A disabled or unavailable reader cannot keep claiming a page is open.
            apply(.init(sightings: [], complete: true))
        }
        // Store updates can be empty or unchanged; queued refreshes still run.
        if let next = threadReads.active { startThreadRead(next) }
    }

    private func apply(_ reading: ClaudeThreadsReader.Reading) {
        let observedAt = Date()
        var updated = store
        updated.observe(reading.sightings, at: observedAt)
        updated.observeCurrentViews(reading.currentViews, at: observedAt, complete: reading.complete)
        guard updated != store else { return }
        store = updated
        now = observedAt
        saveSessions()
    }

    /// What a refresh the user asked for says, in a few words.
    static func refreshText(_ status: ThreadsStatus) -> String {
        switch status {
        case .off: return "Refreshed · Claude threads off in Settings"
        case .claudeNotRunning: return "Refreshed · Claude isn’t open"
        case .needsPermission: return "Refreshed · Claude threads need Accessibility"
        case .read(let found, let complete):
            if found > 0 { return "Refreshed · \(found) Claude conversation\(found == 1 ? "" : "s") seen" }
            return complete ? "Refreshed · show a Claude project or its Threads list"
                            : "Refreshed · Claude’s window was too big to read"
        }
    }

    func refresh() {
        readEvents()
        tick()
    }

    /// The refresh button: hook events, the clock and Claude's Threads list
    /// right now, reading more of Claude's window than the regular look does.
    func refreshNow() {
        usage.refreshNow()
        accounts.refreshAll()
        refresh()
        readClaudeThreads(request: .refresh)
    }

    func stop() {
        pollTimer?.invalidate()
        clockTimer?.invalidate()
        threadsTimer?.invalidate()
        usage.stop()
        accounts.stop()
    }

    /// Asks macOS for Accessibility (shows its prompt), then looks again.
    func allowAccessibility() {
        _ = SidebarClicker.requestTrust()
        readClaudeThreads()
    }

    private func tick() {
        now = Date()
        var updated = store
        updated.reconcileHolds(now: now)
        updated.pruneStale(now: now)
        updated.expireSightings(now: now)
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
        guard usesSystemServices else { return }
        suggestTitles()
        refineOutcomes()
        Notifier.shared.update(sessions: Array(store.sessions.values))
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
                Notifier.shared.update(sessions: Array(self.store.sessions.values))
            }
        }
    }

    private func suggestTitles() {
        var desktop: [ClaudeDesktopSession]?
        for session in store.sessions.values where session.titleIsCustom != true && !session.tool.isWeb {
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
            // A project thread's local session has its own name, which isn't the
            // thread's; the thread is named from what was asked in it.
            if session.tool == .claudeCode, !session.isProjectConversation {
                if desktop == nil { desktop = ClaudeDesktopIndex.load(root: ClaudeDesktopIndex.root()) }
                toolTitle = ClaudeDesktopIndex.session(forCLI: session.sessionId, in: desktop ?? [])?.title
            }
            if toolTitle == nil, !session.isProjectConversation, let transcript { toolTitle = TranscriptReader.toolTitle(at: transcript) }

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

    private func saveSessions() {
        try? JSONFile.save(store, to: paths.sessions)
        guard usesSystemServices else { return }
        // Removing, restoring or renaming changes what notifications should
        // show even though no event arrived.
        Notifier.shared.update(sessions: Array(store.sessions.values))
    }
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

    // MARK: - Browser extension

    let browserConnector = BrowserConnector()

    func browserStatus() -> [(browser: BrowserConnector.Browser, connected: Bool)] {
        browserConnector.status(helper: paths.hookHelper)
    }

    /// Lets the installed Chromium browsers start AI Runs' helper for the extension.
    @discardableResult
    func connectBrowsers() throws -> [String] {
        try browserConnector.install(helper: paths.hookHelper)
    }

    /// Copies the extension out of the app (so its folder survives app
    /// updates) and shows it in Finder, ready for "Load unpacked".
    func revealExtension() {
        let fm = FileManager.default
        guard let source = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else {
            show("The extension isn’t in this build. Use the BrowserExtension folder from the repository.")
            return
        }
        let target = paths.root.appendingPathComponent("browser-extension", isDirectory: true)
        try? fm.removeItem(at: target)
        do {
            try fm.copyItem(at: source, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            show("Couldn’t copy the extension: \(error.localizedDescription)")
        }
    }

    /// Tools whose hooks are set up but have never sent an event, usually
    /// because the tool still asks the user to approve them.
    var silentTools: [AgentTool] {
        AgentTool.hookTools.filter { installer.status(for: $0) == .installed && store.lastSeen($0) == nil }
    }

    var needsHookSetup: Bool {
        AgentTool.hookTools.contains {
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

    func show(_ text: String, place: MessagePlace = .header, undo: (() -> Void)? = nil) {
        messageWork?.cancel()
        messagePlace = place
        message = text
        self.undo = undo
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.message = nil
                self?.undo = nil
            }
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (undo == nil ? 2.8 : 6), execute: work)
    }

    func performUndo() {
        let action = undo
        messageWork?.cancel()
        message = nil
        undo = nil
        action?()
    }

    // MARK: - Sessions

    func toggleSessionPin(_ sessionID: String) {
        guard let session = store.sessions[sessionID] else { return }
        var updated = store
        updated.setPinned(id: sessionID, !session.isPinned)
        do {
            try JSONFile.save(updated, to: paths.sessions)
            store = updated
        } catch {
            show("Couldn’t update the pin.")
        }
    }

    func markSessionRead(_ session: Session) {
        guard let current = store.sessions[session.id], current.hasUnreadReply,
              current.lastReplyAt == session.lastReplyAt, current.lastMessage == session.lastMessage,
              current.currentTopicID == session.currentTopicID else { return }
        store.markReplyRead(id: session.id)
        saveSessions()
    }

    func open(sessionId: String) {
        guard let session = store.sessions[sessionId] else { return }
        Jumper.open(session: session, opened: { [weak self] in
            self?.markSessionRead(session)
            self?.acknowledgeReturn(sessionId, of: session.hold)
        }, show: { [weak self] in self?.show($0) })
    }

    // MARK: - Hold

    /// Dates for the line and the menus, from the clock and calendar right now.
    var holdPlan: HoldPlan { HoldPlan(now: Date()) }

    /// Holds a session until `until`, or moves its hold there. A session that
    /// waits on someone keeps waiting, with its name. Returns false when it
    /// can't be held (approval, or a time that has passed).
    @discardableResult
    func hold(sessionId: String, until: Date) -> Bool {
        let before = store.sessions[sessionId]
        var updated = store
        guard updated.reschedule(id: sessionId, until: until, at: Date()) else { return refuseHold(sessionId) }
        commitHold(updated, sessionId: sessionId, before: before)
        return true
    }

    /// "Waiting on…": held until the user checks back, by default at 9:00 two
    /// days from now. A session already waiting keeps its check-back time and
    /// name; one that came back gets a new time and keeps its name.
    @discardableResult
    func holdWaiting(sessionId: String) -> Bool {
        let before = store.sessions[sessionId]
        let previous = before?.hold
        let now = Date()
        let keepsTime = previous?.isWaiting == true && previous?.returnedAt == nil && (previous?.until ?? now) > now
        let until = keepsTime ? previous?.until ?? holdPlan.date(for: .waiting) : holdPlan.date(for: .waiting)
        var updated = store
        guard updated.hold(id: sessionId, until: until, waitingOn: previous?.waitingOn ?? "", at: now) else {
            return refuseHold(sessionId)
        }
        commitHold(updated, sessionId: sessionId, before: before)
        return true
    }

    func setWaitingName(sessionId: String, _ name: String) {
        guard store.sessions[sessionId]?.hold?.isWaiting == true,
              store.sessions[sessionId]?.hold?.waitingOn != name else { return }
        store.setWaitingName(id: sessionId, name)
        saveSessions()
    }

    /// "Bring back now".
    func bringBack(sessionId: String) {
        guard let before = store.sessions[sessionId], before.hold != nil else { return }
        store.bringBack(id: sessionId)
        saveSessions()
        show("Back in your list", place: .hold) { [weak self] in self?.restoreHold(from: before) }
    }

    /// Says something next to the On hold line (a hint, or why nothing happened).
    func showHoldNote(_ text: String) { show(text, place: .hold) }

    private func acknowledgeReturn(_ sessionId: String, of opened: SessionHold?) {
        guard store.sessions[sessionId]?.isBackFromHold == true else { return }
        store.acknowledgeReturn(id: sessionId, of: opened)
        saveSessions()
    }

    private func commitHold(_ updated: SessionStore, sessionId: String, before: Session?) {
        store = updated
        saveSessions()
        guard let hold = store.sessions[sessionId]?.hold else { return }
        let when = holdPlan.when(hold.until)
        show(hold.isWaiting ? "Check back \(when)" : "Back \(when)", place: .hold) { [weak self] in
            if let before { self?.restoreHold(from: before) }
        }
    }

    /// Undo: the hold and the old "Ignore for Now" go back to what they were.
    private func restoreHold(from before: Session) {
        store.restoreHold(id: before.id, hold: before.hold, ignored: before.ignored, at: Date())
        saveSessions()
    }

    private func refuseHold(_ sessionId: String) -> Bool {
        if store.sessions[sessionId]?.canHold == false { show("Approvals can’t wait. Answer it first.", place: .hold) }
        return false
    }

    func resolve(sessionId: String) {
        let title = store.sessions[sessionId]?.currentTopicTitle
        store.resolve(id: sessionId)
        saveSessions()
        if let title { show("Resolved: \(title)") }
    }

    /// Takes a session off the list until the user messages it again.
    func remove(sessionId: String) {
        guard let session = store.sessions[sessionId] else { return }
        store.dismiss(id: sessionId, at: Date())
        saveSessions()
        show("Removed “\(TextUtils.truncate(session.currentTopicTitle, limit: 28))”") { [weak self] in
            self?.store.restore(session)
            self?.saveSessions()
        }
    }

    func rename(sessionId: String, to title: String) {
        store.rename(id: sessionId, to: title)
        saveSessions()
    }

    /// "Ignore for Now" / "Stop Ignoring" on a run that waits on the user.
    func setIgnored(sessionId: String, _ ignored: Bool) {
        store.setIgnored(id: sessionId, ignored, at: Date())
        saveSessions()
        if ignored, store.sessions[sessionId]?.isIgnored == true {
            show("Ignored. It comes back when it asks something new.")
        }
    }

    func pin(sessionId: String) -> PinCard? {
        guard let session = store.sessions[sessionId] else { return nil }
        var updated = board
        let card = updated.pin(session: session, now: Date())
        return persistBoard(updated) ? card : nil
    }

    @discardableResult
    func saveReply(_ session: Session) -> PinCard? {
        if let existing = board.savedReply(session: session) { return existing }
        var updated = board
        guard let card = updated.saveReply(session: Jumper.sessionForBookmark(session)), persistBoard(updated) else { return nil }
        markSessionRead(session)
        return card
    }

    func openLabel(for attachment: PinAttachment) -> String {
        Jumper.openLabel(for: attachment.link, in: store)
    }

    func liveTitle(for attachment: PinAttachment) -> String? {
        Jumper.currentSession(for: attachment.link, in: store)?.currentTopicTitle
    }

    private func persistBoard(_ updated: PinBoard) -> Bool {
        do {
            try JSONFile.save(updated, to: paths.pins)
            board = updated
            return true
        } catch {
            show("Couldn’t save the pinned card.")
            return false
        }
    }

    // MARK: - Cards

    var pinSessionCandidates: [Session] {
        store.ordered().filter { session in
            if AgentTool.hookTools.contains(session.tool) { return true }
            guard session.tool == .claudeWeb else { return false }
            if case .url = PinAttachment.session(session).link { return true }
            return false
        }
    }

    @discardableResult
    func attach(_ attachment: PinAttachment, to cardID: UUID) -> Bool {
        guard board.attach(attachment, to: cardID) else { return false }
        savePins()
        return true
    }

    @discardableResult
    func detach(_ attachmentID: UUID, from cardID: UUID) -> Bool {
        guard board.detach(attachmentID, from: cardID) else { return false }
        savePins()
        return true
    }

    @discardableResult
    func setMenuNext(_ selected: Bool, for cardID: UUID, next: String? = nil) -> Bool {
        guard let existing = board.card(id: cardID) else { return false }
        var updated = board
        if let next {
            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            updated.update(id: cardID, next: trimmed)
        }
        if selected != (existing.menuNextAt != nil) {
            guard updated.setMenuNext(selected, for: cardID) else {
                if selected, updated.menuNextCards.count >= PinBoard.maximumMenuNextCards {
                    show("Three cards are kept at the top. Use recent order for one to keep another.")
                }
                return false
            }
        } else if next == nil {
            return false
        }
        do {
            try JSONFile.save(updated, to: paths.pins)
            board = updated
            return true
        } catch {
            show("Couldn’t save the pinned card.")
            return false
        }
    }

    func open(card: PinCard) {
        guard let attachments = board.card(id: card.id)?.attachments else { return }
        guard attachments.count == 1, let attachment = attachments.first else {
            show(attachments.isEmpty ? "This card has no links." : "Choose a link on the pinned card.")
            return
        }
        open(card: card, attachment: attachment)
    }

    func open(card: PinCard, attachment: PinAttachment) {
        guard let destination = board.card(id: card.id)?.attachments.first(where: { $0.id == attachment.id }) else { return }
        board.touch(id: card.id)
        savePins()
        if let session = Jumper.currentSession(for: destination.link, in: store) {
            open(sessionId: session.id)
            return
        }
        Jumper.open(link: destination.link, in: store, show: { [weak self] in self?.show($0) })
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
        guard let card = board.card(id: cardId), let index = board.index(of: cardId) else { return }
        board.archive(id: cardId)
        savePins()
        show("Removed “\(TextUtils.truncate(card.title, limit: 28))”") { [weak self] in
            self?.board.unarchive(id: cardId, at: index)
            self?.savePins()
        }
    }

    /// Copies a summary of the card and opens a fresh chat where possible, so
    /// one crowded conversation can be split into clean ones.
    func continueInNewChat(card: PinCard) {
        let handoff = PinBoard.handoff(for: card)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(handoff, forType: .string)
        board.touch(id: card.id)
        savePins()
        if card.attachments.count == 1, case .url(let string) = card.link, let host = URL(string: string)?.host {
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
            if let card = pin(sessionId: session.id) { show("Pinned to \(card.group).") }
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
