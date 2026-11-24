import Foundation

/// What a session was doing over a stretch of time.
public enum SpanKind: String, Codable, Sendable {
    case working
    case waiting
    case background
}

/// One stretch of a session's lifeline. `end` is nil while it lasts.
public struct ActivitySpan: Codable, Equatable, Sendable {
    public var kind: SpanKind
    public var start: Date
    public var end: Date?

    public init(kind: SpanKind, start: Date, end: Date? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    public func end(or now: Date) -> Date { end ?? now }

    /// Seconds of this span that fall inside `from..<to`.
    public func overlap(from: Date, to: Date, now: Date) -> TimeInterval {
        let a = max(start, from), b = min(end(or: now), to)
        return max(0, b.timeIntervalSince(a))
    }
}

extension SpanKind {
    init?(_ session: Session) {
        switch session.state {
        case .unknown: return nil
        case .needsApproval: self = .waiting
        // An ignored or held wait is not time the user kept an agent waiting.
        case .yourTurn: self = session.isDone || session.isIgnored || session.isHeld ? .background : .waiting
        case .working: self = session.isInBackground ? .background : .working
        }
    }
}

/// Numbers for the panel header, computed from all lifelines.
public struct ActivityStats: Equatable, Sendable {
    /// Minutes of work and of waiting per bucket, oldest first.
    public var buckets: [(working: Double, waiting: Double)]
    /// Minutes agents worked per bucket, split by tool, oldest first.
    public var toolBuckets: [(claude: Double, codex: Double)] = []
    /// Total time sessions waited on the user since local midnight.
    public var waitedToday: TimeInterval
    /// Average time the user took to answer a waiting session today; nil before the first answer.
    public var averageReply: TimeInterval?
    /// Sessions active at some point since local midnight.
    public var sessionsToday: Int

    public static func == (lhs: ActivityStats, rhs: ActivityStats) -> Bool {
        lhs.waitedToday == rhs.waitedToday && lhs.averageReply == rhs.averageReply
            && lhs.sessionsToday == rhs.sessionsToday
            && lhs.buckets.map(\.working) == rhs.buckets.map(\.working)
            && lhs.buckets.map(\.waiting) == rhs.buckets.map(\.waiting)
    }

    public static func compute(history: [String: [ActivitySpan]], now: Date, window: TimeInterval = 2 * 3600,
                               bucketCount: Int = 16, calendar: Calendar = .current) -> ActivityStats {
        let size = window / Double(bucketCount)
        let origin = now.addingTimeInterval(-window)
        var buckets = Array(repeating: (working: 0.0, waiting: 0.0), count: bucketCount)
        var toolBuckets = Array(repeating: (claude: 0.0, codex: 0.0), count: bucketCount)
        let midnight = calendar.startOfDay(for: now)
        var waited: TimeInterval = 0
        var replies: [TimeInterval] = []
        var today = 0

        for (key, spans) in history {
            let isCodex = key.hasPrefix(AgentTool.codex.rawValue + ":")
            if spans.contains(where: { $0.end(or: now) > midnight }) { today += 1 }
            for span in spans {
                for index in 0..<bucketCount {
                    let from = origin.addingTimeInterval(Double(index) * size)
                    let seconds = span.overlap(from: from, to: from.addingTimeInterval(size), now: now)
                    guard seconds > 0 else { continue }
                    switch span.kind {
                    case .working, .background:
                        buckets[index].working += seconds / 60
                        if isCodex { toolBuckets[index].codex += seconds / 60 } else { toolBuckets[index].claude += seconds / 60 }
                    case .waiting: buckets[index].waiting += seconds / 60
                    }
                }
                if span.kind == .waiting {
                    waited += span.overlap(from: midnight, to: now, now: now)
                    if let end = span.end, end > midnight { replies.append(end.timeIntervalSince(span.start)) }
                }
            }
        }
        let average = replies.isEmpty ? nil : replies.reduce(0, +) / Double(replies.count)
        return ActivityStats(buckets: buckets, toolBuckets: toolBuckets, waitedToday: waited, averageReply: average,
                             sessionsToday: today)
    }
}

extension SessionStore {
    /// Records the session's current kind at `at`, closing the previous span
    /// when the kind changed. Pass nil to close the lifeline (session ended).
    mutating func record(_ kind: SpanKind?, for key: String, at: Date) {
        var all = history ?? [:]
        var spans = all[key] ?? []
        if let last = spans.last, last.end == nil {
            if last.kind == kind { return }
            spans[spans.count - 1].end = max(at, last.start)
        }
        if let kind { spans.append(ActivitySpan(kind: kind, start: at)) }
        // Keep a day of history and at most 200 spans per session.
        let cutoff = at.addingTimeInterval(-24 * 3600)
        spans.removeAll { ($0.end ?? at) < cutoff }
        if spans.count > 200 { spans.removeFirst(spans.count - 200) }
        all[key] = spans.isEmpty ? nil : spans
        history = all
    }

    public static let lifelineWindow: TimeInterval = 60 * 60

    /// The last `window` of a session's lifeline.
    public func lifeline(for id: String, now: Date, window: TimeInterval = SessionStore.lifelineWindow) -> [ActivitySpan] {
        let from = now.addingTimeInterval(-window)
        return (history?[id] ?? []).filter { $0.end(or: now) > from }
    }

    /// Observed active work in the latest completed turn, even after it leaves the rolling lifeline.
    public func completedWorkDuration(for id: String) -> TimeInterval? {
        guard let session = sessions[id], session.isDone, let end = session.waitingSince,
              session.turnStartedAt < end, let spans = history?[id] else { return nil }

        let working = spans.filter { $0.kind == .working }.sorted { $0.start < $1.start }
        let observed = working.reduce((end: session.turnStartedAt, duration: 0.0)) { partial, span in
            let duration = span.overlap(from: partial.end, to: end, now: end)
            guard duration > 0 else { return partial }
            return (min(span.end(or: end), end), partial.duration + duration)
        }
        return observed.duration.isFinite && observed.duration > 0 ? observed.duration : nil
    }

    public func stats(now: Date, calendar: Calendar = .current) -> ActivityStats {
        ActivityStats.compute(history: history ?? [:], now: now, calendar: calendar)
    }
}
