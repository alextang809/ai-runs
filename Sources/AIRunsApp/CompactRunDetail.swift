import AIRunsCore
import Foundation
import SwiftUI

/// Only information that changes what the user needs to do belongs in a compact row.
/// Activity logs, source metadata and historical evidence stay in the detail flyout.
enum CompactRunDetail: Equatable {
    case approval(String)
    case question(String)
    case progress(RunProgress)

    static func resolve(_ session: Session, now: Date) -> Self? {
        guard session.native == nil, !session.isIgnored else { return nil }
        let detail = session.approvalDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch session.state {
        case .needsApproval:
            // The parser falls back to tool_name when no command or target is supplied.
            if let detail, detail.hasPrefix("mcp__"),
               !detail.contains(where: { $0.isWhitespace }) { return nil }
            return detail.flatMap { $0.isEmpty ? nil : .approval($0) }
        case .yourTurn where session.outcome == .needsInput:
            return detail.flatMap { $0.isEmpty ? nil : .question($0) }
        case .working:
            guard !session.isInBackground, !session.isQuiet(now: now),
                  let progress = session.progress, progress.total > 0,
                  progress.done >= 0, progress.done < progress.total else { return nil }
            return .progress(progress)
        default:
            return nil
        }
    }
}

struct CompactRunDetailLine: View {
    let detail: CompactRunDetail

    var body: some View {
        Group {
            switch detail {
            case .approval(let action):
                Text("Allow: \(action)").truncationMode(.middle)
            case .question(let question):
                Text(question)
            case .progress(let progress):
                Text(progress.summary)
            }
        }
        .font(AppTypography.body)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
