import Foundation

/// Renders a token stream to the final string, including the leading connector
/// (space or nothing) appropriate for the text already sitting at the insertion
/// point. All spacing rules live here.
enum Joiner {
    struct Options {
        var capitalizeSentences: Bool
        var precedingText: String?
    }

    /// Analysis of the text before the insertion point.
    struct LeadIn {
        var needsSpace: Bool
        var capitalize: Bool
    }

    static func leadIn(for preceding: String?) -> LeadIn {
        guard let preceding, !preceding.isEmpty else {
            return LeadIn(needsSpace: false, capitalize: true)
        }
        // Trailing plain spaces are ignored, but a newline is structural: new
        // line means no leading space and a fresh sentence.
        var tail = Substring(preceding)
        while tail.last == " " || tail.last == "\t" { tail = tail.dropLast() }
        if tail.isEmpty || tail.last == "\n" {
            return LeadIn(needsSpace: false, capitalize: true)
        }
        guard let lastNonWS = tail.last(where: { !$0.isWhitespace }) else {
            return LeadIn(needsSpace: false, capitalize: true)
        }
        let endsWithWhitespace = preceding.last!.isWhitespace
        let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
        let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}", "$", "#", "@", "_", "/", "-", "\n"]

        if sentenceTerminators.contains(lastNonWS) {
            return LeadIn(needsSpace: !endsWithWhitespace, capitalize: true)
        }
        if noSpaceAfter.contains(lastNonWS) {
            return LeadIn(needsSpace: false, capitalize: false)
        }
        return LeadIn(needsSpace: !endsWithWhitespace, capitalize: false)
    }

    static func render(_ rawTokens: [Token], options: Options) -> String {
        let tokens = cleanUp(rawTokens)
        guard !tokens.isEmpty else { return "" }

        let lead = leadIn(for: options.precedingText)
        var s = ""
        var pendingSpace = false      // a space is owed before the next word-like token
        var suppressSpace = !lead.needsSpace
        var capitalizeNext = lead.capitalize

        func spacer() {
            if pendingSpace || (!s.isEmpty && !suppressSpace) {
                // handled below; helper unused
            }
        }
        _ = spacer

        var first = true
        for token in tokens {
            switch token {
            case .word(let w):
                emitSpaceIfNeeded(&s, pending: &pendingSpace, suppress: &suppressSpace, first: &first, lead: lead)
                if capitalizeNext && options.capitalizeSentences {
                    s += CaseFormatterCapFirstPreserving(w)
                } else {
                    s += w
                }
                capitalizeNext = false
                pendingSpace = true
            case .verbatim(let v):
                guard !v.isEmpty else { continue }
                emitSpaceIfNeeded(&s, pending: &pendingSpace, suppress: &suppressSpace, first: &first, lead: lead)
                s += v
                capitalizeNext = false
                pendingSpace = true
            case .punct(let p):
                if first {
                    // Utterance starts with punctuation: attach directly to the
                    // preceding text, never with a space.
                    first = false
                }
                s += p
                pendingSpace = true
                suppressSpace = false
                if p == "." || p == "!" || p == "?" || p == "..." {
                    capitalizeNext = true
                }
            case .open(let o):
                emitSpaceIfNeeded(&s, pending: &pendingSpace, suppress: &suppressSpace, first: &first, lead: lead)
                s += o
                pendingSpace = false
                suppressSpace = true
            case .glue(let g):
                s += g
                pendingSpace = false
                suppressSpace = true
                first = false
            case .newline:
                s = trimTrailingSpaces(s)
                s += "\n"
                pendingSpace = false
                suppressSpace = true
                capitalizeNext = true
                first = false
            case .paragraph:
                s = trimTrailingSpaces(s)
                s += "\n\n"
                pendingSpace = false
                suppressSpace = true
                capitalizeNext = true
                first = false
            }
        }
        return s
    }

    private static func emitSpaceIfNeeded(_ s: inout String, pending: inout Bool, suppress: inout Bool, first: inout Bool, lead: LeadIn) {
        if first {
            if lead.needsSpace { s += " " }
            first = false
        } else if pending && !suppress {
            s += " "
        } else if pending && suppress {
            // space suppressed exactly once (after open/glue/newline)
        }
        pending = false
        suppress = false
    }

    private static func trimTrailingSpaces(_ s: String) -> String {
        var out = s
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Structural cleanup: collapse duplicate punctuation and let terminal
    /// punctuation absorb a preceding comma (", ." → "."). Leading punctuation
    /// is kept — dictating "comma which…" legitimately starts with one.
    static func cleanUp(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        for token in tokens {
            if case .punct(let p) = token, p != "\"", p != "'" {
                if case .punct(let prev) = out.last {
                    if prev == p {
                        continue // "?." style duplicates from engine + spoken punctuation
                    }
                    if prev == "," && (p == "." || p == "!" || p == "?") {
                        out.removeLast()
                    }
                }
            }
            out.append(token)
        }
        // Trailing "open" tokens or glue with nothing after are dropped.
        while let last = out.last {
            if case .open = last { out.removeLast(); continue }
            if case .glue = last { out.removeLast(); continue }
            break
        }
        return out
    }
}

/// Uppercases the first letter, preserving the rest ("hello" → "Hello",
/// "iPhone" → "IPhone" is avoided by only touching lowercase ASCII-style starts).
private func CaseFormatterCapFirstPreserving(_ w: String) -> String {
    guard let first = w.first, first.isLowercase else { return w }
    return String(first).uppercased() + w.dropFirst()
}
