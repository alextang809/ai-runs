import AIRunsCore

/// The home screen replaces the session dashboard only when no run needs
/// attention or is working. Unknown observations remain visible on either screen.
struct MenuSessionPresentation {
    let needs: [Session]
    let pinned: [Session]
    let working: [Session]
    let unknown: [Session]
    let done: [Session]
    let ignored: [Session]

    init(sessions: [Session]) {
        needs = sessions.filter(\.needsUser)
        let others = sessions.filter { !$0.needsUser }
        pinned = others.filter(\.isPinned).sorted {
            $0.pinnedAt == $1.pinnedAt ? $0.id < $1.id : ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast)
        }
        let unpinned = others.filter { !$0.isPinned }
        working = unpinned.filter { $0.state == .working }
        unknown = unpinned.filter { $0.state == .unknown }
        done = unpinned.filter(\.isDone)
        ignored = unpinned.filter(\.isIgnored)
    }

    var hasActiveSessions: Bool { !needs.isEmpty || !pinned.isEmpty || !working.isEmpty }
    var recent: [Session] { done + ignored }
}
