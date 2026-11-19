import Foundation
import XCTest
@testable import AIRunsCore

final class CurrentClaudeStoreTests: XCTestCase {
    private let project = "chan_example123"
    private let root = "cmsg_example123"
    private let first = Date(timeIntervalSince1970: 1_800_000_000)

    private var thread: ProjectThread { ProjectThread(projectId: project, threadId: root) }
    private var childKey: String { Session.key(tool: .claudeCode, thread: thread) }
    private var mainKey: String { Session.key(tool: .claudeCode, projectMainId: project) }
    private func view(_ isMain: Bool = false, title: String? = nil) -> CurrentClaudeView {
        CurrentClaudeView(conversation: ClaudeConversation(projectId: project, threadId: isMain ? nil : root), title: title)
    }
    private func seen(_ state: NativeThreadState) -> ThreadSighting {
        ThreadSighting(thread: thread, title: "Example list title", state: state)
    }

    func testUnknownMainAndChildHaveDistinctRowsWithoutCountsAlertsOrActivity() throws {
        var store = SessionStore()
        store.observeCurrentViews([view(true), view()], at: first)
        XCTAssertEqual(Set(store.sessions.keys), [mainKey, childKey])
        for row in store.sessions.values {
            XCTAssertEqual(row.state, .unknown)
            XCTAssertFalse(row.needsUser)
            XCTAssertFalse(row.waitsOnUser)
            XCTAssertFalse(row.isDone)
            XCTAssertFalse(row.isIgnored)
            XCTAssertNil(row.alertKind(now: first))
            XCTAssertNil(SpanKind(row))
            XCTAssertEqual(row.nativeView, NativeViewSighting(seenAt: first))
            XCTAssertTrue(row.isProjectConversation)
        }
        XCTAssertEqual(store.needsUserCount, 0)
        XCTAssertEqual(store.workingCount, 0)
        XCTAssertEqual(store.doneCount, 0)
        XCTAssertTrue(store.history?.isEmpty ?? true)
        XCTAssertEqual(store.stats(now: first.addingTimeInterval(60)).sessionsToday, 0)
        XCTAssertEqual(store.sessions[mainKey]?.claudeAppLink?.absoluteString, "claude://code/project/chan_example123")
        XCTAssertEqual(store.sessions[childKey]?.claudeAppLink, thread.appLink)
    }

    func testCurrentViewMergesWithListRowWithoutRefreshingItsState() throws {
        var store = SessionStore()
        store.observe([seen(.readyForReview)], at: first)
        let original = try XCTUnwrap(store.sessions[childKey])
        let later = first.addingTimeInterval(90)
        store.observeCurrentViews([view(title: "Example page title")], at: later)
        let row = try XCTUnwrap(store.sessions[childKey])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(row.native, original.native)
        XCTAssertEqual(row.lastEventAt, original.lastEventAt)
        XCTAssertEqual(row.waitingSince, original.waitingSince)
        XCTAssertEqual(row.title, original.title)
        XCTAssertEqual(row.nativeView?.seenAt, later)
        XCTAssertEqual(row.state, .yourTurn)
    }

    func testListStateImmediatelyReplacesAnIdentityOnlyUnknownRow() throws {
        var store = SessionStore()
        store.observeCurrentViews([view()], at: first)
        store.observe([seen(.working)], at: first.addingTimeInterval(5))
        let row = try XCTUnwrap(store.sessions[childKey])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(row.state, .working)
        XCTAssertEqual(row.native?.state, .working)
        XCTAssertEqual(store.workingCount, 1)
    }

    func testHookLinkedThreadKeepsItsStateAndDoesNotGainADuplicateRow() throws {
        var store = SessionStore()
        var event = AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "local-example", at: first,
                               prompt: "Example task")
        event.thread = thread
        store.apply(event)
        let original = try XCTUnwrap(store.sessions[childKey])
        store.observeCurrentViews([view()], at: first.addingTimeInterval(30))
        let row = try XCTUnwrap(store.sessions[childKey])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(row.state, .working)
        XCTAssertEqual(row.lastHookAt, original.lastHookAt)
        XCTAssertEqual(row.lastEventAt, original.lastEventAt)
        XCTAssertNil(row.native)
        XCTAssertEqual(row.sessionId, "local-example")
    }

    func testLegacyHookGraceSurvivesAttachingCurrentViewEvidence() throws {
        var original = SessionStore()
        var event = AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "local-example", at: first,
                               prompt: "Example task")
        event.thread = thread
        original.apply(event)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var rows = try XCTUnwrap(document["sessions"] as? [String: [String: Any]])
        rows[childKey]?.removeValue(forKey: "lastHookAt")
        document["sessions"] = rows
        var store = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: document))

        store.observeCurrentViews([view()], at: first.addingTimeInterval(30))
        store.observe([seen(.idle)], at: first.addingTimeInterval(45))
        let fresh = try XCTUnwrap(store.sessions[childKey])
        XCTAssertEqual(fresh.state, .working, "opening a page must not disable the legacy hook grace period")
        XCTAssertNil(fresh.native)
        XCTAssertEqual(fresh.lastEventAt, first)

        store.observe([seen(.idle)], at: first.addingTimeInterval(121))
        XCTAssertEqual(store.sessions[childKey]?.native?.state, .idle)
        XCTAssertEqual(store.sessions[childKey]?.state, .yourTurn)
    }

    func testIdentitySightingsRespectRemovalAndCustomNames() throws {
        var store = SessionStore()
        store.observeCurrentViews([view(true, title: "Example project")], at: first)
        store.rename(id: mainKey, to: "My example name")
        store.observeCurrentViews([view(true, title: "Different example")], at: first.addingTimeInterval(5))
        XCTAssertEqual(store.sessions[mainKey]?.title, "My example name")
        store.dismiss(id: mainKey, at: first.addingTimeInterval(10))
        store.observeCurrentViews([view(true)], at: first.addingTimeInterval(15))
        XCTAssertNil(store.sessions[mainKey])
    }

    func testCompleteReadsRetirePreviousCurrentMarkerButPartialReadsDoNot() {
        var store = SessionStore()
        store.observeCurrentViews([view(true)], at: first)
        store.observeCurrentViews([view()], at: first.addingTimeInterval(5), complete: false)
        XCTAssertEqual(store.sessions[mainKey]?.nativeView?.isOpen, true)
        XCTAssertEqual(store.sessions[childKey]?.nativeView?.isOpen, true)
        store.observeCurrentViews([view()], at: first.addingTimeInterval(10))
        XCTAssertEqual(store.sessions[mainKey]?.nativeView, NativeViewSighting(seenAt: first, isOpen: false))
        XCTAssertEqual(store.sessions[childKey]?.nativeView?.isOpen, true)
        store.observeCurrentViews([], at: first.addingTimeInterval(15))
        XCTAssertEqual(store.sessions[childKey]?.nativeView?.isOpen, false)
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testCurrentIdentityDoesNotPreventKnownStateExpiringToUnknown() throws {
        var store = SessionStore()
        store.observe([seen(.working)], at: first)
        let later = first.addingTimeInterval(11 * 60)
        store.observeCurrentViews([view()], at: later)
        store.expireSightings(now: later)
        let row = try XCTUnwrap(store.sessions[childKey])
        XCTAssertEqual(row.native?.seenAt, first)
        XCTAssertEqual(row.native?.stale, true)
        XCTAssertEqual(row.state, .unknown)
        XCTAssertNil(row.outcome)
        XCTAssertFalse(row.isDone)
        XCTAssertEqual(store.workingCount, 0)
        XCTAssertEqual(store.doneCount, 0)
        XCTAssertNil(row.alertKind(now: later))
    }

    func testRecentIdentityKeepsRowWithoutRefreshingStateActivityTime() throws {
        var store = SessionStore()
        store.observeCurrentViews([view(true)], at: first)
        let later = first.addingTimeInterval(25 * 3600)
        store.observeCurrentViews([view(true)], at: later)
        store.pruneStale(now: later)
        let row = try XCTUnwrap(store.sessions[mainKey])
        XCTAssertEqual(row.lastEventAt, first)
        XCTAssertEqual(row.nativeView?.seenAt, later)
        store.pruneStale(now: later.addingTimeInterval(24 * 3600))
        XCTAssertNil(store.sessions[mainKey])
    }

    func testOldSessionJSONStillDecodesWithoutNewOptionalFields() throws {
        var store = SessionStore()
        store.apply(AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "local-example", at: first))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        var rows = try XCTUnwrap(document["sessions"] as? [String: [String: Any]])
        for key in Array(rows.keys) {
            rows[key]?.removeValue(forKey: "projectMainId")
            rows[key]?.removeValue(forKey: "nativeView")
        }
        document["sessions"] = rows
        let loaded = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: document))
        let row = try XCTUnwrap(loaded.sessions[Session.key(tool: .claudeCode, sessionId: "local-example")])
        XCTAssertNil(row.projectMainId)
        XCTAssertNil(row.nativeView)
        XCTAssertNil(row.claudeConversation)
        XCTAssertEqual(row.state, .working)
    }

    func testNewMainConversationRoundTripsAndInvalidIdentityIsSkipped() throws {
        var store = SessionStore()
        store.observeCurrentViews([view(true)], at: first)
        let loaded = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(loaded, store)
        store.observeCurrentViews([
            CurrentClaudeView(conversation: ClaudeConversation(projectId: "invalid")),
            CurrentClaudeView(conversation: ClaudeConversation(projectId: project, threadId: "session_invalid")),
        ], at: first)
        XCTAssertEqual(Set(store.sessions.keys), [mainKey])
    }

    func testUnknownRowsSortAfterWorkingAndBeforeDone() {
        var store = SessionStore()
        store.observe([seen(.working)], at: first)
        store.observe([seen(.idle)], at: first.addingTimeInterval(5))
        store.observeCurrentViews([view(true)], at: first.addingTimeInterval(10))
        store.apply(AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "local-example", at: first))
        XCTAssertEqual(store.ordered().map(\.id), [
            Session.key(tool: .claudeCode, sessionId: "local-example"), mainKey, childKey,
        ])
    }

    func testTidyRetiresPersistedCurrentMarkersAndMigratesLegacyStaleDone() throws {
        var store = SessionStore()
        store.observe([seen(.working)], at: first)
        let later = first.addingTimeInterval(11 * 60)
        store.observeCurrentViews([view()], at: later)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        var rows = try XCTUnwrap(document["sessions"] as? [String: [String: Any]])
        rows[childKey]?["state"] = "yourTurn"
        rows[childKey]?["outcome"] = "done"
        document["sessions"] = rows
        var loaded = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: document))
        loaded.tidy()
        let row = try XCTUnwrap(loaded.sessions[childKey])
        XCTAssertEqual(row.state, .unknown)
        XCTAssertNil(row.outcome)
        XCTAssertEqual(row.nativeView?.isOpen, false)
        XCTAssertEqual(row.nativeView?.seenAt, later)
        XCTAssertEqual(loaded.doneCount, 0)
    }
}
