import AppKit
import Combine
import WhimperFlowKit

/// Menu bar presence: state-aware icon and the app's main menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let settingsStore: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    var openSettings: (() -> Void)?
    var openHistory: (() -> Void)?

    init(controller: DictationController, settingsStore: SettingsStore) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.controller = controller
        self.settingsStore = settingsStore
        super.init()

        updateIcon(for: .idle)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateIcon(for: state) }
            .store(in: &cancellables)
    }

    private func updateIcon(for state: DictationState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch state {
        case .idle: symbol = "mic"
        case .listening: symbol = "mic.fill"
        case .processing: symbol = "waveform"
        case .error: symbol = "mic.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WhimperFlow")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = state.isListening ? .systemRed : nil
    }

    // Rebuild the menu each open so labels reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = settingsStore.settings

        let stateItem = NSMenuItem(title: stateDescription, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        let toggleTitle = controller.state.isListening
            ? "Stop Dictation"
            : "Start Hands-Free Dictation"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let hint = NSMenuItem(title: "Hold \(settings.hotkeyDisplayName) to talk", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let historyItem = NSMenuItem(title: "History & Stats…", action: #selector(showHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit WhimperFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private var stateDescription: String {
        switch controller.state {
        case .idle: return "WhimperFlow — ready"
        case .listening(let handsFree): return handsFree ? "Listening (hands-free)…" : "Listening…"
        case .processing: return "Processing…"
        case .error(let message): return "Error: \(message)"
        }
    }

    @objc private func toggleDictation() {
        controller.toggleFromMenu()
    }

    @objc private func showSettings() {
        openSettings?()
    }

    @objc private func showHistory() {
        openHistory?()
    }
}
