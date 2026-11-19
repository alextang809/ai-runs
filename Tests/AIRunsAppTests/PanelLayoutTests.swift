import XCTest
@testable import AIRunsApp

final class PanelLayoutTests: XCTestCase {
    func testFlyoutStaysInScreenBudgetAtBottomOfLongList() {
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 360, flyoutHeight: 240, maximumHeight: 400), 160)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 50, flyoutHeight: 240, maximumHeight: 400), 50)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 360, flyoutHeight: 500, maximumHeight: 400), 0)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: -20, flyoutHeight: 240, maximumHeight: 400), 0)
    }
}
