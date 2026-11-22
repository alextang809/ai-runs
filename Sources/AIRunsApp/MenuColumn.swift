import AIRunsCore
import AppKit
import SwiftUI

private enum MenuPart: Hashable {
    case header, sessions, footer
}

private struct MenuHeightPreference: PreferenceKey {
    static var defaultValue: [MenuPart: CGFloat] = [:]
    static func reduce(value: inout [MenuPart: CGFloat], nextValue: () -> [MenuPart: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func menuHeight(_ part: MenuPart) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: MenuHeightPreference.self, value: [part: proxy.size.height])
        })
    }
}

struct MenuColumn: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PanelUIState
    let actions: PanelActions
    @State private var heights: [MenuPart: CGFloat] = [:]
    @State private var showRecent = false

    private var hasActiveSessions: Bool {
        MenuSessionPresentation(sessions: model.store.ordered()).hasActiveSessions
    }

    private var sessionHeight: CGFloat {
        let available = ui.menuHeightLimit - (heights[.header] ?? 0) - (heights[.footer] ?? 0) - 8
        return max(1, min(heights[.sessions] ?? 1, available))
    }

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    SeparatorLine()
                }
                .menuHeight(.header)
                ScrollView(.vertical) {
                    activeSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .menuHeight(.sessions)
                }
                .frame(height: sessionHeight)
                VStack(spacing: 0) {
                    SeparatorLine()
                    MenuQuickActions(manager: model.accounts,
                                     openAccounts: { actions.showAccounts() },
                                     addAccount: { actions.showAddAccount() },
                                     openUsage: { actions.showUsageDashboard() })
                        .onHover { if $0 { ui.hoverOff() } }
                    SeparatorLine()
                    bottomMenu
                }
                .menuHeight(.footer)
            }
            .padding(.vertical, 4)
            .onPreferenceChange(MenuHeightPreference.self) { updated in
                if heights != updated { heights = updated }
            }
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
            if hasActiveSessions {
                HeaderDashboard(needs: model.store.needsUserCount, working: model.store.workingCount,
                                stats: model.store.stats(now: model.now))
            }
            ObservedUsageSummary(monitor: model.usage)
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
        let menu = MenuSessionPresentation(sessions: sessions)
        let overlap = Overlap.sameRepo(sessions)
        let nextCards = model.board.menuNextCards
        VStack(alignment: .leading, spacing: 0) {
            // Setup notices scroll with content so the fixed header and footer
            // still fit when permissions and both providers need attention.
            VStack(alignment: .leading, spacing: 6) {
                if menu.hasActiveSessions {
                    ForEach(model.silentTools, id: \.self) { tool in
                        Text(silentHint(tool))
                            .font(AppTypography.metadata)
                            .foregroundStyle(Palette.tool(tool))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ThreadsHint(model: model)
            }
            .padding(.horizontal, 14)
            if !menu.needs.isEmpty {
                SectionLabel(title: "Needs you", count: menu.needs.count)
                rows(menu.needs, overlap: overlap)
            }
            if !nextCards.isEmpty {
                MenuPinnedNext(cards: nextCards, expandedCardID: $ui.expandedNextCardID,
                               cancelHover: { ui.cancelHover() }) { card, attachment in
                    actions.closePanel()
                    model.open(card: card, attachment: attachment)
                }
                .onHover { if $0 { ui.cancelHover() } }
            } else {
                SectionLabel(title: "Next", count: 0)
                MenuRow(title: "Choose from Pinned…", systemImage: "pin") { actions.showPinnedBoard() }
                    .padding(.horizontal, 5)
                    .onHover { if $0 { ui.cancelHover() } }
            }
            if !menu.working.isEmpty {
                SectionLabel(title: "Working", count: menu.working.count, showsTimeScale: true)
                rows(menu.working, overlap: overlap)
            }
            if !menu.hasActiveSessions {
                idleActions
            }
            if !menu.unknown.isEmpty {
                SectionLabel(title: "State unknown", count: menu.unknown.count)
                rows(menu.unknown, overlap: overlap)
            }
            if menu.hasActiveSessions {
                if !menu.done.isEmpty {
                    sessionDisclosure("Done", count: menu.done.count, expanded: $ui.expandedDone)
                    if ui.expandedDone { rows(menu.done, overlap: overlap) }
                }
                if !menu.ignored.isEmpty {
                    sessionDisclosure("Ignored", count: menu.ignored.count, expanded: $ui.expandedIgnored)
                    if ui.expandedIgnored { rows(menu.ignored, overlap: overlap) }
                }
            } else if !menu.recent.isEmpty {
                sessionDisclosure("Recent Sessions", count: menu.recent.count, expanded: $showRecent)
                if showRecent {
                    if !menu.done.isEmpty {
                        SectionLabel(title: "Done", count: menu.done.count)
                        rows(menu.done, overlap: overlap)
                    }
                    if !menu.ignored.isEmpty {
                        SectionLabel(title: "Ignored", count: menu.ignored.count)
                        rows(menu.ignored, overlap: overlap)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var idleActions: some View {
        VStack(spacing: 0) {
            MenuRow(title: ui.boardVisible ? "Hide Floating Window" : "Show Floating Window",
                    systemImage: "rectangle.on.rectangle") { actions.toggleBoard() }
            if model.needsHookSetup {
                MenuRow(title: "Set Up Session Tracking…", systemImage: "link") { actions.showSettings() }
            }
        }
        .padding(.horizontal, 5)
        .onHover { if $0 { ui.hoverOff() } }
    }

    private func sessionDisclosure(_ title: String, count: Int, expanded: Binding<Bool>) -> some View {
        Button {
            expanded.wrappedValue.toggle()
            ui.cancelHover()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                Text(title).font(AppTypography.section)
                Text("\(count)").font(AppTypography.elapsed)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { ui.hoverOff() } }
        .accessibilityLabel("\(title), \(count) sessions, \(expanded.wrappedValue ? "expanded" : "collapsed")")
        .accessibilityHint(expanded.wrappedValue ? "Hide sessions" : "Show sessions")
    }

    private func rows(_ sessions: [Session], overlap: [String: [Session]]) -> some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                SessionRow(session: session,
                           lifeline: session.isDone ? [] : model.store.lifeline(for: session.id, now: model.now),
                           completedWorkDuration: model.store.completedWorkDuration(for: session.id), now: model.now,
                           alsoHere: (overlap[session.id] ?? []).map(\.title), ui: ui,
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

    @ViewBuilder private var bottomMenu: some View {
        if hasActiveSessions {
            activeFooter
        } else {
            VStack(spacing: 0) {
                MenuRow(title: "Settings…", systemImage: "slider.horizontal.3") { actions.showSettings() }
                MenuRow(title: "About AI Runs", systemImage: "info.circle") { actions.showAbout() }
                MenuRow(title: "Quit AI Runs", shortcut: "⌘Q", systemImage: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .onHover { if $0 { ui.hoverOff() } }
        }
    }

    private var activeFooter: some View {
        HStack(spacing: 14) {
            Button {
                actions.toggleBoard()
            } label: {
                Label("Floating Window", systemImage: "rectangle.on.rectangle")
            }
            .help(ui.boardVisible ? "Hide Floating Window" : "Show Floating Window")
            .accessibilityLabel(ui.boardVisible ? "Hide Floating Window" : "Show Floating Window")
            Spacer(minLength: 4)
            Button("Settings…") { actions.showSettings() }
                .help("Hooks & Settings")
            Menu {
                Button("Pin Front AI Window", systemImage: "pin") { model.pinFrontWindow() }
                Button("About AI Runs", systemImage: "info.circle") { actions.showAbout() }
                Divider()
                Button("Quit AI Runs", systemImage: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .font(AppTypography.body)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .onHover { if $0 { ui.hoverOff() } }
    }
}
