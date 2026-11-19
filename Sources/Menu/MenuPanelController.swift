import AppKit

/// Presents the existing menu tree in transparent windows. Only the background
/// view draws with opacity; windows, scroll views and menu content stay at 100%.
@MainActor
final class MenuPanelController {
    private static let submenuGap: CGFloat = 4
    private(set) var panels: [MenuPanel] = []
    private var rootMenu: NSMenu?
    private var anchorFrame = NSRect.zero
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var submenuTimer: Timer?
    private let onClose: (NSMenu) -> Void

    var isOpen: Bool { rootMenu != nil }

    init(onClose: @escaping (NSMenu) -> Void) {
        self.onClose = onClose
    }

    func show(_ menu: NSMenu, relativeTo button: NSView, appearance: MenuAppearance = .load()) {
        close()
        guard let window = button.window else { return }
        anchorFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        rootMenu = menu
        let panel = makePanel(menu, appearance: appearance, screen: screen)
        let frame = Self.frame(size: panel.frame.size,
                               topLeft: NSPoint(x: anchorFrame.maxX - panel.frame.width, y: anchorFrame.minY - 4),
                               within: screen.visibleFrame)
        panel.move(to: frame)
        panels.append(panel)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func close() {
        submenuTimer?.invalidate()
        submenuTimer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        let menu = rootMenu
        rootMenu = nil
        for panel in panels.reversed() {
            panel.orderOut(nil)
            panel.detachContent()
            panel.close()
        }
        panels.removeAll()
        if let menu { onClose(menu) }
    }

    static func frame(size: NSSize, topLeft: NSPoint, within screen: NSRect) -> NSRect {
        let size = NSSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
        return NSRect(x: min(max(topLeft.x, screen.minX), screen.maxX - size.width),
                      y: min(max(topLeft.y - size.height, screen.minY), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func submenuFrames(size: NSSize, parent: NSRect, row: NSRect, within screen: NSRect)
        -> (parent: NSRect, child: NSRect) {
        let gap = submenuGap
        var parentFrame = parent
        if parent.width + gap + size.width <= screen.width {
            let right = min(parent.minX, screen.maxX - parent.width - gap - size.width)
            let left = max(parent.minX, screen.minX + size.width + gap)
            let opensRight = parent.minX - right <= left - parent.minX
            parentFrame.origin.x = opensRight ? right : left
            let x = opensRight ? parentFrame.maxX + gap : parentFrame.minX - gap - size.width
            let child = frame(size: size, topLeft: NSPoint(x: x, y: row.maxY + 6), within: screen)
            return (parentFrame, child)
        }

        // Stack scrollable panels when the screen cannot fit both widths.
        let availableHeight = screen.height - gap
        parentFrame.size.height = min(parent.height, max(availableHeight / 2, availableHeight - size.height))
        let childHeight = min(size.height, availableHeight - parentFrame.height)
        let opensBelow = parent.midY >= screen.midY
        let minParentY = screen.minY + (opensBelow ? childHeight + gap : 0)
        let maxParentY = screen.maxY - parentFrame.height - (opensBelow ? 0 : childHeight + gap)
        parentFrame.origin.y = min(max(parent.maxY - parentFrame.height, minParentY), maxParentY)
        let childTop = opensBelow ? parentFrame.minY - gap : parentFrame.maxY + gap + childHeight
        let child = frame(size: NSSize(width: size.width, height: childHeight),
                          topLeft: NSPoint(x: parentFrame.minX, y: childTop), within: screen)
        return (parentFrame, child)
    }

    private func makePanel(_ menu: NSMenu, appearance: MenuAppearance, screen: NSScreen) -> MenuPanel {
        let panel = MenuPanel(menu: menu, appearance: appearance, maximumHeight: screen.visibleFrame.height - 12)
        panel.onHover = { [weak self, weak panel] index in
            guard let self, let panel else { return }
            self.select(index, in: panel, openSubmenu: true)
        }
        panel.onActivate = { [weak self, weak panel] index in
            guard let self, let panel else { return }
            self.activate(index, in: panel)
        }
        return panel
    }

    private func select(_ index: Int, in panel: MenuPanel, openSubmenu: Bool) {
        guard let depth = panels.firstIndex(where: { $0 === panel }) else { return }
        submenuTimer?.invalidate()
        submenuTimer = nil
        if panel.selectedIndex != index {
            closePanels(after: depth)
            panel.select(index)
        }
        guard openSubmenu, panel.contentMenu.items[index].submenu != nil,
              panels.count == depth + 1 else { return }
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                self.openSubmenu(index, in: panel)
            }
        }
        submenuTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func closePanels(after depth: Int) {
        while panels.count > depth + 1 {
            let panel = panels.removeLast()
            panel.orderOut(nil)
            panel.detachContent()
            panel.close()
        }
        let parent = panels[depth]
        if let frame = parent.frameBeforeSubmenu {
            parent.move(to: frame)
            parent.frameBeforeSubmenu = nil
        }
    }

    private func openSubmenu(_ index: Int, in panel: MenuPanel, selectFirst: Bool = false) {
        guard let depth = panels.firstIndex(where: { $0 === panel }),
              let submenu = panel.contentMenu.items[index].submenu,
              let screen = panel.screen else { return }
        submenuTimer?.invalidate()
        submenuTimer = nil
        closePanels(after: depth)
        let child = makePanel(submenu, appearance: panel.menuAppearance, screen: screen)
        let row = panel.rows[index]
        let rowFrame = panel.convertToScreen(row.convert(row.bounds, to: nil))
        let bounds = screen.visibleFrame
        var frames = Self.submenuFrames(size: child.frame.size, parent: panel.frame, row: rowFrame, within: bounds)
        if let root = panels.first, panel !== root,
           frames.parent.intersects(root.frame) || frames.child.intersects(root.frame) {
            let available = submenuBounds(for: panel, outside: root.frame, within: bounds)
            frames = Self.submenuFrames(size: child.frame.size, parent: panel.frame, row: rowFrame, within: available)
        }
        if frames.parent != panel.frame {
            panel.frameBeforeSubmenu = panel.frame
            panel.move(to: frames.parent)
        }
        child.move(to: frames.child)
        panels.append(child)
        child.orderFrontRegardless()
        if selectFirst, let first = child.selectableIndices.first { child.select(first) }
    }

    private func submenuBounds(for panel: MenuPanel, outside rootFrame: NSRect, within screen: NSRect) -> NSRect {
        let gap = Self.submenuGap
        if panel.frame.maxX <= rootFrame.minX {
            return screen.divided(atDistance: rootFrame.minX - screen.minX - gap, from: .minXEdge).slice
        }
        if panel.frame.minX >= rootFrame.maxX {
            return screen.divided(atDistance: screen.maxX - rootFrame.maxX - gap, from: .maxXEdge).slice
        }
        if panel.frame.maxY <= rootFrame.minY {
            return screen.divided(atDistance: rootFrame.minY - screen.minY - gap, from: .minYEdge).slice
        }
        return screen.divided(atDistance: screen.maxY - rootFrame.maxY - gap, from: .maxYEdge).slice
    }

    private func activate(_ index: Int, in panel: MenuPanel) {
        let item = panel.contentMenu.items[index]
        guard item.isEnabled else { return }
        if item.submenu != nil {
            select(index, in: panel, openSubmenu: false)
            openSubmenu(index, in: panel, selectFirst: true)
        } else if item.action != nil {
            // Dispatch before cleanup so representedObject and menu ownership
            // remain available to the action, just as with a tracked NSMenu.
            panel.contentMenu.performActionForItem(at: index)
            close()
        }
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown { return self.handleKey(event) }
                if self.panels.contains(where: { $0 === event.window }) { return false }
                if self.anchorFrame.contains(NSEvent.mouseLocation) { return false }
                // The hub selector is a native SwiftUI Menu. Let it finish its
                // own tracking before its selection dismisses our panels.
                if let window = event.window, window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return false }
                self.close()
                return false
            }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func handleKey(_ event: NSEvent) -> Bool {
        // Do not consume keyboard events belonging to the native hub picker.
        guard panels.contains(where: { $0 === event.window }), let panel = panels.last else { return false }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case ",": close(); MenuActions.shared.openSettings(nil); return true
            case "q": close(); MenuActions.shared.quit(nil); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 53: close() // Escape
        case 125, 126: // Down / up, skipping separators and informational rows.
            let indices = panel.selectableIndices
            guard !indices.isEmpty else { return true }
            let current = panel.selectedIndex.flatMap { indices.firstIndex(of: $0) }
            let next = current.map { ($0 + (event.keyCode == 125 ? 1 : indices.count - 1)) % indices.count }
                ?? (event.keyCode == 125 ? 0 : indices.count - 1)
            select(indices[next], in: panel, openSubmenu: false)
            panel.rows[indices[next]].scrollToVisible(panel.rows[indices[next]].bounds)
        case 124: // Right
            if let index = panel.selectedIndex { openSubmenu(index, in: panel, selectFirst: true) }
        case 123: // Left
            if panels.count > 1 { closePanels(after: panels.count - 2) }
        case 36, 49: // Return / space
            if let index = panel.selectedIndex { activate(index, in: panel) } else { return false }
        default: return false
        }
        return true
    }
}

@MainActor
final class MenuPanel: NSPanel {
    let contentMenu: NSMenu
    let menuAppearance: MenuAppearance
    private(set) var rows: [MenuPanelRow] = []
    private(set) var selectedIndex: Int?
    var frameBeforeSubmenu: NSRect?
    var onHover: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?
    private let scroll = NSScrollView()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var selectableIndices: [Int] {
        contentMenu.items.indices.filter { contentMenu.items[$0].isEnabled && (contentMenu.items[$0].action != nil || contentMenu.items[$0].submenu != nil) }
    }

    init(menu: NSMenu, appearance: MenuAppearance, maximumHeight: CGFloat) {
        self.contentMenu = menu
        self.menuAppearance = appearance
        let contentWidth = menu.items.compactMap { $0.view?.frame.width }.max() ?? appearance.size(260)
        let width = max(contentWidth, appearance.size(240)) + 24
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .none
        let document = FlippedMenuView(frame: .zero)
        document.setAccessibilityRole(.menu)
        var y: CGFloat = 0
        for (index, item) in menu.items.enumerated() {
            let row = MenuPanelRow(item: item, width: width, appearance: appearance)
            row.frame.origin.y = y
            row.onHover = { [weak self] in self?.onHover?(index) }
            row.onActivate = { [weak self] in self?.onActivate?(index) }
            rows.append(row)
            document.addSubview(row)
            y += row.frame.height
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
        let height = min(y + 12, maximumHeight)
        setContentSize(NSSize(width: width, height: height))
        let surface = FlippedMenuView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 10
        surface.layer?.masksToBounds = true
        let background = MenuBackgroundView(frame: surface.bounds, opacity: appearance.backgroundOpacity)
        background.autoresizingMask = [.width, .height]
        surface.addSubview(background)
        scroll.frame = NSRect(x: 0, y: 6, width: width, height: height - 12)
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = y > height - 12
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        scroll.autoresizingMask = [.width, .height]
        surface.addSubview(scroll)
        contentView = surface
    }

    func move(to frame: NSRect) {
        setFrame(frame, display: false)
        if let document = scroll.documentView {
            scroll.hasHorizontalScroller = document.frame.width > scroll.frame.width
            scroll.hasVerticalScroller = document.frame.height > scroll.contentSize.height
        }
    }

    func select(_ index: Int) {
        if let selectedIndex { rows[selectedIndex].isSelected = false }
        selectedIndex = index
        rows[index].isSelected = contentMenu.items[index].isEnabled
    }

    func detachContent() {
        contentView = nil
        scroll.documentView = nil
        rows.removeAll()
        onHover = nil
        onActivate = nil
    }
}

@MainActor
final class MenuBackgroundView: NSView {
    let opacity: Double

    init(frame: NSRect, opacity: Double) {
        self.opacity = opacity
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class FlippedMenuView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class MenuPanelRow: NSView {
    let item: NSMenuItem
    var onHover: (() -> Void)?
    var onActivate: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(item: NSMenuItem, width: CGFloat, appearance: MenuAppearance) {
        self.item = item
        let height = item.isSeparatorItem ? 9 : (item.view?.frame.height ?? appearance.size(26))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if item.isSeparatorItem {
            let line = NSBox(frame: NSRect(x: 10, y: 4, width: width - 20, height: 1))
            line.boxType = .separator
            addSubview(line)
        } else if let view = item.view {
            view.frame.origin = NSPoint(x: 6, y: 0)
            addSubview(view)
        } else {
            let label = NSTextField(labelWithString: item.title)
            label.font = menuFont(item, appearance: appearance)
            label.textColor = item.isEnabled ? .labelColor : .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            let inset: CGFloat = item.image == nil ? 12 : 32
            label.frame = NSRect(x: inset, y: (height - label.intrinsicContentSize.height) / 2,
                                 width: width - inset - 24, height: label.intrinsicContentSize.height)
            addSubview(label)
            if let image = item.image {
                let icon = NSImageView(frame: NSRect(x: 10, y: (height - 16) / 2, width: 16, height: 16))
                icon.image = image
                addSubview(icon)
            }
        }
        if item.action != nil || item.submenu != nil {
            setAccessibilityElement(true)
            setAccessibilityRole(.menuItem)
            setAccessibilityLabel(item.title)
            setAccessibilityEnabled(item.isEnabled)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func menuFont(_ item: NSMenuItem, appearance: MenuAppearance) -> NSFont {
        if item.isSectionHeader { return .systemFont(ofSize: appearance.size(11), weight: .semibold) }
        return .menuFont(ofSize: appearance.size(NSFont.menuFont(ofSize: 0).pointSize))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit != nil && (item.action != nil || item.submenu != nil) ? self : hit
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard item.isEnabled else { return false }
        onActivate?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected, item.action != nil || item.submenu != nil else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}
