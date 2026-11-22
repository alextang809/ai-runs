import XCTest
@testable import AIRunsCore

final class SaveForLaterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(prompt: String = "Review the sample export", reply: String?, id: String = "demo-thread") throws -> Session {
        var store = SessionStore()
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: id, at: now, prompt: prompt, transcriptPath: "/test/transcript.jsonl"))
        if let reply {
            store.apply(AgentEvent(tool: .codex, kind: .turnEnd, sessionId: id, at: now.addingTimeInterval(1),
                                   lastMessage: reply))
        }
        return try XCTUnwrap(store.sessions[Session.key(tool: .codex, sessionId: id)])
    }

    func testExplicitActionAndOriginalQuotationSurviveEditingRepinningAndReload() throws {
        var board = PinBoard()
        let quote = "Preview is ready.\n\n**Next step:** Compare the sample exports.\n\n   Keep this indentation."
        let live = try session(reply: quote)
        let saved = board.saveForLater(session: live, now: now)
        XCTAssertTrue(saved.isSavedForLater)
        XCTAssertEqual(saved.next, "Compare the sample exports.")
        XCTAssertTrue(saved.nextIsSuggested)
        XCTAssertEqual(saved.excerpt, quote)
        board.update(id: saved.id, next: "Check with editor", now: now.addingTimeInterval(2))
        var reopened = try JSONDecoder().decode(PinBoard.self, from: JSONEncoder().encode(board))
        let later = try session(reply: "Next step: Archive the preview.")
        let again = reopened.saveForLater(session: later, now: now.addingTimeInterval(50))
        XCTAssertEqual(again.id, saved.id)
        XCTAssertEqual(again.createdAt, saved.createdAt)
        XCTAssertEqual(again.excerpt, quote)
        XCTAssertEqual(again.next, "Check with editor")
        XCTAssertEqual(again.savedTopic?.originalNext, "Compare the sample exports.")
        XCTAssertEqual(again.savedTopic?.quoteSource, .reply)
        XCTAssertFalse(again.nextIsSuggested)
        XCTAssertEqual(reopened.savedForLater(session: later)?.id, saved.id)
        XCTAssertEqual(reopened.savedForLaterCards.map(\.id), [saved.id])
    }

    func testQuestionOfferAndCodeAreNotMistakenForTasks() throws {
        for reply in ["Anything else?", "需要我继续吗？", "已经处理好了。", "Next step: Would you like me to test it?",
                      "Example:\n```text\nNext step: Delete the fixture.\n```"] {
            var board = PinBoard()
            let card = board.saveForLater(session: try session(reply: reply))
            XCTAssertEqual(card.next, "", reply)
            XCTAssertEqual(card.excerpt, reply)
        }
        var board = PinBoard()
        XCTAssertEqual(board.saveForLater(session: try session(reply: "已完成整理。\n下一步：核对示例导出的行数。")).next,
                       "核对示例导出的行数。")
    }

    func testExplicitInstructionsKeepFilenamesAndHandleChineseClauses() throws {
        for (reply, action) in [("Ready. Please open sample.json in Preview.", "open sample.json in Preview."),
                                ("构建好了，可以开始测试导出。", "测试导出。")] {
            var board = PinBoard()
            XCTAssertEqual(board.saveForLater(session: try session(reply: reply)).next, action)
        }
    }

    func testChangingTopicInOneConversationCapturesFreshPromptBeforeReply() throws {
        var store = SessionStore()
        var board = PinBoard()
        let key = Session.key(tool: .codex, sessionId: "thread")
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "thread", at: now,
                               prompt: "Review the export filters", transcriptPath: "/test/thread.jsonl"))
        store.apply(AgentEvent(tool: .codex, kind: .turnEnd, sessionId: "thread", at: now.addingTimeInterval(1),
                               lastMessage: "Next step: Check the export."))
        let first = board.saveForLater(session: try XCTUnwrap(store.sessions[key]), now: now)
        let prompt = "换个话题。帮我设计播客封面。"
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "thread", at: now.addingTimeInterval(2),
                               prompt: prompt, transcriptPath: "/test/thread.jsonl"))
        let second = board.saveForLater(session: try XCTUnwrap(store.sessions[key]), now: now.addingTimeInterval(2))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.savedTopic?.quoteSource, .prompt)
        XCTAssertEqual(second.excerpt, prompt)
        XCTAssertEqual(second.next, "")
        XCTAssertEqual(board.card(id: first.id)?.next, "Check the export.")
    }

    func testLegacyPinsAndThreeChosenTopSlotsStayIndependent() throws {
        var board = PinBoard()
        let live = try session(reply: "Next step: Compare the sample exports.")
        let legacy = board.pin(session: live)
        board.update(id: legacy.id, next: "My own note")
        for i in 0..<3 {
            let card = PinCard(title: "Item \(i)", next: "Review")
            board.add(card)
            XCTAssertTrue(board.setMenuNext(true, for: card.id))
        }
        let selected = board.menuNextCards
        let snapshot = board.saveForLater(session: live)
        XCTAssertNotEqual(snapshot.id, legacy.id)
        XCTAssertEqual(snapshot.next, "My own note")
        XCTAssertFalse(snapshot.nextIsSuggested)
        XCTAssertEqual(board.pin(session: live).id, legacy.id)
        XCTAssertEqual(board.card(id: legacy.id)?.next, "My own note")
        XCTAssertEqual(board.menuNextCards, selected)
        XCTAssertEqual(board.savedForLaterCards.map(\.id), [snapshot.id])
    }

    func testSameTitleInDifferentConversationsKeepsBothOriginals() throws {
        var board = PinBoard()
        let a = board.saveForLater(session: try session(reply: "One", id: "first"), now: now)
        let b = board.saveForLater(session: try session(reply: "Two", id: "second"), now: now.addingTimeInterval(3))
        XCTAssertEqual(board.savedForLaterCards.map(\.id), [b.id, a.id])
        board.archive(id: b.id)
        XCTAssertNil(board.savedForLater(session: try session(reply: nil, id: "second")))
        board.unarchive(id: b.id, at: 0)
        XCTAssertEqual(board.savedForLaterCards.map(\.id), [b.id, a.id])
    }

    func testTopicAndSnapshotStillMatchAfterAppRelaunchWithFractionalEventTimes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var store = SessionStore()
        var board = PinBoard()
        let id = Session.key(tool: .codex, sessionId: "thread")
        for (offset, prompt) in [(0.25, "Review export filters"), (5.75, "New topic: Design a podcast cover")] {
            store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "thread", at: now.addingTimeInterval(offset),
                                   prompt: prompt, transcriptPath: "/test/thread.jsonl"))
        }
        let before = board.saveForLater(session: try XCTUnwrap(store.sessions[id]))
        let sessionsURL = folder.appendingPathComponent("sessions.json")
        let pinsURL = folder.appendingPathComponent("pins.json")
        try JSONFile.save(store, to: sessionsURL)
        try JSONFile.save(board, to: pinsURL)
        let restored = try XCTUnwrap(JSONFile.load(SessionStore.self, from: sessionsURL)?.sessions[id])
        var reopened = try XCTUnwrap(JSONFile.load(PinBoard.self, from: pinsURL))
        XCTAssertEqual(reopened.saveForLater(session: restored).id, before.id)
        XCTAssertEqual(reopened.cards.count, 1)
    }
}
