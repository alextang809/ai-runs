import Foundation
import XCTest
@testable import AIRunsCore

final class CodexCreatedThreadTests: XCTestCase {
    private func metadata(_ id: String = "created", archived: Bool = false) -> CodexThread {
        CodexThread(id: id, name: "Layout review", threadSource: "agent_created_thread", archived: archived)
    }

    private func toolEvent(_ id: String = "created") throws -> AgentEvent {
        let payload: [String: Any] = [
            "session_id": id, "hook_event_name": "PostToolUse", "tool_name": "Bash",
            "tool_input": ["command": "swift test"], "cwd": "/tmp/example-project",
            "transcript_path": "/tmp/example-rollout.jsonl",
        ]
        let line = HookRecord.makeLine(tool: "codex", payload: try JSONSerialization.data(withJSONObject: payload),
            environment: [:], tty: nil, receivedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return try XCTUnwrap(EventParser.parse(line: line))
    }

    func testAgentCreatedConversationIsNotAnInternalHelper() {
        XCTAssertFalse(metadata().isInternal)
        let upper = CodexThread(id: "other", name: nil, threadSource: "AGENT_CREATED_THREAD", archived: false)
        XCTAssertFalse(upper.isInternal)
        for source in ["subagent", "guardian_review", "unknown_helper"] {
            XCTAssertTrue(CodexThread(id: "helper", name: nil, threadSource: source, archived: false).isInternal)
        }
    }

    func testRecoverCreatedConversationFromOnlyToolHooks() throws {
        var store = SessionStore()
        store.ignore(id: "codex:created")
        let hook = try toolEvent()
        XCTAssertNil(hook.prompt)
        let recovered = store.recoveringCodexConversations([metadata()], events: [hook])
        let row = try XCTUnwrap(recovered.sessions["codex:created"])
        XCTAssertEqual(row.title, "Layout review")
        XCTAssertEqual(row.state, .working)
        XCTAssertEqual(row.transcriptPath, hook.transcriptPath)
        XCTAssertFalse(recovered.ignored?.contains(row.id) == true)
        XCTAssertEqual(recovered.recoveringCodexConversations([metadata()], events: [hook]), recovered)
        XCTAssertTrue(store.ignored?.contains("codex:created") == true, "Recovery returns a new store")
        let saved = try JSONEncoder().encode(recovered)
        XCTAssertEqual(try JSONDecoder().decode(SessionStore.self, from: saved), recovered)
    }

    func testArchivedAndUserRemovedCreatedConversationsStayHidden() throws {
        var store = SessionStore()
        let hook = try toolEvent()
        store.apply(hook)
        store.dismiss(id: "codex:created", at: hook.at)
        store.ignore(id: "codex:created")
        XCTAssertEqual(store.recoveringCodexConversations([metadata()], events: [hook]), store)
        var archived = SessionStore()
        archived.ignore(id: "codex:created")
        XCTAssertEqual(archived.recoveringCodexConversations([metadata(archived: true)], events: [hook]), archived)
    }

    func testFutureHookRestoresCreatedConversationWhenLogWasCompacted() throws {
        var store = SessionStore()
        store.ignore(id: "codex:created")
        store = store.recoveringCodexConversations([metadata()], events: [])
        XCTAssertTrue(store.sessions.isEmpty)
        store.apply(try toolEvent())
        XCTAssertEqual(store.sessions["codex:created"]?.state, .working)
    }
}
