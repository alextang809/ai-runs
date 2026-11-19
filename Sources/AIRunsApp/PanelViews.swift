import AIRunsCore
import AppKit
import SwiftUI

enum PanelLayout {
    static let menuWidth: CGFloat = 384
    static let flyoutWidth: CGFloat = 284
    static let gap: CGFloat = 8
    static let outerPadding: CGFloat = 14
}

/// Colour means "which tool": Claude's clay and Codex's ink (OpenAI's black,
/// white in dark mode). Everything else is grey. State is told by words and
/// by how the colour is applied: solid = needs you, outline = working,
/// light fill = replied, grey = done or in the background.
enum Palette {
    static let claude = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.89, green: 0.53, blue: 0.42, alpha: 1)   // a touch lighter on dark
            : NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757
    })
    static let codex = Color(nsColor: .labelColor)

    static func tool(_ tool: AgentTool) -> Color {
        tool.isOpenAI ? codex : claude
    }

    /// Text on a solid fill of the tool colour.
    static func onTool(_ tool: AgentTool) -> Color {
        tool.isOpenAI ? Color(nsColor: .windowBackgroundColor) : .white
    }

    static let quiet = Color.secondary
}

struct RowFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func reportFrame(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: RowFramePreference.self, value: [key: proxy.frame(in: .named("panel"))])
        })
    }
}

// MARK: - Root

struct PanelRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState
    let actions: PanelActions

    var body: some View {
        // The flyout column exists only while something is hovered, so the
        // panel never covers more of the screen than it shows.
        HStack(alignment: .top, spacing: PanelLayout.gap) {
            if ui.hover != nil {
                flyoutColumn
                    .frame(width: PanelLayout.flyoutWidth, alignment: .topTrailing)
            }
            MenuColumn(model: model, ui: ui, actions: actions)
                .frame(width: PanelLayout.menuWidth)
        }
        .padding(PanelLayout.outerPadding)
        .coordinateSpace(name: "panel")
        .onPreferenceChange(RowFramePreference.self) { frames in
            if ui.rowFrames != frames { ui.rowFrames = frames }
        }
        .fixedSize()
    }

    @ViewBuilder private var flyoutColumn: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.frame(width: PanelLayout.flyoutWidth, height: 1)
            if let target = ui.hover, let frame = ui.rowFrames[target.key] {
                flyout(for: target)
                    .padding(.top, max(0, frame.minY - PanelLayout.outerPadding - 6))
                    .onHover { inside in inside ? ui.keepHover() : ui.hoverOff() }
            }
        }
    }

    @ViewBuilder private func flyout(for target: PanelUIState.Target) -> some View {
        switch target {
        case .session(let id):
            if let session = model.store.sessions[id] {
                SessionFlyout(session: session, now: model.now, model: model, ui: ui, actions: actions)
            }
        case .card(let id):
            if let card = model.board.card(id: id) {
                CardFlyout(card: card, stale: model.board.isStale(card, now: model.now), now: model.now,
                           model: model, ui: ui, actions: actions)
            }
        }
    }
}

/// The menu-like card under the menu bar icon.
struct PanelSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GlassSurface(cornerRadius: 20) { content }
    }
}

// MARK: - Menu column

struct MenuColumn: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState
    let actions: PanelActions

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 0) {
                header
                SeparatorLine()
                activeSection
                SeparatorLine()
                PinnedSection(model: model, ui: ui, actions: actions)
                SeparatorLine()
                bottomMenu
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(nsImage: Icons.statusImage(Icons.Status(store: model.store)))
                    .accessibilityHidden(true)
                Text("AI Runs").font(AppTypography.appTitle)
                Spacer()
                if let message = model.message {
                    Text(message)
                        .font(AppTypography.metadata)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                    if model.undo != nil {
                        Button("Undo") { model.performUndo() }
                            .buttonStyle(.plain)
                            .font(AppTypography.section)
                            .foregroundStyle(Color.primary)
                            .keyboardShortcut("z", modifiers: .command)
                    }
                }
                RefreshButton(model: model)
                    .padding(.leading, 4)
            }
            HeaderDashboard(needs: model.store.needsUserCount, working: model.store.workingCount,
                            stats: model.store.stats(now: model.now))
            ForEach(model.silentTools, id: \.self) { tool in
                Text(silentHint(tool))
                    .font(AppTypography.metadata)
                    .foregroundStyle(Palette.tool(tool))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ThreadsHint(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onHover { if $0 { ui.hoverOff() } }
    }

    private func silentHint(_ tool: AgentTool) -> String {
        switch tool {
        case .codex: return "Codex hasn’t reported yet — approve the AI Runs hooks in Codex."
        case .claudeCode: return "Claude Code hasn’t reported yet — start or continue a session."
        case .chatgpt, .claudeWeb: return ""
        }
    }

    @ViewBuilder private var activeSection: some View {
        let sessions = model.store.ordered()
        let overlap = Overlap.sameRepo(sessions)
        VStack(alignment: .leading, spacing: 0) {
            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.needsHookSetup
                         ? "Set up hooks so Claude Code and Codex sessions show up here."
                         : "Nothing running. Start a session in Claude Code or Codex and it shows up here.")
                        .font(AppTypography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.needsHookSetup {
                        Button("Set Up Hooks…") { actions.showSettings() }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                let needs = sessions.filter { $0.needsUser }
                let working = sessions.filter { $0.state == .working }
                let unknown = sessions.filter { $0.state == .unknown }
                let done = sessions.filter { $0.isDone }
                let ignored = sessions.filter { $0.isIgnored }
                if !needs.isEmpty {
                    SectionLabel(title: "Needs you", count: needs.count)
                    rows(needs, overlap: overlap)
                }
                if !working.isEmpty {
                    SectionLabel(title: "Working", count: working.count)
                    rows(working, overlap: overlap)
                }
                if !unknown.isEmpty {
                    SectionLabel(title: "State unknown", count: unknown.count)
                    rows(unknown, overlap: overlap)
                }
                if !done.isEmpty {
                    SectionLabel(title: "Done", count: done.count)
                    rows(done, overlap: overlap)
                }
                if !ignored.isEmpty {
                    SectionLabel(title: "Ignored", count: ignored.count)
                    rows(ignored, overlap: overlap)
                }
                LifelineLegend()
            }
        }
        .padding(.vertical, 3)
    }

    private func rows(_ sessions: [Session], overlap: [String: [Session]]) -> some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                SessionRow(session: session, lifeline: model.store.lifeline(for: session.id, now: model.now),
                           now: model.now, alsoHere: (overlap[session.id] ?? []).map(\.title), ui: ui,
                           rename: { actions.renameSession(session.id) },
                           pin: { model.pin(sessionId: session.id) },
                           remove: {
                               ui.hover = nil
                               model.remove(sessionId: session.id)
                           },
                           ignore: ignoreAction(for: session)) {
                    actions.closePanel()
                    model.open(sessionId: session.id)
                }
            }
        }
        .padding(.horizontal, 5)
    }

    private func ignoreAction(for session: Session) -> (() -> Void)? {
        guard RunText.canIgnore(session) else { return nil }
        let id = session.id, ignored = session.isIgnored
        return { model.setIgnored(sessionId: id, !ignored) }
    }

    private var bottomMenu: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Pin Front AI Window", systemImage: "pin") { model.pinFrontWindow() }
            MenuRow(title: ui.boardVisible ? "Hide Floating Window" : "Show Floating Window", systemImage: "rectangle.on.rectangle") { actions.toggleBoard() }
            MenuRow(title: "Hooks & Settings…", systemImage: "slider.horizontal.3") { actions.showSettings() }
            MenuRow(title: "Quit AI Runs", shortcut: "⌘Q", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .onHover { if $0 { ui.hoverOff() } }
    }
}

struct SeparatorLine: View {
    var body: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 5)
    }
}

// MARK: - Rows

struct CardRow: View {
    let card: PinCard
    let stale: Bool
    let now: Date
    @ObservedObject var ui: PanelUIState
    let remove: (() -> Void)?
    let open: () -> Void

    private var key: PanelUIState.Target { .card(card.id) }
    private var highlighted: Bool { ui.hover == key }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(AppTypography.rowTitle).lineLimit(1)
                    Text(card.next.isEmpty ? "No next step yet" : "Next: \(card.next)")
                        .font(AppTypography.metadata).lineLimit(1)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 8)
                Text(TextUtils.age(now.timeIntervalSince(card.touchedAt)))
                    .font(AppTypography.elapsed)
                    .foregroundStyle(Color.secondary)
                    .opacity(highlighted && remove != nil ? 0 : 1)
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .frame(height: 44)
            .foregroundStyle(Color.primary)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(highlighted ? 0.08 : 0)))
            .opacity(stale && !highlighted ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if highlighted, let remove {
                RemoveZone(label: "Remove \(card.title)", action: remove)
            }
        }
        .contextMenu {
            Button("Open", action: open)
            if let remove { Button("Remove", action: remove) }
        }
        .onHover { inside in inside ? ui.hoverOn(key) : ui.hoverOff() }
        .reportFrame(key.key)
        .accessibilityLabel("\(card.title). \(card.next.isEmpty ? "" : "Next: \(card.next)")")
    }
}

struct MenuRow: View {
    let title: String
    var shortcut: String = ""
    var systemImage: String? = nil
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(AppTypography.body)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(title).font(AppTypography.action)
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut).font(AppTypography.body)
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .foregroundStyle(tint ?? Color.primary)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Pinned section

struct PinnedSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState
    let actions: PanelActions

    var body: some View {
        let groups = model.board.groups(now: model.now)
        let stale = model.board.staleCards(now: model.now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text("Pinned").font(AppTypography.rowTitle)
                Spacer()
                Button {
                    ui.addingNote.toggle()
                } label: {
                    Label("Note", systemImage: "plus").font(AppTypography.section)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.primary)
                .help("Write a quick note")
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .onHover { if $0 { ui.hoverOff() } }

            if ui.addingNote {
                HStack(spacing: 6) {
                    TextField("What are you keeping track of?", text: $ui.draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addNote)
                    Button("Add", action: addNote).controlSize(.small)
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 6)
            }

            if groups.isEmpty && stale.isEmpty && !ui.addingNote {
                Text("Nothing pinned yet. Pin a session from its details, or use “Pin Front AI Window” below.")
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 6)
            }

            ForEach(groups, id: \.name) { group in
                GroupHeader(name: group.name, count: group.cards.count,
                            collapsed: ui.collapsed.contains(group.name)) { ui.toggle(group: group.name) }
                    .onHover { if $0 { ui.hoverOff() } }
                if !ui.collapsed.contains(group.name) {
                    ForEach(group.cards) { card in
                        CardRow(card: card, stale: false, now: model.now, ui: ui, remove: { model.archive(cardId: card.id) }) {
                            actions.closePanel()
                            model.open(card: card)
                        }
                    }
                }
            }

            if !stale.isEmpty {
                GroupHeader(name: "Maybe done · untouched 3+ days", count: stale.count,
                            collapsed: ui.collapsed.contains(PanelUIState.staleGroup)) { ui.toggle(group: PanelUIState.staleGroup) }
                    .onHover { if $0 { ui.hoverOff() } }
                if !ui.collapsed.contains(PanelUIState.staleGroup) {
                    ForEach(stale) { card in
                        CardRow(card: card, stale: true, now: model.now, ui: ui, remove: { model.archive(cardId: card.id) }) {
                            actions.closePanel()
                            model.open(card: card)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }

    private func addNote() {
        model.addNote(title: ui.draft)
        ui.draft = ""
        ui.addingNote = false
    }
}

struct GroupHeader: View {
    let name: String
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(name).font(AppTypography.section)
                Spacer()
                Text("\(count)").font(AppTypography.body).foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(count) cards, \(collapsed ? "collapsed" : "expanded")")
    }
}

// MARK: - Flyouts

struct FlyoutAction: Identifiable {
    let id = UUID()
    let title: String
    var shortcut: String = ""
    let run: () -> Void
}

struct FlyoutSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GlassSurface(cornerRadius: 16) {
            content.frame(width: PanelLayout.flyoutWidth, alignment: .leading)
        }
    }
}

struct FlyoutBody: View {
    let title: String
    let subtitle: String
    var chip: (text: String, color: Color?)? = nil
    var rows: [(String, String)] = []
    var noteLabel: String? = nil
    var note: String? = nil
    var quoteLabel: String? = nil
    var quote: String? = nil
    let actions: [FlyoutAction]

    var body: some View {
        FlyoutSurface {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(AppTypography.detailTitle).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(AppTypography.body).foregroundStyle(.secondary)
                    if let chip {
                        Text(chip.text)
                            .font(AppTypography.metadata)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill((chip.color ?? Color.primary).opacity(chip.color == nil ? 0.08 : 0.16)))
                            .foregroundStyle(chip.color ?? Color.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

                if !rows.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.0).foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(row.1).multilineTextAlignment(.trailing)
                            }
                            .font(AppTypography.body)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 8)
                }

                if let note {
                    VStack(alignment: .leading, spacing: 2) {
                        if let noteLabel { Text(noteLabel).font(AppTypography.metadata).foregroundStyle(.secondary) }
                        Text(note).font(AppTypography.body).lineLimit(8).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 8)
                }

                if let quote, !quote.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if let quoteLabel { Text(quoteLabel).font(AppTypography.metadata).foregroundStyle(.secondary) }
                        // Not selectable: once clicked, selectable text forgets its
                        // line limit and is drawn past the box, over the actions.
                        Text(quote).font(AppTypography.body).lineLimit(8).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    // Whatever the text does, it stays inside its box.
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                    .padding(.horizontal, 14).padding(.bottom, 10)
                }

                SeparatorLine()
                VStack(spacing: 0) {
                    ForEach(actions) { action in
                        MenuRow(title: action.title, shortcut: action.shortcut, action: action.run)
                    }
                }
                .padding(.horizontal, 5).padding(.bottom, 5)
            }
        }
    }
}

struct SessionFlyout: View {
    let session: Session
    let now: Date
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState
    let actions: PanelActions

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        let appName = session.terminal.appName
        var subtitle = session.isProjectConversation ? "Claude project" : session.tool.displayName
        if session.projectMainId != nil { subtitle += " · Main conversation" }
        if !session.project.isEmpty { subtitle += " · \(session.project)" }
        subtitle += " · \(appName)"

        let tint = Palette.tool(session.tool)
        let chip: (text: String, color: Color?)
        if session.isIgnored {
            chip = ("Ignored · waiting \(TextUtils.duration(now.timeIntervalSince(session.waitingSince ?? now)))", nil)
        } else if let native = session.native {
            // Known only from Claude's Threads list: say so, and when.
            let seen = "s" + RunText.seen(native, now: now).dropFirst()
            if native.stale == true {
                chip = ("State unknown · last \(seen)", nil)
            } else if native.state == .idle {
                chip = ("Idle · \(seen)", nil)
            } else {
                chip = ("\(native.state.heading) · \(seen)", tint)
            }
        } else {
        switch session.state {
        case .unknown:
            chip = ("State unknown", nil)
        case .needsApproval:
            chip = ("Needs approval · waiting \(TextUtils.duration(now.timeIntervalSince(session.waitingSince ?? now)))", tint)
        case .yourTurn:
            let since = TextUtils.duration(now.timeIntervalSince(session.waitingSince ?? now))
            switch session.outcome {
            case .needsInput: chip = ("Needs your input · waiting \(since)", tint)
            case .done: chip = ("Done · \(since) ago", nil)
            default: chip = ("Replied · \(since) ago", tint)
            }
        case .working:
            if session.isInBackground {
                let tasks = session.backgroundTasks ?? 1
                chip = ("Waiting on \(tasks) background task\(tasks == 1 ? "" : "s") · continues by itself", nil)
            } else {
                chip = session.isQuiet(now: now)
                    ? ("No update for a while — it may have stopped", nil)
                    : ("Working · \(TextUtils.duration(now.timeIntervalSince(session.turnStartedAt)))", tint)
            }
        }
        }

        var rows: [(String, String)] = []
        if session.nativeView?.isOpen == true { rows.append(("View", "Open in Claude")) }
        if session.state == .working, let progress = session.progress {
            rows.append(("Steps", progress.summary))
        }
        if session.state == .working, let activity = session.activity {
            rows.append(("Now", activity))
        }
        if let driver = session.drivenBy {
            rows.append(("Prompted by", driver))
        }
        if session.state == .yourTurn, let source = session.outcomeSource {
            let verdict: String
            switch session.outcome {
            case .needsInput: verdict = "Needs your input"
            case .done: verdict = "Finished"
            default: verdict = "Can’t tell if it’s done"
            }
            rows.append(("Status", "\(verdict) · \(source.explanation.lowercased())"))
        }
        if let others = Overlap.sameRepo(Array(model.store.sessions.values))[session.id] {
            rows.append(("Also running here", others.map(\.title).sorted().joined(separator: ", ")))
        }
        rows.append(("Started", Self.clock.string(from: session.startedAt)))
        // Only when AI Runs saw the turn start; otherwise the number means nothing.
        if session.needsUser, let since = session.waitingSince, since.timeIntervalSince(session.turnStartedAt) >= 60 {
            rows.append(("Last turn took", TextUtils.duration(since.timeIntervalSince(session.turnStartedAt))))
        }

        var flyoutActions = [
            FlyoutAction(title: "Open in \(appName)", shortcut: "↩") {
                actions.closePanel()
                model.open(sessionId: session.id)
            },
            FlyoutAction(title: "Pin to Board") { model.pin(sessionId: session.id) },
            FlyoutAction(title: "Rename…") { actions.renameSession(session.id) },
        ]
        if RunText.canIgnore(session) {
            flyoutActions.insert(FlyoutAction(title: RunText.ignoreTitle(session)) {
                model.setIgnored(sessionId: session.id, !session.isIgnored)
            }, at: 1)
        }
        // Only for sessions that live in a terminal; desktop and web users never need a command.
        if let bundle = Jumper.bundleId(for: session.terminal), Jumper.terminalBundles.contains(bundle) {
            flyoutActions.append(FlyoutAction(title: "Copy Resume Command") {
                Jumper.copyResumeCommand(for: session)
                model.show("Copied “\(session.tool.resumeCommand(sessionId: session.sessionId))”.")
            })
        }
        flyoutActions.append(FlyoutAction(title: "Remove from List") {
            ui.hover = nil
            model.remove(sessionId: session.id)
        })

        return FlyoutBody(
            title: session.title,
            subtitle: subtitle,
            chip: chip,
            rows: rows,
            noteLabel: session.approvalDetail == nil ? nil : "Wants to run",
            note: session.approvalDetail,
            quoteLabel: "Last reply",
            quote: TextUtils.preview(of: session.lastMessage, limit: 400),
            actions: flyoutActions
        )
    }
}

struct CardFlyout: View {
    let card: PinCard
    let stale: Bool
    let now: Date
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState
    let actions: PanelActions

    var body: some View {
        var subtitle = card.link.map { "Linked to \($0.label)" } ?? "Note · \(card.group)"
        if stale { subtitle += " · untouched \(TextUtils.age(now.timeIntervalSince(card.touchedAt)))" }

        var flyoutActions: [FlyoutAction] = []
        if stale {
            flyoutActions.append(FlyoutAction(title: "Still Working on It") { model.keep(cardId: card.id) })
        } else if card.link != nil {
            flyoutActions.append(FlyoutAction(title: "Open", shortcut: "↩") {
                actions.closePanel()
                model.open(card: card)
            })
            flyoutActions.append(FlyoutAction(title: "Continue in a New Chat") {
                actions.closePanel()
                model.continueInNewChat(card: card)
            })
        }
        flyoutActions.append(FlyoutAction(title: "Edit…") { actions.editCard(card) })
        flyoutActions.append(FlyoutAction(title: "Remove") {
            ui.hover = nil
            model.archive(cardId: card.id)
        })

        return FlyoutBody(
            title: card.title,
            subtitle: subtitle,
            noteLabel: card.nextIsSuggested ? "Next step · suggested from the last reply" : "Next step",
            note: card.next.isEmpty ? "None yet — use Edit to add one." : card.next,
            quoteLabel: "Saved from the reply",
            quote: card.excerpt,
            actions: flyoutActions
        )
    }
}
