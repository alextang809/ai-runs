import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

@MainActor
final class HoldPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func waitingStore(_ ids: [String]) -> SessionStore {
        var store = SessionStore()
        for (index, id) in ids.enumerated() {
            let at = now.addingTimeInterval(Double(index))
            store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: id, at: at,
                                   prompt: "Prepare sample \(index)", transcriptPath: "/tmp/sample-\(id).jsonl"))
            store.apply(AgentEvent(tool: .codex, kind: .turnEnd, sessionId: id, at: at.addingTimeInterval(1),
                                   lastMessage: "Which layout should I use?"))
        }
        return store
    }

    private func key(_ id: String) -> String { Session.key(tool: .codex, sessionId: id) }

    func testHeldSessionsLeaveEveryListAndComeBackToNeedsYou() {
        var store = waitingStore(["one", "two", "three"])
        store.hold(id: key("one"), until: now.addingTimeInterval(7200), at: now)
        store.hold(id: key("two"), until: now.addingTimeInterval(3600), waitingOn: "Li", at: now)
        store.setPinned(id: key("two"), true)

        var menu = MenuSessionPresentation(sessions: store.ordered())
        XCTAssertEqual(menu.held.map(\.id), [key("two"), key("one")], "Soonest back first")
        XCTAssertEqual(menu.needs.map(\.id), [key("three")])
        XCTAssertTrue(menu.pinned.isEmpty, "A pinned session on hold sits on the line only")
        XCTAssertEqual(store.needsUserCount, 1)

        store.reconcileHolds(now: now.addingTimeInterval(3601))
        menu = MenuSessionPresentation(sessions: store.ordered())
        XCTAssertEqual(menu.held.map(\.id), [key("one")])
        XCTAssertEqual(Set(menu.needs.map(\.id)), [key("two"), key("three")])
        XCTAssertEqual(store.needsUserCount, 2)
        XCTAssertEqual(store.sessions[key("two")]?.hold?.returnText, "Check back with Li")

        store.acknowledgeReturn(id: key("two"))
        XCTAssertTrue(store.sessions[key("two")]?.isPinned == true, "Pinning a held session keeps its pin")
    }

    func testLegacyIgnoredRowsStayInTheirSection() {
        var store = waitingStore(["old"])
        store.setIgnored(id: key("old"), true)
        let menu = MenuSessionPresentation(sessions: store.ordered())
        XCTAssertEqual(menu.ignored.map(\.id), [key("old")])
        XCTAssertTrue(menu.held.isEmpty)
    }

    func testDragAcceptsTargetsByRule() throws {
        var store = waitingStore(["one"])
        let drag = HoldDragState()
        let row = try XCTUnwrap(store.sessions[key("one")])
        XCTAssertTrue(drag.accepts(.segment(0), row))
        XCTAssertTrue(drag.accepts(.waiting, row))
        XCTAssertTrue(drag.accepts(.pin, row))
        XCTAssertFalse(drag.accepts(.bringBack, row))

        store.hold(id: key("one"), until: now.addingTimeInterval(3600), at: now)
        let held = try XCTUnwrap(store.sessions[key("one")])
        XCTAssertTrue(drag.accepts(.bringBack, held))
        XCTAssertFalse(drag.accepts(.pin, held))

        store.apply(AgentEvent(tool: .codex, kind: .needsApproval, sessionId: "one", at: now.addingTimeInterval(5)))
        let approval = try XCTUnwrap(store.sessions[key("one")])
        XCTAssertFalse(drag.accepts(.segment(1), approval))
        XCTAssertFalse(drag.accepts(.waiting, approval))
    }

    func testDragLandsOnTheTargetUnderThePointerAndEscapeCancels() throws {
        let store = waitingStore(["one"])
        let row = try XCTUnwrap(store.sessions[key("one")])
        let drag = HoldDragState()
        var active: [Bool] = []
        drag.onActiveChange = { active.append($0) }
        drag.targets = [.segment(1): CGRect(x: 0, y: 100, width: 40, height: 42),
                        .waiting: CGRect(x: 60, y: 100, width: 44, height: 42)]

        drag.changed(row, at: CGPoint(x: 10, y: 10))
        XCTAssertTrue(drag.isActive)
        XCTAssertNil(drag.hovered)
        XCTAssertTrue(drag.consumesClick())
        drag.changed(row, at: CGPoint(x: 39, y: 141))
        XCTAssertEqual(drag.hovered, .segment(1))
        let landed = try XCTUnwrap(drag.ended())
        XCTAssertEqual(landed.target, .segment(1))
        XCTAssertFalse(drag.isActive)
        XCTAssertTrue(drag.consumesClick(), "The click that ends a drag doesn't open the row")

        drag.changed(row, at: CGPoint(x: 70, y: 110))
        XCTAssertEqual(drag.hovered, .waiting)
        XCTAssertTrue(drag.cancel())
        drag.changed(row, at: CGPoint(x: 71, y: 111))
        XCTAssertFalse(drag.isActive, "After Escape the same gesture changes nothing")
        XCTAssertNil(drag.ended())
        XCTAssertEqual(active, [true, false, true, false])
    }

    func testNoTargetMeansNoChange() throws {
        let store = waitingStore(["one"])
        let row = try XCTUnwrap(store.sessions[key("one")])
        let drag = HoldDragState()
        drag.targets = [.segment(0): CGRect(x: 0, y: 0, width: 40, height: 40)]
        drag.changed(row, at: CGPoint(x: 200, y: 200))
        XCTAssertNil(drag.ended())
    }
}
