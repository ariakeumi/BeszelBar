import SwiftUI

@main
struct BeszelBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #if DEBUG
    @State private var showsMenuBarExtra = !DevelopmentSession.isTestHost
    #else
    @State private var showsMenuBarExtra = true
    #endif

    var body: some Scene {
        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            StatusMenuView(appState: AppState.shared) { isOpen in
                AppState.shared.setRealtimeEnabled(isOpen)
                RefreshService.shared.setMenuOpen(isOpen)
            }
        } label: {
            StatusMenuLabel(appState: AppState.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: AppState.shared)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Open Dashboard…") {
                    WindowManager.shared.showDashboard()
                }
                .keyboardShortcut("d")
                Button("Settings...") {
                    WindowManager.shared.showSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }
}

private struct StatusMenuLabel: View {
    let appState: AppState

    var body: some View {
        let alertCount = appState.activeAlerts.count
        if alertCount > 0 {
            Label {
                Text("\(alertCount)")
            } icon: {
                menuBarIcon
            }
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(Text("Alerts (\(alertCount))"))
        } else {
            menuBarIcon
                .accessibilityLabel("BeszelBar")
        }
    }

    private var menuBarIcon: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .resizable()
            .frame(width: 18, height: 18)
    }
}
