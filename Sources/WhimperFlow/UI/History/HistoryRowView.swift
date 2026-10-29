import SwiftUI
import AppKit
import WhimperFlowKit

/// A single dictation record: the processed text, a caption line of
/// metadata, hover actions (copy / delete), and an optional disclosure
/// revealing the raw (pre-processing) transcript when it differs.
struct HistoryRowView: View {
    let record: DictationRecord
    let onFix: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showRaw = false

    private var hasRawDiff: Bool {
        record.rawText != record.processedText && !record.rawText.isEmpty
    }

    private var appLabel: String {
        guard let name = record.appName, !name.isEmpty else { return "Unknown" }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.processedText)
                        .font(.body)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(appLabel)
                        Text("\u{00B7}")
                        Text(HistoryFormat.relativeDate(record.date))
                        Text("\u{00B7}")
                        Text(HistoryFormat.duration(record.durationSeconds))
                        Text("\u{00B7}")
                        Text(HistoryFormat.wordCount(record.wordCount))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isHovering {
                    HStack(spacing: 10) {
                        if hasRawDiff {
                            Button(showRaw ? "Hide What It Heard" : "What It Heard") {
                                withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                            }
                            .controlSize(.small)
                        }
                        Button("Fix a word…", action: onFix)
                            .controlSize(.small)

                        Button {
                            copyToPasteboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy text")

                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete")
                    }
                    .transition(.opacity)
                }
            }

            if hasRawDiff {
                if showRaw {
                    Text(record.rawText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        )
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Fix a Word…", action: onFix)
            Button("Copy Text", action: copyToPasteboard)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.processedText, forType: .string)
    }
}
