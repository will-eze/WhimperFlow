import AVFoundation
import Speech
import WhimperFlowKit

/// `WhimperFlow.app/Contents/MacOS/WhimperFlow --selftest <audio> [--server <url>]`
///
/// Plays a recording through the app's own server path (`ChunkedDictation`, the
/// backends, the fallback) in real time, as the microphone would, and prints the
/// outcome. Point `--server` at a dead address to watch the Apple fallback take
/// over. Runs from the bundle so Speech Recognition permission applies.
@MainActor
enum SelfTest {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return false }
        let audio = URL(fileURLWithPath: args[i + 1])
        let settings = SettingsStore().settings
        var serverURL = settings.dictationServerURL
        if let j = args.firstIndex(of: "--server"), j + 1 < args.count, let url = URL(string: args[j + 1]) {
            serverURL = url
        }
        Task { @MainActor in
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } }
            }
            await run(audio: audio, serverURL: serverURL, settings: settings)
            exit(0)
        }
        return true
    }

    private static func run(audio: URL, serverURL: URL, settings: FlowSettings) async {
        guard let file = try? AVAudioFile(forReading: audio) else { print("can't read \(audio.path)"); exit(1) }
        let client = DictationServerClient(baseURL: serverURL)
        let reachable = await client.health() != nil
        print("server \(serverURL.absoluteString): \(reachable ? "reachable" : "unreachable")")
        let dictation = ChunkedDictation()
        dictation.onServerFailure = { print("server failed mid-dictation, falling back") }
        dictation.onFallback = { print("Apple fallback used") }
        let started = Date()
        var released = Date()
        let outcome: ChunkedDictation.Outcome = await withCheckedContinuation { continuation in
            dictation.onFinal = { continuation.resume(returning: $0) }
            dictation.start(
                primary: reachable ? ServerBackend(client: client) : nil,
                fallback: AppleBackend(localeIdentifier: settings.localeIdentifier,
                                       contextualStrings: settings.contextualStrings(),
                                       addsPunctuation: settings.autoPunctuate)
            )
            // Real-time feed in 1024-frame buffers from a background thread,
            // like the capture tap.
            let format = file.processingFormat
            DispatchQueue.global().async {
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
                          (try? file.read(into: buffer, frameCount: 1024)) != nil, buffer.frameLength > 0 else { break }
                    dictation.append(buffer: buffer)
                    Thread.sleep(forTimeInterval: Double(buffer.frameLength) / format.sampleRate)
                }
                DispatchQueue.main.async {
                    released = Date()
                    dictation.finish()
                }
            }
        }
        let processed = TranscriptProcessor(settings: settings).process(outcome.text).text
        print(String(format: "audio %.1f s, wait after release %.2f s", released.timeIntervalSince(started),
                     Date().timeIntervalSince(released)))
        print("fallback used: \(outcome.usedFallback), failed chunks: \(outcome.failedChunks)")
        print("raw: \(outcome.text)")
        print("typed: \(processed)")
    }
}
