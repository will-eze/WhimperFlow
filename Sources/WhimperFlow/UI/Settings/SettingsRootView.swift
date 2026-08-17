import SwiftUI
import WhimperFlowKit

/// Root tab container for the WhimperFlow Settings window.
struct SettingsRootView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var permissions: PermissionsManager

    init(settingsStore: SettingsStore, permissions: PermissionsManager) {
        self.settingsStore = settingsStore
        self.permissions = permissions
    }

    var body: some View {
        TabView {
            GeneralSettingsView(settingsStore: settingsStore)
                .tabItem { Label("General", systemImage: "gearshape") }

            FormattingSettingsView(settingsStore: settingsStore)
                .tabItem { Label("Formatting", systemImage: "textformat") }

            DictionarySettingsView(settingsStore: settingsStore)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

            SnippetsSettingsView(settingsStore: settingsStore)
                .tabItem { Label("Snippets", systemImage: "text.insert") }

            AppsSettingsView(settingsStore: settingsStore)
                .tabItem { Label("Apps", systemImage: "app.badge") }

            PermissionsSettingsView(permissions: permissions)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 700, height: 520)
    }
}
