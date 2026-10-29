import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhimperFlowKit

/// The personal dictionary: add a word in one line, then a searchable list
/// that edits in place.
struct WordsView: View {
    @ObservedObject var settingsStore: SettingsStore

    @State private var heard = ""
    @State private var write = ""
    @State private var query = ""
    @State private var errorMessage: String?
    @FocusState private var heardFocused: Bool

    private var entries: [DictionaryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return settingsStore.settings.dictionary }
        return settingsStore.settings.dictionary.filter {
            $0.pattern.localizedCaseInsensitiveContains(q) || $0.replacement.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Words it hears wrong, and how to write them. The quickest way to add one is Fix a word on a dictation in Home or History.")
                    .foregroundStyle(.secondary)
                addRow
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
            list
            Divider()
            TermsEditor(settingsStore: settingsStore)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .toolbar {
            ToolbarItem {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            ToolbarItem {
                Menu {
                    Button("Import Words and Snippets…", action: importFile)
                    Button("Export Words and Snippets…", action: exportFile)
                } label: {
                    Label("Import or export", systemImage: "square.and.arrow.up.on.square")
                }
            }
        }
        .alert("Words", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("When I say…", text: $heard)
                .textFieldStyle(.roundedBorder)
                .focused($heardFocused)
                .onSubmit(add)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("write…", text: $write)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || write.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var list: some View {
        if settingsStore.settings.dictionary.isEmpty {
            ContentUnavailableView("No words yet", systemImage: "character.book.closed",
                                   description: Text("Names, jargon and anything it spells wrong. Type one above."))
        } else if entries.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(entries) { entry in
                    WordRow(entry: binding(for: entry), delete: { remove(entry) })
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) {
                Text(countLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private var countLine: String {
        let total = settingsStore.settings.dictionary.count
        let word = total == 1 ? "word" : "words"
        return entries.count == total ? "\(total) \(word)" : "\(entries.count) of \(total) \(word)"
    }

    private func binding(for entry: DictionaryEntry) -> Binding<DictionaryEntry> {
        Binding(
            get: { settingsStore.settings.dictionary.first { $0.id == entry.id } ?? entry },
            set: { updated in
                if let index = settingsStore.settings.dictionary.firstIndex(where: { $0.id == entry.id }) {
                    settingsStore.settings.dictionary[index] = updated
                }
            }
        )
    }

    private func add() {
        guard settingsStore.settings.teach(heard: heard, write: write) else { return }
        heard = ""
        write = ""
        heardFocused = true
    }

    private func remove(_ entry: DictionaryEntry) {
        settingsStore.settings.dictionary.removeAll { $0.id == entry.id }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settingsStore.importPersonalization(from: Data(contentsOf: url))
        } catch {
            errorMessage = "Couldn't import that file: \(error.localizedDescription)"
        }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WhimperFlow-Personalization.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settingsStore.exportPersonalization().write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

private struct WordRow: View {
    @Binding var entry: DictionaryEntry
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("heard", text: $entry.pattern)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("written", text: $entry.replacement)
                .textFieldStyle(.plain)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.caseSensitive {
                Text("Exact case")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Only matches when the case is exactly as typed on the left")
            }
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
        .contextMenu {
            Toggle("Match Exact Case", isOn: $entry.caseSensitive)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

/// The terms the misheard-word fixer may write, as removable chips.
private struct TermsEditor: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var newTerm = ""

    private var terms: [String] { settingsStore.settings.terms ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Terms you use").font(.headline)
                Spacer()
                TextField("Add a term", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(add)
            }
            Text("Jargon and names a recogniser might mishear. The AI fixer on Jarvis may swap a misheard word for one of these, or for a spelling above.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                WordFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        HStack(spacing: 4) {
                            Text(term)
                            Button {
                                settingsStore.settings.terms = terms.filter { $0 != term }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 84, maxHeight: 84)
        }
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
            newTerm = ""
            return
        }
        settingsStore.settings.terms = [term] + terms
        newTerm = ""
    }
}
