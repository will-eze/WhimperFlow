import AppKit
import Combine
import WhimperFlowKit

enum DictationState: Equatable {
    case idle
    case listening(handsFree: Bool)
    case processing
    case error(String)

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

/// The state machine at the center of the app: hotkey → audio → recognition →
/// deterministic processing → injection → history.
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var partialTranscript = ""
    /// The Apple fallback produced some of the current (or last) dictation's text.
    @Published private(set) var usedFallback = false

    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let permissions: PermissionsManager
    private let audio = AudioCaptureEngine()
    private let speech = SpeechService()
    private let chunked = ChunkedDictation()
    private let engineMonitor: EngineMonitor
    private let unsent = UnsentRecordings()
    /// The engine the running dictation uses (fixed at its start).
    private var activeEngine: TranscriptionEngine = .server
    private let customLM = CustomLanguageModelStore()
    private let injector = TextInjector()
    private let sounds = SoundCues()
    private var cancellables: Set<AnyCancellable> = []

    /// Last injected text per app, for "scratch that" and spacing fallback.
    private struct InjectionMemory {
        var text: String
        var bundleID: String?
        var date: Date
    }
    private var lastInjection: InjectionMemory?

    private var sessionStart: Date?
    private var targetApp: NSRunningApplication?
    private var silenceTimer: Timer?
    private var lastVoiceActivity = Date()
    /// Hands-free auto-stop reads voice activity relative to the room's noise
    /// floor; a fixed threshold silently stopped quiet mics mid-sentence.
    private var vad = VoiceActivityDetector()
    private var keyDownAt: Date?

    /// Below the hold threshold a key press is a "tap" (toggles hands-free).
    private let tapThreshold: TimeInterval = 0.35

    init(settingsStore: SettingsStore, historyStore: HistoryStore, permissions: PermissionsManager,
         engineMonitor: EngineMonitor) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.permissions = permissions
        self.engineMonitor = engineMonitor

        // Audio thread: the buffer goes to whichever engine this dictation uses.
        // Both ignore buffers when they aren't running.
        let speech = speech, chunked = chunked
        audio.onBuffer = { buffer in
            speech.append(buffer: buffer)
            chunked.append(buffer: buffer)
        }
        audio.onLevel = { [weak self] level in
            guard let self else { return }
            self.audioLevel = level
            self.speech.noteLevel(level)
            if self.vad.observe(level) { self.lastVoiceActivity = Date() }
        }
        speech.onPartial = { [weak self] text in
            self?.partialTranscript = text
        }
        speech.onFinal = { [weak self] text in
            self?.handleFinalTranscript(text)
        }
        chunked.onPartial = { [weak self] text in
            self?.partialTranscript = text
        }
        chunked.onFallback = { [weak self] in
            self?.usedFallback = true
        }
        chunked.onServerFailure = { [weak self] in
            self?.engineMonitor.noteServerFailure()
        }
        chunked.onFinal = { [weak self] outcome in
            self?.handleChunkedOutcome(outcome)
        }
        // Also fires on the first successful check after launch.
        engineMonitor.onServerBack = { [weak self] in
            self?.retryUnsent()
        }

        speech.onError = { [weak self] error in
            // A near-full disk crashes localspeechrecognitiond outright: it
            // preallocates a ~180 MB compiled-model cache under /var/folders
            // before any audio is processed, so every session dies at start
            // with an opaque XPC error. Name the real cause when it applies.
            var message = error.localizedDescription
            if let free = try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
               free < 2_000_000_000 {
                message += " Your disk is nearly full — on-device recognition needs temporary space to start."
            }
            self?.fail(message)
        }

        // Keep the custom language model in sync with the user's vocabulary
        // (the store hashes and no-ops when nothing relevant changed). Only the
        // Apple-only engine uses it: the server path's fallback is file-based,
        // which ignores custom models, so compiling one at launch would be waste.
        settingsStore.$settings
            .removeDuplicates()
            .sink { [weak self] settings in
                guard settings.transcriptionEngine == .apple else { return }
                self?.customLM.rebuildIfNeeded(settings: settings)
            }
            .store(in: &cancellables)
    }

    // MARK: - Hotkey entry points

    func hotkeyDown() {
        keyDownAt = Date()
        switch state {
        case .idle, .error:
            begin(handsFree: false)
        case .listening(handsFree: true):
            // Pressing the key while hands-free stops and injects.
            finishAndInject()
        default:
            break
        }
    }

    func hotkeyUp() {
        let heldFor = keyDownAt.map { Date().timeIntervalSince($0) } ?? .infinity
        keyDownAt = nil
        guard case .listening(let handsFree) = state, !handsFree else { return }
        if heldFor < tapThreshold, settingsStore.settings.tapToToggleEnabled {
            // Quick tap: convert this session to hands-free.
            state = .listening(handsFree: true)
            startSilenceWatchdog()
        } else {
            finishAndInject()
        }
    }

    /// Escape pressed. Returns true (swallow the key) when a session was live.
    func escapePressed() -> Bool {
        switch state {
        case .listening, .processing:
            cancel()
            return true
        default:
            return false
        }
    }

    /// ⌃⌥V: types the last dictation again at the cursor, for when it landed
    /// in the wrong place. Leading space dropped; the cursor decides spacing.
    func reinsertLast() {
        guard state == .idle,
              let text = (lastInjection?.text ?? historyStore.records.first?.processedText)?
                .trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return }
        injector.inject(text, method: settingsStore.settings.injectionMethod)
    }

    func toggleFromMenu() {
        switch state {
        case .idle, .error:
            begin(handsFree: true)
        case .listening:
            finishAndInject()
        default:
            break
        }
    }

    // MARK: - Session lifecycle

    private func begin(handsFree: Bool) {
        // Re-read rather than trusting the last snapshot: the user may have
        // granted (or revoked) since launch, and macOS never tells us.
        permissions.refresh()
        let settings = settingsStore.settings
        let engine = settings.transcriptionEngine
        // The server engine needs only the microphone; Speech Recognition is for
        // its fallback, which fails per chunk (keeping the audio) without it.
        let missing = [
            permissions.microphone == .granted ? nil : "Microphone",
            engine == .server || permissions.speechRecognition == .granted ? nil : "Speech Recognition",
        ].compactMap { $0 }
        guard missing.isEmpty else {
            fail("\(missing.joined(separator: " and ")) access isn't granted — open Settings › Permissions.")
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        guard settings.isEnabled(forBundleID: targetApp?.bundleIdentifier) else {
            return // dictation disabled for this app
        }

        partialTranscript = ""
        usedFallback = false
        activeEngine = engine
        sessionStart = Date()
        lastVoiceActivity = Date()
        // Re-learn the room each dictation: the mic or the surroundings may
        // have changed since the last one.
        vad.reset()

        do {
            switch engine {
            case .server:
                let fallback = AppleBackend(
                    localeIdentifier: settings.localeIdentifier,
                    contextualStrings: settings.contextualStrings(),
                    addsPunctuation: settings.autoPunctuate
                )
                // Server known down: don't make every chunk wait out a timeout.
                let primary = engineMonitor.serverReachable ? ServerBackend(client: engineMonitor.client) : nil
                chunked.start(primary: primary, fallback: fallback)
                engineMonitor.check() // warms the connection while the user talks
            case .apple:
                try speech.start(config: .init(
                    localeIdentifier: settings.localeIdentifier,
                    contextualStrings: settings.contextualStrings(),
                    addsPunctuation: settings.autoPunctuate,
                    customLanguageModel: customLM.configuration
                ))
            }
            try audio.start(deviceUID: settings.microphoneUID, voiceProcessing: settings.voiceProcessingEnabled)
        } catch {
            speech.cancel()
            chunked.cancel()
            audio.stop()
            fail(error.localizedDescription)
            return
        }

        state = .listening(handsFree: handsFree)
        if settings.playSounds { sounds.play(.begin) }
        if handsFree { startSilenceWatchdog() }
    }

    private func finishAndInject() {
        guard state.isListening else { return }
        stopSilenceWatchdog()
        audio.stop()
        state = .processing
        if settingsStore.settings.playSounds { sounds.play(.end) }
        switch activeEngine {
        case .server: chunked.finish()
        case .apple: speech.finish()
        }
    }

    func cancel() {
        stopSilenceWatchdog()
        audio.stop()
        speech.cancel()
        chunked.cancel()
        partialTranscript = ""
        audioLevel = 0
        state = .idle
        if settingsStore.settings.playSounds { sounds.play(.cancel) }
    }

    private func fail(_ message: String) {
        stopSilenceWatchdog()
        audio.stop()
        speech.cancel()
        chunked.cancel()
        audioLevel = 0
        state = .error(message)
        sounds.play(.cancel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if case .error = self?.state { self?.state = .idle }
        }
    }

    // MARK: - Result handling

    /// The server engine's result. Whatever was recognised is typed; if any
    /// chunk failed on both engines, the whole recording is also kept and
    /// transcribed into History once the server is back.
    private func handleChunkedOutcome(_ outcome: ChunkedDictation.Outcome) {
        guard state == .processing else { return }
        if outcome.failedChunks > 0 {
            unsent.save(outcome.samples, appName: targetApp?.localizedName)
            if outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fail("No engine could transcribe that. The recording is saved and will appear in History once the server is back.")
                return
            }
        }
        handleFinalTranscript(outcome.text)
    }

    private func retryUnsent() {
        unsent.retry(client: engineMonitor.client, settings: settingsStore.settings, history: historyStore)
    }

    private func handleFinalTranscript(_ raw: String) {
        defer {
            partialTranscript = ""
            audioLevel = 0
        }
        let settings = settingsStore.settings
        let bundleID = targetApp?.bundleIdentifier

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            return
        }

        let context = ProcessingContext(
            mode: settings.mode(forBundleID: bundleID),
            precedingText: precedingText(for: bundleID)
        )
        let processor = TranscriptProcessor(settings: settings)
        let result = processor.process(trimmed, context: context)

        if let command = result.command {
            perform(command)
            state = .idle
            return
        }

        guard !result.text.isEmpty else {
            state = .idle
            return
        }

        injector.inject(result.text, method: settings.injectionMethod)
        lastInjection = InjectionMemory(text: result.text, bundleID: bundleID, date: Date())

        if settings.historyEnabled {
            let duration = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
            historyStore.add(DictationRecord(
                date: Date(),
                appBundleID: bundleID,
                appName: targetApp?.localizedName,
                rawText: trimmed,
                processedText: result.text.trimmingCharacters(in: .whitespaces),
                durationSeconds: duration
            ))
        }
        if settings.playSounds { sounds.play(.success) }
        state = .idle
    }

    private func perform(_ command: EditCommand) {
        switch command {
        case .scratchThat:
            guard let memory = lastInjection,
                  memory.bundleID == targetApp?.bundleIdentifier,
                  Date().timeIntervalSince(memory.date) < 120 else { return }
            injector.deleteBackward(count: memory.text.count)
            lastInjection = nil
        case .pressReturn:
            injector.press(.returnKey)
        case .pressTab:
            injector.press(.tab)
        case .undo:
            let source = CGEventSource(stateID: .combinedSessionState)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: false) {
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Best available knowledge of the text before the cursor: live from the
    /// Accessibility API, else our own recent injection into the same app.
    private func precedingText(for bundleID: String?) -> String? {
        if let ax = AXContextReader.precedingText() {
            return ax
        }
        if let memory = lastInjection, memory.bundleID == bundleID,
           Date().timeIntervalSince(memory.date) < 60 {
            return memory.text
        }
        return nil
    }

    // MARK: - Hands-free silence auto-stop

    private func startSilenceWatchdog() {
        stopSilenceWatchdog()
        let limit = settingsStore.settings.silenceAutoStopSeconds
        guard limit > 0 else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, case .listening(handsFree: true) = self.state else { return }
                if Date().timeIntervalSince(self.lastVoiceActivity) > limit {
                    self.finishAndInject()
                }
            }
        }
    }

    private func stopSilenceWatchdog() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}
