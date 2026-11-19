import CoreFoundation
import Foundation

/// Reads only usage and ownership metadata from Codex rollouts. Cached state never
/// retains message bodies. Response-owned usage takes precedence over old snapshots.
public struct CodexUsageParser: Codable, Sendable {
    private struct Metadata: Codable, Sendable {
        let id: String
        let inherited: Bool
        let ownedStart: Int64?
    }

    private struct Response: Codable, Sendable {
        let id: String
        let thread: String
        let timestamp: Date
        let ordinal: Int64?
        let counts: TokenCounts
        let cumulative: TokenCounts?
        let model: String?

        var reconciliationKey: String? { cumulative.map { "\(thread):\($0.signature)" } }
        var record: UsageRecord {
            UsageRecord(id: "codex:response:\(id)", provider: .codex, timestamp: timestamp,
                        counts: counts, model: model, reconciliationKey: reconciliationKey)
        }
    }

    private struct Snapshot: Codable, Sendable {
        let thread: String?
        let timestamp: Date
        let ordinal: Int64?
        let cumulative: TokenCounts?
        let last: TokenCounts?
        let model: String?
    }

    private var metadata: Metadata?
    private var currentModel: String?
    private var responses: [Response] = []
    private var snapshots: [Snapshot] = []
    private var issues: Set<UsageIssue> = []

    public init() {}

    var retainedEventCount: Int { responses.count + snapshots.count }

    public mutating func consume(_ line: Data) {
        guard !line.isEmpty else { return }
        guard line.count <= 8 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            issues.insert(.malformedRecord)
            return
        }
        guard let payload = object["payload"] as? [String: Any] else { return }
        switch object["type"] as? String {
        case "session_meta": readMetadata(payload)
        case "turn_context": currentModel = Self.model(payload["model"])
        case "token_usage_record": readResponse(object, payload: payload)
        case "event_msg" where payload["type"] as? String == "token_count":
            readSnapshot(object, payload: payload)
        default: break
        }
    }

    public func result() -> UsageParseResult {
        var resultIssues = issues
        let canonical = canonicalResponses(issues: &resultIssues)
        let legacy = legacyRecords(canonical: canonical, issues: &resultIssues)
        return UsageParseResult(records: legacy + canonical.map(\.record), issues: resultIssues)
    }

    private mutating func readMetadata(_ payload: [String: Any]) {
        currentModel = nil
        guard let id = Self.identifier(payload["id"]) ?? Self.identifier(payload["session_id"]) else {
            issues.insert(.missingIdentity)
            metadata = nil
            return
        }
        let source = payload["source"] as? [String: Any]
        let inherited = payload["forked_from_id"] != nil || payload["parent_thread_id"] != nil
            || payload["history_base"] != nil || source?["subagent"] != nil
        metadata = Metadata(id: id, inherited: inherited,
                            ownedStart: Self.ordinal(payload["subagent_history_start_ordinal"]))
        currentModel = Self.model(payload["model"])
    }

    private mutating func readResponse(_ object: [String: Any], payload: [String: Any]) {
        guard let id = Self.identifier(payload["response_id"]),
              let thread = Self.identifier(payload["thread_id"]) else {
            issues.insert(.missingIdentity)
            return
        }
        guard let timestamp = Self.timestamp(object),
              let counts = payload["usage"].flatMap(TokenCounts.codex) else {
            issues.insert(.malformedRecord)
            return
        }
        let cumulative = payload["thread_token_usage"].flatMap(TokenCounts.codex)
        if cumulative == nil { issues.insert(.unattributedUsage) }
        responses.append(Response(id: id, thread: thread, timestamp: timestamp,
                                  ordinal: Self.ordinal(object["ordinal"]), counts: counts,
                                  cumulative: cumulative, model: currentModel))
    }

    private mutating func readSnapshot(_ object: [String: Any], payload: [String: Any]) {
        // Null info accompanies some quota-only notifications; it is not zero usage.
        guard let info = payload["info"] as? [String: Any] else { return }
        guard let timestamp = Self.timestamp(object) else {
            issues.insert(.malformedRecord)
            return
        }
        if Self.isContextFill(info["total_token_usage"]),
           info["last_token_usage"] == nil || Self.isContextFill(info["last_token_usage"])
               || info["last_token_usage"].flatMap(TokenCounts.codex)?.total == 0 { return }
        let cumulative = info["total_token_usage"].flatMap(TokenCounts.codex)
        let last = info["last_token_usage"].flatMap(TokenCounts.codex)
        guard cumulative != nil || last != nil else {
            issues.insert(.malformedRecord)
            return
        }
        snapshots.append(Snapshot(thread: metadata?.id, timestamp: timestamp,
                                  ordinal: Self.ordinal(object["ordinal"]), cumulative: cumulative,
                                  last: last, model: currentModel))
    }

    private func canonicalResponses(issues: inout Set<UsageIssue>) -> [Response] {
        var result: [Response] = []
        var positions: [String: Int] = [:]
        for response in responses {
            // Provider totals include observed parent requests even if their only
            // surviving copy is in a child's history. The ledger deduplicates
            // response IDs across files; leaf ownership applies only to legacy usage.
            if metadata == nil { issues.insert(.unattributedUsage) }
            if let position = positions[response.id] {
                if result[position].counts != response.counts {
                    issues.insert(.inconsistentUsage)
                    if response.counts.subtracting(result[position].counts) != nil { result[position] = response }
                }
            } else {
                positions[response.id] = result.count
                result.append(response)
            }
        }
        return result
    }

    private func legacyRecords(canonical: [Response], issues: inout Set<UsageIssue>) -> [UsageRecord] {
        guard !snapshots.isEmpty else { return [] }
        guard let metadata else {
            issues.insert(.missingIdentity)
            return []
        }
        let mirrors = Set(canonical.compactMap(\.reconciliationKey))
        let leafResponses = canonical.filter { $0.thread == metadata.id }
        let firstResponse = leafResponses.min { $0.timestamp < $1.timestamp }
        let canonicalBaseline = firstResponse.flatMap { response in
            response.cumulative?.subtracting(response.counts)
        }
        var previous: TokenCounts?
        var seen: Set<String> = []
        var records: [UsageRecord] = []
        for snapshot in snapshots {
            guard snapshot.thread == metadata.id else { continue }
            if let start = metadata.ownedStart {
                guard let ordinal = snapshot.ordinal else {
                    issues.insert(.unattributedUsage)
                    continue
                }
                if ordinal < start {
                    if let cumulative = snapshot.cumulative,
                       baselineCanAdvance(to: cumulative, from: previous, issues: &issues) {
                        previous = cumulative
                    }
                    continue
                }
            }
            if let cumulative = snapshot.cumulative {
                guard baselineCanAdvance(to: cumulative, from: previous, issues: &issues) else { continue }
                let key = "\(metadata.id):\(cumulative.signature)"
                let mirrored = mirrors.contains(key)
                let delta = mirrored ? nil : legacyDelta(snapshot, previous: previous, metadata: metadata, issues: &issues)
                // Unknown opening history can establish a baseline, but a rejected
                // lower counter must never reduce this watermark and inflate a later delta.
                previous = cumulative
                guard !mirrored, seen.insert(key).inserted, let delta, delta.total > 0 else { continue }
                if let firstResponse {
                    // A mixed rollout can have older legacy-only history. Accept it only
                    // when the first response's known baseline proves it precedes that usage.
                    guard snapshot.timestamp <= firstResponse.timestamp,
                          canonicalBaseline?.subtracting(cumulative) != nil else {
                        issues.insert(.unattributedUsage)
                        continue
                    }
                }
                records.append(UsageRecord(id: "codex:legacy:\(key)", provider: .codex,
                        timestamp: snapshot.timestamp, counts: delta, model: snapshot.model,
                        evidence: .legacy, reconciliationKey: key))
            } else if let last = snapshot.last {
                appendLastOnly(snapshot, counts: last, metadata: metadata, hasCanonical: !leafResponses.isEmpty,
                               seen: &seen, records: &records, issues: &issues)
            }
        }
        return records
    }

    private func baselineCanAdvance(to cumulative: TokenCounts, from previous: TokenCounts?,
                                    issues: inout Set<UsageIssue>) -> Bool {
        guard let previous else { return true }
        guard cumulative.subtracting(previous) != nil else {
            issues.insert(.counterReset)
            return false
        }
        return true
    }

    private func legacyDelta(_ snapshot: Snapshot, previous: TokenCounts?, metadata: Metadata,
                             issues: inout Set<UsageIssue>) -> TokenCounts? {
        guard let cumulative = snapshot.cumulative else { return nil }
        if let previous {
            return cumulative.subtracting(previous)
        }
        if metadata.inherited {
            // No parent lookup is guessed. An explicit child-owned last request can
            // establish its first baseline; an opaque inherited opening cannot.
            if metadata.ownedStart != nil, let last = snapshot.last,
               cumulative.subtracting(last) != nil { return last }
            issues.insert(.unsupportedHistory)
            return nil
        }
        guard let last = snapshot.last else {
            issues.insert(.unattributedUsage)
            return nil
        }
        if cumulative != last { issues.insert(.unattributedUsage) }
        return cumulative.subtracting(last) == nil ? nil : last
    }

    private func appendLastOnly(_ snapshot: Snapshot, counts: TokenCounts, metadata: Metadata,
                                hasCanonical: Bool, seen: inout Set<String>, records: inout [UsageRecord],
                                issues: inout Set<UsageIssue>) {
        issues.insert(.unattributedUsage)
        guard !hasCanonical, !metadata.inherited, let ordinal = snapshot.ordinal else { return }
        let key = "\(metadata.id):\(ordinal):\(snapshot.timestamp.timeIntervalSince1970)"
        guard counts.total > 0, seen.insert(key).inserted else { return }
        records.append(UsageRecord(id: "codex:legacy-last:\(key)", provider: .codex,
                        timestamp: snapshot.timestamp, counts: counts, model: snapshot.model, evidence: .legacy))
    }

    private static func timestamp(_ object: [String: Any]) -> Date? {
        (object["timestamp"] as? String).flatMap(UsageTimestamp.parse)
    }

    private static func ordinal(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let ordinal = Int64(number.stringValue), ordinal >= 0 else { return nil }
        return ordinal
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 1_024,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    private static func isContextFill(_ value: Any?) -> Bool {
        guard let values = value as? [String: Any],
              ordinal(values["input_tokens"]) == 0, ordinal(values["output_tokens"]) == 0,
              let total = ordinal(values["total_tokens"]), total > 0 else { return false }
        return ["cached_input_tokens", "cache_write_input_tokens", "reasoning_output_tokens"].allSatisfy {
            values[$0] == nil || ordinal(values[$0]) == 0
        }
    }

    private static func model(_ value: Any?) -> String? {
        guard let value = identifier(value), value.count <= 128,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._:/-".unicodeScalars.contains($0) })
        else { return nil }
        return value
    }
}
