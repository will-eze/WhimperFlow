import AppKit
import SwiftUI
import WhimperFlowKit

/// Home: is it ready, what's left to set up, a place to try it, and the last
/// few dictations with a one-click fix for a misheard word.
struct HomeView: View {
    let context: AppContext
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var historyStore: HistoryStore
    @ObservedObject private var permissions: PermissionsManager
    @ObservedObject private var engineMonitor: EngineMonitor
    @ObservedObject private var controller: DictationController

    @State private var tryText = ""
    @FocusState private var tryFocused: Bool

    init(context: AppContext) {
        self.context = context
        settingsStore = context.settingsStore
        historyStore = context.historyStore
        permissions = context.permissions
        engineMonitor = context.engineMonitor
        controller = context.controller
    }

    private var settings: FlowSettings { settingsStore.settings }

    private var pending: [SetupStep] {
        SetupStep.pending(permissions: permissions, engineMonitor: engineMonitor, settings: settings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                StatusHeader(
                    status: headerStatus,
                    hotkey: settings.hotkeyDisplayName,
                    tapToToggle: settings.tapToToggleEnabled,
                    recheck: { engineMonitor.check() }
                )
                if !pending.isEmpty {
                    SetupChecklist(permissions: permissions, engineMonitor: engineMonitor, settingsStore: settingsStore)
                } else if settings.transcriptionEngine == .server, permissions.speechRecognition != .granted {
                    fallbackOffer
                }
                tryIt
                recent
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Status

    private var headerStatus: StatusHeader.Status {
        if controller.state.isListening { return .listening }
        if !pending.isEmpty { return .setup }
        switch engineMonitor.status {
        case .server: return .ready(engine: "Parakeet on \(engineMonitor.client.baseURL.host?.components(separatedBy: ".").first ?? "server")")
        case .fallbackOnly:
            return settings.transcriptionEngine == .apple ? .ready(engine: "Apple, on this Mac") : .fallback
        case .none: return .unavailable
        }
    }

    private var fallbackOffer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Optional: a backup engine")
                    .font(.body.weight(.medium))
                Text("Allow Speech Recognition and Apple's on-device recogniser types for you whenever the server can't be reached.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Allow") {
                permissions.speechRecognition == .denied
                    ? permissions.openSystemSettings(for: .speechRecognition)
                    : permissions.requestSpeechRecognition()
            }
        }
    }

    // MARK: - Try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Try it").font(.headline)
                Spacer()
                if !tryText.isEmpty {
                    Button("Clear") { tryText = "" }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $tryText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($tryFocused)
                    .padding(8)
                if tryText.isEmpty {
                    Text("Click here, hold \(settings.hotkeyDisplayName) and say something.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tryFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1),
                                  lineWidth: tryFocused ? 2 : 1)
            )
        }
    }

    // MARK: - Recent

    private var recent: some View {
        let records = Array(historyStore.records.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent").font(.headline)
                Spacer()
                if !historyStore.records.isEmpty {
                    Button("All history") { context.router.section = .history }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            if records.isEmpty {
                Text(settings.historyEnabled
                     ? "Your dictations show up here. If one comes out wrong, Fix teaches WhimperFlow the right spelling."
                     : "History is off, so nothing is kept. Turn it on in Settings to fix words from past dictations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        RecentRow(record: record, fix: { context.router.teaching = record })
                    }
                }
                Text(weekLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }

    private var weekLine: String {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let week = historyStore.records.filter { $0.date >= weekAgo }
        let stats = DictationStats.compute(from: week, typingWPMBaseline: settings.typingWPMBaseline)
        guard stats.totalWords > 0 else { return "Nothing dictated in the last 7 days." }
        return "Last 7 days: \(HistoryFormat.grouped(stats.totalWords)) words, about \(HistoryFormat.minutesSaved(stats.minutesSaved)) saved over typing."
    }
}

/// The big line at the top of Home.
struct StatusHeader: View {
    enum Status: Equatable {
        case ready(engine: String)
        case fallback
        case unavailable
        case setup
        case listening
    }

    let status: Status
    let hotkey: String
    let tapToToggle: Bool
    let recheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .padding(.top, 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status == .fallback || status == .unavailable {
                    Button("Check again", action: recheck)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var color: Color {
        switch status {
        case .ready: return .green
        case .fallback: return .orange
        case .unavailable: return .red
        case .setup: return Color.secondary.opacity(0.5)
        case .listening: return .red
        }
    }

    private var title: String {
        switch status {
        case .ready: return "Ready"
        case .fallback: return "Ready, using Apple"
        case .unavailable: return "Can't transcribe right now"
        case .setup: return "Almost ready"
        case .listening: return "Listening…"
        }
    }

    private var holdLine: String {
        tapToToggle
            ? "Hold \(hotkey) and talk, or tap it to talk hands-free."
            : "Hold \(hotkey) and talk."
    }

    private var detail: String {
        switch status {
        case .ready(let engine): return "\(holdLine) Speech goes to \(engine)."
        case .fallback:
            return "The Jarvis server isn't answering (is Tailscale on?), so Apple's recogniser on this Mac types instead. It's less accurate with names and jargon."
        case .unavailable:
            return "The Jarvis server isn't answering and Apple's recogniser isn't allowed. Recordings are kept and transcribed into History when the server is back."
        case .setup: return "Finish the steps below, then \(holdLine.prefix(1).lowercased() + holdLine.dropFirst())"
        case .listening: return "Release \(hotkey) when you're done. Esc cancels."
        }
    }
}

/// One past dictation with copy and fix.
struct RecentRow: View {
    let record: DictationRecord
    let fix: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.processedText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text([record.appName, HistoryFormat.relativeDate(record.date)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.processedText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .controlSize(.small)
            Button("Fix a word…", action: fix)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
    }
}
