import Foundation

/// A rule that rewrites a spoken word sequence into replacement tokens.
struct PhraseRule {
    /// Normalized (lowercased) words to match, in order. Never empty.
    let phrase: [String]
    /// Tokens to emit instead; empty means "delete".
    let output: [Token]
    /// When true, the original (non-lowercased) words must match exactly.
    let caseSensitive: Bool
    let originalWords: [String]

    init(phrase: [String], output: [Token], caseSensitive: Bool = false, originalWords: [String] = []) {
        self.phrase = phrase
        self.output = output
        self.caseSensitive = caseSensitive
        self.originalWords = originalWords
    }
}

/// Longest-match-first, left-to-right, single-pass phrase rewriting over word
/// tokens. Deterministic by construction: rules are tried in descending phrase
/// length, ties broken by rule order.
enum PhraseMatcher {
    static func apply(_ rules: [PhraseRule], to tokens: [Token]) -> [Token] {
        guard !rules.isEmpty else { return tokens }
        let sorted = rules.enumerated().sorted {
            $0.element.phrase.count != $1.element.phrase.count
                ? $0.element.phrase.count > $1.element.phrase.count
                : $0.offset < $1.offset
        }.map(\.element)
        let maxLen = sorted.first?.phrase.count ?? 0

        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            guard case .word = tokens[i] else {
                out.append(tokens[i])
                i += 1
                continue
            }
            var matched = false
            for rule in sorted {
                guard rule.phrase.count <= maxLen,
                      let length = matchLength(rule, in: tokens, at: i) else { continue }
                out.append(contentsOf: rule.output)
                i += length
                matched = true
                break
            }
            if !matched {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    /// Number of consecutive word tokens consumed if `rule` matches at `start`.
    private static func matchLength(_ rule: PhraseRule, in tokens: [Token], at start: Int) -> Int? {
        var idx = start
        for (j, expected) in rule.phrase.enumerated() {
            guard idx < tokens.count, case .word(let w) = tokens[idx] else { return nil }
            if rule.caseSensitive, j < rule.originalWords.count {
                guard w == rule.originalWords[j] else { return nil }
            } else {
                guard w.lowercased() == expected else { return nil }
            }
            idx += 1
        }
        return idx - start
    }

    /// Splits a phrase string into normalized match words.
    static func words(of phrase: String) -> [String] {
        phrase.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-"))) }
            .filter { !$0.isEmpty }
    }

    static func originalWords(of phrase: String) -> [String] {
        phrase.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }
}
