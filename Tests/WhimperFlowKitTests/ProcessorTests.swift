import Testing
import Foundation
@testable import WhimperFlowKit

private func makeProcessor(_ tweak: (inout FlowSettings) -> Void = { _ in }) -> TranscriptProcessor {
    var s = FlowSettings()
    tweak(&s)
    return TranscriptProcessor(settings: s)
}

@Suite("End-to-end processing, normal mode")
struct NormalModeTests {
    let p = makeProcessor()

    @Test func basicSentence() {
        let r = p.process("this is a simple test")
        #expect(r.text == "This is a simple test.")
    }

    @Test func fillerRemoval() {
        let r = p.process("um so I think we should uh ship it")
        #expect(r.text == "So I think we should ship it.")
    }

    @Test func fillerWithAttachedComma() {
        let r = p.process("Um, let's get started")
        #expect(r.text == "Let's get started.")
    }

    @Test func fillerNeverInsideWords() {
        let r = p.process("the umbrella is uh here")
        #expect(r.text == "The umbrella is here.")
    }

    @Test func multiWordFiller() {
        let r = p.process("it's you know pretty good")
        #expect(r.text == "It's pretty good.")
    }

    @Test func spokenPunctuation() {
        let r = p.process("hello comma world exclamation point")
        #expect(r.text == "Hello, world!")
    }

    @Test func spokenQuestionMark() {
        let r = p.process("are you coming question mark")
        #expect(r.text == "Are you coming?")
    }

    @Test func newParagraphAndCapitalization() {
        let r = p.process("first line period new paragraph second thought here")
        #expect(r.text == "First line.\n\nSecond thought here.")
    }

    @Test func quotesAttachCorrectly() {
        let r = p.process("she said open quote never close quote yesterday")
        #expect(r.text == "She said \"never\" yesterday.")
    }

    @Test func emailAddressViaGlue() {
        let r = p.process("reach me at john at sign example dot com")
        #expect(r.text == "Reach me at john@example.com.")
    }

    @Test func existingPunctuationFromEngine() {
        // macOS addsPunctuation output arrives pre-punctuated.
        let r = p.process("Hello, how are you?")
        #expect(r.text == "Hello, how are you?")
    }

    @Test func noDoubledTerminalPeriod() {
        let r = p.process("this already ends period")
        #expect(r.text == "This already ends.")
    }

    @Test func shortUtteranceGetsNoPeriod() {
        let r = p.process("yes")
        #expect(r.text == "Yes")
    }

    @Test func pronounIFixed() {
        let r = p.process("i think i'm ready and i'll go")
        #expect(r.text == "I think I'm ready and I'll go.")
    }

    @Test func capitalizationAfterSentenceBreak() {
        let r = p.process("done period next item is pending")
        #expect(r.text == "Done. Next item is pending.")
    }

    @Test func emptyInput() {
        #expect(p.process("   ") == ProcessedResult())
    }

    @Test func emojiMapping() {
        let r = p.process("sounds good smiley face")
        #expect(r.text == "Sounds good 🙂")
    }
}

@Suite("Leading context / smart spacing")
struct LeadInTests {
    let p = makeProcessor()

    @Test func afterSentenceGetsSpaceAndCap() {
        let r = p.process("here is more detail", context: .init(precedingText: "First part."))
        #expect(r.text == " Here is more detail.")
    }

    @Test func midSentenceContinuationNoCap() {
        let r = p.process("and some more", context: .init(precedingText: "some text"))
        #expect(r.text == " and some more.")
    }

    @Test func afterTrailingSpaceNoDoubleSpace() {
        let r = p.process("continues here", context: .init(precedingText: "Sentence. "))
        #expect(r.text == "Continues here.")
    }

    @Test func afterNewlineNoLeadingSpace() {
        let r = p.process("fresh line", context: .init(precedingText: "above\n"))
        #expect(r.text == "Fresh line.")
    }

    @Test func afterOpenParenNoSpace() {
        let r = p.process("inner note", context: .init(precedingText: "text ("))
        #expect(r.text == "inner note.")
    }

    @Test func utteranceStartingWithPunctuationAttaches() {
        let r = p.process("comma which is fine", context: .init(precedingText: "clause"))
        #expect(r.text == ", which is fine.")
    }

    @Test func emptyFieldNoLeadingSpace() {
        let r = p.process("start here", context: .init(precedingText: ""))
        #expect(r.text == "Start here.")
    }
}

@Suite("Commands and snippets")
struct CommandTests {
    @Test func scratchThat() {
        let p = makeProcessor()
        let r = p.process("scratch that")
        #expect(r.command == .scratchThat)
        #expect(r.text.isEmpty)
    }

    @Test func scratchThatWithEnginePunctuation() {
        let p = makeProcessor()
        #expect(p.process("Scratch that.").command == .scratchThat)
    }

    @Test func pressEnter() {
        let p = makeProcessor()
        #expect(p.process("press enter").command == .pressReturn)
    }

    @Test func snippetExpansion() {
        let p = makeProcessor {
            $0.snippets = [Snippet(trigger: "insert my signature", expansion: "Best,\nWill Eze")]
        }
        let r = p.process("insert my signature")
        #expect(r.text == "Best,\nWill Eze")
    }

    @Test func snippetAfterSentenceGetsLeadingSpace() {
        let p = makeProcessor {
            $0.snippets = [Snippet(trigger: "my email", expansion: "will@example.com")]
        }
        let r = p.process("My email.", context: .init(precedingText: "Contact:"))
        #expect(r.text == " will@example.com")
    }
}

@Suite("Dictionary")
struct DictionaryTests {
    @Test func simpleReplacement() {
        let p = makeProcessor {
            $0.dictionary = [DictionaryEntry(pattern: "jira", replacement: "Jira")]
        }
        #expect(p.process("check the jira board").text == "Check the Jira board.")
    }

    @Test func multiWordPattern() {
        let p = makeProcessor {
            $0.dictionary = [DictionaryEntry(pattern: "k eight s", replacement: "k8s")]
        }
        #expect(p.process("deploy to k eight s today").text == "Deploy to k8s today.")
    }

    @Test func longestMatchWins() {
        let p = makeProcessor {
            $0.dictionary = [
                DictionaryEntry(pattern: "swift", replacement: "Swift"),
                DictionaryEntry(pattern: "swift ui", replacement: "SwiftUI"),
            ]
        }
        #expect(p.process("swift ui is great").text == "SwiftUI is great.")
    }

    @Test func verbatimNotRecased() {
        let p = makeProcessor {
            $0.dictionary = [DictionaryEntry(pattern: "eye phone", replacement: "iPhone")]
        }
        // Dictionary output keeps its exact casing even at sentence start.
        #expect(p.process("eye phone sales are up").text == "iPhone sales are up.")
    }
}

@Suite("Numbers")
struct NumberTests {
    let p = makeProcessor()

    @Test func smallNumbersStayWords() {
        #expect(p.process("I have five ideas").text == "I have five ideas.")
    }

    @Test func tenAndUpBecomeNumerals() {
        #expect(p.process("we need fifteen chairs").text == "We need 15 chairs.")
    }

    @Test func compoundNumbers() {
        #expect(p.process("twenty five people came").text == "25 people came.")
    }

    @Test func bigNumbersWithGrouping() {
        #expect(p.process("three thousand two hundred units").text == "3,200 units.")
    }

    @Test func hundredAnd() {
        #expect(p.process("one hundred and five days").text == "105 days.")
    }

    @Test func currency() {
        #expect(p.process("that costs twenty five dollars").text == "That costs $25.")
    }

    @Test func currencyWithCents() {
        #expect(p.process("five dollars and twenty five cents please").text == "$5.25 please.")
    }

    @Test func centsAlone() {
        #expect(p.process("it was fifty cents").text == "It was 50¢.")
    }

    @Test func percent() {
        #expect(p.process("about fifty percent done").text == "About 50% done.")
    }

    @Test func decimalPoint() {
        #expect(p.process("pi is three point one four").text == "Pi is 3.14.")
    }

    @Test func ordinalsHighBecomeNumerals() {
        #expect(p.process("the twenty fifth of May").text == "The 25th of May.")
    }

    @Test func ordinalsLowStayWords() {
        #expect(p.process("the third option works").text == "The third option works.")
    }

    @Test func digitTokensWithUnits() {
        #expect(p.process("roughly 80 percent there").text == "Roughly 80% there.")
    }

    @Test func disabledNormalizationKeepsWords() {
        let p2 = makeProcessor { $0.normalizeNumbers = false }
        #expect(p2.process("twenty five people came").text == "Twenty five people came.")
    }
}

@Suite("Modes")
struct ModeTests {
    @Test func casualNoCapsNoPeriod() {
        let p = makeProcessor()
        let r = p.process("sounds good see you soon", context: .init(mode: .casual))
        #expect(r.text == "sounds good see you soon")
    }

    @Test func casualKeepsPronounI() {
        let p = makeProcessor()
        let r = p.process("i think so", context: .init(mode: .casual))
        #expect(r.text == "I think so")
    }

    @Test func literalIsVerbatim() {
        let p = makeProcessor()
        let r = p.process("um hello comma world", context: .init(mode: .literal))
        #expect(r.text == "um hello comma world")
    }

    @Test func codeSnake() {
        let p = makeProcessor()
        let r = p.process("snake case user account id", context: .init(mode: .code))
        #expect(r.text == "user_account_id")
    }

    @Test func codeCamel() {
        let p = makeProcessor()
        let r = p.process("camel case fetch user profile", context: .init(mode: .code))
        #expect(r.text == "fetchUserProfile")
    }

    @Test func codePascal() {
        let p = makeProcessor()
        let r = p.process("pascal case http client factory", context: .init(mode: .code))
        #expect(r.text == "HttpClientFactory")
    }

    @Test func codeKebab() {
        let p = makeProcessor()
        let r = p.process("kebab case my feature branch", context: .init(mode: .code))
        #expect(r.text == "my-feature-branch")
    }

    @Test func codeAllCaps() {
        let p = makeProcessor()
        let r = p.process("all caps do not merge", context: .init(mode: .code))
        #expect(r.text == "DO NOT MERGE")
    }

    @Test func codeWithoutOperatorIsPlain() {
        let p = makeProcessor()
        let r = p.process("git commit dash m", context: .init(mode: .code))
        // "dash" maps to an em dash word in spoken punctuation; code mode
        // still applies spoken punctuation but no caps or terminal period.
        #expect(!r.text.hasSuffix("."))
        #expect(r.text.first.map { $0.isLowercase || !$0.isLetter } == true)
    }

    @Test func codeNoNumberNormalization() {
        let p = makeProcessor()
        let r = p.process("retry twenty five times", context: .init(mode: .code))
        #expect(r.text == "retry twenty five times")
    }
}

@Suite("Settings behavior")
struct SettingsBehaviorTests {
    @Test func modeForBundleID() {
        var s = FlowSettings()
        s.appProfiles = [AppProfile(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", mode: .casual)]
        #expect(s.mode(forBundleID: "com.tinyspeck.slackmacgap") == .casual)
        #expect(s.mode(forBundleID: "com.apple.mail") == .normal)
        #expect(s.mode(forBundleID: nil) == .normal)
    }

    @Test func disabledApp() {
        var s = FlowSettings()
        s.appProfiles = [AppProfile(bundleID: "com.apple.Terminal", appName: "Terminal", mode: .code, enabled: false)]
        #expect(!s.isEnabled(forBundleID: "com.apple.Terminal"))
        #expect(s.isEnabled(forBundleID: "other.app"))
    }

    @Test func contextualStringsDeduplicated() {
        var s = FlowSettings()
        s.dictionary = [
            DictionaryEntry(pattern: "jira", replacement: "Jira"),
            DictionaryEntry(pattern: "notion", replacement: "Notion"),
        ]
        s.snippets = [Snippet(trigger: "insert my signature", expansion: "x")]
        let strings = s.contextualStrings()
        #expect(strings.contains("Jira"))
        #expect(strings.contains("insert my signature"))
        // "jira" pattern equals replacement case-insensitively → only one entry.
        #expect(strings.filter { $0.lowercased() == "jira" }.count == 1)
    }

    @Test func settingsRoundTrip() throws {
        var s = FlowSettings()
        s.hotkey = .fn
        s.dictionary = [DictionaryEntry(pattern: "a", replacement: "B", caseSensitive: true)]
        s.snippets = [Snippet(trigger: "t", expansion: "e")]
        s.appProfiles = [AppProfile(bundleID: "x.y", appName: "XY", mode: .code, enabled: false)]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(FlowSettings.self, from: data)
        #expect(back == s)
    }
}

@Suite("Determinism")
struct DeterminismTests {
    @Test func repeatedRunsIdentical() {
        let p = makeProcessor {
            $0.dictionary = [DictionaryEntry(pattern: "acme", replacement: "ACME")]
        }
        let input = "um so acme owes us twenty five dollars comma right question mark"
        let first = p.process(input)
        for _ in 0..<50 {
            #expect(p.process(input) == first)
        }
        #expect(first.text == "So ACME owes us $25, right?")
    }
}
