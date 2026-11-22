import AIRunsCore
import SwiftUI

/// Shared card content for the menu and floating board. Keeping the editor and
/// link list here gives both surfaces the same controls and reading order.
struct PinnedCardView<Actions: View>: View {
    let card: PinCard
    @Binding var isExpanded: Bool
    var saveNext: ((String) -> Bool)? = nil
    let openLink: (PinAttachment) -> Void
    var highlighted = false
    @ViewBuilder let actions: Actions

    @State private var editingNext = false
    @State private var draft = ""
    @State private var saveFailed = false
    @FocusState private var nextFocused: Bool

    private var hasNext: Bool { !card.next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var identifier: String { "pinned.\(card.id.uuidString)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if editingNext {
                editor
            } else {
                summary
            }
            if isExpanded {
                Divider().padding(.vertical, 3)
                links
                excerpt
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Color.primary.opacity(highlighted ? 0.2 : 0.09), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { cancelEditing() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(card.title)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                if saveNext != nil {
                    Button("Edit next step…", systemImage: "pencil", action: beginEditing)
                        .accessibilityIdentifier("\(identifier).edit-next")
                }
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppTypography.controlIcon)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel("More actions for \(card.title)")
            .accessibilityIdentifier("\(identifier).more")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 7) {
            if hasNext {
                Button { isExpanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(card.next)
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        disclosureIcon
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(card.next)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide linked sessions and artifacts")
                .accessibilityIdentifier("\(identifier).toggle")
            } else if saveNext != nil {
                Button("Add a next step…", action: beginEditing)
                    .buttonStyle(.plain)
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier).edit-next")
                    .padding(.vertical, 2)
            }
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    ForEach(PinnedCardPresentation.tools(for: card.attachments), id: \.self) { tool in
                        toolIcon(tool)
                            .font(.system(size: 10))
                            .frame(width: 14, height: 14)
                    }
                    Text(PinnedCardPresentation.summary(for: card.attachments))
                        .font(AppTypography.section)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    if !hasNext { disclosureIcon }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PinnedCardPresentation.summary(for: card.attachments))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide linked sessions and artifacts")
            .accessibilityIdentifier("\(identifier).\(hasNext ? "links-toggle" : "toggle")")
        }
    }

    private var disclosureIcon: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("What’s the next step?", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(AppTypography.body)
                .textFieldStyle(.roundedBorder)
                .focused($nextFocused)
                .onSubmit(commitNext)
                .accessibilityLabel("Next step for \(card.title)")
                .accessibilityIdentifier("\(identifier).next-field")
            if saveFailed {
                Text("Couldn’t save. Your text is still here; try again.")
                    .font(AppTypography.section)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).save-error")
            }
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancelEditing)
                    .accessibilityIdentifier("\(identifier).cancel-next")
                Button("Save", action: commitNext)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("\(identifier).save-next")
            }
            .controlSize(.small)
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 4) {
            if card.attachments.isEmpty {
                Text("No linked items")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(card.attachments) { attachment in
                Button { openLink(attachment) } label: {
                    HStack(spacing: 9) {
                        attachmentIcon(attachment)
                            .frame(width: 18, height: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.title.isEmpty ? attachment.link.label : attachment.title)
                                .font(AppTypography.body)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(PinnedCardPresentation.subtitle(for: attachment.link))
                                .font(AppTypography.section)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(attachment.title) · \(attachment.link.label)")
                .accessibilityIdentifier("\(identifier).link.\(attachment.id.uuidString)")
            }
        }
    }

    @ViewBuilder private var excerpt: some View {
        if let text = card.excerpt, !text.isEmpty {
            DisclosureGroup("Saved context") {
                Text(text)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .font(AppTypography.section)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityIdentifier("\(identifier).context")
        }
    }

    private func beginEditing() {
        draft = card.next
        saveFailed = false
        editingNext = true
        isExpanded = true
        nextFocused = true
    }

    private func cancelEditing() {
        editingNext = false
        nextFocused = false
        saveFailed = false
        draft = ""
    }

    private func commitNext() {
        let next = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, let saveNext else { return }
        guard saveNext(next) else { saveFailed = true; return }
        cancelEditing()
    }

    private func toolIcon(_ tool: AgentTool) -> some View {
        Image(systemName: tool.isOpenAI ? "bubble.left" : "asterisk")
            .foregroundStyle(Palette.tool(tool))
            .accessibilityHidden(true)
    }

    @ViewBuilder private func attachmentIcon(_ attachment: PinAttachment) -> some View {
        if let tool = PinnedCardPresentation.tool(for: attachment.link) {
            toolIcon(tool)
        } else {
            Image(systemName: attachment.boardIcon == "macwindow" ? "macwindow" : "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

enum PinnedCardPresentation {
    static func tool(for link: PinLink) -> AgentTool? {
        switch link {
        case .session(let tool, _, _, _): return tool
        case .url(let address):
            guard let url = URL(string: address) else { return nil }
            if url.scheme?.lowercased() == "claude", url.host == "code" { return .claudeCode }
            guard url.scheme?.lowercased() == "https" else { return nil }
            switch url.host?.lowercased() {
            case "chatgpt.com" where url.path.hasPrefix("/c/"): return .chatgpt
            case "claude.ai" where url.path.hasPrefix("/chat/"): return .claudeWeb
            default: return nil
            }
        case .app: return nil
        }
    }

    static func tools(for attachments: [PinAttachment]) -> [AgentTool] {
        AgentTool.allCases.filter { candidate in attachments.contains { tool(for: $0.link) == candidate } }
    }

    static func summary(for attachments: [PinAttachment]) -> String {
        let sessions = attachments.filter { tool(for: $0.link) != nil }.count
        let apps = attachments.filter { if case .app = $0.link { return true }; return false }.count
        let artifacts = attachments.count - sessions - apps
        let parts = [(sessions, "session"), (artifacts, "artifact"), (apps, "app")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "No linked items" : parts.joined(separator: " · ")
    }

    static func subtitle(for link: PinLink) -> String {
        tool(for: link)?.displayName ?? link.label
    }
}
