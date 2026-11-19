import AIRunsCore
import AppKit
import Combine
import SwiftUI

/// Actions the panel views ask of the window layer.
@MainActor
protocol PanelActions: AnyObject {
    func closePanel()
    func toggleBoard()
    var isBoardVisible: Bool { get }
    func showSettings()
    func renameSession(_ id: String)
    func editCard(_ card: PinCard)
}

/// A borderless panel that can take keyboard focus (for the note field)
/// without activating the app.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate, PanelActions {
    let model: AppModel
    let ui = PanelUIState()

    private let statusItem: NSStatusItem
    private var panel: MenuPanel?
    private var anchorTopRight: NSPoint?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private lazy var floating = FloatingController(model: model, actions: self)
    private let toast = ToastController()

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A stable name, so macOS and menu bar managers (Bartender, Ice)
        // remember where the user put the icon across launches and updates.
        statusItem.autosaveName = "AIRunsStatusItem"
        super.init()
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("AI Runs")
        }
        model.$store
            .sink { [weak self] store in self?.updateButton(store: store) }
            .store(in: &cancellables)
        model.$message
            .sink { [weak self] message in self?.showToastIfNeeded(message) }
            .store(in: &cancellables)
        // The panel's size follows its content (a flyout opening, a group
        // folding); re-anchor it after each change.
        Publishers.Merge(ui.objectWillChange, model.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.panel?.isVisible == true else { return }
                self.placePanel()
            }
            .store(in: &cancellables)
        floating.onVisibilityChange = { [weak self] visible in self?.ui.boardVisible = visible }
        updateButton(store: model.store)
    }

    /// What the button currently shows, so the item is only touched when it
    /// actually changes. Menu bar managers such as Bartender re-identify an
    /// item whose image keeps being replaced, and may treat it as a new item.
    private var shownCount: Int?
    private var shownStatus: Icons.Status?

    private func updateButton(store: SessionStore) {
        guard let button = statusItem.button else { return }
        let status = Icons.Status(store: store)
        if status != shownStatus {
            shownStatus = status
            button.image = Icons.statusImage(status)
        }
        let needsYou = store.needsUserCount
        guard needsYou != shownCount else { return }
        shownCount = needsYou
        if needsYou > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(needsYou)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                             .foregroundColor: Icons.amber])
            button.setAccessibilityLabel("AI Runs, \(needsYou) holding for you")
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.setAccessibilityLabel("AI Runs")
        }
    }

    private func showToastIfNeeded(_ message: String?) {
        guard let message, panel?.isVisible != true, let button = statusItem.button, let window = button.window else { return }
        toast.show(message, below: window.frame)
    }

    // MARK: - Panel

    @objc func togglePanel(_ sender: Any?) {
        if panel?.isVisible == true { closePanel() } else { openPanel() }
    }

    /// True when the menu bar is too full to show the icon, which on a
    /// MacBook usually means it sits behind the camera notch.
    var isIconHidden: Bool {
        guard let window = statusItem.button?.window, let screen = window.screen ?? NSScreen.main else { return true }
        if !window.occlusionState.contains(.visible) { return true }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            let notch = NSRect(x: left.maxX, y: min(left.minY, right.minY), width: right.minX - left.maxX,
                               height: max(left.height, right.height))
            if window.frame.intersects(notch) { return true }
        }
        return !screen.frame.intersects(window.frame)
    }

    func warnIfIconHidden() {
        let key = "didWarnHiddenIcon"
        guard isIconHidden, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "The AI Runs icon is hidden"
        alert.informativeText = "Your menu bar is full, so macOS hid the AI Runs icon (usually behind the camera notch). Press \(HotKey.displayName) or open AI Runs again from Applications to show the panel. Quitting a menu bar app you rarely use makes room for the icon."
        alert.addButton(withTitle: "Show AI Runs Now")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { openPanel() }
    }

    func openPanel() {
        let front = NSWorkspace.shared.frontmostApplication
        model.frontAppAtOpen = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        model.refresh()
        ui.reset()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screenFrame = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        if let buttonFrame = statusItem.button?.window?.frame, !isIconHidden {
            let menuRight = min(buttonFrame.midX + PanelLayout.menuWidth / 2 + PanelLayout.outerPadding,
                                screenFrame.maxX - 4)
            anchorTopRight = NSPoint(x: menuRight, y: buttonFrame.minY - 2)
        } else {
            // No visible icon to hang from: open at the top-right of the screen.
            anchorTopRight = NSPoint(x: screenFrame.maxX - 4, y: screenFrame.maxY - 2)
        }
        placePanel()
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        let root = PanelRootView(model: model, ui: ui, actions: self)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        return panel
    }

    /// Keeps the panel's top-right corner under the menu bar icon as its size changes.
    private func placePanel() {
        guard let panel, let anchor = anchorTopRight,
              let size = panel.contentViewController?.view.fittingSize, size.width > 0
        else { return }
        let frame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        placePanel()
    }

    func closePanel() {
        panel?.orderOut(nil)
        ui.reset()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func installMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated { self?.closePanel() }
                return nil
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    // MARK: - PanelActions

    var isBoardVisible: Bool { floating.isVisible }

    /// Shows or hides the floating window (runs and the pinned board).
    func toggleBoard() {
        closePanel()
        floating.toggle()
        ui.boardVisible = floating.isVisible
    }

    func restoreFloating() {
        floating.restore()
        ui.boardVisible = floating.isVisible
    }

    func showSettings() {
        closePanel()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(
                model: model, iconHidden: { [weak self] in self?.isIconHidden ?? false })))
            window.title = "AI Runs Settings"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func renameSession(_ id: String) {
        guard let session = model.store.sessions[id] else { return }
        closePanel()
        let field = NSTextField(string: session.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        if runPrompt(title: "Rename session", message: "Give this \(session.tool.displayName) session a name you’ll recognise.",
                     accessory: field, focus: field) {
            model.rename(sessionId: id, to: field.stringValue)
        }
    }

    func editCard(_ card: PinCard) {
        closePanel()
        let title = NSTextField(string: card.title)
        let next = NSTextField(string: card.next)
        next.placeholderString = "What you do next on this thread"
        let group = NSComboBox()
        group.addItems(withObjectValues: model.board.groupNames)
        group.stringValue = card.group
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for (label, field) in [("Title", title as NSView), ("Next step", next as NSView), ("Group", group as NSView)] {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            stack.addArrangedSubview(caption)
            stack.addArrangedSubview(field)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 150)
        if runPrompt(title: "Edit card", message: "", accessory: stack, focus: next) {
            model.update(cardId: card.id, title: title.stringValue, next: next.stringValue, group: group.stringValue)
        }
    }

    private func runPrompt(title: String, message: String, accessory: NSView, focus: NSView) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = focus
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// UI-only state of the panel: what is hovered, which groups are folded.
@MainActor
final class PanelUIState: ObservableObject {
    enum Target: Equatable {
        case session(String)
        case card(UUID)

        var key: String {
            switch self {
            case .session(let id): return "s:\(id)"
            case .card(let id): return "c:\(id.uuidString)"
            }
        }
    }

    static let staleGroup = "__stale__"

    @Published var hover: Target?
    @Published var rowFrames: [String: CGRect] = [:]
    @Published var collapsed: Set<String> = [PanelUIState.staleGroup]
    @Published var addingNote = false
    @Published var draft = ""
    @Published var boardVisible = false
    private var clearWork: DispatchWorkItem?

    private var switchWork: DispatchWorkItem?

    /// The first hover shows details at once. Moving to another row waits a
    /// moment, so passing over rows on the way to a button doesn't flip the
    /// details back and forth.
    func hoverOn(_ target: Target) {
        clearWork?.cancel()
        switchWork?.cancel()
        guard hover != target else { return }
        guard hover != nil else {
            hover = target
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hover = target }
        }
        switchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func hoverOff() {
        switchWork?.cancel()
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hover = nil }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func keepHover() { clearWork?.cancel() }

    func reset() {
        clearWork?.cancel()
        switchWork?.cancel()
        hover = nil
        addingNote = false
        draft = ""
    }

    func toggle(group: String) {
        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
        hover = nil
    }
}

/// A small message under the menu bar icon, used when the panel is closed.
@MainActor
final class ToastController {
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, below anchor: NSRect) {
        let hosting = NSHostingView(rootView: ToastView(text: text))
        let size = hosting.fittingSize
        let panel = window ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .transient]
            return panel
        }()
        window = panel
        panel.contentView = hosting
        let screenMax = (NSScreen.main?.visibleFrame.maxX ?? anchor.maxX) - 8
        let x = min(anchor.midX - size.width / 2, screenMax - size.width)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.window?.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        GlassSurface(cornerRadius: 14, fallbackMaterial: .hudWindow) {
            Text(text)
                .font(AppTypography.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .padding(12)
    }
}

enum Icons {
    /// What the menu bar mark is saying.
    enum Status: Equatable {
        /// Nothing is running: the arc alone.
        case idle
        /// Runs are in progress: the arc with its dot.
        case working
        /// A run is holding for the user: the dot turns amber.
        case needsYou

        init(store: SessionStore) {
            if store.needsUserCount > 0 {
                self = .needsYou
            } else {
                self = store.workingCount > 0 ? .working : .idle
            }
        }
    }

    /// The logo's amber, used for the dot and the count.
    static let amber = NSColor(red: 0.91, green: 0.537, blue: 0.047, alpha: 1)

    /// The app's mark, a fermata: the musical sign for "hold until the
    /// conductor gives the cue". A run holds; the user gives the cue.
    /// Template (follows the menu bar's colour) unless the dot is amber.
    static func statusImage(_ status: Status) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink = status == .needsYou ? NSColor.labelColor : NSColor.black
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 4.6), radius: 6.6, startAngle: 0, endAngle: 180)
            arc.lineWidth = 1.9
            arc.lineCapStyle = .round
            ink.setStroke()
            arc.stroke()
            if status != .idle {
                (status == .needsYou ? amber : ink).setFill()
                NSBezierPath(ovalIn: NSRect(x: 9 - 2, y: 5.1 - 2, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = status != .needsYou
        return image
    }
}
