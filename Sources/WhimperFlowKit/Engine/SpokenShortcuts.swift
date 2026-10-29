import Foundation

/// Things people say naturally that should become formatting, with no command
/// word: "quote unquote I will" → "I will" in quotes, and spelled-out letters
/// ("n g i n x") joined into one word. Pure.
enum SpokenShortcuts {
    // MARK: - Quotes

    private static let closers: [[String]] = [["unquote"], ["end", "quote"], ["close", "quote"]]
    /// How far a "quote … unquote" pair may be apart, in tokens.
    private static let maxQuoteSpan = 40

    /// - "quote unquote X" / "quote on quote X" (how Parakeet hears it): quotes
    ///   X up to the next punctuation.
    /// - "quote X unquote" / "… end quote" / "… close quote": quotes X.
    /// A lone "quote" ("a quote from the book") is left alone.
    static func quotes(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            // "open quote … close quote" is SpokenPunctuation's.
            let afterOpen = i > 0 && tokens[i - 1].matchKey == "open"
            guard tokens[i].matchKey == "quote", !afterOpen else {
                out.append(tokens[i]); i += 1; continue
            }
            // "quote unquote X" or "quote on quote X".
            if let afterPhrase = match(["unquote"], in: tokens, from: i + 1) ?? match(["on", "quote"], in: tokens, from: i + 1) {
                var start = afterPhrase
                while start < tokens.count, isPausePunct(tokens[start]) { start += 1 }
                var end = start
                while end < tokens.count, !isBoundary(tokens[end]) { end += 1 }
                if end > start {
                    // A comma Parakeet put before the phrase stays ("he said, “I will”").
                    out.append(.open("\""))
                    out.append(contentsOf: tokens[start..<end])
                    out.append(.punct("\""))
                    i = end
                    continue
                }
            }
            // "quote X unquote".
            if let (closeAt, closeLength) = findCloser(in: tokens, after: i) {
                var inner = Array(tokens[(i + 1)..<closeAt])
                while let first = inner.first, isPausePunct(first) { inner.removeFirst() }
                while let last = inner.last, isPausePunct(last) { inner.removeLast() }
                if !inner.isEmpty {
                    out.append(.open("\""))
                    out.append(contentsOf: inner)
                    out.append(.punct("\""))
                    i = closeAt + closeLength
                    continue
                }
            }
            out.append(tokens[i])
            i += 1
        }
        return out
    }

    /// Index just past `words` if they follow `from` (commas between allowed).
    private static func match(_ words: [String], in tokens: [Token], from: Int) -> Int? {
        var j = from
        for word in words {
            while j < tokens.count, isPausePunct(tokens[j]) { j += 1 }
            guard j < tokens.count, tokens[j].matchKey == word else { return nil }
            j += 1
        }
        return j
    }

    private static func findCloser(in tokens: [Token], after open: Int) -> (Int, Int)? {
        let limit = min(tokens.count, open + 1 + maxQuoteSpan)
        var j = open + 1
        while j < limit {
            if tokens[j].matchKey == "quote" { return nil } // a second opener: not a pair
            for closer in closers where match(closer, in: tokens, from: j) != nil {
                if tokens[j].matchKey == closer[0] { return (j, closer.count) }
            }
            j += 1
        }
        return nil
    }

    private static func isPausePunct(_ token: Token) -> Bool {
        if case .punct(let p) = token { return p == "," || p == ":" }
        return false
    }

    private static func isBoundary(_ token: Token) -> Bool {
        switch token {
        case .punct, .newline, .paragraph: return true
        default: return false
        }
    }

    // MARK: - Spelled letters

    /// Three or more single letters/digits in a row ("n g i n x", "k 8 s")
    /// become one word: short runs read as acronyms (SFTP), longer ones as
    /// names (nginx). The dictionary runs after this, so it can still
    /// override the spelling.
    static func letters(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var run: [String] = []
        func flush() {
            let letterCount = run.filter { $0.first!.isLetter }.count
            if run.count >= 3, letterCount >= 2 {
                let joined = run.joined()
                out.append(.word(letterCount <= 4 ? joined.uppercased() : joined.lowercased()))
            } else {
                out.append(contentsOf: run.map(Token.word))
            }
            run = []
        }
        for token in tokens {
            if case .word(let w) = token, w.count == 1, let c = w.first, c.isLetter || c.isNumber {
                run.append(w)
            } else {
                flush()
                out.append(token)
            }
        }
        flush()
        return out
    }
}
