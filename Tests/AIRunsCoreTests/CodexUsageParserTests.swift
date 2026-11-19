import Foundation
import XCTest
@testable import AIRunsCore

final class CodexUsageParserTests: XCTestCase {
    private let start = "2026-01-10T12:00:00Z"

    private func counts(_ input: Int64, _ output: Int64) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": 0,
         "cache_write_input_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": input + output]
    }

    private func meta(_ id: String = "sample", parent: String? = nil, boundary: Int64? = nil) -> [String: Any] {
        var payload: [String: Any] = ["id": id]
        if let parent { payload["forked_from_id"] = parent }
        if let boundary { payload["subagent_history_start_ordinal"] = boundary }
        return ["type": "session_meta", "payload": payload]
    }

    private func response(_ id: String = "response-a", thread: String = "sample", ordinal: Int64 = 10,
                          input: Int64 = 10, output: Int64 = 5,
                          totalInput: Int64 = 10, totalOutput: Int64 = 5) -> [String: Any] {
        ["type": "token_usage_record", "timestamp": start, "ordinal": ordinal,
         "payload": ["response_id": id, "thread_id": thread, "session_id": "execution-sample",
                     "usage": counts(input, output), "thread_token_usage": counts(totalInput, totalOutput),
                     "turn_token_usage": counts(1_000, 500)]]
    }

    private func legacy(_ input: Int64, _ output: Int64, ordinal: Int64 = 11,
                        lastInput: Int64? = nil, lastOutput: Int64? = nil) -> [String: Any] {
        var info: [String: Any] = ["total_token_usage": counts(input, output)]
        if let lastInput, let lastOutput { info["last_token_usage"] = counts(lastInput, lastOutput) }
        return ["type": "event_msg", "timestamp": start, "ordinal": ordinal,
                "payload": ["type": "token_count", "info": info]]
    }

    private func feed(_ objects: [[String: Any]], to parser: inout CodexUsageParser) throws {
        for object in objects { parser.consume(try JSONSerialization.data(withJSONObject: object)) }
    }

    func testCanonicalResponseWinsOverLegacyMirrorAndRollupCounters() throws {
        var parser = CodexUsageParser()
        try feed([meta(), response(), legacy(10, 5), response()], to: &parser)
        let result = parser.result()
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.counts.total, 15)
        XCTAssertEqual(result.records.first?.id, "codex:response:response-a")
        XCTAssertNotNil(result.records.first?.reconciliationKey)
    }

    func testLegacyCumulativeDeltasIgnoreRepeatedSnapshots() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(10, 5, lastInput: 10, lastOutput: 5),
                  legacy(10, 5), legacy(30, 10, ordinal: 12)], to: &parser)
        let result = parser.result()
        XCTAssertEqual(result.records.map(\.counts.total), [15, 25])
    }

    func testRejectedLowerSnapshotDoesNotLowerAccountedWatermark() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(100, 0, lastInput: 100, lastOutput: 0),
                  legacy(80, 0, ordinal: 12), legacy(120, 0, ordinal: 13)], to: &parser)
        let result = parser.result()
        XCTAssertEqual(result.records.map(\.counts.total), [100, 20])
        XCTAssertTrue(result.issues.contains(.counterReset))
    }

    func testSuccessiveLowerSnapshotsDoNotCreatePhantomDeltas() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(100, 0, lastInput: 100, lastOutput: 0),
                  legacy(80, 0, ordinal: 12), legacy(90, 0, ordinal: 13),
                  legacy(120, 0, ordinal: 14)], to: &parser)
        let result = parser.result()
        XCTAssertEqual(result.records.map(\.counts.total), [100, 20])
        XCTAssertTrue(result.issues.contains(.counterReset))
    }

    func testIncreasingAndRepeatedSnapshotsPreserveKnownUsage() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(100, 0, lastInput: 100, lastOutput: 0),
                  legacy(100, 0, ordinal: 12), legacy(120, 0, ordinal: 13),
                  legacy(120, 0, ordinal: 14)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [100, 20])
        XCTAssertTrue(parser.result().issues.isEmpty)
    }

    func testUnknownOpeningCumulativeIsOnlyABaseline() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(100, 0)], to: &parser)
        XCTAssertTrue(parser.result().records.isEmpty)
        XCTAssertTrue(parser.result().issues.contains(.unattributedUsage))
        try feed([legacy(120, 0, ordinal: 12)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [20])
    }

    func testKnownOpeningLastRequestDoesNotClaimEntireCumulativeHistory() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(100, 0, lastInput: 20, lastOutput: 0),
                  legacy(120, 0, ordinal: 12)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [20, 20])
        XCTAssertTrue(parser.result().issues.contains(.unattributedUsage))
    }

    func testSuffixOnlyCopyCannotInflateGloballyReconciledUsage() throws {
        var full = CodexUsageParser()
        try feed([meta(), legacy(10, 0, lastInput: 10, lastOutput: 0),
                  legacy(20, 0, ordinal: 12)], to: &full)
        var suffix = CodexUsageParser()
        try feed([meta(), legacy(20, 0, ordinal: 12)], to: &suffix)
        let fullResult = full.result(), suffixResult = suffix.result()
        let now = try XCTUnwrap(UsageTimestamp.parse(start))
        for records in [fullResult.records + suffixResult.records, suffixResult.records + fullResult.records] {
            let snapshot = UsageLedger.snapshot(UsageScanOutput(records: records, availableProviders: [.codex],
                issues: [.codex: fullResult.issues.union(suffixResult.issues)], refreshedAt: now),
                period: .last24Hours, now: now)
            let codex = try XCTUnwrap(snapshot.providers.first { $0.provider == .codex })
            XCTAssertEqual(codex.counts?.total, 20)
            XCTAssertEqual(codex.coverage, .partial)
        }
    }

    func testInheritedPrefixCannotLowerOwnedHistoryBaseline() throws {
        var parser = CodexUsageParser()
        try feed([meta("child", parent: "parent", boundary: 10),
                  legacy(100, 0, ordinal: 2), legacy(80, 0, ordinal: 3),
                  legacy(110, 0, ordinal: 12)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [10])
        XCTAssertTrue(parser.result().issues.contains(.counterReset))
    }

    func testOwnedOrdinalExcludesInheritedLegacyButKeepsCanonicalUsage() throws {
        var parser = CodexUsageParser()
        try feed([meta("child", parent: "parent", boundary: 10),
                  legacy(100, 20, ordinal: 2),
                  response("parent-response", thread: "parent", ordinal: 3),
                  response("child-response", thread: "child", ordinal: 12)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.id),
                       ["codex:response:parent-response", "codex:response:child-response"])
    }

    func testOwnedBoundaryDoesNotExcludeValidatedCanonicalRequest() throws {
        var parser = CodexUsageParser()
        try feed([meta("child", parent: "parent", boundary: 10),
                  response("observed-request", thread: "child", ordinal: 2)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.id), ["codex:response:observed-request"])
        XCTAssertTrue(parser.result().issues.isEmpty)
    }

    func testOwnedForkLegacyUsesKnownInheritedBaseline() throws {
        var parser = CodexUsageParser()
        try feed([meta("child", parent: "parent", boundary: 10),
                  legacy(100, 20, ordinal: 2),
                  legacy(110, 22, ordinal: 12, lastInput: 10, lastOutput: 2)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [12])
    }

    func testOrphanForkNeverCountsUnattributedOpeningCumulativeTotal() throws {
        var parser = CodexUsageParser()
        try feed([meta("child", parent: "missing-parent"), legacy(100, 20)], to: &parser)
        XCTAssertTrue(parser.result().records.isEmpty)
        XCTAssertTrue(parser.result().issues.contains(.unsupportedHistory))
    }

    func testCounterResetIsPartialWithoutTreatingResetAsFreshUsage() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(10, 5, lastInput: 10, lastOutput: 5),
                  legacy(2, 1, ordinal: 12), legacy(4, 2, ordinal: 13)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [15])
        XCTAssertTrue(parser.result().issues.contains(.counterReset))
    }

    func testMixedUnmatchedLegacyDoesNotDoubleCountCanonicalUsage() throws {
        var parser = CodexUsageParser()
        try feed([meta(), response(), legacy(11, 5)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [15])
        XCTAssertTrue(parser.result().issues.contains(.unattributedUsage))
    }

    func testMixedHistoryBeforeCanonicalBaselineRemainsCounted() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(10, 5, lastInput: 10, lastOutput: 5),
                  response(input: 20, output: 5, totalInput: 30, totalOutput: 10)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total).sorted(), [15, 25])
    }

    func testMissingIdentityAndInvalidUsageStayUnavailable() throws {
        var missing = response()
        var payload = try XCTUnwrap(missing["payload"] as? [String: Any])
        payload["response_id"] = nil
        missing["payload"] = payload
        var negative = response("negative")
        payload = try XCTUnwrap(negative["payload"] as? [String: Any])
        payload["usage"] = ["input_tokens": -1, "output_tokens": 2]
        negative["payload"] = payload
        var parser = CodexUsageParser()
        try feed([meta(), missing, negative], to: &parser)
        XCTAssertTrue(parser.result().records.isEmpty)
        XCTAssertTrue(parser.result().issues.contains(.missingIdentity))
        XCTAssertTrue(parser.result().issues.contains(.malformedRecord))
    }

    func testChildOnlyFileKeepsParentAndChildCanonicalUsage() throws {
        var parser = CodexUsageParser()
        var parent = response("parent-response", thread: "parent")
        let originalDate = "2026-01-09T12:00:00Z"
        parent["timestamp"] = originalDate
        try feed([meta("parent"), parent,
                  meta("child", parent: "parent"), response("child-response", thread: "child")], to: &parser)
        let result = parser.result()
        XCTAssertEqual(result.records.map(\.id), ["codex:response:parent-response", "codex:response:child-response"])
        XCTAssertEqual(result.records.map(\.timestamp), [UsageTimestamp.parse(originalDate), UsageTimestamp.parse(start)])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testCopiedCanonicalParentHistoryCountsOnceAcrossFiles() throws {
        let parentObjects = [meta("parent"), response("parent-response", thread: "parent")]
        var parent = CodexUsageParser(), child = CodexUsageParser()
        try feed(parentObjects, to: &parent)
        try feed(parentObjects + [meta("child", parent: "parent"),
                                 response("child-response", thread: "child")], to: &child)
        let now = try XCTUnwrap(UsageTimestamp.parse(start))
        for records in [child.result().records, parent.result().records + child.result().records] {
            let snapshot = UsageLedger.snapshot(UsageScanOutput(records: records, availableProviders: [.codex],
                refreshedAt: now), period: .last24Hours, now: now)
            let codex = try XCTUnwrap(snapshot.providers.first { $0.provider == .codex })
            XCTAssertEqual(codex.counts?.total, 30)
            XCTAssertEqual(codex.coverage, .complete)
        }
    }

    func testParentCanonicalDoesNotBoundUnrelatedChildLegacyCounters() throws {
        var parser = CodexUsageParser()
        try feed([meta("parent"), response("parent-response", thread: "parent"),
                  meta("child", parent: "parent", boundary: 10),
                  legacy(100, 0, ordinal: 2), legacy(110, 0, ordinal: 12)], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total).sorted(), [10, 15])
        XCTAssertTrue(parser.result().issues.isEmpty)
    }

    func testCodableContinuationRetainsBaselineWithoutTranscriptContent() throws {
        var parser = CodexUsageParser()
        try feed([meta(), legacy(10, 5, lastInput: 10, lastOutput: 5),
                  ["type": "response_item", "payload": ["type": "message", "content": "fixture-private-content"]]], to: &parser)
        let data = try JSONEncoder().encode(parser)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-private-content"))
        var restored = try JSONDecoder().decode(CodexUsageParser.self, from: data)
        try feed([legacy(30, 10, ordinal: 12)], to: &restored)
        XCTAssertEqual(restored.result().records.map(\.counts.total), [15, 25])
    }

    func testModelAndOriginalTimestampArePreserved() throws {
        var parser = CodexUsageParser()
        try feed([meta(), ["type": "turn_context", "payload": ["model": "sample-model"]], response()], to: &parser)
        XCTAssertEqual(parser.result().records.first?.model, "sample-model")
        XCTAssertEqual(parser.result().records.first?.timestamp, UsageTimestamp.parse(start))
    }

    func testSyntheticContextFillIsNotConsumptionOrMalformedHistory() throws {
        var fill = counts(0, 0)
        fill["total_tokens"] = 32_000
        var parser = CodexUsageParser()
        try feed([meta(), response(), ["type": "event_msg", "timestamp": start,
                  "payload": ["type": "token_count", "info": ["total_token_usage": fill,
                                                              "last_token_usage": fill]]]], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [15])
        XCTAssertFalse(parser.result().issues.contains(.malformedRecord))
    }

    func testBlankResponseIdentityIsUnavailable() throws {
        var parser = CodexUsageParser()
        try feed([meta(), response("   ")], to: &parser)
        XCTAssertTrue(parser.result().records.isEmpty)
        XCTAssertTrue(parser.result().issues.contains(.missingIdentity))
    }

    func testLastOnlyLegacyNeedsStableOrdinalAndRemainsPartial() throws {
        let event: [String: Any] = ["type": "event_msg", "timestamp": start, "ordinal": 10,
            "payload": ["type": "token_count", "info": ["last_token_usage": counts(10, 5)]]]
        var parser = CodexUsageParser()
        try feed([meta(), event, event], to: &parser)
        XCTAssertEqual(parser.result().records.map(\.counts.total), [15])
        XCTAssertTrue(parser.result().issues.contains(.unattributedUsage))
    }
}
