import AppKit
import Combine

/// Keeps the user's visibility choice separate from temporary WindowServer state.
/// Ordering the nonactivating panel forward must never activate AI Runs or take focus.
@MainActor
final class FloatingPanel: NSPanel {
    private(set) var isPresented = false
    private var presentationChanges: AnyCancellable?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         applicationNotifications: NotificationCenter = .default) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        configurePresentation()
        let workspaceChanges = Publishers.MergeMany([
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ].map { workspaceNotifications.publisher(for: $0) })
        presentationChanges = workspaceChanges
            .merge(with: applicationNotifications.publisher(for: NSApplication.didUnhideNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.restorePresentation() }
            }
    }

    func present() {
        isPresented = true
        restorePresentation()
    }

    func dismiss() {
        // Queued workspace notifications must not undo an explicit hide.
        isPresented = false
        orderOut(nil)
    }

    private func restorePresentation() {
        guard isPresented else { return }
        configurePresentation()
        orderFrontRegardless()
    }

    private func configurePresentation() {
        isFloatingPanel = true
        // isFloatingPanel resets the level, so assign the overlay level afterwards.
        level = .statusBar
        hidesOnDeactivate = false
        canHide = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        // Non-normal windows otherwise default to transient (hidden in Mission Control).
        // canJoinAllApplications also keeps the overlay out of Stage Manager's app sets.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                              .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}
