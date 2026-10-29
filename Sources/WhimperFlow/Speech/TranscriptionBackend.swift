import Foundation
import Speech
import AudioSupport
import WhimperFlowKit

/// Turns one chunk of 16 kHz mono audio into raw text.
protocol TranscriptionBackend: AnyObject, Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Parakeet on the dictation server. The timeout is short on purpose: a chunk
/// the server can't answer quickly goes to the Apple fallback instead.
final class ServerBackend: TranscriptionBackend, @unchecked Sendable {
    let client: DictationServerClient
    /// Terms the misheard-word fixer may write; empty turns fixing off.
    private let vocabulary: [String]
    /// Called on the main queue with each chunk's fixes.
    private let onFixes: @Sendable ([DictationServerClient.Fix]) -> Void

    init(client: DictationServerClient, vocabulary: [String] = [],
         onFixes: @escaping @Sendable ([DictationServerClient.Fix]) -> Void = { _ in }) {
        self.client = client
        self.vocabulary = vocabulary
        self.onFixes = onFixes
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let seconds = Double(samples.count) / MonoResampler.outputRate
        let wav = WAVEncoder.encode(samples[...])
        let text = try await client.transcribe(wav: wav, timeout: 2 + 0.1 * seconds).text
        guard !vocabulary.isEmpty, !text.isEmpty else { return text }
        // The fixer is optional: slow or failing, the chunk keeps what was heard.
        let words = Double(text.split(separator: " ").count)
        guard let fixed = try? await client.correct(text, vocabulary: vocabulary, timeout: 1.5 + 0.06 * words) else {
            return text
        }
        if !fixed.fixes.isEmpty {
            let fixes = fixed.fixes
            DispatchQueue.main.async { [onFixes] in onFixes(fixes) }
        }
        return fixed.text
    }
}

/// Apple's on-device recogniser, run on a saved chunk: the fallback when the
/// server can't be reached, and never a hard stop. A missing on-device model
/// fails only the chunks that needed it, and the recording is kept.
final class AppleBackend: TranscriptionBackend, @unchecked Sendable {
    private let localeIdentifier: String
    private let contextualStrings: [String]
    private let addsPunctuation: Bool

    init(localeIdentifier: String, contextualStrings: [String], addsPunctuation: Bool) {
        self.localeIdentifier = localeIdentifier
        self.contextualStrings = contextualStrings
        self.addsPunctuation = addsPunctuation
    }

    /// Whether this Mac can recognise speech on-device right now.
    static func isAvailable(localeIdentifier: String) -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeechService.SpeechError.localeUnavailable(localeIdentifier)
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw SpeechService.SpeechError.localeUnavailable(localeIdentifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechService.SpeechError.onDeviceUnsupported(localeIdentifier)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whimperflow-\(UUID().uuidString).wav")
        try WAVEncoder.encode(samples[...]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = addsPunctuation
        if !contextualStrings.isEmpty { request.contextualStrings = contextualStrings }

        return try await withCheckedThrowingContinuation { continuation in
            let settled = OnceFlag()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if settled.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    // "No speech detected" is an empty chunk, not a failure.
                    let code = (error as NSError).code
                    if settled.claim() {
                        if code == 1110 { continuation.resume(returning: "") } else { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }
}

/// Resumes a continuation exactly once from a callback that may fire repeatedly.
final class OnceFlag: @unchecked Sendable {
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
