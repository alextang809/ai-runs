import AIRunsCore
import SwiftUI

struct BoardLinkEditor: View {
    let card: PinCard
    @ObservedObject var model: AppModel
    let close: () -> Void

    @State private var selectedSessionID: String?
    @State private var artifactURL = ""
    @State private var artifactTitle = ""
    @State private var error: String?

    private var availableSessions: [Session] {
        model.pinSessionCandidates.filter { session in
            let attachment = PinAttachment.session(session)
            return !card.attachments.contains { $0.matches(attachment) }
        }
    }

    private var selectedSession: Session? {
        availableSessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: close) {
                    Label("Pinned", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Text("Manage Links")
                    .font(AppTypography.rowTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(card.title)
                        .font(AppTypography.rowTitle)
                        .lineLimit(2)
                    sessionForm
                    artifactForm
                    if !card.attachments.isEmpty {
                        Divider()
                        linkedItems
                    }
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var sessionForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Link a Session").font(AppTypography.section).foregroundStyle(.secondary)
            if availableSessions.isEmpty {
                Text("No unlinked Codex or Claude sessions")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Picker("Session", selection: $selectedSessionID) {
                        Text("Choose a session").tag(nil as String?)
                        ForEach(availableSessions) { session in
                            Text(sessionPickerLabel(session)).tag(Optional(session.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Button("Add", action: addSession)
                        .disabled(selectedSession == nil)
                        .accessibilityLabel("Add selected session")
                }
                .controlSize(.small)
            }
        }
    }

    private var artifactForm: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Link an Artifact").font(AppTypography.section).foregroundStyle(.secondary)
            TextField("https://…", text: $artifactURL)
                .accessibilityLabel("Artifact URL")
                .textFieldStyle(.roundedBorder)
                .onSubmit(addArtifact)
            HStack(spacing: 6) {
                TextField("Title (optional)", text: $artifactTitle)
                    .accessibilityLabel("Artifact title (optional)")
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addArtifact)
                Button("Add Link", action: addArtifact)
                    .disabled(artifactURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Text(error)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    private var linkedItems: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Linked Items").font(AppTypography.section).foregroundStyle(.secondary)
            ForEach(card.attachments) { attachment in
                HStack(spacing: 6) {
                    Label(attachment.boardTitle, systemImage: attachment.boardIcon)
                        .font(AppTypography.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(attachment.title)
                    Spacer(minLength: 0)
                    Button {
                        model.detach(attachment.id, from: card.id)
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(width: 23, height: 23)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(attachment.title) from this card")
                    .help("Remove link from this card")
                }
            }
        }
    }

    private func sessionPickerLabel(_ session: Session) -> String {
        let title = "\(session.tool.displayName) · \(session.currentTopicTitle)"
        return session.project.isEmpty ? title : "\(title) · \(session.project)"
    }

    private func addSession() {
        guard let selectedSession, model.attach(PinAttachment.session(selectedSession), to: card.id) else { return }
        selectedSessionID = nil
    }

    private func addArtifact() {
        guard let attachment = PinAttachment.artifact(artifactURL, title: artifactTitle) else {
            error = "Enter a complete HTTP or HTTPS URL."
            return
        }
        guard !card.attachments.contains(where: { $0.matches(attachment) }) else {
            error = "This link is already on the card."
            return
        }
        guard model.attach(attachment, to: card.id) else {
            error = "Couldn’t add this link."
            return
        }
        artifactURL = ""
        artifactTitle = ""
        error = nil
    }
}

extension PinAttachment {
    var boardTitle: String {
        boardTool.map { "\($0.displayName) · \(title)" } ?? title
    }

    var boardIcon: String {
        switch link {
        case .session: return "bubble.left"
        case .url: return boardTool == nil ? "link" : "bubble.left"
        case .app: return "macwindow"
        }
    }

    private var boardTool: AgentTool? {
        switch link {
        case .session(let tool, _, _, _):
            return tool
        case .url(let target):
            let address = URL(string: target)
            return address?.scheme == "claude" || address?.host == "claude.ai" ? .claudeCode : nil
        case .app:
            return nil
        }
    }
}
