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

    var body: some View {
        let groups = model.board.groups(now: model.now)
        let stale = model.board.staleCards(now: model.now)
        VStack(spacing: 0) {
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
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(groups, id: \.name) { group in
                        Text(group.name.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.cards) { card in
                            BoardCard(card: card, stale: false, now: model.now, model: model, editCard: editCard)
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
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        if showStale {
                            ForEach(stale) { card in
                                BoardCard(card: card, stale: true, now: model.now, model: model, editCard: editCard)
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
        .frame(minWidth: 240, minHeight: 220)
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
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Text(TextUtils.age(now.timeIntervalSince(card.touchedAt)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(card.next.isEmpty ? "No next step yet" : "Next: \(card.next)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
            if expanded, let excerpt = card.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .opacity(stale ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(card: card) }
        .onTapGesture { expanded.toggle() }
        .help(card.link.map { "Double-click to open \($0.label)" } ?? "Click to expand")
        .contextMenu {
            if card.link != nil {
                Button("Open") { model.open(card: card) }
                Button("Continue in a New Chat") { model.continueInNewChat(card: card) }
            }
            Button("Edit…") { editCard(card) }
            if stale { Button("Still Working on It") { model.keep(cardId: card.id) } }
            Divider()
            Button("Archive") { model.archive(cardId: card.id) }
        }
    }
}
