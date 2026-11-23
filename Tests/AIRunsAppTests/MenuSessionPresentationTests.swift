import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

final class MenuSessionPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String = "sample") throws -> Session {
        var store = SessionStore()
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: id, at: now,
                               prompt: "Prepare a sample report", transcriptPath: "/tmp/sample-rollout.jsonl"))
        return try XCTUnwrap(store.sessions[Session.key(tool: .codex, sessionId: id)])
    }

    func testObservedWorkUsesDurationLabelsEvenForShortTurns() {
        XCTAssertEqual(RunText.workDuration(0.5), "<1s")
        XCTAssertEqual(RunText.workDuration(12.9), "12s")
        XCTAssertEqual(RunText.workDuration(60), "1m")
        XCTAssertEqual(RunText.workDuration(3_901), "1h 05m")
    }

    func testPinnedSessionMovesBetweenAttentionAndPinnedExactlyOnce() throws {
        var store = SessionStore()
        let id = "claude-code:watched"
        func event(_ kind: EventKind, at seconds: Int, reply: String? = nil) -> AgentEvent {
            AgentEvent(tool: .claudeCode, kind: kind, sessionId: "watched", at: now.addingTimeInterval(Double(seconds)),
                       lastMessage: reply)
        }
        func verify(needs: Bool) {
            let view = MenuSessionPresentation(sessions: store.ordered())
            let all = view.needs + view.pinned + view.working + view.unknown + view.recent
            XCTAssertEqual(all.map(\.id), [id])
            XCTAssertEqual(view.hasActiveSessions, true)
            XCTAssertEqual(view.needs.map(\.id), needs ? [id] : [])
            XCTAssertEqual(view.pinned.map(\.id), needs ? [] : [id])
            XCTAssertEqual(store.needsUserCount, needs ? 1 : 0)
        }
        store.apply(event(.promptStart, at: 0))
        store.setPinned(id: id, true)
        verify(needs: false)
        store.apply(event(.needsApproval, at: 1))
        verify(needs: true)
        store.apply(event(.toolActivity, at: 2))
        verify(needs: false)
        store.apply(event(.question, at: 3))
        verify(needs: true)
        store.setIgnored(id: id, true)
        verify(needs: false)
        store.apply(event(.promptStart, at: 4))
        store.apply(event(.turnEnd, at: 5, reply: "Here is the diagram."))
        verify(needs: false)
        // Providers can ask for approval directly after a reply, without a new prompt event.
        store.apply(event(.needsApproval, at: 6))
        verify(needs: true)
        store.apply(event(.turnEnd, at: 7, reply: "Here is the diagram."))
        store.setOutcome(id: id, .done, source: .message, forMessage: "Here is the diagram.")
        verify(needs: false)
    }

    func testNoSessionsUsesHomeWithoutInventingActivity() {
        let menu = MenuSessionPresentation(sessions: [])
        XCTAssertFalse(menu.hasActiveSessions)
        XCTAssertTrue(menu.unknown.isEmpty)
        XCTAssertTrue(menu.recent.isEmpty)
    }

    func testCompletedAndIgnoredSessionsStayAvailableWithoutActiveDashboard() throws {
        var done = try session("completed")
        done.state = .yourTurn
        done.outcome = .done
        var ignored = try session("ignored")
        ignored.state = .yourTurn
        ignored.outcome = .needsInput
        ignored.ignored = true
        let menu = MenuSessionPresentation(sessions: [done, ignored])
        XCTAssertFalse(menu.hasActiveSessions)
        XCTAssertEqual(menu.recent.map(\.id), [done.id, ignored.id])
        XCTAssertTrue(menu.needs.isEmpty)
    }

    func testUnknownSessionsRemainVisibleWithoutBeingCountedAsActive() throws {
        var unknown = try session()
        unknown.state = .unknown
        let menu = MenuSessionPresentation(sessions: [unknown])
        XCTAssertFalse(menu.hasActiveSessions)
        XCTAssertEqual(menu.unknown.map(\.id), [unknown.id])
        XCTAssertTrue(menu.recent.isEmpty)
    }

    func testWorkingApprovalAndUnansweredReplyKeepActiveSessionOverview() throws {
        let working = try session("working")
        var approval = try session("approval")
        approval.state = .needsApproval
        var reply = try session("reply")
        reply.state = .yourTurn
        for row in [working, approval, reply] {
            XCTAssertTrue(MenuSessionPresentation(sessions: [row]).hasActiveSessions)
        }
        let menu = MenuSessionPresentation(sessions: [working, approval, reply])
        XCTAssertEqual(menu.working.map(\.id), [working.id])
        XCTAssertEqual(menu.needs.map(\.id), [approval.id, reply.id])
    }
}
