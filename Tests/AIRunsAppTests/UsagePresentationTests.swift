import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

final class UsagePresentationTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usage(counts: TokenCounts? = nil, available: Bool = true,
                       scanning: Bool = false, issues: Set<UsageIssue> = [],
                       age: TimeInterval = 0) throws -> ProviderTokenUsage {
        let records = counts.map {
            [UsageRecord(id: "response-sample", provider: .codex,
                         timestamp: now.addingTimeInterval(-age), counts: $0)]
        } ?? []
        let output = UsageScanOutput(records: records, availableProviders: available ? [.codex] : [],
                                     issues: [.codex: issues], scanning: scanning, refreshedAt: now)
        return try XCTUnwrap(UsageLedger.snapshot(output, period: .last24Hours, now: now)
            .providers.first { $0.provider == .codex })
    }

    func testCompactUnitsPromoteAtRoundingBoundaries() {
        let expected: [(Int64, String)] = [
            (0, "0"), (999, "999"), (1_000, "1K"), (1_240, "1.24K"),
            (12_400, "12.4K"), (999_499, "999K"), (999_500, "1M"),
            (1_240_000, "1.24M"), (999_500_000, "1B"), (1_240_000_000, "1.24B"),
        ]
        for (count, text) in expected {
            XCTAssertEqual(UsagePresentation.compact(count, locale: locale), text)
        }
    }

    func testFormattingUsesLocaleAndPreservesExactLargeIntegerDetails() {
        XCTAssertEqual(UsagePresentation.compact(1_240_000, locale: Locale(identifier: "de_DE")), "1,24M")
        XCTAssertEqual(UsagePresentation.exact(Int64.max, locale: locale), "9,223,372,036,854,775,807")
        let compact = UsagePresentation.compact(Int64.max, locale: locale)
        XCTAssertTrue(compact.hasSuffix("B"))
        XCTAssertFalse(compact.contains("-"))
        XCTAssertFalse(compact.lowercased().contains("inf"))
        XCTAssertFalse(compact.lowercased().contains("nan"))
    }

    func testMissingAndPendingUsageNeverDisplayMeasuredZero() throws {
        let missing = try usage(available: false)
        XCTAssertEqual(UsagePresentation.valueText(missing, locale: locale), "No local records")
        let loading = try XCTUnwrap(UsageSnapshot.loading().providers.first)
        XCTAssertEqual(UsagePresentation.valueText(loading, locale: locale), "Scanning…")
        let failed = try usage(issues: [.ioFailure])
        XCTAssertEqual(UsagePresentation.valueText(failed, locale: locale), "Unavailable")
        for item in [missing, loading, failed] {
            XCTAssertFalse(UsagePresentation.accessibilityValue(item, locale: locale).hasPrefix("0 "))
        }
    }

    func testRecordedZeroAndPartialSubtotalRemainDifferent() throws {
        let old = try usage(counts: XCTUnwrap(TokenCounts(input: 10, output: 2)), age: 90_000)
        XCTAssertEqual(UsagePresentation.valueText(old, locale: locale), "0 tokens")
        XCTAssertNil(UsagePresentation.statusText(old))
        let partial = try usage(counts: XCTUnwrap(TokenCounts(input: 10, output: 2)),
                                issues: [.incompleteRecord])
        XCTAssertEqual(UsagePresentation.valueText(partial, locale: locale), "12 tokens")
        XCTAssertEqual(UsagePresentation.statusText(partial), "Partial")
        XCTAssertTrue(UsagePresentation.accessibilityValue(partial, locale: locale).contains("Partial"))
    }

    func testScanningSubtotalIsMarkedAndCacheIsNotAddedTwice() throws {
        let counts = try XCTUnwrap(TokenCounts(input: 100, output: 30,
                                               cacheRead: 40, cacheWrite: 20, reasoning: 10))
        let scanning = try usage(counts: counts, scanning: true)
        XCTAssertEqual(UsagePresentation.valueText(scanning, locale: locale), "130 tokens")
        XCTAssertEqual(UsagePresentation.statusText(scanning), "Scanning")
        XCTAssertTrue(UsagePresentation.accessibilityValue(scanning, locale: locale).contains("130"))
    }
}
