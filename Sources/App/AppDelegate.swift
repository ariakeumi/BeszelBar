import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var isObserving = false
    private var menuIsOpen = false
    private var menuGeneration = UUID()
    private lazy var menuPresenter = MenuPanelController { [weak self] menu in
        self?.menuDidClose(menu)
    }

    func applicationDidFinishLaunching(_: Notification) {
        #if DEBUG
        if DevelopmentSession.isTestHost { return }
        #endif
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "BeszelBar")
            button.image?.size = NSSize(width: 18, height: 18)
            button.target = self
            button.action = #selector(toggleMenu(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        self.statusItem = item

        RefreshService.shared.start()
        startObserving()

        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if DevelopmentSession.isEnabled { WindowManager.shared.showDashboard() }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        if DevelopmentSession.isTestHost { return }
        #endif
        menuPresenter.close()
        RefreshService.shared.stop()
        isObserving = false
        AppState.shared.stopRefreshing()
    }

    @objc private func toggleMenu(_ sender: Any?) {
        if menuPresenter.isOpen {
            menuPresenter.close()
            return
        }
        guard let button = statusItem?.button, button.window != nil else { return }
        let menu = MenuBuilder.build(appState: .shared, onDismiss: { [weak self] in
            self?.menuPresenter.close()
        })
        menuWillOpen(menu)
        menuPresenter.show(menu, relativeTo: button)
        if !menuPresenter.isOpen { menuDidClose(menu) }
    }

    private func startObserving() {
        isObserving = true
        observeState()
    }

    private func observeState() {
        guard isObserving else { return }
        withObservationTracking {
            _ = AppState.shared.instances
            _ = AppState.shared.selectedInstance
            _ = AppState.shared.showsAllHubs
            _ = AppState.shared.hubSnapshots
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObserving else { return }
                self.refreshMenu()
                self.observeState()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showDashboard()
        return true
    }

    private func refreshMenu() {
        // Keep the tracked menu stable while users navigate its submenus.
        guard !menuIsOpen else { return }
        let appState = AppState.shared

        if let button = statusItem?.button {
            let alertCount = appState.activeAlerts.count
            if alertCount > 0 {
                button.image = NSImage(systemSymbolName: "server.rack.fill", accessibilityDescription: "BeszelBar")
                button.title = " \(alertCount)"
            } else {
                button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "BeszelBar")
                button.title = ""
            }
            button.image?.size = NSSize(width: 18, height: 18)
        }

        // Menu rows observe AppState while visible. Build their structure only
        // when opening, rather than allocating hosting views on every poll.
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !menuIsOpen else { return }
        menuGeneration = UUID()
        let updated = MenuBuilder.build(appState: AppState.shared)
        menu.font = updated.font
        releaseContent(of: menu)
        for item in updated.items {
            updated.removeItem(item)
            menu.addItem(item)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuGeneration = UUID()
        menuIsOpen = true
        AppState.shared.setRealtimeEnabled(true)
        RefreshService.shared.setMenuOpen(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        AppState.shared.setRealtimeEnabled(false)
        RefreshService.shared.setMenuOpen(false)
        refreshMenu()

        // AppKit dispatches the selected action after menuDidClose. Release the
        // hosting graphs on the next turn, unless a new menu has been prepared.
        let generation = menuGeneration
        DispatchQueue.main.async { [weak self, weak menu] in
            guard let self, let menu, !self.menuIsOpen,
                  self.menuGeneration == generation else { return }
            self.releaseContent(of: menu)
        }
    }

    private func releaseContent(of menu: NSMenu) {
        for item in menu.items {
            // AppKit or a pending action may still hold an item. Detach views
            // explicitly so those references cannot retain SwiftUI observers.
            item.view = nil
            if let submenu = item.submenu { releaseContent(of: submenu) }
            item.submenu = nil
        }
        menu.removeAllItems()
    }
}
