import Testing
import Foundation
@testable import WhimperFlowKit

private func makeProcessor(_ tweak: (inout FlowSettings) -> Void = { _ in }) -> TranscriptProcessor {
    var s = FlowSettings()
    tweak(&s)
    return TranscriptProcessor(settings: s)
}

// MARK: - Segmenter

@Suite("Function segmenter")
struct FunctionSegmenterTests {
    private func segment(_ raw: String, trigger: String = "flow") -> [FunctionSegment] {
        FunctionSegmenter.segment(Tokenizer.tokenize(raw), triggers: VoiceFunction.triggerPhrases(for: trigger))
    }

    @Test func noTriggerIsOneNormalSegment() {
        let segs = segment("hello world")
        #expect(segs.count == 1)
        #expect(segs[0].kind == .normal)
    }

    @Test func opensSpellSpanToEndOfUtterance() {
        let segs = segment("flow spell a b c")
        #expect(segs == [FunctionSegment(kind: .spell(caps: false), tokens: [.word("a"), .word("b"), .word("c")])])
    }

    @Test func spellCapsModifierIsConsumed() {
        let segs = segment("flow spell caps a b")
        #expect(segs == [FunctionSegment(kind: .spell(caps: true), tokens: [.word("a"), .word("b")])])
    }

    @Test func explicitEndClosesSpanAndResumesNormal() {
        let segs = segment("say flow quote hi flow end now")
        #expect(segs.count == 3)
        #expect(segs[0].kind == .normal)
        #expect(segs[1] == FunctionSegment(kind: .quote, tokens: [.word("hi")]))
        #expect(segs[2] == FunctionSegment(kind: .normal, tokens: [.word("now")]))
    }

    @Test func triggerBeforeOrdinaryWordStaysLiteral() {
        // "flow" is only hot before a function name.
        let segs = segment("the flow is calm")
        #expect(segs == [FunctionSegment(kind: .normal, tokens: [.word("the"), .word("flow"), .word("is"), .word("calm")])])
    }

    @Test func doublingEscapesToOneLiteralTrigger() {
        let segs = segment("flow flow is fine")
        #expect(segs == [FunctionSegment(kind: .normal, tokens: [.word("flow"), .word("is"), .word("fine")])])
    }

    @Test func multiWordFunctionName() {
        let segs = segment("flow speech marks hi flow end")
        #expect(segs == [FunctionSegment(kind: .quote, tokens: [.word("hi")])])
    }

    @Test func triggerInsideSpanIsContentUnlessFollowedByEnd() {
        // A lone "flow" inside a span (not "flow end") is just span content.
        let segs = segment("flow literal the flow rate flow end")
        #expect(segs == [FunctionSegment(kind: .literal, tokens: [.word("the"), .word("flow"), .word("rate")])])
    }

    @Test func punctuationBetweenTriggerAndNameTolerated() {
        // The engine sometimes attaches a comma: "flow, spell …".
        let segs = segment("flow, spell a b c")
        #expect(segs == [FunctionSegment(kind: .spell(caps: false), tokens: [.word("a"), .word("b"), .word("c")])])
    }

    @Test func closesOnStop() {
        let segs = segment("flow quote hi flow stop there")
        #expect(segs.count == 2)
        #expect(segs[0] == FunctionSegment(kind: .quote, tokens: [.word("hi")]))
        #expect(segs[1] == FunctionSegment(kind: .normal, tokens: [.word("there")]))
    }

    @Test func flowAndInsideSpanIsContentNotClose() {
        // The whole point of using "stop": "flow and" stays span content.
        let segs = segment("flow caps flow and now flow stop")
        #expect(segs == [FunctionSegment(kind: .caps, tokens: [.word("flow"), .word("and"), .word("now")])])
    }

    @Test func misheardTriggerOpensSpan() {
        // The recognizer writes the trigger "flow" as "flu"; it must still open.
        let segs = segment("flu spell a b c")
        #expect(segs == [FunctionSegment(kind: .spell(caps: false), tokens: [.word("a"), .word("b"), .word("c")])])
    }

    @Test func strayCloseIsSwallowed() {
        // An orphaned "flow stop" (no span open) must not leak into the text.
        let segs = segment("done flow stop now")
        #expect(segs == [FunctionSegment(kind: .normal, tokens: [.word("done"), .word("now")])])
    }

    @Test func triggerVariantOutsideSpanStaysProse() {
        // "flu" as an ordinary word is preserved exactly, not rewritten to "flow".
        let segs = segment("i have the flu today")
        #expect(segs == [FunctionSegment(kind: .normal, tokens: [.word("i"), .word("have"), .word("the"), .word("flu"), .word("today")])])
    }
}

// MARK: - Spell resolution

@Suite("Spell mode")
struct SpellModeTests {
    let p = makeProcessor()

    @Test func joinsLettersLowercase() {
        #expect(p.process("flow spell n g i n x").text == "nginx")
    }

    @Test func digitsBecomeNumerals() {
        #expect(p.process("deploy to flow spell k eight s flow end").text == "Deploy to k8s")
    }

    @Test func capsModifierUppercases() {
        #expect(p.process("flow spell caps s f t p").text == "SFTP")
    }

    @Test func natoAlphabet() {
        #expect(p.process("flow spell hotel india flow end").text == "hi")
    }

    @Test func letterHomophones() {
        #expect(p.process("flow spell see oh dee ee flow end").text == "code")
    }

    @Test func midUtteranceResumesProse() {
        #expect(p.process("the format is flow spell y a m l flow end today").text == "The format is yaml today.")
    }

    @Test func uppercaseLettersLowercasedByDefault() {
        // The recognizer emits spelled letters capitalized; default output is lower.
        #expect(p.process("flow spell N G I N X").text == "nginx")
    }

    @Test func mergedUppercaseTokenLowercased() {
        // Sometimes the engine merges the spelling into one uppercase token.
        #expect(p.process("flow spell NGINX flow end").text == "nginx")
    }

    @Test func spacingPreservedAroundSpell() {
        #expect(p.process("hello flow spell n g i n x flow end world").text == "Hello nginx world.")
    }

    @Test func unclosedSpanDegradesToSpacedText() {
        // No "flow end": the span runs to the end, but multi-letter words keep
        // their spaces instead of collapsing into one run-on token.
        #expect(p.process("flow spell this is fine").text == "this is fine")
    }
}

// MARK: - Other functions end-to-end

@Suite("Voice functions end-to-end")
struct VoiceFunctionsE2ETests {
    let p = makeProcessor()

    @Test func quoteWrapsAndFormatsInner() {
        // Inner text still runs the prose pipeline (filler removed here).
        #expect(p.process("she said flow quote um ship it flow end").text == "She said \"ship it\"")
    }

    @Test func quoteAtSentenceStartCapitalizes() {
        #expect(p.process("flow quote ship it flow end please").text == "\"Ship it\" please.")
    }

    @Test func literalIsVerbatim() {
        #expect(p.process("flow literal um twenty five flow end").text == "um twenty five")
    }

    @Test func literalNoTrailingPeriod() {
        #expect(p.process("flow literal as is here flow end").text == "as is here")
    }

    @Test func codeFunctionAppliesIdentifierOperator() {
        #expect(p.process("the call is flow code snake case user id flow end").text == "The call is user_id")
    }

    @Test func capsUppercasesWords() {
        #expect(p.process("flow caps fixme flow end handle this").text == "FIXME handle this.")
    }

    @Test func capsAlone() {
        #expect(p.process("flow caps warning flow end").text == "WARNING")
    }

    @Test func capsClosedByStop() {
        #expect(p.process("flow caps warning flow stop message here").text == "WARNING message here.")
    }

    @Test func spellClosedByStop() {
        #expect(p.process("deploy to flow spell k eight s flow stop now").text == "Deploy to k8s now.")
    }

    @Test func flowAndPreservedAsSpanContent() {
        // "and" no longer closes, so it survives inside a span.
        #expect(p.process("flow caps flow and now flow stop").text == "FLOW AND NOW")
    }

    @Test func reportedSentenceMisheardTriggerRecovers() {
        // Live case: opener "flow" heard as "flu"; span still opens, markers gone.
        #expect(p.process("flu spell caps premium flow stop and today on the news").text
            == "PREMIUM and today on the news.")
    }

    @Test func symbolsArrowFromWords() {
        #expect(p.process("flow symbols dash greater than flow end").text == "->")
    }

    @Test func symbolsArrowAliasBetweenWords() {
        #expect(p.process("flow symbols a arrow b flow end").text == "a->b")
    }

    @Test func symbolsGreaterOrEqual() {
        #expect(p.process("flow symbols greater than or equal to flow end").text == ">=")
    }

    @Test func punctuationBeforeEndTolerated() {
        // "flow, end" (comma the engine attached) still closes the span.
        #expect(p.process("say flow quote hi flow, end now").text == "Say \"hi\" now.")
    }
}

// MARK: - Collision safety, config, determinism

@Suite("Voice function guards")
struct VoiceFunctionGuardTests {
    @Test func triggerWordSurvivesAsProse() {
        let p = makeProcessor()
        #expect(p.process("the flow is broken").text == "The flow is broken.")
        #expect(p.process("the workflow is broken").text == "The workflow is broken.")
    }

    @Test func doublingWritesLiteralTrigger() {
        let p = makeProcessor()
        #expect(p.process("flow flow is fine").text == "Flow is fine.")
    }

    @Test func disabledLeavesTranscriptUntouched() {
        let p = makeProcessor { $0.voiceFunctions = false }
        #expect(p.process("flow spell hello").text == "Flow spell hello.")
    }

    @Test func customTrigger() {
        let p = makeProcessor { $0.functionTrigger = "compose" }
        #expect(p.process("compose spell n g i n x").text == "nginx")
        // The old default word is now just prose.
        #expect(p.process("the flow is calm").text == "The flow is calm.")
    }

    @Test func biasingIncludesFunctionPhrases() {
        let strings = FlowSettings().contextualStrings()
        #expect(strings.contains("flow"))
        #expect(strings.contains("flow spell"))
        #expect(strings.contains("flow stop"))
    }

    @Test func deterministicAcrossRuns() {
        let p = makeProcessor()
        let input = "note flow spell caps a p i flow end returns flow quote ok flow end"
        let first = p.process(input)
        for _ in 0..<25 { #expect(p.process(input) == first) }
        #expect(first.text == "Note API returns \"ok\"")
    }
}
