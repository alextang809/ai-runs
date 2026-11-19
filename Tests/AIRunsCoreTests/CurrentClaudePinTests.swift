import Foundation
import XCTest
@testable import AIRunsCore

final class CurrentClaudePinTests: XCTestCase {
    private let firstSeen = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(project: String, thread: String? = nil, title: String = "Example conversation") -> Session {
        var row = Session(tool: .claudeCode, sessionId: "", title: title, cwd: nil,
                          state: .working, startedAt: firstSeen, turnStartedAt: firstSeen,
                          lastEventAt: firstSeen,
                          terminal: TerminalContext(bundleId: "com.anthropic.claudefordesktop"))
        if let thread {
            row.thread = ProjectThread(projectId: project, threadId: thread)
        } else {
            row.projectMainId = project
        }
        return row
    }

    func testProjectMainConversationsPinToDistinctAppLinks() {
        var board = PinBoard()
        let first = board.pin(session: session(project: "chan_example123"), now: firstSeen)
        let second = board.pin(session: session(project: "chan_example456"), now: firstSeen)

        XCTAssertEqual(board.cards.count, 2, "main conversations must not share an empty CLI session identity")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.link, .url("claude://code/project/chan_example123"))
        XCTAssertEqual(second.link, .url("claude://code/project/chan_example456"))
        XCTAssertEqual(first.link?.label, "Claude")
    }

    func testProjectMainAndChildThreadHaveSeparatePins() {
        var board = PinBoard()
        let main = board.pin(session: session(project: "chan_example123"), now: firstSeen)
        let thread = board.pin(session: session(project: "chan_example123", thread: "cmsg_example123"), now: firstSeen)

        XCTAssertEqual(board.cards.count, 2)
        XCTAssertNotEqual(main.id, thread.id)
        XCTAssertEqual(thread.link, .url("claude://code/project/chan_example123?thread=cmsg_example123"))
    }

    func testPinningMainAgainRefreshesItsExistingCard() {
        var board = PinBoard()
        let row = session(project: "chan_example123")
        let first = board.pin(session: row, now: firstSeen)
        let later = firstSeen.addingTimeInterval(90)
        let updated = board.pin(session: row, now: later)

        XCTAssertEqual(board.cards.count, 1)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.touchedAt, later)
        XCTAssertEqual(updated.link, .url("claude://code/project/chan_example123"))
    }
}
