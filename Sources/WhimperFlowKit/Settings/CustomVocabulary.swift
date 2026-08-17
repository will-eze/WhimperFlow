import Foundation

/// The personal vocabulary taught to the on-device recognizer's custom
/// language model. Pure and deterministic (settings in, ordered phrases out)
/// so the app and the offline eval harness always bias recognition the same
/// way — a measured WER only means something if the two agree.
public enum CustomVocabulary {
    /// Every phrase worth teaching: dictionary spellings, misheard patterns,
    /// and snippet triggers. Order is stable and duplicates are dropped
    /// case-insensitively, so the result can be content-hashed for caching.
    public static func phrases(from settings: FlowSettings) -> [String] {
        var candidates: [String] = []
        for entry in settings.dictionary {
            candidates.append(entry.replacement)
            candidates.append(entry.pattern)
        }
        candidates.append(contentsOf: settings.snippets.map(\.trigger))

        var seen = Set<String>()
        var out: [String] = []
        for raw in candidates {
            let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else { continue }
            out.append(phrase)
        }
        return out
    }
}
