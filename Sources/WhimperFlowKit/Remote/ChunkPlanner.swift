import Foundation

/// Decides where to cut a dictation into chunks for the dictation server, so
/// most of the audio is recognised while the user is still talking and only
/// the last few seconds are left when they let go of the key.
///
/// Cuts land in pauses, so no word is split: once a chunk is `minSeconds` long,
/// the first quiet stretch of `pauseSeconds` ends it. Speech that runs on to
/// `maxSeconds` without a pause is cut at the quietest moment of its last
/// `searchSeconds`. Context is lost across a cut, which costs little at these
/// lengths and buys a near-constant wait after release.
///
/// Works on 16 kHz mono samples in 20 ms frames, judging speech with the same
/// adaptive `VoiceActivityDetector` the app uses for hands-free auto-stop. Pure
/// and deterministic: the same samples always produce the same cuts, so the app
/// and the eval harness chunk identically.
public struct ChunkPlanner: Sendable {
    public struct Config: Equatable, Sendable {
        public var sampleRate: Int = 16_000
        public var minSeconds: Double = 4
        public var maxSeconds: Double = 8
        public var pauseSeconds: Double = 0.3
        public var searchSeconds: Double = 3
        /// A chunk with less voiced audio than this is silence or a breath and is
        /// never sent: recognisers invent words for silent input.
        public var minSpeechSeconds: Double = 0.1

        public init() {}
    }

    /// A span of the dictation's samples, `[start, end)`.
    public struct Chunk: Equatable, Sendable {
        public var start: Int
        public var end: Int
        public var hasSpeech: Bool

        public var count: Int { end - start }
    }

    public let config: Config
    private let frameLength: Int
    private var vad = VoiceActivityDetector()

    /// Absolute sample index where the open chunk starts.
    private var chunkStart = 0
    /// Samples consumed so far (whole frames only; the rest waits in `pending`).
    private var consumed = 0
    private var pending: [Float] = []
    /// Per-frame level and voicing for the open chunk.
    private var levels: [Float] = []
    private var voicedFlags: [Bool] = []
    private var voicedFrames = 0
    private var quietRun = 0

    public init(config: Config = Config()) {
        self.config = config
        frameLength = config.sampleRate / 50
    }

    /// Feeds samples in arrival order; returns any chunks this closed.
    public mutating func append(_ samples: [Float]) -> [Chunk] {
        pending.append(contentsOf: samples)
        var closed: [Chunk] = []
        var offset = 0
        while pending.count - offset >= frameLength {
            let frame = pending[offset..<(offset + frameLength)]
            offset += frameLength
            if let chunk = observe(frame) { closed.append(chunk) }
        }
        pending.removeFirst(offset)
        return closed
    }

    /// Ends the dictation: everything not yet in a chunk becomes the last one.
    public mutating func finish() -> Chunk? {
        let end = consumed + pending.count
        pending.removeAll()
        guard end > chunkStart else { return nil }
        let chunk = Chunk(start: chunkStart, end: end, hasSpeech: hasSpeech)
        chunkStart = end
        consumed = end
        levels.removeAll()
        voicedFlags.removeAll()
        voicedFrames = 0
        quietRun = 0
        return chunk
    }

    // MARK: - Frames

    private var hasSpeech: Bool {
        Double(voicedFrames * frameLength) / Double(config.sampleRate) >= config.minSpeechSeconds
    }

    private mutating func observe(_ frame: ArraySlice<Float>) -> Chunk? {
        let level = Self.normalizedLevel(frame)
        let voiced = vad.observe(level)
        levels.append(level)
        voicedFlags.append(voiced)
        consumed += frameLength
        if voiced {
            voicedFrames += 1
            quietRun = 0
        } else {
            quietRun += 1
        }

        let rate = Double(config.sampleRate)
        let length = Double(consumed - chunkStart) / rate
        let pauseFrames = max(1, Int((config.pauseSeconds * 50).rounded()))
        if quietRun >= pauseFrames {
            // Cut in the middle of the pause, once the chunk is long enough.
            let cut = consumed - (pauseFrames / 2) * frameLength
            if Double(cut - chunkStart) / rate >= config.minSeconds {
                return close(at: cut)
            }
        }
        if length >= config.maxSeconds {
            let searchFrames = min(levels.count, max(1, Int(config.searchSeconds * 50)))
            let window = levels.suffix(searchFrames)
            let quietest = window.indices.min { levels[$0] < levels[$1] } ?? levels.count - 1
            return close(at: chunkStart + (quietest + 1) * frameLength)
        }
        return nil
    }

    /// Closes the open chunk at `cut` (a frame boundary), carrying the frames
    /// after it into the next chunk.
    private mutating func close(at cut: Int) -> Chunk {
        let keptFrames = (cut - chunkStart) / frameLength
        let carriedVoiced = voicedFlags[keptFrames...].filter { $0 }.count
        voicedFrames -= carriedVoiced
        let chunk = Chunk(start: chunkStart, end: cut, hasSpeech: hasSpeech)
        chunkStart = cut
        levels.removeFirst(keptFrames)
        voicedFlags.removeFirst(keptFrames)
        voicedFrames = carriedVoiced
        quietRun = min(quietRun, levels.count)
        return chunk
    }

    /// RMS → dB → 0…1, the same mapping as the app's capture level, so the
    /// detector's thresholds mean the same thing here.
    static func normalizedLevel(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        let rms = (sum / Float(frame.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 50) / 45))
    }
}
