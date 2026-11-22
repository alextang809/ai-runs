import AIRunsCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The pinned board, shown in the floating window's Pinned tab.
struct BoardView: View {
    @ObservedObject var model: AppModel
    let editCard: (PinCard) -> Void
    var reveal: FloatingState.PinReveal? = nil
    @State private var draft = ""
    @State private var dropTargeted = false
    @State private var showStale = false
    @State private var linkCardID: UUID?
    @State private var expandedCardID: UUID?

    var body: some View {
        Group {
            if let linkCardID, let card = model.board.card(id: linkCardID) {
                BoardLinkEditor(card: card, model: model) { self.linkCardID = nil }
            } else {
                board
            }
        }
        .frame(minWidth: 240, minHeight: 220)
        .onChange(of: reveal) { _, request in
            if request != nil { linkCardID = nil }
        }
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

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
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
                                BoardCard(card: card, stale: false, model: model,
                                          editCard: editCard, editLinks: { linkCardID = card.id },
                                          highlighted: reveal?.cardID == card.id,
                                          expandedCardID: $expandedCardID)
                                    .id(card.id)
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
                                    Text("Older pins · \(stale.count)")
                                        .font(AppTypography.section)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 10)
                            if showStale {
                                ForEach(stale) { card in
                                    BoardCard(card: card, stale: true, model: model,
                                              editCard: editCard, editLinks: { linkCardID = card.id },
                                          highlighted: reveal?.cardID == card.id,
                                          expandedCardID: $expandedCardID)
                                    .id(card.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .task(id: reveal) {
                    guard let reveal, model.board.card(id: reveal.cardID) != nil else { return }
                    expandedCardID = reveal.cardID
                    if stale.contains(where: { $0.id == reveal.cardID }) { showStale = true }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo(reveal.cardID, anchor: .top)
                }
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
    @ObservedObject var model: AppModel
    let editCard: (PinCard) -> Void
    let editLinks: () -> Void
    var highlighted = false
    @Binding var expandedCardID: UUID?

    private var isSelected: Bool { card.menuNextAt != nil }
    private var hasNext: Bool { !card.next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        PinnedCardView(card: card, isExpanded: Binding(
            get: { expandedCardID == card.id },
            set: { expandedCardID = $0 ? card.id : nil }
        ), saveNext: { next in
            model.setMenuNext(isSelected, for: card.id, next: next)
        }, liveTitle: model.liveTitle(for:), openLink: { model.open(card: card, attachment: $0) }, highlighted: highlighted) {
            Button("Edit Card…") { editCard(card) }
            Button(card.attachments.isEmpty ? "Add Links…" : "Manage Links…", action: editLinks)
            Button(isSelected ? "Use Recent Order" : "Keep at Top") {
                model.setMenuNext(!isSelected, for: card.id)
            }
            .disabled(!isSelected && (!hasNext || model.board.menuNextCards.count >= PinBoard.maximumMenuNextCards))
            if !card.attachments.isEmpty {
                Button("Continue in a New Chat") { model.continueInNewChat(card: card) }
            }
            if stale { Button("Keep in Recent Pins") { model.keep(cardId: card.id) } }
            Divider()
            Button("Unpin") { model.archive(cardId: card.id) }
        }
    }
}
