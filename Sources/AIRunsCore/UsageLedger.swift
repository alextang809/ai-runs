import Foundation

public enum UsageCoverage: String, Sendable { case unavailable, scanning, partial, complete }

public struct UsageModelTotal: Equatable, Identifiable, Sendable {
    public let model: String
    public let counts: TokenCounts
    public var id: String { model }
}

public struct ProviderTokenUsage: Equatable, Identifiable, Sendable {
    public let provider: UsageProvider
    public let counts: TokenCounts?
    public let coverage: UsageCoverage
    public let issues: Set<UsageIssue>
    public let models: [UsageModelTotal]
    public let costHistory: UsageCostHistory?
    public var id: UsageProvider { provider }

    init(provider: UsageProvider, counts: TokenCounts?, coverage: UsageCoverage,
         issues: Set<UsageIssue>, models: [UsageModelTotal], costHistory: UsageCostHistory? = nil) {
        self.provider = provider
        self.counts = counts
        self.coverage = coverage
        self.issues = issues
        self.models = models
        self.costHistory = costHistory
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let period: UsagePeriod
    public let providers: [ProviderTokenUsage]
    public let updatedAt: Date?

    public static func loading(period: UsagePeriod = .last24Hours) -> Self {
        Self(period: period, providers: UsageProvider.allCases.map {
            ProviderTokenUsage(provider: $0, counts: nil, coverage: .scanning, issues: [], models: [])
        }, updatedAt: nil)
    }
}

/// One request is counted once across transcripts, archives and copied history.
/// Canonical response records also suppress their legacy cumulative mirrors.
public enum UsageLedger {
    public static func snapshot(_ output: UsageScanOutput, period: UsagePeriod,
                                now: Date = Date(), calendar: Calendar = .current) -> UsageSnapshot {
        var issues = output.issues
        let records = deduplicated(output.records, issues: &issues)
        let responseKeys = Set(records.filter { $0.evidence == .response }.compactMap { record in
            record.reconciliationKey.map { "\(record.provider.rawValue):\($0)" }
        })
        let accepted = records.filter { record in
            guard record.evidence == .legacy, let key = record.reconciliationKey else { return true }
            return !responseKeys.contains("\(record.provider.rawValue):\(key)")
        }
        let interval = period.interval(now: now, calendar: calendar)
        let byProvider = Dictionary(grouping: accepted, by: \.provider)
        let providers = UsageProvider.allCases.map { provider in
            let records = byProvider[provider] ?? []
            let available = output.availableProviders.contains(provider)
            let providerIssues = issues[provider] ?? []
            let scan = ProviderScan(available: available, scanning: output.scanning, issues: providerIssues,
                                    hasPastRecords: records.contains { $0.timestamp <= now })
            let history = costHistory(provider, records: records, scan: scan, now: now, calendar: calendar)
            let window = windowRecords(records, in: interval)
            return summarize(provider, window: window,
                             hasEvidence: scan.hasEvidence(in: window), scanning: output.scanning,
                             issues: providerIssues, costHistory: history)
        }
        return UsageSnapshot(period: period, providers: providers, updatedAt: output.refreshedAt)
    }

    private static func deduplicated(_ records: [UsageRecord],
                                    issues: inout [UsageProvider: Set<UsageIssue>]) -> [UsageRecord] {
        var requests: [String: UsageRecord] = [:]
        for record in records {
            guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.id.utf8.count <= 4_096, record.timestamp.timeIntervalSince1970.isFinite else {
                issues[record.provider, default: []].insert(.missingIdentity)
                continue
            }
            let key = "\(record.provider.rawValue):\(record.id)"
            guard let prior = requests[key] else { requests[key] = record; continue }
            if prior.evidence == .legacy, record.evidence == .legacy {
                if prior.counts != record.counts { issues[record.provider, default: []].insert(.inconsistentUsage) }
                requests[key] = conservativeLegacy(prior, record)
                continue
            }
            if prior.isFinal == record.isFinal, prior.counts != record.counts,
               prior.counts.subtracting(record.counts) == nil, record.counts.subtracting(prior.counts) == nil {
                issues[record.provider, default: []].insert(.inconsistentUsage)
            }
            requests[key] = preferred(prior, record)
        }
        return Array(requests.values)
    }

    /// A legacy ID identifies a cumulative checkpoint, not a growing response.
    /// Conflicting per-file baselines cannot justify choosing a larger delta.
    private static func conservativeLegacy(_ first: UsageRecord, _ second: UsageRecord) -> UsageRecord {
        let a = first.counts, b = second.counts
        let counts = TokenCounts(input: min(a.input, b.input), output: min(a.output, b.output),
                                 cacheRead: min(a.cacheRead, b.cacheRead), cacheWrite: min(a.cacheWrite, b.cacheWrite),
                                 reasoning: min(a.reasoning, b.reasoning)) ?? .zero
        let origin = first.timestamp <= second.timestamp ? first : second
        return UsageRecord(id: origin.id, provider: origin.provider, timestamp: origin.timestamp,
                           counts: counts, model: origin.model, evidence: .legacy,
                           reconciliationKey: origin.reconciliationKey, isFinal: first.isFinal && second.isFinal)
    }

    private static func preferred(_ earlier: UsageRecord, _ later: UsageRecord) -> UsageRecord {
        if earlier.isFinal != later.isFinal { return later.isFinal ? later : earlier }
        if earlier.timestamp != later.timestamp { return later.timestamp > earlier.timestamp ? later : earlier }
        if earlier.counts.total != later.counts.total { return later.counts.total > earlier.counts.total ? later : earlier }
        // Stable ordering when copies disagree without a stronger completion/time signal.
        return later.counts.signature > earlier.counts.signature ? later : earlier
    }

    private static func windowRecords(_ records: [UsageRecord], in interval: DateInterval) -> [UsageRecord] {
        records.filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end }
    }

    private struct ProviderScan {
        let available: Bool
        let scanning: Bool
        let issues: Set<UsageIssue>
        let hasPastRecords: Bool

        func hasEvidence(in window: [UsageRecord]) -> Bool {
            available && (!window.isEmpty || (!scanning && issues.isEmpty && hasPastRecords))
        }
    }

    private static func costHistory(_ provider: UsageProvider, records: [UsageRecord], scan: ProviderScan, now: Date,
                                    calendar: Calendar) -> UsageCostHistory {
        func estimate(_ window: [UsageRecord], hasEvidence: Bool) -> UsageCostWindow {
            let usage = summarize(provider, window: window, hasEvidence: hasEvidence,
                                  scanning: scan.scanning, issues: scan.issues)
            return UsageCostWindow(tokens: usage.counts?.total, estimate: UsageCost.estimate(usage))
        }

        func summary(_ period: UsagePeriod) -> UsageCostWindow {
            let window = windowRecords(records, in: period.interval(now: now, calendar: calendar))
            return estimate(window, hasEvidence: scan.hasEvidence(in: window))
        }

        let today = calendar.startOfDay(for: now)
        let dates = (0..<30).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
        let grouped = dates.first.map { earliest in
            Dictionary(grouping: windowRecords(records, in: DateInterval(start: earliest, end: now))) {
                calendar.startOfDay(for: $0.timestamp)
            }
        } ?? [:]
        let days = dates.map { date in
            let window = grouped[date] ?? []
            let amount = estimate(window, hasEvidence: scan.available && !window.isEmpty)
            return UsageCostDay(date: date, estimate: amount.estimate)
        }

        return UsageCostHistory(today: summary(.today), last24Hours: summary(.last24Hours),
                                last30Days: summary(.last30Days), days: days)
    }

    private static func summarize(_ provider: UsageProvider, window: [UsageRecord], hasEvidence: Bool,
                                  scanning: Bool, issues initialIssues: Set<UsageIssue>,
                                  costHistory: UsageCostHistory? = nil) -> ProviderTokenUsage {
        var issues = initialIssues
        if window.contains(where: { !$0.isFinal }) { issues.insert(.incompleteRecord) }
        var total: TokenCounts? = .zero
        var models: [String: TokenCounts] = [:]
        for record in window {
            total = total?.adding(record.counts)
            let name = record.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unspecified"
            if let sum = (models[model] ?? .zero).adding(record.counts) { models[model] = sum }
            else { issues.insert(.inconsistentUsage) }
        }
        if total == nil { issues.insert(.inconsistentUsage) }
        let coverage: UsageCoverage
        if scanning { coverage = .scanning }
        else if !issues.isEmpty { coverage = .partial }
        else { coverage = hasEvidence ? .complete : .unavailable }
        let rows = models.map { UsageModelTotal(model: $0.key, counts: $0.value) }
            .sorted { $0.counts.total == $1.counts.total ? $0.model < $1.model : $0.counts.total > $1.counts.total }
        return ProviderTokenUsage(provider: provider, counts: hasEvidence ? total : nil,
                                  coverage: coverage, issues: issues, models: rows, costHistory: costHistory)
    }
}
