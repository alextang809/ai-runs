import AIRunsCore
import XCTest
@testable import AIRunsApp

@MainActor
final class SessionDestinationTests: XCTestCase {
    private func session(_ tool: AgentTool, _ terminal: TerminalContext = .init()) throws -> Session {
        var store = SessionStore()
        store.apply(.init(tool: tool, kind: .promptStart, sessionId: "fixture", at: Date(),
                          transcriptPath: "/tmp/absent-route-fixture.jsonl", terminal: terminal))
        return try XCTUnwrap(store.sessions.values.first)
    }

    func testDesktopTerminalAndEditorsHaveDifferentActionsForSameProvider() throws {
        for (tool, terminal, label) in [
            (AgentTool.codex, TerminalContext(bundleId: "com.openai.codex"), "Open in Codex"),
            (.claudeCode, .init(bundleId: "com.anthropic.claudefordesktop"), "Open in Claude"),
            (.codex, .init(termProgram: "Apple_Terminal"), "Open in Terminal"),
            (.claudeCode, .init(itermSessionId: "w0t1p0:fixture"), "Open in iTerm2"),
            (.codex, .init(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92"), "Open in Cursor"),
            (.codex, .init(bundleId: "dev.zed.Zed"), "Open in Zed"),
            (.chatgpt, .init(bundleId: "com.google.Chrome"), "Open in Chrome"),
            (.claudeWeb, .init(), "Open in Browser"),
        ] {
            let row = try session(tool, terminal)
            XCTAssertEqual(Jumper.openLabel(for: row), label)
        }
        let unknown = try session(.claudeCode)
        XCTAssertEqual(Jumper.openLabel(for: unknown), "Open Conversation")
        XCTAssertNil(Jumper.hostName(for: unknown))
    }

    func testDesktopRolloutWithNoTerminalAndProjectExecutorWithTTY() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"type":"session_meta","payload":{"id":"fixture","originator":"Codex Desktop","source":"vscode"}}"#.utf8).write(to: url)
        var row = try session(.codex)
        row.transcriptPath = url.path
        XCTAssertEqual(Jumper.hostName(for: row), "Codex")
        XCTAssertEqual(Jumper.openLabel(for: row), "Open in Codex")
        let captured = PinAttachment.session(Jumper.sessionForBookmark(row))
        XCTAssertEqual(Jumper.openLabel(for: captured.link, in: SessionStore()), "Open in Codex")
        XCTAssertNil(row.terminal.bundleId)
        row.terminal = .init(termProgram: "Apple_Terminal", tty: "/dev/ttys002")
        XCTAssertEqual(Jumper.hostName(for: row), "Terminal")
        var project = try session(.claudeCode, .init(termProgram: "Apple_Terminal"))
        project.projectMainId = "chan_example"
        XCTAssertEqual(Jumper.openLabel(for: project), "Open in Claude")
    }

    func testMissingWebAddressDoesNotMarkWatchedSessionAsRead() throws {
        let row = try session(.claudeWeb)
        var markedRead = false
        var message: String?
        Jumper.open(session: row, opened: { markedRead = true }, show: { message = $0 })
        XCTAssertFalse(markedRead)
        XCTAssertNotNil(message)
    }

    func testStoredLinksUsePersistedHostAndIndependentCurrentSessionResolution() {
        let target = PinLink.session(tool: .codex, sessionId: "fixture", cwd: nil,
                                    terminal: .init(termProgram: "vscode"))
        XCTAssertEqual(Jumper.openLabel(for: target, in: SessionStore()), "Open in VS Code")
        XCTAssertEqual(Jumper.openLabel(for: .url("claude://code/project/chan_example"), in: SessionStore()), "Open in Claude")
        XCTAssertEqual(Jumper.openLabel(for: .url("https://claude.ai/chat/example"), in: SessionStore()), "Open in Browser")
    }
}
