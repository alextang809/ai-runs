import Foundation
import XCTest
@testable import AIRunsCore

final class ClaudeCurrentViewTests: XCTestCase {
    private let project = "chan_example123"
    private let root = "cmsg_example123"

    private func area(_ url: String, title: String? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: "AXWebArea", title: title, url: url, children: children)
    }

    private func threadHeader(_ title: String) -> AXNode {
        AXNode(role: "AXToolbar", children: [AXNode(role: "AXGroup", children: [
            AXNode(role: "AXButton", title: "Threads"),
            AXNode(role: "AXHeading", title: title, children: [AXNode(role: "AXStaticText", value: title)]),
        ])])
    }

    private func projectHeader(_ title: String) -> AXNode {
        AXNode(role: "AXToolbar", children: [AXNode(role: "AXGroup", children: [
            AXNode(role: "AXHeading", title: title, children: [AXNode(role: "AXButton", title: title)]),
        ])])
    }

    private func views(_ nodes: [AXNode]) -> [CurrentClaudeView] {
        ClaudeCurrentView.sightings(in: AXNode(role: "AXApplication", children: nodes))
    }

    func testCurrentMainConversationHasAnExplicitProjectIdentity() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)", title: "Example project")])
        XCTAssertEqual(found, [CurrentClaudeView(conversation: ClaudeConversation(projectId: project), title: "Example project")])
        XCTAssertNil(found.first?.conversation.thread)
        XCTAssertEqual(found.first?.conversation.appLink?.absoluteString, "claude://code/project/\(project)")
    }

    func testCurrentThreadRetainsTheExistingThreadAddressAndLink() {
        let found = views([area("https://claude.ai/code/project/\(project)?thread=\(root)", title: "Example project",
                                children: [threadHeader("Example thread")])])
        XCTAssertEqual(found.first?.title, "Example thread")
        XCTAssertEqual(found.first?.conversation.thread, ProjectThread(projectId: project, threadId: root))
        XCTAssertEqual(found.first?.conversation.appLink?.absoluteString, "claude://code/project/\(project)?thread=\(root)")
    }

    func testMainAndChildDoNotCollapseIntoOneIdentity() {
        let found = views([
            area("https://claude.ai/epitaxy/project/\(project)"),
            area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)"),
        ])
        XCTAssertEqual(Set(found.map(\.conversation)).count, 2)
    }

    func testRepeatedWebAreasUseTheFirstReliableTitle() {
        let url = "https://claude.ai/epitaxy/project/\(project)?thread=\(root)"
        let found = views([
            area(url, title: "Claude"),
            area(url, title: "Example project", children: [threadHeader("  Example\n thread  ")]),
            area(url, title: "Example project", children: [threadHeader("Later title")]),
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.title, "Example thread")
    }

    func testOnlyTheWebAreaIdentifiesTheCurrentConversation() {
        let link = AXNode(role: "AXLink", title: "Example linked thread",
                          url: "https://claude.ai/epitaxy/project/\(project)?thread=\(root)")
        XCTAssertTrue(views([link]).isEmpty)
        XCTAssertTrue(views([AXNode(role: "AXGroup", url: link.url)]).isEmpty)
    }

    func testConversationTextIsNeverUsedAsItsTitleOrState() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)", children: [
            AXNode(role: "AXHeading", title: "An example conversation message"),
            AXNode(role: "AXStaticText", value: "Working"),
            AXNode(role: "AXStaticText", value: "An example transcript sentence"),
        ])])
        XCTAssertEqual(found, [CurrentClaudeView(conversation: ClaudeConversation(projectId: project))])
    }

    func testMalformedThreadQueriesNeverBecomeMainConversations() {
        let suffixes = ["?thread", "?thread=", "?thread=invalid", "?thread=session_example",
                        "?thread=\(root)&thread=\(root)", "?thread=\(root)&thread=", "?thread=\(root)%0A", "?Thread=\(root)"]
        for suffix in suffixes {
            XCTAssertTrue(views([area("https://claude.ai/epitaxy/project/\(project)\(suffix)")]).isEmpty, suffix)
        }
    }

    func testForeignOrMalformedRoutesAreNotCurrentClaudeViews() {
        let urls = [
            "http://claude.ai/epitaxy/project/\(project)",
            "https://claude.ai.example/epitaxy/project/\(project)",
            "https://example.com/epitaxy/project/\(project)",
            "https://user:password@claude.ai/epitaxy/project/\(project)",
            "https://claude.ai:444/epitaxy/project/\(project)",
            "https://claude.ai/epitaxy/project/not-a-project",
            "https://claude.ai/epitaxy/project/\(project)/extra",
            "https://claude.ai/epitaxy//project/\(project)",
            "https://claude.ai/chat/example",
            "https://claude.ai/epitaxy/project/\(project)%0A",
        ]
        for url in urls { XCTAssertTrue(views([area(url)]).isEmpty, url) }
    }

    func testNavigationQueryAndFragmentDoNotChangeIdentity() {
        let found = views([
            area("https://claude.ai/epitaxy/project/\(project)?tab=threads#top"),
            area("https://claude.ai/code/project/\(project)/?tab=context"),
        ])
        XCTAssertEqual(found.map(\.conversation), [ClaudeConversation(projectId: project)])
    }

    func testMissingOrGenericWebAreaTitlesStayUnavailable() {
        for title in [nil, "", " \n ", "Claude", "Claude.ai", "Threads"] {
            XCTAssertNil(views([area("https://claude.ai/epitaxy/project/\(project)", title: title)]).first?.title)
        }
    }

    func testInvalidConstructedAddressesCannotProduceAppLinks() {
        XCTAssertNil(ClaudeConversation(projectId: "invalid").appLink)
        XCTAssertNil(ClaudeConversation(projectId: project, threadId: "").appLink)
        XCTAssertNil(ClaudeConversation(projectId: project, threadId: "cmsg_example123\n").appLink)
        XCTAssertNil(ClaudeConversation(projectId: project, threadId: "invalid").thread)
    }


    func testChildNeverBorrowsTheProjectDocumentTitle() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: "Example project", children: [
            AXNode(role: "AXHeading", title: "Example body heading"),
        ])])
        XCTAssertEqual(found, [CurrentClaudeView(conversation: ClaudeConversation(projectId: project, threadId: root))])
    }

    func testVisibleMainAndChildToolbarsIdentifyBothConversations() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: "Example project", children: [
            projectHeader("Example project"), threadHeader("Example child"),
        ])])
        XCTAssertEqual(found, [
            CurrentClaudeView(conversation: ClaudeConversation(projectId: project), title: "Example project"),
            CurrentClaudeView(conversation: ClaudeConversation(projectId: project, threadId: root), title: "Example child"),
        ])
    }

    func testUnrelatedProjectToolbarDoesNotIdentifyTheVisibleMain() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: "Example project", children: [
            projectHeader("Different project"), threadHeader("Example child"),
        ])])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.conversation.threadId, root)
        XCTAssertEqual(found.first?.title, "Example child")
    }

    func testAmbiguousThreadToolbarHeadingsStayUnavailable() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", children: [
            threadHeader("Example first"), threadHeader("Example second"),
        ])])
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found.first?.title)
    }

    func testNestedWebAreaHeaderDoesNotSupplyAParentTitle() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", children: [
            area("https://example.com/embedded", children: [threadHeader("Embedded heading")]),
        ])])
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found.first?.title)
    }

    func testProjectDocumentBrandWrapperStillIdentifiesTheVisibleMain() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: "Example project - Claude", children: [
            projectHeader("Example project"), threadHeader("Example child"),
        ])])
        XCTAssertEqual(found.map(\.conversation), [ClaudeConversation(projectId: project), ClaudeConversation(projectId: project, threadId: root)])
        XCTAssertEqual(found.map(\.title), ["Example project", "Example child"])
    }

    func testProjectDocumentWorkspaceWrapperStillIdentifiesTheVisibleMain() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: "Example project · Example workspace", children: [
            projectHeader("Example project"), threadHeader("Example child"),
        ])])
        XCTAssertEqual(found.map(\.conversation), [ClaudeConversation(projectId: project), ClaudeConversation(projectId: project, threadId: root)])
        XCTAssertEqual(found.map(\.title), ["Example project", "Example child"])
    }

    func testArbitraryDocumentTextCannotSupplyAProjectHeaderMatch() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: "Some text about Example project in a conversation", children: [
            projectHeader("Example project"), threadHeader("Example child"),
        ])])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.conversation.threadId, root)
    }

    func testProjectHeaderNeedsASeparatedDocumentName() {
        for document in ["Example projectExtra", "Example workspace_Example project"] {
            let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: document, children: [
                projectHeader("Example project"), threadHeader("Example child"),
            ])])
            XCTAssertEqual(found.count, 1, document)
        }
        let suffix = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: "Example workspace | Example project", children: [
            projectHeader("Example project"), threadHeader("Example child"),
        ])])
        XCTAssertEqual(suffix.count, 2)
    }

    func testProjectHeaderComparisonUsesTheFullTitle() {
        let shared = String(repeating: "A", count: 70)
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", title: shared + " first - Claude", children: [
            projectHeader(shared + " second"), threadHeader("Example child"),
        ])])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.conversation.threadId, root)
    }

    func testTrustedBreadcrumbCanUseABrandWordAsAThreadName() {
        let found = views([area("https://claude.ai/epitaxy/project/\(project)?thread=\(root)", children: [threadHeader("Claude")])])
        XCTAssertEqual(found.first?.title, "Claude")
    }

    func testMainConversationAddressDecodesWithoutAThreadField() throws {
        let data = Data(#"{"projectId":"chan_example123"}"#.utf8)
        let address = try JSONDecoder().decode(ClaudeConversation.self, from: data)
        XCTAssertEqual(address, ClaudeConversation(projectId: project))
        XCTAssertEqual(try JSONDecoder().decode(ClaudeConversation.self, from: JSONEncoder().encode(address)), address)
    }
}
