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
                    sessionDisclosure("Done", count: done.count, expanded: $ui.expandedDone)
                    if ui.expandedDone { rows(done, overlap: overlap) }
                }
                if !ignored.isEmpty {
                    sessionDisclosure("Ignored", count: ignored.count, expanded: $ui.expandedIgnored)
                    if ui.expandedIgnored { rows(ignored, overlap: overlap) }
                }
            }
        }
        .padding(.vertical, 3)
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
                SessionRow(session: session, now: model.now,
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

    private var bottomMenu: some View {
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
