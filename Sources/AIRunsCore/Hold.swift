import Foundation

/// The user put a session aside until a time ("Hold"), or until they check
/// back with someone ("Waiting on…"). The session's real state is tracked
/// separately and keeps changing underneath.
public struct SessionHold: Codable, Equatable, Sendable {
    /// When it comes back to Needs you.
    public var until: Date
    /// Set for "Waiting on…": who or what the user waits for. Empty means
    /// nobody was named.
    public var waitingOn: String?
    /// When the user put it on hold.
    public var heldAt: Date
    /// Set once `until` has passed: the session is back in Needs you, with
    /// "Back from hold", until the user opens it.
    public var returnedAt: Date?

    public init(until: Date, waitingOn: String? = nil, heldAt: Date, returnedAt: Date? = nil) {
        self.until = until
        self.waitingOn = waitingOn
        self.heldAt = heldAt
        self.returnedAt = returnedAt
    }

    public var isWaiting: Bool { waitingOn != nil }

    /// The name to show, or nil when nobody was named.
    public var waitingName: String? {
        guard let name = waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// "Back from hold" or "Check back with Li".
    public var returnText: String {
        guard isWaiting else { return "Back from hold" }
        return waitingName.map { "Check back with \($0)" } ?? "Check back"
    }
}

extension Session {
    /// On hold and not yet due: out of Needs you and the menu bar count.
    public var isHeld: Bool { hold != nil && hold?.returnedAt == nil }
    /// Its hold came due: back in Needs you until the user opens it.
    public var isBackFromHold: Bool { hold?.returnedAt != nil }
    /// Only a session waiting for approval can't be held: approval never waits.
    public var canHold: Bool { state != .needsApproval }
}

/// Where a hold can land, and when that is. All dates are local, computed with
/// an injected calendar and clock, so tests can pin the day, time zone and
/// daylight-saving changes.
public struct HoldPlan: Sendable {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    /// The quick choices in a row's menu, and what dropping on the line does.
    public enum Preset: String, CaseIterable, Sendable {
        /// Later today: three hours from now, while that is still this evening.
        case later
        /// 9:00 tomorrow.
        case tomorrow
        /// 9:00 Friday, or next Monday when Friday is less than two days away.
        case week
        /// Waiting on someone: check back at 9:00 two days from now.
        case waiting
    }

    public static let laterInterval: TimeInterval = 3 * 3600
    public static let morningHour = 9
    /// "Today" never means later than this hour; nobody wants a session back at night.
    public static let eveningHour = 21
    static let latestHour = 22
    /// Never closer than this, so a hold always means something.
    static let minimumLead: TimeInterval = 15 * 60

    public func date(for preset: Preset) -> Date {
        switch preset {
        case .later: return laterToday ?? morning(daysAhead: 1)
        case .tomorrow: return morning(daysAhead: 1)
        case .week:
            let toFriday = 6 - weekday(now) // Friday is 6 in a Gregorian weekday
            return morning(daysAhead: toFriday >= 2 ? toFriday : daysToNextMonday)
        case .waiting: return morning(daysAhead: 2)
        }
    }

    /// When "Today" brings a session back: three hours from now. In the
    /// evening that would be at night, so it is 21:00 instead while that is at
    /// least an hour away, and after that there is no "Today" any more.
    public var laterToday: Date? {
        let candidate = now.addingTimeInterval(Self.laterInterval)
        let today = calendar.startOfDay(for: now)
        if let latest = calendar.date(bySettingHour: Self.latestHour, minute: 0, second: 0, of: today),
           calendar.isDate(candidate, inSameDayAs: now), candidate <= latest {
            return candidate
        }
        if let evening = calendar.date(bySettingHour: Self.eveningHour, minute: 0, second: 0, of: today),
           evening.timeIntervalSince(now) >= 3600 {
            return evening
        }
        return nil
    }

    /// The quick choices on offer right now. "Today" is left out late in the evening.
    public var presets: [Preset] { laterToday == nil ? [.tomorrow, .week] : [.later, .tomorrow, .week] }

    /// 9:00 on the day `days` after today, never in the past.
    public func morning(daysAhead days: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: days, to: today) ?? today
        let nine = calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: day) ?? day
        return max(nine, now.addingTimeInterval(Self.minimumLead))
    }

    private func weekday(_ date: Date) -> Int { calendar.component(.weekday, from: date) }

    /// Days from today to the next Monday (1 on a Sunday, 7 on a Monday).
    var daysToNextMonday: Int {
        let days = (9 - weekday(now)) % 7
        return days == 0 ? 7 : days
    }

    // MARK: The line

    /// One labelled stretch of the line. Dropping on it holds until `dropDate`.
    public struct Segment: Equatable, Sendable, Identifiable {
        /// Days after today; 0 is Today.
        public var daysAhead: Int
        public var label: String
        /// True for the stretch into next Monday, drawn dashed for the weekend.
        public var isNextWeek: Bool
        /// Nil for Today late in the evening: nothing can be dropped there.
        public var dropDate: Date?
        public var id: Int { daysAhead }
        public var isToday: Bool { daysAhead == 0 }
    }

    /// Today, each remaining weekday through Friday, then next Monday. On a
    /// Friday or at the weekend: Today and Monday.
    public var segments: [Segment] {
        let day = weekday(now)
        let lastWeekday = (2...6).contains(day) ? 6 - day : 0
        var result = (0...lastWeekday).map { offset in
            Segment(daysAhead: offset, label: offset == 0 ? "Today" : dayName(daysAhead: offset),
                    isNextWeek: false,
                    dropDate: offset == 0 ? laterToday : morning(daysAhead: offset))
        }
        result.append(Segment(daysAhead: daysToNextMonday, label: dayName(daysAhead: daysToNextMonday),
                              isNextWeek: true, dropDate: morning(daysAhead: daysToNextMonday)))
        return result
    }

    /// Calendar days from today to `date`'s day; 0 or less is today.
    public func daysAhead(of date: Date) -> Int {
        let from = calendar.startOfDay(for: now), to = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// The stretch a held session is drawn on. Anything past the line sits on its last stretch.
    public func segment(for date: Date) -> Segment {
        let all = segments
        let days = daysAhead(of: date)
        if days <= 0 { return all[0] }
        return all.first { $0.daysAhead == days } ?? all[all.count - 1]
    }

    /// True when `date` falls after the line's last stretch, so its row must say the full date.
    public func isBeyondLine(_ date: Date) -> Bool {
        daysAhead(of: date) > (segments.last?.daysAhead ?? 0)
    }

    /// True when `date` is on the very day its stretch is named after. A
    /// Saturday sits on the dashed stretch into Monday and is not.
    public func isOnLabelledDay(_ date: Date) -> Bool {
        max(0, daysAhead(of: date)) == segment(for: date).daysAhead
    }

    /// When a held session comes back, as said under its stretch and in its
    /// tray: just the time on the stretch's own day ("3:00 PM"), otherwise the
    /// day too ("Sat 9:00 AM", "Tue 8 Dec 9:00 AM"), so a weekend date is never
    /// read as Monday.
    public func returnText(_ date: Date) -> String {
        if isOnLabelledDay(date) { return time(date) }
        let days = daysAhead(of: date)
        let day = isBeyondLine(date)
            ? Self.formatter("EEE d MMM", calendar: calendar).string(from: date)
            : dayName(daysAhead: days)
        return "\(day) \(time(date))"
    }

    // MARK: Words

    /// "Mon", "Tue"…
    public func dayName(daysAhead days: Int) -> String {
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        return Self.formatter("EEE", calendar: calendar).string(from: day)
    }

    /// "3:00 PM"
    public func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// "today 3:00 PM", "tomorrow 9:00 AM", "Thu 9:00 AM", "Mon 1 Dec 9:00 AM" (past the line).
    public func when(_ date: Date) -> String {
        let days = daysAhead(of: date)
        let day: String
        switch days {
        case ...0: day = "today"
        case 1: day = "tomorrow"
        default:
            day = isBeyondLine(date)
                ? Self.formatter("EEE d MMM", calendar: calendar).string(from: date)
                : dayName(daysAhead: days)
        }
        return "\(day) \(time(date))"
    }

    /// What a drag chip or menu item says: "Back today 3:00 PM", "Back Thu 9:00 AM".
    public func backText(_ date: Date) -> String { "Back \(when(date))" }

    /// A menu item for a preset: "Today", "Tomorrow", "Fri", "Waiting on…", with the time it means.
    public func title(for preset: Preset) -> String {
        let date = date(for: preset)
        switch preset {
        case .waiting: return "Waiting on… · check back \(when(date))"
        case .later, .tomorrow, .week:
            let when = self.when(date)
            return when.prefix(1).uppercased() + when.dropFirst()
        }
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
