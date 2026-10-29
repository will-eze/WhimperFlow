import SwiftUI
import WhimperFlowKit

/// The sections of the Settings window, shown as an icon sidebar.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, formatting, functions, dictionary, snippets, apps, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .formatting: return "Formatting"
        case .functions: return "Functions"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .apps: return "Apps"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .formatting: return "textformat"
        case .functions: return "function"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.insert"
        case .apps: return "app.badge"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

/// Sidebar-driven container for the WhimperFlow Settings window. A left-hand list
/// of labeled icons selects the pane shown in the detail column.
struct SettingsRootView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var permissions: PermissionsManager
    let engineMonitor: EngineMonitor
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.icon)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .navigationTitle("Settings")
        } detail: {
            detail(for: selection)
                .navigationTitle(selection.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralSettingsView(settingsStore: settingsStore, engineMonitor: engineMonitor)
        case .formatting: FormattingSettingsView(settingsStore: settingsStore)
        case .functions: FunctionsSettingsView(settingsStore: settingsStore)
        case .dictionary: DictionarySettingsView(settingsStore: settingsStore)
        case .snippets: SnippetsSettingsView(settingsStore: settingsStore)
        case .apps: AppsSettingsView(settingsStore: settingsStore)
        case .permissions: PermissionsSettingsView(permissions: permissions)
        case .about: AboutSettingsView()
        }
    }
}
