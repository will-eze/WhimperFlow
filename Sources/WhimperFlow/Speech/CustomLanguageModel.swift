import Foundation
import Speech
import CryptoKit
import WhimperFlowKit

/// Builds and compiles an on-device custom language model from the user's
/// dictionary and snippets. This biases recognition toward personal vocabulary
/// far more strongly than `contextualStrings`. Everything happens locally:
/// the model is derived deterministically from settings and cached by content
/// hash, so it only recompiles when the vocabulary or locale changes.
@MainActor
final class CustomLanguageModelStore {
    /// Ready-to-use configuration for `SFSpeechRecognitionRequest`, or nil
    /// while unprepared / when the user has no custom vocabulary.
    private(set) var configuration: SFSpeechLanguageModel.Configuration?

    private var preparedHash: String?
    private var preparing = false

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? SettingsStore.defaultDirectory().appendingPathComponent("customlm", isDirectory: true)
    }

    /// Recompile if the vocabulary or locale changed; no-op otherwise.
    func rebuildIfNeeded(settings: FlowSettings) {
        let phrases = Self.phrases(from: settings)
        guard !phrases.isEmpty else {
            configuration = nil
            preparedHash = nil
            return
        }
        let hash = Self.hash(locale: settings.localeIdentifier, phrases: phrases)
        guard hash != preparedHash, !preparing else { return }

        let modelURL = directory.appendingPathComponent("model-\(hash).lm")
        let lmConfiguration = SFSpeechLanguageModel.Configuration(languageModel: modelURL)
        if FileManager.default.fileExists(atPath: modelURL.path) {
            configuration = lmConfiguration
            preparedHash = hash
            return
        }

        preparing = true
        let locale = Locale(identifier: settings.localeIdentifier)
        let dir = directory
        Task {
            defer { preparing = false }
            // Compilation fails intermittently ("Failed to initialize language
            // model", kLSRErrorDomain 400) on vocabulary that compiles fine on a
            // later attempt. Giving up after one try silently drops the strongest
            // recognition bias we have, so retry before falling back.
            for attempt in 1...3 {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let assetURL = dir.appendingPathComponent("asset-\(hash).bin")
                    let data = SFCustomLanguageModelData(locale: locale, identifier: "com.whimperflow.app.lm", version: hash)
                    for phrase in phrases {
                        data.insert(phraseCount: .init(phrase: phrase, count: 10))
                    }
                    try await data.export(to: assetURL)
                    try await Self.prepare(assetURL: assetURL, configuration: lmConfiguration)
                    try? FileManager.default.removeItem(at: assetURL)
                    // Drop stale models from previous vocabularies.
                    if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                        for url in contents where url.lastPathComponent != modelURL.lastPathComponent {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                    configuration = lmConfiguration
                    preparedHash = hash
                    return
                } catch {
                    NSLog("WhimperFlow: custom language model attempt \(attempt) failed: \(error)")
                    // A failed build can leave a partial .lm behind. Since the
                    // cache check below only tests for existence, leaving it
                    // would make every later launch attach a corrupt model and
                    // fail every single recognition. Clear it.
                    try? FileManager.default.removeItem(at: modelURL)
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("asset-\(hash).bin"))
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            // Recognition proceeds without the custom model.
            NSLog("WhimperFlow: custom language model unavailable after 3 attempts")
        }
    }

    private static func prepare(assetURL: URL, configuration: SFSpeechLanguageModel.Configuration) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            SFSpeechLanguageModel.prepareCustomLanguageModel(
                for: assetURL,
                clientIdentifier: "com.whimperflow.app",
                configuration: configuration
            ) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    static func phrases(from settings: FlowSettings) -> [String] {
        CustomVocabulary.phrases(from: settings)
    }

    static func hash(locale: String, phrases: [String]) -> String {
        let joined = locale + "\u{1}" + phrases.joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
