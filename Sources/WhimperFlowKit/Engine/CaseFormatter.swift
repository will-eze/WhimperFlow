import Foundation

/// Identifier style operators available in code mode: dictating
/// "snake case user account id" yields `user_account_id`.
public enum IdentifierStyle: String, CaseIterable, Sendable {
    case camel, snake, kebab, pascal, dot
    case allCaps, lowercase, titleCase

    /// Operator phrases, matched as an utterance prefix in code mode.
    static let operators: [([String], IdentifierStyle)] = [
        (["camel", "case"], .camel),
        (["snake", "case"], .snake),
        (["kebab", "case"], .kebab),
        (["dash", "case"], .kebab),
        (["pascal", "case"], .pascal),
        (["dot", "case"], .dot),
        (["all", "caps"], .allCaps),
        (["uppercase"], .allCaps),
        (["all", "lowercase"], .lowercase),
        (["title", "case"], .titleCase),
    ]
}

enum CaseFormatter {
    /// Detects a leading identifier-style operator in code mode. Returns the
    /// style and how many word tokens to strip.
    static func detectOperator(in tokens: [Token]) -> (style: IdentifierStyle, wordCount: Int)? {
        for (phrase, style) in IdentifierStyle.operators {
            var idx = 0
            var matched = true
            for expected in phrase {
                guard idx < tokens.count, case .word(let w) = tokens[idx], w.lowercased() == expected else {
                    matched = false
                    break
                }
                idx += 1
            }
            // Require content after the operator so "snake case" alone stays text.
            if matched, idx < tokens.count { return (style, idx) }
        }
        return nil
    }

    /// Collapses the remaining tokens into a single identifier.
    static func transform(_ tokens: [Token], style: IdentifierStyle) -> Token {
        var parts: [String] = []
        for token in tokens {
            switch token {
            case .word(let w):
                parts.append(contentsOf: subwords(of: w))
            case .verbatim(let v):
                parts.append(contentsOf: subwords(of: v))
            default:
                continue // punctuation has no meaning inside an identifier
            }
        }
        guard !parts.isEmpty else { return .verbatim("") }

        let result: String
        switch style {
        case .camel:
            result = (parts.first!.lowercased() + parts.dropFirst().map(capitalizedFirst).joined())
        case .pascal:
            result = parts.map(capitalizedFirst).joined()
        case .snake:
            result = parts.map { $0.lowercased() }.joined(separator: "_")
        case .kebab:
            result = parts.map { $0.lowercased() }.joined(separator: "-")
        case .dot:
            result = parts.map { $0.lowercased() }.joined(separator: ".")
        case .allCaps:
            result = parts.map { $0.uppercased() }.joined(separator: " ")
        case .lowercase:
            result = parts.map { $0.lowercased() }.joined(separator: " ")
        case .titleCase:
            result = parts.map(capitalizedFirst).joined(separator: " ")
        }
        return .verbatim(result)
    }

    private static func subwords(of s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map(String.init)
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst().lowercased()
    }

    /// English pronoun fix, applied in prose modes: "i" → "I", "i'm" → "I'm".
    static func fixPronounI(_ tokens: [Token]) -> [Token] {
        tokens.map { token in
            guard case .word(let w) = token else { return token }
            let lower = w.lowercased()
            if lower == "i" { return .word("I") }
            for suffix in ["'m", "'ll", "'ve", "'d"] where lower == "i" + suffix {
                return .word("I" + w.dropFirst())
            }
            return token
        }
    }
}
