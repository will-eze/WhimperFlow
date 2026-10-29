import Testing
@testable import WhimperFlowKit

@Suite("Spoken shortcuts")
struct SpokenShortcutsTests {
    private func run(_ raw: String) -> String {
        TranscriptProcessor(settings: FlowSettings()).process(raw).text
    }

    @Test func quoteUnquoteQuotesTheNextPhrase() {
        #expect(run("Then he said quote unquote I will.") == "Then he said \"I will\".")
        #expect(run("Then he said, quote on quote, I will, and left.") == "Then he said, \"I will\", and left.")
    }

    @Test func quotePairsWrapTheirInside() {
        #expect(run("then he said quote I will unquote and left") == "Then he said \"I will\" and left.")
        #expect(run("she wrote quote ship it end quote on the board") == "She wrote \"ship it\" on the board.")
    }

    @Test func aLoneQuoteIsAWord() {
        #expect(run("I like that quote from the book") == "I like that quote from the book.")
        #expect(run("remove the quotes from the page") == "Remove the quotes from the page.")
    }

    @Test func spelledLettersJoin() {
        #expect(run("install n g i n x on the server") == "Install nginx on the server.")
        #expect(run("connect over s f t p today") == "Connect over SFTP today.")
        #expect(run("deploy to k 8 s") == "Deploy to K8S.")
        #expect(run("I am a b student") == "I am a b student.")
    }
}
