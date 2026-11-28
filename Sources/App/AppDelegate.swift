import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        #if DEBUG
        if DevelopmentSession.isTestHost { return }
        #endif
        RefreshService.shared.start()
        #if DEBUG
        if DevelopmentSession.isEnabled { WindowManager.shared.showDashboard() }
        #endif
    }

    func applicationWillTerminate(_: Notification) {
        #if DEBUG
        if DevelopmentSession.isTestHost { return }
        #endif
        RefreshService.shared.stop()
        AppState.shared.stopRefreshing()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showDashboard()
        return true
    }
}
