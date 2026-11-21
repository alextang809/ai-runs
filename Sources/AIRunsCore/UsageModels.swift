import CoreFoundation
import Foundation

public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case codex, claudeCode

    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

/// Input includes cached reads/writes. Reasoning is part of output, never extra.
public struct TokenCounts: Codable, Equatable, Sendable {
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let reasoning: Int64
    public var total: Int64 { input + output }
    public var signature: String { "\(input):\(output):\(cacheRead):\(cacheWrite):\(reasoning)" }
    public static let zero = TokenCounts(input: 0, output: 0)!

    public init?(input: Int64, output: Int64, cacheRead: Int64 = 0,
                 cacheWrite: Int64 = 0, reasoning: Int64 = 0) {
        guard input >= 0, output >= 0, cacheRead >= 0, cacheWrite >= 0, reasoning >= 0,
              cacheRead <= input, cacheWrite <= input, reasoning <= output,
              !input.addingReportingOverflow(output).overflow,
              !cacheRead.addingReportingOverflow(cacheWrite).overflow,
              cacheRead + cacheWrite <= input else { return nil }
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    private enum CodingKeys: CodingKey { case input, output, cacheRead, cacheWrite, reasoning }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let counts = TokenCounts(input: try values.decode(Int64.self, forKey: .input),
                    output: try values.decode(Int64.self, forKey: .output),
                    cacheRead: try values.decode(Int64.self, forKey: .cacheRead),
                    cacheWrite: try values.decode(Int64.self, forKey: .cacheWrite),
                    reasoning: try values.decode(Int64.self, forKey: .reasoning)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: "Invalid token counts"))
        }
        self = counts
    }

    public func adding(_ other: Self) -> Self? {
        let sums = zip(components, other.components).map { $0.addingReportingOverflow($1) }
        guard sums.allSatisfy({ !$0.overflow }) else { return nil }
        return Self(input: sums[0].partialValue, output: sums[1].partialValue,
                    cacheRead: sums[2].partialValue, cacheWrite: sums[3].partialValue,
                    reasoning: sums[4].partialValue)
    }

    public func subtracting(_ earlier: Self) -> Self? {
        guard zip(components, earlier.components).allSatisfy({ $0 >= $1 }) else { return nil }
        return Self(input: input - earlier.input, output: output - earlier.output,
                    cacheRead: cacheRead - earlier.cacheRead, cacheWrite: cacheWrite - earlier.cacheWrite,
                    reasoning: reasoning - earlier.reasoning)
    }

    private var components: [Int64] { [input, output, cacheRead, cacheWrite, reasoning] }

    public static func codex(_ value: Any) -> Self? {
        guard let values = value as? [String: Any],
              let input = integer(values["input_tokens"]), let output = integer(values["output_tokens"]),
              let cached = optionalInteger(values, "cached_input_tokens"),
              let written = optionalInteger(values, "cache_write_input_tokens"),
              let reasoning = optionalInteger(values, "reasoning_output_tokens"),
              let counts = Self(input: input, output: output, cacheRead: cached,
                                cacheWrite: written, reasoning: reasoning) else { return nil }
        if let raw = values["total_tokens"] {
            guard let reported = integer(raw), reported == counts.total || reported == 0 else { return nil }
        }
        return counts
    }

    public static func claude(_ value: Any) -> Self? {
        guard let values = value as? [String: Any], let fresh = integer(values["input_tokens"]),
              let output = integer(values["output_tokens"]),
              let cached = optionalInteger(values, "cache_read_input_tokens"),
              let written = optionalInteger(values, "cache_creation_input_tokens"),
              let reasoning = optionalInteger(values, "thinking_tokens") else { return nil }
        let prompt = fresh.addingReportingOverflow(cached)
        guard !prompt.overflow else { return nil }
        let input = prompt.partialValue.addingReportingOverflow(written)
        guard !input.overflow else { return nil }
        return Self(input: input.partialValue, output: output, cacheRead: cached,
                    cacheWrite: written, reasoning: reasoning)
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(number.stringValue), integer >= 0 else { return nil }
        return integer
    }

    private static func optionalInteger(_ values: [String: Any], _ key: String) -> Int64? {
        values[key].map { integer($0) } ?? 0
    }
}

public enum UsageEvidence: String, Codable, Sendable { case response, legacy }

public struct UsageRecord: Codable, Equatable, Sendable {
    public let id: String
    public let provider: UsageProvider
    public let timestamp: Date
    public let counts: TokenCounts
    public let model: String?
    public let evidence: UsageEvidence
    public let reconciliationKey: String?
    public let isFinal: Bool

    public init(id: String, provider: UsageProvider, timestamp: Date, counts: TokenCounts,
                model: String? = nil, evidence: UsageEvidence = .response,
                reconciliationKey: String? = nil, isFinal: Bool = true) {
        self.id = id
        self.provider = provider
        self.timestamp = timestamp
        self.counts = counts
        self.model = model.map { String($0.prefix(128)) }
        self.evidence = evidence
        self.reconciliationKey = reconciliationKey
        self.isFinal = isFinal
    }
}

public enum UsageIssue: String, Codable, Hashable, Sendable {
    case malformedRecord, missingIdentity, counterReset, unattributedUsage
    case unsupportedHistory, incompleteRecord, inconsistentUsage, ioFailure
}

public struct UsageParseResult: Codable, Equatable, Sendable {
    public let records: [UsageRecord]
    public let issues: Set<UsageIssue>
    public init(records: [UsageRecord], issues: Set<UsageIssue> = []) {
        self.records = records
        self.issues = issues
    }
}

public struct UsageScanOutput: Sendable {
    public let records: [UsageRecord]
    public let availableProviders: Set<UsageProvider>
    public let issues: [UsageProvider: Set<UsageIssue>]
    public let scanning: Bool
    public let refreshedAt: Date

    public init(records: [UsageRecord], availableProviders: Set<UsageProvider>,
                issues: [UsageProvider: Set<UsageIssue>] = [:], scanning: Bool = false,
                refreshedAt: Date) {
        self.records = records
        self.availableProviders = availableProviders
        self.issues = issues
        self.scanning = scanning
        self.refreshedAt = refreshedAt
    }
}

public enum UsagePeriod: String, Codable, CaseIterable, Sendable {
    case today, last24Hours = "24h", last7Days = "7d", last30Days = "30d"
    public var title: String {
        switch self {
        case .today: return "Today"
        case .last24Hours, .last7Days, .last30Days: return rawValue
        }
    }
    public func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let start: Date
        switch self {
        case .today: start = calendar.startOfDay(for: now)
        case .last24Hours: start = now.addingTimeInterval(-86_400)
        case .last7Days: start = now.addingTimeInterval(-7 * 86_400)
        case .last30Days: start = now.addingTimeInterval(-30 * 86_400)
        }
        return DateInterval(start: start, end: now)
    }
}

public enum UsageTimestamp {
    public static func parse(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value))
    }
}
