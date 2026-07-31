import AppKit
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(store: store)
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}
