import AIRunsCore
import AppKit
import SwiftUI

// MARK: - Session row

/// One run: where it lives (app icon + words), its state as a word with a
/// time, what it is doing now, and its last hour as a lifeline. Everything
/// important is visible without hovering; hovering adds the details flyout.
struct SessionRow: View {
    let session: Session
    let lifeline: [ActivitySpan]
    let now: Date
    /// Titles of other runs working in the same repository right now.
    var alsoHere: [String] = []
    @ObservedObject var ui: PanelUIState
    let rename: () -> Void
    let pin: () -> Void
    let remove: () -> Void
    let open: () -> Void

    private var key: PanelUIState.Target { .session(session.id) }
    private var highlighted: Bool { ui.hover == key }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                AppIcon(bundleId: Jumper.hostBundle(for: session))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        StatePill(session: session, now: now)
                        // Always reserved, so nothing moves when the × appears.
                        Color.clear.frame(width: RemoveZone.slot, height: 18)
                    }
                    Text(RunText.place(session))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        LiveLine(session: session, now: now)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LifelineView(spans: lifeline, now: now, color: Palette.tool(session.tool))
                            .frame(width: 104, height: 9)
                    }
                    .padding(.top, 2)
                    if let warning = RunText.alsoHere(alsoHere) {
                        Label(warning, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(highlighted ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if highlighted {
                RemoveZone(label: "Remove \(session.title) from the list", action: remove)
                    .padding(.top, 7 + 9 - RemoveZone.size.height / 2)
                    .padding(.trailing, 8 + RemoveZone.slot / 2 - RemoveZone.size.width / 2)
            }
        }
        .contextMenu {
            Button("Open", action: open)
            Button("Rename…", action: rename)
            Button("Pin to Board", action: pin)
            Divider()
            Button("Remove from List", action: remove)
        }
        .onHover { inside in inside ? ui.hoverOn(key) : ui.hoverOff() }
        .reportFrame(key.key)
        .accessibilityElement(children: .ignore)
        .accessibilityAction(named: "Remove from List", remove)
        .accessibilityLabel("\(session.title), \(RunText.place(session)), \(RunText.stateWord(session, now: now)), \(RunText.stateTime(session, now: now)). \(RunText.liveText(session, now: now))\(RunText.alsoHere(alsoHere).map { ". \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// Words shared by the row, the flyout and VoiceOver.
enum RunText {
    static func place(_ session: Session) -> String {
        var host = session.terminal.appName
        if session.tool == .codex, session.terminal.bundleId == nil, session.terminal.termProgram == nil,
           session.terminal.tty == nil {
            host = "Codex"
        }
        var parts: [String]
        if session.tool.isWeb {
            parts = [session.tool.displayName, host]
        } else if (session.tool == .claudeCode && host == "Claude") || (session.tool == .codex && host == "Codex") {
            parts = ["\(host) app"]
        } else {
            parts = [session.tool.displayName, host]
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

    static func stateWord(_ session: Session, now: Date) -> String {
        switch session.state {
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

    static func stateTime(_ session: Session, now: Date) -> String {
        if session.state.needsUser {
            return TextUtils.duration(now.timeIntervalSince(session.waitingSince ?? session.lastEventAt))
        }
        if session.isQuiet(now: now) { return TextUtils.duration(now.timeIntervalSince(session.lastEventAt)) }
        return TextUtils.duration(now.timeIntervalSince(session.turnStartedAt))
    }

    static func liveText(_ session: Session, now: Date) -> String {
        switch session.state {
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
        let style: (fill: Color, text: Color, outline: Bool) = {
            switch session.state {
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
            if session.isDone {
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy))
            }
            Text(RunText.stateWord(session, now: now))
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
            Text(RunText.stateTime(session, now: now))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(style.text)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(style.fill))
        .overlay(Capsule().strokeBorder(style.outline ? style.text : .clear, lineWidth: 1))
        .fixedSize()
    }
}

/// The third line: the step bar, the current action, or the command it wants to run.
struct LiveLine: View {
    let session: Session
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            switch session.state {
            case .needsApproval:
                Text("wants to run").foregroundStyle(.secondary)
                Text(session.approvalDetail ?? "a tool")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            case .yourTurn:
                if session.outcome == .needsInput {
                    Text(session.outcomeSource == .asked ? "asks" : "asks you").foregroundStyle(.secondary)
                    Text(RunText.liveText(session, now: now)).lineLimit(1)
                } else {
                    Text(RunText.liveText(session, now: now)).foregroundStyle(.secondary).lineLimit(1)
                }
            case .working:
                Text(RunText.liveText(session, now: now))
                    .foregroundStyle(session.isInBackground || session.isQuiet(now: now) ? .secondary : .primary)
                    .lineLimit(1)
                if let progress = session.progress, !session.isInBackground {
                    StepsBar(progress: progress, color: Palette.tool(session.tool))
                }
            }
        }
        .font(.system(size: 11.5, weight: .medium))
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
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
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
    var window: TimeInterval = 3600

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 0, y: mid))
            line.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(line, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

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
                    .overlay(Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary))
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
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(stats.waitedToday >= 60 ? Color.primary : .secondary)
            Text(" today")
            if let average = stats.averageReply {
                Text(" · you replied in ")
                Text(Self.short(average))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(" on average")
            }
        }
        .font(.system(size: 11))
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
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
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
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Agent activity over the last two hours, Claude and Codex")
    }
}

struct SectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.9)
            Text("\(count)").font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 1)
    }
}

struct LifelineLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            swatch(Palette.claude, "Claude")
            swatch(Palette.codex, "Codex")
            Text("·")
            bar(filled: true, "working")
            bar(filled: false, "waiting on you")
            Spacer(minLength: 4)
            Text("last 60 min")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 6)
            Text(label)
        }
    }

    private func bar(filled: Bool, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(filled ? 0.9 : 0.25))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary, lineWidth: filled ? 0 : 1))
                .frame(width: 10, height: 6)
            Text(label)
        }
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
