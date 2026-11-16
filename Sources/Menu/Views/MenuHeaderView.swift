import SwiftUI
import AppKit

struct MenuHeaderView: View {
    @Environment(\.menuAppearance) private var appearance
    var appState: AppState
    var width: CGFloat = 320
    var onOpenWebDashboard: (URL) -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    var onSelectHub: (Instance?) -> Void

    private var webDashboardURL: URL? {
        guard let instance = appState.selectedInstance ?? appState.instances.first else { return nil }
        return appState.hubSnapshots[instance.id]?.connectedURL ?? HubURL.baseURL(instance.url)
    }

    private var beszelIcon: Image {
        if let icon = NSImage(named: "AppIcon") {
            return Image(nsImage: icon)
        }
        return Image(systemName: "server.rack")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: appearance.size(8)) {
                Button {
                    guard let url = webDashboardURL else { return }
                    onOpenWebDashboard(url)
                } label: {
                    beszelIcon
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: appearance.size(28), height: appearance.size(28))
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(webDashboardURL == nil)
                .help("menu.openWebDashboard")
                .accessibilityLabel("menu.openWebDashboard")

                VStack(alignment: .leading, spacing: appearance.size(1)) {
                    Text("BeszelBar")
                        .font(.system(size: appearance.size(13), weight: .semibold))
                    scopeSelector
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !appState.visibleSystems.isEmpty {
                    let online = appState.visibleSystems.filter { $0.system.isOnline }.count
                    let offline = appState.visibleSystems.count - online

                    HStack(spacing: appearance.size(6)) {
                        StatusBubble(count: online, color: .green, icon: "checkmark.circle.fill")
                        if offline > 0 {
                            StatusBubble(count: offline, color: .red, icon: "xmark.circle.fill")
                        }
                    }
                    .fixedSize()
                }

                HStack(spacing: appearance.size(4)) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .frame(width: appearance.size(26), height: appearance.size(26))
                            .contentShape(Rectangle())
                    }
                    .help("menu.settings")
                    .accessibilityLabel("menu.settings")
                    .keyboardShortcut(",")

                    Button(action: onQuit) {
                        Image(systemName: "power")
                            .frame(width: appearance.size(26), height: appearance.size(26))
                            .contentShape(Rectangle())
                    }
                    .help("menu.quit")
                    .accessibilityLabel("menu.quit")
                    .keyboardShortcut("q")
                }
                .buttonStyle(.plain)
                .font(.system(size: appearance.size(13), weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .padding(.horizontal, appearance.size(12))
            .padding(.vertical, appearance.size(8))

            Divider()
        }
        .frame(width: width, height: appearance.size(46))
    }

    @ViewBuilder
    private var scopeSelector: some View {
        if appState.instances.count > 1 {
            Menu {
                Button { onSelectHub(nil) } label: {
                    if appState.showsAllHubs {
                        Label("All Hubs", systemImage: "checkmark")
                    } else {
                        Text("All Hubs")
                    }
                }
                Divider()
                ForEach(appState.instances) { instance in
                    Button { onSelectHub(instance) } label: {
                        if !appState.showsAllHubs && instance.id == appState.selectedInstance?.id {
                            Label(instance.displayName, systemImage: "checkmark")
                        } else {
                            Text(instance.displayName)
                        }
                    }
                }
            } label: {
                scopeTitle
            }
            .menuStyle(.borderlessButton)
            .controlSize(.mini)
            .fixedSize(horizontal: false, vertical: true)
            .font(.system(size: appearance.size(10)))
            .foregroundStyle(.secondary)
            .help("menu.showHubs")
            .accessibilityLabel("menu.showHubs")
        } else {
            scopeTitle
                .font(.system(size: appearance.size(10)))
                .foregroundStyle(.secondary)
        }
    }

    private var scopeTitle: some View {
        Group {
            if appState.showsAllHubs {
                Text("All Hubs")
            } else if let instance = appState.selectedInstance {
                Text(instance.displayName)
            } else {
                Text("No Hub Configured")
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

struct StatusBubble: View {
    @Environment(\.menuAppearance) private var appearance
    let count: Int
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: appearance.size(3)) {
            Image(systemName: icon)
                .font(.system(size: appearance.size(10), weight: .semibold))
            Text("\(count)")
                .font(.system(size: appearance.size(10), weight: .bold, design: .rounded))
        }
        .foregroundColor(color)
        .padding(.horizontal, appearance.size(6))
        .padding(.vertical, appearance.size(3))
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}
