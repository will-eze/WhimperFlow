import Foundation

/// Turning a word picked out of a past dictation into a dictionary entry.
public enum TeachWord {
    /// The words of a dictation as shown for picking, punctuation kept so the
    /// sentence still reads naturally.
    public static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// What to match next time: the picked words without surrounding
    /// punctuation, lowercased (entries match case-insensitively by default).
    public static func pattern(from picked: String) -> String {
        picked
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

extension FlowSettings {
    /// Adds "heard → write", or updates the entry already matching `heard`.
    /// Returns false when either side is blank or the pair changes nothing.
    @discardableResult
    public mutating func teach(heard: String, write: String) -> Bool {
        let pattern = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = write.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, !replacement.isEmpty, pattern != replacement else { return false }
        if let index = dictionary.firstIndex(where: {
            $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame
        }) {
            dictionary[index].replacement = replacement
        } else {
            dictionary.insert(DictionaryEntry(pattern: pattern, replacement: replacement), at: 0)
        }
        return true
    }
}
