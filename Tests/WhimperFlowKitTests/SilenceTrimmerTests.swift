import Testing
import Foundation
import AVFoundation
@testable import AudioSupport

/// Writes a mono 44.1kHz WAV: `toneSeconds` of signal, then `silenceSeconds` of digital silence.
private func makeClip(toneSeconds: Double, silenceSeconds: Double, in directory: URL, name: String) throws -> URL {
    let sampleRate = 44100.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let toneFrames = Int(toneSeconds * sampleRate)
    let silenceFrames = Int(silenceSeconds * sampleRate)
    let total = AVAudioFrameCount(toneFrames + silenceFrames)

    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
    buffer.frameLength = total
    let samples = buffer.floatChannelData![0]
    for i in 0..<toneFrames {
        samples[i] = Float(0.3 * sin(2.0 * .pi * 440.0 * Double(i) / sampleRate))
    }
    for i in toneFrames..<Int(total) { samples[i] = 0 }

    let url = directory.appendingPathComponent("\(name).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
    return url
}

private func duration(of url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

@Suite("Silence trimming")
struct SilenceTrimmerTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func trimsLongTrailingSilenceBelowTheRecognizerCliff() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 2s of speech-like signal followed by 3s of silence: the shape that
        // makes the recognizer return an empty result.
        let clip = try makeClip(toneSeconds: 2, silenceSeconds: 3, in: dir, name: "long-tail")
        let result = try #require(try SilenceTrimmer.trimmedCopy(of: clip, into: dir.appendingPathComponent("out")))

        #expect(result.outcome.didTrim)
        let trimmedDuration = try duration(of: result.url)
        // Signal plus the half-second we deliberately keep, well under 2s of tail.
        #expect(trimmedDuration > 2.0)
        #expect(trimmedDuration < 2.75)
    }

    @Test func leavesCleanClipsAlone() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = try makeClip(toneSeconds: 2, silenceSeconds: 0.1, in: dir, name: "clean")
        #expect(try SilenceTrimmer.trimmedCopy(of: clip, into: dir.appendingPathComponent("out")) == nil)
    }

    @Test func silentClipIsLeftUntouched() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Nothing audible to anchor on — better to leave it and let the clip
        // score badly than to truncate it to nothing.
        let clip = try makeClip(toneSeconds: 0, silenceSeconds: 3, in: dir, name: "silent")
        #expect(try SilenceTrimmer.trimmedCopy(of: clip, into: dir.appendingPathComponent("out")) == nil)
    }

    @Test func trimInPlaceShortensTheOriginal() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = try makeClip(toneSeconds: 1.5, silenceSeconds: 3, in: dir, name: "in-place")
        let before = try duration(of: clip)
        let outcome = try #require(try SilenceTrimmer.trimInPlace(clip))
        let after = try duration(of: clip)

        #expect(outcome.didTrim)
        #expect(after < before)
        #expect(after > 1.5)
    }
}
