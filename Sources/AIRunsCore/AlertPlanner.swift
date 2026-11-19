import Foundation

/// The kinds of moment AI Runs can notify about.
public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case approval   // APPROVE
    case input      // NEEDS INPUT
    case replied    // REPLIED
    case done       // DONE
    case stalled    // NO UPDATE
}

extension Session {
    /// What this session would notify about at `now`, if anything.
    public func alertKind(now: Date = Date()) -> AlertKind? {
        switch state {
        case .unknown: return nil
        case .needsApproval: return .approval
        case .yourTurn:
            if isIgnored { return nil }
            switch outcome {
            case .needsInput: return .input
            // "Idle" in Claude's list isn't news that work finished.
            case .done: return native == nil ? .done : nil
            default: return .replied
            }
        case .working:
            // Waiting on background tasks or a wake-up is expected quiet, not a stall.
            return isQuiet(now: now) && !isInBackground ? .stalled : nil
        }
    }

    /// Identifies one waiting moment, so each one is announced once. A stall
    /// is keyed by its last event, so it stays the same until a new event ends it.
    func alertSignature(now: Date = Date()) -> String? {
        guard let kind = alertKind(now: now) else { return nil }
        let since = kind == .stalled ? lastEventAt : (waitingSince ?? lastEventAt)
        return "\(kind.rawValue)|\(since.timeIntervalSince1970)"
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
    public mutating func prime(_ sessions: [Session], now: Date = Date()) {
        seen = [:]
        for session in sessions {
            if let signature = session.alertSignature(now: now) { seen[session.id] = signature }
        }
    }

    /// - Returns: sessions to announce, and IDs of sessions whose moment ended
    ///   or changed (their earlier notification is stale).
    public mutating func changes(in sessions: [Session], enabled: Set<AlertKind>,
                                 now: Date = Date()) -> (post: [Session], ended: [String]) {
        var post: [Session] = []
        var ended: [String] = []
        var current: [String: String] = [:]
        for session in sessions {
            guard let kind = session.alertKind(now: now), let signature = session.alertSignature(now: now) else { continue }
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
