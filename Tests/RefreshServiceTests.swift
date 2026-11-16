import XCTest
import AppKit
import SwiftUI
@testable import BeszelBar

@MainActor
final class WindowLifecycleTests: XCTestCase {
    func testClosingDashboardDetachesChartsAndReopeningCreatesNewWindow() throws {
        let manager = BeszelBar.WindowManager.shared
        manager.showDashboard()
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.contentView is NSHostingView<BeszelBar.DashboardView>
        })
        manager.showDashboard()
        XCTAssertEqual(NSApp.windows.filter {
            $0.contentView is NSHostingView<BeszelBar.DashboardView>
        }.count, 1)
        window.close()
        XCTAssertNil(window.contentView, "Closed dashboards must detach the graph and its refresh tasks")
        manager.showDashboard()
        let reopened = try XCTUnwrap(NSApp.windows.first {
            $0.contentView is NSHostingView<BeszelBar.DashboardView>
        })
        defer { reopened.close() }
        XCTAssertFalse(reopened === window)
    }

    func testClosingSettingsDetachesContent() throws {
        BeszelBar.WindowManager.shared.showSettings()
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.contentView is NSHostingView<BeszelBar.SettingsView>
        })
        window.close()
        XCTAssertNil(window.contentView)
    }
}

@MainActor
final class MenuLifecycleTests: XCTestCase {
    func testRepeatedLargeMenusReleaseAllHostingViewsBeforeBackgroundPolling() async throws {
        let suite = "BeszelBarTests.MenuMemory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = BeszelBar.StorageManager(defaults: defaults)
        storage.saveInstances([BeszelBar.Instance(name: "Memory test", url: "https://example.invalid", email: "", credential: "")])
        let state = BeszelBar.AppState(storage: storage, credentials: MenuTestCredentials(), serviceFactory: { _ in MenuMemoryService() })
        state.refresh()
        await state.waitForRefresh()
        defer { state.stopRefreshing() }
        let delegate = BeszelBar.AppDelegate()

        for _ in 0..<3 {
            let menu = BeszelBar.MenuBuilder.build(appState: state)
            let views = trackedViews(in: menu)
            XCTAssertEqual(views.count, 131)
            delegate.menuWillOpen(menu)
            delegate.menuDidClose(menu)
            try await Task.sleep(for: .milliseconds(100))
            state.poll()
            await state.waitForRefresh()
            XCTAssertEqual(menu.numberOfItems, 0)
            XCTAssertTrue(views.allSatisfy { $0.value == nil }, "Closed menus must release every hosting graph, including container overflow menus")
        }
    }

    private final class WeakView {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }

    private func trackedViews(in menu: NSMenu) -> [WeakView] {
        menu.items.flatMap { item -> [WeakView] in
            // System rows wrap the hosting view in a plain AppKit view.
            let own = item.view.map {
                [WeakView((type(of: $0) == NSView.self ? $0.subviews.first : nil) ?? $0)]
            } ?? []
            return own + (item.submenu.map { trackedViews(in: $0) } ?? [])
        }
    }

    func testClosingMenuReleasesNestedViewsAfterActionsHaveRun() async throws {
        let delegate = BeszelBar.AppDelegate()
        let menu = NSMenu()
        let item = NSMenuItem(title: "System", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let detail = NSMenuItem()
        item.representedObject = "pending-action"
        item.view = NSHostingView(rootView: Text("System"))
        detail.view = NSHostingView(rootView: Text("Details"))
        weak var rowView = item.view
        weak var detailView = detail.view
        submenu.addItem(detail)
        item.submenu = submenu
        menu.addItem(item)

        delegate.menuWillOpen(menu)
        delegate.menuDidClose(menu)
        XCTAssertEqual(menu.numberOfItems, 1, "Keep the selection intact until AppKit dispatches its action")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(menu.numberOfItems, 0)
        XCTAssertNil(item.view)
        XCTAssertNil(detail.view)
        XCTAssertNil(item.submenu)
        XCTAssertNil(rowView)
        XCTAssertNil(detailView)
        XCTAssertEqual(item.representedObject as? String, "pending-action")

        delegate.menuNeedsUpdate(menu)
        XCTAssertGreaterThan(menu.numberOfItems, 0, "Reopening must rebuild the menu")
    }

    func testPendingCleanupDoesNotClearReopenedMenu() async throws {
        let delegate = BeszelBar.AppDelegate()
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        delegate.menuWillOpen(menu)
        delegate.menuDidClose(menu)
        delegate.menuNeedsUpdate(menu)
        delegate.menuWillOpen(menu)
        let header = try XCTUnwrap(menu.items.first?.view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(menu.items.first?.view === header)
        delegate.menuDidClose(menu)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(menu.numberOfItems, 0)
    }

    func testPendingCleanupDoesNotClearNewlyPreparedMenu() async throws {
        let delegate = BeszelBar.AppDelegate()
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        delegate.menuWillOpen(menu)
        delegate.menuDidClose(menu)
        delegate.menuNeedsUpdate(menu)
        let header = try XCTUnwrap(menu.items.first?.view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(menu.items.first?.view === header)
    }
}

private struct MenuMemoryService: BeszelBar.BeszelServing {
    func fetchSystems() throws -> [BeszelBar.SystemRecord] {
        let rows = (0..<12).map { ["id": "system-\($0)", "name": "System \($0)", "status": "up"] }
        return try JSONDecoder().decode([BeszelBar.SystemRecord].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    func fetchContainers(filter: String?) -> [BeszelBar.ContainerRecord] {
        (0..<98).map {
            BeszelBar.ContainerRecord(id: "container-\($0)", name: "Container \($0)",
                cpu: 1, memory: 20, net: 0, health: .healthy, status: "running",
                image: "test:latest", system: "system-\($0 % 8)", updated: 0)
        }
    }
    func fetchSystemDetails() -> [BeszelBar.SystemDetailsRecord] { [] }
    func fetchAlerts(filter: String?) -> [BeszelBar.AlertRecord] { [] }
    func fetchHistory(systemID: String, range: BeszelBar.HistoryRange, now: Date) -> [BeszelBar.SystemStatsRecord] { [] }
}

@MainActor
final class RefreshServiceTests: XCTestCase {
    func testOpeningRefreshesImmediatelyAndClosingRestoresDefaultWithoutChangingPreferences() throws {
        var refreshes = 0
        try withService(refresh: { refreshes += 1 }) { service, defaults in
            service.start()
            XCTAssertEqual(service.scheduledInterval, 30)
            XCTAssertEqual(refreshes, 1)

            service.setMenuOpen(true)
            XCTAssertEqual(service.scheduledInterval, 1)
            XCTAssertEqual(refreshes, 2)
            service.setMenuOpen(true)
            XCTAssertEqual(refreshes, 2)
            XCTAssertNil(defaults.object(forKey: "refreshInterval"))

            service.setMenuOpen(false)
            XCTAssertEqual(service.scheduledInterval, 30)
            XCTAssertEqual(refreshes, 2)
            XCTAssertNil(defaults.object(forKey: "refreshInterval"))
        }
    }

    func testPreferenceChangesKeepMenuFastAndRestoreLatestBackgroundInterval() throws {
        try withService { service, defaults in
            defaults.set(60, forKey: "refreshInterval")
            service.start()
            XCTAssertEqual(service.scheduledInterval, 60)
            service.setMenuOpen(true)
            defaults.set(120, forKey: "refreshInterval")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            runLoop(for: 0.7, mode: .default)
            XCTAssertEqual(service.scheduledInterval, 1)

            service.setMenuOpen(false)
            XCTAssertEqual(service.scheduledInterval, 120)
            defaults.set(300, forKey: "refreshInterval")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            runLoop(for: 0.7, mode: .default)
            XCTAssertEqual(service.scheduledInterval, 300)
        }
    }

    func testPollingContinuesDuringMenuTrackingAndSlowsAfterClosing() throws {
        var refreshes = 0
        try withService(refresh: { refreshes += 1 }) { service, _ in
            service.start()
            service.setMenuOpen(true)
            XCTAssertEqual(refreshes, 2)
            runLoop(for: 2.2, mode: .eventTracking)
            XCTAssertGreaterThanOrEqual(refreshes, 4)

            service.setMenuOpen(false)
            let countAtClose = refreshes
            runLoop(for: 1.2, mode: .eventTracking)
            XCTAssertEqual(refreshes, countAtClose)
        }
    }

    func testMenuCallbacksDoNotRestartStoppedService() throws {
        var refreshes = 0
        try withService(refresh: { refreshes += 1 }) { service, _ in
            service.start()
            service.setMenuOpen(true)
            service.stop()
            service.setMenuOpen(false)
            service.setMenuOpen(true)
            XCTAssertNil(service.scheduledInterval)
            let countAtStop = refreshes
            runLoop(for: 1.2, mode: .eventTracking)
            XCTAssertEqual(refreshes, countAtStop)
        }
    }

    private func withService(refresh: @escaping @MainActor () -> Void = {},
                             body: (RefreshService, UserDefaults) -> Void) throws {
        let suite = "BeszelBarTests.RefreshService.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let service = RefreshService(defaults: defaults, refresh: refresh)
        defer {
            service.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        body(service, defaults)
    }

    private func runLoop(for duration: TimeInterval, mode: RunLoop.Mode) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(mode: mode, before: deadline)
        }
    }
}

// Exercise the app module's menu views, not only the duplicated test models.
@MainActor
final class MenuRefreshTests: XCTestCase {
    func testMenuRendersRealtimeMetricsDuringTrackingWithoutPollingEverySecond() async throws {
        let suite = "BeszelBarTests.MenuRealtime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = BeszelBar.StorageManager(defaults: defaults)
        let hub = BeszelBar.Instance(name: "Realtime test", url: "https://example.invalid", email: "", credential: "")
        storage.saveInstances([hub])
        let api = MenuRealtimeService()
        let state = BeszelBar.AppState(storage: storage, credentials: MenuTestCredentials(), serviceFactory: { _ in api })
        state.refresh()
        await state.waitForRefresh()
        state.setRealtimeEnabled(true)
        let menu = BeszelBar.MenuBuilder.build(appState: state)
        let service = BeszelBar.RefreshService(defaults: defaults, refresh: { state.poll() })
        service.start()
        service.setMenuOpen(true)
        defer { service.stop(); state.stopRefreshing() }
        let tracking = MenuTrackingSession(menu: menu, state: state)
        await tracking.run()
        XCTAssertGreaterThanOrEqual(Set(tracking.samples.compactMap(\.cpu)).count, 3)
        XCTAssertGreaterThanOrEqual(Set(tracking.samples.map(\.image)).count, 3,
                                    "The open menu must render incoming realtime metrics")
        let systemsCalls = await api.systemsCalls
        XCTAssertEqual(systemsCalls, 1, "Fresh realtime metrics must not trigger second-by-second collection reads")
        state.setRealtimeEnabled(false)
        for _ in 0..<100 {
            if await api.streamClosed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let closed = await api.streamClosed
        XCTAssertTrue(closed)
    }

    func testMenuDisplaysAsyncPollingResultsWhileTracking() async throws {
        let suite = "BeszelBarTests.MenuRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = BeszelBar.StorageManager(defaults: defaults)
        let hub = BeszelBar.Instance(name: "Polling test", url: "https://example.invalid", email: "", credential: "")
        storage.saveInstances([hub])
        let api = MenuPollingService()
        let state = BeszelBar.AppState(storage: storage, credentials: MenuTestCredentials(), serviceFactory: { _ in api })
        state.refresh()
        await state.waitForRefresh()
        await api.delayDetails()
        let menu = BeszelBar.MenuBuilder.build(appState: state)
        let service = BeszelBar.RefreshService(defaults: defaults, refresh: { state.refresh() })
        service.start()
        service.setMenuOpen(true)
        defer { service.stop(); state.stopRefreshing() }

        let tracking = MenuTrackingSession(menu: menu, state: state)
        await tracking.run()
        XCTAssertGreaterThanOrEqual(Set(tracking.samples.compactMap(\.cpu)).count, 3,
                                    "Slow system details must not hold up the one-second systems poll")
        XCTAssertGreaterThanOrEqual(Set(tracking.samples.map(\.image)).count, 3,
                                    "The open menu must render the new polling results")
        let detailsCalls = await api.detailsCalls
        XCTAssertEqual(detailsCalls, 2, "The slow collection must keep only one in-flight request")
    }
}

@MainActor
final class MenuFontSizeTests: XCTestCase {
    func testSavedFontSizeAppliesWhenRebuildingMenus() throws {
        let suite = "BeszelBarTests.MenuFont.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = BeszelBar.AppState(storage: BeszelBar.StorageManager(defaults: defaults), credentials: MenuTestCredentials())
        let standard = BeszelBar.MenuBuilder.build(appState: state, appearance: .load(from: defaults))
        let standardHeader = try XCTUnwrap(standard.items.first?.view)
        XCTAssertEqual(standardHeader.frame.width, 320)

        defaults.set(18.0, forKey: BeszelBar.MenuAppearance.fontSizeKey)
        let restored = try XCTUnwrap(UserDefaults(suiteName: suite))
        let large = BeszelBar.MenuBuilder.build(appState: state, appearance: .load(from: restored))
        let largeHeader = try XCTUnwrap(large.items.first?.view)
        XCTAssertEqual(largeHeader.frame.width, 480)
        XCTAssertGreaterThan(largeHeader.frame.height, standardHeader.frame.height)
        XCTAssertGreaterThan(try XCTUnwrap(large.font).pointSize, try XCTUnwrap(standard.font).pointSize)

        defaults.set(0.0, forKey: BeszelBar.MenuAppearance.fontSizeKey)
        XCTAssertEqual(BeszelBar.MenuAppearance.load(from: defaults).fontSize, 10)
        defaults.set(100.0, forKey: BeszelBar.MenuAppearance.fontSizeKey)
        XCTAssertEqual(BeszelBar.MenuAppearance.load(from: defaults).fontSize, 18)
        defaults.removeObject(forKey: BeszelBar.MenuAppearance.fontSizeKey)
        XCTAssertEqual(BeszelBar.MenuAppearance.load(from: defaults).fontSize, 12)
    }

    func testMenuLayoutsAtSmallDefaultAndLargeFontSizes() async throws {
        let suite = "BeszelBarTests.MenuFontLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = BeszelBar.StorageManager(defaults: defaults)
        let hub = BeszelBar.Instance(name: "Menu font test", url: "https://example.invalid", email: "", credential: "")
        storage.saveInstances([hub])
        let state = BeszelBar.AppState(storage: storage, credentials: MenuTestCredentials(), serviceFactory: { _ in MenuRealtimeService() })
        state.refresh()
        await state.waitForRefresh()
        defer { state.stopRefreshing() }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/screenshots-menu-fonts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for fontSize in [10.0, 12, 18] {
            let appearance = BeszelBar.MenuAppearance(fontSize: fontSize)
            let menu = BeszelBar.MenuBuilder.build(appState: state, appearance: appearance)
            let systemItem = try XCTUnwrap(menu.items.last)
            let submenu = try XCTUnwrap(systemItem.submenu)
            XCTAssertEqual(submenu.font?.pointSize, menu.font?.pointSize)
            for view in menu.items.compactMap(\.view) + submenu.items.compactMap(\.view) {
                // System rows use a clear AppKit wrapper around the hosting view.
                let content = view.subviews.first ?? view
                XCTAssertGreaterThanOrEqual(view.frame.height + 0.5, content.fittingSize.height)
            }
            for (name, content) in [("menu", menu), ("details", submenu)] {
                for (index, view) in content.items.compactMap(\.view).enumerated() {
                    try saveRender(view, to: folder.appendingPathComponent("\(name)-\(Int(fontSize))-\(index).png"))
                }
            }
        }
        let settings = NSHostingView(rootView: BeszelBar.SettingsView(appState: state))
        settings.frame = NSRect(x: 0, y: 0, width: 500, height: 420)
        try saveRender(settings, to: folder.appendingPathComponent("settings.png"))
    }

    private func saveRender(_ view: NSView, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        window.close()
    }
}

private actor MenuRealtimeService: BeszelBar.BeszelServing {
    private(set) var systemsCalls = 0
    private(set) var streamClosed = false
    func fetchSystems() throws -> [BeszelBar.SystemRecord] {
        systemsCalls += 1
        return try JSONDecoder().decode([BeszelBar.SystemRecord].self, from:
            Data(#"[{"id":"realtime-system","name":"Realtime system","status":"up","info":{"cpu":0,"mp":40,"dp":50}}]"#.utf8))
    }
    func realtimeUpdates(systemIDs: [String]) -> AsyncThrowingStream<BeszelBar.RealtimeSystemUpdate, Error>? {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for version in 1...12 {
                        try await Task.sleep(for: .milliseconds(400))
                        let json = #"{"info":{"cpu":\#(version * 5),"mp":40,"dp":50}}"#
                        let metrics = try JSONDecoder().decode(BeszelBar.RealtimeMetrics.self, from: Data(json.utf8))
                        continuation.yield(BeszelBar.RealtimeSystemUpdate(systemID: "realtime-system", metrics: metrics))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { await self?.didClose() }
            }
        }
    }
    private func didClose() { streamClosed = true }
    func fetchSystemDetails() -> [BeszelBar.SystemDetailsRecord] { [] }
    func fetchContainers(filter: String?) -> [BeszelBar.ContainerRecord] { [] }
    func fetchAlerts(filter: String?) -> [BeszelBar.AlertRecord] { [] }
    func fetchHistory(systemID: String, range: BeszelBar.HistoryRange, now: Date) -> [BeszelBar.SystemStatsRecord] { [] }
}

/// Enter tracking from the run loop, outside the test's executing Swift task,
/// just as AppKit does for a status-item click.
@MainActor
private final class MenuTrackingSession {
    struct Sample {
        let cpu: Double?
        let image: Data
    }
    let menu: NSMenu
    let state: BeszelBar.AppState
    var samples: [Sample] = []

    init(menu: NSMenu, state: BeszelBar.AppState) {
        self.menu = menu
        self.state = state
    }

    func run() async {
        let sampleTimer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.sample() }
        }
        let closeTimer = Timer(timeInterval: 3.3, repeats: false) { _ in
            MainActor.assumeIsolated { self.menu.cancelTracking() }
        }
        RunLoop.main.add(sampleTimer, forMode: .common)
        RunLoop.main.add(closeTimer, forMode: .common)
        defer { sampleTimer.invalidate(); closeTimer.invalidate() }
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    _ = self.menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 100), in: nil)
                }
                continuation.resume()
            }
        }
    }

    private func sample() {
        guard let view = menu.items.last?.view,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.representation(using: .png, properties: [:]) else { return }
        samples.append(Sample(cpu: state.visibleSystems.first?.system.cpuPercentage, image: image))
    }
}

private final class MenuTestCredentials: BeszelBar.CredentialStore {
    func saveCredential(_ credential: String, for account: String) -> Bool { true }
    func loadCredential(for account: String) -> String? { nil }
    func deleteCredential(for account: String) -> Bool { true }
}

private actor MenuPollingService: BeszelBar.BeszelServing {
    private var version = 0
    private var delaysDetails = false
    private(set) var detailsCalls = 0
    func delayDetails() { delaysDetails = true }
    func fetchSystems() async throws -> [BeszelBar.SystemRecord] {
        try await Task.sleep(for: .milliseconds(30))
        version += 1
        let json = #"{"id":"polling-system","name":"Polling system","status":"up","info":{"cpu":\#(version),"mp":40,"dp":50}}"#
        return try JSONDecoder().decode([BeszelBar.SystemRecord].self, from: Data("[\(json)]".utf8))
    }
    func fetchSystemDetails() async throws -> [BeszelBar.SystemDetailsRecord] {
        detailsCalls += 1
        if delaysDetails { try await Task.sleep(for: .seconds(4)) }
        return []
    }
    func fetchContainers(filter: String?) async throws -> [BeszelBar.ContainerRecord] { [] }
    func fetchAlerts(filter: String?) async throws -> [BeszelBar.AlertRecord] { [] }
    func fetchHistory(systemID: String, range: BeszelBar.HistoryRange, now: Date) async throws -> [BeszelBar.SystemStatsRecord] { [] }
}
