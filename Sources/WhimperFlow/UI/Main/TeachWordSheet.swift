import AppKit
import SwiftUI
import WhimperFlowKit

/// Fix a word: starts from the dictation that went wrong. Click the wrong
/// word(s), type how they should be written, and see the corrected sentence
/// before saving.
struct TeachWordSheet: View {
    let record: DictationRecord
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var picked: ClosedRange<Int>?
    @State private var heard = ""
    @State private var write = ""
    @FocusState private var writeFocused: Bool

    private var words: [String] { TeachWord.words(in: record.processedText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fix a word").font(.title2.weight(.semibold))
                Text("Click the word it got wrong. Shift-click to pick a few words in a row.")
                    .foregroundStyle(.secondary)
            }

            WordFlow(spacing: 4, lineSpacing: 6) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    WordChip(word: word, selected: picked?.contains(index) ?? false)
                        .onTapGesture { pick(index) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("When I say").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("the words it heard", text: $heard)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Write").foregroundStyle(.secondary)
                    TextField("how it should be spelled", text: $write)
                        .textFieldStyle(.roundedBorder)
                        .focused($writeFocused)
                        .onSubmit { save(copy: false) }
                }
            }

            preview

            HStack {
                if let existing = existingEntry {
                    Text("Replaces “\(existing.pattern) → \(existing.replacement)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save and Copy Fixed Text") { save(copy: true) }
                    .disabled(!canSave)
                Button("Save") { save(copy: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    // MARK: - Preview

    private var trialSettings: FlowSettings {
        var settings = settingsStore.settings
        settings.teach(heard: heard, write: write)
        return settings
    }

    private var fixedText: String {
        TranscriptProcessor(settings: trialSettings)
            .process(record.rawText, context: ProcessingContext(mode: settingsStore.settings.mode(forBundleID: record.appBundleID)))
            .text
            .trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private var preview: some View {
        if canSave {
            let fixed = fixedText
            VStack(alignment: .leading, spacing: 4) {
                Text("Next time it reads").font(.callout).foregroundStyle(.secondary)
                if fixed == record.processedText {
                    Text("No change to this dictation yet. Check that “When I say” matches the words it typed.")
                        .foregroundStyle(.orange)
                } else {
                    Text(fixed).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Actions

    private var canSave: Bool {
        let h = heard.trimmingCharacters(in: .whitespaces)
        let w = write.trimmingCharacters(in: .whitespaces)
        return !h.isEmpty && !w.isEmpty && h != w
    }

    private var existingEntry: DictionaryEntry? {
        let h = heard.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        return settingsStore.settings.dictionary.first { $0.pattern.caseInsensitiveCompare(h) == .orderedSame }
    }

    private func pick(_ index: Int) {
        if NSEvent.modifierFlags.contains(.shift), let current = picked {
            picked = min(current.lowerBound, index)...max(current.upperBound, index)
        } else {
            picked = picked == index...index ? nil : index...index
        }
        guard let picked else {
            heard = ""
            write = ""
            return
        }
        let phrase = words[picked].joined(separator: " ")
        heard = TeachWord.pattern(from: phrase)
        write = phrase.trimmingCharacters(in: .punctuationCharacters)
        writeFocused = true
    }

    private func save(copy: Bool) {
        guard canSave else { return }
        let fixed = fixedText
        settingsStore.settings.teach(heard: heard, write: write)
        if copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fixed, forType: .string)
        }
        dismiss()
    }
}

private struct WordChip: View {
    let word: String
    let selected: Bool

    var body: some View {
        Text(word)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Lays words out left to right, wrapping like text.
struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows.removeLast()
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows.append(row)
        }
        return rows
    }
}
