import Foundation

/// Decides whether a normalized microphone level is speech or background noise,
/// by tracking the room's noise floor instead of comparing against a constant.
///
/// The constant it replaces was `level > 0.12` (≈ −44.6 dB), hardcoded in two
/// places. On a close-talking mic in a quiet room that works. On a quiet or
/// far-field mic real speech never crosses it, and since this signal drives
/// hands-free auto-stop *and* the "is it safe to rotate the session" check, a
/// quiet input made dictation stop mid-sentence and rotate mid-word — the same
/// class of bug as reading only channel 0 of a multichannel input.
///
/// Deterministic and pure: same sequence of levels in, same decisions out, so
/// it can be pinned by tests like the rest of the engine.
public struct VoiceActivityDetector: Equatable, Sendable {
    /// Nothing below this counts as speech, however quiet the room gets. Without
    /// it the floor would adapt down into near-silence and then treat the
    /// faintest hiss as talking.
    public static let absoluteFloor: Float = 0.01

    /// How far above the noise floor a level must sit to count as speech.
    /// Speech peaks run well over 3× a steady room floor; below that is the
    /// noise itself fluctuating.
    public static let margin: Float = 3.0

    /// However loud the room, speech is never required to exceed this — a
    /// pathological floor must not be able to switch detection off altogether.
    public static let maximumThreshold: Float = 0.25

    /// The floor is the quietest level seen in roughly the last second, which
    /// is what makes this work in both directions.
    ///
    /// The obvious scheme — nudge a running average, but only on samples judged
    /// *not* to be speech — cannot learn a loud room at all: every sample
    /// starts out above the threshold, so it is called speech, so the floor is
    /// never updated, so it stays wrong forever. Taking a minimum instead needs
    /// no such judgement. Speech is not continuous at this timescale; the gaps
    /// between words reach room tone, so the window minimum tracks the room
    /// even while someone is talking over it, and drops the instant they stop.
    static let windowSize = 43           // ≈ 1s of 1024-frame buffers at 44.1kHz

    private var window: [Float]
    private var next: Int
    private var filled: Int

    public init() {
        window = [Float](repeating: 0, count: Self.windowSize)
        next = 0
        filled = 0
    }

    /// Level above which the current room counts a sample as speech.
    public var threshold: Float {
        min(Self.maximumThreshold, max(Self.absoluteFloor, estimatedNoiseFloor * Self.margin))
    }

    /// Quietest level in the window; 0 until the first observation.
    public var estimatedNoiseFloor: Float {
        guard filled > 0 else { return 0 }
        return window.prefix(filled).min() ?? 0
    }

    /// Classify one level and fold it into the noise-floor window.
    ///
    /// The sample is classified against the floor *as it stood before* this
    /// observation, so a single loud buffer can never raise the bar it is
    /// itself being measured against.
    @discardableResult
    public mutating func observe(_ level: Float) -> Bool {
        let clamped = max(0, level)
        let speech = clamped > threshold
        window[next] = clamped
        next = (next + 1) % Self.windowSize
        filled = Swift.min(filled + 1, Self.windowSize)
        return speech
    }

    public mutating func reset() {
        for i in window.indices { window[i] = 0 }
        next = 0
        filled = 0
    }
}
