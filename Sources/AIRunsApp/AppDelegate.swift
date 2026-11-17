import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let statusBar = StatusBarController(model: model)
        self.model = model
        self.statusBar = statusBar
        model.start()
        if model.shouldOfferSetup() {
            statusBar.showSettings()
        }
    }
}
