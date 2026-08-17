import SwiftUI
import WhimperFlowKit

extension Notification.Name {
    /// Posted with `object: Bool` when hotkey recording starts/stops so the
    /// global event tap can get out of the way (it would otherwise swallow
    /// the very key the user is trying to record).
    static let hotkeyRecordingActive = Notification.Name("WhimperFlow.hotkeyRecordingActive")
}

/// Captures the next key press (while the settings window is key) and stores
/// it as the custom dictation hotkey. Escape cancels recording.
struct HotkeyRecorderView: View {
    @ObservedObject var settingsStore: SettingsStore

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack {
            Text(currentLabel)
                .foregroundStyle(settingsStore.settings.customKeyCode == nil ? .secondary : .primary)
            Spacer()
            Button(isRecording ? "Press a key… (Esc cancels)" : "Record Key") {
                isRecording ? stopRecording() : startRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    private var currentLabel: String {
        if let label = settingsStore.settings.customKeyLabel {
            return "Current: \(label)"
        }
        return "No key recorded yet"
    }

    private func startRecording() {
        isRecording = true
        NotificationCenter.default.post(name: .hotkeyRecordingActive, object: true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            let keyCode = Int64(event.keyCode)
            guard keyCode != 53 else { return nil } // Escape cancels
            settingsStore.settings.customKeyCode = keyCode
            settingsStore.settings.customKeyLabel = KeyCodeNames.name(for: keyCode)
            return nil // swallow the captured press
        }
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if isRecording {
            NotificationCenter.default.post(name: .hotkeyRecordingActive, object: false)
        }
        isRecording = false
    }
}
