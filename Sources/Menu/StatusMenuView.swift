import AppKit
import SwiftUI

struct StatusMenuView: View {
    private enum Page: Hashable {
        case alerts
        case system(HubRecordID)
    }

    let appState: AppState
    let onVisibilityChange: (Bool) -> Void
    @AppStorage(MenuAppearance.fontSizeKey) private var fontSize = MenuAppearance.defaultFontSize
    @Environment(\.dismiss) private var dismiss
    @State private var isVisible = false
    @State private var visibleScreenHeight: CGFloat?
    @State private var page: Page?
    @State private var hoverPreview: SystemMenuHoverPreview

    init(appState: AppState, hoverPreview: SystemMenuHoverPreview? = nil,
         onVisibilityChange: @escaping (Bool) -> Void) {
        self.appState = appState
        self.onVisibilityChange = onVisibilityChange
        _hoverPreview = State(initialValue: hoverPreview ?? SystemMenuHoverPreview())
    }

    private var appearance: MenuAppearance { MenuAppearance(fontSize: fontSize) }

    private var listHeightLimit: CGFloat {
        let screenHeight = visibleScreenHeight ?? NSScreen.main?.visibleFrame.height ?? 600
        let availableHeight = max(1, screenHeight - appearance.size(46) - 16)
        return page == .alerts ? min(420, availableHeight) : availableHeight
    }

    var body: some View {
        menuContent
        .frame(width: appearance.size(306))
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.menuAppearance, appearance)
        .background {
            StatusMenuVisibilityObserver { view in
                hoverPreview.menuContentView = view
                visibleScreenHeight = view.window?.screen?.visibleFrame.height
                let visible = view.window?.isKeyWindow == true
                guard isVisible != visible else { return }
                isVisible = visible
                if !visible {
                    hoverPreview.close()
                    page = nil
                }
                onVisibilityChange(visible)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: page) { hoverPreview.close() }
        .onChange(of: appState.visibleInstances.map(\.id)) { hoverPreview.close() }
        .onDisappear {
            hoverPreview.close()
            if isVisible { onVisibilityChange(false) }
        }
    }

    private var menuContent: some View {
        VStack(spacing: 0) {
            if let page {
                pageHeader(page)
            } else {
                MenuHeaderView(
                    appState: appState,
                    onOpenWebDashboard: { url in
                        dismiss()
                        NSWorkspace.shared.open(url)
                    },
                    onOpenSettings: {
                        dismiss()
                        WindowManager.shared.showSettings()
                    },
                    onQuit: { NSApp.terminate(nil) },
                    onSelectHub: { appState.selectInstance($0) }
                )
            }

            MenuFittingContent(maximumHeight: listHeightLimit) {
                VStack(alignment: .leading, spacing: appearance.size(2)) {
                    switch page {
                    case .alerts: alerts
                    case .system(let id):
                        SystemMenuDetails(appState: appState, id: id)
                    case nil: systems
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(appearance.size(4))
            }
            .id(page)
            .buttonStyle(StatusMenuRowButtonStyle())
        }
    }

    @ViewBuilder
    private var systems: some View {
        let alertCount = appState.activeAlerts.count
        if alertCount > 0 {
            Button {
                page = .alerts
            } label: {
                Label("Alerts (\(alertCount))", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: appearance.size(12), weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(appearance.size(8))
            }
            Divider()
        }

        if appState.instances.isEmpty {
            InfoMenuRowView(title: "No Hub Configured", subtext: String(localized: "Open Settings to add a hub"))
        } else {
            ForEach(appState.visibleInstances) { instance in
                let snapshot = appState.hubSnapshots[instance.id] ?? HubSnapshot()
                if appState.showsAllHubs {
                    Text(instance.displayName)
                        .font(.system(size: appearance.size(11), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, appearance.size(10))
                        .padding(.vertical, appearance.size(4))
                        .accessibilityAddTraits(.isHeader)
                }
                if let notice = snapshot.notice {
                    InfoMenuRowView(title: "Hub needs attention", subtext: notice)
                }
                if snapshot.systems.isEmpty {
                    if snapshot.isLoading {
                        InfoMenuRowView(title: "Loading…", subtext: nil)
                    } else if snapshot.errorMessage == nil {
                        InfoMenuRowView(title: "No Systems Found", subtext: nil)
                    }
                }
                ForEach(snapshot.systems) { system in
                    let entry = HubSystem(instance: instance, system: system, connectionURL: snapshot.connectedURL)
                    Button {
                        page = .system(entry.id)
                    } label: {
                        SystemMenuRowView(appState: appState, entry: entry)
                            .frame(minHeight: appearance.size(32))
                    }
                    .background {
                        SystemMenuHoverAnchor { anchor, isHovered in
                            if isHovered {
                                hoverPreview.enter(anchor, appState: appState, id: entry.id,
                                                   appearance: appearance, onAction: dismiss.callAsFunction)
                            } else {
                                hoverPreview.exit(anchor)
                            }
                        }
                    }
                }
            }
        }
    }

    private func pageHeader(_ page: Page) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: appearance.size(8)) {
                Button {
                    self.page = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: appearance.size(24), height: appearance.size(24))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .help("Back")

                switch page {
                case .alerts:
                    Text("Alerts (\(appState.activeAlerts.count))")
                case .system(let id):
                    let entry = appState.system(for: id)
                    Text(entry?.name ?? id.recordID)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let entry {
                        SystemDetailActions(appState: appState, entry: entry, onAction: dismiss.callAsFunction)
                    }
                }
            }
            .font(.system(size: appearance.size(13), weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(appearance.size(8))
            Divider()
        }
    }

    private var alerts: some View {
        ForEach(appState.activeAlerts) { entry in
            AlertMenuRowView(alert: entry.alert, systemName: "\(entry.systemName) · \(entry.instance.displayName)")
        }
    }

}

struct SystemMenuDetails: View {
    @Environment(\.menuAppearance) private var appearance
    let appState: AppState
    let id: HubRecordID
    var onAction: (() -> Void)? = nil
    var showsLoadAverage = false

    var body: some View {
        if let entry = appState.system(for: id) {
            let snapshot = appState.hubSnapshots[id.hubID]
            let containers = (snapshot?.containers ?? []).filter { $0.system == id.recordID }
            SystemDetailView(appState: appState, entry: entry, onAction: onAction, showsLoadAverage: showsLoadAverage)
            if !containers.isEmpty {
                Divider()
                Label("Containers (\(containers.count))", systemImage: "shippingbox.fill")
                    .font(.system(size: appearance.size(11), weight: .semibold))
                    .padding(appearance.size(8))
                    .accessibilityAddTraits(.isHeader)
                ForEach(containers) { container in
                    ContainerMenuRowView(appState: appState,
                        entry: HubContainer(instance: entry.instance, container: container, systemName: entry.system.name))
                }
            }
        } else {
            InfoMenuRowView(title: "No Systems Found", subtext: nil)
        }
    }
}

struct SystemDetailActions: View {
    @Environment(\.menuAppearance) private var appearance
    let appState: AppState
    let entry: HubSystem
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: appearance.size(4)) {
            actionButton("View Charts…", icon: "chart.xyaxis.line") {
                onAction()
                WindowManager.shared.showDashboard(systemID: entry.id)
            }
            actionButton("Open in Browser", icon: "safari") {
                guard let url = entry.browserURL else { return }
                onAction()
                NSWorkspace.shared.open(url)
            }
            .disabled(entry.browserURL == nil)
            if let hostname = appState.hubSnapshots[entry.id.hubID]?.details[entry.id.recordID]?.hostname
                ?? entry.system.info?.h {
                actionButton("Copy Hostname", icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hostname, forType: .string)
                    onAction()
                }
            }
        }
        .font(.system(size: appearance.size(12), weight: .medium))
        .buttonStyle(StatusMenuRowButtonStyle())
        .fixedSize()
    }

    private func actionButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: appearance.size(24), height: appearance.size(24))
        }
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

struct MenuFittingContent<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        HeightLimit(maximumHeight: maximumHeight) {
            ViewThatFits(in: .vertical) {
                content()

                ScrollView {
                    content()
                }
                .frame(height: maximumHeight)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct HeightLimit: Layout {
        let maximumHeight: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            // A window's ideal-size query can leave height unspecified.
            // Give ViewThatFits the cap even for that first measurement.
            subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: maximumHeight))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

// The popup can keep its SwiftUI hierarchy mounted after losing key status.
private struct StatusMenuVisibilityObserver: NSViewRepresentable {
    let onChange: (NSView) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView()
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((NSView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                center.addObserver(self, selector: #selector(updateVisibility),
                                   name: NSWindow.didBecomeKeyNotification, object: window)
                center.addObserver(self, selector: #selector(updateVisibility),
                                   name: NSWindow.didResignKeyNotification, object: window)
                center.addObserver(self, selector: #selector(updateVisibility),
                                   name: NSWindow.didChangeScreenNotification, object: window)
            }
            updateVisibility()
        }

        @objc private func updateVisibility() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                onChange?(self)
            }
        }
    }
}

struct StatusMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.5)
                .background {
                    if isEnabled && (isHovered || configuration.isPressed) {
                        RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}
