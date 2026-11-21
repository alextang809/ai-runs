import Foundation
import XCTest
@testable import AIRunsCore

final class UsageCostTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testChargesFreshInputCachedReadsAndWritesOnce() throws {
        let counts = try XCTUnwrap(TokenCounts(input: 1_000_000, output: 100_000,
                                                cacheRead: 600_000, cacheWrite: 100_000, reasoning: 50_000))
        let rate = UsageTokenRate(input: 2, cachedInput: Decimal(string: "0.1")!,
                                  cacheWrite: Decimal(string: "2.5")!, output: 10)
        XCTAssertEqual(rate.usd(for: counts), Decimal(string: "1.91"))
    }

    func testPricesOnlyRecognizedModelAndMarksUnknownUsageAsPartial() throws {
        let usage = try snapshot([
            record("known", model: "gpt-6.2-sol", input: 1_000_000, output: 100_000),
            record("custom", model: "gpt-6.2-sol-unverified", input: 800, output: 200),
            record("unknown", model: nil, input: 20, output: 0),
        ])
        let estimate = UsageCost.estimate(usage)
        XCTAssertEqual(estimate.totalUSD, 3)
        XCTAssertEqual(estimate.byModelUSD, ["gpt-6.2-sol": 3])
        XCTAssertEqual(estimate.unpricedTokens, 1_020)
        XCTAssertTrue(estimate.isPartial)
    }

    func testMissingRatesAndMissingRecordsDoNotLookLikeZero() throws {
        let absent = try snapshot([])
        XCTAssertNil(UsageCost.estimate(absent).totalUSD)
        let unsupported = try snapshot([record("unpriced", model: "internal-model", input: 10, output: 2)])
        let estimate = UsageCost.estimate(unsupported)
        XCTAssertNil(estimate.totalUSD)
        XCTAssertEqual(estimate.unpricedTokens, 12)
        XCTAssertTrue(estimate.byModelUSD.isEmpty)
    }

    func testZeroTokenModelDoesNotTurnOtherUnpricedUsageIntoZeroCost() throws {
        let usage = try snapshot([
            record("known-zero", model: "gpt-6.2-sol", input: 0, output: 0),
            record("unpriced", model: "internal-model", input: 10, output: 2),
        ])
        let estimate = UsageCost.estimate(usage)
        XCTAssertEqual(estimate.byModelUSD["gpt-6.2-sol"], 0)
        XCTAssertNil(estimate.totalUSD)
        XCTAssertEqual(estimate.unpricedTokens, 12)
    }

    func testRecordedZeroAndIncompleteCoverageRemainDistinct() throws {
        let zero = try snapshot([record("historical", model: "internal-model", input: 10, output: 2, age: 100_000)])
        XCTAssertEqual(UsageCost.estimate(zero).totalUSD, 0)
        XCTAssertFalse(UsageCost.estimate(zero).isPartial)
        let incompleteZero = try snapshot([record("historical", model: "internal-model", input: 10, output: 2,
                                                  age: 100_000)], issues: [.unsupportedHistory])
        XCTAssertNil(UsageCost.estimate(incompleteZero).totalUSD)

        let partial = try snapshot([record("partial", model: "gpt-6.2-sol", input: 1_000_000, output: 0)],
                                   issues: [.incompleteRecord])
        let estimate = UsageCost.estimate(partial)
        XCTAssertEqual(estimate.totalUSD, 2)
        XCTAssertEqual(estimate.unpricedTokens, 0)
        XCTAssertTrue(estimate.isPartial)
    }

    func testClaudeUsesItsOwnCacheRates() throws {
        let usage = try snapshot([
            UsageRecord(id: "claude", provider: .claudeCode, timestamp: now,
                counts: try XCTUnwrap(TokenCounts(input: 1_000_000, output: 100_000,
                                                  cacheRead: 600_000, cacheWrite: 100_000)),
                model: "claude-sonnet-4-6"),
        ], provider: .claudeCode)
        let estimate = UsageCost.estimate(usage)
        XCTAssertEqual(estimate.totalUSD, Decimal(string: "2.955"))
        XCTAssertEqual(estimate.unpricedTokens, 0)
        XCTAssertFalse(estimate.isPartial)
    }

    private func snapshot(_ records: [UsageRecord], provider: UsageProvider = .codex,
                          issues: Set<UsageIssue> = []) throws -> ProviderTokenUsage {
        let output = UsageScanOutput(records: records, availableProviders: [provider],
                                     issues: [provider: issues], refreshedAt: now)
        return try XCTUnwrap(UsageLedger.snapshot(output, period: .last24Hours, now: now)
            .providers.first { $0.provider == provider })
    }

    private func record(_ id: String, model: String?, input: Int64, output: Int64,
                        age: TimeInterval = 0) throws -> UsageRecord {
        UsageRecord(id: id, provider: .codex, timestamp: now.addingTimeInterval(-age),
                    counts: try XCTUnwrap(TokenCounts(input: input, output: output)), model: model)
    }
}
