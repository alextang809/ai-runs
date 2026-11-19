import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

final class CompactRunDetailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ kind: EventKind = .toolActivity,
                         detail: String? = nil, progress: RunProgress? = nil) throws -> Session {
        var store = SessionStore()
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "sample", at: now,
                               prompt: "Prepare a report", transcriptPath: "/tmp/sample-session.jsonl"))
        store.apply(AgentEvent(tool: .codex, kind: kind, sessionId: "sample", at: now,
                               approvalDetail: detail, activity: "mcp__sample__run", progress: progress))
        return try XCTUnwrap(store.sessions["codex:sample"])
    }

    func testOrdinaryActivityHasNoExtraLine() throws {
        XCTAssertNil(CompactRunDetail.resolve(try session(), now: now))
        XCTAssertNil(CompactRunDetail.resolve(try session(.turnEnd), now: now))
    }

    func testApprovalKeepsActualRequestedAction() throws {
        let row = try session(.needsApproval, detail: "  swift test  ")
        XCTAssertEqual(CompactRunDetail.resolve(row, now: now), .approval("swift test"))
        XCTAssertNil(CompactRunDetail.resolve(try session(.needsApproval, detail: " \n"), now: now))
    }

    func testApprovalDoesNotDisplayBareConnectorIdentifier() throws {
        XCTAssertNil(CompactRunDetail.resolve(
            try session(.needsApproval, detail: "mcp__sample__run"), now: now))
        XCTAssertEqual(CompactRunDetail.resolve(
            try session(.needsApproval, detail: "Edit /tmp/sample.txt"), now: now),
            .approval("Edit /tmp/sample.txt"))
    }

    func testQuestionUsesObservedQuestionRatherThanLastReply() throws {
        var row = try session(.turnEnd)
        row.outcome = .needsInput
        row.approvalDetail = "Which format should I use?"
        row.lastMessage = "A longer reply with unrelated detail"
        XCTAssertEqual(CompactRunDetail.resolve(row, now: now), .question("Which format should I use?"))
        row.approvalDetail = nil
        XCTAssertNil(CompactRunDetail.resolve(row, now: now))
        row.approvalDetail = "Question already set aside"
        row.ignored = true
        XCTAssertNil(CompactRunDetail.resolve(row, now: now))
    }

    func testPlanIsShownOnlyWhileCurrentAndActivelyWorking() throws {
        let plan = RunProgress(done: 2, total: 5, current: "Review output")
        let active = try session(progress: plan)
        XCTAssertEqual(CompactRunDetail.resolve(active, now: now), .progress(plan))
        XCTAssertNil(CompactRunDetail.resolve(active, now: now.addingTimeInterval(Session.quietThreshold + 1)))
        var background = active
        background.backgroundTasks = 1
        XCTAssertNil(CompactRunDetail.resolve(background, now: now))
        var scheduled = active
        scheduled.scheduled = 1
        XCTAssertNil(CompactRunDetail.resolve(scheduled, now: now))
        var native = active
        native.native = NativeSighting(state: .working, seenAt: now)
        XCTAssertNil(CompactRunDetail.resolve(native, now: now))
        var unknown = active
        unknown.state = .unknown
        XCTAssertNil(CompactRunDetail.resolve(unknown, now: now))
    }

    func testFinishedEmptyAndInvalidPlansDoNotClaimActiveProgress() throws {
        for plan in [RunProgress(done: 0, total: 0, current: nil),
                     RunProgress(done: 3, total: 3, current: nil),
                     RunProgress(done: -1, total: 3, current: nil),
                     RunProgress(done: 4, total: 3, current: nil)] {
            XCTAssertNil(CompactRunDetail.resolve(try session(progress: plan), now: now))
        }
    }
}
