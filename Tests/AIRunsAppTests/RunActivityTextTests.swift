import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

final class RunActivityTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func working(activity: String) throws -> Session {
        var store = SessionStore()
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "sample", at: now,
                               prompt: "Prepare a report", transcriptPath: "/tmp/sample-session.jsonl"))
        store.apply(AgentEvent(tool: .codex, kind: .toolActivity, sessionId: "sample", at: now,
                               activity: activity))
        return try XCTUnwrap(store.sessions["codex:sample"])
    }

    func testShowsReadableActivityWithoutLeakingRawConnectorNames() throws {
        for activity in ["Running tests", "Editing sample_file.swift", "Reviewing changes", "Using git", "整理参考资料"] {
            XCTAssertEqual(RunText.rowActivity(try working(activity: activity), now: now), activity)
        }
        for activity in ["collaborationfollowup_task", "mcp__sample__run", "functions.exec", "Using codex_app", " \n"] {
            XCTAssertEqual(RunText.rowActivity(try working(activity: activity), now: now), "Working")
        }
    }

    func testActualPlanTakesPriorityOverOrdinaryToolActivity() throws {
        var session = try working(activity: "mcp__sample__run")
        session.progress = RunProgress(done: 2, total: 5, current: "Review output")
        XCTAssertEqual(RunText.rowActivity(session, now: now), "2/5 · Review output")
        session.progress = RunProgress(done: 5, total: 5, current: nil)
        XCTAssertEqual(RunText.rowActivity(session, now: now), "Working")
        session.progress = RunProgress(done: 1, total: 3, current: "mcp__sample__run")
        XCTAssertEqual(RunText.rowActivity(session, now: now), "1/3")
    }

    func testStaleBackgroundAndUnknownDoNotClaimCurrentPlanActivity() throws {
        var session = try working(activity: "Running tests")
        session.progress = RunProgress(done: 2, total: 5, current: "Review output")
        XCTAssertEqual(RunText.rowActivity(session, now: now.addingTimeInterval(Session.quietThreshold + 1)),
                       "No events for a while — it may have stopped")
        session.backgroundTasks = 1
        XCTAssertEqual(RunText.rowActivity(session, now: now),
                       "Waiting on 1 background task · continues by itself")
        session.state = .unknown
        XCTAssertEqual(RunText.rowActivity(session, now: now), "State unavailable")
    }

    func testNativeAndScheduledEvidenceOutranksOldPlan() throws {
        var session = try working(activity: "Running tests")
        session.progress = RunProgress(done: 2, total: 5, current: "Review output")
        session.scheduled = 1
        XCTAssertEqual(RunText.rowActivity(session, now: now),
                       "Scheduled a wake-up · continues by itself")
        session.native = NativeSighting(state: .working, seenAt: now, stale: true)
        XCTAssertEqual(RunText.rowActivity(session, now: now),
                       "State unknown · show its Threads list in Claude to refresh")
    }
}
