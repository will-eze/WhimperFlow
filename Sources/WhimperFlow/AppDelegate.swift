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
    private var hudModel: HUDModel!
    private var hudPanel: HUDPanel!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
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

        statusBar = StatusBarController(controller: controller, settingsStore: settingsStore, engineMonitor: engineMonitor)
        statusBar.openSettings = { [weak self] in self?.showSettings() }
        statusBar.openHistory = { [weak self] in self?.showHistory() }

        hotkey = HotkeyMonitor()
        hotkey.setHotkey(settingsStore.settings.hotkey, customKeyCode: settingsStore.settings.customKeyCode)
        hotkey.onKeyDown = { [weak self] in self?.controller.hotkeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.controller.hotkeyUp() }
        hotkey.onEscape = { [weak self] in self?.controller.escapePressed() ?? false }
        startHotkeyWhenTrusted()

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

        // First run (or missing permissions): open onboarding via Settings.
        // Prompts go up one at a time; TCC silently drops a request raised
        // while another dialog is already on screen, which used to leave the
        // app looking like it had never asked for Accessibility at all.
        if !permissions.allGranted {
            showSettings()
            permissions.requestMissing()
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

    // MARK: - Windows

    func showSettings() {
        permissions.refresh()
        if settingsWindow == nil {
            let root = SettingsRootView(
                settingsStore: settingsStore,
                permissions: permissions,
                engineMonitor: engineMonitor
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "WhimperFlow Settings"
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showHistory() {
        if historyWindow == nil {
            let root = HistoryView(
                historyStore: historyStore,
                settingsStore: settingsStore
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "History & Stats"
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }
}
