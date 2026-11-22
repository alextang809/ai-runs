import AIRunsCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The pinned board, shown in the floating window's Pinned tab.
struct BoardView: View {
    @ObservedObject var model: AppModel
    let editCard: (PinCard) -> Void
    @State private var draft = ""
    @State private var dropTargeted = false
    @State private var showStale = false
    @State private var linkCardID: UUID?

    var body: some View {
        Group {
            if let linkCardID, let card = model.board.card(id: linkCardID) {
                BoardLinkEditor(card: card, model: model) { self.linkCardID = nil }
            } else {
                board
            }
        }
        .frame(minWidth: 240, minHeight: 220)
    }

    private var board: some View {
        let groups = model.board.groups(now: model.now)
        let stale = model.board.staleCards(now: model.now)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Quick note…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNote)
                Button(action: addNote) { Image(systemName: "plus") }
                    .help("Add note")
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if groups.isEmpty && stale.isEmpty {
                        Text("Nothing pinned yet. Drag text or a link here, or type a quick note above.")
                            .font(AppTypography.body)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(groups, id: \.name) { group in
                        Text(group.name.uppercased())
                            .font(AppTypography.section)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.cards) { card in
                            BoardCard(card: card, stale: false, now: model.now, model: model,
                                      editCard: editCard, editLinks: { linkCardID = card.id })
                        }
                    }
                    if !stale.isEmpty {
                        Button {
                            showStale.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(showStale ? 90 : 0))
                                Text("MAYBE DONE · \(stale.count)")
                                    .font(AppTypography.section)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        if showStale {
                            ForEach(stale) { card in
                                BoardCard(card: card, stale: true, now: model.now, model: model,
                                          editCard: editCard, editLinks: { linkCardID = card.id })
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Text(dropTargeted ? "Drop to make a card" : "Drag text or a link here to make a card")
                .font(.system(size: 11.5, weight: dropTargeted ? .semibold : .regular))
                .foregroundStyle(dropTargeted ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [4, 3]))
                    .foregroundStyle(dropTargeted ? Color.primary : Color.secondary.opacity(0.5)))
                .padding(10)
        }
        .onDrop(of: [UTType.url, UTType.plainText], isTargeted: $dropTargeted, perform: handleDrop)
    }

    private func addNote() {
        model.addNote(title: draft)
        draft = ""
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let text = url.absoluteString
                Task { @MainActor in model.addDropped(text: text) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? String else { return }
                Task { @MainActor in model.addDropped(text: text) }
            }
            return true
        }
        return false
    }
}

struct BoardCard: View {
    let card: PinCard
    let stale: Bool
    let now: Date
    @ObservedObject var model: AppModel
    let editCard: (PinCard) -> Void
    let editLinks: () -> Void
    @State private var hovering = false
    @State private var expanded = false
    @State private var showAllLinks = false
    @State private var editingMenuNext = false
    @State private var nextDraft = ""
    @FocusState private var nextFieldFocused: Bool

    private static let visibleLinkCount = 3

    private var showsInMainMenu: Bool { card.menuNextAt != nil }
    private var hasNext: Bool { !card.next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var mainMenuAction: String {
        if showsInMainMenu { return "Remove from Main Menu" }
        return hasNext ? "Show in Main Menu" : "Add Next to Main Menu…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                cardSummary
                Button(action: toggleMainMenu) {
                    Image(systemName: showsInMainMenu ? "pin.fill" : "pin")
                        .frame(width: 23, height: 23)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(showsInMainMenu ? Color.accentColor : Color.secondary)
                .accessibilityLabel("\(mainMenuAction), \(card.title)")
                .help(mainMenuAction)
                Button(action: editLinks) {
                    Image(systemName: "link.badge.plus")
                        .frame(width: 23, height: 23)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Manage links for \(card.title)")
                .help(card.attachments.isEmpty ? "Add Links…" : "Manage Links…")
            }
            if editingMenuNext {
                menuNextEditor
            }
            if !card.attachments.isEmpty {
                attachmentList
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .opacity(stale ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let attachment = card.attachments.first {
                if card.attachments.count == 1 {
                    Button("Open") { model.open(card: card, attachment: attachment) }
                }
                Button("Continue in a New Chat") { model.continueInNewChat(card: card) }
            }
            Button("Edit…") { editCard(card) }
            Button(mainMenuAction, action: toggleMainMenu)
            Button(card.attachments.isEmpty ? "Add Links…" : "Manage Links…", action: editLinks)
            if stale { Button("Still Working on It") { model.keep(cardId: card.id) } }
            Divider()
            Button("Archive") { model.archive(cardId: card.id) }
        }
    }

    private func toggleMainMenu() {
        if showsInMainMenu || hasNext {
            model.setMenuNext(!showsInMainMenu, for: card.id)
        } else {
            editingMenuNext = true
            nextFieldFocused = true
        }
    }

    private var menuNextEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What’s the next step?", text: $nextDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Next step for \(card.title)")
                .focused($nextFieldFocused)
                .onSubmit(saveMenuNext)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") { closeMenuNextEditor() }
                Button("Show in Main Menu", action: saveMenuNext)
                    .disabled(nextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func saveMenuNext() {
        let next = nextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, model.setMenuNext(true, for: card.id, next: next) else { return }
        closeMenuNextEditor()
    }

    private func closeMenuNextEditor() {
        editingMenuNext = false
        nextDraft = ""
    }

    private var cardSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.title).font(AppTypography.rowTitle).lineLimit(2)
                Spacer(minLength: 4)
                Text(TextUtils.age(now.timeIntervalSince(card.touchedAt)))
                    .font(AppTypography.elapsed)
                    .foregroundStyle(.secondary)
            }
            if !editingMenuNext {
                Text(hasNext ? "Next: \(card.next)" : "No next step yet")
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
            }
            if expanded, let excerpt = card.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(AppTypography.body)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if card.attachments.count == 1, let attachment = card.attachments.first {
                model.open(card: card, attachment: attachment)
            } else {
                expanded.toggle()
            }
        }
        .onTapGesture { expanded.toggle() }
    }

    private var attachmentList: some View {
        let shownLinks = showAllLinks ? card.attachments[...] : card.attachments.prefix(Self.visibleLinkCount)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shownLinks) { attachment in
                Button { model.open(card: card, attachment: attachment) } label: {
                    Label(attachment.boardTitle, systemImage: attachment.boardIcon)
                        .font(AppTypography.metadata)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Open \(attachment.title) · \(attachment.link.label)")
            }
            if card.attachments.count > Self.visibleLinkCount {
                Button(showAllLinks ? "Show fewer links" : "Show \(card.attachments.count - Self.visibleLinkCount) more links") {
                    showAllLinks.toggle()
                }
                .buttonStyle(.plain)
                .font(AppTypography.section)
                .foregroundStyle(.secondary)
            }
        }
    }
}
