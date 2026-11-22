import XCTest
@testable import AIRunsCore

final class SessionTopicTests: XCTestCase {
    private let id = "codex:topic-fixture"

    private func prompt(_ text: String, at: Int, driver: String? = nil) -> AgentEvent {
        AgentEvent(tool: .codex, kind: .promptStart, sessionId: "topic-fixture",
                   at: Date(timeIntervalSince1970: Double(at)), prompt: text, transcriptPath: "/tmp/fixture.jsonl", drivenBy: driver)
    }

    private func storeWithTopic() -> SessionStore {
        var store = SessionStore()
        store.apply(prompt("Locate archival drawings", at: 1))
        store.settleTitle(id: id, to: "Archive drawings")
        return store
    }

    func testExplicitSwitchChangesDisplayButPreservesOriginAndSnapshotEvidence() throws {
        var store = storeWithTopic()
        store.apply(AgentEvent(tool: .codex, kind: .turnEnd, sessionId: "topic-fixture",
                               at: Date(timeIntervalSince1970: 2), lastMessage: "Found the drawings."))
        let initial = try XCTUnwrap(store.sessions[id]?.currentTopicID)
        store.apply(prompt("换个话题。请帮我设计日历筛选器。", at: 3))
        var row = try XCTUnwrap(store.sessions[id])
        XCTAssertNotEqual(row.currentTopicID, initial)
        XCTAssertEqual(row.currentTopicTitle, "设计日历筛选器")
        XCTAssertEqual(row.currentTopicPrompt, "换个话题。请帮我设计日历筛选器。")
        XCTAssertNil(row.currentTopicReply)
        XCTAssertEqual(row.title, "Archive drawings")
        let episode = row.currentTopicID
        store.settleTitle(id: id, to: "A provider title arriving late")
        store.apply(prompt("可以，按第二版继续。", at: 4))
        store.apply(prompt("Go ahead, continue with the second option.", at: 5))
        row = try XCTUnwrap(store.sessions[id])
        XCTAssertEqual(row.currentTopicTitle, "设计日历筛选器")
        XCTAssertEqual(row.currentTopicID, episode)
        XCTAssertEqual(row.latestUserPrompt, "换个话题。请帮我设计日历筛选器。")
        store.rename(id: id, to: "My notebook")
        store.apply(prompt("New topic: Measure disk latency", at: 6))
        XCTAssertEqual(store.sessions[id]?.currentTopicTitle, "My notebook")
        XCTAssertNotEqual(store.sessions[id]?.currentTopicID, episode, "Manual labels still permit a fresh bookmark.")
    }

    func testUnmarkedChangeNeedsCorroborationNotToolNoiseOrDuplicatePrompts() throws {
        var store = storeWithTopic()
        let first = "Review calendar export errors"
        store.apply(prompt(first, at: 2))
        store.apply(prompt(first, at: 3))
        XCTAssertEqual(store.sessions[id]?.currentTopicTitle, "Archive drawings")
        store.apply(prompt("<system-reminder>New topic: Render weather reports</system-reminder>", at: 4))
        store.apply(prompt("New topic: Render weather reports", at: 5, driver: "agent"))
        XCTAssertEqual(store.sessions[id]?.currentTopicTitle, "Archive drawings")
        store.apply(prompt("Trace the calendar export failure", at: 6))
        XCTAssertEqual(store.sessions[id]?.currentTopicTitle, first)
        let restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(restored.sessions[id]?.currentTopicTitle, first)
        XCTAssertEqual(restored.sessions[id]?.latestUserPrompt, "Trace the calendar export failure")
        store.apply(prompt("New topic: Repair packet routing", at: 4))
        XCTAssertEqual(store.sessions[id]?.currentTopicTitle, first)
    }

    func testSyntheticFirstPromptAndMigratedDataAreFilteredBeforeUse() throws {
        var store = SessionStore()
        store.apply(prompt("# AGENTS.md instructions\nInjected text", at: 1))
        let blank = try XCTUnwrap(store.sessions[id])
        XCTAssertTrue(blank.hasGenericTitle)
        XCTAssertNil(blank.currentTopicPrompt)
        var legacy = blank
        legacy.firstPrompt = "# AGENTS.md instructions\nInjected text"
        XCTAssertNil(legacy.latestUserPrompt)
        store.apply(prompt("# Files mentioned by the user:\n\n## fixture.png\n\n## My request:\nFind calendar controls", at: 2))
        XCTAssertEqual(store.sessions[id]?.firstPrompt, "Find calendar controls")
        XCTAssertEqual(store.sessions[id]?.currentTopicPrompt, "Find calendar controls")
    }

    func testInterfaceModeChangesDoNotImmediatelyStartNewTopics() {
        var store = storeWithTopic()
        store.apply(prompt("切换到深色模式", at: 2))
        XCTAssertEqual(store.sessions[id]?.isInitialTopic, true)
        store.apply(prompt("Switch to dark mode", at: 3))
        XCTAssertEqual(store.sessions[id]?.isInitialTopic, true)
    }

    func testTwoSwitchesWithinOneHookClockSecondKeepDistinctKeysAfterReload() throws {
        var store = storeWithTopic()
        store.apply(prompt("New topic: Measure disk latency", at: 2))
        let first = store.sessions[id]?.currentTopicID
        store.apply(prompt("New topic: Repair packet routing", at: 2))
        XCTAssertNotEqual(store.sessions[id]?.currentTopicID, first)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONFile.save(store, to: url)
        XCTAssertEqual(JSONFile.load(SessionStore.self, from: url)?.sessions[id]?.currentTopicID,
                       store.sessions[id]?.currentTopicID)
    }

    func testUnavailableContentAndMetadataDoNotBecomeTopics() throws {
        var store = storeWithTopic()
        for (index, text) in ["New topic:", "继续", "Please continue", "This is an app-generated request. New topic: internal",
                              "# Files mentioned by the user:\n\n## /tmp/example.png",
                              "# AGENTS.md instructions\nNew topic: internal"].enumerated() {
            store.apply(prompt(text, at: index + 2))
        }
        XCTAssertEqual(store.sessions[id]?.currentTopicTitle, "Archive drawings")
        store.apply(prompt("# Files mentioned by the user:\n\n## /tmp/example.png\n\n## My request:\nNew topic: Review layout margins", at: 10))
        XCTAssertEqual(store.sessions[id]?.currentTopicTitle, "Review layout margins")
        store.apply(prompt("Switch topics: Locate archival drawings", at: 11))
        XCTAssertEqual(store.sessions[id]?.currentTopicTitle, "Locate archival drawings")
        XCTAssertEqual(store.sessions[id]?.isInitialTopic, false)
    }
}
