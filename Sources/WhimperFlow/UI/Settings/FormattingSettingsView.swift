import SwiftUI
import WhimperFlowKit

/// Deterministic-formatter toggles plus the editable filler-word list.
struct FormattingSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var newFiller: String = ""

    var body: some View {
        Form {
            Section("Cleanup") {
                Toggle("Remove filler words", isOn: $settingsStore.settings.removeFillers)
                caption("Strips words like \u{201C}um\u{201D}, \u{201C}uh\u{201D}, and \u{201C}you know\u{201D} from the transcript.")

                Toggle("Spoken punctuation", isOn: $settingsStore.settings.spokenPunctuationEnabled)
                caption("Say \u{201C}comma\u{201D}, \u{201C}period\u{201D}, \u{201C}new line\u{201D}, etc. to insert punctuation as you speak.")

                Toggle("Auto-punctuate", isOn: $settingsStore.settings.autoPunctuate)
                caption("Adds a terminal period and asks the OS engine for punctuation when it's missing.")

                Toggle("Auto-capitalize", isOn: $settingsStore.settings.autoCapitalize)
                caption("Capitalizes the first letter of each sentence.")

                Toggle("Normalize numbers", isOn: $settingsStore.settings.normalizeNumbers)
                caption("Converts spoken numbers like \u{201C}twenty three\u{201D} into \u{201C}23\u{201D}.")
            }

            Section("Filler phrases") {
                List {
                    ForEach(settingsStore.settings.fillerPhrases, id: \.self) { phrase in
                        HStack {
                            Text(phrase)
                            Spacer()
                            Button {
                                removeFiller(phrase)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { indexSet in
                        settingsStore.settings.fillerPhrases.remove(atOffsets: indexSet)
                    }
                }
                .frame(minHeight: 120, maxHeight: 180)

                HStack {
                    TextField("Add filler phrase", text: $newFiller)
                        .onSubmit(addFiller)
                    Button {
                        addFiller()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newFiller.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button("Restore default fillers") {
                    settingsStore.settings.fillerPhrases = FlowSettings.defaultFillers
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func addFiller() {
        let trimmed = newFiller.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !settingsStore.settings.fillerPhrases.contains(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else {
            newFiller = ""
            return
        }
        settingsStore.settings.fillerPhrases.append(trimmed)
        newFiller = ""
    }

    private func removeFiller(_ phrase: String) {
        if let index = settingsStore.settings.fillerPhrases.firstIndex(of: phrase) {
            settingsStore.settings.fillerPhrases.remove(at: index)
        }
    }
}
