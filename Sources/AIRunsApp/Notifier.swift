import AIRunsCore
import AppKit
import UserNotifications

/// Which moments to announce; set in Settings.
enum NotificationSettings {
    static func key(_ kind: AlertKind) -> String { "notify.\(kind.rawValue)" }
    static let remindKey = "notify.remind"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            key(.approval): true, key(.input): true, key(.replied): false, key(.done): false, key(.stalled): false,
            remindKey: true,
        ])
    }

    static var enabled: Set<AlertKind> {
        Set(AlertKind.allCases.filter { UserDefaults.standard.bool(forKey: key($0)) })
    }

    static var remind: Bool { UserDefaults.standard.bool(forKey: remindKey) }
}

/// Posts a notification when a session starts needing the user, withdraws it
/// when that moment is over, and handles Open / Snooze.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Opens a session by its ID (set by the app model).
    var open: ((String) -> Void)?
    /// Holds a session for three hours by its ID (set by the app model).
    var hold: ((String) -> Void)?

    private var planner = AlertPlanner()
    private var primed = false
    /// The sessions from the last update. A stall is the absence of events,
    /// so no update announces it: a timer re-checks these instead.
    private var lastSessions: [Session] = []
    private var recheckTimer: Timer?
    private static let recheckEvery: TimeInterval = 60
    private static let category = "session"
    /// Questions and replies, which can be held; approvals can't.
    private static let waitingCategory = "session-waiting"
    private static let holdAction = "hold"
    /// Delivered by earlier versions as "Ignore"; now holds like the new button.
    private static let legacyIgnoreAction = "ignore"
    private static let openAction = "open"
    private static let snoozeAction = "snooze"
    private static let remindAfter: TimeInterval = 15 * 60

    /// Notifications need a bundle; a bare `swift run` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        NotificationSettings.registerDefaults()
        guard let center else { return }
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open", options: [.foreground])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 15m", options: [])
        let hold = UNNotificationAction(identifier: Self.holdAction, title: "Hold 3 Hours", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [open, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.waitingCategory, actions: [open, snooze, hold], intentIdentifiers: []),
        ])
    }

    // MARK: Permission

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// Shows the system prompt the first time; afterwards macOS remembers the answer.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Updates

    func update(sessions: [Session]) {
        lastSessions = sessions
        startRechecking()
        let now = Date()
        guard !primed else {
            return post(planner.changes(in: sessions, enabled: NotificationSettings.enabled, now: now), now: now)
        }
        planner.prime(sessions, now: now)
        primed = true
    }

    /// Runs the planner again on the last sessions, so a run that went quiet
    /// is announced (and its notification withdrawn once it reports again).
    private func recheck() {
        guard primed else { return }
        let now = Date()
        post(planner.changes(in: lastSessions, enabled: NotificationSettings.enabled, now: now), now: now)
    }

    private func startRechecking() {
        guard recheckTimer == nil else { return }
        let timer = Timer(timeInterval: Self.recheckEvery, repeats: true) { _ in
            MainActor.assumeIsolated { Notifier.shared.recheck() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    private var askedThisLaunch = false

    private func post(_ changes: (post: [Session], ended: [String]), now: Date) {
        guard let center else { return }
        // Ask for permission the first time there is something worth showing,
        // rather than at launch when the user doesn't know why yet.
        if !changes.post.isEmpty, !askedThisLaunch {
            askedThisLaunch = true
            Task {
                if await authorizationStatus() == .notDetermined { await requestAuthorization() }
                post(changes, now: now)
            }
            return
        }
        if !changes.ended.isEmpty {
            let ids = changes.ended.flatMap { ["alert-\($0)", "remind-\($0)", "snooze-\($0)"] }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for session in changes.post {
            guard let kind = session.alertKind(now: now) else { continue }
            // Not while the user is already looking at that session's app. A
            // browser is skipped only for agents: the chat may be in another tab.
            if !session.tool.isWeb, let host = Jumper.hostBundle(for: session), host == front { continue }
            let content = Self.content(for: session, kind: kind)
            center.add(UNNotificationRequest(identifier: "alert-\(session.id)", content: content, trigger: nil))
            if NotificationSettings.remind, kind == .approval || kind == .input {
                let reminder = content.mutableCopy() as! UNMutableNotificationContent
                reminder.title = "Still waiting: \(session.title)"
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.remindAfter, repeats: false)
                center.add(UNNotificationRequest(identifier: "remind-\(session.id)", content: reminder, trigger: trigger))
            }
        }
    }

    static func content(for session: Session, kind: AlertKind) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let tool: String
        switch session.tool {
        case .claudeCode: tool = "Claude"
        case .codex: tool = "Codex"
        case .chatgpt, .claudeWeb: tool = session.tool.displayName
        }
        content.title = session.title
        switch kind {
        case .approval:
            content.subtitle = "\(tool) · Approve"
            content.body = "Wants to run " + (session.approvalDetail ?? "a tool")
            content.sound = .default
        case .input:
            content.subtitle = "\(tool) · \(session.native?.state.heading ?? "Needs input")"
            content.body = session.approvalDetail.map { "“\($0)”" }
                ?? TextUtils.preview(of: session.lastMessage, limit: 160) ?? "It needs your input."
            content.sound = .default
        case .replied:
            content.subtitle = "\(tool) · \(session.native?.state.heading ?? "Replied")"
            content.body = TextUtils.preview(of: session.lastMessage, limit: 160) ?? "It finished its turn."
        case .done:
            content.subtitle = "\(tool) · Done"
            content.body = TextUtils.preview(of: session.lastMessage, limit: 160) ?? "It finished."
        case .stalled:
            content.subtitle = "\(tool) · No update"
            content.body = "No events for \(Int(Session.quietThreshold / 60)) minutes — it may have stopped."
        }
        content.threadIdentifier = session.id
        content.categoryIdentifier = kind == .input || kind == .replied ? waitingCategory : category
        content.userInfo = ["session": session.id]
        return content
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        let snoozed = response.notification.request.content.mutableCopy() as? UNMutableNotificationContent
        await MainActor.run {
            switch action {
            case Self.snoozeAction:
                guard let snoozed else { return }
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.remindAfter, repeats: false)
                UNUserNotificationCenter.current()
                    .add(UNNotificationRequest(identifier: "snooze-\(id)", content: snoozed, trigger: trigger))
            case Self.holdAction, Self.legacyIgnoreAction:
                Notifier.shared.hold?(id)
            case UNNotificationDismissActionIdentifier:
                break
            default:
                Notifier.shared.open?(id)
            }
        }
    }
}
