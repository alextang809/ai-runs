import AIRunsCore
import SwiftUI

struct MenuPinnedNext: View {
    let cards: [PinCard]
    var pinnedCards: [PinCard] = []
    @Binding var expandedCardID: UUID?
    let cancelHover: () -> Void
    var updateNext: ((PinCard, Bool, String?) -> Bool)? = nil
    var archiveCard: ((PinCard) -> Void)? = nil
    let openLink: (PinCard, PinAttachment) -> Void
    @State private var showAllPinned = false

    private static let previewLimit = 3

    static func visiblePinnedCards(_ pinned: [PinCard], selected: [PinCard], expandedID: UUID?,
                                   showAll: Bool) -> [PinCard] {
        let selectedIDs = Set(selected.map(\.id))
        let candidates = pinned.filter { !selectedIDs.contains($0.id) }
            .sorted {
                $0.touchedAt == $1.touchedAt ? $0.id.uuidString < $1.id.uuidString : $0.touchedAt > $1.touchedAt
            }
        if showAll { return candidates }
        // Always leave a recent pin visible, including when three priorities
        // are occupied, so a successful pin does not disappear on reopening.
        let capacity = max(1, previewLimit - selected.count)
        let recent = Array(candidates.prefix(capacity))
        guard let focused = candidates.first(where: { $0.id == expandedID }),
              !recent.contains(where: { $0.id == focused.id }) else { return recent }
        // A newly pinned card is revealed even when all three priorities are occupied.
        return [focused] + Array(recent.prefix(max(0, capacity - 1)))
    }

    var body: some View {
        let preview = Self.visiblePinnedCards(pinnedCards, selected: cards,
            expandedID: expandedCardID, showAll: showAllPinned)
        let visible = cards + preview
        let total = Set((cards + pinnedCards).map(\.id)).count
        let hasMore = total > visible.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pin").accessibilityHidden(true)
                Text("Next")
                if total > 0 { Text("\(total)").monospacedDigit() }
                Spacer(minLength: 0)
                Text("Pinned by you")
            }
            .font(AppTypography.section)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .accessibilityAddTraits(.isHeader)

            if visible.isEmpty {
                Text("Pin a session to keep it here.")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(visible) { card in
                PinnedCardView(card: card, isExpanded: Binding(
                    get: { expandedCardID == card.id },
                    set: { expandedCardID = $0 ? card.id : nil; cancelHover() }
                ), saveNext: updateNext.map { update in
                    { next in update(card, card.menuNextAt != nil, next) }
                }, openLink: { openLink(card, $0) }) {
                    if let updateNext {
                        let selected = card.menuNextAt != nil
                        Button(selected ? "Use Recent Order" : "Keep at Top") {
                            _ = updateNext(card, !selected, nil)
                        }
                        .disabled(!selected && (card.next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || cards.count >= PinBoard.maximumMenuNextCards))
                    }
                    if let archiveCard {
                        Divider()
                        Button("Unpin") { archiveCard(card) }
                    }
                }
                .id(card.id)
            }
            if showAllPinned || hasMore {
                Button {
                    showAllPinned.toggle()
                    cancelHover()
                } label: {
                    HStack {
                        Text(showAllPinned ? "Show fewer" : "View all pinned (\(total))")
                        Spacer(minLength: 0)
                        Image(systemName: showAllPinned ? "chevron.up" : "chevron.down")
                    }
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pinned.show-all")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .onChange(of: (cards + pinnedCards).map(\.id)) { _, ids in
            if let expandedCardID, !ids.contains(expandedCardID) {
                self.expandedCardID = nil
            }
        }
    }
}
