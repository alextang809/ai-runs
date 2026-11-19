import AIRunsCore

/// The home screen replaces the session dashboard only when no run needs
/// attention or is working. Unknown observations remain visible on either screen.
struct MenuSessionPresentation {
    let needs: [Session]
    let working: [Session]
    let unknown: [Session]
    let done: [Session]
    let ignored: [Session]

    init(sessions: [Session]) {
        needs = sessions.filter { $0.needsUser }
        working = sessions.filter { $0.state == .working }
        unknown = sessions.filter { $0.state == .unknown }
        done = sessions.filter { $0.isDone }
        ignored = sessions.filter { $0.isIgnored }
    }

    var hasActiveSessions: Bool { !needs.isEmpty || !working.isEmpty }
    var recent: [Session] { done + ignored }
}
