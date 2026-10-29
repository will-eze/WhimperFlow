import SwiftUI
import WhimperFlowKit

/// The key, the microphone and language, how text is typed, and app behaviour.
struct GeneralSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    @State private var microphones: [AudioInputDevice] = AudioDevices.inputDevices()
    @State private var locales: [SpeechLocaleOption] = SpeechLocales.options()

    /// Silence limits offered, plus whatever an older version saved.
    private var silenceChoices: [Double] {
        Array(Set([3, 5, 8, 10, 20, 30, settingsStore.settings.silenceAutoStopSeconds].filter { $0 > 0 })).sorted()
    }

    var body: some View {
        Form {
            Section("Dictation key") {
                Picker("Hold to talk", selection: $settingsStore.settings.hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                if settingsStore.settings.hotkey == .custom {
                    HotkeyRecorderView(settingsStore: settingsStore)
                }
                if let action = GlobeKey.conflict(for: settingsStore.settings) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("🌐 also does “\(action)”. Set “Press 🌐 key to” → “Do Nothing”.")
                            .font(.callout)
                        Spacer()
                        Button("Open Keyboard Settings", action: GlobeKey.openKeyboardSettings)
                    }
                }
                Toggle("Tap the key to talk hands-free", isOn: $settingsStore.settings.tapToToggleEnabled)
                if settingsStore.settings.tapToToggleEnabled {
                    Picker("Stop hands-free after", selection: $settingsStore.settings.silenceAutoStopSeconds) {
                        Text("Never (tap again to stop)").tag(0.0)
                        ForEach(silenceChoices, id: \.self) { seconds in
                            Text("\(Int(seconds)) s of silence").tag(seconds)
                        }
                    }
                }
            }

            Section("Microphone and language") {
                Picker("Microphone", selection: $settingsStore.settings.microphoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(microphones) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Toggle(isOn: $settingsStore.settings.voiceProcessingEnabled) {
                    Text("Reduce background noise")
                    Text("Uses macOS voice processing, which can lower other apps' volume while you dictate.")
                }
                Picker("Language", selection: $settingsStore.settings.localeIdentifier) {
                    ForEach(locales) { option in
                        Text(option.displayName + (option.supportsOnDevice ? "" : " (not on this Mac)"))
                            .tag(option.identifier)
                            .disabled(!option.supportsOnDevice)
                    }
                }
            }

            Section("Typing") {
                Picker("Put text in by", selection: $settingsStore.settings.injectionMethod) {
                    ForEach(InjectionMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
            }

            Section("Behaviour") {
                Toggle("Show the pop-up while dictating", isOn: $settingsStore.settings.showHUD)
                Toggle("Play sounds", isOn: $settingsStore.settings.playSounds)
                Toggle("Keep history", isOn: $settingsStore.settings.historyEnabled)
                Toggle("Open at login", isOn: $settingsStore.settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // A USB mic may have been plugged in since the window opened.
            microphones = AudioDevices.inputDevices()
            locales = SpeechLocales.options()
        }
    }
}
