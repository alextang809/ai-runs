import Foundation

/// Sessions working in the same repository at once, which can step on each
/// other's edits.
public enum Overlap {
    /// For each working session that shares a folder with another working
    /// session (the same `cwd`, or one inside the other), the other sessions,
    /// in the order given. Sessions without a folder (web chats) never overlap.
    /// - Returns: keyed by session id; sessions with no overlap are absent.
    public static func sameRepo(_ sessions: [Session]) -> [String: [Session]] {
        let working: [(session: Session, path: String)] = sessions.compactMap { session in
            guard session.state == .working, let path = standardized(session.cwd) else { return nil }
            return (session, path)
        }
        var result: [String: [Session]] = [:]
        for (index, item) in working.enumerated() {
            var others: [Session] = []
            for (otherIndex, other) in working.enumerated() where otherIndex != index {
                guard other.session.id != item.session.id else { continue }
                if contains(item.path, other.path) || contains(other.path, item.path) { others.append(other.session) }
            }
            if !others.isEmpty { result[item.session.id] = others }
        }
        return result
    }

    /// True when `inner` is `outer` or a folder inside it: `/a/b` is inside
    /// `/a`, `/a/bc` is not.
    static func contains(_ outer: String, _ inner: String) -> Bool {
        if inner == outer { return true }
        let prefix = outer.hasSuffix("/") ? outer : outer + "/"
        return inner.hasPrefix(prefix)
    }

    static func standardized(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var standard = (path as NSString).expandingTildeInPath
        standard = URL(fileURLWithPath: standard).standardizedFileURL.path
        while standard.count > 1, standard.hasSuffix("/") { standard.removeLast() }
        return standard
    }
}
