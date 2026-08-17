import SwiftUI

struct RecorderView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.prompts.isEmpty {
                emptyState
            } else {
                HSplitView {
                    promptList.frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                    detail.frame(minWidth: 420)
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clips folder").font(.caption).foregroundStyle(.secondary)
                Text(model.folder.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(model.folder.path)
            }
            Spacer(minLength: 12)
            Button("Choose…") { model.chooseFolder() }
            Button("Reveal") { model.revealInFinder() }
            if !model.prompts.isEmpty {
                Text("\(model.recordedCount) of \(model.prompts.count) recorded")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(model.recordedCount == model.prompts.count ? .green : .secondary)
            }
        }
        .padding(12)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.badge.mic").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No prompts in this folder yet").font(.title3.weight(.semibold))
            Text("""
                Start from a set covering prose, email, jargon and numbers — then edit \
                any sentence so it sounds like something you'd actually dictate.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack {
                Button("Load starter set") { model.loadStarterPrompts() }
                    .keyboardShortcut(.defaultAction)
                Button("Add blank prompt") { model.addPrompt() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var promptList: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.prompts) { prompt in
                    HStack(spacing: 8) {
                        Image(systemName: prompt.isRecorded ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(prompt.isRecorded ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(prompt.name).font(.callout.weight(.medium))
                            Text(prompt.text.isEmpty ? "No sentence yet" : prompt.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(prompt.id)
                    .contextMenu {
                        Button("Delete recording") { model.deleteRecording(prompt.id) }
                            .disabled(!prompt.isRecorded)
                        Button("Delete prompt", role: .destructive) { model.deletePrompt(prompt.id) }
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    model.addPrompt()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Starter set") { model.loadStarterPrompts() }
                    .buttonStyle(.borderless)
                    .help("Add any starter prompts that aren't already here")
            }
            .padding(8)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let prompt = model.selectedPrompt {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(prompt.name).font(.title3.weight(.semibold))
                    Spacer()
                    if prompt.isRecorded {
                        Label("Recorded", systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Read this aloud").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { prompt.text },
                        set: { model.updateText($0, for: prompt.id) }
                    ))
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    .frame(minHeight: 120, maxHeight: 200)
                    Text("This is the reference the score is measured against — write it the way you want it to come out.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                meter

                HStack(spacing: 10) {
                    Button {
                        model.toggleRecording()
                    } label: {
                        Label(model.isRecording ? "Stop" : (prompt.isRecorded ? "Re-record" : "Record"),
                              systemImage: model.isRecording ? "stop.fill" : "mic.fill")
                            .frame(minWidth: 96)
                    }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    .tint(model.isRecording ? .red : .accentColor)
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.togglePlayback()
                    } label: {
                        Label(model.isPlaying ? "Stop" : "Play", systemImage: model.isPlaying ? "stop.circle" : "play.circle")
                    }
                    .controlSize(.large)
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!prompt.isRecorded || model.isRecording)

                    Spacer()

                    Button("Next unrecorded") { model.selectNextUnrecorded() }
                        .controlSize(.large)
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                }

                if !model.micAuthorized {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Microphone access is off, so recording won't capture anything.")
                            .font(.callout)
                        Button("Open Settings") { model.openMicrophoneSettings() }
                            .buttonStyle(.link)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }

                Spacer()
            }
            .padding(18)
        } else {
            Text("Select a prompt").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Live input level. The point isn't precision — it's catching a dead or
    /// far-too-quiet input before you record twenty clips of silence.
    private var meter: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .quaternaryLabelColor))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(levelColor)
                        .frame(width: max(2, geometry.size.width * model.level))
                        .animation(.linear(duration: 0.05), value: model.level)
                }
            }
            .frame(height: 8)
            Text(model.isRecording
                 ? "Speak at your normal dictation pace and distance."
                 : "⌘R record · ⌘P play · ⇧⌘N next")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var levelColor: Color {
        if model.level > 0.92 { return .red }        // clipping
        if model.level < 0.18 { return .orange }     // too quiet to score fairly
        return .green
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack {
            Text(model.status.isEmpty
                 ? "Recordings are saved beside their sentence, ready for `make eval`."
                 : model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
