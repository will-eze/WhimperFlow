import SwiftUI
import WhimperFlowKit

/// Inline "voice functions": open a span mid-dictation to spell, quote, force
/// verbatim/code/caps, or type operators, then close it with `<trigger> stop`
/// (or just release the key). The trigger is only special right before a
/// function name, so it stays usable as an ordinary word.
struct FunctionsSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    private var enabled: Bool { settingsStore.settings.voiceFunctionsEnabled }
    private var trigger: String { settingsStore.settings.functionTriggerText }

    private var triggerBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.functionTrigger ?? "flow" },
            set: { settingsStore.settings.functionTrigger = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Voice functions") {
                Toggle("Enable voice functions", isOn: $settingsStore.settings.voiceFunctionsEnabled)
                caption("Say \u{201C}\(trigger) spell\u{201D}, \u{201C}\(trigger) quote\u{201D}, etc. mid-dictation to switch how the next words are transcribed.")

                HStack {
                    Text("Trigger word")
                    TextField("flow", text: triggerBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .disabled(!enabled)
                    Spacer()
                }
                HStack(spacing: 6) {
                    Text("Try:").font(.caption).foregroundStyle(.secondary)
                    ForEach(triggerPresets, id: \.self) { preset in
                        Button(preset) { settingsStore.settings.functionTrigger = preset }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!enabled)
                    }
                }
                caption("Only \u{201C}hot\u{201D} right before a function name, so \u{201C}\(trigger)\u{201D} still transcribes normally on its own. Say it twice (\u{201C}\(trigger) \(trigger)\u{201D}) to type the word itself. If a word is misheard often, pick a more distinctive one \u{2014} two-word phrases like \u{201C}hey flow\u{201D} are the most reliable.")
            }

            Section("How to use") {
                Text("Open with \u{201C}\(trigger) <function>\u{201D}. Close with \u{201C}\(trigger) stop\u{201D}, or just release the key to close at the end of what you\u{2019}re saying.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Functions") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Say").font(.caption).foregroundStyle(.secondary)
                        Text("Result").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(referenceRows, id: \.spoken) { row in
                        GridRow {
                            Text(row.spoken).font(.system(.callout, design: .monospaced))
                            Text(row.result).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }

    private let triggerPresets = ["flow", "computer", "hey flow"]

    private struct ReferenceRow { let spoken: String; let result: String }

    private var referenceRows: [ReferenceRow] {
        [
            ReferenceRow(spoken: "\(trigger) spell n g i n x",            result: "nginx"),
            ReferenceRow(spoken: "\(trigger) spell caps s f t p",         result: "SFTP"),
            ReferenceRow(spoken: "\(trigger) quote ship it \(trigger) stop", result: "\u{201C}ship it\u{201D}"),
            ReferenceRow(spoken: "\(trigger) literal as-is \(trigger) stop", result: "verbatim, no polishing"),
            ReferenceRow(spoken: "\(trigger) code snake case user id \(trigger) stop", result: "user_id"),
            ReferenceRow(spoken: "\(trigger) caps fixme \(trigger) stop",   result: "FIXME"),
            ReferenceRow(spoken: "\(trigger) symbols dash greater than \(trigger) stop", result: "->"),
        ]
    }

    @ViewBuilder
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
