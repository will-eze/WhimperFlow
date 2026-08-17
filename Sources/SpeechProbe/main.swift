import Foundation
import AVFoundation
import Speech

// Diagnostic for the *live* recognition path.
//
// `whimpereval` measures the file-based API. The app instead streams buffers
// into SFSpeechAudioBufferRecognitionRequest, and the file-based API turned out
// to discard an entire utterance when the audio ends in ≥2s of silence. This
// probe replays a clip through the streaming API with a controlled amount of
// trailing silence to find out whether the same cliff exists there — i.e.
// whether holding the hotkey after you stop talking loses your words.
//
// Must run from inside an app bundle: an unbundled process gets
// kAFAssistantErrorDomain 1107 from the buffer-based request, even though the
// URL-based request works fine.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("speechprobe: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first else {
    fail("usage: speechprobe <clip.wav> [padSeconds…]   (default pads: 0 1 2 3 5)")
}
let clipURL = URL(fileURLWithPath: path)
let pads: [Double] = arguments.count > 1 ? arguments.dropFirst().compactMap(Double.init) : [0, 1, 2, 3, 5]
let localeIdentifier = ProcessInfo.processInfo.environment["PROBE_LOCALE"] ?? "en-GB"

// MARK: - Setup

let authSemaphore = DispatchSemaphore(value: 0)
var authorization: SFSpeechRecognizerAuthorizationStatus = .notDetermined
SFSpeechRecognizer.requestAuthorization { authorization = $0; authSemaphore.signal() }
authSemaphore.wait()
guard authorization == .authorized else { fail("speech recognition not authorized") }

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
      recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
    fail("no on-device recognizer for \(localeIdentifier)")
}

// The app always has a live capture engine running while it streams buffers.
// Without one, the buffer-based request fails immediately with
// kAFAssistantErrorDomain 1107, so stand a real engine up first and simply
// discard what the microphone hears.
let engine = AVAudioEngine()
var engineRunning = false
if ProcessInfo.processInfo.environment["PROBE_NO_ENGINE"] == nil {
    let micSemaphore = DispatchSemaphore(value: 0)
    var micGranted = false
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        micGranted = true
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { micGranted = $0; micSemaphore.signal() }
        micSemaphore.wait()
    default:
        micGranted = false
    }
    if micGranted {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { _, _ in }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            FileHandle.standardError.write(Data("engine start failed: \(error)\n".utf8))
        }
    }
}

let file = try AVAudioFile(forReading: clipURL)
let format = file.processingFormat
let frameCount = AVAudioFrameCount(file.length)
guard let clip = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
    fail("couldn't buffer \(clipURL.lastPathComponent)")
}
try file.read(into: clip)
clip.frameLength = frameCount

/// Collects every callback the recognition task delivers, in order.
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(isFinal: Bool, text: String)] = []
    private var completed = false

    func append(isFinal: Bool, text: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append((isFinal, text))
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        completed = true
    }

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return completed }

    var snapshot: [(isFinal: Bool, text: String)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// Streams the clip, then `pad` seconds of silence, then ends audio —
/// mirroring what the capture engine does while the hotkey is held.
func probe(padSeconds: Double) -> (final: String, lastNonEmpty: String, callbacks: Int, error: String?) {
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    request.taskHint = .dictation
    request.addsPunctuation = true

    let results = Results()
    var errorText: String?

    let task = recognizer.recognitionTask(with: request) { result, error in
        if let result {
            results.append(isFinal: result.isFinal, text: result.bestTranscription.formattedString)
            if result.isFinal { results.finish() }
        }
        if let error {
            let ns = error as NSError
            // 1110 = "no speech detected", a normal outcome worth seeing here.
            errorText = "\(ns.domain) \(ns.code)"
            results.finish()
        }
    }

    // Feed off the main thread so the run loop stays free for callbacks —
    // the same split the app has between its audio thread and the main queue.
    DispatchQueue.global().async {
        let sampleRate = format.sampleRate
        let chunk = AVAudioFrameCount(sampleRate * 0.1)
        let channels = Int(format.channelCount)

        var offset: AVAudioFrameCount = 0
        while offset < frameCount {
            let length = min(chunk, frameCount - offset)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) {
                buffer.frameLength = length
                for channel in 0..<channels {
                    buffer.floatChannelData![channel]
                        .update(from: clip.floatChannelData![channel] + Int(offset), count: Int(length))
                }
                request.append(buffer)
            }
            offset += length
            Thread.sleep(forTimeInterval: 0.1)
        }

        for _ in 0..<Int(padSeconds / 0.1) {
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) {
                buffer.frameLength = chunk
                for channel in 0..<channels {
                    buffer.floatChannelData![channel].update(repeating: 0, count: Int(chunk))
                }
                request.append(buffer)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        request.endAudio()
    }

    let deadline = Date().addingTimeInterval(90)
    while !results.isDone && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    task.cancel()

    let entries = results.snapshot
    return (entries.last?.text ?? "",
            entries.last(where: { !$0.text.isEmpty })?.text ?? "",
            entries.count,
            errorText)
}

// MARK: - Run

// Launched via LaunchServices there is no terminal to print to, so mirror
// everything into a file the caller can read.
// Default beside the bundle (the checkout), since LaunchServices starts the
// process in "/" where nothing is writable.
let outputDirectory = ProcessInfo.processInfo.environment["PROBE_OUT"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? Bundle.main.bundleURL.deletingLastPathComponent()
let outputURL = outputDirectory.appendingPathComponent("probe-results.txt")
var transcript: [String] = []

func emit(_ line: String) {
    print(line)
    transcript.append(line)
    try? transcript.joined(separator: "\n").appending("\n").write(to: outputURL, atomically: true, encoding: .utf8)
}

emit("speechprobe — \(clipURL.lastPathComponent), locale \(localeIdentifier), streaming (buffer) API")
emit("capture engine running: \(engineRunning)")
emit("")

var dropouts = 0
var probeFailures = 0
var successes = 0

for pad in pads {
    // Starting recognition tasks back to back sometimes fails outright with
    // 1107 (zero callbacks). That's startup flakiness, not a result, so retry
    // rather than record it as evidence.
    var outcome = probe(padSeconds: pad)
    var attempt = 1
    while outcome.callbacks == 0 && attempt < 4 {
        Thread.sleep(forTimeInterval: 3)
        outcome = probe(padSeconds: pad)
        attempt += 1
    }
    let verdict: String
    if outcome.callbacks == 0 {
        // No results at all means the probe never got off the ground —
        // 1107 with zero callbacks is an environment problem, not evidence
        // about trailing silence. Never report it as a finding.
        verdict = "PROBE FAILED — no callbacks at all"
        probeFailures += 1
    } else if outcome.final.isEmpty && !outcome.lastNonEmpty.isEmpty {
        verdict = "LOST — final empty, but a partial had: \"\(outcome.lastNonEmpty)\""
        dropouts += 1
    } else if outcome.final.isEmpty {
        verdict = "EMPTY — callbacks arrived but nothing was recognized"
        dropouts += 1
    } else {
        verdict = "ok — \"\(outcome.final)\""
        successes += 1
    }
    let errorNote = outcome.error.map { " [\($0)]" } ?? ""
    emit(String(format: "pad %.1fs · %2d callbacks%@ · %@", pad, outcome.callbacks, errorNote, verdict))
}

emit("")
if probeFailures == pads.count {
    emit("INCONCLUSIVE — every run failed to start, so this says nothing about trailing silence.")
} else if dropouts > 0 && successes > 0 {
    emit("The streaming path DOES drop utterances at some trailing-silence lengths.")
} else if dropouts == 0 {
    emit("No dropout on the streaming path at these pad lengths.")
} else {
    emit("All runs came back empty — check the clip before drawing conclusions.")
}
