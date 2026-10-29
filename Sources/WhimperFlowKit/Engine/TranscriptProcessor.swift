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

        let tokens = Tokenizer.tokenize(trimmed)

        // 3. Split into inline function spans. Disabled or trigger-less → one
        // normal segment, so the ordinary pipeline below is byte-identical.
        let triggers = settings.voiceFunctionsEnabled
            ? VoiceFunction.triggerPhrases(for: settings.functionTriggerText)
            : []
        let segments = triggers.isEmpty
            ? [FunctionSegment(kind: .normal, tokens: tokens)]
            : FunctionSegmenter.segment(tokens, triggers: triggers)
        let hasFunctionSpan = segments.contains { $0.kind != .normal }

        // 4. Literal mode with no function spans keeps the whole-utterance
        // verbatim contract exactly (including spacing the tokenizer would peel).
        if context.mode == .literal, !hasFunctionSpan {
            let lead = Joiner.leadIn(for: context.precedingText)
            return ProcessedResult(text: (lead.needsSpace ? " " : "") + trimmed)
        }

        // 5. Process each segment into a token stream and concatenate.
        var out: [Token] = []
        for segment in segments {
            out.append(contentsOf: processSegment(segment, mode: context.mode))
        }

        // 6. Terminal period: normal prose only, when the final span is normal,
        // ≥2 words, and the last token is a word (never after a bare symbol,
        // spelled term, path, or quote).
        let lastKind = segments.last?.kind ?? .normal
        let wordCount = out.reduce(into: 0) { count, t in if t.isWordLike { count += 1 } }
        if context.mode == .normal, settings.autoPunctuate, lastKind == .normal, wordCount >= 2,
           let last = out.last, last.isWordLike, lastTokenTakesPeriod(last) {
            out.append(.punct("."))
        }

        // 7. Render with smart spacing.
        let capitalize = context.mode == .normal && settings.autoCapitalize
        let text = Joiner.render(out, options: .init(
            capitalizeSentences: capitalize,
            precedingText: context.precedingText
        ))
        return ProcessedResult(text: text)
    }

    /// Turns one segment into its processed token stream.
    private func processSegment(_ segment: FunctionSegment, mode: FormattingMode) -> [Token] {
        switch segment.kind {
        case .normal:
            return processProse(segment.tokens, mode: mode)
        case .code:
            return processProse(segment.tokens, mode: .code)
        case .spell(let caps):
            return FunctionFormatters.spell(segment.tokens, caps: caps)
        case .caps:
            return FunctionFormatters.caps(segment.tokens)
        case .literal:
            return FunctionFormatters.literal(segment.tokens)
        case .symbols:
            return FunctionFormatters.symbols(segment.tokens)
        case .quote:
            // Quote wraps prose; a verbatim (literal-mode) ambient still reads
            // its inner text as ordinary words.
            var inner = processProse(segment.tokens, mode: mode == .literal ? .normal : mode)
            inner.insert(.open("\""), at: 0)
            inner.append(.punct("\""))
            return inner
        }
    }

    /// The ordinary prose/code pipeline for a normal (or code-function) segment.
    /// Identical stage order to the pre-functions processor; the terminal period
    /// and final render are applied once at the utterance level.
    private func processProse(_ tokens: [Token], mode: FormattingMode) -> [Token] {
        if mode == .literal {
            return FunctionFormatters.literal(tokens)
        }
        var toks = tokens

        // Code mode identifier operators ("snake case foo bar" → foo_bar).
        var identifierStyle: IdentifierStyle?
        if mode == .code, let op = CaseFormatter.detectOperator(in: toks) {
            identifierStyle = op.style
            toks.removeFirst(op.wordCount)
        }

        if settings.removeFillers {
            toks = FillerRemover.apply(to: toks, fillers: settings.fillerPhrases)
        }
        if settings.spokenPunctuationEnabled {
            toks = SpokenShortcuts.quotes(toks)
            toks = SpokenPunctuation.apply(to: toks)
        }
        toks = SpokenShortcuts.letters(toks)
        toks = DictionaryReplacer.apply(to: toks, entries: settings.dictionary)
        if settings.normalizeNumbers, identifierStyle == nil, mode != .code {
            toks = NumberNormalizer.apply(to: toks)
        }
        if mode == .normal || mode == .casual {
            toks = CaseFormatter.fixPronounI(toks)
        }
        if let style = identifierStyle {
            toks = [CaseFormatter.transform(toks, style: style)]
        }
        return toks
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
