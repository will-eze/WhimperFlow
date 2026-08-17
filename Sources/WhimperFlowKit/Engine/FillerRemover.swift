import Foundation

/// Deletes configured filler phrases ("um", "you know", …) with word-boundary
/// semantics — "umbrella" is never touched because matching is whole-token.
enum FillerRemover {
    static func apply(to tokens: [Token], fillers: [String]) -> [Token] {
        let rules = fillers.compactMap { phrase -> PhraseRule? in
            let words = PhraseMatcher.words(of: phrase)
            guard !words.isEmpty else { return nil }
            return PhraseRule(phrase: words, output: [])
        }
        guard !rules.isEmpty else { return tokens }
        let fillerStartedUtterance = startsWithFiller(tokens, rules: rules)
        var out = PhraseMatcher.apply(rules, to: tokens)
        if fillerStartedUtterance {
            out = dropOrphanedPunctuation(out)
        }
        return out
    }

    /// True when a filler phrase matches at the very first token — the only
    /// case where trailing punctuation it carried ("Um, hello") gets orphaned.
    private static func startsWithFiller(_ tokens: [Token], rules: [PhraseRule]) -> Bool {
        for rule in rules {
            var matched = true
            for (offset, expected) in rule.phrase.enumerated() {
                guard offset < tokens.count, case .word(let w) = tokens[offset],
                      w.lowercased() == expected else {
                    matched = false
                    break
                }
            }
            if matched { return true }
        }
        return false
    }

    /// Removing "Um," leaves a comma with nothing before it; drop punctuation
    /// that ended up at the very start of the utterance.
    private static func dropOrphanedPunctuation(_ tokens: [Token]) -> [Token] {
        var out = tokens
        while let first = out.first {
            if case .punct(let p) = first, p != "\"" , p != "'" {
                out.removeFirst()
            } else {
                break
            }
        }
        return out
    }
}
