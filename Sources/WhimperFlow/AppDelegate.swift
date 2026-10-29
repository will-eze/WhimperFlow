import AppKit
import SwiftUI
import Combine
import ServiceManagement
import WhimperFlowKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsStore: SettingsStore!
    private var historyStore: HistoryStore!
    private var permissions: PermissionsManager!
    private var controller: DictationController!
    private var engineMonitor: EngineMonitor!
    private var statusBar: StatusBarController!
    private var hotkey: HotkeyMonitor!
    private var pasteLast: PasteLastShortcut!
    private var hudModel: HUDModel!
    private var hudPanel: HUDPanel!
    private var mainWindow: MainWindowController!
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settingsStore = SettingsStore()
        // Launch at login became the default on 2026-10-29. Settings saved
        // before then say false only because that was the old default; switch
        // them on once, and from then on the toggle's value is the user's.
        if settingsStore.settings.launchAtLoginDefaultApplied != true {
            settingsStore.settings.launchAtLogin = true
            settingsStore.settings.launchAtLoginDefaultApplied = true
        }
        historyStore = HistoryStore()
        permissions = PermissionsManager()
        permissions.beginPolling()

        engineMonitor = EngineMonitor(settingsStore: settingsStore)
        controller = DictationController(
            settingsStore: settingsStore,
            historyStore: historyStore,
            permissions: permissions,
            engineMonitor: engineMonitor
        )

        hudModel = HUDModel()
        hudPanel = HUDPanel(model: hudModel)
        wireHUD()

        let router = MainRouter()
        mainWindow = MainWindowController(context: AppContext(
            settingsStore: settingsStore,
            historyStore: historyStore,
            permissions: permissions,
            engineMonitor: engineMonitor,
            controller: controller,
            router: router
        ))
        AppMenu.install(openWindow: #selector(openSettingsFromMenu), target: self)

        statusBar = StatusBarController(controller: controller, settingsStore: settingsStore, engineMonitor: engineMonitor,
                                        historyStore: historyStore, permissions: permissions)
        statusBar.open = { [weak self] section in self?.mainWindow.show(section) }
        statusBar.teach = { [weak self] record in
            self?.mainWindow.show()
            router.teaching = record
        }

        hotkey = HotkeyMonitor()
        hotkey.setHotkey(settingsStore.settings.hotkey, customKeyCode: settingsStore.settings.customKeyCode)
        hotkey.onKeyDown = { [weak self] in self?.controller.hotkeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.controller.hotkeyUp() }
        hotkey.onEscape = { [weak self] in self?.controller.escapePressed() ?? false }
        startHotkeyWhenTrusted()
        pasteLast = PasteLastShortcut { [weak self] in self?.controller.reinsertLast() }

        // Pause the global tap while the settings window records a new
        // hotkey, so the pressed key reaches the recorder instead of being
        // swallowed (or starting dictation).
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingActive, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                if note.object as? Bool == true {
                    self.hotkey.stop()
                } else {
                    self.hotkey.start()
                }
            }
        }

        // React to settings changes: hotkey rebind + login item.
        settingsStore.$settings
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.hotkey.setHotkey(settings.hotkey, customKeyCode: settings.customKeyCode)
                self?.syncLoginItem(settings.launchAtLogin)
            }
            .store(in: &cancellables)

        if let directory = Snapshot.directory {
            hotkey.stop()
            Snapshot.run(window: mainWindow, router: router, history: historyStore, to: directory)
            return
        }

        // Something still to set up: open Home, whose checklist asks for one
        // permission at a time when the user clicks, instead of a burst of
        // system prompts at launch.
        if !SetupStep.pending(permissions: permissions, engineMonitor: engineMonitor, settings: settingsStore.settings).isEmpty {
            mainWindow.show(.home)
        }
    }

    /// The event tap can only start once Accessibility is granted; retry until
    /// then. Runs in common run loop modes so the retry isn't stalled while a
    /// menu or scroll is tracking.
    private func startHotkeyWhenTrusted() {
        if hotkey.start() { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if self.hotkey.start() { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func wireHUD() {
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state.isListening, !self.hudModel.state.isListening {
                    let server = self.settingsStore.settings.transcriptionEngine == .server
                        && self.engineMonitor.status == .server
                    self.hudModel.engine = server ? "Parakeet" : "Apple"
                }
                self.hudModel.state = state
                guard self.settingsStore.settings.showHUD else { return }
                switch state {
                case .listening, .processing, .error:
                    self.hudPanel.show()
                case .idle:
                    // After an Apple-fallback dictation, leave the HUD up a
                    // moment so its marker can be seen.
                    let linger = self.hudModel.usedFallback ? 1.5 : 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + linger) {
                        guard self.hudModel.state == .idle else { return }
                        self.hudModel.reset()
                        self.hudPanel.hide()
                    }
                }
            }
            .store(in: &cancellables)

        controller.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.hudModel.pushLevel(level) }
            .store(in: &cancellables)

        controller.$usedFallback
            .receive(on: DispatchQueue.main)
            .sink { [weak self] used in self?.hudModel.usedFallback = used }
            .store(in: &cancellables)

        controller.$partialTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.hudModel.partialText = text }
            .store(in: &cancellables)
    }

    private func syncLoginItem(_ enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Login item registration requires a proper .app bundle; harmless in dev runs.
        }
    }

    // MARK: - Window

    @objc private func openSettingsFromMenu() {
        mainWindow.show(.settings)
    }

    /// Opening the app again (Finder, Spotlight, `open -a`) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }
}
