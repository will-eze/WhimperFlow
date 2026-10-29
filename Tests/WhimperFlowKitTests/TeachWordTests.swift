import Testing
@testable import WhimperFlowKit

@Suite("Teaching a word")
struct TeachWordTests {
    @Test func patternDropsPunctuationAndCase() {
        #expect(TeachWord.pattern(from: "Wimperflow,") == "wimperflow")
        #expect(TeachWord.pattern(from: "“K8 cluster.”") == "k8 cluster")
        #expect(TeachWord.pattern(from: " ... ") == "")
    }

    @Test func teachAddsThenUpdates() {
        var settings = FlowSettings()
        let before = settings.dictionary.count
        let added = settings.teach(heard: "ash s", write: "Ash S.")
        #expect(added)
        #expect(settings.dictionary.count == before + 1)
        #expect(settings.dictionary.first?.replacement == "Ash S.")
        let updated = settings.teach(heard: "Ash S", write: "Ash Sharma")
        #expect(updated)
        #expect(settings.dictionary.count == before + 1)
        #expect(settings.dictionary.first?.replacement == "Ash Sharma")
        let blank = settings.teach(heard: "", write: "x")
        let same = settings.teach(heard: "same", write: "same")
        #expect(!blank && !same)
    }

    @Test func taughtWordFixesTheDictation() {
        var settings = FlowSettings()
        settings.teach(heard: "wimperflow", write: "WhimperFlow")
        let text = TranscriptProcessor(settings: settings).process("open wimperflow settings").text
        #expect(text.contains("WhimperFlow"))
    }
}
