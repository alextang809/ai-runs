import Foundation

/// The kinds of moment AI Runs can notify about.
public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case approval   // APPROVE
    case input      // NEEDS INPUT
    case replied    // REPLIED
    case done       // DONE
}

extension Session {
    /// What this session would notify about right now, if anything.
    public var alertKind: AlertKind? {
        switch state {
        case .needsApproval: return .approval
        case .yourTurn:
            switch outcome {
            case .needsInput: return .input
            case .done: return .done
            default: return .replied
            }
        case .working: return nil
        }
    }

    /// Identifies one waiting moment, so each one is announced once.
    var alertSignature: String? {
        alertKind.map { "\($0.rawValue)|\((waitingSince ?? lastEventAt).timeIntervalSince1970)" }
    }
}

/// Decides which sessions to announce. Each waiting moment is announced at
/// most once; moments that end are reported so their notifications can be
/// withdrawn.
public struct AlertPlanner: Sendable {
    private var seen: [String: String] = [:]

    public init() {}

    /// Records the current moments without announcing them (on launch, so
    /// opening the app doesn't replay old news).
    public mutating func prime(_ sessions: [Session]) {
        seen = [:]
        for session in sessions {
            if let signature = session.alertSignature { seen[session.id] = signature }
        }
    }

    /// - Returns: sessions to announce, and IDs of sessions whose moment ended
    ///   or changed (their earlier notification is stale).
    public mutating func changes(in sessions: [Session], enabled: Set<AlertKind>) -> (post: [Session], ended: [String]) {
        var post: [Session] = []
        var ended: [String] = []
        var current: [String: String] = [:]
        for session in sessions {
            guard let signature = session.alertSignature, let kind = session.alertKind else { continue }
            current[session.id] = signature
            if seen[session.id] != signature {
                if seen[session.id] != nil { ended.append(session.id) }
                if enabled.contains(kind) { post.append(session) }
            }
        }
        for id in seen.keys where current[id] == nil { ended.append(id) }
        seen = current
        return (post, ended)
    }
}
