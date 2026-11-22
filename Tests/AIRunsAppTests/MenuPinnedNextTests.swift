import AIRunsCore
import AppKit
import SwiftUI
import XCTest
@testable import AIRunsApp

final class MenuPinnedNextTests: XCTestCase {
    @MainActor
    func testExpandingCardFitsLinksInlineWithoutWideningMenu() {
        let first = PinCard(title: "Account setup", next: "Verify browser authorization",
                            link: .session(tool: .codex, sessionId: "example-codex", cwd: nil, terminal: .init()))
        let second = PinCard(title: "Release checks", next: "Install and launch the new build")
        var board = PinBoard()
        board.add(first)
        XCTAssertTrue(board.attach(.init(title: "Review",
                                         link: .session(tool: .claudeCode, sessionId: "example-claude",
                                                        cwd: nil, terminal: .init())), to: first.id))
        XCTAssertTrue(board.attach(.init(title: "Example PR",
                                         link: .url("https://example.com/pr")), to: first.id))
        let cards = [board.card(id: first.id)!, second]
        let collapsed = fittingSize(cards: cards, expanded: nil)
        let expanded = fittingSize(cards: cards, expanded: first.id)

        XCTAssertEqual(collapsed.width, PanelLayout.menuWidth, accuracy: 1)
        XCTAssertEqual(expanded.width, collapsed.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(expanded.height - collapsed.height, 3 * 24)
    }

    @MainActor
    func testPinnedCardsAppearImmediatelyWithoutNextSelection() {
        let start = Date(timeIntervalSince1970: 100)
        let cards = (0..<5).map { offset in
            PinCard(title: "Card \(offset)", createdAt: start.addingTimeInterval(Double(offset)))
        }
        let shown = MenuPinnedNext.visiblePinnedCards(cards, selected: [], expandedID: nil, showAll: false)
        XCTAssertEqual(shown.map(\.id), [cards[4], cards[3], cards[2]].map(\.id))
    }

    @MainActor
    func testFocusedPinnedCardIsVisibleWithoutOpeningTheFullList() {
        let selected = PinCard(title: "Selected", next: "Verify build")
        let pinned = PinCard(title: "Pinned")
        let shown = MenuPinnedNext.visiblePinnedCards([selected, pinned], selected: [selected],
                                                      expandedID: pinned.id, showAll: false)
        XCTAssertEqual(shown.map(\.id), [pinned.id])
        XCTAssertEqual(MenuPinnedNext.visiblePinnedCards([selected, pinned], selected: [selected],
                                                        expandedID: nil, showAll: false).map(\.id), [pinned.id])
    }

    @MainActor
    func testNewPinRemainsVisibleAfterClosingMenuWithExistingSelections() {
        let selected = PinCard(title: "Selected", next: "Review")
        let recent = PinCard(title: "New pin", createdAt: Date(timeIntervalSince1970: 200))
        let older = PinCard(title: "Older pin", createdAt: Date(timeIntervalSince1970: 100))
        let ui = PanelUIState()
        ui.expandedNextCardID = recent.id
        ui.reset()
        let visible = MenuPinnedNext.visiblePinnedCards([selected, older, recent], selected: [selected],
            expandedID: ui.expandedNextCardID, showAll: false)
        XCTAssertEqual(visible.map(\.id), [recent.id, older.id])
    }

    @MainActor
    func testFullSelectionStillRevealsNewPinAndViewAllDeduplicatesSelections() {
        let selected = (0..<3).map { PinCard(title: "Selected \($0)", next: "Review") }
        let pinned = PinCard(title: "New pin")
        XCTAssertEqual(MenuPinnedNext.visiblePinnedCards(selected + [pinned], selected: selected,
            expandedID: pinned.id, showAll: false).map(\.id), [pinned.id])
        XCTAssertEqual(MenuPinnedNext.visiblePinnedCards(selected + [pinned], selected: selected,
            expandedID: nil, showAll: true).map(\.id), [pinned.id])
        XCTAssertEqual(MenuPinnedNext.visiblePinnedCards(selected + [pinned], selected: selected,
            expandedID: nil, showAll: false).map(\.id), [pinned.id])
    }

    @MainActor
    func testClosingMenuClearsExpandedNextCard() {
        let ui = PanelUIState()
        ui.expandedNextCardID = UUID()
        ui.reset()
        XCTAssertNil(ui.expandedNextCardID)
    }

    @MainActor
    private func fittingSize(cards: [PinCard], expanded: UUID?) -> CGSize {
        NSHostingView(rootView: MenuPinnedNext(cards: cards, expandedCardID: .constant(expanded),
                                               cancelHover: {}, openLink: { _, _ in })
            .frame(width: PanelLayout.menuWidth)).fittingSize
    }
}
