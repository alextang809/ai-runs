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

    init() {
        try? paths.ensureRoot()
        let cursor = JSONFile.load(Cursor.self, from: paths.cursor)
        reader = EventLogReader(url: paths.events, offset: cursor?.offset ?? 0)
        store = JSONFile.load(SessionStore.self, from: paths.sessions) ?? SessionStore()
        board = JSONFile.load(PinBoard.self, from: paths.pins) ?? PinBoard()
        installHelper()
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
        nameUntitledSessions()
    }

    private var titleLookups: [String: Date] = [:]

    /// Sessions that started before the hooks were installed have no first
    /// prompt; read it from the transcript instead (at most once a minute each).
    private func nameUntitledSessions() {
        var updated = store
        for session in store.sessions.values where session.hasGenericTitle {
            guard let path = session.transcriptPath else { continue }
            if let last = titleLookups[session.id], Date().timeIntervalSince(last) < 60 { continue }
            titleLookups[session.id] = Date()
            if let prompt = TranscriptReader.firstUserPrompt(at: URL(fileURLWithPath: path)) {
                updated.rename(id: session.id, to: TextUtils.title(fromPrompt: prompt))
            }
        }
        if updated != store {
            store = updated
            saveSessions()
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

    func hookStatus(_ tool: AgentTool) -> HookInstaller.Status { installer.status(for: tool) }

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
        guard let app = frontAppAtOpen ?? NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            show("Click into an AI window first, then pin it.")
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
