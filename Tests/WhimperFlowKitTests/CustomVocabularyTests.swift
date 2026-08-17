import Testing
@testable import WhimperFlowKit

@Suite("Custom vocabulary")
struct CustomVocabularyTests {
    private func settings(
        dictionary: [DictionaryEntry] = [],
        snippets: [Snippet] = []
    ) -> FlowSettings {
        var s = FlowSettings()
        s.dictionary = dictionary
        s.snippets = snippets
        return s
    }

    @Test func emptyVocabularyProducesNoPhrases() {
        #expect(CustomVocabulary.phrases(from: settings()).isEmpty)
    }

    @Test func teachesBothSpellingAndMisheardPattern() {
        let phrases = CustomVocabulary.phrases(from: settings(
            dictionary: [DictionaryEntry(pattern: "k eight s", replacement: "k8s")]
        ))
        #expect(phrases == ["k8s", "k eight s"])
    }

    @Test func includesSnippetTriggers() {
        let phrases = CustomVocabulary.phrases(from: settings(
            snippets: [Snippet(trigger: "insert my signature", expansion: "Best,\nWill")]
        ))
        #expect(phrases == ["insert my signature"])
    }

    @Test func dropsBlanksAndCaseInsensitiveDuplicates() {
        let phrases = CustomVocabulary.phrases(from: settings(
            dictionary: [
                DictionaryEntry(pattern: "jira", replacement: "Jira"),
                DictionaryEntry(pattern: "  ", replacement: "JIRA"),
            ]
        ))
        #expect(phrases == ["Jira"])
    }

    @Test func orderIsStableForContentHashing() {
        let s = settings(
            dictionary: [
                DictionaryEntry(pattern: "gh", replacement: "GitHub"),
                DictionaryEntry(pattern: "whimper flow", replacement: "WhimperFlow"),
            ],
            snippets: [Snippet(trigger: "sign off", expansion: "Cheers")]
        )
        #expect(CustomVocabulary.phrases(from: s) == CustomVocabulary.phrases(from: s))
        #expect(CustomVocabulary.phrases(from: s) == ["GitHub", "gh", "WhimperFlow", "whimper flow", "sign off"])
    }
}
