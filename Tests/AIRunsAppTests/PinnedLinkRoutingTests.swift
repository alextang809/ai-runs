import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

final class PinnedLinkRoutingTests: XCTestCase {
    @MainActor
    func testSessionLinkUsesCurrentTrackedWindowForItsOwnToolAndID() throws {
        var store = SessionStore()
        let now = Date()
        let oldTerminal = TerminalContext(tty: "/dev/ttys001")
        let newTerminal = TerminalContext(tty: "/dev/ttys002")
        for tool in [AgentTool.codex, .claudeCode] {
            store.apply(AgentEvent(tool: tool, kind: .promptStart, sessionId: "tracked", at: now,
                                   transcriptPath: "/tmp/fixture", terminal: newTerminal))
        }
        let link = PinLink.session(tool: .codex, sessionId: "tracked", cwd: nil, terminal: oldTerminal)
        let destination = try XCTUnwrap(Jumper.currentSession(for: link, in: store))
        XCTAssertEqual(destination.tool, .codex)
        XCTAssertEqual(destination.state, .working)
        XCTAssertEqual(destination.terminal, newTerminal)
        XCTAssertNil(Jumper.currentSession(for: .session(tool: .codex, sessionId: "missing",
                                                        cwd: nil, terminal: oldTerminal), in: store))
    }

    @MainActor
    func testWebLinkSelectsOnlyItsExactTrackedConversation() {
        let recordedURL = "https://claude.ai/chat/example"
        var event = AgentEvent(tool: .claudeWeb, kind: .promptStart, sessionId: "example", at: Date())
        event.url = recordedURL
        var store = SessionStore()
        store.apply(event)
        XCTAssertEqual(Jumper.currentSession(for: .url(recordedURL), in: store)?.sessionId, "example")
        XCTAssertNil(Jumper.currentSession(for: .url("https://claude.ai/chat/different"), in: store))
        XCTAssertNil(Jumper.currentSession(for: .url("https://github.com/example/repo/pull/1"), in: store))
    }
}
