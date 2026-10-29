import Foundation

/// The per-span transforms for voice functions. Each takes the span's tokens and
/// returns tokens ready to be joined with the rest of the utterance. Pure.
enum FunctionFormatters {
    /// Join spoken letters/digits into one identifier ("k eight s" → "k8s").
    /// Output is lowercase by default; the `caps` modifier uppercases it.
    ///
    /// A run of recognized letters/digits glues together with no spaces; a word
    /// the letter table doesn't recognize is emitted as its own token so it keeps
    /// a space. That means a span that fails to close (recognizer missed
    /// "<trigger> stop") degrades to readable, spaced text instead of one giant
    /// run-on word.
    static func spell(_ tokens: [Token], caps: Bool) -> [Token] {
        var out: [Token] = []
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            out.append(.verbatim(caps ? run.uppercased() : run))
            run = ""
        }
        for token in tokens {
            switch token {
            case .word(let w):
                if let ch = VoiceFunction.spellChar(for: w) {
                    run += ch // already lowercase
                } else {
                    flushRun()
                    out.append(.verbatim(caps ? w.uppercased() : w.lowercased()))
                }
            case .verbatim(let v):
                run += caps ? v.uppercased() : v.lowercased()
            default:
                flushRun() // punctuation/structure has no meaning while spelling
            }
        }
        flushRun()
        return out
    }

    /// Uppercase the spoken words. Emitted as verbatim so nothing re-cases them.
    static func caps(_ tokens: [Token]) -> [Token] {
        tokens.map { token in
            switch token {
            case .word(let w): return .verbatim(w.uppercased())
            case .verbatim(let v): return .verbatim(v.uppercased())
            default: return token
            }
        }
    }

    /// Verbatim output: words become verbatim so the Joiner never re-cases them,
    /// while their normal left-to-right spacing is preserved.
    static func literal(_ tokens: [Token]) -> [Token] {
        tokens.map { token in
            if case .word(let w) = token { return .verbatim(w) }
            return token
        }
    }

    /// Operator/punctuation mode: spoken symbol names → tightly packed marks
    /// ("dash greater than" → "->"). No automatic spaces are inserted — say
    /// "space" for one. Emitted as a single verbatim token so a trailing operator
    /// survives the Joiner's trailing-glue cleanup.
    static func symbols(_ tokens: [Token]) -> [Token] {
        var s = ""
        for token in SymbolLexicon.apply(to: tokens) {
            switch token {
            case .word(let w), .verbatim(let w), .glue(let w), .punct(let w), .open(let w):
                s += w
            case .newline: s += "\n"
            case .paragraph: s += "\n\n"
            }
        }
        return s.isEmpty ? [] : [.verbatim(s)]
    }
}

/// Spoken names → literal symbols for `symbols` mode. Each match emits a `glue`
/// token so consecutive symbols concatenate with no spaces ("dash greater than"
/// → "->"). Words with no symbol name are left as ordinary words.
enum SymbolLexicon {
    static let rules: [PhraseRule] = {
        var r: [PhraseRule] = []
        func add(_ phrase: String, _ symbol: String) {
            r.append(PhraseRule(phrase: PhraseMatcher.words(of: phrase), output: [.glue(symbol)]))
        }

        // Comparison / assignment (multi-word forms first so they win).
        add("greater than or equal to", ">=")
        add("less than or equal to", "<=")
        add("greater than", ">")
        add("less than", "<")
        add("triple equals", "===")
        add("double equals", "==")
        add("not equals", "!=")
        add("not equal", "!=")
        add("equals equals", "==")
        add("equals", "=")
        add("equal sign", "=")

        // Arrows.
        add("right arrow", "->")
        add("left arrow", "<-")
        add("fat arrow", "=>")
        add("arrow", "->")

        // Arithmetic / bitwise.
        add("plus plus", "++")
        add("minus minus", "--")
        add("plus", "+")
        add("minus", "-")
        add("dash", "-")
        add("hyphen", "-")
        add("star", "*")
        add("asterisk", "*")
        add("times", "*")
        add("forward slash", "/")
        add("slash", "/")
        add("backslash", "\\")
        add("double pipe", "||")
        add("pipe", "|")
        add("vertical bar", "|")
        add("double ampersand", "&&")
        add("ampersand", "&")
        add("caret", "^")
        add("percent", "%")
        add("tilde", "~")

        // Punctuation / brackets.
        add("hash", "#")
        add("pound", "#")
        add("at sign", "@")
        add("at", "@")
        add("dot", ".")
        add("period", ".")
        add("comma", ",")
        add("colon", ":")
        add("semicolon", ";")
        add("question mark", "?")
        add("exclamation mark", "!")
        add("exclamation", "!")
        add("bang", "!")
        add("underscore", "_")
        add("dollar sign", "$")
        add("dollar", "$")
        add("open paren", "(")
        add("close paren", ")")
        add("open bracket", "[")
        add("close bracket", "]")
        add("open brace", "{")
        add("close brace", "}")

        // An explicit space, for when tight packing isn't wanted.
        add("space", " ")

        return r
    }()

    static func apply(to tokens: [Token]) -> [Token] {
        PhraseMatcher.apply(rules, to: tokens)
    }
}
