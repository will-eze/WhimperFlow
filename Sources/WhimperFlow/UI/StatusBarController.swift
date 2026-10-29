import AppKit
import Combine
import WhimperFlowKit

/// Menu bar presence: state-aware icon and the app's main menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let settingsStore: SettingsStore
    private let engineMonitor: EngineMonitor
    /// Engine status over the icon's corner: green server, amber Apple only, red none.
    private let dot = NSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
    private var cancellables: Set<AnyCancellable> = []

    var openSettings: (() -> Void)?
    var openHistory: (() -> Void)?

    init(controller: DictationController, settingsStore: SettingsStore, engineMonitor: EngineMonitor) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.controller = controller
        self.settingsStore = settingsStore
        self.engineMonitor = engineMonitor
        super.init()

        if let button = statusItem.button {
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.borderWidth = 0.5
            dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3),
            ])
        }
        engineMonitor.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.updateDot(status) }
            .store(in: &cancellables)

        updateIcon(for: .idle)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateIcon(for: state) }
            .store(in: &cancellables)
    }

    private func updateDot(_ status: EngineMonitor.Status) {
        let color: NSColor
        switch status {
        case .server: color = .systemGreen
        case .fallbackOnly: color = .systemOrange
        case .none: color = .systemRed
        }
        dot.layer?.backgroundColor = color.cgColor
        statusItem.button?.toolTip = engineMonitor.summary
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
        engineMonitor.check()
        let settings = settingsStore.settings

        let stateItem = NSMenuItem(title: stateDescription, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        let engineItem = NSMenuItem(title: engineMonitor.summary, action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        menu.addItem(engineItem)
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
