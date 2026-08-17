import SwiftUI
import WhimperFlowKit

/// Input hotkey, audio/language, output, and general app-behavior toggles.
struct GeneralSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    @State private var microphones: [AudioInputDevice] = AudioDevices.inputDevices()
    @State private var locales: [SpeechLocaleOption] = SpeechLocales.options()

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Dictation key", selection: $settingsStore.settings.hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }

                if settingsStore.settings.hotkey == .custom {
                    HotkeyRecorderView(settingsStore: settingsStore)
                }

                if let notice = globeKeyNotice {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice)
                            Button("Open Keyboard Settings…") {
                                let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                                NSWorkspace.shared.open(url)
                            }
                            .buttonStyle(.link)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.caption)
                }

                Toggle("Quick-tap toggles hands-free mode", isOn: $settingsStore.settings.tapToToggleEnabled)

                Slider(
                    value: $settingsStore.settings.silenceAutoStopSeconds,
                    in: 0...30,
                    step: 1
                ) {
                    Text("Silence auto-stop")
                }
                Text(silenceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio & Language") {
                Picker("Microphone", selection: $settingsStore.settings.microphoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(microphones) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }

                Toggle("Noise suppression (voice processing)", isOn: $settingsStore.settings.voiceProcessingEnabled)

                Picker("Language", selection: $settingsStore.settings.localeIdentifier) {
                    ForEach(locales) { option in
                        Text(option.displayName + (option.supportsOnDevice ? " (on-device)" : ""))
                            .tag(option.identifier)
                            .disabled(!option.supportsOnDevice)
                    }
                }
            }

            Section("Output") {
                Picker("Injection method", selection: $settingsStore.settings.injectionMethod) {
                    ForEach(InjectionMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }

                Picker("Default formatting", selection: $settingsStore.settings.defaultMode) {
                    ForEach(FormattingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Play sounds", isOn: $settingsStore.settings.playSounds)
                Toggle("Show HUD while dictating", isOn: $settingsStore.settings.showHUD)
                Toggle("Launch at login", isOn: $settingsStore.settings.launchAtLogin)
                Toggle("Keep dictation history", isOn: $settingsStore.settings.historyEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Devices/locales can change while the window is open (e.g. a USB
            // mic plugged in); refresh whenever General becomes visible.
            microphones = AudioDevices.inputDevices()
            locales = SpeechLocales.options()
        }
    }

    /// Warns when fn is the dictation key but macOS also has an action bound
    /// to the Globe key. WhimperFlow swallows fn while it is running, but the
    /// system action returns whenever the app is quit or the tap drops.
    private var globeKeyNotice: String? {
        guard settingsStore.settings.hotkey == .fn else { return nil }
        let usage = CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString,
            "com.apple.HIToolbox" as CFString
        ) as? Int ?? 1
        guard usage != 0 else { return nil }
        let action: String
        switch usage {
        case 1: action = "Change Input Source"
        case 2: action = "Show Emoji & Symbols"
        case 3: action = "Start Dictation (macOS)"
        default: action = "a system action"
        }
        return "Your 🌐 key is also set to “\(action)” system-wide. WhimperFlow intercepts fn while running, but for reliability set “Press 🌐 key to” → “Do Nothing” in Keyboard Settings."
    }

    private var silenceLabel: String {
        let seconds = settingsStore.settings.silenceAutoStopSeconds
        return seconds <= 0
            ? "Off — hands-free dictation only stops when you tap the hotkey again."
            : "\(Int(seconds))s of silence stops hands-free dictation."
    }
}
