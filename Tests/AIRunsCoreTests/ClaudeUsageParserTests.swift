import Foundation
import XCTest
@testable import AIRunsCore

final class ClaudeUsageParserTests: XCTestCase {
    private func line(messageID: String = "message-sample", requestID: String? = "request-sample",
                      sessionID: String? = "session-sample", timestamp: String = "2026-11-19T08:00:00Z",
                      usage: [String: Any] = ["input_tokens": 10, "output_tokens": 5],
                      stopReason: Any? = "end_turn", snakeCase: Bool = false,
                      content: String = "Synthetic response content") throws -> Data {
        var message: [String: Any] = [
            "id": messageID, "role": "assistant", "model": "sample-model",
            "content": [["type": "text", "text": content]], "usage": usage,
        ]
        if let stopReason { message["stop_reason"] = stopReason }
        var object: [String: Any] = ["type": "assistant", "timestamp": timestamp, "message": message]
        if let requestID { object[snakeCase ? "request_id" : "requestId"] = requestID }
        if let sessionID { object[snakeCase ? "session_id" : "sessionId"] = sessionID }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testNormalizesCachedInputWithoutAddingCacheDurationBreakdownTwice() throws {
        var parser = ClaudeUsageParser()
        parser.consume(try line(usage: ["input_tokens": 4, "output_tokens": 6,
                                       "cache_read_input_tokens": 20, "cache_creation_input_tokens": 10,
                                       "cache_creation": ["ephemeral_5m_input_tokens": 7,
                                                          "ephemeral_1h_input_tokens": 3]]))
        let record = try XCTUnwrap(parser.result().records.first)
        XCTAssertEqual(record.provider, .claudeCode)
        XCTAssertEqual(record.counts.input, 34)
        XCTAssertEqual(record.counts.output, 6)
        XCTAssertEqual(record.counts.total, 40)
        XCTAssertEqual(record.counts.cacheRead, 20)
        XCTAssertEqual(record.counts.cacheWrite, 10)
        XCTAssertEqual(record.model, "sample-model")
        XCTAssertTrue(parser.result().issues.isEmpty)
    }

    func testFinalCumulativeSnapshotReplacesStreamingAndRepeatedChunks() throws {
        var parser = ClaudeUsageParser()
        parser.consume(try line(usage: ["input_tokens": 10, "output_tokens": 2], stopReason: NSNull()))
        parser.consume(try line(timestamp: "2026-11-19T08:01:00Z",
                                usage: ["input_tokens": 10, "output_tokens": 9]))
        parser.consume(try line(timestamp: "2026-11-19T08:01:00Z",
                                usage: ["input_tokens": 10, "output_tokens": 9]))
        let result = parser.result()
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.counts.total, 19)
        XCTAssertEqual(result.records.first?.timestamp, UsageTimestamp.parse("2026-11-19T08:01:00Z"))
    }

    func testCompletedSnapshotSurvivesLaterReplayOfPartialChunk() throws {
        var parser = ClaudeUsageParser()
        parser.consume(try line(usage: ["input_tokens": 10, "output_tokens": 9]))
        parser.consume(try line(timestamp: "2026-11-19T08:02:00Z",
                                usage: ["input_tokens": 10, "output_tokens": 2], stopReason: NSNull()))
        XCTAssertEqual(parser.result().records.first?.counts.total, 19)
    }

    func testAuditAliasesGiveSameGlobalIdentityAsNativeCopies() throws {
        var native = ClaudeUsageParser()
        native.consume(try line())
        var audit = ClaudeUsageParser()
        audit.consume(try line(sessionID: "other-copy-location", snakeCase: true))
        XCTAssertEqual(native.result().records.first?.id, audit.result().records.first?.id)
    }

    func testDistinctRequestsWithSameTimeAndTokensRemainDistinct() throws {
        var parser = ClaudeUsageParser()
        parser.consume(try line(requestID: "request-one"))
        parser.consume(try line(requestID: "request-two"))
        XCTAssertEqual(parser.result().records.count, 2)
        XCTAssertEqual(Set(parser.result().records.map(\.id)).count, 2)
    }

    func testMissingRequestUsesSessionAndMessageWithoutCollidingWithExplicitRequest() throws {
        var parser = ClaudeUsageParser()
        parser.consume(try line(requestID: nil, sessionID: "session-one"))
        parser.consume(try line(requestID: nil, sessionID: "session-two"))
        parser.consume(try line(requestID: "session-one", sessionID: nil))
        XCTAssertEqual(parser.result().records.count, 3)
    }

    func testIncompleteInputOnlyChunkIsExcludedUntilCompleted() throws {
        var parser = ClaudeUsageParser()
        parser.consume(try line(usage: ["input_tokens": 8, "output_tokens": 0], stopReason: NSNull()))
        XCTAssertTrue(parser.result().records.isEmpty)
        XCTAssertTrue(parser.result().issues.contains(.incompleteRecord))
        parser.consume(try line(usage: ["input_tokens": 8, "output_tokens": 3]))
        XCTAssertEqual(parser.result().records.first?.counts.total, 11)
        XCTAssertFalse(parser.result().issues.contains(.incompleteRecord))
    }

    func testAbsentStopReasonAndCachedResponsesRemainCompatible() throws {
        var parser = ClaudeUsageParser()
        parser.consume(try line(stopReason: nil))
        parser.consume(try line(messageID: "cached-message", requestID: "cached-request",
                                usage: ["input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 8],
                                stopReason: NSNull()))
        XCTAssertEqual(parser.result().records.count, 2)
        XCTAssertFalse(parser.result().issues.contains(.incompleteRecord))
    }

    func testMalformedCountsMissingIdentityAndInvalidTimeAreNotTurnedIntoZeroUsage() throws {
        for usage: [String: Any] in [["input_tokens": -1, "output_tokens": 2],
                                     ["input_tokens": true, "output_tokens": 2],
                                     ["input_tokens": 1.5, "output_tokens": 2],
                                     ["input_tokens": Int64.max, "output_tokens": 1],
                                     ["output_tokens": 2]] {
            var parser = ClaudeUsageParser()
            parser.consume(try line(usage: usage))
            XCTAssertTrue(parser.result().records.isEmpty)
            XCTAssertFalse(parser.result().issues.isEmpty)
        }
        var parser = ClaudeUsageParser()
        parser.consume(try line(requestID: nil, sessionID: nil))
        parser.consume(try line(messageID: "", requestID: "request-known"))
        parser.consume(try line(timestamp: "not-a-time"))
        XCTAssertTrue(parser.result().records.isEmpty)
        XCTAssertTrue(parser.result().issues.contains(.missingIdentity))
        XCTAssertTrue(parser.result().issues.contains(.malformedRecord))
    }

    func testIgnoresAuditAggregatesAndUsageTextInsideUserMessages() throws {
        var parser = ClaudeUsageParser()
        for object: [String: Any] in [
            ["type": "result", "timestamp": "2026-11-19T08:00:00Z", "usage": ["input_tokens": 999]],
            ["type": "user", "message": ["usage": ["input_tokens": 999, "output_tokens": 999]]],
            ["type": "assistant", "message": ["content": "message.usage is documentation"]],
        ] {
            parser.consume(try JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertTrue(parser.result().records.isEmpty)
        XCTAssertTrue(parser.result().issues.isEmpty)
    }

    func testCompletedSnapshotMovesAcrossMidnightWithoutDuplicatingResponse() throws {
        var parser = ClaudeUsageParser()
        parser.consume(try line(timestamp: "2026-11-18T23:59:59Z",
                                usage: ["input_tokens": 10, "output_tokens": 2], stopReason: NSNull()))
        parser.consume(try line(timestamp: "2026-11-19T00:00:01Z",
                                usage: ["input_tokens": 10, "output_tokens": 5]))
        XCTAssertEqual(parser.result().records.count, 1)
        XCTAssertEqual(parser.result().records.first?.timestamp, UsageTimestamp.parse("2026-11-19T00:00:01Z"))
    }

    func testCacheStateRoundTripContainsNoConversationContentAndRemainsIdempotent() throws {
        var parser = ClaudeUsageParser()
        let sample = try line(content: "PRIVATE-SENTINEL-CONTENT-ONLY-FOR-TEST")
        parser.consume(sample)
        let encoded = try JSONEncoder().encode(parser)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE-SENTINEL"))
        var restored = try JSONDecoder().decode(ClaudeUsageParser.self, from: encoded)
        restored.consume(sample)
        XCTAssertEqual(restored.result().records.count, 1)
        XCTAssertEqual(restored.result().records.first, parser.result().records.first)
    }
}
