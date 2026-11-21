import AIRunsCore
import AppKit
import SwiftUI
import XCTest
@testable import AIRunsApp

final class PanelLayoutTests: XCTestCase {
    @MainActor
    func testQuickActionsFitInTwoCompactMenuRowsBeforeAccountsAreAdded() {
        let view = NSHostingView(rootView: MenuQuickActions(manager: AccountManager(),
            openAccounts: {}, addAccount: {}, openUsage: {})
            .frame(width: PanelLayout.menuWidth))

        XCTAssertEqual(view.fittingSize.width, PanelLayout.menuWidth, accuracy: 1)
        XCTAssertEqual(view.fittingSize.height, 56, accuracy: 1)
    }

    @MainActor
    func testProviderSelectionStartsBrowserSignInOrOpensMatchingAPIKeyForm() {
        let navigation = AccountWindowNavigation()
        for provider in AccountProvider.allCases {
            navigation.route = .providers
            var signedIn: [AccountProvider] = []
            navigation.choose(provider) { signedIn.append($0) }
            if provider.usesAPIKey {
                XCTAssertEqual(navigation.route, .apiKey(provider))
                XCTAssertTrue(signedIn.isEmpty)
            } else {
                XCTAssertEqual(navigation.route, .accounts)
                XCTAssertEqual(signedIn, [provider])
            }
        }
    }

    func testFlyoutStaysInScreenBudgetAtBottomOfLongList() {
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 360, flyoutHeight: 240, maximumHeight: 400), 160)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 50, flyoutHeight: 240, maximumHeight: 400), 50)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: 360, flyoutHeight: 500, maximumHeight: 400), 0)
        XCTAssertEqual(PanelLayout.flyoutOffset(rowTop: -20, flyoutHeight: 240, maximumHeight: 400), 0)
    }
}
