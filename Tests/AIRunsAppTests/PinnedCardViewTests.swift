import AIRunsCore
import AppKit
import SwiftUI
import XCTest
@testable import AIRunsApp

final class PinnedCardViewTests: XCTestCase {
    func testSummarySeparatesSessionsArtifactsAndApplications() {
        let attachments = [
            PinAttachment(title: "Implementation", link: .session(tool: .codex, sessionId: "fixture", cwd: nil, terminal: .init())),
            PinAttachment(title: "Review", link: .url("https://claude.ai/chat/example")),
            PinAttachment(title: "Checklist", link: .url("https://example.com/checklist")),
        ]
        XCTAssertEqual(PinnedCardPresentation.summary(for: attachments), "2 sessions · 1 artifact")
        XCTAssertEqual(PinnedCardPresentation.summary(for: []), "No linked items")
        XCTAssertEqual(PinnedCardPresentation.summary(for: [.init(title: "Editor", link: .app(bundleId: "example.editor", name: "Editor"))]), "1 app")
    }

    func testOnlyKnownConversationRoutesAreClassifiedAsSessions() {
        XCTAssertEqual(PinnedCardPresentation.tool(for: .url("https://chatgpt.com/c/example")), .chatgpt)
        XCTAssertEqual(PinnedCardPresentation.tool(for: .url("https://claude.ai/chat/example")), .claudeWeb)
        XCTAssertEqual(PinnedCardPresentation.tool(for: .url("claude://code/project/example?thread=fixture")), .claudeCode)
        XCTAssertNil(PinnedCardPresentation.tool(for: .url("https://claude.ai.example.com/chat/example")))
        XCTAssertNil(PinnedCardPresentation.tool(for: .url("https://chatgpt.com/pricing")))
    }

    @MainActor
    func testExpandedCardKeepsAllLinksInsideBothSurfaceWidths() {
        var board = PinBoard()
        let card = PinCard(title: "A long project title that must fit in a narrow floating window",
                           next: "Verify the browser authorization and review the resulting account connection")
        board.add(card)
        for index in 0..<5 {
            XCTAssertTrue(board.attach(.init(title: "Review document \(index)", link: .url("https://example.com/\(index)")), to: card.id))
        }
        let linked = board.card(id: card.id)!
        for width in [CGFloat(286), 360] {
            let collapsed = size(linked, width: width, expanded: false)
            let expanded = size(linked, width: width, expanded: true)
            XCTAssertEqual(collapsed.width, width, accuracy: 1)
            XCTAssertEqual(expanded.width, width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(expanded.height - collapsed.height, 5 * 28)
        }
    }

    @MainActor
    private func size(_ card: PinCard, width: CGFloat, expanded: Bool) -> CGSize {
        NSHostingView(rootView: PinnedCardView(card: card, isExpanded: .constant(expanded),
                                             saveNext: { _ in true }, openLink: { _ in }) {
            EmptyView()
        }.frame(width: width)).fittingSize
    }
}
