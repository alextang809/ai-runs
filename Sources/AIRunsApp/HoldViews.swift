import AIRunsCore
import AppKit
import SwiftUI

// MARK: - Drag state

/// Where a dragged session can be let go.
enum HoldTarget: Hashable {
    /// A stretch of the line, by days after today (0 is Today).
    case segment(Int)
    /// The Waiting end cap.
    case waiting
    /// "Pin to Top", above the list while a row that isn't held is dragged.
    case pin
    /// "Bring back now", above the list while a held session is dragged.
    case bringBack
}

/// One window's drag of a session onto the On hold line, and what the line
/// shows (the open tray, the Waiting name being typed). The menu panel and the
/// floating window each have their own, so a field appears where the drag started.
///
/// The drag is an in-window gesture: nothing goes through the pasteboard, so
/// the floating window's board never sees it.
@MainActor
final class HoldDragState: ObservableObject {
    static let space = "hold-surface"

    @Published private(set) var dragged: Session?
    @Published private(set) var location: CGPoint = .zero
    @Published private(set) var hovered: HoldTarget?
    /// The stretch whose tray is open, by days after today.
    @Published var openSegment: Int?
    /// The held session whose "who or what" field is shown.
    @Published var editingWaitingID: String?

    /// Frames of the drop targets in `space`, reported by the views.
    var targets: [HoldTarget: CGRect] = [:]
    /// Called when a drag starts and ends, so the menu can freeze its hover details.
    var onActiveChange: ((Bool) -> Void)?
    /// Makes this window take the keyboard for the "who or what" field. The
    /// floating window never takes it by itself.
    var requestKeyboard: (() -> Void)?

    private var cancelled = false
    private var endedAt: Date?
    private var escapeMonitor: Any?

    var isActive: Bool { dragged != nil }

    func changed(_ session: Session, at point: CGPoint) {
        guard !cancelled else { return }
        if dragged == nil {
            dragged = session
            onActiveChange?(true)
            installEscape()
        }
        location = point
        let hit = target(at: point, for: session)
        if hovered != hit { hovered = hit }
    }

    /// The pointer went up at `point`. Returns the target under it, or nil for
    /// nowhere or after Escape. The release point decides, not the last hover.
    func ended(at point: CGPoint? = nil) -> (session: Session, target: HoldTarget)? {
        defer { finish() }
        guard !cancelled, let session = dragged,
              let target = target(at: point ?? location, for: session) else { return nil }
        return (session, target)
    }

    private func target(at point: CGPoint, for session: Session) -> HoldTarget? {
        targets.first { $0.value.contains(point) && accepts($0.key, session) }?.key
    }

    /// Escape during a drag: it changes nothing. True when a drag was cancelled.
    @discardableResult
    func cancel() -> Bool {
        guard dragged != nil, !cancelled else { return false }
        cancelled = true
        dragged = nil
        hovered = nil
        onActiveChange?(false)
        removeEscape()
        return true
    }

    /// True while a drag is on, or just after one: the row's own click must not open it.
    func consumesClick() -> Bool {
        if dragged != nil || cancelled { return true }
        guard let endedAt else { return false }
        return Date().timeIntervalSince(endedAt) < 0.3
    }

    private func finish() {
        let wasActive = dragged != nil
        dragged = nil
        hovered = nil
        endedAt = Date()
        // The gesture keeps reporting until the pointer goes up; only then may a new drag start.
        cancelled = false
        removeEscape()
        if wasActive { onActiveChange?(false) }
    }

    func accepts(_ target: HoldTarget, _ session: Session) -> Bool {
        switch target {
        case .segment, .waiting: return session.canHold
        case .pin: return !session.isHeld && !session.isPinned
        case .bringBack: return session.hold != nil
        }
    }

    private func installEscape() {
        removeEscape()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { self?.cancel() ?? false }
            return handled ? nil : event
        }
    }

    private func removeEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

private struct HoldTargetFrames: PreferenceKey {
    static var defaultValue: [HoldTarget: CGRect] = [:]
    static func reduce(value: inout [HoldTarget: CGRect], nextValue: () -> [HoldTarget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view as a drop target of the On hold drag.
    func holdTarget(_ target: HoldTarget) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: HoldTargetFrames.self,
                                   value: [target: proxy.frame(in: .named(HoldDragState.space))])
        })
    }

    /// The surface the drag happens in: the coordinate space, the targets'
    /// frames, and the chip that follows the pointer.
    func holdDragSurface(_ drag: HoldDragState, plan: HoldPlan) -> some View {
        coordinateSpace(name: HoldDragState.space)
            .onPreferenceChange(HoldTargetFrames.self) { frames in
                MainActor.assumeIsolated { drag.targets = frames }
            }
            .overlay(alignment: .topLeading) {
                if let session = drag.dragged {
                    HoldDragChip(session: session, readout: HoldText.readout(drag.hovered, plan: plan))
                        .offset(x: drag.location.x + 12, y: drag.location.y + 10)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Lets a session row be dragged onto the line, a day, Waiting, Pin or Bring back now.
    /// A session waiting for approval can't be held, so its row is not draggable.
    func holdDraggable(_ session: Session, drag: HoldDragState, drop: @escaping (Session, HoldTarget) -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(HoldDragState.space))
                .onChanged { value in
                    guard session.canHold else { return }
                    drag.changed(session, at: value.location)
                }
                .onEnded { value in
                    guard let landed = drag.ended(at: value.location) else { return }
                    drop(landed.session, landed.target)
                },
            including: session.canHold ? .all : .subviews
        )
    }
}

// MARK: - Words

enum HoldText {
    static let hint = "Drag a session onto a day"
    static let tooLate = "Too late for today. Pick a day."

    static func readout(_ target: HoldTarget?, plan: HoldPlan) -> String? {
        switch target {
        case .segment(let days)?:
            guard let segment = plan.segments.first(where: { $0.daysAhead == days }) else { return nil }
            return segment.dropDate.map(plan.backText) ?? "Too late today"
        case .waiting?: return "Waiting on…"
        case .pin?: return "Pin to Top"
        case .bringBack?: return "Bring back now"
        case nil: return nil
        }
    }

    /// "On hold until Thu 9:00 AM", "Waiting on Li · check back Thu 9:00 AM".
    static func status(_ hold: SessionHold, plan: HoldPlan) -> String {
        if hold.isWaiting {
            return "Waiting on \(hold.waitingName ?? "someone") · check back \(plan.when(hold.until))"
        }
        return "On hold until \(plan.when(hold.until))"
    }

    /// A state word inside a sentence: "NEEDS INPUT" becomes "Needs input".
    static func sentence(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst().lowercased()
    }
}

// MARK: - Commands

/// The click path for every drag: the same store commands from a row's menus.
struct HoldCommands {
    let session: Session
    let plan: HoldPlan
    let hold: (Date) -> Void
    let waiting: () -> Void
    let bringBack: () -> Void

    @MainActor init(session: Session, model: AppModel, onWaiting: @escaping (String) -> Void = { _ in }) {
        self.session = session
        plan = model.holdPlan
        let id = session.id
        hold = { model.hold(sessionId: id, until: $0) }
        waiting = { if model.holdWaiting(sessionId: id) { onWaiting(id) } }
        bringBack = { model.bringBack(sessionId: id) }
    }

    struct Choice: Identifiable {
        let title: String
        let date: Date
        var id: String { title }
    }

    /// Today (while it isn't too late), Tomorrow, and Friday or next Monday.
    var presets: [Choice] { plan.presets.map(choice) }
    var tomorrow: Choice { choice(.tomorrow) }

    private func choice(_ preset: HoldPlan.Preset) -> Choice {
        Choice(title: plan.title(for: preset), date: plan.date(for: preset))
    }
}

/// "Hold Until" with its choices, and "Bring Back Now" for a held session.
/// `flat` lists the choices directly, for a menu that already says Hold.
struct HoldMenuItems: View {
    let commands: HoldCommands
    var flat = false

    var body: some View {
        if commands.session.hold != nil {
            Button("Bring Back Now", systemImage: "arrow.uturn.up", action: commands.bringBack)
        }
        if commands.session.canHold {
            if flat {
                if commands.session.hold != nil { Divider() }
                choices
            } else {
                Menu { choices } label: { Label("Hold Until", systemImage: "clock") }
            }
        } else {
            Button("Hold Until", systemImage: "clock") {}
                .disabled(true)
                .help("Approvals can’t wait")
        }
    }

    @ViewBuilder private var choices: some View {
        ForEach(commands.presets) { preset in
            Button(preset.title) { commands.hold(preset.date) }
        }
        Divider()
        Button(commands.plan.title(for: .waiting), action: commands.waiting)
    }
}

/// The same choices as an AppKit menu, for the details flyout's action list.
@MainActor
enum HoldPopUp {
    static func show(_ commands: HoldCommands) {
        let menu = NSMenu()
        for preset in commands.presets {
            menu.addItem(ClosureMenuItem(title: preset.title) { commands.hold(preset.date) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: commands.plan.title(for: .waiting), handler: commands.waiting))
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

// MARK: - Row additions

/// Next to the state pill of a session that came back: "Back from hold" or
/// "Check back with Li", outlined. Goes away when the user opens it.
struct HoldReturnChip: View {
    let hold: SessionHold

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: hold.isWaiting ? "person" : "clock")
                .font(.system(size: 9, weight: .semibold))
            Text(hold.returnText).font(AppTypography.badge).lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.45), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Follows the pointer while dragging: the host icon, the title, and where it will go.
private struct HoldDragChip: View {
    let session: Session
    let readout: String?

    var body: some View {
        HStack(spacing: 6) {
            AppIcon(bundleId: Jumper.hostBundle(for: session))
                .scaleEffect(0.7)
                .frame(width: 18, height: 18)
            Text(session.currentTopicTitle)
                .font(AppTypography.section.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            if let readout {
                Text(readout)
                    .font(AppTypography.section)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }
}

/// A surface that floats over the list while a row is dragged.
private struct RaisedBackground: View {
    var hot = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hot ? 0.12 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(hot ? 0.4 : 0.14), lineWidth: 1))
    }
}

/// Above the list while dragging: "Pin to Top" for a row, "Bring back now" for a held session.
struct HoldTopTarget: View {
    @ObservedObject var drag: HoldDragState

    var body: some View {
        if let session = drag.dragged {
            let target: HoldTarget? = drag.accepts(.bringBack, session) ? .bringBack
                : (drag.accepts(.pin, session) ? .pin : nil)
            if let target {
                let hot = drag.hovered == target
                Label(target == .pin ? "Pin to Top" : "Bring back now",
                      systemImage: target == .pin ? "pin" : "arrow.uturn.up")
                    .font(AppTypography.section.weight(.semibold))
                    .foregroundStyle(hot ? Color.primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(RaisedBackground(hot: hot))
                    .holdTarget(target)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - The dock

/// "On hold": a line from now through next Monday, with a dot per held
/// session, the Waiting end cap, and a tray for the day that is open. Shared
/// by the menu panel and the floating window; it sits outside the scrolled
/// list. It is the quietest part of the panel: a section label and a grey
/// line, no card. Only what the user arranged (the dots) carries colour.
struct HoldDock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drag: HoldDragState
    let held: [Session]
    /// The floating window: narrower, smaller labels.
    var compact = false
    let open: (Session) -> Void
    let drop: (Session, HoldTarget) -> Void

    private var inset: CGFloat { compact ? 10 : 14 }

    var body: some View {
        let plan = model.holdPlan
        VStack(alignment: .leading, spacing: 0) {
            if held.isEmpty {
                // Nothing held: one line. While a row is dragged the line rises
                // over the end of the list instead of pushing it, so nothing
                // under the pointer moves and the panel keeps its height.
                header
                    .overlay(alignment: .bottom) {
                        if drag.isActive {
                            VStack(alignment: .leading, spacing: 0) {
                                header
                                line(plan)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .background(RaisedBackground().padding(.horizontal, 4))
                        }
                    }
            } else {
                header
                if let days = drag.openSegment {
                    let items = held.filter { Self.days($0, plan) == days }
                    if !items.isEmpty {
                        HoldTray(model: model, drag: drag, items: items, plan: plan, compact: compact,
                                 open: open, drop: drop)
                            .padding(.horizontal, inset - 6)
                    }
                }
                line(plan)
            }
        }
        .onChange(of: held.map(\.id)) { _, ids in
            // A tray closes once nothing is left in it.
            if let days = drag.openSegment, !held.contains(where: { Self.days($0, plan) == days }) {
                drag.openSegment = nil
            }
            if let editing = drag.editingWaitingID, !ids.contains(editing) { drag.editingWaitingID = nil }
        }
    }

    static func days(_ session: Session, _ plan: HoldPlan) -> Int {
        plan.segment(for: session.hold?.until ?? plan.now).daysAhead
    }

    private func line(_ plan: HoldPlan) -> some View {
        HoldLine(drag: drag, held: held, plan: plan, compact: compact, waitingTapped: {
            // The first waiting session's tray, or what the cap is for.
            if let first = held.first(where: { $0.hold?.isWaiting == true }) {
                let days = Self.days(first, plan)
                drag.openSegment = drag.openSegment == days ? nil : days
            } else {
                model.showHoldNote("Drag a session here when it waits on someone")
            }
        })
        .padding(.horizontal, inset - 4)
        .padding(.bottom, 5)
    }

    /// Same weight as "Pinned 2" and the other section labels. To its right:
    /// what just happened here, with Undo, or else how to use the line.
    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 10, weight: .medium))
            Text("On hold").font(AppTypography.section)
            if !held.isEmpty { Text("\(held.count)").font(AppTypography.elapsed) }
            Spacer(minLength: 8)
            if let message = model.message, model.messagePlace == .hold {
                Text(message)
                    .font(AppTypography.section)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if model.undo != nil {
                    Button("Undo") { model.performUndo() }
                        .buttonStyle(.plain)
                        .font(AppTypography.section.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            } else if !drag.isActive {
                Text(HoldText.hint)
                    .font(AppTypography.section)
                    .lineLimit(1)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, inset)
        .frame(height: 24)
        .accessibilityElement(children: .contain)
    }
}

/// The line itself: Today, the rest of the week, next Monday, and Waiting.
private struct HoldLine: View {
    @ObservedObject var drag: HoldDragState
    let held: [Session]
    let plan: HoldPlan
    let compact: Bool
    let waitingTapped: () -> Void

    static let height: CGFloat = 42
    /// The floating window needs drop targets at least this wide.
    static let minimumDay: CGFloat = 40

    var body: some View {
        let segments = plan.segments
        let cap: CGFloat = compact ? 44 : 50
        GeometryReader { proxy in
            let available = max(1, proxy.size.width - cap - 4)
            let others = CGFloat(segments.count - 1)
            // Today is wider than a day; in a narrow window it gives up width
            // first, so every day keeps a target of at least 40 pt.
            let todayWeight = compact ? max(1, min(1.8, available / Self.minimumDay - others)) : 1.8
            let unit = available / (todayWeight + others)
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    HoldSegmentView(drag: drag, segment: segment, plan: plan,
                                    items: held.filter { HoldDock.days($0, plan) == segment.daysAhead })
                        .frame(width: segment.isToday ? unit * todayWeight : unit)
                }
                Spacer(minLength: 4)
                waitingCap.frame(width: cap)
            }
        }
        .frame(height: Self.height)
    }

    private var waitingCap: some View {
        let hot = drag.hovered == .waiting
        let count = held.filter { $0.hold?.isWaiting == true }.count
        return VStack(spacing: 2) {
            Image(systemName: count > 0 ? "person.fill" : "person").font(.system(size: 11, weight: .medium))
                .frame(height: 16)
            Text("Waiting").font(.system(size: compact ? 10 : 10.5, weight: count > 0 ? .semibold : .regular))
        }
        .foregroundStyle(drag.isActive || count > 0 ? Color.primary : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A plain grey well: a place to drop, not a button and not "unknown".
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hot ? 0.16 : (drag.isActive ? 0.08 : 0.04))))
        .contentShape(Rectangle())
        .onTapGesture(perform: waitingTapped)
        .holdTarget(.waiting)
        .help("Drop here when it waits on someone; check back in two days")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting on someone, \(count) session\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, waitingTapped)
    }
}

private struct HoldSegmentView: View {
    @ObservedObject var drag: HoldDragState
    let segment: HoldPlan.Segment
    let plan: HoldPlan
    let items: [Session]

    private var isOpen: Bool { drag.openSegment == segment.daysAhead && !items.isEmpty }
    private var hot: Bool { drag.hovered == .segment(segment.daysAhead) }
    /// Today late in the evening: shown, but nothing can be dropped on it.
    private var closed: Bool { segment.dropDate == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            axis.frame(height: 14)
            Text(segment.label)
                .font(.system(size: 11, weight: items.isEmpty ? .regular : .semibold))
                .foregroundStyle(items.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .padding(.leading, 4)
            Text(sub)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.leading, 4)
                .frame(height: 13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        // The open day is marked by a thin rule under it, not a filled tab.
        .overlay(alignment: .bottom) {
            if isOpen {
                Capsule().fill(Color.primary.opacity(0.55)).frame(height: 1.5).padding(.horizontal, 4)
            }
        }
        .opacity(drag.isActive && closed ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .holdTarget(.segment(segment.daysAhead))
        .help(items.isEmpty ? "" : "Show what comes back here")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On hold, \(segment.label), \(items.count) session\(items.count == 1 ? "" : "s")")
        .accessibilityAddTraits(items.isEmpty ? [] : .isButton)
        .accessibilityValue(isOpen ? "Expanded" : "")
        .accessibilityAction(.default, toggle)
    }

    private func toggle() {
        guard !items.isEmpty else { return }
        drag.openSegment = isOpen ? nil : segment.daysAhead
    }

    private var fill: Color {
        if hot { return Color.primary.opacity(closed ? 0.05 : 0.16) }
        return drag.isActive ? Color.primary.opacity(0.04) : .clear
    }

    /// Under the label, whether or not the tray is open: who it waits on, or
    /// when the first one is back. A date that isn't this stretch's own day
    /// (a Saturday before Monday) names its day.
    private var sub: String {
        if drag.isActive, closed { return "too late" }
        let names = items.compactMap(\.hold).filter(\.isWaiting).map { $0.waitingName ?? "someone" }
        if !names.isEmpty { return names.joined(separator: ", ") }
        guard let first = items.first?.hold?.until else { return "" }
        if segment.isToday { return plan.time(first) }
        if !plan.isOnLabelledDay(first) {
            return plan.isBeyondLine(first) ? "and later" : "from \(plan.dayName(daysAhead: plan.daysAhead(of: first)))"
        }
        return ""
    }

    private var axis: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, mid = proxy.size.height / 2
            ZStack(alignment: .topLeading) {
                if segment.isNextWeek {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: mid))
                        path.addLine(to: CGPoint(x: width, y: mid))
                    }
                    .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.45))
                        .frame(width: width, height: 1.5)
                        .offset(y: mid - 0.75)
                }
                // Each day starts with a small tick; Today starts with "now".
                Rectangle().fill(Color.primary.opacity(segment.isToday ? 0.8 : 0.3))
                    .frame(width: segment.isToday ? 3 : 1, height: segment.isToday ? 12 : 7)
                    .offset(y: mid - (segment.isToday ? 6 : 3.5))
                let shown = Array(items.prefix(4))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                    HoldDot(session: session)
                        .position(x: Self.dotX(fraction(session, index: index, in: shown), width: width), y: mid)
                }
                if items.count > 4 {
                    Text("+\(items.count - 4)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .position(x: width - 8, y: mid - 9)
                }
            }
        }
    }

    /// A dot never touches the "now" bar or the next day's tick: it must read
    /// as later, not as due.
    static func dotX(_ fraction: CGFloat, width: CGFloat) -> CGFloat {
        let low: CGFloat = 13, high = max(13, width - 8)
        return min(high, max(low, fraction * width))
    }

    private func fraction(_ session: Session, index: Int, in shown: [Session]) -> CGFloat {
        guard let until = session.hold?.until else { return 0.5 }
        if segment.isToday {
            let end = max(plan.now.addingTimeInterval(4 * 3600), endOfToday)
            return CGFloat(until.timeIntervalSince(plan.now) / max(1, end.timeIntervalSince(plan.now)))
        }
        if segment.isNextWeek {
            // The dashed part is the weekend; Monday itself is at the far end.
            let weekend = shown.filter { !plan.isOnLabelledDay($0.hold?.until ?? until) }
            if let place = weekend.firstIndex(where: { $0.id == session.id }) {
                return Self.spread(place, of: weekend.count, from: 0.2, to: 0.55)
            }
            let monday = shown.filter { plan.isOnLabelledDay($0.hold?.until ?? until) }
            let place = monday.firstIndex(where: { $0.id == session.id }) ?? 0
            return Self.spread(place, of: monday.count, from: 0.72, to: 0.92)
        }
        return Self.spread(index, of: shown.count, from: 0.3, to: 0.8)
    }

    static func spread(_ index: Int, of count: Int, from: CGFloat, to: CGFloat) -> CGFloat {
        count <= 1 ? (from + to) / 2 : from + CGFloat(index) * (to - from) / CGFloat(count - 1)
    }

    private var endOfToday: Date {
        plan.calendar.date(bySettingHour: HoldPlan.eveningHour, minute: 0, second: 0, of: plan.now) ?? plan.now
    }
}

/// One held session on the line, in its tool's colour; a ring when it waits on someone.
private struct HoldDot: View {
    let session: Session

    var body: some View {
        let color = Palette.tool(session.tool)
        Group {
            if session.hold?.isWaiting == true {
                Circle().strokeBorder(color, lineWidth: 2)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 11, height: 11)
        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
        .help(session.currentTopicTitle)
    }
}

// MARK: - Tray

private struct HoldTray: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drag: HoldDragState
    let items: [Session]
    let plan: HoldPlan
    let compact: Bool
    let open: (Session) -> Void
    let drop: (Session, HoldTarget) -> Void

    static let rowHeight: CGFloat = 38
    /// More rows than this scroll inside the tray, so a busy day still fits a short screen.
    static let visibleRows = 4

    var body: some View {
        if items.count > Self.visibleRows {
            ScrollView(.vertical) { rows }
                .frame(height: Self.rowHeight * (CGFloat(Self.visibleRows) + 0.5))
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(items) { session in
                HoldTrayRow(model: model, drag: drag, session: session, plan: plan, compact: compact,
                            open: { open(session) })
                    .frame(height: Self.rowHeight)
                    .holdDraggable(session, drag: drag, drop: drop)
            }
        }
    }
}

/// A held session: its title and, always, when it comes back. The time is the
/// control: click it to move the hold or bring the session back now. Clicking
/// the row opens the session and keeps the hold.
private struct HoldTrayRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drag: HoldDragState
    let session: Session
    let plan: HoldPlan
    let compact: Bool
    let open: () -> Void
    @State private var name = ""
    @State private var hovering = false
    @FocusState private var nameFocused: Bool

    private var editing: Bool { drag.editingWaitingID == session.id }
    private var commands: HoldCommands { HoldDrop.commands(session, model: model, drag: drag) }

    var body: some View {
        let hold = session.hold ?? SessionHold(until: model.now, heldAt: model.now)
        HStack(spacing: 8) {
            AppIcon(bundleId: Jumper.hostBundle(for: session))
                .scaleEffect(0.77)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.currentTopicTitle)
                    .font(compact ? AppTypography.body.weight(.semibold) : AppTypography.rowTitle)
                    .lineLimit(1)
                detail(hold)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            whenMenu(hold)
        }
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !drag.consumesClick(), !editing else { return }
            open()
        }
        .contextMenu {
            Button(Jumper.openLabel(for: session), action: open)
            HoldMenuItems(commands: commands)
            Divider()
            Button("Remove from List") { model.remove(sessionId: session.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.currentTopicTitle), \(HoldText.status(hold, plan: plan)), \(RunText.stateWord(session, now: model.now))")
        .accessibilityAction(named: "Open", open)
        .accessibilityAction(named: "Bring Back Now") { model.bringBack(sessionId: session.id) }
    }

    /// Second line: who it waits on (click to name), and its real state in words.
    @ViewBuilder private func detail(_ hold: SessionHold) -> some View {
        let state = HoldText.sentence(RunText.stateWord(session, now: model.now))
        HStack(spacing: 4) {
            if hold.isWaiting {
                Image(systemName: "person").font(.system(size: 9, weight: .medium))
                if editing {
                    TextField("who or what", text: $name)
                        .textFieldStyle(.plain)
                        .font(AppTypography.section)
                        .foregroundStyle(.primary)
                        .frame(width: compact ? 90 : 120)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .onAppear {
                            name = hold.waitingName ?? ""
                            // The floating window doesn't take the keyboard by itself.
                            drag.requestKeyboard?()
                            DispatchQueue.main.async { nameFocused = true }
                        }
                        .onChange(of: nameFocused) { _, focused in if !focused { commit() } }
                        .accessibilityLabel("Waiting on whom")
                } else {
                    Text(hold.waitingName ?? "name who…")
                        .underline(hold.waitingName == nil, pattern: .dot)
                        .lineLimit(1)
                        .onTapGesture { drag.editingWaitingID = session.id }
                        .help("Name who or what this waits on")
                    Text("·")
                }
            }
            if !editing { Text(state).lineLimit(1) }
        }
        .font(AppTypography.section)
        .foregroundStyle(.secondary)
    }

    /// "3:00 PM ⌄", "Sat 9:00 AM ⌄": when it comes back, and the menu to change that.
    private func whenMenu(_ hold: SessionHold) -> some View {
        Menu {
            HoldMenuItems(commands: commands, flat: true)
            if hold.isWaiting {
                Button("Name Who It Waits On…") { drag.editingWaitingID = session.id }
            }
        } label: {
            HStack(spacing: 3) {
                Text(plan.returnText(hold.until)).font(AppTypography.elapsed)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .semibold))
            }
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(HoldText.status(hold, plan: plan)). Click to change.")
        .accessibilityLabel("Back \(plan.when(hold.until)). Change")
    }

    private func commit() {
        guard editing else { return }
        model.setWaitingName(sessionId: session.id, name)
        drag.editingWaitingID = nil
    }
}

// MARK: - Drops

/// What letting go on a target does. Every target calls the same model
/// commands as the menus, so the store applies one set of rules.
@MainActor
enum HoldDrop {
    static func perform(_ target: HoldTarget, session: Session, model: AppModel, drag: HoldDragState) {
        let plan = model.holdPlan
        switch target {
        case .segment(let days):
            guard let segment = plan.segments.first(where: { $0.daysAhead == days }) else { return }
            guard let date = segment.dropDate else { return model.showHoldNote(HoldText.tooLate) }
            model.hold(sessionId: session.id, until: date)
        case .waiting:
            guard model.holdWaiting(sessionId: session.id) else { return }
            editWaiting(session.id, model: model, drag: drag)
        case .pin:
            if model.store.sessions[session.id]?.isPinned == false { model.toggleSessionPin(session.id) }
        case .bringBack:
            model.bringBack(sessionId: session.id)
        }
    }

    /// Opens the tray where the waiting session sits and asks "who or what"
    /// in this window, the one the user acted in. The name is optional.
    static func editWaiting(_ id: String, model: AppModel, drag: HoldDragState) {
        guard let until = model.store.sessions[id]?.hold?.until else { return }
        drag.openSegment = model.holdPlan.segment(for: until).daysAhead
        drag.editingWaitingID = id
    }

    static func commands(_ session: Session, model: AppModel, drag: HoldDragState) -> HoldCommands {
        HoldCommands(session: session, model: model) { id in editWaiting(id, model: model, drag: drag) }
    }
}

extension View {
    /// VoiceOver and keyboard users reach the same Hold commands without
    /// dragging. Each action is offered only while it can do something.
    @ViewBuilder func holdAccessibilityActions(_ commands: HoldCommands?) -> some View {
        if let commands, commands.session.canHold || commands.session.hold != nil {
            let tomorrow = commands.tomorrow
            let canHold = commands.session.canHold, held = commands.session.hold != nil
            if canHold, held {
                accessibilityAction(named: Text("Hold Until \(tomorrow.title)")) { commands.hold(tomorrow.date) }
                    .accessibilityAction(named: Text("Bring Back Now"), commands.bringBack)
            } else if canHold {
                accessibilityAction(named: Text("Hold Until \(tomorrow.title)")) { commands.hold(tomorrow.date) }
            } else {
                accessibilityAction(named: Text("Bring Back Now"), commands.bringBack)
            }
        } else {
            self
        }
    }
}
