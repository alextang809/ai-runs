import Foundation
import XCTest
@testable import AIRunsCore

final class CodexVoiceRecoveryTests: XCTestCase {
    private func thread(_ id: String, source: String = "voice_chat", archived: Bool = false) -> CodexThread {
        CodexThread(id: id, name: "Voice session", threadSource: source, archived: archived)
    }

    private func event(_ id: String, name: String = "PostToolUse", seconds: Double = 0,
                       tool: AgentTool = .codex) throws -> AgentEvent {
        let payload: [String: Any] = [
            "session_id": id, "hook_event_name": name, "prompt": "Check the layout",
            "transcript_path": "/tmp/example-rollout.jsonl", "cwd": "/tmp/example-project",
            "last_assistant_message": "Done. All checks passed.",
        ]
        let line = HookRecord.makeLine(tool: tool.rawValue,
            payload: try JSONSerialization.data(withJSONObject: payload), environment: [:], tty: nil,
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        return try XCTUnwrap(EventParser.parse(line: line))
    }

    func testVoiceChatsAreUserThreadsWhileHelpersStayInternal() {
        for source in ["user", "voice_chat", "VOICE_CHAT", "", nil] as [String?] {
            XCTAssertFalse(CodexThread(id: "v", name: nil, threadSource: source, archived: false).isInternal,
                           "Unexpected internal source: \(source ?? "nil")")
        }
        for source in ["subagent", "guardian_review", "unknown_helper"] {
            XCTAssertTrue(thread("helper", source: source).isInternal)
        }
    }

    func testRecoveryReplaysOnlyMisclassifiedVoiceEventsAndPersists() throws {
        var store = SessionStore()
        for id in ["voice", "helper", "archived", "removed", "missing", "typed"] {
            store.ignore(id: "codex:\(id)")
        }
        let removed = try event("removed")
        var prior = SessionStore()
        prior.apply(removed)
        store.restore(try XCTUnwrap(prior.sessions["codex:removed"]))
        store.dismiss(id: "codex:removed", at: removed.at)
        store.ignore(id: "claude-code:voice")
        store.apply(try event("existing"))
        let existing = store.sessions["codex:existing"]
        let metadata = [thread("voice"), thread("helper", source: "subagent"),
                        thread("archived", archived: true), thread("removed"), thread("typed", source: "user")]
        let events = try [event("voice", name: "UserPromptSubmit"), event("helper"), event("archived"),
                          event("removed"), event("missing"), event("typed"),
                          event("voice", tool: .claudeCode), event("existing", name: "Stop"),
                          event("voice", name: "Stop", seconds: 10)]
        let recovered = store.recoveringCodexVoiceThreads(metadata, events: events)
        let row = try XCTUnwrap(recovered.sessions["codex:voice"])
        XCTAssertEqual(row.state, .yourTurn)
        XCTAssertEqual(row.title, "Voice session")
        XCTAssertEqual(row.lastMessage, "Done. All checks passed.")
        XCTAssertEqual(row.lastEventAt, events.last?.at)
        XCTAssertEqual(recovered.sessions["codex:existing"], existing)
        XCTAssertEqual(recovered.dismissed, store.dismissed)
        XCTAssertEqual(recovered.ignored, store.ignored?.subtracting(["codex:voice"]))
        XCTAssertEqual(Set(recovered.sessions.keys), ["codex:voice", "codex:existing"])
        XCTAssertEqual(recovered.recoveringCodexVoiceThreads(metadata, events: events), recovered)
        let saved = try JSONEncoder().encode(recovered)
        XCTAssertEqual(try JSONDecoder().decode(SessionStore.self, from: saved), recovered)
    }

    func testWithoutRetainedEventsNextHookRestoresVoiceWithoutInventingState() throws {
        var store = SessionStore()
        store.ignore(id: "codex:voice")
        store = store.recoveringCodexVoiceThreads([thread("voice")], events: [])
        XCTAssertFalse(store.ignored?.contains("codex:voice") == true)
        XCTAssertTrue(store.sessions.isEmpty)
        store.apply(try event("voice"))
        XCTAssertEqual(store.sessions["codex:voice"]?.state, .working)
    }

    func testUnverifiedAndArchivedMetadataLeaveStoreUntouched() throws {
        var store = SessionStore()
        store.ignore(id: "codex:voice")
        let events = try [event("voice")]
        XCTAssertEqual(store.recoveringCodexVoiceThreads([], events: events), store)
        XCTAssertEqual(store.recoveringCodexVoiceThreads([thread("voice", archived: true)], events: events), store)
    }
    func testRecoveryPrefixLeavesUnreadPlanAdvanceForLiveReader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        func line(_ plan: [String: Any], seconds: Double) throws -> Data {
            let payload: [String: Any] = ["session_id": "voice", "hook_event_name": "PostToolUse",
                "tool_name": "mcp__ccd_turn__update_plan", "tool_input": plan, "transcript_path": "/tmp/example-rollout.jsonl"]
            return HookRecord.makeLine(tool: "codex", payload: try JSONSerialization.data(withJSONObject: payload),
                environment: [:], tty: nil, receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        }
        let first = try line(["items": [["content": "A", "status": "in_progress"],
                                         ["content": "B", "status": "pending"],
                                         ["content": "C", "status": "pending"]]], seconds: 0)
        let second = try line(["advance": true], seconds: 1)
        try (first + Data([10]) + second + Data([10])).write(to: url)
        let cursor = UInt64(first.count + 1)
        var store = SessionStore()
        store.ignore(id: "codex:voice")
        let retained = EventLogReader(url: url).readNewLines(upTo: cursor).compactMap { EventParser.parse(line: $0) }
        XCTAssertEqual(retained.count, 1)
        store = store.recoveringCodexVoiceThreads([thread("voice")], events: retained)
        for event in EventLogReader(url: url, offset: cursor).readNewLines().compactMap({ EventParser.parse(line: $0) }) {
            store.apply(event)
        }
        XCTAssertEqual(store.sessions["codex:voice"]?.progress?.done, 1)
        XCTAssertEqual(store.sessions["codex:voice"]?.progress?.current, "B")
    }

    func testTruncatedLogIsLeftForLiveReader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("new\n".utf8).write(to: url)
        XCTAssertTrue(EventLogReader(url: url).readNewLines(upTo: 100).isEmpty)
        let live = EventLogReader(url: url, offset: 100)
        XCTAssertEqual(live.readNewLines(), [Data("new".utf8)])
    }

}
