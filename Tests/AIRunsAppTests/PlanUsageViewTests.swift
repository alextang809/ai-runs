import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

final class PlanUsageViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testResetCountdownRoundsUpAndShowsDaysHoursAndMinutes() {
        XCTAssertEqual(PlanUsageReset(at: now.addingTimeInterval(10), now: now).text, "Resets in 1m")
        XCTAssertEqual(PlanUsageReset(at: now.addingTimeInterval(61), now: now).text, "Resets in 2m")
        XCTAssertEqual(PlanUsageReset(at: now.addingTimeInterval(3_660), now: now).text, "Resets in 1h 1m")
        XCTAssertEqual(PlanUsageReset(at: now.addingTimeInterval(90_000), now: now).text, "Resets in 1d 1h")
    }

    func testMissingAndElapsedResetStayDistinct() {
        XCTAssertEqual(PlanUsageReset(at: nil, now: now).text, "Reset time unavailable")
        XCTAssertEqual(PlanUsageReset(at: now.addingTimeInterval(1e24), now: now).text, "Reset time unavailable")
        XCTAssertEqual(PlanUsageReset(at: now, now: now).text, "Reset time passed · awaiting new reading")
        XCTAssertEqual(PlanUsageReset(at: now.addingTimeInterval(-120), now: now).text,
                       "Reset time passed · awaiting new reading")
    }
}
