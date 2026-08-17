import Testing
@testable import WhimperFlowKit

@Suite("Word error rate")
struct WordErrorRateTests {
    @Test func identicalTextScoresZero() {
        let score = WordErrorRate.score(reference: "the quick brown fox", hypothesis: "the quick brown fox")
        #expect(score.errors == 0)
        #expect(score.rate == 0)
        #expect(score.referenceWords == 4)
    }

    @Test func ignoresCaseAndSurroundingPunctuation() {
        let score = WordErrorRate.score(reference: "Hello, world.", hypothesis: "hello world")
        #expect(score.errors == 0)
    }

    @Test func keepsApostrophesAndInnerHyphens() {
        #expect(WordErrorRate.normalize("don't on-device") == ["don't", "on-device"])
        #expect(WordErrorRate.score(reference: "don't", hypothesis: "dont").errors == 1)
    }

    @Test func countsSubstitutionDeletionInsertion() {
        // reference: the quick brown fox
        // hypothesis: the quick red fox jumps   → 1 substitution, 1 insertion
        let a = WordErrorRate.score(reference: "the quick brown fox", hypothesis: "the quick red fox jumps")
        #expect(a.substitutions == 1)
        #expect(a.insertions == 1)
        #expect(a.deletions == 0)
        #expect(a.rate == 0.5)

        let b = WordErrorRate.score(reference: "the quick brown fox", hypothesis: "the brown fox")
        #expect(b.deletions == 1)
        #expect(b.substitutions == 0)
        #expect(b.insertions == 0)
    }

    @Test func emptyReference() {
        #expect(WordErrorRate.score(reference: "", hypothesis: "").rate == 0)
        #expect(WordErrorRate.score(reference: "", hypothesis: "noise").rate == 1)
        #expect(WordErrorRate.score(reference: "one two", hypothesis: "").rate == 1)
    }

    @Test func scoresAddUp() {
        let a = WordErrorRate.score(reference: "one two", hypothesis: "one three")
        let b = WordErrorRate.score(reference: "four five six", hypothesis: "four five six")
        let total = a + b
        #expect(total.referenceWords == 5)
        #expect(total.errors == 1)
        #expect(total.rate == 0.2)
    }

    @Test func alignmentIsWordLevel() {
        let steps = WordAlignment.align(reference: ["a", "b", "c"], hypothesis: ["a", "x", "c"])
        #expect(steps.map(\.operation) == [.match, .substitution, .match])
        #expect(steps[1].reference == "b")
        #expect(steps[1].hypothesis == "x")
    }

    @Test func alignmentHandlesEmptySides() {
        let deleted = WordAlignment.align(reference: ["a", "b"], hypothesis: [])
        #expect(deleted.map(\.operation) == [.deletion, .deletion])

        let inserted = WordAlignment.align(reference: [], hypothesis: ["a", "b"])
        #expect(inserted.map(\.operation) == [.insertion, .insertion])

        #expect(WordAlignment.align(reference: [], hypothesis: []).isEmpty)
    }

    @Test func diffIsReadable() {
        let text = WordErrorRate.diff(reference: "the quick brown fox", hypothesis: "the quick red fox jumps")
        #expect(text == "the quick [brown→red] fox (+jumps)")
    }
}
