import Foundation

/// The key the user holds to dictate.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case rightControl
    case leftControl
    /// Fn held together with Control (either side). A genuine two-key
    /// chord rather than a single key's own gesture: macOS cancels fn's
    /// tap-based system action (Emoji & Symbols / input source switch)
    /// itself the moment another key is pressed while fn is held, so this
    /// combo coexists with that system behavior with no special handling
    /// needed — a lone fn tap still reaches the system untouched.
    case fnControl
    /// A user-recorded non-modifier key; the key code lives in
    /// `FlowSettings.customKeyCode`.
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fn: return "fn (Globe)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        case .leftControl: return "Left ⌃"
        case .fnControl: return "fn + Control"
        case .custom: return "Custom key…"
        }
    }

    /// Modifier keys arrive as `flagsChanged` events; a custom key arrives as
    /// `keyDown`/`keyUp`.
    public var isModifier: Bool { self != .custom }

    /// macOS virtual key code reported in `flagsChanged` events.
    /// `.custom` has no fixed code (-1); read `FlowSettings.customKeyCode`.
    /// `.fnControl` is a chord with no single code — `HotkeyMonitor` watches
    /// its two flags directly instead of consulting this property.
    public var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case .leftControl: return 59
        case .fnControl: return -1
        case .custom: return -1
        }
    }
}

/// How processed text is delivered into the frontmost app.
public enum InjectionMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Pasteboard + synthetic ⌘V, clipboard restored afterwards. Fast for long text.
    case paste
    /// Synthetic unicode key events. Leaves the clipboard untouched.
    case type
    /// `type` for short utterances, `paste` for long ones.
    case auto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .paste: return "Paste (restores clipboard)"
        case .type: return "Simulated typing"
        case .auto: return "Automatic"
        }
    }
}

/// Output style applied by the deterministic formatter.
public enum FormattingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Sentence capitalization, terminal punctuation, prose spacing.
    case normal
    /// Chat style: no automatic capitalization or terminal period.
    case casual
    /// Editors/terminals: identifier operators (camel/snake/kebab…), no prose fixes.
    case code
    /// Verbatim recognizer output, untouched.
    case literal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .normal: return "Normal (prose)"
        case .casual: return "Casual (chat)"
        case .code: return "Code"
        case .literal: return "Literal"
        }
    }
}

/// A user-taught correction: whenever `pattern` is heard, emit `replacement` verbatim.
public struct DictionaryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The phrase as the recognizer tends to hear it, e.g. "jira" or "k eight s".
    public var pattern: String
    /// Exactly what should be written, e.g. "Jira" or "k8s".
    public var replacement: String
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), pattern: String, replacement: String, caseSensitive: Bool = false) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.caseSensitive = caseSensitive
    }
}

/// A spoken trigger phrase that expands to canned text.
public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// e.g. "insert my signature"
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// Per-application behavior override, keyed by bundle identifier.
public struct AppProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    /// Human-readable app name, for display only.
    public var appName: String
    public var mode: FormattingMode
    /// When false, dictation is disabled entirely while this app is frontmost.
    public var enabled: Bool

    public init(id: UUID = UUID(), bundleID: String, appName: String, mode: FormattingMode = .normal, enabled: Bool = true) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.mode = mode
        self.enabled = enabled
    }
}

/// The complete, versioned user configuration. Everything the deterministic
/// pipeline does is driven by this value.
public struct FlowSettings: Codable, Equatable, Sendable {
    public var version: Int

    // Input
    public var hotkey: HotkeyChoice
    /// Virtual key code for `HotkeyChoice.custom` (nil until one is recorded).
    /// Optional so settings saved by older versions still decode.
    public var customKeyCode: Int64?
    /// Human-readable name of the recorded custom key, e.g. "F13".
    public var customKeyLabel: String?
    /// Quick-tap of the hotkey toggles hands-free dictation on/off.
    public var tapToToggleEnabled: Bool
    /// Hands-free mode stops after this many seconds of silence (0 disables).
    public var silenceAutoStopSeconds: Double
    /// Audio input device UID; nil = system default.
    public var microphoneUID: String?
    /// Apple's on-device voice-processing DSP (echo cancellation + noise
    /// suppression) on the mic input. Off by default: on some Macs the
    /// voice-processed input delivers a multi-channel, near-silent stream
    /// that breaks recognition entirely. Optional so settings saved by older
    /// versions still decode; nil means off.
    public var voiceProcessing: Bool?
    /// BCP-47 locale for recognition, e.g. "en-US".
    public var localeIdentifier: String

    // Output
    public var injectionMethod: InjectionMethod
    public var defaultMode: FormattingMode

    // Formatting toggles
    public var removeFillers: Bool
    public var fillerPhrases: [String]
    public var spokenPunctuationEnabled: Bool
    /// Ask the OS engine for punctuation and add a terminal period when missing.
    public var autoPunctuate: Bool
    public var autoCapitalize: Bool
    public var normalizeNumbers: Bool
    /// Inline voice functions (`flow spell …`, `flow quote …`, etc.). Optional so
    /// settings saved by older versions still decode; nil means enabled.
    public var voiceFunctions: Bool?
    /// The word that opens a voice function (only "hot" before a function name).
    /// Optional for back-compat; nil/empty falls back to "flow".
    public var functionTrigger: String?

    // Personalization
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    public var appProfiles: [AppProfile]

    // App behavior
    public var playSounds: Bool
    public var launchAtLogin: Bool
    public var showHUD: Bool
    public var historyEnabled: Bool
    /// Words-per-minute assumed for the "time saved vs typing" statistic.
    public var typingWPMBaseline: Double

    public init() {
        version = 1
        hotkey = .rightCommand
        customKeyCode = nil
        customKeyLabel = nil
        tapToToggleEnabled = true
        silenceAutoStopSeconds = 8
        microphoneUID = nil
        voiceProcessing = nil
        localeIdentifier = "en-US"
        injectionMethod = .auto
        defaultMode = .normal
        removeFillers = true
        fillerPhrases = FlowSettings.defaultFillers
        spokenPunctuationEnabled = true
        autoPunctuate = true
        autoCapitalize = true
        normalizeNumbers = true
        voiceFunctions = true
        functionTrigger = "flow"
        dictionary = []
        snippets = []
        appProfiles = []
        playSounds = true
        launchAtLogin = false
        showHUD = true
        historyEnabled = true
        typingWPMBaseline = 45
    }

    public static let defaultFillers: [String] = [
        "um", "uh", "uhm", "erm", "hmm", "you know", "i mean", "sort of like", "kind of like",
    ]

    /// Deterministic recognition biasing: the phrases fed to
    /// `SFSpeechRecognitionRequest.contextualStrings` (Apple caps usefulness ~100).
    public func contextualStrings(limit: Int = 100) -> [String] {
        var phrases: [String] = []
        // Bias the recognizer toward the function trigger + names so spans open
        // reliably ("flow spell", "flow quote", …, "flow stop").
        if voiceFunctionsEnabled {
            let trigger = functionTriggerText
            phrases.append(trigger)
            phrases.append("\(trigger) \(VoiceFunction.endWord)")
            for function in VoiceFunction.allCases {
                phrases.append("\(trigger) \(function.canonicalName)")
            }
        }
        for entry in dictionary {
            phrases.append(entry.replacement)
            if entry.pattern.caseInsensitiveCompare(entry.replacement) != .orderedSame {
                phrases.append(entry.pattern)
            }
        }
        phrases.append(contentsOf: snippets.map(\.trigger))
        var seen = Set<String>()
        var unique: [String] = []
        for p in phrases {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            unique.append(trimmed)
            if unique.count == limit { break }
        }
        return unique
    }

    /// Effective voice-processing state (`nil` decodes as off).
    public var voiceProcessingEnabled: Bool {
        get { voiceProcessing ?? false }
        set { voiceProcessing = newValue }
    }

    /// Effective voice-functions state (`nil` decodes as enabled).
    public var voiceFunctionsEnabled: Bool {
        get { voiceFunctions ?? true }
        set { voiceFunctions = newValue }
    }

    /// The effective function trigger word, defaulting to "flow" when unset or
    /// blank (turn the feature off with `voiceFunctionsEnabled`, not by clearing this).
    public var functionTriggerText: String {
        get {
            let t = (functionTrigger ?? "flow").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "flow" : t
        }
        set { functionTrigger = newValue }
    }

    /// The hotkey name to show in menus/UI, resolving `.custom` to the
    /// recorded key's label.
    public var hotkeyDisplayName: String {
        guard hotkey == .custom else { return hotkey.displayName }
        return customKeyLabel ?? "Custom key (not set)"
    }

    /// The effective profile for a frontmost app, falling back to defaults.
    public func profile(forBundleID bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return appProfiles.first { $0.bundleID == bundleID }
    }

    public func mode(forBundleID bundleID: String?) -> FormattingMode {
        profile(forBundleID: bundleID)?.mode ?? defaultMode
    }

    public func isEnabled(forBundleID bundleID: String?) -> Bool {
        profile(forBundleID: bundleID)?.enabled ?? true
    }
}
