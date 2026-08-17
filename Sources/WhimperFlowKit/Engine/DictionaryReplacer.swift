import Foundation

/// Applies user dictionary corrections. Output is `verbatim` so later stages
/// never re-case what the user taught ("k8s" stays "k8s" at sentence start? No —
/// verbatim text is trusted exactly as written).
enum DictionaryReplacer {
    static func apply(to tokens: [Token], entries: [DictionaryEntry]) -> [Token] {
        let rules = entries.compactMap { entry -> PhraseRule? in
            let words = PhraseMatcher.words(of: entry.pattern)
            guard !words.isEmpty, !entry.replacement.isEmpty else { return nil }
            return PhraseRule(
                phrase: words,
                output: [.verbatim(entry.replacement)],
                caseSensitive: entry.caseSensitive,
                originalWords: PhraseMatcher.originalWords(of: entry.pattern)
            )
        }
        guard !rules.isEmpty else { return tokens }
        return PhraseMatcher.apply(rules, to: tokens)
    }
}
