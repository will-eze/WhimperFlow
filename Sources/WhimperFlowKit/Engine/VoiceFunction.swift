import Foundation

/// An inline "voice function": a span the user opens mid-utterance to switch how
/// the enclosed speech is transcribed. Spoken as `<trigger> <name> … <trigger> stop`
/// (or closed implicitly at the end of the utterance). The trigger word is only
/// "hot" immediately before one of these names, so the trigger stays usable as an
/// ordinary word everywhere else.
enum VoiceFunction: String, CaseIterable, Sendable {
    /// Join spoken letters/digits into a single word ("n g i n x" → "nginx").
    case spell
    /// Wrap the enclosed text in double quotes.
    case quote
    /// Emit the enclosed text verbatim — no filler/number/case/punctuation rules.
    case literal
    /// Force code mode for the span (identifier operators, no prose fixes).
    case code
    /// Uppercase the enclosed words.
    case caps
    /// Operator/punctuation mode: spoken symbol names → glued marks ("dash greater than" → "->").
    case symbols

    /// The canonical single-word name, used for recognition biasing.
    var canonicalName: String { rawValue }

    /// Known mis-hears of common default triggers, so a span still opens/closes
    /// when the recognizer mangles the trigger (e.g. "flow" → "flu"). Only ever
    /// consulted immediately before a function name or close word, so these stay
    /// usable as ordinary words everywhere else.
    static let triggerVariants: [String: [String]] = [
        "flow": ["flu", "flue", "flo", "floe"],
    ]

    /// All accepted trigger phrases for a configured trigger: the trigger itself
    /// plus any known mis-hears (single-word triggers only). Each phrase is a
    /// list of lowercased words.
    static func triggerPhrases(for trigger: String) -> [[String]] {
        let base = PhraseMatcher.words(of: trigger)
        guard !base.isEmpty else { return [] }
        var phrases = [base]
        if base.count == 1, let variants = triggerVariants[base[0]] {
            phrases.append(contentsOf: variants.map { [$0] })
        }
        return phrases
    }

    /// Spoken names → function, matched as a phrase right after the trigger.
    /// Order is irrelevant; the matcher tries the longest phrases first.
    static let aliases: [(words: [String], function: VoiceFunction)] = [
        (["spell"], .spell),
        (["quote"], .quote),
        (["quotes"], .quote),
        (["speech", "marks"], .quote),
        (["quotation", "marks"], .quote),
        (["quotation", "mark"], .quote),
        (["literal"], .literal),
        (["verbatim"], .literal),
        (["code"], .code),
        (["caps"], .caps),
        (["capitals"], .caps),
        (["all", "caps"], .caps),
        (["symbols"], .symbols),
        (["symbol"], .symbols),
        (["punctuation"], .symbols),
    ]

    /// The canonical closing keyword (used for display and recognition biasing).
    /// "stop" is used rather than "end" because the on-device recognizer reliably
    /// mis-hears spoken "end" as "and" — and "and" is a word you might genuinely
    /// dictate inside a span, so it must not double as the close.
    static let endWord = "stop"

    /// Words accepted as the close after the trigger (`<trigger> stop`). "end" is
    /// kept as an intuitive alias for when it's heard correctly; "and" is
    /// deliberately excluded so "<trigger> and" stays usable as span content.
    /// Only ever consulted immediately after the trigger.
    static let endWords: Set<String> = ["stop", "end"]

    /// Words that, right after `spell`, request uppercase output ("spell caps …").
    static let spellCapsModifiers: Set<String> = ["caps", "cap", "capital", "capitals", "uppercase", "upper"]

    // MARK: - Spell resolution

    /// Resolves one spoken token to the character(s) it contributes when spelling.
    /// Single letters/digits pass through; NATO words and common letter homophones
    /// map to their letter; number words map to their digit. Returns nil when the
    /// token isn't a recognizable letter/digit (the caller then joins it verbatim).
    static func spellChar(for word: String) -> String? {
        let w = word.lowercased()
        // Single letters/digits pass through lowercased — the recognizer emits
        // spelled letters capitalized ("N", "G", …), so default output is lower.
        if w.count == 1, let c = w.first, c.isLetter || c.isNumber { return w }
        return spellMap[w]
    }

    /// NATO alphabet, digit words, and common letter homophones the on-device
    /// recognizer emits when a single letter is spoken.
    private static let spellMap: [String: String] = {
        var m: [String: String] = [:]
        // Digits.
        let digits = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
                      "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"]
        m.merge(digits) { a, _ in a }
        // NATO phonetic alphabet.
        let nato = ["alpha": "a", "alfa": "a", "bravo": "b", "charlie": "c", "delta": "d",
                    "echo": "e", "foxtrot": "f", "golf": "g", "hotel": "h", "india": "i",
                    "juliet": "j", "juliett": "j", "kilo": "k", "lima": "l", "mike": "m",
                    "november": "n", "oscar": "o", "papa": "p", "quebec": "q", "romeo": "r",
                    "sierra": "s", "tango": "t", "uniform": "u", "victor": "v", "whiskey": "w",
                    "xray": "x", "x-ray": "x", "yankee": "y", "zulu": "z"]
        m.merge(nato) { a, _ in a }
        // Letter homophones (only ever consulted inside an explicit spell span).
        let homophones = ["ay": "a", "bee": "b", "cee": "c", "see": "c", "sea": "c",
                          "dee": "d", "ee": "e", "ef": "f", "eff": "f", "gee": "g",
                          "aitch": "h", "haitch": "h", "jay": "j", "kay": "k",
                          "el": "l", "ell": "l", "em": "m", "en": "n", "oh": "o",
                          "pee": "p", "pea": "p", "cue": "q", "queue": "q",
                          "ar": "r", "es": "s", "ess": "s", "tee": "t", "tea": "t",
                          "vee": "v", "ex": "x", "wye": "y", "zee": "z", "zed": "z"]
        m.merge(homophones) { a, _ in a }
        return m
    }()
}
