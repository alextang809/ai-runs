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
    public var id: UsageProvider { provider }
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
        let providers = UsageProvider.allCases.map { provider in
            summarize(provider, records: accepted.filter { $0.provider == provider },
                      available: output.availableProviders.contains(provider), interval: interval,
                      scanning: output.scanning, issues: issues[provider] ?? [])
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

    private static func summarize(_ provider: UsageProvider, records: [UsageRecord], available: Bool,
                                  interval: DateInterval, scanning: Bool,
                                  issues initialIssues: Set<UsageIssue>) -> ProviderTokenUsage {
        var issues = initialIssues
        let window = records.filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end }
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
        let hasEvidence = available && !records.isEmpty
        let coverage: UsageCoverage
        if scanning { coverage = .scanning }
        else if !issues.isEmpty { coverage = .partial }
        else { coverage = hasEvidence ? .complete : .unavailable }
        let rows = models.map { UsageModelTotal(model: $0.key, counts: $0.value) }
            .sorted { $0.counts.total == $1.counts.total ? $0.model < $1.model : $0.counts.total > $1.counts.total }
        return ProviderTokenUsage(provider: provider, counts: hasEvidence ? total : nil,
                                  coverage: coverage, issues: issues, models: rows)
    }
}
