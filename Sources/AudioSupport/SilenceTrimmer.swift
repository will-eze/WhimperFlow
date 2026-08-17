import Foundation
import AVFoundation

/// Trailing-silence trimming.
///
/// Measured on macOS 15.5 (M1): giving `SFSpeechURLRecognitionRequest` a clip
/// that ends in **2 seconds or more** of silence makes it return an *empty*
/// final result — the whole utterance is discarded, not merely mis-recognized.
/// The identical audio with ≤1s of trailing silence transcribes perfectly.
/// So a clip that simply caught a pause before the stop button scores 100% WER
/// and quietly poisons the baseline.
///
/// Everything here is deterministic: same input file, same output samples.
public enum SilenceTrimmer {
    /// How much trailing quiet to leave in place. Comfortably under the ~2s
    /// cliff, while still giving the recognizer an endpoint to settle on.
    public static let defaultKeepSeconds: Double = 0.5

    public struct Outcome: Equatable, Sendable {
        /// Seconds removed from the end (0 when the clip was already fine).
        public var trimmedSeconds: Double
        public var originalDuration: Double

        public var didTrim: Bool { trimmedSeconds > 0 }
    }

    /// Last frame whose short-window RMS rises above the noise floor.
    /// The threshold is relative to the clip's own peak, so it adapts to
    /// quiet recordings instead of assuming a fixed input gain.
    private static func lastAudibleFrame(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> Int? {
        guard count > 0 else { return nil }

        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(samples[i])) }
        guard peak > 0 else { return nil }
        let threshold = max(Float(1e-4), peak * 0.03)

        let window = max(1, Int(sampleRate * 0.02))
        var frame = count
        while frame > 0 {
            let start = max(0, frame - window)
            var sum: Float = 0
            for i in start..<frame { sum += samples[i] * samples[i] }
            let rms = (sum / Float(frame - start)).squareRoot()
            if rms > threshold { return frame }
            frame = start
        }
        return nil
    }

    /// Write a trimmed copy of `url` into `directory`, or return nil when the
    /// clip needs no trimming (the caller then uses the original).
    public static func trimmedCopy(
        of url: URL,
        into directory: URL,
        keepSeconds: Double = defaultKeepSeconds
    ) throws -> (url: URL, outcome: Outcome)? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        try file.read(into: buffer)
        buffer.frameLength = total

        let sampleRate = format.sampleRate
        let originalDuration = Double(total) / sampleRate
        guard let channel = buffer.floatChannelData?[0],
              let lastAudible = lastAudibleFrame(channel, count: Int(total), sampleRate: sampleRate) else {
            return nil
        }

        let keepFrames = Int(keepSeconds * sampleRate)
        let target = min(Int(total), lastAudible + keepFrames)
        let removed = Double(Int(total) - target) / sampleRate
        // Leave clips alone unless the tail is genuinely long enough to matter.
        guard removed > 0.25, target > 0 else { return nil }

        guard let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(target)) else { return nil }
        let channelCount = Int(format.channelCount)
        for ch in 0..<channelCount {
            guard let source = buffer.floatChannelData?[ch], let destination = trimmed.floatChannelData?[ch] else { continue }
            destination.update(from: source, count: target)
        }
        trimmed.frameLength = AVAudioFrameCount(target)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: output)
        let outFile = try AVAudioFile(forWriting: output, settings: file.fileFormat.settings)
        try outFile.write(from: trimmed)

        return (output, Outcome(trimmedSeconds: removed, originalDuration: originalDuration))
    }

    /// Trim `url` in place. Used right after recording so the saved clip is
    /// never one the recognizer will silently discard.
    @discardableResult
    public static func trimInPlace(_ url: URL, keepSeconds: Double = defaultKeepSeconds) throws -> Outcome? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("whimper-trim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let result = try trimmedCopy(of: url, into: scratch, keepSeconds: keepSeconds) else { return nil }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: result.url)
        return result.outcome
    }
}
