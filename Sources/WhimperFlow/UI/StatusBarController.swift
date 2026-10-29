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

    private let historyStore: HistoryStore
    private let permissions: PermissionsManager

    var open: ((MainSection) -> Void)?
    var teach: ((DictationRecord) -> Void)?

    init(controller: DictationController, settingsStore: SettingsStore, engineMonitor: EngineMonitor,
         historyStore: HistoryStore, permissions: PermissionsManager) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.historyStore = historyStore
        self.permissions = permissions
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

        menu.addItem(disabled(controller.state.isListening ? stateDescription : engineMonitor.summary))
        let pending = SetupStep.pending(permissions: permissions, engineMonitor: engineMonitor, settings: settings)
        if !pending.isEmpty {
            menu.addItem(item(pending.count == 1 ? "Finish Setup (1 step)…" : "Finish Setup (\(pending.count) steps)…",
                              #selector(showHome)))
        } else {
            menu.addItem(disabled("Hold \(settings.hotkeyDisplayName) to talk"))
        }
        menu.addItem(.separator())

        if let last = historyStore.records.first {
            let preview = last.processedText.count > 48 ? String(last.processedText.prefix(47)) + "…" : last.processedText
            menu.addItem(disabled("Last: \u{201C}\(preview)\u{201D}"))
            menu.addItem(item("Copy Last Dictation", #selector(copyLast)))
            menu.addItem(item("Fix a Word in It…", #selector(fixLast)))
            menu.addItem(.separator())
        }

        menu.addItem(item(controller.state.isListening ? "Stop Dictation" : "Start Hands-Free Dictation",
                          #selector(toggleDictation)))
        menu.addItem(.separator())
        menu.addItem(item("Open WhimperFlow", #selector(showHome), key: "o"))
        menu.addItem(item("History", #selector(showHistory), key: "y"))
        menu.addItem(item("Words", #selector(showWords)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WhimperFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private var stateDescription: String {
        switch controller.state {
        case .idle: return "Ready"
        case .listening(let handsFree): return handsFree ? "Listening hands-free…" : "Listening…"
        case .processing: return "Typing…"
        case .error(let message): return message
        }
    }

    @objc private func copyLast() {
        guard let last = historyStore.records.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.processedText, forType: .string)
    }

    @objc private func fixLast() {
        guard let last = historyStore.records.first else { return }
        teach?(last)
    }

    @objc private func showHome() { open?(.home) }
    @objc private func showHistory() { open?(.history) }
    @objc private func showWords() { open?(.words) }
    @objc private func showSettings() { open?(.settings) }

    @objc private func toggleDictation() {
        controller.toggleFromMenu()
    }

}
