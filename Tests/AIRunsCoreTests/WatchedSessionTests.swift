import XCTest
@testable import AIRunsCore

final class WatchedSessionTests: XCTestCase {
    private let id = "claude-code:fixture"
    private func event(_ kind: EventKind, _ seconds: Int, reply: String? = nil) -> AgentEvent {
        AgentEvent(tool: .claudeCode, kind: kind, sessionId: "fixture", at: Date(timeIntervalSince1970: Double(seconds)),
                   lastMessage: reply)
    }

    func testOnlyNewRepliesHaveAnUnreadMarkAndRepeatedDeliveryDoesNotReviveIt() throws {
        var store = SessionStore()
        store.apply(event(.turnEnd, 1, reply: "The first diagram is ready."))
        store.setPinned(id: id, true)
        XCTAssertFalse(try XCTUnwrap(store.sessions[id]).hasUnreadReply)
        store.apply(event(.promptStart, 2))
        store.apply(event(.turnEnd, 3, reply: "Here is another diagram."))
        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        XCTAssertTrue(try XCTUnwrap(restored.sessions[id]).hasUnreadReply)
        restored.markReplyRead(id: id)
        restored.apply(event(.turnEnd, 3, reply: "Here is another diagram."))
        XCTAssertFalse(try XCTUnwrap(restored.sessions[id]).hasUnreadReply)
        restored.apply(event(.turnEnd, 1, reply: "The first diagram is ready."))
        XCTAssertEqual(restored.sessions[id]?.lastMessage, "Here is another diagram.")
        restored.apply(event(.promptStart, 4))
        restored.apply(event(.turnEnd, 5, reply: "Here is another diagram."))
        XCTAssertTrue(try XCTUnwrap(restored.sessions[id]).hasUnreadReply)
        restored.setPinned(id: id, false)
        XCTAssertFalse(try XCTUnwrap(restored.sessions[id]).hasUnreadReply)
        XCTAssertFalse(try XCTUnwrap(restored.sessions[id]).isPinned)
    }

    func testWatchFollowsAClaudeDesktopThreadWhenTheHookExecutorMergesIntoIt() throws {
        var store = SessionStore()
        let thread = ProjectThread(projectId: "chan_example123", threadId: "cmsg_example123")
        store.observe([ThreadSighting(thread: thread, title: "Desktop sample", state: .working)],
                      at: Date(timeIntervalSince1970: 1))
        store.apply(event(.promptStart, 2))
        store.setPinned(id: id, true)
        var wake = event(.promptStart, 3)
        wake.thread = thread
        store.apply(wake)
        let row = try XCTUnwrap(store.sessions[Session.key(tool: .claudeCode, thread: thread)])
        XCTAssertTrue(row.isPinned)
        XCTAssertEqual(row.sessionId, "fixture")
        XCTAssertNil(store.sessions[id])
        store.observe([ThreadSighting(thread: thread, state: .readyForReview)], at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.needsUserCount, 1)
    }

    func testWatchingSurvivesPruningEndingAndReopeningTheSameConversation() throws {
        var store = SessionStore()
        store.apply(event(.promptStart, 1))
        store.setPinned(id: id, true)
        store.pruneStale(now: Date(timeIntervalSince1970: 100_000))
        XCTAssertTrue(try XCTUnwrap(store.sessions[id]).isPinned)
        XCTAssertEqual(store.sessions[id]?.state, .unknown)
        XCTAssertEqual(store.workingCount, 0)
        store.apply(event(.sessionEnd, 100_001))
        XCTAssertEqual(store.sessions[id]?.state, .unknown)
        store.apply(event(.promptStart, 100_002))
        XCTAssertEqual(store.sessions[id]?.state, .working)
        XCTAssertTrue(try XCTUnwrap(store.sessions[id]).isPinned)
        store.setPinned(id: id, false)
        store.apply(event(.sessionEnd, 100_003))
        XCTAssertNil(store.sessions[id])
    }
}
