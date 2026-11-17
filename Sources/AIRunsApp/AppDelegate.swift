import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusBar: StatusBarController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let statusBar = StatusBarController(model: model)
        self.model = model
        self.statusBar = statusBar
        model.start()

        // A full menu bar can hide the icon (often behind the camera notch),
        // so the panel can also be opened with a shortcut or by opening the
        // app again.
        hotKey = HotKey { [weak statusBar] in statusBar?.togglePanel(nil) }

        if model.shouldOfferSetup() {
            statusBar.showSettings()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak statusBar] in
            MainActor.assumeIsolated { statusBar?.warnIfIconHidden() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.openPanel()
        return false
    }
}
