import SwiftUI
import WhimperFlowKit

/// Snippets: say a phrase on its own, get a block of text. A list on the
/// left, the selected snippet's editor on the right.
struct SnippetsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var selection: Snippet.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if settingsStore.settings.snippets.isEmpty {
                    ContentUnavailableView {
                        Label("No snippets", systemImage: "text.insert")
                    } description: {
                        Text("Say “my email” and get your address, or “sign off” for a signature.")
                    } actions: {
                        Button("New Snippet", action: add)
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(settingsStore.settings.snippets) { snippet in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.trigger.isEmpty ? "New snippet" : "“\(snippet.trigger)”")
                                    .fontWeight(.medium)
                                    .foregroundStyle(snippet.trigger.isEmpty ? .secondary : .primary)
                                Text(snippet.expansion.isEmpty ? "Empty" : snippet.expansion)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(snippet.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) { remove(snippet.id) }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .onDeleteCommand { if let selection { remove(selection) } }
                    Divider()
                    HStack {
                        Button(action: add) { Label("New Snippet", systemImage: "plus") }
                            .buttonStyle(.borderless)
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            editor
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil { selection = settingsStore.settings.snippets.first?.id }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let index = settingsStore.settings.snippets.firstIndex(where: { $0.id == selection }) {
            let snippet = $settingsStore.settings.snippets[index]
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("When I say").font(.callout).foregroundStyle(.secondary)
                    TextField("e.g. my email", text: snippet.trigger)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                    Text("Say it on its own, as the whole dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: snippet.expansion)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                }
                HStack {
                    Spacer()
                    Button("Delete Snippet", role: .destructive) { remove(settingsStore.settings.snippets[index].id) }
                }
            }
            .padding(24)
        } else if !settingsStore.settings.snippets.isEmpty {
            Text("Pick a snippet to edit it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func add() {
        let snippet = Snippet(trigger: "", expansion: "")
        settingsStore.settings.snippets.append(snippet)
        selection = snippet.id
    }

    private func remove(_ id: Snippet.ID) {
        settingsStore.settings.snippets.removeAll { $0.id == id }
        if selection == id { selection = settingsStore.settings.snippets.first?.id }
    }
}
