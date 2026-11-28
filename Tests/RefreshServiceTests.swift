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
    func testPopupFitsShortContentAndScrollsWhenTheListOverflows() {
        for (height, expectedHeight) in [(CGFloat(90), CGFloat(90)), (580, 580), (850, 650)] {
            let hostingView = NSHostingView(rootView: BeszelBar.MenuFittingContent(maximumHeight: 650) {
                Text("System rows").frame(width: 306, height: height)
            })
            XCTAssertEqual(hostingView.fittingSize.height, expectedHeight, accuracy: 0.5)
        }
    }

    func testHoverPreviewFitsNearScreenEdgesAndOnNarrowScreens() {
        let screen = NSRect(x: -900, y: -100, width: 900, height: 600)
        let menuAtRight = NSRect(x: -335, y: 45, width: 306, height: 430)
        let row = NSRect(x: -325, y: 367, width: 286, height: 42)
        let leftPlacement = BeszelBar.SystemMenuHoverPreview.placement(
            width: 276, row: row, menu: menuAtRight, bounds: screen
        )
        let left = leftPlacement.frame(contentHeight: 550, within: screen)
        XCTAssertTrue(screen.contains(left))
        XCTAssertEqual(menuAtRight.minX - left.maxX, 4)
        XCTAssertEqual(left.height, 550)
        XCTAssertEqual(leftPlacement.frame(contentHeight: 800, within: screen).height, screen.height)

        let menuAtLeft = NSRect(x: -880, y: 45, width: 306, height: 430)
        let right = BeszelBar.SystemMenuHoverPreview.placement(
            width: 276, row: row.offsetBy(dx: menuAtLeft.minX - menuAtRight.minX, dy: 0),
            menu: menuAtLeft, bounds: screen
        ).frame(contentHeight: 300, within: screen)
        XCTAssertTrue(screen.contains(right))
        XCTAssertEqual(right.minX - menuAtLeft.maxX, 4)

        let narrowScreen = NSRect(x: 0, y: 0, width: 550, height: 480)
        let wideMenu = NSRect(x: 50, y: 16, width: 459, height: 448)
        let bottomRow = NSRect(x: 56, y: 24, width: 444, height: 36)
        let above = BeszelBar.SystemMenuHoverPreview.placement(
            width: 414, row: bottomRow, menu: wideMenu, bounds: narrowScreen
        ).frame(contentHeight: 800, within: narrowScreen)
        XCTAssertTrue(narrowScreen.contains(above))
        XCTAssertGreaterThan(above.minY, bottomRow.maxY)
        XCTAssertEqual(above.maxY, narrowScreen.maxY)
    }

    func testReopeningLargeMenuStartsAndStopsFastRefresh() async throws {
        let suite = "BeszelBarTests.MenuMemory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = BeszelBar.StorageManager(defaults: defaults)
        storage.saveInstances([BeszelBar.Instance(name: "Memory test", url: "https://example.invalid", email: "", credential: "")])
        let state = BeszelBar.AppState(storage: storage, credentials: MenuTestCredentials(), serviceFactory: { _ in MenuMemoryService() })
        let service = BeszelBar.RefreshService(defaults: defaults, refresh: { state.poll() })
        service.start()
        await state.waitForRefresh()
        defer { service.stop(); state.stopRefreshing() }
        XCTAssertEqual(state.visibleSystems.count, 12)
        XCTAssertEqual(state.visibleContainers.count, 98)

        let menu = MenuTestWindow(state: state, service: service)
        defer { menu.close() }
        for _ in 0..<3 {
            menu.show()
            for _ in 0..<100 where service.scheduledInterval != 1 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(service.scheduledInterval, 1)

            menu.window.orderOut(nil)
            for _ in 0..<100 where service.scheduledInterval != 30 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(service.scheduledInterval, 30)
        }
    }

    func testHoveringSystemRowShowsSeparatePreviewWithoutResizingThePopup() async throws {
        let suite = "BeszelBarTests.MenuHover.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = BeszelBar.StorageManager(defaults: defaults)
        storage.saveInstances([BeszelBar.Instance(name: "Hover test", url: "https://example.invalid", email: "", credential: "")])
        let state = BeszelBar.AppState(storage: storage, credentials: MenuTestCredentials(), serviceFactory: { _ in MenuMemoryService() })
        let service = BeszelBar.RefreshService(defaults: defaults, refresh: { state.poll() })
        service.start()
        await state.waitForRefresh()
        defer { service.stop(); state.stopRefreshing() }

        var pointer = CGPoint.zero
        let hoverPreview = BeszelBar.SystemMenuHoverPreview(mouseLocation: { pointer })
        let menuInset: CGFloat = 20
        let menu = MenuTestWindow(state: state, service: service, defaults: defaults, hoverPreview: hoverPreview,
                                  horizontalInset: menuInset)
        defer { menu.close() }
        menu.window.appearance = NSAppearance(named: .darkAqua)
        let host = try XCTUnwrap(menu.window.contentView)
        XCTAssertGreaterThan(host.fittingSize.height, 400, "The first window sizing pass must include the host list")
        menu.show()
        let row = try XCTUnwrap(hoverAnchor(in: host))
        let trackingArea = try XCTUnwrap(row.trackingAreas.first)
        func hoverEvent(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
        }
        XCTAssertTrue(trackingArea.options.contains(.inVisibleRect))
        let menuFrame = menu.window.frame
        row.mouseEntered(with: try hoverEvent(.mouseEntered, in: menu.window))
        for _ in 0..<100 where menu.window.childWindows?.isEmpty != false {
            try await Task.sleep(for: .milliseconds(10))
        }

        let preview = try XCTUnwrap(menu.window.childWindows?.first)
        XCTAssertTrue(preview.isVisible)
        XCTAssertFalse(preview.canBecomeKey)
        XCTAssertTrue(menu.window.isKeyWindow)
        XCTAssertEqual(menu.window.frame, menuFrame)
        let screen = try XCTUnwrap(menu.window.screen)
        XCTAssertTrue(screen.visibleFrame.contains(preview.frame))
        let menuContent = menu.window.convertToScreen(host.convert(host.bounds.insetBy(dx: menuInset, dy: 0), to: nil))
        let gap = max(preview.frame.minX - menuContent.maxX, menuContent.minX - preview.frame.maxX)
        XCTAssertEqual(gap, 4, accuracy: 0.5, "The gap starts at the menu content edge")

        let previewContent = try XCTUnwrap(preview.contentView)
        XCTAssertEqual(previewContent.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(previewContent.layer?.backgroundColor, NSColor.white.cgColor)
        previewContent.layoutSubtreeIfNeeded()
        var trackingView = hoverAnchor(in: previewContent)
        for _ in 0..<100 where trackingView == nil {
            try await Task.sleep(for: .milliseconds(10))
            trackingView = hoverAnchor(in: previewContent)
        }
        let previewAnchor = try XCTUnwrap(trackingView)
        row.mouseExited(with: try hoverEvent(.mouseExited, in: menu.window))
        pointer = CGPoint(x: preview.frame.midX, y: preview.frame.midY)
        previewAnchor.mouseEntered(with: try hoverEvent(.mouseEntered, in: preview))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(preview.isVisible, "Moving from the row into the separate preview must keep it open")
        XCTAssertEqual(menu.window.frame, menuFrame)

        pointer = CGPoint(x: preview.frame.maxX + 20, y: preview.frame.midY)
        previewAnchor.mouseExited(with: try hoverEvent(.mouseExited, in: preview))
        for _ in 0..<100 where preview.isVisible {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(preview.isVisible)
        XCTAssertNil(preview.contentView)
        XCTAssertEqual(menu.window.frame, menuFrame)

        row.mouseEntered(with: try hoverEvent(.mouseEntered, in: menu.window))
        for _ in 0..<100 where menu.window.childWindows?.isEmpty != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reopenedPreview = try XCTUnwrap(menu.window.childWindows?.first)
        menu.window.orderOut(nil)
        for _ in 0..<100 where menu.window.childWindows?.isEmpty == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(menu.window.childWindows?.isEmpty ?? true)
        XCTAssertNil(reopenedPreview.contentView)
    }

    private func hoverAnchor(in view: NSView) -> BeszelBar.SystemMenuHoverAnchor.TrackingView? {
        if let anchor = view as? BeszelBar.SystemMenuHoverAnchor.TrackingView, !anchor.visibleRect.isEmpty {
            return anchor
        }
        return view.subviews.lazy.compactMap { self.hoverAnchor(in: $0) }.first
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
    func testOpenMenuRendersRealtimeMetricsWithoutPollingEverySecond() async throws {
        let suite = "BeszelBarTests.MenuRealtime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = BeszelBar.StorageManager(defaults: defaults)
        let hub = BeszelBar.Instance(name: "Realtime test", url: "https://example.invalid", email: "", credential: "")
        storage.saveInstances([hub])
        let api = MenuRealtimeService()
        let state = BeszelBar.AppState(storage: storage, credentials: MenuTestCredentials(), serviceFactory: { _ in api })
        let service = BeszelBar.RefreshService(defaults: defaults, refresh: { state.poll() })
        service.start()
        await state.waitForRefresh()
        defer { service.stop(); state.stopRefreshing() }
        let menu = MenuTestWindow(state: state, service: service)
        let samples = try await menu.sampleWhileVisible()
        XCTAssertGreaterThanOrEqual(Set(samples.compactMap(\.cpu)).count, 3)
        XCTAssertGreaterThanOrEqual(Set(samples.map(\.image)).count, 3,
                                    "The open menu must render incoming realtime metrics")
        let systemsCalls = await api.systemsCalls
        XCTAssertEqual(systemsCalls, 1, "Fresh realtime metrics must not trigger second-by-second collection reads")
        XCTAssertEqual(service.scheduledInterval, 30)
        for _ in 0..<100 {
            if await api.streamClosed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let closed = await api.streamClosed
        XCTAssertTrue(closed)
    }

    func testOpenMenuDisplaysAsyncPollingResults() async throws {
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
        let service = BeszelBar.RefreshService(defaults: defaults, refresh: { state.refresh() })
        service.start()
        defer { service.stop(); state.stopRefreshing() }

        let menu = MenuTestWindow(state: state, service: service)
        let samples = try await menu.sampleWhileVisible()
        XCTAssertGreaterThanOrEqual(Set(samples.compactMap(\.cpu)).count, 3,
                                    "Slow system details must not hold up the one-second systems poll")
        XCTAssertGreaterThanOrEqual(Set(samples.map(\.image)).count, 3,
                                    "The open menu must render the new polling results")
        let detailsCalls = await api.detailsCalls
        XCTAssertEqual(detailsCalls, 2, "The slow collection must keep only one in-flight request")
    }
}

@MainActor
final class MenuFontSizeTests: XCTestCase {
    func testSavedFontSizeScalesMenuContent() throws {
        let suite = "BeszelBarTests.MenuFont.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = BeszelBar.AppState(storage: BeszelBar.StorageManager(defaults: defaults), credentials: MenuTestCredentials())
        let service = BeszelBar.RefreshService(defaults: defaults, refresh: {})
        let standard = MenuTestWindow(state: state, service: service, defaults: defaults)
        standard.show()
        let standardWidth = try XCTUnwrap(standard.window.contentView).fittingSize.width
        standard.close()

        defaults.set(18.0, forKey: BeszelBar.MenuAppearance.fontSizeKey)
        let restored = try XCTUnwrap(UserDefaults(suiteName: suite))
        let large = MenuTestWindow(state: state, service: service, defaults: restored)
        large.show()
        defer { large.close() }
        XCTAssertGreaterThan(standardWidth, 0)
        XCTAssertEqual(try XCTUnwrap(large.window.contentView).fittingSize.width, standardWidth * 1.5, accuracy: 0.5)

        XCTAssertEqual(BeszelBar.MenuAppearance(fontSize: 0).fontSize, 10)
        XCTAssertEqual(BeszelBar.MenuAppearance(fontSize: 100).fontSize, 18)
        XCTAssertEqual(BeszelBar.MenuAppearance(fontSize: .nan).fontSize, 12)
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

@MainActor
private final class MenuTestWindow {
    struct Sample {
        let cpu: Double?
        let image: Data
    }
    let window: NSWindow
    private let state: BeszelBar.AppState

    init(state: BeszelBar.AppState, service: BeszelBar.RefreshService, defaults: UserDefaults = .standard,
         hoverPreview: BeszelBar.SystemMenuHoverPreview? = nil, horizontalInset: CGFloat = 0) {
        self.state = state
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 306 + 2 * horizontalInset, height: 470),
                          styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BeszelBar.StatusMenuView(appState: state, hoverPreview: hoverPreview) { isOpen in
            state.setRealtimeEnabled(isOpen)
            service.setMenuOpen(isOpen)
        }
        .defaultAppStorage(defaults)
        .padding(.horizontal, horizontalInset))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    func sampleWhileVisible() async throws -> [Sample] {
        show()
        defer { close() }
        var samples: [Sample] = []
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(500))
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            samples.append(Sample(cpu: state.visibleSystems.first?.system.cpuPercentage, image: image))
        }
        return samples
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
