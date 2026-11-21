import Foundation
import XCTest
@testable import AIRunsCore

final class UsageCostHistoryTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-07-01T17:00:00Z")!

    func testDedupeAndCanonicalReconciliationApplyToEachWindowAndDay() throws {
        let day = 86_400.0
        let today = record("today", at: now, key: "canonical")
        let replay = record("replay", at: now, evidence: .legacy, key: "canonical")
        let yesterday = record("yesterday", at: now.addingTimeInterval(-7_200))
        let old = record("old", at: now.addingTimeInterval(-29 * day))
        let boundary = record("rolling-boundary", at: now.addingTimeInterval(-30 * day))
        let excluded = record("excluded", at: now.addingTimeInterval(-31 * day))
        let future = record("future", at: now.addingTimeInterval(3_600))
        let usage = try provider([today, today, replay, yesterday, old, boundary, excluded, future])
        let history = try XCTUnwrap(usage.costHistory)
        XCTAssertEqual(usage.counts?.total, 4_000_000)
        XCTAssertEqual(history.today.tokens, 1_000_000)
        XCTAssertEqual(history.today.estimate.totalUSD, 2)
        XCTAssertEqual(history.last24Hours.tokens, 2_000_000)
        XCTAssertEqual(history.last24Hours.estimate.totalUSD, 4)
        XCTAssertEqual(history.last30Days.tokens, 4_000_000)
        XCTAssertEqual(history.last30Days.estimate.totalUSD, 8)
        XCTAssertEqual(history.days.count, 30)
        XCTAssertEqual(history.days.first?.estimate.totalUSD, 2)
        XCTAssertEqual(history.days.last?.estimate.totalUSD, 2)
        XCTAssertEqual(history.days.last?.date, calendar.startOfDay(for: now))
        XCTAssertNil(history.days[1].estimate.totalUSD)
    }

    func testIncompleteEmptyWindowsAndDaysDoNotRepresentZero() throws {
        let old = record("old", at: now.addingTimeInterval(-3 * 86_400))
        let usage = try provider([old], scanning: true)
        let history = try XCTUnwrap(usage.costHistory)
        XCTAssertNil(history.today.tokens)
        XCTAssertNil(history.today.estimate.totalUSD)
        XCTAssertTrue(history.today.estimate.isPartial)
        XCTAssertNil(history.last24Hours.estimate.totalUSD)
        XCTAssertEqual(history.last30Days.estimate.totalUSD, 2)
        XCTAssertTrue(history.last30Days.estimate.isPartial)
        XCTAssertNil(history.days.last?.estimate.totalUSD)

        let selected = try provider([old], period: .today, scanning: true)
        XCTAssertNil(selected.counts)
        XCTAssertNil(UsageCost.estimate(selected).totalUSD)
    }

    func testUnknownModelUsesTokensButDoesNotInventDollarAmount() throws {
        let unknown = record("unknown", at: now, model: "model-without-price")
        let usage = try provider([unknown])
        let history = try XCTUnwrap(usage.costHistory)
        XCTAssertEqual(history.today.tokens, 1_000_000)
        XCTAssertNil(history.today.estimate.totalUSD)
        XCTAssertTrue(history.today.estimate.isPartial)
        XCTAssertNil(history.days.last?.estimate.totalUSD)
    }

    func testFutureRecordsDoNotEstablishAZeroCostWindow() throws {
        let future = record("future", at: now.addingTimeInterval(3_600))
        let selected = try provider([future])
        let history = try XCTUnwrap(selected.costHistory)
        XCTAssertNil(selected.counts)
        XCTAssertNil(history.today.estimate.totalUSD)
        XCTAssertNil(history.last24Hours.estimate.totalUSD)
        XCTAssertNil(history.last30Days.estimate.totalUSD)
        XCTAssertTrue(history.days.allSatisfy { $0.estimate.totalUSD == nil })
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func provider(_ records: [UsageRecord], period: UsagePeriod = .last30Days,
                          scanning: Bool = false) throws -> ProviderTokenUsage {
        let output = UsageScanOutput(records: records, availableProviders: [.codex],
                                     scanning: scanning, refreshedAt: now)
        return try XCTUnwrap(UsageLedger.snapshot(output, period: period, now: now, calendar: calendar)
            .providers.first { $0.provider == .codex })
    }

    private func record(_ id: String, at date: Date, model: String = "gpt-6.2-sol",
                        evidence: UsageEvidence = .response, key: String? = nil) -> UsageRecord {
        return UsageRecord(id: id, provider: .codex, timestamp: date,
                           counts: TokenCounts(input: 1_000_000, output: 0)!, model: model,
                           evidence: evidence, reconciliationKey: key)
    }
}
