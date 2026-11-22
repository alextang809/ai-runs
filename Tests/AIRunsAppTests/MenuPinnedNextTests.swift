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
