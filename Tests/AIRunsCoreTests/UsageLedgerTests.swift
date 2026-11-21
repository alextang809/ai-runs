import Foundation
import XCTest
@testable import AIRunsCore

final class UsageLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func record(_ id: String, provider: UsageProvider = .codex, input: Int64 = 100,
                        output: Int64 = 20, at: Date? = nil, evidence: UsageEvidence = .response,
                        key: String? = nil, final: Bool = true) -> UsageRecord {
        UsageRecord(id: id, provider: provider, timestamp: at ?? now, counts: TokenCounts(input: input, output: output)!,
                    model: "sample-model", evidence: evidence, reconciliationKey: key, isFinal: final)
    }
    private func snapshot(_ records: [UsageRecord], available: Set<UsageProvider> = [.codex, .claudeCode]) -> UsageSnapshot {
        UsageLedger.snapshot(UsageScanOutput(records: records, availableProviders: available,
                                             refreshedAt: now), period: .last24Hours, now: now)
    }

    func testGlobalDuplicatesAndLegacyMirrorsCountOnceButDistinctResponsesStaySeparate() {
        let response = record("response-a", key: "thread:120")
        let legacy = record("legacy-a", evidence: .legacy, key: "thread:120")
        let result = snapshot([response, response, legacy, record("response-b")])
        XCTAssertEqual(result.providers[0].counts?.total, 240)
        XCTAssertEqual(result.providers[0].models.first?.counts.total, 240)
    }

    func testCompletedResponseWinsOverReplayedPartialAcrossFiles() {
        let partial = record("response-a", output: 5, final: false)
        let complete = record("response-a", output: 20, at: now.addingTimeInterval(-1))
        for records in [[partial, complete], [complete, partial]] {
            XCTAssertEqual(snapshot(records).providers[0].counts?.total, 120)
            XCTAssertEqual(snapshot(records).providers[0].coverage, .complete)
        }
    }

    func testCanonicalTimePreventsMirrorFromMovingUsageIntoNewPeriod() {
        let old = record("response-a", at: now.addingTimeInterval(-90_000), key: "thread:120")
        let replay = record("legacy-a", evidence: .legacy, key: "thread:120")
        XCTAssertEqual(snapshot([old, replay]).providers[0].counts?.total, 0)
    }

    func testUnavailableIsDifferentFromMeasuredEmptyWindowAndScanning() {
        XCTAssertNil(snapshot([]).providers[0].counts)
        XCTAssertEqual(snapshot([]).providers[0].coverage, .unavailable)
        let old = record("old", at: now.addingTimeInterval(-90_000))
        XCTAssertEqual(snapshot([old]).providers[0].counts?.total, 0)
        XCTAssertEqual(snapshot([old]).providers[0].coverage, .complete)
        let scanning = UsageLedger.snapshot(UsageScanOutput(records: [], availableProviders: [],
                        scanning: true, refreshedAt: now), period: .last24Hours, now: now)
        XCTAssertEqual(scanning.providers[0].coverage, .scanning)
    }

    func testIncompleteOrConflictingEvidenceMarksSubtotalPartial() {
        let partial = snapshot([record("unfinished", final: false)]).providers[0]
        XCTAssertEqual(partial.coverage, .partial)
        XCTAssertTrue(partial.issues.contains(.incompleteRecord))
        let conflict = snapshot([record("same", input: 200, output: 1),
                                 record("same", input: 1, output: 200)]).providers[0]
        XCTAssertEqual(conflict.coverage, .partial)
        XCTAssertTrue(conflict.issues.contains(.inconsistentUsage))
    }

    func testOverflowDoesNotHideOtherProviderOrPublishFakeTotal() {
        let result = snapshot([record("a", input: Int64.max, output: 0),
                               record("b", input: 1, output: 0),
                               record("claude", provider: .claudeCode)])
        XCTAssertNil(result.providers[0].counts)
        XCTAssertEqual(result.providers[0].coverage, .partial)
        XCTAssertEqual(result.providers[1].counts?.total, 120)
    }

    func testLatestCumulativeSnapshotReplacesEarlierAcrossMidnight() {
        let earlier = record("same", output: 5, at: now.addingTimeInterval(-90_000), final: false)
        let complete = record("same", output: 20)
        XCTAssertEqual(snapshot([earlier, complete]).providers[0].counts?.total, 120)
    }

    func testConflictingLegacyDeltasNeverInflateSameCumulativeCheckpoint() {
        let start = record("legacy-10", input: 10, output: 0, evidence: .legacy, key: "thread:10")
        let knownDelta = record("legacy-20", input: 10, output: 0, evidence: .legacy, key: "thread:20")
        let ambiguousCopy = record("legacy-20", input: 20, output: 0, evidence: .legacy, key: "thread:20")
        for rows in [[start, knownDelta, ambiguousCopy], [ambiguousCopy, knownDelta, start]] {
            let result = snapshot(rows).providers[0]
            XCTAssertEqual(result.counts?.total, 20)
            XCTAssertEqual(result.coverage, .partial)
            XCTAssertTrue(result.issues.contains(.inconsistentUsage))
        }
    }
}
