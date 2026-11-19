import Foundation
import XCTest
@testable import AIRunsCore

/// Synthetic values with the group and nested-heading structure observed on a Mac.
final class ClaudeThreadsLiveShapeTests: XCTestCase {
    private let firstLook = Date(timeIntervalSince1970: 1_800_000_000)

    private func thread(_ number: Int) -> ProjectThread {
        ProjectThread(projectId: "chan_example123", threadId: "cmsg_root000\(number)")
    }

    private func key(_ number: Int) -> String {
        Session.key(tool: .claudeCode, thread: thread(number))
    }

    private func link(_ number: Int, title: String) -> AXNode {
        AXNode(role: "AXLink", url: "https://claude.ai/epitaxy/project/chan_example123?thread=cmsg_root000\(number)",
               children: [AXNode(role: "AXStaticText", value: title)])
    }

    private func section(_ heading: String, links: [AXNode]) -> AXNode {
        AXNode(role: "AXGroup", children: [
            AXNode(role: "AXHeading", title: heading, children: [
                AXNode(role: "AXButton", title: heading),
            ]),
            AXNode(role: "AXGroup", children: links.map {
                AXNode(role: "AXGroup", children: [$0])
            }),
        ])
    }

    private func window(_ sections: [AXNode]) -> AXNode {
        AXNode(role: "AXWindow", children: [
            AXNode(role: "AXWebArea", children: [
                // Activity in the main conversation does not identify a project thread.
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXHeading", title: "Example conversation"),
                    AXNode(role: "AXStaticText", value: "Working"),
                ]),
                AXNode(role: "AXGroup", children: sections),
            ]),
        ])
    }

    private var listedThreads: AXNode {
        window([
            section("Ready for review 1", links: [link(1, title: "Example review")]),
            section("Idle 2", links: [link(2, title: "Example second"), link(3, title: "Example third")]),
        ])
    }

    func testNestedHeadingAndGroupRowsCreateOnlyTheActiveThread() throws {
        let sightings = ClaudeThreadsView.sightings(in: listedThreads)
        XCTAssertEqual(sightings.map(\.thread), [thread(1), thread(2), thread(3)])
        XCTAssertEqual(sightings.map(\.title), ["Example review", "Example second", "Example third"])
        XCTAssertEqual(sightings.map(\.state), [.readyForReview, .idle, .idle])

        var store = SessionStore()
        store.observe(sightings, at: firstLook)
        XCTAssertEqual(Set(store.sessions.keys), [key(1)])
        let review = try XCTUnwrap(store.sessions[key(1)])
        XCTAssertEqual(review.native, NativeSighting(state: .readyForReview, seenAt: firstLook))
        XCTAssertEqual(review.title, "Example review")
        XCTAssertEqual(review.outcome, .replied)
        XCTAssertTrue(review.needsUser)
        XCTAssertEqual(store.workingCount, 0, "the main conversation's Working text is not a listed thread")
    }

    func testPreviouslyIdleThreadGetsARowWhenItsSectionBecomesWorking() throws {
        var store = SessionStore()
        store.observe(ClaudeThreadsView.sightings(in: listedThreads), at: firstLook)
        let originalReview = try XCTUnwrap(store.sessions[key(1)])
        let nextLook = firstLook.addingTimeInterval(30)
        let changedList = window([
            section("Ready for review 1", links: [link(1, title: "Example review")]),
            section("Working 1", links: [link(2, title: "Example second")]),
            section("Idle 1", links: [link(3, title: "Example third")]),
        ])

        store.observe(ClaudeThreadsView.sightings(in: changedList), at: nextLook)

        XCTAssertEqual(Set(store.sessions.keys), [key(1), key(2)])
        let working = try XCTUnwrap(store.sessions[key(2)])
        XCTAssertEqual(working.native, NativeSighting(state: .working, seenAt: nextLook))
        XCTAssertEqual(working.state, .working)
        XCTAssertEqual(working.title, "Example second")
        XCTAssertEqual(store.workingCount, 1)
        XCTAssertNil(store.sessions[key(3)], "a thread never observed active stays out")
        let review = try XCTUnwrap(store.sessions[key(1)])
        XCTAssertEqual(review.id, originalReview.id)
        XCTAssertEqual(review.title, originalReview.title)
        XCTAssertEqual(review.waitingSince, originalReview.waitingSince)
        XCTAssertEqual(review.native?.state, .readyForReview)
        XCTAssertEqual(review.native?.seenAt, nextLook)
    }

    func testAThreadMissingFromAPartialListKeepsItsLastObservation() throws {
        var store = SessionStore()
        store.observe(ClaudeThreadsView.sightings(in: listedThreads), at: firstLook)
        let originalReview = try XCTUnwrap(store.sessions[key(1)])
        let partialList = window([
            section("Idle 1", links: [link(3, title: "Example third")]),
        ])

        store.observe(ClaudeThreadsView.sightings(in: partialList), at: firstLook.addingTimeInterval(30))

        XCTAssertEqual(Set(store.sessions.keys), [key(1)])
        XCTAssertEqual(store.sessions[key(1)], originalReview,
                       "a partly drawn list says nothing new about the missing thread")
    }
}
