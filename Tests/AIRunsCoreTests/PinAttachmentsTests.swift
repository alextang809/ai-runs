import Foundation
import XCTest
@testable import AIRunsCore

final class PinAttachmentsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLegacyLinkMigratesAndExistingLinksRoundTrip() throws {
        let original = PinCard(title: "Release", next: "Review changes", link: .url("https://example.com/report"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "attachments")

        let decoded = try JSONDecoder().decode(PinCard.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.next, "Review changes")
        XCTAssertEqual(decoded.attachments.map(\.link), [.url("https://example.com/report")])

        let roundTrip = try JSONDecoder().decode(PinCard.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }

    func testAttachAndDetachSessionsAndArtifactWithoutChangingSharedNext() throws {
        var board = PinBoard()
        let card = PinCard(title: "Release", next: "Run the smoke test")
        board.add(card)
        let codex = PinAttachment.session(session(tool: .codex, id: "one", title: "Implementation"))
        let claude = PinAttachment.session(session(tool: .claudeCode, id: "one", title: "Review"))
        let artifact = try XCTUnwrap(PinAttachment.artifact(" https://example.com/release ", title: " Release notes "))

        XCTAssertTrue(board.attach(codex, to: card.id, now: now))
        XCTAssertTrue(board.attach(claude, to: card.id, now: now))
        XCTAssertTrue(board.attach(artifact, to: card.id, now: now))
        XCTAssertFalse(board.attach(.session(session(tool: .codex, id: "one", title: "Renamed", terminal: .init(tty: "new"))), to: card.id))
        XCTAssertFalse(board.attach(artifact, to: UUID()))
        XCTAssertEqual(board.card(id: card.id)?.attachments.map(\.title), ["Implementation", "Review", "Release notes"])

        var updatedClaude = session(tool: .claudeCode, id: "one", title: "New Review")
        updatedClaude.lastMessage = "Shall I rerun the review?"
        XCTAssertEqual(board.pin(session: updatedClaude, now: now).id, card.id)
        XCTAssertEqual(board.cards.count, 1)
        XCTAssertTrue(board.detach(codex.id, from: card.id, now: now))
        XCTAssertFalse(board.detach(codex.id, from: card.id, now: now))
        XCTAssertEqual(board.card(id: card.id)?.link, claude.link)
        XCTAssertEqual(board.card(id: card.id)?.next, "Run the smoke test")
        XCTAssertEqual(board.card(id: card.id)?.attachments.map(\.link), [claude.link, artifact.link])

        let restored = try JSONDecoder().decode(PinBoard.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(restored, board)
        XCTAssertEqual(restored.card(id: card.id)?.attachments.map(\.id), [claude.id, artifact.id])
    }

    func testRejectsUnsafeOrMalformedArtifactURLs() throws {
        for input in ["", "example.com/release", "file:///tmp/report", "javascript:alert(1)",
                      "ssh://example.com", "https://", "https://user:pass@example.com/",
                      "https://example.com/a b", "https://bad%20host/release", "https://example.com:99999/",
                      "https://example.com/\nnext"] {
            XCTAssertNil(PinAttachment.artifact(input), input)
        }
        let artifact = try XCTUnwrap(PinAttachment.artifact("https://example.com/reports/release%20notes"))
        XCTAssertFalse(artifact.title.isEmpty)
        XCTAssertEqual(artifact.link, .url("https://example.com/reports/release%20notes"))
    }

    func testClaudeWebAttachmentUsesItsConversationURL() {
        var web = session(tool: .claudeWeb, id: "web", title: "Browser review")
        web.webURL = "https://claude.ai/chat/example"
        XCTAssertEqual(PinAttachment.session(web).link, .url("https://claude.ai/chat/example"))
    }

    func testLegacyWebLinkCanOpenAndDoesNotDuplicateItsTrackedConversation() {
        let id = "legacy-example-id"
        let legacy = PinLink.session(tool: .claudeWeb, sessionId: id, cwd: nil, terminal: .init())
        let url = "https://claude.ai/chat/\(id)"
        let card = PinCard(title: "Previous review", link: legacy)
        XCTAssertEqual(card.link, .url(url))

        var web = session(tool: .claudeWeb, id: id, title: "Browser review")
        web.webURL = url
        var board = PinBoard()
        board.add(card)
        XCTAssertFalse(board.attach(.session(web), to: card.id))
        XCTAssertEqual(board.card(id: card.id)?.attachments.count, 1)

        let invalid = PinLink.session(tool: .claudeWeb, sessionId: "escape/../id", cwd: nil, terminal: .init())
        XCTAssertEqual(PinCard(title: "Invalid", link: invalid).link, invalid)
    }

    private func session(tool: AgentTool, id: String, title: String, terminal: TerminalContext = .init()) -> Session {
        Session(tool: tool, sessionId: id, title: title, cwd: nil, state: .working,
                startedAt: now, turnStartedAt: now, lastEventAt: now, terminal: terminal)
    }
}
