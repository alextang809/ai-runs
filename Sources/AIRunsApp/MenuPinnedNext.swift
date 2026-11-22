import AIRunsCore
import SwiftUI

struct MenuPinnedNext: View {
    let cards: [PinCard]
    @Binding var expandedCardID: UUID?
    let cancelHover: () -> Void
    let openLink: (PinCard, PinAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Next", count: cards.count)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(cards) { card in
                    MenuNextCard(card: card, isExpanded: expandedCardID == card.id) {
                        expandedCardID = expandedCardID == card.id ? nil : card.id
                        cancelHover()
                    } openLink: { attachment in
                        openLink(card, attachment)
                    }
                }
            }
            .padding(.horizontal, 5)
        }
        .onChange(of: cards.map(\.id)) { _, ids in
            if let expandedCardID, !ids.contains(expandedCardID) {
                self.expandedCardID = nil
            }
        }
    }
}

private struct MenuNextCard: View {
    let card: PinCard
    let isExpanded: Bool
    let toggle: () -> Void
    let openLink: (PinAttachment) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title)
                            .font(AppTypography.section)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(card.next)
                            .font(AppTypography.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if !card.attachments.isEmpty {
                            Image(systemName: "link")
                                .accessibilityHidden(true)
                            Text("\(card.attachments.count)")
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(AppTypography.section)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering || isExpanded ? 0.07 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(Text("\(card.title), \(card.next)"))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hide linked items" : "Show \(card.attachments.count) linked items")

            if isExpanded {
                links
                    .padding(.leading, 13)
            }
        }
    }

    @ViewBuilder private var links: some View {
        if card.attachments.isEmpty {
            Text("No linked items")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
        }
        ForEach(card.attachments) { attachment in
            Button { openLink(attachment) } label: {
                HStack(spacing: 7) {
                    Image(systemName: attachment.boardIcon)
                        .frame(width: 15)
                        .accessibilityHidden(true)
                    Text(attachment.boardTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .accessibilityHidden(true)
                }
                .font(AppTypography.metadata)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 9)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(attachment.boardTitle)
        }
    }
}
