import AIRunsCore
import AppKit
import SwiftUI

// MARK: - Session row

/// A run's host icon, title, state, readable activity and observed history.
/// Source/project metadata stays in the details; repository overlap stays visible.
struct SessionRow: View {
    let session: Session
    let lifeline: [ActivitySpan]
    let completedWorkDuration: TimeInterval?
    let now: Date
    /// Titles of other runs working in the same repository right now.
    var alsoHere: [String] = []
    @ObservedObject var ui: PanelUIState
    let rename: () -> Void
    let togglePin: () -> Void
    let details: () -> Void
    let remove: () -> Void
    /// "Ignore for Now" or "Stop Ignoring"; nil when this run can't be ignored.
    var ignore: (() -> Void)? = nil
    let open: () -> Void

    private var key: PanelUIState.Target { .session(session.id) }
    private var highlighted: Bool { ui.hover == key }
    private var workDuration: String? { completedWorkDuration.map(RunText.workDuration) }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                AppIcon(bundleId: Jumper.hostBundle(for: session))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(session.currentTopicTitle)
                            .font(AppTypography.rowTitle)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        // Always reserved, so nothing moves when the × appears.
                        Color.clear.frame(width: RemoveZone.slot + SessionRowControls.width, height: 18)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatePill(session: session, now: now)
                        if session.hasUnreadReply { UnreadReplyLabel() }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        LiveLine(session: session, now: now)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let workDuration {
                            Text("Worked \(workDuration)")
                                .font(AppTypography.elapsed)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .help("Observed working time in the last completed turn")
                        } else if !session.isDone && session.state != .needsApproval && session.outcome != .needsInput {
                            LifelineView(spans: lifeline, now: now, color: Palette.tool(session.tool))
                                .frame(width: LifelineView.compactWidth, height: 9)
                                .help("Observed activity over the last hour")
                        }
                    }
                    .padding(.top, 2)
                    if let warning = RunText.alsoHere(alsoHere) {
                        Label(warning, systemImage: "arrow.triangle.branch")
                            .font(AppTypography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(highlighted ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if highlighted {
                RemoveZone(label: "Remove \(session.currentTopicTitle) from the list", action: remove)
                    .padding(.top, 6 + 9 - RemoveZone.size.height / 2)
                    .padding(.trailing, SessionRowControls.width + 8 + RemoveZone.slot / 2 - RemoveZone.size.width / 2)
            }
        }
        .contextMenu {
            Button("Open", action: open)
            if let ignore { Button(RunText.ignoreTitle(session), action: ignore) }
            Button("Rename…", action: rename)
            Button(SessionRowControls.pinTitle(session), action: togglePin)
            Divider()
            Button("Remove from List", action: remove)
        }
        .onHover { inside in inside ? ui.hoverOn(key) : ui.hoverOff() }
        .help(RunText.place(session))
        .reportFrame(key.key)
        .accessibilityElement(children: .ignore)
        .accessibilityAction(named: "Remove from List", remove)
        .accessibilityAction(named: Text(SessionRowControls.pinTitle(session)), togglePin)
        .accessibilityLabel("\(session.currentTopicTitle), \(RunText.place(session)), \(RunText.stateWord(session, now: now)), \(RunText.stateTime(session, now: now)). \(RunText.rowActivity(session, now: now))\(workDuration.map { ". Observed working time, \($0)" } ?? "")\(RunText.alsoHere(alsoHere).map { ". \($0)" } ?? "")")
        .accessibilityValue(session.hasUnreadReply ? "New reply" : "")
        .accessibilityAddTraits(.isButton)
        .overlay(alignment: .topTrailing) {
            SessionRowControls(session: session, togglePin: togglePin, details: details)
                .padding(.trailing, 8)
                .padding(.top, 4)
        }
    }
}

struct UnreadReplyLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.primary).frame(width: 5, height: 5)
            Text("New reply").font(AppTypography.section)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SessionRowControls: View {
    static let width: CGFloat = 50
    let session: Session
    let togglePin: () -> Void
    let details: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            control("ellipsis", label: "Details", id: "details", action: details)
            control(session.isPinned ? "pin.fill" : "pin", label: Self.pinTitle(session), id: "pin", action: togglePin)
        }
    }

    private func control(_ image: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(AppTypography.controlIcon)
                .foregroundStyle(.secondary)
                .frame(width: Self.width / 2, height: 23)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("session.\(session.id).\(id)")
    }

    static func pinTitle(_ session: Session) -> String { session.isPinned ? "Unpin" : "Pin to Top" }
}

/// Words shared by the row, the flyout and VoiceOver.
enum RunText {
    @MainActor static func place(_ session: Session) -> String {
        var parts: [String]
        if session.isProjectConversation {
            parts = ["Claude project"]
            if session.projectMainId != nil { parts.append("Main conversation") }
        } else if let host = Jumper.hostName(for: session) {
            if (session.tool == .claudeCode && host == "Claude") || (session.tool == .codex && host == "Codex") {
                parts = ["\(host) app"]
            } else {
                parts = [session.tool.displayName, host]
            }
        } else {
            parts = [session.tool.displayName]
        }
        if !session.project.isEmpty { parts.append(session.project) }
        if let driver = session.drivenBy { parts.append("via \(driver)") }
        return parts.joined(separator: " · ")
    }

    /// "Also running here: Fix login" or "Also running here: Fix login and 2 more".
    static func alsoHere(_ titles: [String]) -> String? {
        guard let first = titles.first else { return nil }
        let rest = titles.count - 1
        return "Also running here: " + (rest == 0 ? first : "\(first) and \(rest) more")
    }

    /// "Seen in Claude just now", "Seen in Claude 3m ago".
    static func seen(_ native: NativeSighting, now: Date) -> String {
        let age = now.timeIntervalSince(native.seenAt)
        return age < 60 ? "Seen in Claude just now" : "Seen in Claude \(TextUtils.duration(age)) ago"
    }

    /// A question or a reply can be ignored; an approval request can't.
    static func canIgnore(_ session: Session) -> Bool { session.state == .yourTurn && session.waitsOnUser }
    static func ignoreTitle(_ session: Session) -> String { session.isIgnored ? "Stop Ignoring" : "Ignore for Now" }

    static func stateWord(_ session: Session, now: Date) -> String {
        if session.isIgnored { return "IGNORED" }
        // A thread known only from Claude's Threads list keeps Claude's own word.
        if let native = session.native { return native.stale == true ? "LAST SEEN" : native.state.word }
        switch session.state {
        case .unknown: return "STATE UNKNOWN"
        case .needsApproval: return "APPROVE"
        case .yourTurn:
            switch session.outcome {
            case .needsInput: return "NEEDS INPUT"
            case .done: return "DONE"
            default: return "REPLIED"
            }
        case .working:
            if (session.scheduled ?? 0) > 0, (session.backgroundTasks ?? 0) == 0 { return "SCHEDULED" }
            if session.isInBackground { return "BACKGROUND" }
            return session.isQuiet(now: now) ? "NO UPDATE" : "WORKING"
        }
    }

    static func workDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds))s" }
        return TextUtils.duration(seconds)
    }

    static func stateTime(_ session: Session, now: Date) -> String {
        guard session.state != .unknown else { return "" }
        if session.state.needsUser {
            return TextUtils.duration(now.timeIntervalSince(session.waitingSince ?? session.lastEventAt))
        }
        if session.isQuiet(now: now) { return TextUtils.duration(now.timeIntervalSince(session.lastEventAt)) }
        return TextUtils.duration(now.timeIntervalSince(session.turnStartedAt))
    }

    static func liveText(_ session: Session, now: Date) -> String {
        if let native = session.native {
            if session.nativeView?.isOpen == true {
                let age = max(0, now.timeIntervalSince(native.seenAt))
                let when = age < 60 ? "just now" : "\(TextUtils.duration(age)) ago"
                return "Open in Claude · state \(native.stale == true ? "last seen" : "seen") \(when)"
            }
            return native.stale == true ? "State unknown · show its Threads list in Claude to refresh" : seen(native, now: now)
        }
        if session.state == .unknown {
            guard let view = session.nativeView else { return "State unavailable" }
            let age = max(0, now.timeIntervalSince(view.seenAt))
            let when = age < 60 ? "just now" : "\(TextUtils.duration(age)) ago"
            return view.isOpen ? "Open in Claude · seen \(when)" : "Seen in Claude \(when) · state unavailable"
        }
        let detail = stateDetail(session, now: now)
        return session.nativeView?.isOpen == true ? "Open in Claude · \(detail)" : detail
    }

    /// Main-menu summary; raw activity remains available in the flyout.
    static func rowActivity(_ session: Session, now: Date) -> String {
        guard session.native == nil, session.state == .working,
              !session.isInBackground, !session.isQuiet(now: now) else {
            return liveText(session, now: now)
        }
        let detail: String
        if case .progress(let plan) = CompactRunDetail.resolve(session, now: now) {
            detail = RunProgress(done: plan.done, total: plan.total,
                                 current: readableActivity(plan.current)).summary
        } else {
            detail = readableActivity(session.activity) ?? "Working"
        }
        return session.nativeView?.isOpen == true ? "Open in Claude · \(detail)" : detail
    }

    private static func readableActivity(_ activity: String?) -> String? {
        guard let text = activity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.hasPrefix("mcp__") || text.hasPrefix("functions.") { return nil }
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        let identifier = parts.count == 1 ? parts.first
            : (parts.count == 2 && parts[0] == "Using" ? parts.last : nil)
        if let identifier, identifier.contains("_") || identifier.contains(".") { return nil }
        return text
    }

    private static func stateDetail(_ session: Session, now: Date) -> String {
        switch session.state {
        case .unknown:
            return "State unavailable"
        case .needsApproval:
            return "Wants to run " + (session.approvalDetail ?? "a tool")
        case .yourTurn:
            if session.outcome == .needsInput, let question = session.approvalDetail { return question }
            return TextUtils.preview(of: session.lastMessage, limit: 90) ?? "Finished its turn"
        case .working:
            if (session.scheduled ?? 0) > 0, (session.backgroundTasks ?? 0) == 0 {
                return "Scheduled a wake-up · continues by itself"
            }
            if session.isInBackground {
                let tasks = session.backgroundTasks ?? 1
                return "Waiting on \(tasks) background task\(tasks == 1 ? "" : "s") · continues by itself"
            }
            if session.isQuiet(now: now) { return "No events for a while — it may have stopped" }
            return session.activity ?? "Working"
        }
    }
}

struct StatePill: View {
    let session: Session
    let now: Date

    var body: some View {
        let tint = Palette.tool(session.tool)
        // Solid = needs you, light fill = replied, outline = working, grey = the rest.
        let stale = session.native?.stale == true
        let style: (fill: Color, text: Color, outline: Bool) = {
            if stale { return (.clear, .secondary, false) }
            if session.isIgnored { return (Color.primary.opacity(0.07), .secondary, false) }
            switch session.state {
            case .unknown: return (Color.primary.opacity(0.07), .secondary, false)
            case .needsApproval: return (tint, Palette.onTool(session.tool), false)
            case .yourTurn:
                switch session.outcome {
                case .needsInput: return (tint, Palette.onTool(session.tool), false)
                case .done: return (Color.primary.opacity(0.07), .secondary, false)
                default: return (tint.opacity(0.16), tint, false)
                }
            case .working:
                if session.isInBackground || session.isQuiet(now: now) { return (Color.primary.opacity(0.07), .secondary, false) }
                return (.clear, tint, true)
            }
        }()
        HStack(spacing: 5) {
            if session.isDone, session.native == nil {
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy))
            }
            Text(RunText.stateWord(session, now: now))
                .font(AppTypography.badge)
                .tracking(0.2)
            if session.state != .unknown {
                Text(RunText.stateTime(session, now: now))
                    .font(AppTypography.elapsed)
            }
        }
        .foregroundStyle(style.text)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(style.fill))
        .overlay(Capsule().strokeBorder(style.outline ? style.text : .clear, lineWidth: 1))
        // Dashed: AI Runs no longer knows this thread's state.
        .overlay(Capsule().strokeBorder(stale ? Color.secondary : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .fixedSize()
    }
}

/// The third line: the step bar, the current action, or the command it wants to run.
struct LiveLine: View {
    let session: Session
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            if session.native != nil || session.state == .unknown {
                Text(RunText.liveText(session, now: now)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                hookLine
            }
        }
        .font(AppTypography.body)
    }

    @ViewBuilder private var hookLine: some View {
            switch session.state {
            case .unknown:
                Text(RunText.liveText(session, now: now)).foregroundStyle(.secondary).lineLimit(1)
            case .needsApproval:
                if case .approval(let action) = CompactRunDetail.resolve(session, now: now) {
                    Text("Allow: \(action)").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Waiting for approval").foregroundStyle(.secondary).lineLimit(1)
                }
            case .yourTurn:
                if session.outcome == .needsInput {
                    Text(session.outcomeSource == .asked ? "asks" : "asks you").foregroundStyle(.secondary)
                    Text(RunText.liveText(session, now: now)).lineLimit(1)
                } else {
                    Text(RunText.liveText(session, now: now)).foregroundStyle(.secondary).lineLimit(1)
                }
            case .working:
                Text(RunText.rowActivity(session, now: now))
                    .foregroundStyle(session.isInBackground || session.isQuiet(now: now) ? .secondary : .primary)
                    .lineLimit(1)
            }
    }
}

/// Small segments, one per step: "▮▮▮▯▯▯▯ 3/7".
struct StepsBar: View {
    let progress: RunProgress
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            // Long plans collapse into one bar so the line never overflows.
            if progress.total <= 12 {
                ForEach(0..<progress.total, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < progress.done ? color : Color.primary.opacity(0.15))
                        .frame(width: 8, height: 5)
                }
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(color).frame(width: proxy.size.width * CGFloat(progress.done) / CGFloat(max(1, progress.total)))
                    }
                }
                .frame(width: 60, height: 5)
            }
            Text("\(progress.done)/\(progress.total)")
                .font(AppTypography.elapsed)
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
        }
        .fixedSize()
        .accessibilityLabel("\(progress.done) of \(progress.total) steps done")
    }
}

/// A run's last hour drawn like a sequence-diagram lifeline: a dashed line,
/// with a bar wherever it was working (blue), waiting on you (orange), or
/// running in the background (grey). The tick on the right is now.
struct LifelineView: View {
    let spans: [ActivitySpan]
    let now: Date
    /// The tool's colour: solid while working, faded and outlined while it
    /// waits on the user, grey in the background.
    let color: Color
    static let compactWidth: CGFloat = 104

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 0, y: mid))
            line.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(line, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

            let window = SessionStore.lifelineWindow
            let start = now.addingTimeInterval(-window)
            for span in spans {
                let from = max(span.start, start), to = min(span.end(or: now), now)
                guard to > from else { continue }
                let x = CGFloat(from.timeIntervalSince(start) / window) * size.width
                let width = max(2, CGFloat(to.timeIntervalSince(from) / window) * size.width)
                let rect = CGRect(x: x, y: mid - 3.5, width: width, height: 7)
                let shape = Path(roundedRect: rect, cornerRadius: 2)
                switch span.kind {
                case .working:
                    context.fill(shape, with: .color(color))
                case .waiting:
                    context.fill(shape, with: .color(color.opacity(0.28)))
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2),
                                   with: .color(color), lineWidth: 1)
                case .background:
                    context.fill(shape, with: .color(.secondary.opacity(0.45)))
                }
            }
            let tick = CGRect(x: size.width - 1.5, y: 0, width: 1.5, height: size.height)
            context.fill(Path(roundedRect: tick, cornerRadius: 0.75), with: .color(.primary.opacity(0.5)))
        }
        .accessibilityHidden(true)
    }
}

/// The icon of the app the session runs in, as the Mac draws it.
struct AppIcon: View {
    let bundleId: String?

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private var image: NSImage? {
        guard let bundleId else { return nil }
        if let cached = Self.cache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache[bundleId] = icon
        return icon
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.1))
                    .overlay(Image(systemName: "terminal").font(AppTypography.section).foregroundStyle(.secondary))
                    .padding(2)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

// MARK: - Header dashboard

/// Counts, a two-hour histogram of agent work stacked with time spent waiting
/// on the user, and today's numbers.
struct HeaderDashboard: View {
    let needs: Int
    let working: Int
    let stats: ActivityStats

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .bottom, spacing: 18) {
                Metric(value: needs, label: "need you", color: needs > 0 ? .primary : .secondary)
                Metric(value: working, label: "working", color: working > 0 ? .primary : .secondary)
                Metric(value: stats.sessionsToday, label: "today", color: .primary)
                Spacer(minLength: 0)
                Histogram(buckets: stats.toolBuckets)
            }
            todayLine
        }
    }

    @ViewBuilder private var todayLine: some View {
        let waited = TextUtils.duration(stats.waitedToday)
        HStack(spacing: 0) {
            Text("Agents waited on you ")
            Text(waited == "now" ? "0m" : waited)
                .font(AppTypography.elapsed)
                .foregroundStyle(stats.waitedToday >= 60 ? Color.primary : .secondary)
            Text(" today")
            if let average = stats.averageReply {
                Text(" · you replied in ")
                Text(Self.short(average))
                    .font(AppTypography.elapsed)
                    .foregroundStyle(.primary)
                Text(" on average")
            }
        }
        .font(AppTypography.metadata)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// "45s", "1m 40s", "12m".
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 60)m"
    }
}

private struct Metric: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)")
                .font(AppTypography.metric)
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(AppTypography.section)
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Minutes agents worked in each slice of the last two hours, Claude and
/// Codex stacked in their own colours.
private struct Histogram: View {
    let buckets: [(claude: Double, codex: Double)]

    var body: some View {
        let peak = max(1, buckets.map { $0.claude + $0.codex }.max() ?? 1)
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(buckets.indices, id: \.self) { index in
                    let bucket = buckets[index]
                    VStack(spacing: 1) {
                        if bucket.codex > 0 {
                            Rectangle().fill(Palette.codex)
                                .frame(height: max(1.5, 32 * bucket.codex / peak))
                        }
                        if bucket.claude > 0 {
                            Rectangle().fill(Palette.claude)
                                .frame(height: max(1.5, 32 * bucket.claude / peak))
                        }
                        if bucket.claude + bucket.codex == 0 {
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1.5)
                        }
                    }
                    .frame(width: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                }
            }
            .frame(height: 34, alignment: .bottom)
            HStack {
                Text("−2h")
                Spacer()
                Text("−1h")
                Spacer()
                Text("now")
            }
            .font(AppTypography.elapsed)
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Agent activity over the last two hours, Claude and Codex")
    }
}

struct SectionLabel: View {
    let title: String
    let count: Int
    var showsTimeScale = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(AppTypography.section)
            Text("\(count)").font(AppTypography.elapsed)
            if showsTimeScale {
                Spacer(minLength: 4)
                LifelineTimeScale()
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 14)
        .padding(.trailing, 13)
        .padding(.top, 7)
        .padding(.bottom, 1)
    }
}

private struct LifelineTimeScale: View {
    private let minutes = Int(SessionStore.lifelineWindow / 60)

    var body: some View {
        HStack(spacing: 5) {
            Text("−\(minutes)m")
            Spacer(minLength: 0)
            Image(systemName: "arrow.right")
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Text("Now")
        }
        .font(AppTypography.section)
        .frame(width: LifelineView.compactWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity timeline, \(minutes) minutes ago to now")
    }
}

/// A small grey × that appears on the hovered row.
struct RemoveButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.16 : 0.08)))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove from list")
        .accessibilityLabel(label)
    }
}

/// The × plus a margin around it that swallows clicks, so a near miss does
/// nothing instead of opening the session.
struct RemoveZone: View {
    static let slot: CGFloat = 20
    static let size = CGSize(width: 40, height: 34)
    let label: String
    let action: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
            RemoveButton(label: label, action: action)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
