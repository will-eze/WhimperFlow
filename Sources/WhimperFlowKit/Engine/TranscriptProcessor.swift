import Foundation

/// Where and how the processed text will land.
public struct ProcessingContext: Sendable {
    public var mode: FormattingMode
    /// Text known to sit immediately before the insertion point (from the
    /// Accessibility API or our own last injection). Drives leading spacing
    /// and sentence capitalization. nil = unknown/empty field.
    public var precedingText: String?

    public init(mode: FormattingMode = .normal, precedingText: String? = nil) {
        self.mode = mode
        self.precedingText = precedingText
    }
}

public struct ProcessedResult: Equatable, Sendable {
    /// Text to inject, already including any needed leading space. Empty when
    /// the utterance was a command or noise.
    public var text: String
    public var command: EditCommand?

    public init(text: String = "", command: EditCommand? = nil) {
        self.text = text
        self.command = command
    }
}

/// The deterministic core: raw recognizer transcript in, polished text out.
/// Pure function of (raw, context, settings) — no clocks, no randomness, no IO.
public struct TranscriptProcessor: Sendable {
    public var settings: FlowSettings

    public init(settings: FlowSettings) {
        self.settings = settings
    }

    public func process(_ raw: String, context: ProcessingContext = ProcessingContext()) -> ProcessedResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ProcessedResult() }

        // 1. Whole-utterance spoken commands.
        if let command = CommandInterpreter.command(for: trimmed) {
            return ProcessedResult(command: command)
        }

        // 2. Whole-utterance snippet triggers.
        let normalized = CommandInterpreter.normalize(trimmed)
        if let snippet = settings.snippets.first(where: { CommandInterpreter.normalize($0.trigger) == normalized }) {
            let lead = Joiner.leadIn(for: context.precedingText)
            return ProcessedResult(text: (lead.needsSpace ? " " : "") + snippet.expansion)
        }

        // 3. Literal mode: verbatim recognizer output.
        if context.mode == .literal {
            let lead = Joiner.leadIn(for: context.precedingText)
            return ProcessedResult(text: (lead.needsSpace ? " " : "") + trimmed)
        }

        var tokens = Tokenizer.tokenize(trimmed)

        // 4. Code mode identifier operators ("snake case foo bar" → foo_bar).
        var identifierStyle: IdentifierStyle?
        if context.mode == .code, let op = CaseFormatter.detectOperator(in: tokens) {
            identifierStyle = op.style
            tokens.removeFirst(op.wordCount)
        }

        // 5. Fillers.
        if settings.removeFillers {
            tokens = FillerRemover.apply(to: tokens, fillers: settings.fillerPhrases)
        }

        // 6. Spoken punctuation & structure.
        if settings.spokenPunctuationEnabled {
            tokens = SpokenPunctuation.apply(to: tokens)
        }

        // 7. User dictionary.
        tokens = DictionaryReplacer.apply(to: tokens, entries: settings.dictionary)

        // 8. Numbers (prose modes only — code identifiers keep words).
        if settings.normalizeNumbers, identifierStyle == nil, context.mode != .code {
            tokens = NumberNormalizer.apply(to: tokens)
        }

        // 9. Pronoun "i" in prose modes.
        if context.mode == .normal || context.mode == .casual {
            tokens = CaseFormatter.fixPronounI(tokens)
        }

        // 10. Identifier transform collapses everything into one verbatim token.
        if let style = identifierStyle {
            tokens = [CaseFormatter.transform(tokens, style: style)]
        }

        // 11. Terminal period (normal prose only, ≥2 words, never after a
        // bare symbol/emoji token).
        let wordCount = tokens.reduce(into: 0) { count, t in if t.isWordLike { count += 1 } }
        if context.mode == .normal, settings.autoPunctuate, wordCount >= 2,
           let last = tokens.last, last.isWordLike, lastTokenTakesPeriod(last) {
            tokens.append(.punct("."))
        }

        // 12. Render with smart spacing.
        let capitalize = context.mode == .normal && settings.autoCapitalize
        let text = Joiner.render(tokens, options: .init(
            capitalizeSentences: capitalize,
            precedingText: context.precedingText
        ))
        return ProcessedResult(text: text)
    }

    /// Periods follow words, not bare symbols or emoji ("sounds good 🙂").
    private func lastTokenTakesPeriod(_ token: Token) -> Bool {
        let text: String
        switch token {
        case .word(let w): text = w
        case .verbatim(let v): text = v
        default: return false
        }
        return text.contains { $0.isLetter || $0.isNumber }
    }
}
