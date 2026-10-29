import Foundation

/// A contiguous run of the utterance and how it should be processed. Normal runs
/// go through the ordinary prose pipeline; function runs are transformed by
/// `FunctionFormatters`.
struct FunctionSegment: Equatable {
    enum Kind: Equatable {
        case normal
        case spell(caps: Bool)
        case quote
        case literal
        case code
        case caps
        case symbols
    }
    var kind: Kind
    var tokens: [Token]
}

/// Splits a tokenized utterance into function spans. Pure and deterministic.
///
/// Grammar: `<trigger> <name>` opens a span; `<trigger> stop` (or the end of the
/// utterance) closes it. `triggers` is a list of accepted trigger phrases — the
/// configured word plus known mis-hears (e.g. "flow"/"flu") — each only special
/// immediately before a function name or close word, so triggers stay usable as
/// ordinary words. Saying the trigger twice escapes it. Spans don't nest.
/// A stray `<trigger> stop` with no span open is swallowed (an orphaned close
/// must not leak into the text). Literal triggers are emitted as the words that
/// were actually spoken, so a mis-hear like "flu" is never rewritten to "flow".
enum FunctionSegmenter {
    static func segment(_ tokens: [Token], triggers rawTriggers: [[String]]) -> [FunctionSegment] {
        let triggers = rawTriggers.filter { !$0.isEmpty }
        guard !triggers.isEmpty else { return [FunctionSegment(kind: .normal, tokens: tokens)] }

        var segments: [FunctionSegment] = []
        var current: [Token] = []
        var i = 0

        func flushNormal() {
            if !current.isEmpty {
                segments.append(FunctionSegment(kind: .normal, tokens: current))
                current = []
            }
        }

        while i < tokens.count {
            guard let trigLen = matchAnyTrigger(triggers, in: tokens, at: i) else {
                current.append(tokens[i])
                i += 1
                continue
            }
            let afterTrigger = i + trigLen
            // Tolerate punctuation the engine may attach ("flow, spell").
            let nameStart = skipPunct(tokens, from: afterTrigger)

            // Doubling escape: the trigger immediately repeated → one literal trigger.
            if let secondLen = matchAnyTrigger(triggers, in: tokens, at: nameStart) {
                current.append(contentsOf: tokens[i..<afterTrigger]) // the words actually said
                i = nameStart + secondLen
                continue
            }

            // Stray close: "<trigger> stop" with no span open. Swallow it so an
            // orphaned or redundant close never leaks into the transcript.
            if matchesEndWord(in: tokens, at: nameStart) {
                i = nameStart + 1
                continue
            }

            // Trigger followed by a known function name → open a span.
            guard let (function, nameLen) = matchFunctionName(tokens, at: nameStart) else {
                // Not a function opener: the trigger is just an ordinary word,
                // emitted exactly as spoken (so "flu" is not rewritten to "flow").
                current.append(contentsOf: tokens[i..<afterTrigger])
                i = afterTrigger
                continue
            }

            var contentStart = skipPunct(tokens, from: nameStart + nameLen)
            var caps = false
            if function == .spell, contentStart < tokens.count, case .word(let w) = tokens[contentStart],
               VoiceFunction.spellCapsModifiers.contains(w.lowercased()) {
                caps = true
                contentStart = skipPunct(tokens, from: contentStart + 1)
            }
            let kind: FunctionSegment.Kind
            switch function {
            case .spell: kind = .spell(caps: caps)
            case .quote: kind = .quote
            case .literal: kind = .literal
            case .code: kind = .code
            case .caps: kind = .caps
            case .symbols: kind = .symbols
            }

            // Collect span content up to `<trigger> stop` (punctuation-tolerant),
            // else to the end of the utterance (implicit close).
            var j = contentStart
            var content: [Token] = []
            while j < tokens.count {
                if let tLen = matchAnyTrigger(triggers, in: tokens, at: j) {
                    let endStart = skipPunct(tokens, from: j + tLen)
                    if matchesEndWord(in: tokens, at: endStart) {
                        j = endStart + 1
                        break
                    }
                }
                content.append(tokens[j])
                j += 1
            }

            flushNormal()
            segments.append(FunctionSegment(kind: kind, tokens: content))
            i = j
        }

        flushNormal()
        return segments.isEmpty ? [FunctionSegment(kind: .normal, tokens: tokens)] : segments
    }

    // MARK: - Matching helpers

    /// First index at or after `index` that isn't a punctuation token. Lets the
    /// trigger/name/end still match when the engine attaches a comma or period.
    private static func skipPunct(_ tokens: [Token], from index: Int) -> Int {
        var i = index
        while i < tokens.count, case .punct = tokens[i] { i += 1 }
        return i
    }

    /// Length of the first trigger phrase that matches at `start`, if any.
    private static func matchAnyTrigger(_ triggers: [[String]], in tokens: [Token], at start: Int) -> Int? {
        for phrase in triggers {
            if let len = matchWords(phrase, in: tokens, at: start) { return len }
        }
        return nil
    }

    /// Length in tokens if the word phrase matches consecutive word tokens at `start`.
    private static func matchWords(_ phrase: [String], in tokens: [Token], at start: Int) -> Int? {
        guard !phrase.isEmpty else { return nil }
        var idx = start
        for expected in phrase {
            guard idx < tokens.count, case .word(let w) = tokens[idx], w.lowercased() == expected else {
                return nil
            }
            idx += 1
        }
        return idx - start
    }

    /// Whether the token at `index` is one of the accepted close words.
    private static func matchesEndWord(in tokens: [Token], at index: Int) -> Bool {
        guard index < tokens.count, case .word(let w) = tokens[index] else { return false }
        return VoiceFunction.endWords.contains(w.lowercased())
    }

    /// Matches a function name (longest phrase first) at `start`.
    private static func matchFunctionName(_ tokens: [Token], at start: Int) -> (VoiceFunction, Int)? {
        let sorted = VoiceFunction.aliases.sorted { $0.words.count > $1.words.count }
        for (words, function) in sorted {
            if let length = matchWords(words, in: tokens, at: start) {
                return (function, length)
            }
        }
        return nil
    }
}
