import Foundation
import XCTest
@testable import AIRunsCore

/// Made-up wrappers in the shape Claude projects send (see collab/rounds/02-codex.md).
private func wake(project: String = "chan_example123", thread: String = "cmsg_root123456",
                  message: String = "cmsg_message789", from: String = "human", trigger: String = "true",
                  _ text: String) -> String {
    """
    <wake reason="mention" current-time="2026-01-01T00:00:00Z">
      <project id="\(project)" type="project">
        <thread ts="\(thread)">
          <message trigger="\(trigger)" from="\(from)" trust="principal" author-id="user_example" id="\(message)" sent-at="2026-01-01T00:00:00Z">\(text)</message>
        </thread>
      </project>
      <system-note>Example note.</system-note>
    </wake>
    """
}

final class PromptWrapperTests: XCTestCase {
    func testWakeCarriesThreadAndRequest() throws {
        let parsed = try XCTUnwrap(PromptWrapper.wake(in: wake("Fix the export button")))
        XCTAssertEqual(parsed.thread, ProjectThread(projectId: "chan_example123", threadId: "cmsg_root123456"))
        XCTAssertEqual(parsed.request, "Fix the export button")
    }

    func testAttributeNamesAreExact() {
        XCTAssertEqual(PromptWrapper.attribute("id", in: #" author-id="a" id="b""#), "b")
        XCTAssertNil(PromptWrapper.attribute("id", in: #" author-id="a""#))
    }

    func testSystemMessagesAreNotRequests() throws {
        let parsed = try XCTUnwrap(PromptWrapper.wake(in: wake(from: "system", "You are a thread session.")))
        XCTAssertNotNil(parsed.thread)
        XCTAssertNil(parsed.request)
        XCTAssertNil(TextUtils.cleanPrompt(wake(from: "system", "You are a thread session.")))
    }

    func testSeveralWakesAndARelayInOnePrompt() throws {
        let prompt = wake(from: "system", "Spawned.")
            + "\n<relay from=\"coordinator\" session=\"session_example\" current-time=\"x\">Text<note>Notes.</note></relay>\n"
            + wake(message: "cmsg_message790", "Add a test")
        let parsed = try XCTUnwrap(PromptWrapper.wake(in: prompt))
        XCTAssertEqual(parsed.thread?.threadId, "cmsg_root123456")
        XCTAssertEqual(parsed.request, "Add a test")
        XCTAssertEqual(TextUtils.cleanPrompt(prompt), "Add a test")
    }

    func testDisagreeingOrUnknownAddressesStayUnlinked() throws {
        let two = wake("One") + wake(thread: "cmsg_otherroot99", "Two")
        XCTAssertNil(try XCTUnwrap(PromptWrapper.wake(in: two)).thread)
        XCTAssertNil(try XCTUnwrap(PromptWrapper.wake(in: wake(project: "proj_example", "Hi"))).thread)
        XCTAssertNil(try XCTUnwrap(PromptWrapper.wake(in: wake(thread: "session_example", "Hi"))).thread)
        // The request is still usable for naming.
        XCTAssertEqual(TextUtils.cleanPrompt(two), "Two")
    }

    func testUnclosedWakeIsLeftToPlainCleaning() {
        XCTAssertNil(PromptWrapper.wake(in: "<wake reason=\"mention\"> fix flaky test"))
        XCTAssertEqual(TextUtils.cleanPrompt("<wake reason=\"mention\"> fix flaky test"), "fix flaky test")
    }

    func testWakeQuotedInsideARequestIsIgnored() {
        let prompt = "Why does this break? " + wake("Inner")
        XCTAssertNil(PromptWrapper.wake(in: prompt))
        XCTAssertEqual(TextUtils.cleanPrompt(prompt), "Why does this break?")
    }

    func testCleanPromptKeepsTheRequestInsideAWake() {
        // The bug: the whole <wake> block was stripped, request and all.
        XCTAssertEqual(TextUtils.cleanPrompt(wake("Implement steps 1 and 2 &amp; keep &lt;message&gt; text, it&#39;s &#x2713;")),
                       "Implement steps 1 and 2 & keep <message> text, it's ✓")
        XCTAssertEqual(TextUtils.cleanPrompt("<system-reminder>ctx</system-reminder>\n" + wake("Rename  the\n tab")),
                       "Rename the tab")
        XCTAssertEqual(TextUtils.title(fromPrompt: wake("Fix Safari export")), "Fix Safari export")
        // Plain prompts are untouched, entities included.
        XCTAssertEqual(TextUtils.cleanPrompt("Use &amp; here"), "Use &amp; here")
    }

    func testDecodeEntitiesLeavesStrayAmpersands() {
        XCTAssertEqual(PromptWrapper.decodeEntities("a & b &unknown; &#34;q&#34;"), "a & b &unknown; \"q\"")
    }

    func testParserReadsTheThreadFromAClaudePrompt() throws {
        let payload: [String: Any] = ["session_id": "local-a", "hook_event_name": "UserPromptSubmit", "prompt": wake("Go")]
        let event = try XCTUnwrap(EventParser.parse(tool: .claudeCode, payload: payload, at: Date(), terminal: TerminalContext()))
        XCTAssertEqual(event.thread?.projectId, "chan_example123")
        let codex = try XCTUnwrap(EventParser.parse(tool: .codex, payload: payload, at: Date(), terminal: TerminalContext()))
        XCTAssertNil(codex.thread)
    }
}

final class ProjectThreadStoreTests: XCTestCase {
    private let thread = ProjectThread(projectId: "chan_example123", threadId: "cmsg_root123456")

    private func event(_ kind: EventKind, _ seconds: TimeInterval, session: String, prompt: String? = nil,
                       thread: ProjectThread? = nil, message: String? = nil) -> AgentEvent {
        var event = AgentEvent(tool: .claudeCode, kind: kind, sessionId: session, at: Date(timeIntervalSince1970: seconds),
                               prompt: prompt, lastMessage: message, transcriptPath: "/x/\(session).jsonl")
        event.thread = thread
        return event
    }

    private var rowKey: String { Session.key(tool: .claudeCode, thread: thread) }

    func testLocalSessionsOfOneThreadShareOneRow() throws {
        var store = SessionStore()
        store.apply(event(.promptStart, 0, session: "local-a", prompt: wake("Fix the export button"), thread: thread))
        store.apply(event(.turnEnd, 10, session: "local-a", message: "Fixed it."))
        store.apply(event(.promptStart, 100, session: "local-b", prompt: wake(message: "cmsg_message790", "Add a test"), thread: thread))

        XCTAssertEqual(store.sessions.count, 1)
        let row = try XCTUnwrap(store.sessions[rowKey])
        XCTAssertEqual(row.id, rowKey)
        XCTAssertEqual(row.thread, thread)
        XCTAssertEqual(row.sessionId, "local-b", "the newest local session speaks for the row")
        XCTAssertEqual(row.transcriptPath, "/x/local-b.jsonl")
        XCTAssertEqual(row.state, .working)
        XCTAssertEqual(row.firstPrompt, "Fix the export button")
        XCTAssertEqual(row.title, "Fix the export button")
        XCTAssertEqual(store.executors?.count, 2)

        // A late event from the earlier session doesn't move the row.
        store.apply(event(.turnEnd, 110, session: "local-a", message: "Late."))
        XCTAssertEqual(store.sessions[rowKey]?.state, .working)
        store.apply(event(.turnEnd, 120, session: "local-b", message: "Added it."))
        XCTAssertEqual(store.sessions[rowKey]?.state, .yourTurn)
        XCTAssertEqual(store.sessions[rowKey]?.lastMessage, "Added it.")
    }

    func testAnEarlierSessionAskingForApprovalTakesTheRow() {
        var store = SessionStore()
        store.apply(event(.promptStart, 0, session: "local-a", prompt: wake("One"), thread: thread))
        store.apply(event(.promptStart, 10, session: "local-b", prompt: wake("Two"), thread: thread))
        store.apply(event(.toolActivity, 15, session: "local-a"))
        XCTAssertEqual(store.sessions[rowKey]?.sessionId, "local-b")
        store.apply(event(.needsApproval, 20, session: "local-a"))
        XCTAssertEqual(store.sessions[rowKey]?.sessionId, "local-a")
        XCTAssertEqual(store.sessions[rowKey]?.state, .needsApproval)
    }

    func testThreadAppLink() {
        XCTAssertEqual(thread.appLink?.absoluteString, "claude://code/project/chan_example123?thread=cmsg_root123456")
        XCTAssertNil(ProjectThread(projectId: "chan_x y", threadId: "cmsg_root123456").appLink)
    }

    func testPlainSessionsKeepTheirOwnRows() {
        var store = SessionStore()
        store.apply(event(.promptStart, 0, session: "local-a", prompt: wake("Thread work"), thread: thread))
        store.apply(event(.promptStart, 5, session: "local-c", prompt: "Refactor the login flow"))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNil(store.sessions[Session.key(tool: .claudeCode, sessionId: "local-c")]?.thread)
        // A later plain prompt in a linked session stays with its thread.
        store.apply(event(.promptStart, 9, session: "local-a", prompt: "and the tests too"))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions[rowKey]?.turnStartedAt, Date(timeIntervalSince1970: 9))
    }

    func testASessionSeenBeforeItsWakeBecomesTheThreadRow() throws {
        var store = SessionStore()
        store.apply(event(.toolActivity, 0, session: "local-a"))
        store.rename(id: Session.key(tool: .claudeCode, sessionId: "local-a"), to: "Mine")
        store.apply(event(.promptStart, 5, session: "local-a", prompt: wake("Go on"), thread: thread))
        XCTAssertEqual(store.sessions.count, 1)
        let row = try XCTUnwrap(store.sessions[rowKey])
        XCTAssertEqual(row.title, "Mine")
        XCTAssertNotNil(store.lifeline(for: rowKey, now: Date(timeIntervalSince1970: 10)).first)
        XCTAssertTrue(store.lifeline(for: Session.key(tool: .claudeCode, sessionId: "local-a"),
                                     now: Date(timeIntervalSince1970: 10)).isEmpty)
    }

    func testRemovingAndEndingAThreadRow() {
        var store = SessionStore()
        store.apply(event(.promptStart, 0, session: "local-a", prompt: wake("Go"), thread: thread))
        store.apply(event(.turnEnd, 5, session: "local-a", message: "Done."))
        store.dismiss(id: rowKey, at: Date(timeIntervalSince1970: 6))
        store.apply(event(.toolActivity, 7, session: "local-a"))
        XCTAssertNil(store.sessions[rowKey], "removed rows stay out until the user writes again")
        store.apply(event(.promptStart, 8, session: "local-a", prompt: wake("Again"), thread: thread))
        XCTAssertNotNil(store.sessions[rowKey])

        store.apply(event(.sessionEnd, 9, session: "local-a"))
        XCTAssertNil(store.sessions[rowKey])
        XCTAssertNil(store.executors?["claude-code:local-a"])
    }

    func testStoreWithLinksSurvivesSaving() throws {
        var store = SessionStore()
        store.apply(event(.promptStart, 0, session: "local-a", prompt: wake("Go"), thread: thread))
        let data = try JSONEncoder().encode(store)
        let loaded = try JSONDecoder().decode(SessionStore.self, from: data)
        XCTAssertEqual(loaded, store)
        XCTAssertEqual(loaded.sessions[rowKey]?.thread, thread)
    }
}

// MARK: - Claude's Threads list (made-up trees in the shape Codex reported in round 3)

private func threadLink(_ root: String, _ name: String, extra: [AXNode] = [], project: String = "chan_example123") -> AXNode {
    AXNode(role: "AXLink", title: name, url: "https://claude.ai/epitaxy/project/\(project)?thread=\(root)",
           children: [AXNode(role: "AXStaticText", value: name)] + extra)
}

/// A status section: its heading (also repeated as a button), then the rows,
/// three steps above each link.
private func section(_ heading: String, _ links: [AXNode]) -> AXNode {
    AXNode(role: "AXGroup", children: [
        AXNode(role: "AXGroup", children: [AXNode(role: "AXHeading", title: heading), AXNode(role: "AXButton", title: heading)]),
        AXNode(role: "AXList", children: links.map { AXNode(role: "AXGroup", children: [$0]) }),
    ])
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: "AXWindow", children: [AXNode(role: "AXWebArea", children: children)])
}

final class ClaudeThreadsViewTests: XCTestCase {
    private func states(_ root: AXNode) -> [String: NativeThreadState?] {
        Dictionary(uniqueKeysWithValues: ClaudeThreadsView.sightings(in: root).map { ($0.thread.threadId, $0.state) })
    }

    func testThreadsTakeTheStateOfTheirSection() {
        let tree = window([
            AXNode(role: "AXHeading", title: "Threads"),
            section("Ready for review 1", [threadLink("cmsg_root0001", "One")]),
            section("Waiting on you 2", [threadLink("cmsg_root0002", "Two"), threadLink("cmsg_root0003", "Three")]),
            section("Idle (2)", [threadLink("cmsg_root0004", "Four"), threadLink("cmsg_root0005", "Five")]),
        ])
        let sightings = ClaudeThreadsView.sightings(in: tree)
        XCTAssertEqual(sightings.count, 5)
        XCTAssertEqual(sightings.first?.thread, ProjectThread(projectId: "chan_example123", threadId: "cmsg_root0001"))
        XCTAssertEqual(sightings.map(\.title), ["One", "Two", "Three", "Four", "Five"])
        XCTAssertEqual(sightings.map(\.state), [.readyForReview, .waitingOnYou, .waitingOnYou, .idle, .idle])
    }

    func testAThreadOutsideEverySectionHasNoState() {
        // One section and a link elsewhere (a sidebar): the section's heading isn't the stray link's.
        let tree = window([
            AXNode(role: "AXGroup", children: [threadLink("cmsg_stray001", "Stray")]),
            section("Idle 1", [threadLink("cmsg_root0004", "Four")]),
        ])
        let found = states(tree)
        XCTAssertEqual(found["cmsg_root0004"], .some(.idle))
        XCTAssertEqual(found["cmsg_stray001"], .some(nil))
    }

    func testWorkingTextBelongsToTheOnlyThreadNextToIt() {
        let tree = window([AXNode(role: "AXList", children: [
            AXNode(role: "AXGroup", children: [threadLink("cmsg_root0001", "One"), AXNode(role: "AXStaticText", value: "Working")]),
            AXNode(role: "AXGroup", children: [threadLink("cmsg_root0002", "Two")]),
        ])])
        let found = states(tree)
        XCTAssertEqual(found["cmsg_root0001"], .some(.working))
        XCTAssertEqual(found["cmsg_root0002"], .some(nil), "a Working text elsewhere says nothing about this thread")

        let inside = window([threadLink("cmsg_root0003", "Three", extra: [AXNode(role: "AXStaticText", value: "Working")])])
        XCTAssertEqual(ClaudeThreadsView.sightings(in: inside).first?.state, .working)
        XCTAssertEqual(ClaudeThreadsView.sightings(in: inside).first?.title, "Three")
    }

    func testAThreadListedUnderTwoStatesHasNone() {
        let tree = window([
            section("Idle 1", [threadLink("cmsg_root0001", "One")]),
            section("Waiting on you 1", [threadLink("cmsg_root0001", "One")]),
        ])
        XCTAssertEqual(ClaudeThreadsView.sightings(in: tree), [
            ThreadSighting(thread: ProjectThread(projectId: "chan_example123", threadId: "cmsg_root0001"), title: "One", state: nil),
        ])
    }

    func testOnlyProjectThreadLinksCount() {
        XCTAssertNotNil(ClaudeThreadsView.thread(fromLink: "https://claude.ai/code/project/chan_example123?thread=cmsg_root0001&msg=cmsg_other001"))
        XCTAssertNil(ClaudeThreadsView.thread(fromLink: "https://example.com/epitaxy/project/chan_example123?thread=cmsg_root0001"))
        XCTAssertNil(ClaudeThreadsView.thread(fromLink: "https://claude.ai/epitaxy/project/chan_example123"))
        XCTAssertNil(ClaudeThreadsView.thread(fromLink: "https://claude.ai/epitaxy/project/chan_example123?thread=session_example1"))
        XCTAssertNil(ClaudeThreadsView.thread(fromLink: "https://claude.ai/chat/abc"))
        let tree = window([section("Idle 1", [AXNode(role: "AXLink", title: "Docs", url: "https://claude.ai/chat/abc")])])
        XCTAssertTrue(ClaudeThreadsView.sightings(in: tree).isEmpty)
    }

    func testHeadings() {
        XCTAssertEqual(NativeThreadState.from(heading: "Waiting on you 2"), .waitingOnYou)
        XCTAssertEqual(NativeThreadState.from(heading: " idle (3) "), .idle)
        XCTAssertEqual(NativeThreadState.from(heading: "Ready for review"), .readyForReview)
        XCTAssertNil(NativeThreadState.from(heading: "Threads"))
        XCTAssertNil(NativeThreadState.from(heading: "Working on the release"))
        XCTAssertEqual(NativeThreadState.waitingOnYou.word, "WAITING ON YOU")
    }
}

final class NativeThreadStoreTests: XCTestCase {
    private func thread(_ n: Int) -> ProjectThread { ProjectThread(projectId: "chan_example123", threadId: "cmsg_root000\(n)") }
    private func key(_ n: Int) -> String { Session.key(tool: .claudeCode, thread: thread(n)) }
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }
    private func seen(_ n: Int, _ state: NativeThreadState?, title: String? = nil) -> ThreadSighting {
        ThreadSighting(thread: thread(n), title: title, state: state)
    }
    private func hook(_ kind: EventKind, _ seconds: TimeInterval, session: String = "local-a", prompt: String? = nil,
                      thread: ProjectThread? = nil, message: String? = nil) -> AgentEvent {
        var event = AgentEvent(tool: .claudeCode, kind: kind, sessionId: session, at: at(seconds), prompt: prompt,
                               lastMessage: message, transcriptPath: "/x/\(session).jsonl")
        event.thread = thread
        return event
    }

    func testCloudThreadsGetRowsWhenTheyAreActive() throws {
        var store = SessionStore()
        store.observe([seen(1, .waitingOnYou, title: "Privacy audit"), seen(2, .working), seen(3, .readyForReview),
                       seen(4, .idle), seen(5, nil)], at: at(0))
        XCTAssertEqual(Set(store.sessions.keys), [key(1), key(2), key(3)], "idle and unreadable threads never seen active stay out")

        let waiting = try XCTUnwrap(store.sessions[key(1)])
        XCTAssertEqual(waiting.title, "Privacy audit")
        XCTAssertEqual(waiting.sessionId, "")
        XCTAssertEqual(waiting.thread, thread(1))
        XCTAssertEqual(waiting.native, NativeSighting(state: .waitingOnYou, seenAt: at(0)))
        XCTAssertEqual(waiting.terminal.appName, "Claude")
        XCTAssertTrue(waiting.needsUser)
        XCTAssertEqual(waiting.alertKind(now: at(0)), .input)
        XCTAssertEqual(store.sessions[key(2)]?.state, .working)
        XCTAssertEqual(store.sessions[key(3)]?.alertKind(now: at(0)), .replied)
        XCTAssertEqual(store.needsUserCount, 2)
        XCTAssertEqual(store.workingCount, 1)

        // Seeing the same thing again is not a new moment.
        store.observe([seen(1, .waitingOnYou)], at: at(30))
        XCTAssertEqual(store.sessions[key(1)]?.waitingSince, at(0))
        XCTAssertEqual(store.sessions[key(1)]?.native?.seenAt, at(30))

        // A row that goes idle stays, as Claude's "Idle", and that is not news.
        store.observe([seen(2, .idle)], at: at(40))
        XCTAssertEqual(store.sessions[key(2)]?.native?.state, .idle)
        XCTAssertEqual(store.sessions[key(2)]?.isDone, true)
        XCTAssertNil(store.sessions[key(2)]?.alertKind(now: at(40)))
    }

    func testAnOldSightingStopsClaimingAState() {
        var store = SessionStore()
        store.observe([seen(1, .waitingOnYou), seen(2, .working)], at: at(0))
        store.expireSightings(now: at(9 * 60))
        XCTAssertNil(store.sessions[key(2)]?.native?.stale)
        store.expireSightings(now: at(11 * 60))
        XCTAssertEqual(store.sessions[key(2)]?.native?.stale, true)
        XCTAssertEqual(store.sessions[key(2)]?.state, .yourTurn)
        XCTAssertEqual(store.workingCount, 0, "an unseen thread isn't counted as working")
        XCTAssertNil(store.sessions[key(2)]?.alertKind(now: at(11 * 60)))
        // Waiting on you stays true until it is seen as something else.
        XCTAssertNil(store.sessions[key(1)]?.native?.stale)
        XCTAssertEqual(store.needsUserCount, 1)

        store.observe([seen(2, .working)], at: at(12 * 60))
        XCTAssertNil(store.sessions[key(2)]?.native?.stale)
        XCTAssertEqual(store.sessions[key(2)]?.state, .working)
    }

    func testHooksSpeakFirstThenClaudesList() {
        var store = SessionStore()
        store.apply(hook(.promptStart, 0, prompt: wake(thread: thread(1).threadId, "Fix the export button"), thread: thread(1)))
        XCTAssertEqual(store.sessions[key(1)]?.state, .working)

        // Right after a hook event the hooks know best; Claude's name is still taken.
        store.observe([seen(1, .idle, title: "Export button")], at: at(20))
        XCTAssertNil(store.sessions[key(1)]?.native)
        XCTAssertEqual(store.sessions[key(1)]?.state, .working)
        XCTAssertEqual(store.sessions[key(1)]?.title, "Export button")

        // Later, when the list agrees, there is nothing to change…
        store.observe([seen(1, .working)], at: at(300))
        XCTAssertNil(store.sessions[key(1)]?.native)
        // …and when it disagrees (the thread went on in the cloud), it takes over.
        store.observe([seen(1, .waitingOnYou)], at: at(310))
        XCTAssertEqual(store.sessions[key(1)]?.native?.state, .waitingOnYou)
        XCTAssertEqual(store.sessions[key(1)]?.needsUser, true)
        XCTAssertEqual(store.sessions[key(1)]?.waitingSince, at(310))
        XCTAssertEqual(store.sessions.count, 1)

        // A new hook event takes the row back.
        store.apply(hook(.toolActivity, 320))
        XCTAssertNil(store.sessions[key(1)]?.native)
        XCTAssertEqual(store.sessions[key(1)]?.state, .working)
    }

    func testALocalApprovalIsNotReplacedByWaitingOnYou() {
        var store = SessionStore()
        store.apply(hook(.promptStart, 0, prompt: wake(thread: thread(1).threadId, "Go"), thread: thread(1)))
        store.apply(hook(.needsApproval, 5))
        store.observe([seen(1, .waitingOnYou)], at: at(600))
        XCTAssertEqual(store.sessions[key(1)]?.state, .needsApproval)
        XCTAssertNil(store.sessions[key(1)]?.native)
    }

    func testAWakeAttachesALocalSessionToACloudRow() {
        var store = SessionStore()
        store.observe([seen(1, .working, title: "Privacy audit")], at: at(0))
        store.apply(hook(.promptStart, 5, prompt: wake(thread: thread(1).threadId, "Check the logs"), thread: thread(1)))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[key(1)]?.sessionId, "local-a")
        XCTAssertEqual(store.sessions[key(1)]?.title, "Privacy audit", "Claude's name stays")
        XCTAssertNil(store.sessions[key(1)]?.native)
    }

    func testRenamedRowsKeepTheUsersName() {
        var store = SessionStore()
        store.observe([seen(1, .working, title: "Privacy audit")], at: at(0))
        store.rename(id: key(1), to: "Mine")
        store.observe([seen(1, .working, title: "Privacy audit v2")], at: at(5))
        XCTAssertEqual(store.sessions[key(1)]?.title, "Mine")
    }

    func testRemovedRowsComeBackOnlyWhenTheyNewlyWantTheUser() {
        var store = SessionStore()
        store.observe([seen(1, .waitingOnYou), seen(2, .working)], at: at(0))
        store.dismiss(id: key(1), at: at(1))
        store.dismiss(id: key(2), at: at(1))

        store.observe([seen(1, .waitingOnYou), seen(2, .working)], at: at(10))
        XCTAssertTrue(store.sessions.isEmpty, "still waiting, still working: both stay removed")

        store.observe([seen(1, .idle), seen(2, .waitingOnYou)], at: at(20))
        XCTAssertEqual(Set(store.sessions.keys), [key(2)], "a removed thread that now wants the user returns")

        store.observe([seen(1, .waitingOnYou)], at: at(30))
        XCTAssertNotNil(store.sessions[key(1)], "it was seen idle in between, so this is a new wait")
    }

    func testPinningAThreadKeepsItsLink() {
        var store = SessionStore()
        store.observe([seen(1, .waitingOnYou, title: "Privacy audit")], at: at(0))
        var board = PinBoard()
        let card = board.pin(session: store.sessions[key(1)]!, now: at(1))
        XCTAssertEqual(card.link, .url("claude://code/project/chan_example123?thread=cmsg_root0001"))
        XCTAssertEqual(card.link?.label, "Claude")
        board.pin(session: store.sessions[key(1)]!, now: at(2))
        XCTAssertEqual(board.cards.count, 1)
    }
}
