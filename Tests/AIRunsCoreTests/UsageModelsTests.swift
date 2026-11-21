import Foundation
import XCTest
@testable import AIRunsCore

final class UsageModelsTests: XCTestCase {
    func testProviderCountersNormalizeCacheWithoutDoubleCounting() throws {
        let codex = try XCTUnwrap(TokenCounts.codex([
            "input_tokens": 100, "cached_input_tokens": 60, "cache_write_input_tokens": 10,
            "output_tokens": 20, "reasoning_output_tokens": 5, "total_tokens": 120]))
        XCTAssertEqual(codex.total, 120)
        let claude = try XCTUnwrap(TokenCounts.claude([
            "input_tokens": 30, "cache_read_input_tokens": 60,
            "cache_creation_input_tokens": 10, "output_tokens": 20,
            "cache_creation": ["ephemeral_5m_input_tokens": 10]]))
        XCTAssertEqual(claude.total, 120)
        XCTAssertEqual(claude.input, 100)
        XCTAssertEqual(claude.cacheWrite, 10)
    }

    func testInvalidAndOverflowingCountersAreRejectedIncludingCacheDecode() throws {
        XCTAssertNil(TokenCounts(input: -1, output: 2))
        XCTAssertNil(TokenCounts(input: Int64.max, output: 1))
        XCTAssertNil(TokenCounts(input: 10, output: 1, cacheRead: 11))
        XCTAssertNil(TokenCounts.codex(["input_tokens": true, "output_tokens": 1]))
        XCTAssertNil(TokenCounts.codex(["input_tokens": 5, "output_tokens": 2, "total_tokens": 90]))
        XCTAssertNil(TokenCounts.claude(["input_tokens": Int64.max, "cache_read_input_tokens": 1, "output_tokens": 0]))
        XCTAssertThrowsError(try JSONDecoder().decode(TokenCounts.self,
            from: Data(#"{"input":-1,"output":1,"cacheRead":0,"cacheWrite":0,"reasoning":0}"#.utf8)))
    }

    func testCumulativeArithmeticCannotTurnResetIntoUsage() throws {
        let earlier = try XCTUnwrap(TokenCounts(input: 100, output: 20, cacheRead: 40))
        let later = try XCTUnwrap(TokenCounts(input: 150, output: 30, cacheRead: 50))
        XCTAssertEqual(later.subtracting(earlier)?.total, 60)
        XCTAssertNil(earlier.subtracting(later))
        XCTAssertEqual(earlier.adding(earlier)?.total, 240)
    }

    func testRollingPeriodAndLocalTodayUseEventTimeAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(UsageTimestamp.parse("2026-03-08T16:00:00Z"))
        let rolling = UsagePeriod.last24Hours.interval(now: now, calendar: calendar)
        XCTAssertEqual(rolling.duration, 86_400)
        let today = UsagePeriod.today.interval(now: now, calendar: calendar)
        XCTAssertEqual(today.start, UsageTimestamp.parse("2026-03-08T05:00:00Z"))
        XCTAssertEqual(today.duration, 11 * 3_600)
        XCTAssertNotNil(UsageTimestamp.parse("2026-11-19T12:00:00.123456Z"))
    }
}
