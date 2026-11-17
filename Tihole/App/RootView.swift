import SwiftUI

/// The top of the view tree: resolves the theme, routes between onboarding
/// and the main tabs, and owns the app-wide blocking poll.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let theme = app.theme(for: colorScheme)

        Group {
            if app.config.instances.isEmpty {
                OnboardingView()
            } else {
                MainTabs()
            }
        }
        .environment(\.theme, theme)
        .tint(theme.accent)
        .preferredColorScheme(app.preferredColorScheme)
        .task(id: app.generation) {
            await repeatEvery(5) {
                await app.refreshBlocking()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                app.sceneDidEnterBackground()
            case .active:
                app.sceneDidBecomeActive()
                Task {
                    await app.refreshBlocking()
                }
            default:
                break
            }
        }
    }
}

/// The five tabs. The TUI's ten sidebar entries map onto them like this:
/// Dashboard and Query Log get their own tabs; Domains, Groups, Clients,
/// Adlists, and Local DNS live under Lists; System and Settings each get one;
/// Blocking is the pill in every screen's toolbar.
struct MainTabs: View {
    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label("Dashboard", systemImage: "square.grid.2x2")
            }

            NavigationStack {
                QueryLogView()
            }
            .tabItem {
                Label("Queries", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                ManageView()
            }
            .tabItem {
                Label("Lists", systemImage: "shield.lefthalf.filled")
            }

            NavigationStack {
                SystemView()
            }
            .tabItem {
                Label("System", systemImage: "cpu")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
