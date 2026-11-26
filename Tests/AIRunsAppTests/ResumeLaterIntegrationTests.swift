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
        model.toggleSessionPin(session.id)
        let watched = try XCTUnwrap(JSONFile.load(SessionStore.self, from: model.paths.sessions))
        XCTAssertTrue(try XCTUnwrap(watched.sessions[session.id]).isPinned)
        XCTAssertTrue(model.board.cards.isEmpty)
        let saved = try XCTUnwrap(model.saveReply(session))
        let disk = try XCTUnwrap(JSONFile.load(PinBoard.self, from: model.paths.pins))
        XCTAssertEqual(disk.card(id: saved.id)?.excerpt, end.lastMessage)
        let reopened = AppModel(testingRoot: root, store: store, board: disk)
        XCTAssertEqual(reopened.saveReply(session)?.id, saved.id)
        XCTAssertEqual(reopened.board.cards.count, 1)
        let link = try XCTUnwrap(saved.attachments.first)
        XCTAssertEqual(Jumper.currentSession(for: link.link, in: store)?.id, session.id)
        XCTAssertEqual(reopened.liveTitle(for: link), session.currentTopicTitle)
        XCTAssertNil(reopened.message)
    }

    func testViewingAnOlderReplyInTheSameSecondKeepsTheLatestReplyUnread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 100)
        var store = SessionStore()
        store.apply(.init(tool: .codex, kind: .promptStart, sessionId: "fixture", at: date,
                          transcriptPath: "/tmp/example.jsonl"))
        let id = try XCTUnwrap(store.sessions.values.first?.id)
        store.setPinned(id: id, true, at: date)
        let at = date.addingTimeInterval(1)
        store.apply(.init(tool: .codex, kind: .turnEnd, sessionId: "fixture", at: at, lastMessage: "First original."))
        let first = try XCTUnwrap(store.sessions[id])
        store.apply(.init(tool: .codex, kind: .turnEnd, sessionId: "fixture", at: at, lastMessage: "Second original."))
        let model = AppModel(testingRoot: root, store: store)
        model.markSessionRead(first)
        XCTAssertTrue(try XCTUnwrap(model.store.sessions[id]).hasUnreadReply)
        model.markSessionRead(try XCTUnwrap(model.store.sessions[id]))
        XCTAssertFalse(try XCTUnwrap(model.store.sessions[id]).hasUnreadReply)
    }

}
