import AIRunsCore
import XCTest
@testable import AIRunsApp

final class PinnedNextEditingTests: XCTestCase {
    @MainActor
    func testEditingSelectedNextAtCapacityPreservesSelectionAndLinksOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var board = PinBoard()
        let original = PinCard(title: "Connection checks", next: "Review the draft",
                               link: .session(tool: .codex, sessionId: "sample", cwd: nil, terminal: .init()))
        board.add(original)
        XCTAssertTrue(board.attach(.init(title: "Review", link: .session(tool: .claudeCode,
            sessionId: "review", cwd: nil, terminal: .init())), to: original.id))
        XCTAssertTrue(board.attach(.init(title: "Checklist", link: .url("https://example.com/checks")), to: original.id))
        XCTAssertTrue(board.setMenuNext(true, for: original.id, now: Date(timeIntervalSince1970: 100)))
        for index in 0..<2 {
            let card = PinCard(title: "Other \(index)", next: "Review")
            board.add(card)
            XCTAssertTrue(board.setMenuNext(true, for: card.id, now: Date(timeIntervalSince1970: Double(101 + index))))
        }
        let before = try XCTUnwrap(board.card(id: original.id))
        let model = AppModel(testingRoot: root, board: board)
        XCTAssertTrue(model.setMenuNext(true, for: original.id, next: "  Test browser sign-in  "))
        let saved = try XCTUnwrap(JSONFile.load(PinBoard.self, from: model.paths.pins))
        let after = try XCTUnwrap(saved.card(id: original.id))
        XCTAssertEqual(after.next, "Test browser sign-in")
        XCTAssertEqual(after.menuNextAt, before.menuNextAt)
        XCTAssertEqual(after.attachments, before.attachments)
        XCTAssertEqual(saved.menuNextCards.map(\.id), board.menuNextCards.map(\.id))
    }

    @MainActor
    func testEditingUnselectedCardDoesNotSelectItOrLoseAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var board = PinBoard()
        let card = PinCard(title: "Release", link: .url("https://example.com/release"))
        board.add(card)
        let model = AppModel(testingRoot: root, board: board)
        XCTAssertTrue(model.setMenuNext(false, for: card.id, next: "Review release notes"))
        let saved = try XCTUnwrap(JSONFile.load(PinBoard.self, from: model.paths.pins)?.card(id: card.id))
        XCTAssertEqual(saved.next, "Review release notes")
        XCTAssertNil(saved.menuNextAt)
        XCTAssertEqual(saved.attachments, card.attachments)
    }

    @MainActor
    func testFailedSaveLeavesOriginalNextAndSelectionUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var board = PinBoard()
        let card = PinCard(title: "Review", next: "Original")
        board.add(card)
        let model = AppModel(testingRoot: root, board: board)
        XCTAssertFalse(model.setMenuNext(false, for: card.id, next: "Changed"))
        XCTAssertEqual(model.board.card(id: card.id), card)
        XCTAssertFalse(model.setMenuNext(false, for: card.id, next: " \n "))
    }
}
