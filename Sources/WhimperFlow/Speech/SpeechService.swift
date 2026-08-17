import Foundation
import Speech
import AVFoundation
import os
import WhimperFlowKit

/// Streaming on-device recognition with automatic session chunking so
/// hands-free dictation can run indefinitely. Audio never leaves the machine:
/// `requiresOnDeviceRecognition` is always true.
final class SpeechService: NSObject {
    struct Config {
        var localeIdentifier: String
        var contextualStrings: [String]
        var addsPunctuation: Bool
        var customLanguageModel: SFSpeechLanguageModel.Configuration?
    }

    enum SpeechError: LocalizedError {
        case localeUnavailable(String)
        case onDeviceUnsupported(String)

        var errorDescription: String? {
            switch self {
            case .localeUnavailable(let id):
                return "Speech recognition is not available for “\(id)”."
            case .onDeviceUnsupported(let id):
                return "On-device recognition for “\(id)” isn’t downloaded. Enable Dictation for this language in System Settings → Keyboard → Dictation."
            }
        }
    }

    // Callbacks fire on the main queue.
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var config: Config?

    /// The request buffers are fed into, and the flags gating that feed.
    ///
    /// `append(buffer:)` runs on the audio thread while rotation and finish
    /// rewrite these on main, so every access goes through `stateLock`.
    /// `os_unfair_lock` is the right primitive here rather than a queue hop:
    /// the critical section is a pointer read, and it participates in priority
    /// inheritance, so the audio thread can't be blocked by a lower-priority
    /// holder. Nothing but the assignments below is ever done while holding it.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var stateLock = os_unfair_lock_s()

    /// The session that has been asked to stop but is still producing results.
    /// Held apart from `task` because `startSession()` overwrites that
    /// immediately, and we still need to be able to cancel this one.
    private var drainingTask: SFSpeechRecognitionTask?
    private var drainingGeneration: Int?
    private var currentGeneration = 0

    /// Text recognized so far this dictation, across chunked sessions.
    /// Guards against the recognizer's empty-final-after-silence behavior.
    private var transcript = TranscriptAccumulator()
    private var secondsInCurrentSession: Double = 0
    private var finishing = false
    private var active = false
    private var watchdogGeneration = 0

    /// Restart the recognition task periodically to stay well inside the
    /// engine's comfort zone for buffer-based requests. Past the soft limit we
    /// wait for a pause in speech so no word is cut mid-utterance; the hard
    /// limit rotates regardless.
    private let softSessionLimitSeconds: Double = 35
    private let hardSessionLimitSeconds: Double = 60
    /// Quiet stretch (via `noteLevel`) treated as a safe rotation point.
    private let rotationSilenceSeconds: Double = 0.4
    private var lastLoudAt = Date()
    /// Adapts to the room rather than trusting a fixed level (see the type).
    private var vad = VoiceActivityDetector()

    func start(config: Config) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: config.localeIdentifier)) else {
            throw SpeechError.localeUnavailable(config.localeIdentifier)
        }
        guard recognizer.isAvailable else {
            throw SpeechError.localeUnavailable(config.localeIdentifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechError.onDeviceUnsupported(config.localeIdentifier)
        }
        self.recognizer = recognizer
        self.config = config
        transcript.reset()
        finishing = false
        active = true
        drainingTask = nil
        drainingGeneration = nil
        lastLoudAt = Date()
        vad.reset()
        startSession()
    }

    /// Normalized mic loudness from the capture engine (main thread); used to
    /// find quiet moments where rotating the session can't clip a word.
    func noteLevel(_ level: Float) {
        if vad.observe(level) { lastLoudAt = Date() }
    }

    /// Point the audio thread at a request, or at nothing. Setting nil is how
    /// every "stop feeding buffers" path works, which is why `append` needs no
    /// other flags: one atomic read decides whether the buffer has a home.
    private func setAudioSink(_ sink: SFSpeechAudioBufferRecognitionRequest?) {
        os_unfair_lock_lock(&stateLock)
        request = sink
        os_unfair_lock_unlock(&stateLock)
    }

    /// Detach the sink and hand it back, so the caller can end it knowing no
    /// further buffer can arrive. Every teardown path goes through here.
    @discardableResult
    private func takeAudioSink() -> SFSpeechAudioBufferRecognitionRequest? {
        os_unfair_lock_lock(&stateLock)
        let previous = request
        request = nil
        os_unfair_lock_unlock(&stateLock)
        return previous
    }

    /// Called from the audio thread.
    func append(buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(&stateLock)
        let sink = request
        sink?.append(buffer)
        os_unfair_lock_unlock(&stateLock)
        guard sink != nil else { return }
        let seconds = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, !self.finishing else { return }
            self.secondsInCurrentSession += seconds
            if self.secondsInCurrentSession >= self.softSessionLimitSeconds {
                let quiet = Date().timeIntervalSince(self.lastLoudAt) >= self.rotationSilenceSeconds
                if quiet || self.secondsInCurrentSession >= self.hardSessionLimitSeconds {
                    self.rotateSession()
                }
            }
        }
    }

    /// Stop feeding audio; `onFinal` fires once the last session settles.
    func finish() {
        guard active else { return }
        finishing = true
        takeAudioSink()?.endAudio()
        armFinishWatchdog(after: 4.0)
    }

    /// Deliver what we have if the recognizer goes quiet (e.g. pure silence).
    /// Re-armed on every result during finish so the final pass — where the
    /// engine retro-corrects earlier words — is never truncated mid-revision.
    private func armFinishWatchdog(after delay: Double) {
        watchdogGeneration += 1
        let generation = watchdogGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.finishing, generation == self.watchdogGeneration else { return }
            self.deliverFinal()
        }
    }

    func cancel() {
        active = false
        finishing = false
        task?.cancel()
        task = nil
        drainingTask?.cancel()
        drainingTask = nil
        drainingGeneration = nil
        takeAudioSink()
        transcript.reset()
    }

    // MARK: - Sessions

    private func startSession() {
        guard let config, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .dictation
        req.addsPunctuation = config.addsPunctuation
        if !config.contextualStrings.isEmpty {
            req.contextualStrings = config.contextualStrings
        }
        if let lm = config.customLanguageModel {
            req.customizedLanguageModel = lm
        }
        currentGeneration += 1
        let generation = currentGeneration
        setAudioSink(req)
        secondsInCurrentSession = 0

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handle(result: result, error: error, generation: generation)
            }
        }
    }

    /// Seamlessly begin a new recognition session mid-dictation.
    ///
    /// The outgoing session is *ended*, not cancelled. Cancelling — what this
    /// did before — destroys the task before it can deliver its final result,
    /// so every chunk boundary threw away both the audio still in flight and
    /// the engine's end-of-session retro-correction, and committed a partial in
    /// their place. Partials are measurably worse than finals. Now the outgoing
    /// session keeps running until it finalizes, holding its slot in the
    /// transcript via `TranscriptAccumulator.draining`, while the new session
    /// takes over the microphone immediately so no audio is dropped between them.
    private func rotateSession() {
        // Only one session can be draining at a time. If the previous one never
        // finalized, settle for its placeholder rather than lose text ordering.
        if drainingGeneration != nil { settleDraining(final: "") }

        transcript.beginDraining()
        drainingTask = task
        drainingGeneration = currentGeneration
        takeAudioSink()?.endAudio()
        armDrainWatchdog(for: currentGeneration)
        startSession()
    }

    /// A rotated-away session gets a bounded window to deliver its final before
    /// we accept its placeholder — otherwise a session that dies quietly would
    /// hold up the transcript until the dictation ends.
    private func armDrainWatchdog(for generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self, self.drainingGeneration == generation else { return }
            self.settleDraining(final: "")
        }
    }

    /// Fold the draining session's result into the transcript and forget it.
    /// An empty `text` keeps the placeholder, per the accumulator's rule.
    private func settleDraining(final text: String) {
        drainingTask?.cancel()
        drainingTask = nil
        drainingGeneration = nil
        transcript.finishDraining(final: text)
        onPartial?(transcript.stitched)
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, generation: Int) {
        guard active else { return }
        if generation == drainingGeneration {
            handleDraining(result: result, error: error)
            return
        }
        // A session we've already moved past; its text is accounted for.
        guard generation == currentGeneration else { return }
        if let result {
            transcript.update(partial: result.bestTranscription.formattedString)
            onPartial?(transcript.stitched)
            if finishing {
                if result.isFinal {
                    deliverFinal()
                    return
                }
                // Still revising; give the final pass a bit more time.
                armFinishWatchdog(after: 1.5)
            }
        }
        if let error {
            if finishing {
                // Whatever went wrong at the end, the stitched text is still
                // the best result we'll get.
                deliverFinal()
            } else {
                let ns = error as NSError
                // "No speech detected" and cancellation are normal outcomes.
                let benign = ns.code == 1110 || ns.code == 203 || ns.code == 216 || ns.code == 301
                if !benign {
                    active = false
                    onError?(error)
                }
            }
        }
    }

    /// Results from the session that rotation asked to stop. Its final replaces
    /// the placeholder standing in for it, in the slot it already holds.
    private func handleDraining(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                settleDraining(final: text)
                return
            }
            transcript.updateDraining(text)
            onPartial?(transcript.stitched)
        }
        // Died before finalizing — the placeholder is the best we'll get.
        if error != nil { settleDraining(final: "") }
    }

    private func deliverFinal() {
        guard active else { return }
        active = false
        finishing = false
        drainingTask?.cancel()
        drainingTask = nil
        drainingGeneration = nil
        // commitAll, not commitPartial: a rotation may still be draining, and
        // its text sits ahead of the running session's in the transcript.
        transcript.commitAll()
        let text = transcript.committed
        task?.cancel()
        task = nil
        takeAudioSink()
        transcript.reset()
        onFinal?(text)
    }
}
