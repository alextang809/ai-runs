import AIRunsCore
import AppKit
import Combine
import SwiftUI

/// Stored choices for the floating window.
enum FloatingSettings {
    static let visibleKey = "floating.visible"
    static let expandedKey = "floating.expanded"
    static let autoExpandKey = "floating.autoExpand"
    static let originKey = "floating.topLeft"
}

/// State the floating window's views share with its controller.
@MainActor
final class FloatingState: ObservableObject {
    enum Tab: String { case runs, pinned }
    @Published var expanded = UserDefaults.standard.bool(forKey: FloatingSettings.expandedKey) {
        didSet { UserDefaults.standard.set(expanded, forKey: FloatingSettings.expandedKey) }
    }
    @Published var tab: Tab = .runs
    /// Expanded by itself because something needed the user; folds back after a jump.
    var autoExpanded = false
}

/// A small window that floats above everything, on every Space and over
/// full-screen apps: a capsule with the count, or a card with the runs and
/// the pinned board. Drag it anywhere; it snaps to screen edges.
@MainActor
final class FloatingController: NSObject {
    private let model: AppModel
    private weak var actions: PanelActions?
    private let state = FloatingState()
    private var panel: FloatingPanel?
    private var cancellables = Set<AnyCancellable>()
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var lastNeeds = 0
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel, actions: PanelActions) {
        self.model = model
        self.actions = actions
        super.init()
        lastNeeds = model.store.needsUserCount
        model.$store
            .sink { [weak self] store in self?.storeChanged(needs: store.needsUserCount) }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isPresented == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.present()
        UserDefaults.standard.set(true, forKey: FloatingSettings.visibleKey)
        onVisibilityChange?(true)
    }

    func hide() {
        panel?.dismiss()
        UserDefaults.standard.set(false, forKey: FloatingSettings.visibleKey)
        onVisibilityChange?(false)
    }

    /// Reopens the window at launch if it was open when AI Runs quit.
    func restore() {
        if UserDefaults.standard.bool(forKey: FloatingSettings.visibleKey) { show() }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        let root = FloatingRoot(model: model, state: state, controller: self)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrameTopLeftPoint(savedTopLeft())
        return panel
    }

    // MARK: Size and position

    /// Keeps the corner nearest the screen edge still while the content grows
    /// or shrinks, so expanding never pushes the window off-screen.
    func contentSizeChanged(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? old
        let keepRight = old.midX > screen.midX
        let keepBottom = old.midY < screen.midY
        var frame = NSRect(origin: .zero, size: size)
        frame.origin.x = keepRight ? old.maxX - size.width : old.minX
        frame.origin.y = keepBottom ? old.minY : old.maxY - size.height
        panel.setFrame(clamp(frame, to: screen), display: true)
    }

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    func dragEnded() {
        dragStart = nil
        guard let panel else { return }
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var frame = panel.frame
        let margin: CGFloat = 12, reach: CGFloat = 40
        if frame.minX - screen.minX < reach { frame.origin.x = screen.minX + margin }
        if screen.maxX - frame.maxX < reach { frame.origin.x = screen.maxX - margin - frame.width }
        if frame.minY - screen.minY < reach { frame.origin.y = screen.minY + margin }
        if screen.maxY - frame.maxY < reach { frame.origin.y = screen.maxY - margin - frame.height }
        frame = clamp(frame, to: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().setFrame(frame, display: true)
        }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: FloatingSettings.originKey)
    }

    private func clamp(_ frame: NSRect, to screen: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        return frame
    }

    private func savedTopLeft() -> NSPoint {
        if let text = UserDefaults.standard.string(forKey: FloatingSettings.originKey) {
            let point = NSPointFromString(text)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) { return point }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - 320, y: screen.maxY - 12)
    }

    // MARK: Behaviour

    private func storeChanged(needs: Int) {
        defer { lastNeeds = needs }
        guard isVisible, needs > lastNeeds, !state.expanded,
              UserDefaults.standard.bool(forKey: FloatingSettings.autoExpandKey) else { return }
        state.autoExpanded = true
        state.tab = .runs
        state.expanded = true
    }

    func open(_ session: Session) {
        model.open(sessionId: session.id)
        if state.autoExpanded {
            state.autoExpanded = false
            state.expanded = false
        }
    }

    func rename(_ id: String) { actions?.renameSession(id) }
    func editCard(_ card: PinCard) { actions?.editCard(card) }
}

// MARK: - Views

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct FloatingRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: FloatingState
    let controller: FloatingController

    var body: some View {
        Group {
            if state.expanded {
                FloatingCard(model: model, state: state, controller: controller)
            } else {
                FloatingCapsule(model: model, state: state, controller: controller)
            }
        }
        .padding(14) // room for the shadow
        .fixedSize()
        .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
        .onPreferenceChange(SizeKey.self) { size in
            MainActor.assumeIsolated { controller.contentSizeChanged(size) }
        }
    }
}

/// Moves the window by dragging; a short press stays a click.
private struct WindowDrag: ViewModifier {
    let controller: FloatingController
    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in controller.dragEnded() }
        )
    }
}

private struct FloatingSurface<Content: View>: View {
    var radius: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        GlassSurface(cornerRadius: radius) { content }
    }
}

struct FloatingCapsule: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: FloatingState
    let controller: FloatingController

    var body: some View {
        let sessions = model.store.ordered()
        let needs = model.store.needsUserCount
        FloatingSurface(radius: 22) {
            HStack(spacing: 10) {
                Image(nsImage: Icons.statusImage(Icons.Status(store: model.store)))
                HStack(spacing: 5) {
                    Text("\(needs > 0 ? needs : model.store.workingCount)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text(needs > 0 ? "NEED YOU" : (model.store.workingCount > 0 ? "WORKING" : "ALL CLEAR"))
                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(.secondary)
                }
                if !sessions.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 16)
                    HStack(spacing: 4) {
                        ForEach(sessions.prefix(10)) { session in RunDot(session: session, now: model.now) }
                    }
                }
            }
            .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .onTapGesture { state.expanded = true }
        .modifier(WindowDrag(controller: controller))
        .help("Click to open · drag to move")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI Runs, \(needs) need you, \(model.store.workingCount) working")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.expanded = true }
    }
}

/// One dot per run: solid when it needs you, outlined while it works, grey otherwise.
private struct RunDot: View {
    let session: Session
    let now: Date
    var body: some View {
        let color = Palette.tool(session.tool)
        Group {
            if session.needsUser {
                Circle().fill(color)
            } else if session.state == .working, !session.isInBackground, !session.isQuiet(now: now) {
                Circle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Circle().fill(Color.secondary.opacity(0.45))
            }
        }
        .frame(width: 8, height: 8)
    }
}

struct FloatingCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: FloatingState
    let controller: FloatingController

    var body: some View {
        FloatingSurface(radius: 20) {
            VStack(spacing: 0) {
                header
                if let message = model.message {
                    Text(message)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 6)
                }
                switch state.tab {
                case .runs: runs
                case .pinned:
                    BoardView(model: model, editCard: { controller.editCard($0) })
                        .frame(height: 360)
                }
            }
            .frame(width: 310)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: Icons.statusImage(Icons.Status(store: model.store)))
            Picker("", selection: $state.tab) {
                Text("Runs").tag(FloatingState.Tab.runs)
                Text("Pinned").tag(FloatingState.Tab.pinned)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .controlSize(.small)
            Spacer()
            RefreshButton(model: model)
            Button { state.expanded = false } label: {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Fold into the capsule")
            Button { controller.hide() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide the floating window")
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .modifier(WindowDrag(controller: controller))
    }

    private func ignoreAction(for session: Session) -> (() -> Void)? {
        guard RunText.canIgnore(session) else { return nil }
        let id = session.id
        return { model.setIgnored(sessionId: id, true) }
    }

    @ViewBuilder private var runs: some View {
        let sessions = model.store.ordered()
        // Keep unknown and currently open conversations in the same list.
        // Other finished and ignored runs fold into one line.
        let active = sessions.filter { (!$0.isDone || $0.nativeView?.isOpen == true) && !$0.isIgnored }
        let quiet = sessions.count - active.count
        ThreadsHint(model: model)
            .padding(.horizontal, 14).padding(.bottom, 8)
        if active.isEmpty {
            Text(sessions.isEmpty ? "Nothing running." : "Nothing needs you; nothing is working right now.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 12)
        } else {
            let list = VStack(spacing: 0) {
                ForEach(active) { session in
                    FloatingRow(session: session, now: model.now,
                                open: { controller.open(session) },
                                rename: { controller.rename(session.id) },
                                pin: { model.pin(sessionId: session.id) },
                                remove: { model.remove(sessionId: session.id) },
                                ignore: ignoreAction(for: session))
                }
            }
            .padding(.horizontal, 4)
            // The window sizes itself to its content, so a scroll view only
            // appears (with a fixed height) once the list is long.
            if active.count <= 8 {
                list
            } else {
                ScrollView { list }.frame(height: 400)
            }
        }
        if quiet > 0 {
            Text("+ \(quiet) done or ignored")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 9).padding(.top, 2)
        }
    }
}

/// A compact row: the tool's colour as a bar, the title and state, and what
/// it's doing. Click to jump; × or right-click to remove.
private struct FloatingRow: View {
    let session: Session
    let now: Date
    let open: () -> Void
    let rename: () -> Void
    let pin: () -> Void
    let remove: () -> Void
    /// "Ignore for Now"; nil when this run can't be ignored.
    var ignore: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.tool(session.tool)).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        StatePill(session: session, now: now)
                        Color.clear.frame(width: RemoveZone.slot, height: 16)
                    }
                    Text(RunText.liveText(session, now: now))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering {
                RemoveZone(label: "Remove \(session.title) from the list", action: remove)
                    .padding(.top, 6 + 8 - RemoveZone.size.height / 2)
                    .padding(.trailing, 8 + RemoveZone.slot / 2 - RemoveZone.size.width / 2)
            }
        }
        // A waiting run can be set aside right here: it leaves this window and
        // stays in the panel's Ignored section.
        .overlay(alignment: .bottomTrailing) {
            if hovering, let ignore {
                Button("Ignore", action: ignore)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                    .padding(.trailing, 8).padding(.bottom, 5)
                    .help("Stop counting this until it asks something new")
                    .accessibilityLabel("Ignore \(session.title) for now")
            }
        }
        .onHover { hovering = $0 }
        .help(RunText.place(session))
        .contextMenu {
            Button("Open", action: open)
            if let ignore { Button("Ignore for Now", action: ignore) }
            Button("Rename…", action: rename)
            Button("Pin to Board", action: pin)
            Divider()
            Button("Remove from List", action: remove)
        }
    }
}
