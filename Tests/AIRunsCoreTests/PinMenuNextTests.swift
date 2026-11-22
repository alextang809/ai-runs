import Foundation
import XCTest
@testable import AIRunsCore

final class PinMenuNextTests: XCTestCase {
    func testOnlyChosenCardsWithNextAppearInSelectionOrderAndPersist() throws {
        var board = PinBoard()
        let unscheduled = PinCard(title: "Unselected", next: "Verify later")
        let first = PinCard(title: "First", next: "Check the install")
        let second = PinCard(title: "Second", next: "Read the review")
        let empty = PinCard(title: "Empty", next: "   ")
        for card in [unscheduled, first, second, empty] { board.add(card) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(board.setMenuNext(true, for: first.id, now: now))
        XCTAssertTrue(board.setMenuNext(true, for: second.id, now: now.addingTimeInterval(1)))
        XCTAssertFalse(board.setMenuNext(true, for: empty.id, now: now))
        XCTAssertEqual(board.menuNextCards.map(\.id), [first.id, second.id])
        let reopened = try JSONDecoder().decode(PinBoard.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(reopened.menuNextCards.map(\.id), [first.id, second.id])
        board.update(id: first.id, next: "")
        XCTAssertNil(board.card(id: first.id)?.menuNextAt)
        XCTAssertEqual(board.menuNextCards.map(\.id), [second.id])
    }

    func testExistingPinnedCardCanAddNextAndReopenWithAllLinkedDestinations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("pins.json")
        var board = PinBoard()
        let card = PinCard(title: "Account setup")
        board.add(card)
        let links = [
            PinAttachment(title: "Implementation", link: .session(tool: .codex, sessionId: "fixture-codex", cwd: nil, terminal: .init())),
            PinAttachment(title: "Review", link: .session(tool: .claudeCode, sessionId: "fixture-claude", cwd: nil, terminal: .init())),
            try XCTUnwrap(PinAttachment.artifact("https://example.com/pr/42", title: "PR"))
        ]
        for link in links { XCTAssertTrue(board.attach(link, to: card.id)) }
        XCTAssertEqual(board.menuNextCards.count, 0)

        board.update(id: card.id, next: "Verify browser authorization")
        XCTAssertTrue(board.setMenuNext(true, for: card.id))
        try JSONFile.save(board, to: path)

        let reopened = try XCTUnwrap(JSONFile.load(PinBoard.self, from: path))
        let selected = try XCTUnwrap(reopened.menuNextCards.first)
        XCTAssertEqual(selected.next, "Verify browser authorization")
        XCTAssertEqual(selected.attachments, links)
    }

    func testSelectionLimitAndArchiveUndo() {
        var board = PinBoard()
        let cards = (1...4).map { PinCard(title: "Card \($0)", next: "Review") }
        cards.forEach { board.add($0) }
        for card in cards.prefix(3) { XCTAssertTrue(board.setMenuNext(true, for: card.id)) }
        XCTAssertFalse(board.setMenuNext(true, for: cards[3].id))
        board.archive(id: cards[0].id)
        XCTAssertTrue(board.setMenuNext(true, for: cards[3].id))
        board.unarchive(id: cards[0].id, at: 0)
        XCTAssertNil(board.card(id: cards[0].id)?.menuNextAt)
        XCTAssertTrue(board.setMenuNext(false, for: cards[3].id))
        XCTAssertTrue(board.setMenuNext(true, for: cards[0].id))
        XCTAssertEqual(Set(board.menuNextCards.map(\.id)), Set(cards.prefix(3).map(\.id)))
    }
}
