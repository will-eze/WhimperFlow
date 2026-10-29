import Foundation
import AudioSupport
import WhimperFlowKit

/// Dictations no engine could transcribe, kept as WAV files so nothing is lost.
/// When the server comes back they are transcribed and added to History (not
/// typed: the cursor has long moved on), then deleted.
@MainActor
final class UnsentRecordings {
    private let directory: URL
    private var retrying = false

    init() {
        directory = SettingsStore.defaultDirectory().appendingPathComponent("Unsent", isDirectory: true)
    }

    var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".wav") }.count ?? 0
    }

    @discardableResult
    func save(_ samples: [Float], appName: String?) -> URL? {
        guard !samples.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = [stamp, appName?.replacingOccurrences(of: "/", with: "-")].compactMap { $0 }.joined(separator: " ")
        let url = directory.appendingPathComponent(name + ".wav")
        do {
            try WAVEncoder.encode(samples[...]).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Transcribes every saved recording on the server, oldest first.
    func retry(client: DictationServerClient, settings: FlowSettings, history: HistoryStore) {
        guard !retrying, count > 0 else { return }
        retrying = true
        Task { @MainActor in
            defer { self.retrying = false }
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "wav" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard let samples = try? MonoResampler.samples(of: file) else { continue }
                var planner = ChunkPlanner()
                var chunks = planner.append(samples)
                if let last = planner.finish() { chunks.append(last) }
                var parts: [String] = []
                do {
                    for chunk in chunks where chunk.hasSpeech {
                        let wav = WAVEncoder.encode(samples[chunk.start..<chunk.end])
                        parts.append(try await client.transcribe(wav: wav, timeout: 30).text)
                    }
                } catch {
                    return // server went away again; try on the next return
                }
                let raw = ChunkJoiner.join(parts)
                let processed = TranscriptProcessor(settings: settings).process(raw).text
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                history.add(DictationRecord(
                    date: attributes?[.creationDate] as? Date ?? Date(),
                    appBundleID: nil,
                    appName: "Recovered recording",
                    rawText: raw,
                    processedText: processed.trimmingCharacters(in: .whitespaces),
                    durationSeconds: Double(samples.count) / MonoResampler.outputRate
                ))
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
