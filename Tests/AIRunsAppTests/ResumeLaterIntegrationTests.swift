import AIRunsCore
import XCTest
@testable import AIRunsApp

@MainActor
final class ResumeLaterIntegrationTests: XCTestCase {
    func testCapturedReplySurvivesRelaunchAndTheSessionRemainsOpenable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let date = Date()
        var store = SessionStore()
        var start = AgentEvent(tool: .codex, kind: .promptStart, sessionId: "fixture", at: date,
                               transcriptPath: "/tmp/example.jsonl")
        start.prompt = "Compare the sample diagrams"
        store.apply(start)
        var end = AgentEvent(tool: .codex, kind: .turnEnd, sessionId: "fixture", at: date.addingTimeInterval(2))
        end.lastMessage = "Two drawings are ready.\n\nNext step: Compare their labels."
        store.apply(end)
        let session = try XCTUnwrap(store.sessions.values.first)
        let model = AppModel(testingRoot: root, store: store)
        let saved = try XCTUnwrap(model.resumeLater(session))
        let disk = try XCTUnwrap(JSONFile.load(PinBoard.self, from: model.paths.pins))
        XCTAssertEqual(disk.card(id: saved.id)?.excerpt, end.lastMessage)
        let reopened = AppModel(testingRoot: root, store: store, board: disk)
        XCTAssertEqual(reopened.resumeLater(session)?.id, saved.id)
        XCTAssertEqual(reopened.board.cards.count, 1)
        let link = try XCTUnwrap(saved.attachments.first)
        XCTAssertEqual(Jumper.currentSession(for: link.link, in: store)?.id, session.id)
        XCTAssertEqual(reopened.liveTitle(for: link), session.currentTopicTitle)
        XCTAssertNil(reopened.message)
    }
}
