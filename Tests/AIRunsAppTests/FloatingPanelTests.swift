import AppKit
import XCTest
@testable import AIRunsApp

final class FloatingPanelTests: XCTestCase {
    @MainActor
    func testPanelStaysAboveAppsAcrossSpacesAndStageManager() {
        _ = NSApplication.shared
        let panel = FloatingPanel()
        XCTAssertEqual(panel.level, .statusBar)
        for behavior: NSWindow.CollectionBehavior in [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
            .stationary, .ignoresCycle,
        ] {
            XCTAssertTrue(panel.collectionBehavior.contains(behavior), "Missing \(behavior)")
        }
        XCTAssertFalse(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.canHide)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    @MainActor
    func testPresentAndRecoveryDoNotTakeKeyboardFocus() async {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        let panel = FloatingPanel(workspaceNotifications: notifications)
        let keyWindow = NSApp.keyWindow
        let wasActive = NSApp.isActive
        defer { panel.dismiss() }

        panel.present()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.isPresented)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSApp.isActive, wasActive)
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await drainNotifications()
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSApp.isActive, wasActive)
        XCTAssertFalse(panel.isKeyWindow)
    }

    @MainActor
    func testWorkspaceChangesRestoreTemporarilyRemovedPanel() async {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        let panel = FloatingPanel(workspaceNotifications: notifications)
        defer { panel.dismiss() }
        panel.present()

        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            // Simulate WindowServer removing the window without a user hide.
            panel.orderOut(nil)
            panel.level = .normal
            panel.collectionBehavior = []
            XCTAssertTrue(panel.isPresented)
            XCTAssertFalse(panel.isVisible)
            notifications.post(name: name, object: nil)
            await drainNotifications()
            XCTAssertTrue(panel.isVisible, "Not restored after \(name)")
            XCTAssertEqual(panel.level, .statusBar)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        }
    }

    @MainActor
    func testApplicationUnhideRestoresPresentedPanel() async {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        let panel = FloatingPanel(applicationNotifications: notifications)
        defer { panel.dismiss() }
        panel.present()
        panel.orderOut(nil)
        notifications.post(name: NSApplication.didUnhideNotification, object: NSApp)
        await drainNotifications()
        XCTAssertTrue(panel.isVisible)
    }

    @MainActor
    func testExplicitHideWinsOverQueuedAndFutureRecovery() async {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        let panel = FloatingPanel(workspaceNotifications: notifications,
                                  applicationNotifications: notifications)
        panel.present()
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        panel.dismiss()
        await drainNotifications()
        XCTAssertFalse(panel.isPresented)
        XCTAssertFalse(panel.isVisible)

        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        notifications.post(name: NSApplication.didUnhideNotification, object: nil)
        await drainNotifications()
        XCTAssertFalse(panel.isVisible)

        panel.present()
        XCTAssertTrue(panel.isVisible)
        panel.dismiss()
    }

    @MainActor
    func testNeverPresentedPanelDoesNotAppearOnWorkspaceChanges() async {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        let panel = FloatingPanel(workspaceNotifications: notifications)
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await drainNotifications()
        XCTAssertFalse(panel.isPresented)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    private func drainNotifications() async {
        let drained = expectation(description: "Main run loop delivered presentation changes")
        RunLoop.main.perform { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}
