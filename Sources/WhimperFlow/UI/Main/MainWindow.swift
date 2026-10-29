import AppKit
import SwiftUI
import WhimperFlowKit

/// The pages of the one WhimperFlow window.
enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case home, history, words, snippets, style, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .words: return "Words"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .words: return "character.book.closed"
        case .snippets: return "text.insert"
        case .style: return "textformat"
        case .settings: return "gearshape"
        }
    }
}

/// Where the window is and what it should show; shared by the menu bar, the
/// window and the teach-a-word sheet.
@MainActor
final class MainRouter: ObservableObject {
    @Published var section: MainSection = .home
    /// The dictation being corrected in the teach-a-word sheet.
    @Published var teaching: DictationRecord?
}

/// Everything the window's pages read or change.
@MainActor
struct AppContext {
    let settingsStore: SettingsStore
    let historyStore: HistoryStore
    let permissions: PermissionsManager
    let engineMonitor: EngineMonitor
    let controller: DictationController
    let router: MainRouter
}

struct MainRootView: View {
    let context: AppContext
    @ObservedObject var router: MainRouter
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var engineMonitor: EngineMonitor

    init(context: AppContext) {
        self.context = context
        router = context.router
        permissions = context.permissions
        engineMonitor = context.engineMonitor
    }

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $router.section) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            page(for: router.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(router.section.title)
        }
        .sheet(item: $router.teaching) { record in
            TeachWordSheet(record: record, settingsStore: context.settingsStore)
        }
    }

    /// Home carries a count of setup steps still to do.
    private func badge(for section: MainSection) -> Int {
        guard section == .home else { return 0 }
        return SetupStep.pending(permissions: permissions, engineMonitor: engineMonitor,
                                 settings: context.settingsStore.settings).count
    }

    @ViewBuilder
    private func page(for section: MainSection) -> some View {
        switch section {
        case .home: HomeView(context: context)
        case .history: HistoryView(historyStore: context.historyStore, settingsStore: context.settingsStore,
                                   router: context.router)
        case .words: WordsView(settingsStore: context.settingsStore)
        case .snippets: SnippetsView(settingsStore: context.settingsStore)
        case .style: StyleView(settingsStore: context.settingsStore)
        case .settings: SettingsView(context: context)
        }
    }
}

/// Owns the window. While it is open WhimperFlow shows in the Dock and the
/// app switcher like any other app; closing it returns to menu bar only.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let context: AppContext
    private var window: NSWindow?

    init(context: AppContext) {
        self.context = context
    }

    func show(_ section: MainSection? = nil) {
        if let section { context.router.section = section }
        context.permissions.refresh()
        context.engineMonitor.check()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "WhimperFlow"
            window.contentMinSize = NSSize(width: 720, height: 500)
            let host = NSHostingView(rootView: MainRootView(context: context))
            // Only the minimum size comes from SwiftUI; otherwise long lists
            // stretch the window to fit every row.
            host.sizingOptions = [.minSize]
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("WhimperFlowMain")
            if !window.setFrameUsingName("WhimperFlowMain") { window.center() }
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        context.router.teaching = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
