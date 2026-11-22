import AIRunsCore
import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import AIRunsApp

final class PinnedCardInteractionTests: XCTestCase {
    @MainActor
    func testPinActionRevealsNewCardAndSavesNextInMenu() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var store = SessionStore()
        var event = AgentEvent(tool: .codex, kind: .promptStart, sessionId: "fixture", at: Date(),
                               cwd: "/tmp/pinned-fixture", transcriptPath: root.appendingPathComponent("session.jsonl").path)
        event.toolTitle = "Account connection checks"
        store.apply(event)
        let model = AppModel(testingRoot: root, store: store)
        let ui = PanelUIState()
        let actions = NativePinMenuActions(model: model, ui: ui)
        let window = try NativePinWindow(width: 360) {
            MenuColumn(model: model, ui: ui, actions: actions)
        }
        defer { window.close() }
        try window.performNamedAction("Pin to Board")

        XCTAssertEqual(actions.pinnedSession, "codex:fixture")
        XCTAssertFalse(actions.isBoardVisible)
        let pinned = try XCTUnwrap(model.board.cards.first)
        let prefix = "pinned.\(pinned.id.uuidString)"
        XCTAssertEqual(ui.expandedNextCardID, pinned.id)
        let sessionLink = try XCTUnwrap(pinned.attachments.first)
        _ = try window.requireElement("\(prefix).link.\(sessionLink.id.uuidString)")

        try window.press("\(prefix).edit-next")
        try window.edit("\(prefix).next-field", to: "Verify browser sign-in")
        try window.press("\(prefix).save-next")
        _ = try window.requireElement("\(prefix).toggle")
        XCTAssertNil(window.element("\(prefix).next-field"))
        let saved = try XCTUnwrap(JSONFile.load(PinBoard.self, from: model.paths.pins)?.card(id: pinned.id))
        XCTAssertEqual(saved.next, "Verify browser sign-in")
        XCTAssertEqual(saved.attachments, pinned.attachments)
        XCTAssertFalse(actions.isBoardVisible)
    }

    @MainActor
    func testExpandedLinksInvokeTheCorrespondingAttachmentActions() throws {
        var board = PinBoard()
        let card = PinCard(title: "Account connection checks", next: "Review sign-in")
        board.add(card)
        let attachments: [PinAttachment] = [
            .init(title: "Implementation", link: .session(tool: .codex, sessionId: "implementation", cwd: nil, terminal: .init())),
            .init(title: "Review", link: .session(tool: .claudeCode, sessionId: "review", cwd: nil, terminal: .init())),
            .init(title: "Checklist", link: .url("https://example.com/checklist")),
        ]
        for attachment in attachments {
            XCTAssertTrue(board.attach(attachment, to: card.id))
        }
        let pinned = try XCTUnwrap(board.card(id: card.id))
        var opened: [PinAttachment] = []
        let window = try NativePinWindow(width: 286) {
            NativePinFixture(card: pinned, saveNext: nil, openLink: { opened.append($0) })
        }
        defer { window.close() }
        let prefix = "pinned.\(card.id.uuidString)"
        let links = attachments.map { "\(prefix).link.\($0.id.uuidString)" }
        _ = try window.requireElement("\(prefix).toggle")
        XCTAssertTrue(links.allSatisfy { window.element($0) == nil })

        try window.press("\(prefix).toggle")
        for link in links {
            try window.press(link)
        }
        XCTAssertEqual(opened, attachments)
        try window.press("\(prefix).toggle")
        window.update()
        XCTAssertTrue(links.allSatisfy { window.element($0) == nil })
    }

    @MainActor
    func testFailedSaveKeepsDraftAndCancelDiscardsIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("blocked")
        try Data("fixture file".utf8).write(to: root)
        var board = PinBoard()
        let card = PinCard(title: "Account connection checks")
        board.add(card)
        let model = AppModel(testingRoot: root, board: board)
        let window = try NativePinWindow(width: 286) {
            NativePinFixture(card: card, saveNext: { model.setMenuNext(false, for: card.id, next: $0) },
                             openLink: { _ in })
        }
        defer { window.close() }
        let prefix = "pinned.\(card.id.uuidString)"
        let field = "\(prefix).next-field"
        try window.press("\(prefix).edit-next")
        try window.edit(field, to: "Keep this draft")
        try window.press("\(prefix).save-next")
        _ = try window.requireElement("\(prefix).save-error")
        let failedField = try window.requireElement(field)
        XCTAssertEqual(window.value(kAXValueAttribute, of: failedField) as? String, "Keep this draft")
        XCTAssertEqual(model.board.card(id: card.id), card)

        try window.press("\(prefix).cancel-next")
        try window.press("\(prefix).edit-next")
        let reopenedField = try window.requireElement(field)
        XCTAssertEqual(window.value(kAXValueAttribute, of: reopenedField) as? String, "")
        XCTAssertNil(window.element("\(prefix).save-error"))
        XCTAssertEqual(model.board.card(id: card.id), card)
    }

    @MainActor
    func testFloatingEditOfExistingNextUpdatesTheMenuAndPreservesSelection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var board = PinBoard()
        let card = PinCard(title: "Account connection checks", next: "Review sign-in",
                           link: .url("https://example.com/checklist"))
        board.add(card)
        XCTAssertTrue(board.setMenuNext(true, for: card.id, now: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))))
        let model = AppModel(testingRoot: root, board: board)
        let ui = PanelUIState()
        let actions = NativePinMenuActions(model: model, ui: ui)
        let floatingState = FloatingState()
        floatingState.tab = .pinned
        let controller = FloatingController(model: model, actions: actions)
        let menuWindow = try NativePinWindow(width: 360) {
            MenuColumn(model: model, ui: ui, actions: actions)
        }
        defer { menuWindow.close() }
        let floatingWindow = try NativePinWindow(width: 310) {
            FloatingCard(model: model, state: floatingState, controller: controller)
        }
        defer { floatingWindow.close() }
        let prefix = "pinned.\(card.id.uuidString)"
        let initialNext = try menuWindow.requireElement("\(prefix).toggle")
        XCTAssertEqual(menuWindow.value(kAXDescriptionAttribute, of: initialNext) as? String, "Review sign-in")

        try floatingWindow.pressMenu("\(prefix).more", item: "\(prefix).edit-next", title: "Edit next step…")
        let identifier = "\(prefix).next-field"
        let input = try floatingWindow.requireElement(identifier)
        XCTAssertEqual(floatingWindow.value(kAXValueAttribute, of: input) as? String, "Review sign-in")
        try floatingWindow.edit(identifier, to: "Verify browser sign-in")
        try floatingWindow.press("\(prefix).save-next")

        let saved = try XCTUnwrap(JSONFile.load(PinBoard.self, from: model.paths.pins)?.card(id: card.id))
        XCTAssertEqual(saved.next, "Verify browser sign-in")
        XCTAssertEqual(saved.menuNextAt, board.card(id: card.id)?.menuNextAt)
        XCTAssertEqual(saved.attachments, card.attachments)
        let changedNext = try menuWindow.requireElement("\(prefix).toggle")
        XCTAssertEqual(menuWindow.value(kAXDescriptionAttribute, of: changedNext) as? String, saved.next)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct NativePinFixture: View {
    let card: PinCard
    let saveNext: ((String) -> Bool)?
    let openLink: (PinAttachment) -> Void
    @State private var expanded = false

    var body: some View {
        PinnedCardView(card: card, isExpanded: $expanded, saveNext: saveNext, openLink: openLink) {
            EmptyView()
        }
    }
}

@MainActor
private final class NativePinMenuActions: PanelActions {
    let model: AppModel
    let ui: PanelUIState
    private(set) var pinnedSession: String?
    private(set) var isBoardVisible = false

    init(model: AppModel, ui: PanelUIState) {
        self.model = model
        self.ui = ui
    }

    func pinSessionInMenu(_ sessionID: String) {
        pinnedSession = sessionID
        ui.expandedNextCardID = model.pin(sessionId: sessionID)?.id
        ui.menuPinRevealID = UUID()
    }

    func closePanel() {}
    func toggleBoard() { isBoardVisible.toggle() }
    func showPinnedBoard() { isBoardVisible = true }
    func pinSession(_ sessionID: String) { isBoardVisible = true }
    func showSettings() {}
    func showAccounts() {}
    func showAddAccount() {}
    func showUsageDashboard() {}
    func showAbout() {}
    func renameSession(_ id: String) {}
    func editCard(_ card: PinCard) {}
}

@MainActor
private final class NativePinWindow {
    private let window: NSWindow
    private let application = AXUIElementCreateApplication(getpid())
    private var menuItemPress: AXError?

    init<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) throws {
        NSApplication.shared.finishLaunching()
        guard let screen = NSScreen.main else {
            throw XCTSkip("Native card interactions need a WindowServer display.")
        }
        let hosting = NSHostingView(rootView: content().frame(width: width))
        hosting.sizingOptions = []
        let frame = CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                           width: width, height: min(660, screen.visibleFrame.height - 40))
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Pinned card interaction \(UUID().uuidString)"
        window.contentView = hosting
        window.orderFront(nil)
        update()
    }

    func close() {
        window.close()
    }

    func update() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    func element(_ identifier: String) -> AXUIElement? {
        elements().first { value(kAXIdentifierAttribute, of: $0) as? String == identifier }
    }

    func requireElement(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) throws -> AXUIElement {
        let found = waitFor { element(identifier) }
        return try XCTUnwrap(found, "Missing native control \(identifier). \(treeDescription())", file: file, line: line)
    }

    func press(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let button = try requireElement(identifier, file: file, line: line)
        XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success,
                       "Could not press \(identifier)", file: file, line: line)
        update()
    }

    func edit(_ identifier: String, to text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let field = try requireElement(identifier, file: file, line: line)
        XCTAssertEqual(AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success,
                       file: file, line: line)
        XCTAssertEqual(AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString), .success,
                       file: file, line: line)
        update()
    }

    func pressMenu(_ identifier: String, item: String, title: String,
                   file: StaticString = #filePath, line: UInt = #line) throws {
        menuItemPress = nil
        let tracking = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                               object: nil, queue: nil) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu,
                      menu.indexOfItem(withTitle: title) >= 0 else { return }
                // Wait until AppKit enters the tracking run loop and exposes its menu items.
                let selection = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        if let self, let action = self.element(item) {
                            self.menuItemPress = AXUIElementPerformAction(action, kAXPressAction as CFString)
                        }
                        menu.cancelTracking()
                    }
                }
                RunLoop.current.add(selection, forMode: .eventTracking)
                RunLoop.current.add(selection, forMode: .default)
            }
        }
        defer { NotificationCenter.default.removeObserver(tracking) }
        try press(identifier, file: file, line: line)
        XCTAssertEqual(waitFor { menuItemPress }, .success, "Could not press \(item)", file: file, line: line)
    }

    func performNamedAction(_ description: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let found = waitFor {
            elements().lazy.compactMap { element -> (AXUIElement, String)? in
                var names: CFArray?
                guard AXUIElementCopyActionNames(element, &names) == .success else { return nil }
                let name = (names as? [String])?.first { action in
                    var title: CFString?
                    return AXUIElementCopyActionDescription(element, action as CFString, &title) == .success
                        && (title as String?) == description
                }
                return name.map { (element, $0) }
            }.first
        }
        let action = try XCTUnwrap(found, "Missing native action \(description). \(treeDescription())", file: file, line: line)
        XCTAssertEqual(AXUIElementPerformAction(action.0, action.1 as CFString), .success,
                       file: file, line: line)
        update()
    }

    func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func treeDescription() -> String {
        elements().map { element in
            let role = value(kAXRoleAttribute, of: element) as? String ?? ""
            let identifier = value(kAXIdentifierAttribute, of: element) as? String ?? ""
            let label = value(kAXDescriptionAttribute, of: element) as? String ?? ""
            let title = value(kAXTitleAttribute, of: element) as? String ?? ""
            let value1 = value(kAXValueAttribute, of: element) as? String ?? ""
            var names: CFArray?
            let _ = AXUIElementCopyActionNames(element, &names)
            return "\(role) \(identifier) \(label) \(title) \(value1) (\(names as? [String] ?? []))"
        }.joined(separator: ", ")
    }

    private func elements() -> [AXUIElement] {
        let windows = value(kAXWindowsAttribute, of: application) as? [AXUIElement] ?? []
        guard let ownWindow = windows.first(where: { value(kAXTitleAttribute, of: $0) as? String == window.title })
        else { return [] }
        return descendants(of: ownWindow)
    }

    private func descendants(of element: AXUIElement) -> [AXUIElement] {
        let children = value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        return [element] + children.flatMap { descendants(of: $0) }
    }

    private func waitFor<T>(_ find: () -> T?) -> T? {
        let deadline = Date(timeIntervalSinceNow: 2)
        repeat {
            if let result = find() { return result }
            update()
        } while Date() < deadline
        return nil
    }
}
