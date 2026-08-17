import SwiftUI
import WhimperFlowKit

/// Spoken trigger phrases that expand to canned text.
struct SnippetsSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var selection: Snippet.ID?

    var body: some View {
        Form {
            Section {
                Text("Say the trigger phrase alone to insert the expansion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List(selection: $selection) {
                    ForEach($settingsStore.settings.snippets) { $snippet in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Trigger phrase", text: $snippet.trigger)
                                .textFieldStyle(.roundedBorder)
                            TextEditor(text: $snippet.expansion)
                                .frame(minHeight: 60)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.3))
                                )
                        }
                        .padding(.vertical, 4)
                        .tag(snippet.id)
                    }
                    .onDelete { indexSet in
                        settingsStore.settings.snippets.remove(atOffsets: indexSet)
                    }
                }
                .frame(minHeight: 260)

                HStack {
                    Button {
                        settingsStore.settings.snippets.append(Snippet(trigger: "", expansion: ""))
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        deleteSelected()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func deleteSelected() {
        guard let selection else { return }
        settingsStore.settings.snippets.removeAll { $0.id == selection }
        self.selection = nil
    }
}
