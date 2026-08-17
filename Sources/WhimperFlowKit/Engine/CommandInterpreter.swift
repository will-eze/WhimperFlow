import Foundation

/// An editing action recognized from a whole utterance, executed by the app
/// layer instead of inserting text.
public enum EditCommand: Equatable, Sendable {
    /// Delete the previously injected utterance (exact backspace count).
    case scratchThat
    /// Press the Return key (e.g. to send a chat message).
    case pressReturn
    /// Press the Tab key.
    case pressTab
    /// Press ⌘Z in the frontmost app.
    case undo
}

/// Whole-utterance spoken commands. Matching is deterministic: the trimmed,
/// lowercased, punctuation-stripped utterance must equal a known phrase exactly.
public enum CommandInterpreter {
    static let commands: [String: EditCommand] = [
        "scratch that": .scratchThat,
        "delete that": .scratchThat,
        "erase that": .scratchThat,
        "undo that": .undo,
        "press enter": .pressReturn,
        "press return": .pressReturn,
        "hit enter": .pressReturn,
        "press tab": .pressTab,
    ]

    public static func command(for raw: String) -> EditCommand? {
        commands[normalize(raw)]
    }

    /// Also used for whole-utterance snippet trigger matching.
    static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
