import Foundation

/// The spoken-punctuation vocabulary: fixed, ordered, deterministic.
/// Multi-word phrases always win over their single-word prefixes because the
/// matcher is longest-match-first.
enum SpokenPunctuation {
    static let rules: [PhraseRule] = {
        var r: [PhraseRule] = []
        func add(_ phrase: String, _ output: [Token]) {
            r.append(PhraseRule(phrase: PhraseMatcher.words(of: phrase), output: output))
        }

        // Terminal & clause punctuation (attach left).
        add("period", [.punct(".")])
        add("full stop", [.punct(".")])
        add("comma", [.punct(",")])
        add("question mark", [.punct("?")])
        add("exclamation point", [.punct("!")])
        add("exclamation mark", [.punct("!")])
        add("colon", [.punct(":")])
        add("semicolon", [.punct(";")])
        add("semi colon", [.punct(";")])
        add("ellipsis", [.punct("...")])
        add("dot dot dot", [.punct("...")])

        // Structure.
        add("new line", [.newline])
        add("next line", [.newline])
        add("new paragraph", [.paragraph])
        add("next paragraph", [.paragraph])

        // Pairs.
        add("open quote", [.open("\"")])
        add("close quote", [.punct("\"")])
        add("end quote", [.punct("\"")])
        add("open single quote", [.open("'")])
        add("close single quote", [.punct("'")])
        add("open parenthesis", [.open("(")])
        add("open paren", [.open("(")])
        add("close parenthesis", [.punct(")")])
        add("close paren", [.punct(")")])
        add("open bracket", [.open("[")])
        add("close bracket", [.punct("]")])
        add("open brace", [.open("{")])
        add("close brace", [.punct("}")])

        // Joiners (attach both sides).
        add("hyphen", [.glue("-")])
        add("underscore", [.glue("_")])
        add("forward slash", [.glue("/")])
        add("slash", [.glue("/")])
        add("backslash", [.glue("\\")])
        add("dot", [.glue(".")])
        add("point", [.glue(".")])
        add("at sign", [.glue("@")])

        // Standalone symbols.
        add("dash", [.word("—")])
        add("em dash", [.word("—")])
        add("ampersand", [.word("&")])
        add("asterisk", [.word("*")])
        add("plus sign", [.word("+")])
        add("equals sign", [.word("=")])
        add("dollar sign", [.open("$")])
        add("percent sign", [.punct("%")])
        add("number sign", [.open("#")])
        add("hashtag", [.open("#")])
        add("caret", [.word("^")])
        add("tilde", [.word("~")])
        add("apostrophe", [.glue("'")])
        add("degree sign", [.punct("°")])
        add("copyright sign", [.word("©")])
        add("trademark sign", [.word("™")])
        add("euro sign", [.open("€")])
        add("pound sterling sign", [.open("£")])

        // A few deterministic emoji, Wispr-style delight.
        add("smiley face", [.word("🙂")])
        add("smiley emoji", [.word("🙂")])
        add("winky face", [.word("😉")])
        add("sad face", [.word("🙁")])
        add("heart emoji", [.word("❤️")])
        add("thumbs up emoji", [.word("👍")])
        add("fire emoji", [.word("🔥")])
        add("laughing emoji", [.word("😂")])
        add("shrug emoji", [.word("🤷")])

        return r
    }()

    static func apply(to tokens: [Token]) -> [Token] {
        PhraseMatcher.apply(rules, to: tokens)
    }
}
