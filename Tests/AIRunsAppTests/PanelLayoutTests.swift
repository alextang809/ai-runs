import AppKit
import SwiftUI
import XCTest
@testable import AIRunsApp

final class PanelLayoutTests: XCTestCase {
    @MainActor
    func testQuickActionsFitInThreeCompactMenuRowsBeforeAccountsAreAdded() {
        let view = NSHostingView(rootView: MenuQuickActions(manager: AccountManager(),
            openAccounts: {}, openUsage: {}, openStatus: { _ in })
            .frame(width: PanelLayout.menuWidth))

        XCTAssertEqual(view.fittingSize.width, PanelLayout.menuWidth, accuracy: 1)
        XCTAssertEqual(view.fittingSize.height, 84, accuracy: 1)
    }

    func testFlyoutStaysInScreenBudgetAtBottomOfLongList() {
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 360, flyoutHeight: 240, maximumHeight: 400), 160)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 50, flyoutHeight: 240, maximumHeight: 400), 50)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 360, flyoutHeight: 500, maximumHeight: 400), 0)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: -20, flyoutHeight: 240, maximumHeight: 400), 0)
    }
}
