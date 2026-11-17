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
                AppIcon(bundleId: Jumper.bundleId(for: session.terminal))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        StatePill(session: session, now: now)
                        if highlighted {
                            RemoveButton(label: "Remove \(session.title) from the list", action: remove)
                        }
                    }
                    Text(RunText.place(session))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        LiveLine(session: session, now: now)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LifelineView(spans: lifeline, now: now)
                            .frame(width: 104, height: 9)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(highlighted ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .accessibilityLabel("\(session.title), \(RunText.place(session)), \(RunText.stateWord(session, now: now)), \(RunText.stateTime(session, now: now)). \(RunText.liveText(session, now: now))")
        .accessibilityAddTraits(.isButton)
    }
}

/// Words shared by the row, the flyout and VoiceOver.
enum RunText {
    static func place(_ session: Session) -> String {
        let host = session.terminal.appName
        var parts: [String]
        if (session.tool == .claudeCode && host == "Claude") || (session.tool == .codex && host == "Codex") {
            parts = ["\(host) app"]
        } else {
            parts = [session.tool.displayName, host]
        }
        if !session.project.isEmpty { parts.append(session.project) }
        if let driver = session.drivenBy { parts.append("via \(driver)") }
        return parts.joined(separator: " · ")
    }

    static func stateWord(_ session: Session, now: Date) -> String {
        switch session.state {
        case .needsApproval: return "APPROVE"
        case .yourTurn: return "YOUR TURN"
        case .working:
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
            if let progress = session.progress, progress.isFinished { return "Done" }
            return TextUtils.preview(of: session.lastMessage, limit: 90) ?? "Finished its turn"
        case .working:
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
        let (fill, text): (Color, Color) = {
            switch session.state {
            case .needsApproval: return (Palette.waitingFill, .white)
            case .yourTurn: return (Palette.waitingFill.opacity(0.16), Palette.waiting)
            case .working:
                if session.isInBackground || session.isQuiet(now: now) { return (Color.primary.opacity(0.07), .secondary) }
                return (Palette.working.opacity(0.13), Palette.working)
            }
        }()
        HStack(spacing: 5) {
            Text(RunText.stateWord(session, now: now))
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
            Text(RunText.stateTime(session, now: now))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(text)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(fill))
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
                if let progress = session.progress, progress.isFinished {
                    Text("Done")
                    StepsBar(progress: progress, color: Palette.waitingFill)
                } else {
                    Text(RunText.liveText(session, now: now)).foregroundStyle(.secondary).lineLimit(1)
                }
            case .working:
                Text(RunText.liveText(session, now: now))
                    .foregroundStyle(session.isInBackground || session.isQuiet(now: now) ? .secondary : .primary)
                    .lineLimit(1)
                if let progress = session.progress, !session.isInBackground {
                    StepsBar(progress: progress, color: Palette.working)
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
                let color: Color
                switch span.kind {
                case .working: color = Palette.working
                case .waiting: color = Palette.waitingFill
                case .background: color = .secondary.opacity(0.55)
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
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
                Metric(value: needs, label: "need you", color: needs > 0 ? Palette.waitingFill : .secondary)
                Metric(value: working, label: "working", color: working > 0 ? Palette.working : .secondary)
                Metric(value: stats.sessionsToday, label: "today", color: .primary)
                Spacer(minLength: 0)
                Histogram(buckets: stats.buckets)
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
                .foregroundStyle(stats.waitedToday >= 60 ? Palette.waiting : .secondary)
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

private struct Histogram: View {
    let buckets: [(working: Double, waiting: Double)]

    var body: some View {
        let peak = max(1, buckets.map { $0.working + $0.waiting }.max() ?? 1)
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(buckets.indices, id: \.self) { index in
                    let bucket = buckets[index]
                    VStack(spacing: 1) {
                        if bucket.waiting > 0 {
                            Rectangle().fill(Palette.waitingFill)
                                .frame(height: max(1.5, 32 * bucket.waiting / peak))
                        }
                        if bucket.working > 0 {
                            Rectangle().fill(Palette.working)
                                .frame(height: max(1.5, 32 * bucket.working / peak))
                        }
                        if bucket.working + bucket.waiting == 0 {
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
        .accessibilityLabel("Agent activity over the last two hours")
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
        HStack(spacing: 11) {
            item(Palette.working, "working")
            item(Palette.waitingFill, "waiting on you")
            item(.secondary.opacity(0.55), "background")
            Spacer()
            Text("last 60 min")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 6)
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
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove from list")
        .accessibilityLabel(label)
    }
}
