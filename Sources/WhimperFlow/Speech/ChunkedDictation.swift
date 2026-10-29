import AVFoundation
import os
import AudioSupport
import WhimperFlowKit

/// The server engine's dictation: records the microphone as 16 kHz mono, cuts
/// it into chunks at pauses while the user talks, and recognises each chunk as
/// soon as it closes, so letting go of the key leaves only the last few seconds
/// to wait for.
///
/// Recording is separate from recognition: every sample is kept until the text
/// is delivered, so no backend failure can lose a dictation. Each chunk tries
/// the server first and falls back to Apple on its own; once the server fails
/// in a dictation, the rest of that dictation goes straight to Apple instead of
/// waiting out another timeout.
final class ChunkedDictation {
    struct Outcome {
        var text: String
        /// At least one chunk was recognised by Apple, not the server.
        var usedFallback: Bool
        /// Chunks that neither backend could recognise; the recording is in
        /// `samples` so it can be saved.
        var failedChunks: Int
        var samples: [Float]
    }

    // Callbacks fire on the main queue.
    var onPartial: ((String) -> Void)?
    var onFallback: (() -> Void)?
    var onServerFailure: (() -> Void)?
    var onFinal: ((Outcome) -> Void)?

    // Audio-thread state, behind `lock`.
    private var lock = os_unfair_lock_s()
    private var resampler: MonoResampler?
    private var planner = ChunkPlanner()
    private var samples: [Float] = []
    private var recording = false

    // Main-thread state.
    private var primary: TranscriptionBackend?
    private var fallback: TranscriptionBackend?
    private var serverDown = false
    private var usedFallback = false
    private var failedChunks = 0
    private var results: [Int: String] = [:]
    private var dispatched = 0
    private var finishing = false
    private var generation = 0

    /// Starts a dictation. `primary` nil means the server is known to be down,
    /// so every chunk goes to `fallback`.
    func start(primary: TranscriptionBackend?, fallback: TranscriptionBackend) {
        generation += 1
        self.primary = primary
        self.fallback = fallback
        serverDown = primary == nil
        usedFallback = false
        failedChunks = 0
        results = [:]
        dispatched = 0
        finishing = false
        os_unfair_lock_lock(&lock)
        resampler = nil
        planner = ChunkPlanner()
        samples = []
        recording = true
        os_unfair_lock_unlock(&lock)
    }

    /// Called on the audio thread.
    func append(buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(&lock)
        guard recording else { os_unfair_lock_unlock(&lock); return }
        if resampler == nil { resampler = MonoResampler(inputFormat: buffer.format) }
        let converted = resampler?.process(buffer) ?? []
        samples += converted
        let closed = planner.append(converted)
        let pieces = closed.map { ($0, Array(samples[$0.start..<$0.end])) }
        os_unfair_lock_unlock(&lock)
        guard !pieces.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for (chunk, audio) in pieces { self?.dispatch(chunk, audio) }
        }
    }

    /// Stops recording (call after the capture engine has stopped). `onFinal`
    /// fires once every chunk has an answer.
    func finish() {
        os_unfair_lock_lock(&lock)
        recording = false
        let tail = resampler?.flush() ?? []
        samples += tail
        var pieces = planner.append(tail).map { ($0, Array(samples[$0.start..<$0.end])) }
        if let last = planner.finish() { pieces.append((last, Array(samples[last.start..<last.end]))) }
        os_unfair_lock_unlock(&lock)
        // Behind any chunks the audio thread already queued on main.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (chunk, audio) in pieces { self.dispatch(chunk, audio) }
            self.finishing = true
            self.deliverIfComplete()
        }
    }

    func cancel() {
        generation += 1
        finishing = false
        os_unfair_lock_lock(&lock)
        recording = false
        samples = []
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Chunks (main thread)

    private func dispatch(_ chunk: ChunkPlanner.Chunk, _ audio: [Float]) {
        let index = dispatched
        dispatched += 1
        guard chunk.hasSpeech else {
            results[index] = ""
            return
        }
        let generation = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let text = await self.recognise(audio, generation: generation)
            guard generation == self.generation else { return }
            self.results[index] = text
            self.onPartial?(self.stitchedSoFar)
            self.deliverIfComplete()
        }
    }

    @MainActor
    private func recognise(_ audio: [Float], generation: Int) async -> String {
        if let primary, !serverDown {
            do {
                return try await primary.transcribe(audio)
            } catch {
                guard generation == self.generation else { return "" }
                if !serverDown {
                    serverDown = true
                    onServerFailure?()
                }
            }
        }
        guard let fallback else { failedChunks += 1; return "" }
        do {
            let text = try await fallback.transcribe(audio)
            if !usedFallback, generation == self.generation {
                usedFallback = true
                onFallback?()
            }
            return text
        } catch {
            failedChunks += 1
            return ""
        }
    }

    /// Text of the chunks answered so far, up to the first one still pending.
    private var stitchedSoFar: String {
        var parts: [String] = []
        var index = 0
        while let text = results[index] { parts.append(text); index += 1 }
        return ChunkJoiner.join(parts)
    }

    private func deliverIfComplete() {
        guard finishing, results.count == dispatched else { return }
        finishing = false
        let text = ChunkJoiner.join((0..<dispatched).map { results[$0] ?? "" })
        os_unfair_lock_lock(&lock)
        let recorded = samples
        samples = []
        os_unfair_lock_unlock(&lock)
        onFinal?(Outcome(text: text, usedFallback: usedFallback, failedChunks: failedChunks, samples: recorded))
    }
}
