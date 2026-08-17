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

    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let permissions: PermissionsManager
    private let audio = AudioCaptureEngine()
    private let speech = SpeechService()
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

    init(settingsStore: SettingsStore, historyStore: HistoryStore, permissions: PermissionsManager) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.permissions = permissions

        audio.onBuffer = { [weak self] buffer in
            self?.speech.append(buffer: buffer)
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
        // (the store hashes and no-ops when nothing relevant changed).
        customLM.rebuildIfNeeded(settings: settingsStore.settings)
        settingsStore.$settings
            .removeDuplicates()
            .sink { [weak self] settings in
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
        let missing = [
            permissions.microphone == .granted ? nil : "Microphone",
            permissions.speechRecognition == .granted ? nil : "Speech Recognition",
        ].compactMap { $0 }
        guard missing.isEmpty else {
            fail("\(missing.joined(separator: " and ")) access isn't granted — open Settings › Permissions.")
            return
        }
        let settings = settingsStore.settings
        targetApp = NSWorkspace.shared.frontmostApplication
        guard settings.isEnabled(forBundleID: targetApp?.bundleIdentifier) else {
            return // dictation disabled for this app
        }

        partialTranscript = ""
        sessionStart = Date()
        lastVoiceActivity = Date()
        // Re-learn the room each dictation: the mic or the surroundings may
        // have changed since the last one.
        vad.reset()

        do {
            try speech.start(config: .init(
                localeIdentifier: settings.localeIdentifier,
                contextualStrings: settings.contextualStrings(),
                addsPunctuation: settings.autoPunctuate,
                customLanguageModel: customLM.configuration
            ))
            try audio.start(deviceUID: settings.microphoneUID, voiceProcessing: settings.voiceProcessingEnabled)
        } catch {
            speech.cancel()
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
        speech.finish()
    }

    func cancel() {
        stopSilenceWatchdog()
        audio.stop()
        speech.cancel()
        partialTranscript = ""
        audioLevel = 0
        state = .idle
        if settingsStore.settings.playSounds { sounds.play(.cancel) }
    }

    private func fail(_ message: String) {
        stopSilenceWatchdog()
        audio.stop()
        speech.cancel()
        audioLevel = 0
        state = .error(message)
        sounds.play(.cancel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if case .error = self?.state { self?.state = .idle }
        }
    }

    // MARK: - Result handling

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
