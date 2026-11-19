import Foundation

/// Reads native Claude Code and Desktop audit assistant records. Only response
/// identities, token counts and timestamps survive into the checkpoint.
public struct ClaudeUsageParser: Codable, Sendable {
    private var records: [String: UsageRecord] = [:]
    private var incompleteIDs: Set<String> = []
    private var parsingIssues: Set<UsageIssue> = []

    public init() {}

    var retainedEventCount: Int { records.count + incompleteIDs.count }

    public mutating func consume(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            parsingIssues.insert(.malformedRecord)
            return
        }
        // Audit result summaries also contain usage. Only explicit assistant
        // message usage is request-level evidence; never add those summaries.
        guard object["type"] as? String == "assistant" else { return }
        guard let message = object["message"] as? [String: Any], let rawUsage = message["usage"] else { return }
        guard let id = recordID(object: object, message: message) else {
            parsingIssues.insert(.missingIdentity)
            return
        }
        guard let rawTime = object["timestamp"] as? String, rawTime.utf8.count <= 64,
              let timestamp = UsageTimestamp.parse(rawTime) else {
            parsingIssues.insert(.malformedRecord)
            return
        }
        guard let counts = TokenCounts.claude(rawUsage) else {
            parsingIssues.insert(.inconsistentUsage)
            return
        }
        if let reason = message["stop_reason"], !(reason is NSNull),
           Self.identifier(reason) == nil {
            parsingIssues.insert(.malformedRecord)
            return
        }
        let explicitNull = message["stop_reason"] is NSNull
        if explicitNull, counts.input > 0, counts.output == 0,
           counts.cacheRead == 0, counts.cacheWrite == 0 {
            if records[id] == nil { incompleteIDs.insert(id) }
            return
        }
        let record = UsageRecord(id: id, provider: .claudeCode, timestamp: timestamp, counts: counts,
                                 model: message["model"] as? String, isFinal: !explicitNull)
        incompleteIDs.remove(id)
        if let previous = records[id], !Self.shouldReplace(previous, with: record) { return }
        records[id] = record
    }

    public func result() -> UsageParseResult {
        let issues = incompleteIDs.isEmpty ? parsingIssues : parsingIssues.union([.incompleteRecord])
        return UsageParseResult(records: records.values.sorted { $0.id < $1.id }, issues: issues)
    }

    private static func shouldReplace(_ previous: UsageRecord, with next: UsageRecord) -> Bool {
        if previous.isFinal != next.isFinal { return next.isFinal }
        return next.timestamp >= previous.timestamp
    }

    private func recordID(object: [String: Any], message: [String: Any]) -> String? {
        guard let messageID = Self.identifier(message["id"]) else { return nil }
        let request = Self.alias(object, keys: ["requestId", "request_id"])
        guard request.valid else { return nil }
        if let requestID = request.value { return Self.identity(kind: "request", owner: requestID, message: messageID) }
        let session = Self.alias(object, keys: ["sessionId", "session_id"])
        guard session.valid, let sessionID = session.value else { return nil }
        return Self.identity(kind: "session", owner: sessionID, message: messageID)
    }

    private static func alias(_ object: [String: Any], keys: [String]) -> (value: String?, valid: Bool) {
        var found: String?
        for key in keys {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            guard let value = identifier(raw), found == nil || found == value else { return (nil, false) }
            found = value
        }
        return (found, true)
    }

    private static func identifier(_ raw: Any?) -> String? {
        guard let value = raw as? String, value.utf8.count <= 512,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func identity(kind: String, owner: String, message: String) -> String {
        "claude:\(kind):\(owner.utf8.count):\(owner):\(message.utf8.count):\(message)"
    }
}
