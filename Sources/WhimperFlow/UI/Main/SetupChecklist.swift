import AppKit
import SwiftUI
import WhimperFlowKit

/// One thing standing between the user and a working dictation, with the
/// single action that fixes it.
enum SetupStep: String, Identifiable, CaseIterable {
    case microphone, accessibility, globeKey, speechRecognition

    var id: String { rawValue }

    /// Steps still to do, in the order they should be done. Speech
    /// Recognition only counts when the Apple engine is chosen; with the
    /// server it is offered separately as the offline fallback.
    @MainActor
    static func pending(permissions: PermissionsManager, engineMonitor: EngineMonitor, settings: FlowSettings) -> [SetupStep] {
        var steps: [SetupStep] = []
        if permissions.microphone != .granted || permissions.blocker(for: .microphone) != nil { steps.append(.microphone) }
        if !permissions.accessibility || permissions.blocker(for: .accessibility) != nil { steps.append(.accessibility) }
        if settings.transcriptionEngine == .apple, permissions.speechRecognition != .granted { steps.append(.speechRecognition) }
        if GlobeKey.conflict(for: settings) != nil { steps.append(.globeKey) }
        return steps
    }

    var title: String {
        switch self {
        case .microphone: return "Allow the microphone"
        case .accessibility: return "Allow Accessibility"
        case .globeKey: return "Free up the 🌐 key"
        case .speechRecognition: return "Allow Speech Recognition"
        }
    }

    var service: PermissionsManager.Service? {
        switch self {
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        case .speechRecognition: return .speechRecognition
        case .globeKey: return nil
        }
    }
}

/// The 🌐 key's own system action, which fires alongside dictation when fn
/// is the hotkey.
enum GlobeKey {
    static func conflict(for settings: FlowSettings) -> String? {
        guard settings.hotkey == .fn else { return nil }
        let usage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int ?? 1
        switch usage {
        case 0: return nil
        case 1: return "Change Input Source"
        case 2: return "Show Emoji & Symbols"
        case 3: return "Start Dictation"
        default: return "a system action"
        }
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

/// The setup list on Home: numbered in the order to do them, the first one
/// carrying the prominent button.
struct SetupChecklist: View {
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var engineMonitor: EngineMonitor
    @ObservedObject var settingsStore: SettingsStore

    private var steps: [SetupStep] {
        SetupStep.pending(permissions: permissions, engineMonitor: engineMonitor, settings: settingsStore.settings)
    }

    var body: some View {
        let steps = steps
        VStack(alignment: .leading, spacing: 0) {
            Text(steps.count == 1 ? "One step before you can dictate" : "\(steps.count) steps before you can dictate")
                .font(.headline)
                .padding(.bottom, 10)
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                if index > 0 { Divider().padding(.leading, 34) }
                row(step, number: index + 1, isNext: index == 0)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ step: SetupStep, number: Int, isNext: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(isNext ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isNext ? Color.accentColor : Color.secondary.opacity(0.15)))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.body.weight(.medium))
                Text(explanation(step))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action(step, prominent: isNext)
        }
        .padding(.vertical, 10)
    }

    private func explanation(_ step: SetupStep) -> String {
        if let service = step.service, let blocker = permissions.blocker(for: service) {
            return blocker == .staleGrant
                ? "System Settings shows it on, but that approval belongs to an older build. Fix clears it so macOS can ask again."
                : "If you already allowed it, this build lost it. Reset clears the old approval so macOS asks again."
        }
        switch step {
        case .microphone:
            return "So WhimperFlow can hear you while you hold the key."
        case .accessibility:
            return "So it can see the hotkey and type into the app you're using. Switch WhimperFlow on in the list that opens."
        case .speechRecognition:
            return "The Apple engine needs it to turn speech into text on this Mac."
        case .globeKey:
            return "Pressing 🌐 also does “\(GlobeKey.conflict(for: settingsStore.settings) ?? "")”. Set “Press 🌐 key to” → “Do Nothing” so the two don't fight."
        }
    }

    @ViewBuilder
    private func action(_ step: SetupStep, prominent: Bool) -> some View {
        let button = Button(actionTitle(step)) { perform(step) }
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    private func actionTitle(_ step: SetupStep) -> String {
        if let service = step.service, let blocker = permissions.blocker(for: service) {
            return blocker == .staleGrant ? "Fix" : "Reset"
        }
        switch step {
        case .globeKey: return "Open Keyboard Settings"
        case .accessibility: return "Open Settings"
        default:
            return permissions.status(of: step.service!) == .denied ? "Open Settings" : "Allow"
        }
    }

    private func perform(_ step: SetupStep) {
        guard let service = step.service else {
            GlobeKey.openKeyboardSettings()
            return
        }
        if permissions.blocker(for: service) != nil, permissions.canResetGrants {
            permissions.resetAndRequest(service)
            return
        }
        switch service {
        case .microphone:
            permissions.microphone == .denied ? permissions.openSystemSettings(for: .microphone) : permissions.requestMicrophone()
        case .speechRecognition:
            permissions.speechRecognition == .denied ? permissions.openSystemSettings(for: .speechRecognition) : permissions.requestSpeechRecognition()
        case .accessibility:
            permissions.promptAccessibility()
            permissions.openSystemSettings(for: .accessibility)
        }
    }
}
