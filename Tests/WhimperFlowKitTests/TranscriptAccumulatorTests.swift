import Testing
@testable import WhimperFlowKit

@Suite("Transcript accumulation")
struct TranscriptAccumulatorTests {
    @Test func laterPartialsReviseEarlierOnes() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "quick one do we")
        accumulator.update(partial: "Quick one, do we need approval")
        #expect(accumulator.stitched == "Quick one, do we need approval")
    }

    /// The regression this type exists for: after ~2s of trailing silence the
    /// recognizer delivers an empty final result even though a partial carried
    /// the whole utterance. Honouring it would silently discard the dictation.
    @Test func emptyFinalNeverDiscardsRecognizedText() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "Quick one, do we need approval before I go ahead?")
        accumulator.update(partial: "")

        #expect(accumulator.stitched == "Quick one, do we need approval before I go ahead?")
        accumulator.commitPartial()
        #expect(accumulator.committed == "Quick one, do we need approval before I go ahead?")
    }

    @Test func whitespaceOnlyResultIsAlsoIgnored() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "hello there")
        accumulator.update(partial: "   \n ")
        #expect(accumulator.stitched == "hello there")
    }

    @Test func sessionsAreJoinedWithASingleSpace() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "first session text")
        accumulator.commitPartial()
        accumulator.update(partial: "second session text")

        #expect(accumulator.stitched == "first session text second session text")
        accumulator.commitPartial()
        #expect(accumulator.committed == "first session text second session text")
    }

    @Test func silentDictationStaysEmpty() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "")
        accumulator.commitPartial()
        #expect(accumulator.stitched.isEmpty)
        #expect(accumulator.committed.isEmpty)
    }

    @Test func commitIsIdempotentAndResetClears() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "only once")
        accumulator.commitPartial()
        accumulator.commitPartial()
        #expect(accumulator.committed == "only once")

        accumulator.reset()
        #expect(accumulator.stitched.isEmpty)
        #expect(accumulator.committed.isEmpty)
    }

    @Test func partialsAreTrimmed() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "  padded text  ")
        #expect(accumulator.partial == "padded text")
    }

    // MARK: - Rotation

    /// The B1 regression. A dictation past the session limit rotates; the
    /// outgoing session's *final* is retro-corrected and must supersede the
    /// partial that stood in for it — in its original position, even though the
    /// next session has already started producing text.
    @Test func rotationFinalSupersedesThePlaceholderInPlace() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "I deployed the container to the cake cluster")

        accumulator.beginDraining()
        accumulator.update(partial: "and the pod kept crash looping")
        // Outgoing session finalizes late, after the new one has text.
        accumulator.finishDraining(final: "I deployed the container to the k8s cluster")

        #expect(accumulator.stitched == "I deployed the container to the k8s cluster and the pod kept crash looping")
    }

    /// While the outgoing session is still settling, its text must stay visible
    /// and stay *ahead* of the new session's — no flicker, no reordering.
    @Test func drainingTextHoldsItsPositionWhileWaiting() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "first chunk")
        accumulator.beginDraining()
        accumulator.update(partial: "second chunk")

        #expect(accumulator.isDraining)
        #expect(accumulator.stitched == "first chunk second chunk")
    }

    /// Same empty-final rule as the non-rotating path: a session that ends on
    /// silence returns nothing, and that must not erase what it already heard.
    @Test func emptyRotationFinalKeepsThePlaceholder() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "text the outgoing session heard")
        accumulator.beginDraining()
        accumulator.finishDraining(final: "")

        #expect(accumulator.committed == "text the outgoing session heard")
        #expect(!accumulator.isDraining)
    }

    /// A second rotation before the first settled must not drop the first —
    /// order is committed, oldest first.
    @Test func overlappingRotationsKeepOrder() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "one")
        accumulator.beginDraining()
        accumulator.update(partial: "two")
        accumulator.beginDraining()   // first placeholder folds in
        accumulator.update(partial: "three")

        #expect(accumulator.stitched == "one two three")
    }

    /// Ending a dictation mid-rotation must keep both the draining text and the
    /// running partial, in that order — `commitPartial` alone would lose one.
    @Test func commitAllPreservesDrainingThenPartial() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "outgoing text")
        accumulator.beginDraining()
        accumulator.update(partial: "incoming text")
        accumulator.commitAll()

        #expect(accumulator.committed == "outgoing text incoming text")
        #expect(accumulator.stitched == "outgoing text incoming text")
    }

    @Test func rotatingASilentChunkAddsNothing() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "real text")
        accumulator.commitPartial()
        accumulator.beginDraining()          // nothing running
        accumulator.finishDraining(final: "")
        #expect(accumulator.committed == "real text")
    }

    // MARK: - Internal utterance resets

    /// The long-04 regression. Within one session the on-device recognizer
    /// endpoints on an inter-sentence pause and resets `formattedString` to the
    /// new utterance, with no `isFinal`. The finished utterance must survive
    /// instead of being overwritten by the new one's partials.
    @Test func internalUtteranceResetPreservesTheFinishedUtterance() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "The invoice came to one thousand two hundred and forty pounds")
        // Recognizer resets: a new, shorter utterance with a different opening.
        accumulator.update(partial: "There were")
        accumulator.update(partial: "There were three line items I couldn't account for")

        #expect(accumulator.stitched == "The invoice came to one thousand two hundred and forty pounds There were three line items I couldn't account for")
    }

    /// A reset that happens to start with the same word as the previous utterance
    /// is still caught, because the string collapses to just a word or two.
    @Test func resetWithSameOpeningWordIsCaughtByTheCollapse() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "The container I deployed kept crash looping badly")
        accumulator.update(partial: "The")   // collapse to one word
        accumulator.update(partial: "The logs were all JSON")

        #expect(accumulator.stitched == "The container I deployed kept crash looping badly The logs were all JSON")
    }

    /// The guard against false positives: a revision that *shortens* the tail but
    /// keeps the same opening is a correction, not a new utterance — it must not
    /// duplicate the shared words.
    @Test func tailShorteningRevisionIsNotTreatedAsAReset() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "we should ship the whole entire feature today")
        accumulator.update(partial: "we should ship the feature")

        #expect(accumulator.stitched == "we should ship the feature")
    }

    /// Accumulated utterances survive a rotation as a unit: the whole running
    /// session (both utterances) becomes the draining placeholder, so an empty
    /// rotation final keeps all of it.
    @Test func multiUtteranceSessionSurvivesRotation() {
        var accumulator = TranscriptAccumulator()
        accumulator.update(partial: "first sentence of the outgoing session here")
        accumulator.update(partial: "second")              // reset to new utterance
        accumulator.update(partial: "second sentence of the outgoing session")
        accumulator.beginDraining()
        accumulator.update(partial: "the incoming session text")
        accumulator.finishDraining(final: "")              // outgoing ended on silence

        #expect(accumulator.committed == "first sentence of the outgoing session here second sentence of the outgoing session")
        #expect(accumulator.stitched == "first sentence of the outgoing session here second sentence of the outgoing session the incoming session text")
    }
}
