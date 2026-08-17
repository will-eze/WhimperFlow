import Foundation

/// The unit the pipeline operates on. Spacing behavior is encoded in the case:
/// `word` is space-separated, `punct` attaches to the left, `open` attaches to
/// the right, `glue` attaches on both sides, `verbatim` is user-supplied text
/// that must never be case-transformed.
public enum Token: Equatable, Sendable {
    case word(String)
    case verbatim(String)
    case punct(String)
    case open(String)
    case glue(String)
    case newline
    case paragraph

    /// Lowercased, punctuation-free form used for phrase matching; nil for
    /// tokens that never participate in matching.
    var matchKey: String? {
        switch self {
        case .word(let w): return w.lowercased()
        default: return nil
        }
    }

    var isWordLike: Bool {
        switch self {
        case .word, .verbatim, .glue: return true
        default: return false
        }
    }
}

/// Splits raw recognizer output into tokens, peeling punctuation the OS engine
/// attaches to words ("Hello," → word("Hello") + punct(",")).
public enum Tokenizer {
    static let leftAttaching: Set<Character> = [",", ".", "!", "?", ":", ";", ")", "]", "}", "…", "%", "\u{201D}", "\u{2019}"]
    static let rightAttaching: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "$", "#", "@", "¿", "¡"]

    public static func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        for chunk in raw.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if chunk == "\n" { tokens.append(.newline); continue }
            // The recognizer never emits newlines mid-string in practice, but be safe.
            for line in splitKeepingNewlines(String(chunk)) {
                if line == "\n" { tokens.append(.newline); continue }
                tokenizeChunk(line, into: &tokens)
            }
        }
        return tokens
    }

    private static func splitKeepingNewlines(_ s: String) -> [String] {
        guard s.contains("\n") else { return [s] }
        var out: [String] = []
        var current = ""
        for ch in s {
            if ch == "\n" {
                if !current.isEmpty { out.append(current); current = "" }
                out.append("\n")
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func tokenizeChunk(_ chunk: String, into tokens: inout [Token]) {
        var body = Substring(chunk)
        var leading: [Token] = []
        var trailing: [Token] = []

        while let first = body.first, rightAttaching.contains(first) {
            leading.append(.open(normalizeQuote(String(first))))
            body = body.dropFirst()
        }
        while let last = body.last, leftAttaching.contains(last), body.count > 1 || !leading.isEmpty || !last.isLetter {
            // Peel trailing punctuation, but keep a bare "." style token intact below.
            trailing.insert(.punct(normalizeQuote(String(last))), at: 0)
            body = body.dropLast()
            if body.isEmpty { break }
        }
        if !body.isEmpty {
            leading.forEach { tokens.append($0) }
            tokens.append(.word(String(body)))
            trailing.forEach { tokens.append($0) }
        } else {
            // Chunk was pure punctuation.
            leading.forEach { tokens.append($0) }
            trailing.forEach { tokens.append($0) }
        }
    }

    /// Curly quotes from the recognizer are normalized to straight quotes so the
    /// output is stable regardless of engine styling.
    private static func normalizeQuote(_ s: String) -> String {
        switch s {
        case "\u{201C}", "\u{201D}": return "\""
        case "\u{2018}", "\u{2019}": return "'"
        default: return s
        }
    }
}
