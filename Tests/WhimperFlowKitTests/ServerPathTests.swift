import Testing
import Foundation
@testable import WhimperFlowKit

/// 16 kHz test audio: `speech` is a loud tone, `silence` a faint hiss.
private func speech(_ seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.2) }
}

private func silence(_ seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(($0 * 7919) % 13) / 13 * 0.0004 }
}

private func plan(_ samples: [Float], config: ChunkPlanner.Config = .init(), feed: Int = 1_600) -> [ChunkPlanner.Chunk] {
    var planner = ChunkPlanner(config: config)
    var chunks: [ChunkPlanner.Chunk] = []
    var offset = 0
    while offset < samples.count {
        let end = min(samples.count, offset + feed)
        chunks += planner.append(Array(samples[offset..<end]))
        offset = end
    }
    if let last = planner.finish() { chunks.append(last) }
    return chunks
}

@Suite("Chunk planning")
struct ChunkPlannerTests {
    @Test func shortDictationIsOneChunk() {
        let audio = silence(0.5) + speech(3) + silence(0.5)
        let chunks = plan(audio)
        #expect(chunks.count == 1)
        #expect(chunks[0].start == 0 && chunks[0].end == audio.count)
        #expect(chunks[0].hasSpeech)
    }

    @Test func cutsAtThePauseOnceLongEnough() {
        // A pause at 2 s is too early to cut; the one at 5 s is taken.
        let audio = silence(0.5) + speech(1.5) + silence(0.5) + speech(2.5) + silence(0.6) + speech(2)
        let chunks = plan(audio)
        #expect(chunks.count == 2)
        let cut = Double(chunks[0].end) / 16_000
        #expect(cut > 5.0 && cut < 5.6, "cut at \(cut) s should fall inside the pause at 5.0–5.6 s")
        let voiced = chunks.filter(\.hasSpeech)
        #expect(voiced.count == chunks.count)
    }

    @Test func unbrokenSpeechIsCutAtTheLimit() {
        let chunks = plan(silence(0.5) + speech(20))
        #expect(chunks.count >= 3)
        for chunk in chunks.dropLast() {
            #expect(Double(chunk.count) / 16_000 <= 8.01)
        }
    }

    @Test func chunksTileTheAudioExactly() {
        let audio = silence(1) + speech(5) + silence(0.4) + speech(9) + silence(0.3) + speech(3) + silence(2)
        let chunks = plan(audio, feed: 1_024)
        #expect(chunks.first?.start == 0)
        #expect(chunks.last?.end == audio.count)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(a.end == b.start) }
    }

    @Test func trailingSilenceIsNotSpeech() {
        let chunks = plan(silence(0.5) + speech(5) + silence(0.5) + silence(3))
        #expect(chunks.first?.hasSpeech == true)
        if chunks.count > 1 { #expect(chunks.last?.hasSpeech == false) }
        let silent = plan(silence(3)).filter(\.hasSpeech)
        #expect(silent.isEmpty)
    }

    @Test func feedSizeDoesNotChangeCuts() {
        let audio = silence(0.5) + speech(5) + silence(0.5) + speech(7) + silence(0.4) + speech(4)
        #expect(plan(audio, feed: 160) == plan(audio, feed: 4_096))
    }
}

@Suite("Server path pieces")
struct ServerPathTests {
    @Test func wavHeaderAndSamples() {
        let data = WAVEncoder.encode([0, 1, -1, 0.5][...])
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
        let second = data[46..<48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        #expect(Int16(littleEndian: second) == 32_767)
    }

    @Test func joinerDropsMidSentenceStops() {
        #expect(ChunkJoiner.join(["I deployed the container.", "to the cluster."]) == "I deployed the container to the cluster.")
        #expect(ChunkJoiner.join(["First sentence.", "Second one."]) == "First sentence. Second one.")
        #expect(ChunkJoiner.join(["", " hello ", ""]) == "hello")
        #expect(ChunkJoiner.join(["Wait...", "then go."]) == "Wait... then go.")
    }

    @Test func oldSettingsGetTheServerEngine() throws {
        var legacy = FlowSettings()
        legacy.launchAtLogin = false
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        for key in ["engine", "serverURL", "launchAtLoginDefaultApplied"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(FlowSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.transcriptionEngine == .server)
        #expect(decoded.dictationServerURL.absoluteString == FlowSettings.defaultServerURL)
        #expect(decoded.launchAtLoginDefaultApplied == nil)
        #expect(decoded.launchAtLogin == false)
    }

    @Test func blankOrBadServerURLFallsBack() {
        var settings = FlowSettings()
        settings.serverURL = "  "
        #expect(settings.dictationServerURL.absoluteString == FlowSettings.defaultServerURL)
        settings.serverURL = "not a url"
        #expect(settings.dictationServerURL.absoluteString == FlowSettings.defaultServerURL)
        settings.serverURL = "http://127.0.0.1:7030"
        #expect(settings.dictationServerURL.absoluteString == "http://127.0.0.1:7030")
    }

    @Test func newSettingsLaunchAtLogin() {
        let settings = FlowSettings()
        #expect(settings.launchAtLogin)
        #expect(settings.transcriptionEngine == .server)
    }
}
