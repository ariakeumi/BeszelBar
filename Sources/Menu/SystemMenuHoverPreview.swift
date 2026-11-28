import AppKit
import SwiftUI

@MainActor
final class SystemMenuHoverPreview {
    struct Placement {
        let x: CGFloat
        let yAnchor: CGFloat
        let width: CGFloat
        let height: CGFloat
        var alignsBottom = false

        func frame(contentHeight: CGFloat, within bounds: NSRect) -> NSRect {
            let height = min(ceil(contentHeight), height)
            let originY = alignsBottom ? yAnchor : yAnchor - height
            let y = min(max(originY, bounds.minY), bounds.maxY - height)
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }

    weak var menuContentView: NSView?
    private weak var anchor: NSView?
    private weak var displayedAnchor: NSView?
    private let mouseLocation: () -> CGPoint
    private var panel: PreviewPanel?
    private var transition: Task<Void, Never>?

    init(mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.mouseLocation = mouseLocation
    }

    func enter(_ anchor: NSView, appState: AppState, id: HubRecordID,
               appearance: MenuAppearance, onAction: @escaping () -> Void) {
        transition?.cancel()
        self.anchor = anchor
        guard displayedAnchor !== anchor else { return }
        transition = Task { [weak self, weak anchor] in
            do { try await Task.sleep(for: .milliseconds(160)) }
            catch { return }
            guard let self, let anchor, self.anchor === anchor,
                  appState.system(for: id) != nil else { return }
            self.show(from: anchor, appState: appState, id: id, appearance: appearance, onAction: onAction)
        }
    }

    func exit(_ anchor: NSView) {
        guard self.anchor === anchor else { return }
        self.anchor = nil
        scheduleClose()
    }

    func close() {
        transition?.cancel()
        transition = nil
        anchor = nil
        hidePanel()
    }

    private func scheduleClose() {
        transition?.cancel()
        transition = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            guard let self, self.panel?.frame.contains(self.mouseLocation()) != true else { return }
            self.close()
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        self.panel = nil
        displayedAnchor = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func show(from anchor: NSView, appState: AppState, id: HubRecordID,
                      appearance: MenuAppearance, onAction: @escaping () -> Void) {
        guard let parent = anchor.window, parent.isKeyWindow, parent.isVisible, let screen = parent.screen,
              !anchor.visibleRect.isEmpty else { return }
        hidePanel()

        let row = parent.convertToScreen(anchor.convert(anchor.visibleRect, to: nil))
        // The system window can extend beyond the SwiftUI menu surface.
        let menuFrame: NSRect
        if let menuContentView, menuContentView.window === parent, !menuContentView.bounds.isEmpty {
            menuFrame = parent.convertToScreen(menuContentView.convert(menuContentView.bounds, to: nil))
        } else {
            menuFrame = parent.frame
        }
        let bounds = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        let placement = Self.placement(width: appearance.size(276), row: row, menu: menuFrame, bounds: bounds)
        let preview = PreviewPanel(contentRect: placement.frame(contentHeight: placement.height, within: bounds),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let performAction = { [weak self] in
            self?.close()
            onAction()
        }
        let content = NSHostingView(rootView: MenuFittingContent(maximumHeight: placement.height) {
            VStack(alignment: .leading, spacing: appearance.size(2)) {
                SystemMenuDetails(appState: appState, id: id, onAction: performAction, showsLoadAverage: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(appearance.size(4))
        }
        .environment(\.menuAppearance, appearance)
        .buttonStyle(StatusMenuRowButtonStyle())
        .frame(width: placement.width)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak preview] height in
            let frame = placement.frame(contentHeight: height, within: bounds)
            if let preview, preview.isVisible, preview.frame != frame {
                preview.setFrame(frame, display: true)
            }
        }
        .background {
            SystemMenuHoverAnchor { [weak self, weak preview] _, isHovered in
                guard let self, let preview, self.panel === preview, self.anchor == nil else { return }
                if isHovered { self.transition?.cancel() }
                else { self.scheduleClose() }
            }
        })

        let frame = placement.frame(contentHeight: content.fittingSize.height, within: bounds)
        // Keep the panel frame under our control when the hosting view relayouts.
        content.sizingOptions = []
        preview.setFrame(frame, display: false)
        preview.isReleasedWhenClosed = false
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.hasShadow = true
        preview.appearance = NSAppearance(named: .aqua)
        preview.level = parent.level
        let contentBounds = NSRect(origin: .zero, size: frame.size)
        content.frame = contentBounds
        content.autoresizingMask = [.width, .height]
        let background = NSView(frame: contentBounds)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.white.cgColor
        background.layer?.masksToBounds = true
        if #available(macOS 26.0, *) {
            background.layer?.cornerRadius = 20
            background.layer?.cornerCurve = .continuous
        } else {
            background.layer?.cornerRadius = 10
        }
        background.addSubview(content)
        preview.contentView = background

        displayedAnchor = anchor
        panel = preview
        parent.addChildWindow(preview, ordered: .above)
        preview.orderFront(nil)
    }

    static func placement(width: CGFloat, row: NSRect, menu: NSRect, bounds: NSRect) -> Placement {
        let gap: CGFloat = 4
        let width = min(width, bounds.width)
        let right = menu.maxX + gap
        let left = menu.minX - gap - width
        let height = bounds.height
        if bounds.maxX - right >= width {
            return Placement(x: right, yAnchor: row.maxY, width: width, height: height)
        }
        if left >= bounds.minX {
            return Placement(x: left, yAnchor: row.maxY, width: width, height: height)
        }

        // On narrower screens, keep the preview clear of the hovered row.
        let below = row.minY - gap - bounds.minY
        let above = bounds.maxY - row.maxY - gap
        let x = min(max(row.minX, bounds.minX), bounds.maxX - width)
        if below >= above {
            return Placement(x: x, yAnchor: row.minY - gap, width: width, height: min(height, below))
        }
        return Placement(x: x, yAnchor: row.maxY + gap, width: width, height: min(height, above), alignsBottom: true)
    }

    private final class PreviewPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}

struct SystemMenuHoverAnchor: NSViewRepresentable {
    let onHover: (NSView, Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: view))
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onHover = onHover
    }

    static func dismantleNSView(_ view: TrackingView, coordinator: ()) {
        view.onHover?(view, false)
    }

    final class TrackingView: NSView {
        var onHover: ((NSView, Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) { onHover?(self, true) }
        override func mouseExited(with event: NSEvent) { onHover?(self, false) }
    }
}
