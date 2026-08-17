import Foundation

/// Converts spoken number phrases to written form using fixed AP-style rules:
/// values under 10 stay as words ("five ideas"), 10 and up become numerals,
/// multi-word numbers always become numerals, and currency/percent phrases are
/// symbolized ("twenty five dollars" → "$25", "fifty percent" → "50%").
enum NumberNormalizer {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    private static let ordinalUnits: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19,
    ]
    private static let ordinalTens: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]
    private static let ordinalScales: [String: Int] = [
        "hundredth": 100, "thousandth": 1_000, "millionth": 1_000_000,
    ]

    private struct ParsedNumber {
        var value: Int
        var decimalDigits: String?
        var wordCount: Int       // number of word tokens consumed
        var tokenCount: Int      // total tokens consumed (incl. glue for decimals)
        var isOrdinal: Bool
        var sawMultipleWords: Bool
    }

    static func apply(to tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            guard case .word = tokens[i], let parsed = parseNumber(tokens, at: i) else {
                out.append(tokens[i])
                i += 1
                continue
            }
            let after = i + parsed.tokenCount
            let unit = after < tokens.count ? unitWord(tokens[after]) : nil

            if let unit {
                i = emitUnit(parsed, unit: unit, tokens: tokens, at: after, into: &out)
            } else if parsed.isOrdinal {
                if parsed.value >= 10 {
                    out.append(.word(ordinalString(parsed.value)))
                } else {
                    out.append(contentsOf: tokens[i..<after])
                }
                i = after
            } else if parsed.decimalDigits != nil || parsed.sawMultipleWords || parsed.value >= 10 {
                out.append(.word(numberString(parsed)))
                i = after
            } else {
                out.append(contentsOf: tokens[i..<after])
                i = after
            }
        }
        return out
    }

    // MARK: - Unit handling

    private enum Unit: String {
        case dollars, cents, percent, euros
    }

    private static func unitWord(_ token: Token) -> Unit? {
        guard case .word(let w) = token else { return nil }
        switch w.lowercased() {
        case "dollar", "dollars": return .dollars
        case "cent", "cents": return .cents
        case "percent": return .percent
        case "euro", "euros": return .euros
        default: return nil
        }
    }

    /// Emits the symbolized form and returns the next scan index.
    private static func emitUnit(_ parsed: ParsedNumber, unit: Unit, tokens: [Token], at unitIndex: Int, into out: inout [Token]) -> Int {
        var next = unitIndex + 1
        switch unit {
        case .percent:
            out.append(.word(numberString(parsed) + "%"))
        case .euros:
            out.append(.word("€" + numberString(parsed)))
        case .cents:
            out.append(.word(numberString(parsed) + "¢"))
        case .dollars:
            // Optional "and <n> cents" continuation.
            if parsed.decimalDigits == nil,
               unitIndex + 1 < tokens.count,
               case .word(let andWord) = tokens[unitIndex + 1], andWord.lowercased() == "and",
               let centsParsed = parseNumber(tokens, at: unitIndex + 2),
               centsParsed.decimalDigits == nil, centsParsed.value < 100,
               unitIndex + 2 + centsParsed.tokenCount < tokens.count,
               unitWord(tokens[unitIndex + 2 + centsParsed.tokenCount]) == .cents {
                let cents = String(format: "%02d", centsParsed.value)
                out.append(.word("$" + groupedInteger(parsed.value) + "." + cents))
                next = unitIndex + 3 + centsParsed.tokenCount
            } else {
                out.append(.word("$" + numberString(parsed)))
            }
        }
        return next
    }

    // MARK: - Parsing

    /// Parses a spoken number starting at `start`. Grammar: standard English
    /// number words with scales and optional "and" ("one hundred and five"),
    /// a trailing ordinal word, or "point" followed by digit words. Also accepts
    /// an already-digitized token ("25" or "25,000").
    private static func parseNumber(_ tokens: [Token], at start: Int) -> ParsedNumber? {
        var i = start
        var total = 0
        var current = 0
        var wordCount = 0
        var sawNumberWord = false
        var isOrdinal = false

        loop: while i < tokens.count {
            guard case .word(let raw) = tokens[i] else { break }
            let w = raw.lowercased()

            // Digit token, only valid as the sole "word" of the run.
            if !sawNumberWord, let digits = digitValue(w) {
                current = digits
                sawNumberWord = true
                wordCount += 1
                i += 1
                break loop
            }

            if let v = wordValue(w) {
                // Reject "twenty three" after "three" style repeats gracefully:
                // additive semantics are handled below; ill-formed runs just end.
                if v.isScale {
                    guard sawNumberWord || v.value == 100 else { break loop }
                    if v.value == 100 {
                        current = max(current, 1) * 100
                    } else {
                        total += max(current, 1) * v.value
                        current = 0
                    }
                } else {
                    if v.value < 10 && current % 10 != 0 { break loop }
                    if v.value >= 10 && v.value <= 19 && current != 0 && current % 100 != 0 { break loop }
                    current += v.value
                }
                sawNumberWord = true
                wordCount += 1
                i += 1
                continue
            }

            if let ord = ordinalValue(w), sawNumberWord || ord.standalone {
                if ord.isScale {
                    current = max(current, 1) * ord.value
                } else {
                    current += ord.value
                }
                isOrdinal = true
                sawNumberWord = true
                wordCount += 1
                i += 1
                break loop
            }

            if w == "and", sawNumberWord, currentEndsScale(tokens, before: i) {
                // "one hundred and five" — consume the "and" only if a number follows.
                if i + 1 < tokens.count, case .word(let nextW) = tokens[i + 1],
                   wordValue(nextW.lowercased())?.isScale == false || ordinalValue(nextW.lowercased()) != nil {
                    wordCount += 1
                    i += 1
                    continue
                }
            }
            break loop
        }

        guard sawNumberWord else { return nil }
        var result = ParsedNumber(
            value: total + current,
            decimalDigits: nil,
            wordCount: wordCount,
            tokenCount: i - start,
            isOrdinal: isOrdinal,
            sawMultipleWords: wordCount >= 2
        )

        // Decimal continuation: glue(".") from spoken "point", or the word "point".
        if !isOrdinal, i < tokens.count {
            var j = i
            var isDecimal = false
            if case .glue(".") = tokens[j] { isDecimal = true; j += 1 }
            else if case .word(let pw) = tokens[j], pw.lowercased() == "point" { isDecimal = true; j += 1 }
            if isDecimal {
                var digits = ""
                while j < tokens.count, case .word(let dw) = tokens[j],
                      let d = units[dw.lowercased()], d <= 9 {
                    digits.append(String(d))
                    j += 1
                }
                if !digits.isEmpty {
                    result.decimalDigits = digits
                    result.tokenCount = j - start
                    result.sawMultipleWords = true
                }
            }
        }
        return result
    }

    private static func currentEndsScale(_ tokens: [Token], before i: Int) -> Bool {
        guard i > 0, case .word(let w) = tokens[i - 1] else { return false }
        return scales[w.lowercased()] != nil
    }

    private struct WordNumber { var value: Int; var isScale: Bool }

    private static func wordValue(_ w: String) -> WordNumber? {
        if let v = units[w] { return WordNumber(value: v, isScale: false) }
        if let v = tens[w] { return WordNumber(value: v, isScale: false) }
        if let v = scales[w] { return WordNumber(value: v, isScale: true) }
        // Hyphenated compounds: "twenty-five".
        if w.contains("-") {
            let parts = w.split(separator: "-").map(String.init)
            if parts.count == 2, let t = tens[parts[0]], let u = units[parts[1]], u < 10 {
                return WordNumber(value: t + u, isScale: false)
            }
        }
        return nil
    }

    private struct OrdinalWord { var value: Int; var isScale: Bool; var standalone: Bool }

    private static func ordinalValue(_ w: String) -> OrdinalWord? {
        if let v = ordinalUnits[w] { return OrdinalWord(value: v, isScale: false, standalone: true) }
        if let v = ordinalTens[w] { return OrdinalWord(value: v, isScale: false, standalone: true) }
        if let v = ordinalScales[w] { return OrdinalWord(value: v, isScale: true, standalone: false) }
        if w.contains("-") {
            let parts = w.split(separator: "-").map(String.init)
            if parts.count == 2, let t = tens[parts[0]], let u = ordinalUnits[parts[1]], u < 10 {
                return OrdinalWord(value: t + u, isScale: false, standalone: true)
            }
        }
        return nil
    }

    private static func digitValue(_ w: String) -> Int? {
        let cleaned = w.replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, cleaned.allSatisfy(\.isNumber) else { return nil }
        return Int(cleaned)
    }

    // MARK: - Formatting

    private static func numberString(_ parsed: ParsedNumber) -> String {
        var s = groupedInteger(parsed.value)
        if let d = parsed.decimalDigits { s += "." + d }
        return s
    }

    /// Fixed en-US comma grouping for 1,000 and above.
    static func groupedInteger(_ value: Int) -> String {
        var digits = Array(String(value))
        guard digits.count > 3 else { return String(value) }
        var insertAt = digits.count - 3
        while insertAt > 0 {
            digits.insert(",", at: insertAt)
            insertAt -= 3
        }
        return String(digits)
    }

    static func ordinalString(_ value: Int) -> String {
        let suffix: String
        let mod100 = value % 100
        if (11...13).contains(mod100) {
            suffix = "th"
        } else {
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return groupedInteger(value) + suffix
    }
}
