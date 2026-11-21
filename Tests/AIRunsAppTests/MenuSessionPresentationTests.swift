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
