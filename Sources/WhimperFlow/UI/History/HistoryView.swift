import AppKit
import SwiftUI
import WhimperFlowKit

/// The History & Stats window: a stats header, search, the list of past
/// dictations, and a footer with a "Clear History" action.
struct HistoryView: View {
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var settingsStore: SettingsStore
    let router: MainRouter

    @State private var searchQuery: String = ""
    @State private var isConfirmingClear = false

    init(historyStore: HistoryStore, settingsStore: SettingsStore, router: MainRouter) {
        self.historyStore = historyStore
        self.settingsStore = settingsStore
        self.router = router
    }

    private var stats: DictationStats {
        historyStore.stats(typingWPMBaseline: settingsStore.settings.typingWPMBaseline)
    }

    private var filteredRecords: [DictationRecord] {
        historyStore.search(searchQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryStatsHeader(stats: stats)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider()

            content

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        if historyStore.records.isEmpty {
            emptyState
        } else if filteredRecords.isEmpty {
            noResultsState
        } else {
            List {
                ForEach(filteredRecords) { record in
                    HistoryRowView(record: record, onFix: { router.teaching = record }) {
                        historyStore.delete(id: record.id)
                    }
                    .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search dictations", text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var footer: some View {
        HStack {
            Text(footerCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Clear History\u{2026}", role: .destructive) {
                isConfirmingClear = true
            }
            .disabled(historyStore.records.isEmpty)
            .confirmationDialog(
                "Clear all dictation history?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    historyStore.clear()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all \(historyStore.records.count) recorded dictations. This can't be undone.")
            }
        }
    }

    private var footerCountLabel: String {
        let total = historyStore.records.count
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return total == 1 ? "1 dictation" : "\(total) dictations"
        }
        let shown = filteredRecords.count
        return "\(shown) of \(total) dictations"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No dictations yet. Hold \(settingsStore.settings.hotkeyDisplayName) and speak.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No dictations match \u{201C}\(searchQuery)\u{201D}")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
