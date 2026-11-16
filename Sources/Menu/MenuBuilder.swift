import SwiftUI
import AppKit

@MainActor
enum MenuBuilder {
    private static let menuWidth: CGFloat = 320

    static func build(appState: AppState, appearance: MenuAppearance = .load()) -> NSMenu {
        let menu = makeMenu(appearance: appearance)
        menu.autoenablesItems = false
        let actions = MenuActions.shared

        let headerItem = NSMenuItem()
        let headerView = host(MenuHeaderView(
            appState: appState,
            width: appearance.size(menuWidth),
            onOpenWebDashboard: { [weak headerItem] url in
                headerItem?.menu?.cancelTracking()
                NSWorkspace.shared.open(url)
            },
            onOpenSettings: { [weak headerItem] in
                headerItem?.menu?.cancelTracking()
                actions.openSettings(nil)
            },
            onQuit: { [weak headerItem] in
                headerItem?.menu?.cancelTracking()
                actions.quit(nil)
            },
            onSelectHub: { [weak headerItem] instance in
                headerItem?.menu?.cancelTracking()
                appState.selectInstance(instance)
            }
        ), width: menuWidth, minimumHeight: 46, appearance: appearance)
        headerItem.view = headerView
        menu.addItem(headerItem)

        if !appState.activeAlerts.isEmpty {
            menu.addItem(createAlertsSubmenu(alerts: appState.activeAlerts, appearance: appearance))
            menu.addItem(NSMenuItem.separator())
        }

        if appState.instances.isEmpty {
            menu.addItem(createInfoItem("No Hub Configured", subtext: String(localized: "Open Settings to add a hub"), appearance: appearance))
        } else {
            for instance in appState.visibleInstances {
                let snapshot = appState.hubSnapshots[instance.id] ?? HubSnapshot()
                if appState.showsAllHubs {
                    let heading = NSMenuItem.sectionHeader(title: instance.displayName)
                    menu.addItem(heading)
                }
                if let notice = snapshot.notice {
                    menu.addItem(createInfoItem("Hub needs attention", subtext: notice, appearance: appearance))
                }
                if snapshot.isLoading && snapshot.systems.isEmpty {
                    menu.addItem(createInfoItem("Loading…", subtext: nil, appearance: appearance))
                } else if snapshot.systems.isEmpty && snapshot.errorMessage == nil {
                    menu.addItem(createInfoItem("No Systems Found", subtext: nil, appearance: appearance))
                }
                for system in snapshot.systems {
                    menu.addItem(createSystemItem(for: HubSystem(instance: instance, system: system, connectionURL: snapshot.connectedURL), appState: appState, appearance: appearance))
                }
            }
        }

        return menu
    }

    private static func createAlertsSubmenu(alerts: [HubAlert], appearance: MenuAppearance) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Alerts (\(alerts.count))"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        item.image?.size = NSSize(width: appearance.size(14), height: appearance.size(14))
        item.image?.isTemplate = false

        let submenu = makeMenu(appearance: appearance)

        for entry in alerts.prefix(10) {
            let alert = entry.alert
            let systemName = "\(entry.systemName) · \(entry.instance.displayName)"
            let alertItem = NSMenuItem()

            let view = host(AlertMenuRowView(alert: alert, systemName: systemName),
                            width: menuWidth - 20, minimumHeight: 44, appearance: appearance)
            alertItem.view = view

            submenu.addItem(alertItem)
        }

        if alerts.count > 10 {
            submenu.addItem(NSMenuItem.separator())
            let moreItem = NSMenuItem(title: String(localized: "+\(alerts.count - 10) more alerts"), action: nil, keyEquivalent: "")
            moreItem.isEnabled = false
            submenu.addItem(moreItem)
        }

        item.submenu = submenu
        return item
    }

    private static func createInfoItem(_ title: LocalizedStringKey, subtext: String?, appearance: MenuAppearance) -> NSMenuItem {
        let item = NSMenuItem()
        let view = host(InfoMenuRowView(title: title, subtext: subtext), width: menuWidth,
                        minimumHeight: subtext != nil ? 40 : 28, appearance: appearance)
        item.view = view
        item.isEnabled = true
        return item
    }

    private static func createSystemItem(for entry: HubSystem, appState: AppState, appearance: MenuAppearance) -> NSMenuItem {
        let system = entry.system
        let item = NSMenuItem(
            title: system.name.isEmpty ? system.id : system.name,
            action: #selector(MenuActions.openSystemInBrowser(_:)),
            keyEquivalent: ""
        )
        item.target = MenuActions.shared
        item.representedObject = entry.id

        let hostingView = host(SystemMenuRowView(appState: appState, entry: entry),
                               width: menuWidth, minimumHeight: 48, appearance: appearance)

        let wrapper = NSView(frame: hostingView.frame)
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = .clear
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        wrapper.addSubview(hostingView)
        hostingView.frame = wrapper.bounds

        item.view = wrapper

        let snapshot = appState.hubSnapshots[entry.instance.id] ?? HubSnapshot()
        let containers = snapshot.containers.filter { $0.system == system.id }
        let submenu = createSystemSubmenu(for: entry, containers: containers, appState: appState, appearance: appearance)
        item.submenu = submenu

        return item
    }

    private static func createSystemSubmenu(for entry: HubSystem, containers: [ContainerRecord], appState: AppState, appearance: MenuAppearance) -> NSMenu {
        let submenu = makeMenu(appearance: appearance)
        let system = entry.system
        let details = appState.hubSnapshots[entry.instance.id]?.details[system.id]

        let detailItem = NSMenuItem()
        let detailView = host(SystemDetailView(appState: appState, entry: entry),
                              width: 250, minimumHeight: 180, appearance: appearance)
        detailItem.view = detailView
        submenu.addItem(detailItem)

        if !containers.isEmpty {
            submenu.addItem(NSMenuItem.separator())

            let headerItem = NSMenuItem()
            let headerView = host(
                HStack {
                    Label("Containers (\(containers.count))", systemImage: "shippingbox.fill")
                        .font(.system(size: appearance.size(11), weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, appearance.size(10))
                .padding(.vertical, appearance.size(4)),
                width: 260, minimumHeight: 24, appearance: appearance
            )
            headerItem.view = headerView
            submenu.addItem(headerItem)

            let sortedContainers = containers.sorted { $0.name.lowercased() < $1.name.lowercased() }

            for container in sortedContainers.prefix(10) {
                let containerItem = NSMenuItem()
                let view = host(ContainerMenuRowView(appState: appState,
                    entry: HubContainer(instance: entry.instance, container: container, systemName: system.name)),
                    width: 260, minimumHeight: 50, appearance: appearance)
                containerItem.view = view
                submenu.addItem(containerItem)
            }

            if containers.count > 10 {
                let moreItem = NSMenuItem(title: String(localized: "+\(containers.count - 10) more containers"), action: nil, keyEquivalent: "")
                moreItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
                moreItem.image?.size = NSSize(width: appearance.size(12), height: appearance.size(12))

                let moreSubmenu = makeMenu(appearance: appearance)
                for container in sortedContainers.dropFirst(10) {
                    let containerItem = NSMenuItem()
                    let view = host(ContainerMenuRowView(appState: appState,
                        entry: HubContainer(instance: entry.instance, container: container, systemName: system.name)),
                        width: 260, minimumHeight: 50, appearance: appearance)
                    containerItem.view = view
                    moreSubmenu.addItem(containerItem)
                }
                moreItem.submenu = moreSubmenu
                submenu.addItem(moreItem)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let dashboardItem = NSMenuItem(title: String(localized: "View Charts…"), action: #selector(MenuActions.openDashboard(_:)), keyEquivalent: "")
        dashboardItem.target = MenuActions.shared
        dashboardItem.representedObject = entry.id
        submenu.addItem(dashboardItem)

        let openItem = NSMenuItem(
            title: String(localized: "Open in Browser"),
            action: #selector(MenuActions.openSystemInBrowser(_:)),
            keyEquivalent: ""
        )
        openItem.target = MenuActions.shared
        openItem.representedObject = entry.id
        openItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        openItem.image?.size = NSSize(width: appearance.size(14), height: appearance.size(14))
        submenu.addItem(openItem)

        let hostname = details?.hostname ?? system.info?.h
        if let hostname = hostname {
            let copyItem = NSMenuItem(
                title: String(localized: "Copy Hostname"),
                action: #selector(MenuActions.copyToClipboard(_:)),
                keyEquivalent: ""
            )
            copyItem.target = MenuActions.shared
            copyItem.representedObject = hostname
            copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            copyItem.image?.size = NSSize(width: appearance.size(14), height: appearance.size(14))
            submenu.addItem(copyItem)
        }

        return submenu
    }

    private static func makeMenu(appearance: MenuAppearance) -> NSMenu {
        let menu = NSMenu()
        menu.font = NSFont.menuFont(ofSize: appearance.size(NSFont.menuFont(ofSize: 0).pointSize))
        return menu
    }

    private static func host<Content: View>(_ content: Content, width: CGFloat,
                                           minimumHeight: CGFloat, appearance: MenuAppearance) -> NSView {
        let view = NSHostingView(rootView: content
            .environment(\.menuAppearance, appearance)
            .frame(width: appearance.size(width)))
        view.frame = NSRect(x: 0, y: 0, width: appearance.size(width),
                            height: max(appearance.size(minimumHeight), view.fittingSize.height))
        return view
    }
}
