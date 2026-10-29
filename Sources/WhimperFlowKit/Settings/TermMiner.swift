import Foundation

/// Finds the jargon someone actually dictates (CamelCase names and acronyms
/// they've used more than once), to start the misheard-word fixer's term list.
public enum TermMiner {
    /// Capitalised common words that turn up in shouted text, not jargon.
    private static let ordinary: Set<String> = [
        "THE", "AND", "SO", "ON", "TO", "IT", "IS", "IN", "OF", "OR", "IF", "AT", "BE", "BY", "DO", "GO", "NO",
        "OK", "WE", "MY", "ME", "UP", "AN", "AS", "FOR", "NOT", "BUT", "ALL", "NEW", "NOW", "YOU", "WITH",
        "THIS", "THAT", "TODAY", "NEWS", "LOGIN", "FLOW", "EM", "AM", "PM", "SU", "FN", "DC",
    ]

    /// Common developer jargon. Mining can't find these when the recogniser
    /// always mishears them ("repo" only ever arrived as "reaper").
    public static let starter = [
        "repo", "GitHub", "git", "commit", "pull request", "PR", "README", "JSON", "API", "CLI", "SSH", "SQL",
        "npm", "regex", "localhost", "Docker", "Kubernetes", "k8s", "kubectl", "Python", "Swift", "SwiftUI",
        "Xcode", "macOS", "iOS", "Claude", "Claude Code", "ChatGPT",
    ]

    /// The first term list: the starter terms, then mined jargon, no repeats.
    public static func initialTerms(from texts: [String]) -> [String] {
        var seen = Set<String>()
        return (starter + terms(from: texts)).filter { seen.insert($0.lowercased()).inserted }
    }

    public static func terms(from texts: [String], minimumCount: Int = 2, limit: Int = 60) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for text in texts {
            for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let w = String(word)
                guard isJargon(w), !ordinary.contains(w) else { continue }
                if counts[w] == nil { order.append(w) }
                counts[w, default: 0] += 1
            }
        }
        return order
            .filter { counts[$0, default: 0] >= minimumCount }
            .sorted { counts[$0, default: 0] > counts[$1, default: 0] }
            .prefix(limit)
            .map { $0 }
    }

    /// "GitHub", "SwiftUI" (a lower-case letter followed by a capital) or
    /// "JSON", "API" (2–6 capitals, digits allowed: "K8S").
    static func isJargon(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter else { return false }
        let chars = Array(word)
        let camel = zip(chars, chars.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
        let acronym = (2...6).contains(word.count) && word.allSatisfy { $0.isUppercase || $0.isNumber }
            && word.contains { $0.isLetter }
        return camel || acronym
    }
}
