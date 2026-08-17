import Testing
@testable import WhimperFlowKit

@Suite("Voice activity detection")
struct VoiceActivityDetectorTests {
    /// Feed a steady room tone for long enough that the floor settles.
    private func settled(noise: Float, samples: Int = 200) -> VoiceActivityDetector {
        var vad = VoiceActivityDetector()
        for _ in 0..<samples { vad.observe(noise) }
        return vad
    }

    /// The B5 regression. A quiet or far-field mic puts speech well under the
    /// old fixed 0.12 threshold, so hands-free dictation auto-stopped
    /// mid-sentence and the session rotated mid-word.
    @Test func quietMicSpeechIsHeard() {
        var vad = settled(noise: 0.004)
        let heard = vad.observe(0.03)       // speech, 7.5x the room
        #expect(heard)
        #expect(Float(0.03) < 0.12)         // ...and invisible to the old constant
    }

    @Test func roomToneIsNotSpeech() {
        var vad = settled(noise: 0.004)
        let tone = vad.observe(0.004)
        let drift = vad.observe(0.006)
        #expect(!tone)
        #expect(!drift)
    }

    /// A noisy room must raise the bar, not just lower it — otherwise fan noise
    /// reads as continuous speech and nothing ever auto-stops.
    @Test func noisyRoomRaisesTheBar() {
        var vad = settled(noise: 0.06)
        let noise = vad.observe(0.06)
        let speech = vad.observe(0.4)
        #expect(!noise)
        #expect(speech)
        #expect(vad.threshold > VoiceActivityDetector.absoluteFloor)
    }

    /// Pure digital silence must never register, however quiet the room got.
    @Test func silenceIsNeverSpeech() {
        var vad = settled(noise: 0.0)
        let quiet = vad.observe(0.0)
        let faint = vad.observe(0.001)
        #expect(!quiet)
        #expect(!faint)
        #expect(vad.threshold == VoiceActivityDetector.absoluteFloor)
    }

    /// Talking must not walk the floor up underneath itself. Speech is modelled
    /// the way it actually arrives — syllables separated by short dips to room
    /// tone — because that is exactly what lets a window minimum stay put while
    /// someone is speaking over it.
    @Test func sustainedSpeechDoesNotPoisonTheFloor() {
        var vad = settled(noise: 0.004)
        for i in 0..<500 { vad.observe(i % 5 == 0 ? 0.004 : 0.05) }
        let stillHeard = vad.observe(0.05)
        #expect(vad.estimatedNoiseFloor == 0.004)
        #expect(stillHeard)
    }

    /// The flip side, and correct: a level that never dips *is* background, so
    /// after a second of it the detector stops calling it speech. Documented
    /// because it's the one case where a window minimum differs from intuition.
    @Test func aTrulyConstantToneBecomesTheFloor() {
        var vad = settled(noise: 0.004)
        for _ in 0..<VoiceActivityDetector.windowSize { vad.observe(0.05) }
        let stillHeard = vad.observe(0.05)
        #expect(!stillHeard)
    }

    /// However loud the room gets, speech must not be required to clear an
    /// impossible bar — detection stays switched on.
    @Test func thresholdIsCapped() {
        var vad = settled(noise: 0.9)
        #expect(vad.threshold == VoiceActivityDetector.maximumThreshold)
        let shout = vad.observe(1.0)
        #expect(shout)
    }

    /// Quiet from the first buffer: no warm-up window where speech is missed.
    @Test func quietSpeechIsHeardImmediately() {
        var vad = VoiceActivityDetector()
        let heard = vad.observe(0.02)
        #expect(heard)
    }

    @Test func negativeLevelsAreTreatedAsSilence() {
        var vad = VoiceActivityDetector()
        let heard = vad.observe(-1.0)
        #expect(!heard)
    }

    @Test func resetReturnsToTheQuietDefault() {
        var vad = settled(noise: 0.09)
        #expect(vad.threshold > VoiceActivityDetector.absoluteFloor)
        vad.reset()
        #expect(vad.threshold == VoiceActivityDetector.absoluteFloor)
    }

    @Test func decisionsAreDeterministic() {
        let levels: [Float] = [0.0, 0.002, 0.05, 0.3, 0.01, 0.0, 0.08, 0.004]
        var a = VoiceActivityDetector()
        var b = VoiceActivityDetector()
        let first = levels.map { a.observe($0) }
        let second = levels.map { b.observe($0) }
        #expect(first == second)
    }
}
