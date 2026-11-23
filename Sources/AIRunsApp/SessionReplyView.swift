import AIRunsCore
import SwiftUI

/// Keep the text on screen and the value captured by Save in the same render.
struct SessionReplyView: View {
    let session: Session
    @ObservedObject var model: AppModel

    var body: some View {
        if let reply = session.currentTopicReply,
           !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let saved = model.board.savedReply(session: session) != nil
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Last reply")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        model.saveReply(session)
                    } label: {
                        Label(saved ? "Saved" : "Save Reply", systemImage: saved ? "bookmark.fill" : "bookmark")
                            .font(AppTypography.metadata)
                    }
                    .buttonStyle(.borderless)
                    .disabled(saved)
                    .accessibilityIdentifier("session.\(session.id).save-reply")
                }
                Text(verbatim: reply)
                    .font(AppTypography.body)
                    .lineLimit(8)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
    }
}
