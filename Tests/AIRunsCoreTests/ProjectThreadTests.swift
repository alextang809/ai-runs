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
