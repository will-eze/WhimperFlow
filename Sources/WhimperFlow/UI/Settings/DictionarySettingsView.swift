import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WhimperFlowKit

/// Editable "heard as -> write as" personalization dictionary, with
/// import/export of the shared personalization JSON (dictionary + snippets).
struct DictionarySettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var selection: DictionaryEntry.ID?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Heard phrases on the left are always written as the right side. Entries also bias recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Table(settingsStore.settings.dictionary, selection: $selection) {
                    TableColumn("Heard as") { entry in
                        TextField("e.g. jira", text: binding(for: entry, \.pattern))
                    }
                    TableColumn("Write as") { entry in
                        TextField("e.g. Jira", text: binding(for: entry, \.replacement))
                    }
                    TableColumn("Case sensitive") { entry in
                        Toggle("Case sensitive", isOn: binding(for: entry, \.caseSensitive))
                            .labelsHidden()
                    }
                    .width(110)
                }
                .frame(minHeight: 220)

                HStack {
                    Button {
                        settingsStore.settings.dictionary.append(DictionaryEntry(pattern: "", replacement: ""))
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

                    Button("Import\u{2026}") { importDictionary() }
                    Button("Export\u{2026}") { exportDictionary() }
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            "Dictionary",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func binding<T>(
        for entry: DictionaryEntry,
        _ keyPath: WritableKeyPath<DictionaryEntry, T>
    ) -> Binding<T> {
        guard let index = settingsStore.settings.dictionary.firstIndex(where: { $0.id == entry.id }) else {
            return .constant(entry[keyPath: keyPath])
        }
        return Binding(
            get: { settingsStore.settings.dictionary[index][keyPath: keyPath] },
            set: { settingsStore.settings.dictionary[index][keyPath: keyPath] = $0 }
        )
    }

    private func deleteSelected() {
        guard let selection else { return }
        settingsStore.settings.dictionary.removeAll { $0.id == selection }
        self.selection = nil
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try settingsStore.importPersonalization(from: data)
        } catch {
            errorMessage = "Couldn't import: \(error.localizedDescription)"
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WhimperFlow-Personalization.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try settingsStore.exportPersonalization()
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}
