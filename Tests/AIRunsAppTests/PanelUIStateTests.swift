import XCTest
@testable import AIRunsApp

final class PanelUIStateTests: XCTestCase {
    @MainActor
    func testCollapsingASectionCancelsPendingFlyout() async throws {
        let ui = PanelUIState()
        ui.hoverOn(.session("first"))
        ui.hoverOn(.session("second"))
        ui.cancelHover()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(ui.hover)
    }
}
