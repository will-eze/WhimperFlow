import Foundation

/// Assembles a single dictation out of streaming recognition results, across
/// however many chunked recognizer sessions it took.
///
/// Three recognizer behaviours shape this type, all measured on macOS 15.5:
///
/// 1. **Empty final after silence.** Once roughly 2 seconds of silence follow
///    the speech, the on-device recognizer delivers an *empty* final result even
///    though earlier partials carried the complete utterance. Taking that final
///    at face value throws away what the user said — which, with a push-to-talk
///    hotkey, happens every time someone finishes a sentence and pauses before
///    letting go. So an empty transcription never overwrites text we already hold.
///
/// 2. **Rotation retro-correction.** When a long dictation is chunked, the
///    outgoing session is asked to stop but its *final* result — where the engine
///    retro-corrects earlier words — arrives a moment later, by which time the
///    next session is already producing text. Committing the outgoing session's
///    last partial instead threw that correction away on every chunk boundary. So
///    the outgoing text is parked in `draining`, holding its position, until its
///    real final arrives to supersede it.
///
/// 3. **Internal utterance resets (the subtle one).** Within a *single*
///    recognizer session, the on-device engine endpoints on inter-sentence
///    pauses and, without ever setting `isFinal`, resets `formattedString` to the
///    *new* utterance — dropping the finished one from the string entirely. A
///    naive "latest partial replaces the previous" therefore loses every utterance
///    but the last one in each session (a 43s dense paragraph collapsed to its
///    final two sentences). So each session is accumulated as the utterances it
///    has already endpointed plus the one it is still revising; a partial that
///    shrinks back to a fresh short string is recognised as a new utterance and
///    the finished one is preserved rather than overwritten.
public struct TranscriptAccumulator: Equatable, Sendable {
    /// Text finalized by earlier sessions in this dictation.
    public private(set) var committed = ""

    /// The session that has been asked to finish (rotation) but whose final
    /// result hasn't arrived. Kept apart from `committed` so the final can
    /// replace this estimate, and apart from the running session so the session
    /// that started after it can't jump ahead of it in the output.
    private var drainingSession = Session()

    /// The session currently feeding audio.
    private var runningSession = Session()

    public init() {}

    /// Best text from the draining session, for live display and diagnostics.
    public var draining: String { drainingSession.text }
    /// Best text from the running session (all its utterances so far).
    public var partial: String { runningSession.text }

    /// Record the newest transcription for the running session. Later results
    /// revise earlier ones; an empty one is ignored, and a reset to a new
    /// utterance preserves the previous one (see behaviours 1 and 3).
    public mutating func update(partial text: String) {
        runningSession.observe(text)
    }

    /// Fold the running session's text into the committed transcript.
    public mutating func commitPartial() {
        let text = runningSession.text
        guard !text.isEmpty else { return }
        append(text)
        runningSession = Session()
    }

    // MARK: - Rotation

    /// Begin rotating: the running session's text becomes a placeholder that
    /// holds its slot in the transcript while that session finishes and produces
    /// its real final result.
    ///
    /// Only one session can be draining at a time — a second rotation folds the
    /// previous placeholder in first, since holding two would leave no way to
    /// tell which final belongs where.
    public mutating func beginDraining() {
        if !drainingSession.text.isEmpty {
            append(drainingSession.text)
        }
        drainingSession = runningSession
        runningSession = Session()
    }

    /// Revise the draining session's placeholder, for results that arrive after
    /// `endAudio()` but before the final.
    public mutating func updateDraining(_ text: String) {
        drainingSession.observe(text)
    }

    /// The draining session finished. Its final revises the last utterance of the
    /// placeholder (earlier utterances of that session are kept); an empty final
    /// leaves the placeholder untouched, per behaviour 1.
    public mutating func finishDraining(final text: String) {
        drainingSession.observe(text)
        let best = drainingSession.text
        drainingSession = Session()
        guard !best.isEmpty else { return }
        append(best)
    }

    /// True while a rotated-away session still owes us its final result.
    public var isDraining: Bool { !drainingSession.text.isEmpty }

    /// Fold everything held — draining placeholder then running session — into
    /// the committed transcript, preserving order. Used when the dictation ends.
    public mutating func commitAll() {
        if !drainingSession.text.isEmpty {
            append(drainingSession.text)
            drainingSession = Session()
        }
        commitPartial()
    }

    /// Everything recognized so far, for live display.
    public var stitched: String {
        [committed, drainingSession.text, runningSession.text]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public mutating func reset() {
        committed = ""
        drainingSession = Session()
        runningSession = Session()
    }

    private mutating func append(_ text: String) {
        committed = committed.isEmpty ? text : committed + " " + text
    }

    /// One recognizer session, accumulated across the internal utterance resets
    /// described in behaviour 3.
    private struct Session: Equatable, Sendable {
        /// Utterances the recognizer has already endpointed this session.
        private var settled = ""
        /// The utterance it is still revising.
        private var current = ""

        var text: String {
            [settled, current].filter { !$0.isEmpty }.joined(separator: " ")
        }

        mutating func observe(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !current.isEmpty, TranscriptAccumulator.isNewUtterance(previous: current, next: trimmed) {
                settled = [settled, current].filter { !$0.isEmpty }.joined(separator: " ")
            }
            current = trimmed
        }
    }

    /// Distinguish the recognizer starting a fresh utterance (behaviour 3) from
    /// an ordinary revision of the current one.
    ///
    /// Revisions extend or lightly edit the tail while keeping the head stable,
    /// so the text only ever grows or shrinks slightly with the same opening.
    /// A reset instead collapses `formattedString` back to a short fresh string.
    /// We treat a *shrink* that either drops to a couple of words, or no longer
    /// shares the opening word, as a new utterance. Growth is never a reset, so
    /// the common case can't false-positive.
    static func isNewUtterance(previous: String, next: String) -> Bool {
        let previousWords = previous.split(separator: " ")
        let nextWords = next.split(separator: " ")
        guard previousWords.count >= 4, nextWords.count < previousWords.count else { return false }
        if nextWords.count <= 2 { return true }
        return nextWords.first?.lowercased() != previousWords.first?.lowercased()
    }
}
