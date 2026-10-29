import Foundation
import Speech
import AVFoundation
import CryptoKit
import WhimperFlowKit
import AudioSupport

// Offline accuracy harness: feed recorded clips through the same on-device
// recognizer and the same deterministic pipeline the app uses, and report WER.
// Nothing here touches the network; `requiresOnDeviceRecognition` is always true.

// MARK: - Arguments

struct Options {
    var clipsDirectory = URL(fileURLWithPath: "Eval/clips", isDirectory: true)
    var localeOverride: String?
    var settingsDirectory: URL?
    var useCustomLanguageModel = true
    var verbose = false
    /// Replay clips through the streaming buffer API the app actually uses,
    /// instead of the file-based one. The two are not equivalent: the custom
    /// language model is ignored by the file-based request.
    var streaming = false
    /// Where to write the report. Needed when launched from a bundle via
    /// LaunchServices, which gives the process no usable stdout.
    var outputFile: URL?
    /// Append per-session streaming events here (session starts, rotations,
    /// isFinal arrivals with timing). For diagnosing why a clip truncates.
    var debugLog: URL?
    /// Score pre-recognised text instead of running a recogniser: a JSONL file of
    /// `{"clip": name, "text": raw}` lines (e.g. Parakeet output from the server
    /// bench). The text still goes through `TranscriptProcessor`.
    var hypotheses: URL?
    /// Write each clip's raw text here as `{"clip","text"}` JSONL, ready for
    /// `--hypotheses` (e.g. to score a post-correction step offline).
    var dumpFile: URL?
    /// `--correct`: run each server chunk through the misheard-word fixer, as
    /// the app does, with the vocabulary from the settings in use.
    var correct = false
    /// `apple` (default) or `server`: send each clip to the dictation server the
    /// way the app does (16 kHz mono, cut at pauses) and score what comes back.
    var backend = "apple"
    var serverURL: URL?
    var chunking = ChunkPlanner.Config()
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--clips":
            guard let value = args.first else { fail("--clips needs a directory") }
            args.removeFirst()
            options.clipsDirectory = URL(fileURLWithPath: value, isDirectory: true)
        case "--locale":
            guard let value = args.first else { fail("--locale needs an identifier, e.g. en-GB") }
            args.removeFirst()
            options.localeOverride = value
        case "--settings-dir":
            guard let value = args.first else { fail("--settings-dir needs a directory") }
            args.removeFirst()
            options.settingsDirectory = URL(fileURLWithPath: value, isDirectory: true)
        case "--out":
            guard let value = args.first else { fail("--out needs a file path") }
            args.removeFirst()
            options.outputFile = URL(fileURLWithPath: value)
            reportFile = options.outputFile
        case "--streaming":
            options.streaming = true
        case "--debug-log":
            guard let value = args.first else { fail("--debug-log needs a file path") }
            args.removeFirst()
            options.debugLog = URL(fileURLWithPath: value)
        case "--hypotheses":
            guard let value = args.first else { fail("--hypotheses needs a JSONL file") }
            args.removeFirst()
            options.hypotheses = URL(fileURLWithPath: value)
        case "--backend":
            guard let value = args.first, ["apple", "server"].contains(value) else { fail("--backend needs apple or server") }
            args.removeFirst()
            options.backend = value
        case "--server":
            guard let value = args.first, let url = URL(string: value) else { fail("--server needs a URL") }
            args.removeFirst()
            options.serverURL = url
        case "--chunk-min", "--chunk-max":
            guard let value = args.first, let seconds = Double(value), seconds > 0 else { fail("\(arg) needs seconds") }
            args.removeFirst()
            if arg == "--chunk-min" { options.chunking.minSeconds = seconds } else { options.chunking.maxSeconds = seconds }
        case "--no-lm":
            options.useCustomLanguageModel = false
        case "--correct":
            options.correct = true
        case "--dump":
            guard let value = args.first else { fail("--dump needs a file path") }
            args.removeFirst()
            options.dumpFile = URL(fileURLWithPath: value)
        case "--verbose", "-v":
            options.verbose = true
        case "--help", "-h":
            print("""
            whimpereval — offline WER harness for WhimperFlow

              --clips <dir>          directory of clips (default: Eval/clips)
              --locale <id>          override the recognizer locale from settings.json
              --settings-dir <dir>   read settings.json from here instead of
                                     Application Support/WhimperFlow
              --streaming            replay clips through the buffer API the app
                                     uses, rather than the file-based API
              --no-lm                skip the custom language model (measures its effect)
              --correct              (server) also run the misheard-word fixer per chunk
              --dump <jsonl>         append each clip's raw text as {"clip","text"}
              --hypotheses <jsonl>   score pre-recognised text ({"clip","text"} per
                                     line) through the pipeline; no recogniser runs
              --backend server       recognise on the dictation server, chunked as
                                     the app does; also reports the wait after release
              --server <url>         server for --backend server (default: the URL
                                     in settings.json)
              --chunk-min/--chunk-max <s>  chunk cut limits for --backend server
              --verbose              print a word-level diff for every clip
              --out <file>           also write the report here (used when the
                                     tool runs from its app bundle, where stdout
                                     goes nowhere)

            Each clip is an audio file (.wav/.m4a/.aiff/.caf/.mp3) with a sibling
            .txt file of the same name holding the reference text.

            Run it via `make eval`, which launches the bundled copy. An unbundled
            process does not own the client identifier that
            prepareCustomLanguageModel binds to, so the custom language model has
            no effect there and only the text pipeline gets measured.
            """)
            exit(0)
        default:
            fail("unknown argument: \(arg)")
        }
    }
    return options
}

/// Set as soon as `--out` is parsed, so an early exit still leaves a readable
/// reason behind. A bundled run has no stderr the caller can see.
var reportFile: URL?

/// Optional streaming-diagnostics sink (`--debug-log`). A bundled run has no
/// stdout/stderr the caller sees, so events go to a file instead.
let streamDebugLock = NSLock()
var streamDebugLog: URL?
func streamDebug(_ clip: String, _ message: String) {
    guard let streamDebugLog else { return }
    streamDebugLock.lock(); defer { streamDebugLock.unlock() }
    let line = "\(clip)\t\(message)\n"
    if let handle = try? FileHandle(forWritingTo: streamDebugLog) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: streamDebugLog, atomically: true, encoding: .utf8)
    }
}

func fail(_ message: String) -> Never {
    let text = "whimpereval: " + message + "\n"
    FileHandle.standardError.write(Data(text.utf8))
    if let reportFile {
        try? text.write(to: reportFile, atomically: true, encoding: .utf8)
    }
    exit(1)
}

/// The identity `prepareCustomLanguageModel` binds a compiled model to. An
/// unbundled process owns none, which is exactly why the custom language model
/// used to have no measurable effect here: it was silently ignored. Running
/// from `whimpereval.app` gives the harness a real identity and makes the LM's
/// recognition biasing observable.
let clientIdentifier = Bundle.main.bundleIdentifier
let isBundled = clientIdentifier != nil

// MARK: - Clip discovery

struct Clip {
    var name: String
    var audio: URL
    var reference: String
}

let audioExtensions: Set<String> = ["wav", "m4a", "aiff", "aif", "caf", "mp3", "flac"]

func loadClips(in directory: URL) -> [Clip] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    ) else {
        fail("can't read clips directory \(directory.path) — see Eval/README.md")
    }

    var clips: [Clip] = []
    for audio in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where audioExtensions.contains(audio.pathExtension.lowercased()) {
        let referenceURL = audio.deletingPathExtension().appendingPathExtension("txt")
        guard let text = try? String(contentsOf: referenceURL, encoding: .utf8) else {
            FileHandle.standardError.write(Data("skipping \(audio.lastPathComponent): no reference \(referenceURL.lastPathComponent)\n".utf8))
            continue
        }
        clips.append(Clip(
            name: audio.deletingPathExtension().lastPathComponent,
            audio: audio,
            reference: text.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }
    return clips
}

// MARK: - Recognition

func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
}

func recognize(
    audio: URL,
    recognizer: SFSpeechRecognizer,
    addsPunctuation: Bool,
    languageModel: SFSpeechLanguageModel.Configuration?
) async throws -> String {
    let request = SFSpeechURLRecognitionRequest(url: audio)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    request.taskHint = .dictation
    request.addsPunctuation = addsPunctuation
    if let languageModel {
        request.customizedLanguageModel = languageModel
    }

    return try await withCheckedThrowingContinuation { continuation in
        // The task callback can fire more than once; resume exactly once.
        let settled = Settled()
        recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                if settled.claim() {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            } else if let error {
                if settled.claim() { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Replays a clip through the streaming recognizer *the way `SpeechService`
/// drives it* — including the 35s/60s session rotation the app performs so a
/// long dictation stays inside the recognizer's single-session comfort zone.
///
/// This matters because a single un-rotated `SFSpeechAudioBufferRecognitionRequest`
/// truncates badly once a clip runs much past a minute, or once the recognizer
/// endpoints early on an inter-sentence pause — losing most of the utterance.
/// The app defends against exactly that by chunking sessions; a harness that
/// doesn't rotate measures a failure mode the app doesn't have. So the scored
/// text is what the app would actually have injected, not an artifact of feeding
/// the whole clip to one session.
func recognizeStreaming(
    name: String,
    audio: URL,
    recognizer: SFSpeechRecognizer,
    addsPunctuation: Bool,
    languageModel: SFSpeechLanguageModel.Configuration?
) async throws -> String {
    let file = try AVAudioFile(forReading: audio)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0, let clip = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "whimpereval", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "couldn't buffer \(audio.lastPathComponent)"
        ])
    }
    try file.read(into: clip)
    clip.frameLength = frameCount

    let session = RotatingStreamSession(
        name: name,
        recognizer: recognizer,
        addsPunctuation: addsPunctuation,
        languageModel: languageModel
    )
    return try await session.run(clip: clip, format: format, frameCount: frameCount)
}

/// Mirrors `SpeechService`'s session handling closely enough to measure it:
/// a real-time buffer feed, silence-aware rotation past a soft limit (and a hard
/// limit regardless), a draining slot so a rotated-away session's final result
/// supersedes its placeholder, and the empty-final guard — all via the real
/// `TranscriptAccumulator`. There is no live microphone here; the clip is the
/// whole input, so `finish()` runs once its audio is exhausted rather than on a
/// hotkey release. Thresholds are kept identical to `SpeechService`.
///
/// A mid-dictation `isFinal` from a still-running session is deliberately *not*
/// treated as the end of the dictation (the old harness bailed on the first one,
/// discarding the rest of the clip). The app ignores it too and waits for
/// rotation; replicating that is the point of this harness.
final class RotatingStreamSession: @unchecked Sendable {
    private let name: String
    private let recognizer: SFSpeechRecognizer
    private let addsPunctuation: Bool
    private let languageModel: SFSpeechLanguageModel.Configuration?
    /// Wall clock the feed started, for elapsed-time diagnostics.
    private var startedAt = Date()
    /// All state below is touched only on this serial queue — the harness's
    /// stand-in for `SpeechService`'s main-queue/`stateLock` discipline.
    private let queue = DispatchQueue(label: "com.whimperflow.eval.stream")

    private let softSessionLimitSeconds: Double = 35
    private let hardSessionLimitSeconds: Double = 60
    private let rotationSilenceSeconds: Double = 0.4

    private var transcript = TranscriptAccumulator()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var currentGeneration = 0
    private var drainingTask: SFSpeechRecognitionTask?
    private var drainingGeneration: Int?
    private var secondsInCurrentSession: Double = 0
    private var finishing = false
    private var active = false
    private var vad = VoiceActivityDetector()
    private var lastLoudAt = Date()
    private var watchdogGeneration = 0

    private var continuation: CheckedContinuation<String, Error>?
    private var completed = false

    /// Last word count logged for the running / draining sessions, so the debug
    /// log records only when a partial actually grows rather than every callback.
    private var lastRunningWords = -1
    private var lastDrainWords = -1

    init(name: String,
         recognizer: SFSpeechRecognizer,
         addsPunctuation: Bool,
         languageModel: SFSpeechLanguageModel.Configuration?) {
        self.name = name
        self.recognizer = recognizer
        self.addsPunctuation = addsPunctuation
        self.languageModel = languageModel
    }

    /// Seconds since the feed began, to two decimals — for the debug log.
    private var elapsed: String { String(format: "%.2fs", Date().timeIntervalSince(startedAt)) }

    func run(clip: AVAudioPCMBuffer, format: AVAudioFormat, frameCount: AVAudioFrameCount) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.active = true
                self.startedAt = Date()
                self.lastLoudAt = Date()
                self.startSession()
            }
            // Feed in real time: pacing drives the recognizer's endpointing, and
            // the wall-clock quiet check the rotation decision relies on.
            DispatchQueue.global().async {
                let chunk = AVAudioFrameCount(format.sampleRate * 0.1)
                let channels = Int(format.channelCount)
                var offset: AVAudioFrameCount = 0
                while offset < frameCount {
                    let length = min(chunk, frameCount - offset)
                    if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
                       let source = clip.floatChannelData, let destination = buffer.floatChannelData {
                        buffer.frameLength = length
                        for channel in 0..<channels {
                            destination[channel].update(from: source[channel] + Int(offset), count: Int(length))
                        }
                        let level = Self.level(of: buffer)
                        self.queue.async { self.append(buffer: buffer, level: level) }
                    }
                    offset += length
                    Thread.sleep(forTimeInterval: 0.1)
                }
                self.queue.async { self.finish() }
            }
        }
    }

    // MARK: - Feed

    private func append(buffer: AVAudioPCMBuffer, level: Float) {
        guard active, !finishing, let request else { return }
        request.append(buffer)
        if vad.observe(level) { lastLoudAt = Date() }
        secondsInCurrentSession += Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        if secondsInCurrentSession >= softSessionLimitSeconds {
            let quiet = Date().timeIntervalSince(lastLoudAt) >= rotationSilenceSeconds
            if quiet {
                rotateSession(reason: "soft-quiet")
            } else if secondsInCurrentSession >= hardSessionLimitSeconds {
                rotateSession(reason: "hard")
            }
        }
    }

    private func finish() {
        guard active, !finishing else { return }
        finishing = true
        streamDebug(name, "\(elapsed) finish (audio exhausted) gen=\(currentGeneration) sessionSecs=\(String(format: "%.1f", secondsInCurrentSession))")
        request?.endAudio()
        request = nil
        armFinishWatchdog(after: 4.0)
    }

    // MARK: - Sessions

    private func startSession() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .dictation
        req.addsPunctuation = addsPunctuation
        if let languageModel { req.customizedLanguageModel = languageModel }
        currentGeneration += 1
        let generation = currentGeneration
        request = req
        secondsInCurrentSession = 0
        lastRunningWords = -1
        streamDebug(name, "\(elapsed) startSession gen=\(generation)")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.queue.async { self?.handle(result: result, error: error, generation: generation) }
        }
    }

    private func rotateSession(reason: String) {
        streamDebug(name, "\(elapsed) rotate gen=\(currentGeneration) reason=\(reason) sessionSecs=\(String(format: "%.1f", secondsInCurrentSession)) partialWords=\(transcript.partial.split(separator: " ").count)")
        if drainingGeneration != nil { settleDraining(final: "") }
        transcript.beginDraining()
        lastDrainWords = -1
        drainingTask = task
        drainingGeneration = currentGeneration
        request?.endAudio()
        request = nil
        armDrainWatchdog(for: currentGeneration)
        startSession()
    }

    private func armDrainWatchdog(for generation: Int) {
        queue.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self, self.drainingGeneration == generation else { return }
            streamDebug(self.name, "\(self.elapsed) drain-watchdog fired gen=\(generation)")
            self.settleDraining(final: "")
        }
    }

    private func settleDraining(final text: String) {
        let placeholder = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        streamDebug(name, "\(elapsed) settleDraining placeholder=\(placeholder) finalWords=\(text.split(separator: " ").count) drainWords=\(transcript.draining.split(separator: " ").count)")
        drainingTask?.cancel()
        drainingTask = nil
        drainingGeneration = nil
        transcript.finishDraining(final: text)
        streamDebug(name, "\(elapsed) committed now words=\(transcript.committed.split(separator: " ").count)")
    }

    private func armFinishWatchdog(after delay: Double) {
        watchdogGeneration += 1
        let generation = watchdogGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.finishing, generation == self.watchdogGeneration else { return }
            self.deliverFinal()
        }
    }

    // MARK: - Results

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, generation: Int) {
        guard active else { return }
        if generation == drainingGeneration {
            handleDraining(result: result, error: error)
            return
        }
        guard generation == currentGeneration else { return }
        if let result {
            let words = result.bestTranscription.formattedString.split(separator: " ").count
            if result.isFinal {
                streamDebug(name, "\(elapsed) isFinal gen=\(generation) finishing=\(finishing) words=\(words)")
            } else if words != lastRunningWords {
                streamDebug(name, "\(elapsed) partial gen=\(generation) words=\(words)")
                lastRunningWords = words
            }
            transcript.update(partial: result.bestTranscription.formattedString)
            if finishing {
                if result.isFinal { deliverFinal(); return }
                armFinishWatchdog(after: 1.5)
            }
        }
        if let error {
            if finishing {
                deliverFinal()
            } else {
                let ns = error as NSError
                let benign = ns.code == 1110 || ns.code == 203 || ns.code == 216 || ns.code == 301
                if !benign { fail(error) }
            }
        }
    }

    private func handleDraining(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let words = text.split(separator: " ").count
            if result.isFinal {
                streamDebug(name, "\(elapsed) drain-final gen=\(drainingGeneration ?? -1) words=\(words)")
                settleDraining(final: text); return
            }
            if words != lastDrainWords {
                streamDebug(name, "\(elapsed) drain-partial words=\(words)")
                lastDrainWords = words
            }
            transcript.updateDraining(text)
        }
        if let error {
            streamDebug(name, "\(elapsed) drain-error \((error as NSError).code) settling placeholder")
            settleDraining(final: "")
        }
    }

    private func deliverFinal() {
        guard active else { return }
        active = false
        finishing = false
        drainingTask?.cancel()
        drainingTask = nil
        drainingGeneration = nil
        transcript.commitAll()
        let text = transcript.committed
        streamDebug(name, "\(elapsed) deliverFinal words=\(text.split(separator: " ").count)")
        streamDebug(name, "\(elapsed) deliverFinal text=\(text.prefix(400))")
        task?.cancel()
        task = nil
        request = nil
        finishCompletion(.success(text))
    }

    private func fail(_ error: Error) {
        active = false
        task?.cancel(); task = nil
        drainingTask?.cancel(); drainingTask = nil
        request = nil
        finishCompletion(.failure(error))
    }

    private func finishCompletion(_ result: Result<String, Error>) {
        guard !completed else { return }
        completed = true
        continuation?.resume(with: result)
        continuation = nil
    }

    /// RMS of channel 0 — a linear loudness the `VoiceActivityDetector` can adapt
    /// to, standing in for the normalized level the app feeds it from the mic.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        return (sum / Float(count)).squareRoot()
    }
}

final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Custom language model

/// Compiles the same phrase set the app teaches the recognizer, cached by
/// content hash in its own directory so eval runs never disturb the app's.
func prepareLanguageModel(settings: FlowSettings, locale: Locale) async -> SFSpeechLanguageModel.Configuration? {
    let phrases = CustomVocabulary.phrases(from: settings)
    guard !phrases.isEmpty else { return nil }

    // The client identifier is part of the cache key: a model compiled for one
    // identity is useless under another, and reusing it would silently measure
    // a model that isn't actually attached.
    let identity = clientIdentifier ?? "unbundled"
    let joined = identity + "\u{1}" + locale.identifier + "\u{1}" + phrases.joined(separator: "\u{1}")
    let digest = SHA256.hash(data: Data(joined.utf8))
    let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

    let directory = await MainActor.run { SettingsStore.defaultDirectory() }
        .appendingPathComponent("customlm-eval", isDirectory: true)
    let modelURL = directory.appendingPathComponent("model-\(hash).lm")
    let configuration = SFSpeechLanguageModel.Configuration(languageModel: modelURL)
    if FileManager.default.fileExists(atPath: modelURL.path) { return configuration }

    // Compiling the model fails intermittently ("Failed to initialize language
    // model", kLSRErrorDomain 400) with input that succeeds on a later attempt,
    // so retry before giving up — silently running without the model would
    // remove the single biggest recognition-accuracy lever.
    var lastError: Error?
    for attempt in 1...3 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let assetURL = directory.appendingPathComponent("asset-\(hash).bin")
            let data = SFCustomLanguageModelData(locale: locale, identifier: identity + ".lm", version: hash)
            for phrase in phrases {
                data.insert(phraseCount: .init(phrase: phrase, count: 10))
            }
            try await data.export(to: assetURL)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                SFSpeechLanguageModel.prepareCustomLanguageModel(
                    for: assetURL,
                    clientIdentifier: identity,
                    configuration: configuration
                ) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            try? FileManager.default.removeItem(at: assetURL)
            if attempt > 1 {
                FileHandle.standardError.write(Data("custom language model built on attempt \(attempt)\n".utf8))
            }
            return configuration
        } catch {
            lastError = error
            // Don't leave a partial .lm behind: the cache check above only
            // tests for existence, so it would be mistaken for a good model.
            try? FileManager.default.removeItem(at: modelURL)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("asset-\(hash).bin"))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
    FileHandle.standardError.write(Data("custom language model unavailable after 3 attempts (\(lastError.map { "\($0)" } ?? "unknown")); continuing without it\n".utf8))
    return nil
}

// MARK: - Other text sources

enum EvalError: LocalizedError {
    case noHypothesis
    var errorDescription: String? { "no hypothesis for this clip" }
}

var serverModel = "?"

func loadHypotheses(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { fail("can't read \(url.path)") }
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let clip = object["clip"] as? String, let hyp = object["text"] as? String else {
            fail("bad hypotheses line: \(line.prefix(80))")
        }
        out[clip] = hyp
    }
    return out
}

/// The app's server path, minus the microphone: 16 kHz mono, fed to the chunk
/// planner in 0.1 s buffers, every chunk but the last sent "while talking", and
/// the last one timed. That last round trip is the wait after letting go.
func recognizeOnServer(audio: URL, client: DictationServerClient, chunking: ChunkPlanner.Config,
                       vocabulary: [String] = [])
    async throws -> (text: String, afterRelease: Double, chunks: Int) {
    let samples = try MonoResampler.samples(of: audio)
    var planner = ChunkPlanner(config: chunking)
    var chunks: [ChunkPlanner.Chunk] = []
    var offset = 0
    while offset < samples.count {
        let end = min(samples.count, offset + 1600)
        chunks += planner.append(Array(samples[offset..<end]))
        offset = end
    }
    if let last = planner.finish() { chunks.append(last) }
    var parts: [String] = []
    var wait = 0.0
    for (index, chunk) in chunks.enumerated() where chunk.hasSpeech {
        let wav = WAVEncoder.encode(samples[chunk.start..<chunk.end])
        let started = Date()
        var text = try await client.transcribe(wav: wav, timeout: 30).text
        if !vocabulary.isEmpty, !text.isEmpty {
            text = try await client.correct(text, vocabulary: vocabulary, timeout: 30).text
        }
        if index == chunks.count - 1 { wait = Date().timeIntervalSince(started) }
        parts.append(text)
    }
    return (ChunkJoiner.join(parts), wait, chunks.count)
}

// MARK: - Report

func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}

/// Everything emitted accumulates here as well as going to stdout, so a run
/// launched from the app bundle — where LaunchServices discards stdout — can
/// write the identical report to `--out`.
var reportLines: [String] = []

func emit(_ line: String = "") {
    reportLines.append(line)
    print(line)
}

func writeReport(to file: URL?) {
    guard let file else { return }
    try? FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? (reportLines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
}

// MARK: - Run

let options = parseOptions()
let clips = loadClips(in: options.clipsDirectory)
guard !clips.isEmpty else {
    fail("no clips found in \(options.clipsDirectory.path) — see Eval/README.md for the layout")
}

let settingsDirectory = options.settingsDirectory
let settings = await MainActor.run { SettingsStore(directory: settingsDirectory).settings }
/// What the app would send the fixer: the saved terms, or (before the app has
/// filled them in) the same list mined from History.
let fixerVocabulary: [String] = await MainActor.run {
    guard options.correct else { return [] }
    var vocab = settings
    if vocab.terms == nil {
        vocab.terms = TermMiner.initialTerms(from: HistoryStore(directory: settingsDirectory).records.map(\.processedText))
    }
    return vocab.correctionVocabulary
}
let localeIdentifier = options.localeOverride ?? settings.localeIdentifier
let locale = Locale(identifier: localeIdentifier)

/// Text that skips the Apple recogniser: from a file, or from the server.
let hypotheses: [String: String]? = options.hypotheses.map(loadHypotheses)
let serverClient = options.backend == "server"
    ? DictationServerClient(baseURL: options.serverURL ?? settings.dictationServerURL)
    : nil
let usesApple = hypotheses == nil && serverClient == nil

var recognizer: SFSpeechRecognizer?
var languageModel: SFSpeechLanguageModel.Configuration?
let captureEngine = AVAudioEngine()
if usesApple {
    let status = await requestAuthorization()
    guard status == .authorized else {
        fail("""
            speech recognition not authorized (status: \(status.rawValue)).
            Grant the terminal app Speech Recognition access in
            System Settings → Privacy & Security → Speech Recognition, then re-run.
            """)
    }

    guard let appleRecognizer = SFSpeechRecognizer(locale: locale), appleRecognizer.isAvailable else {
        fail("no recognizer available for \(localeIdentifier)")
    }
    guard appleRecognizer.supportsOnDeviceRecognition else {
        fail("""
            on-device recognition unavailable for \(localeIdentifier).
            The Siri/dictation asset for this language isn't installed.
            """)
    }

    // The buffer-based request returns kAFAssistantErrorDomain 1107 with zero
    // callbacks unless a live capture session is running in the same process — true
    // even inside a signed bundle. Stand a real engine up and discard what it hears.
    if options.streaming {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            granted = false
        }
        guard granted else {
            fail("""
                streaming mode needs microphone access (the buffer-based recognition
                request fails without a live capture session). Grant it in
                System Settings → Privacy & Security → Microphone.
                """)
        }
        let input = captureEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { _, _ in }
        do {
            try captureEngine.start()
        } catch {
            fail("streaming mode couldn't start a capture engine: \(error)")
        }
    }

    recognizer = appleRecognizer
    languageModel = options.useCustomLanguageModel
        ? await prepareLanguageModel(settings: settings, locale: locale)
        : nil
}
if let serverClient {
    guard let health = await serverClient.health(timeout: 10) else {
        fail("dictation server not reachable at \(serverClient.baseURL)")
    }
    serverModel = health.model
}

let processor = TranscriptProcessor(settings: settings)

if let hypotheses = options.hypotheses {
    emit("whimpereval — hypotheses from \(hypotheses.lastPathComponent), \(clips.count) clip(s)")
} else if let serverClient {
    emit("whimpereval — dictation server \(serverClient.baseURL.absoluteString) (\(serverModel)), "
         + "chunks \(options.chunking.minSeconds)–\(options.chunking.maxSeconds) s, \(clips.count) clip(s)")
} else {
    emit("whimpereval — locale \(localeIdentifier), custom LM: \(languageModel == nil ? "off" : "on"), "
         + "API: \(options.streaming ? "streaming (as the app)" : "file-based"), \(clips.count) clip(s)")
}
if !usesApple {
    // No recogniser identity matters here.
} else if let clientIdentifier {
    emit("identity: \(clientIdentifier) — bundled, so the custom language model is really attached")
} else {
    emit("identity: none (unbundled) — ⚠️ the custom language model is IGNORED by the")
    emit("recognizer, so these numbers measure the text pipeline only. Use `make eval`.")
}
emit("")
emit("| clip | words | raw WER | processed WER | exact |")
emit("|---|---:|---:|---:|:---:|")

var rawTotal = WordErrorRate.Score()
var processedTotal = WordErrorRate.Score()
/// WER normalization strips `£`, `%` and `.`, so number and punctuation
/// *formatting* is invisible to it. Exact match against the reference is the
/// complementary metric: it is what the user would have had to type.
var exactMatches = 0
var scoredClips = 0
var diffs: [(String, String)] = []
var failures: [(String, String)] = []
var trimmed: [(String, Double)] = []
var categoryScores: [String: WordErrorRate.Score] = [:]
var afterRelease: [Double] = []
var chunkCounts: [Int] = []

// Trimmed copies live here for the run only; the recordings are never touched.
let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("whimpereval-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: scratch) }

// Streaming diagnostics: start each run with a fresh file so events accumulate.
streamDebugLog = options.debugLog
if let streamDebugLog { try? "".write(to: streamDebugLog, atomically: true, encoding: .utf8) }

for clip in clips {
    do {
        // A clip ending in ≥2s of silence comes back completely empty from the
        // recognizer, which would score as 100% WER and look like an accuracy
        // problem. Trim the tail so we measure recognition, not that cliff.
        var audio = clip.audio
        if usesApple, let result = try? SilenceTrimmer.trimmedCopy(of: clip.audio, into: scratch) {
            audio = result.url
            trimmed.append((clip.name, result.outcome.trimmedSeconds))
        }

        // kAFAssistantErrorDomain 1107 shows up sporadically when recognition
        // tasks run back to back; it's a startup failure, not a result, so
        // retry rather than scoring the clip as a total miss.
        var raw = ""
        var attempt = 0
        if let hypotheses {
            guard let text = hypotheses[clip.name] else { throw EvalError.noHypothesis }
            raw = text
        } else if let serverClient {
            let result = try await recognizeOnServer(audio: clip.audio, client: serverClient, chunking: options.chunking,
                                                     vocabulary: fixerVocabulary)
            raw = result.text
            afterRelease.append(result.afterRelease)
            chunkCounts.append(result.chunks)
        }
        while usesApple, let recognizer {
            do {
                raw = options.streaming
                    ? try await recognizeStreaming(
                        name: clip.name,
                        audio: audio,
                        recognizer: recognizer,
                        addsPunctuation: settings.autoPunctuate,
                        languageModel: languageModel
                    )
                    : try await recognize(
                        audio: audio,
                        recognizer: recognizer,
                        addsPunctuation: settings.autoPunctuate,
                        languageModel: languageModel
                    )
                break
            } catch {
                attempt += 1
                let code = (error as NSError).code
                guard code == 1107, attempt < 4 else { throw error }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        let processed = processor.process(raw).text
        if let dump = options.dumpFile {
            let line = try JSONSerialization.data(withJSONObject: ["clip": clip.name, "text": raw]) + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: dump) {
                handle.seekToEndOfFile(); handle.write(line); try? handle.close()
            } else {
                try line.write(to: dump)
            }
        }

        let rawScore = WordErrorRate.score(reference: clip.reference, hypothesis: raw)
        let processedScore = WordErrorRate.score(reference: clip.reference, hypothesis: processed)
        rawTotal = rawTotal + rawScore
        processedTotal = processedTotal + processedScore

        let exact = processed.trimmingCharacters(in: .whitespacesAndNewlines) == clip.reference
        if exact { exactMatches += 1 }
        scoredClips += 1

        let category = clip.name.split(separator: "-").first.map(String.init) ?? clip.name
        categoryScores[category, default: WordErrorRate.Score()] = categoryScores[category, default: WordErrorRate.Score()] + processedScore
        emit("| \(clip.name) | \(rawScore.referenceWords) | \(percent(rawScore.rate)) | \(percent(processedScore.rate)) | \(exact ? "✓" : "·") |")
        if options.verbose {
            diffs.append((clip.name, WordErrorRate.diff(reference: clip.reference, hypothesis: processed)))
        }
    } catch {
        failures.append((clip.name, "\(error)"))
        emit("| \(clip.name) | — | failed | failed | · |")
    }
}

emit("| **total** | \(rawTotal.referenceWords) | **\(percent(rawTotal.rate))** | **\(percent(processedTotal.rate))** | **\(exactMatches)/\(scoredClips)** |")
emit("")
emit("processed errors: \(processedTotal.substitutions) substitutions, "
     + "\(processedTotal.deletions) deletions, \(processedTotal.insertions) insertions")
emit("exact matches: \(exactMatches)/\(scoredClips) — catches formatting WER normalization hides")
emit("processed WER by category: " + categoryScores.keys.sorted().map {
    "\($0) \(percent(categoryScores[$0]!.rate))"
}.joined(separator: " · "))
if !afterRelease.isEmpty {
    let sorted = afterRelease.sorted()
    let median = sorted[sorted.count / 2]
    let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    emit(String(format: "after release (last chunk, round trip from this Mac): median %.2f s, p90 %.2f s, max %.2f s",
                median, p90, sorted.last!))
    emit("chunks per clip: " + chunkCounts.map(String.init).joined(separator: " "))
}

if !trimmed.isEmpty {
    let detail = trimmed.map { "\($0.0) (\(String(format: "%.1f", $0.1))s)" }.joined(separator: ", ")
    emit("trailing silence trimmed for recognition on \(trimmed.count) clip(s): \(detail)")
}

if options.verbose {
    for (name, diff) in diffs {
        emit("")
        emit("\(name): \(diff)")
    }
}

if !failures.isEmpty {
    emit("")
    for (name, message) in failures {
        emit("FAILED \(name): \(message)")
        FileHandle.standardError.write(Data("\(name): \(message)\n".utf8))
    }
    writeReport(to: options.outputFile)
    exit(1)
}

writeReport(to: options.outputFile)
