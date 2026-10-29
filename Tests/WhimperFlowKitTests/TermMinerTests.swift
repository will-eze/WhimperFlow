import Testing
@testable import WhimperFlowKit

@Suite("Misheard-word fixer vocabulary")
struct TermMinerTests {
    @Test func minesRepeatedJargonOnly() {
        let texts = [
            "Push the JSON to GitHub and check the API.",
            "THE API is down, open GitHub.",
            "Parse the JSON again. SO annoying.",
            "SwiftUI once",
        ]
        let terms = TermMiner.terms(from: texts)
        #expect(Set(terms) == ["JSON", "GitHub", "API"])
        let initial = TermMiner.initialTerms(from: texts)
        #expect(initial.first == "repo")
        #expect(initial.filter { $0 == "JSON" }.count == 1)
    }

    @Test func vocabularyJoinsTermsAndDictionaryWithoutRepeats() {
        var settings = FlowSettings()
        settings.dictionary = [DictionaryEntry(pattern: "jason", replacement: "JSON"),
                               DictionaryEntry(pattern: "cake cluster", replacement: "k8s cluster")]
        settings.terms = ["repo", "json", " "]
        #expect(settings.correctionVocabulary == ["repo", "json", "k8s cluster"])
        #expect(settings.fixMishearsEnabled)
    }
}
