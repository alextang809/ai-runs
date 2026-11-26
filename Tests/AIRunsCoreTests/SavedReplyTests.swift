import XCTest
@testable import AIRunsCore

final class SavedReplyTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = "sample-cleanup"

    private func event(_ kind: EventKind, _ offset: Double, prompt: String? = nil, reply: String? = nil) -> AgentEvent {
        AgentEvent(tool: .codex, kind: kind, sessionId: id, at: origin.addingTimeInterval(offset),
                   prompt: prompt, lastMessage: reply, transcriptPath: "/test/report.jsonl")
    }

    private func session(_ store: SessionStore) throws -> Session {
        try XCTUnwrap(store.sessions[Session.key(tool: .codex, sessionId: id)])
    }

    func testSavesExactDisplayedReplyPerTurnAndPreservesOlderSnapshot() throws {
        var store = SessionStore()
        var board = PinBoard()
        let earlier = "Keep the example archive.\n\n  Reason: review pending."
        store.apply(event(.promptStart, 0, prompt: "Review the fixture files"))
        store.apply(event(.turnEnd, 1.25, reply: earlier))
        let firstView = try session(store)
        let first = try XCTUnwrap(board.saveReply(session: firstView, now: origin.addingTimeInterval(2)))
        XCTAssertTrue(first.isSavedReply)
        store.apply(event(.promptStart, 3, prompt: "Continue"))
        XCTAssertEqual(board.savedReply(session: try session(store))?.id, first.id)
        store.apply(event(.turnEnd, 4.25, reply: "Next step: Review the file index."))
        let secondView = try session(store)
        XCTAssertNil(board.savedReply(session: secondView))
        let second = try XCTUnwrap(board.saveReply(session: secondView, now: origin.addingTimeInterval(5)))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.excerpt, earlier)
        XCTAssertEqual(second.next, "Review the file index.")
        XCTAssertEqual(board.saveReply(session: firstView)?.id, first.id)
        XCTAssertEqual(board.saveReply(session: secondView)?.id, second.id)
        store.apply(event(.promptStart, 6, prompt: "Continue"))
        store.apply(event(.turnEnd, 7.25, reply: earlier))
        let repeatedWording = try session(store)
        XCTAssertNil(board.savedReply(session: repeatedWording))
        let third = try XCTUnwrap(board.saveReply(session: repeatedWording))
        XCTAssertNotEqual(first.id, third.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pins = folder.appendingPathComponent("pins.json"), sessions = folder.appendingPathComponent("sessions.json")
        try JSONFile.save(board, to: pins)
        try JSONFile.save(store, to: sessions)
        var reloaded = try XCTUnwrap(JSONFile.load(PinBoard.self, from: pins))
        let current = try session(XCTUnwrap(JSONFile.load(SessionStore.self, from: sessions)))
        XCTAssertEqual(reloaded.saveReply(session: current)?.id, third.id)
        XCTAssertEqual(reloaded.cards.count, 3)
    }

    func testLegacyCardIsReusedOnlyForMatchingReplyInSameTopic() throws {
        var store = SessionStore()
        var board = PinBoard()
        store.apply(event(.promptStart, 0, prompt: "Review the fixture files"))
        XCTAssertNil(board.saveReply(session: try session(store)))
        let quote = "The sample is ready."
        store.apply(event(.turnEnd, 1, reply: quote))
        let legacy = board.saveForLater(session: try session(store), now: origin.addingTimeInterval(2))
        XCTAssertFalse(legacy.isSavedReply)
        XCTAssertEqual(board.saveReply(session: try session(store))?.id, legacy.id)
        store.apply(event(.promptStart, 3, prompt: "Continue"))
        store.apply(event(.turnEnd, 4, reply: quote))
        let later = try XCTUnwrap(board.saveReply(session: try session(store)))
        XCTAssertNotEqual(later.id, legacy.id)
        store.apply(event(.promptStart, 5, prompt: "New topic: Design a podcast cover"))
        XCTAssertNil(board.saveReply(session: try session(store)))
        store.apply(event(.turnEnd, 6, reply: quote))
        let third = try XCTUnwrap(board.saveReply(session: try session(store)))
        XCTAssertNotEqual(later.id, third.id)
        XCTAssertNotEqual(later.savedTopic?.topicID, third.savedTopic?.topicID)
        XCTAssertEqual(board.cards.count, 3)
    }
}
