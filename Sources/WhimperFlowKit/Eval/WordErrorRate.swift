import Foundation

/// Word-level alignment between a reference and a hypothesis transcript.
/// Pure and deterministic: the same pair of inputs always produces the same
/// alignment, which is what makes it usable both for scoring (the eval
/// harness) and for deriving correction rules from user edits.
public enum WordAlignment {
    public enum Operation: String, Equatable, Sendable {
        case match
        case substitution
        case insertion   // hypothesis has a word the reference doesn't
        case deletion    // reference has a word the hypothesis dropped
    }

    public struct Step: Equatable, Sendable {
        public var operation: Operation
        public var reference: String?
        public var hypothesis: String?

        public init(operation: Operation, reference: String?, hypothesis: String?) {
            self.operation = operation
            self.reference = reference
            self.hypothesis = hypothesis
        }
    }

    /// Levenshtein alignment over words. Ties are broken in a fixed order
    /// (substitution, then deletion, then insertion) so the output is stable.
    public static func align(reference: [String], hypothesis: [String]) -> [Step] {
        let n = reference.count
        let m = hypothesis.count

        // cost[i][j] = edit distance between reference[0..<i] and hypothesis[0..<j].
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: 1, through: n, by: 1) { cost[i][0] = i }
        for j in stride(from: 1, through: m, by: 1) { cost[0][j] = j }
        for i in stride(from: 1, through: n, by: 1) {
            for j in stride(from: 1, through: m, by: 1) {
                let substitute = cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                let delete = cost[i - 1][j] + 1
                let insert = cost[i][j - 1] + 1
                cost[i][j] = min(substitute, min(delete, insert))
            }
        }

        // Walk back from the corner, emitting steps in reverse.
        var steps: [Step] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1) {
                let same = reference[i - 1] == hypothesis[j - 1]
                steps.append(Step(operation: same ? .match : .substitution,
                                  reference: reference[i - 1],
                                  hypothesis: hypothesis[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                steps.append(Step(operation: .deletion, reference: reference[i - 1], hypothesis: nil))
                i -= 1
            } else {
                steps.append(Step(operation: .insertion, reference: nil, hypothesis: hypothesis[j - 1]))
                j -= 1
            }
        }
        return steps.reversed()
    }
}

/// Word error rate over normalized text.
public enum WordErrorRate {
    public struct Score: Equatable, Sendable {
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        public var referenceWords: Int

        public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, referenceWords: Int = 0) {
            self.substitutions = substitutions
            self.deletions = deletions
            self.insertions = insertions
            self.referenceWords = referenceWords
        }

        public var errors: Int { substitutions + deletions + insertions }

        /// Errors per reference word. An empty reference scores 0 when the
        /// hypothesis is also empty, and 1 otherwise (everything is an error).
        public var rate: Double {
            guard referenceWords > 0 else { return errors == 0 ? 0 : 1 }
            return Double(errors) / Double(referenceWords)
        }

        public static func + (lhs: Score, rhs: Score) -> Score {
            Score(substitutions: lhs.substitutions + rhs.substitutions,
                  deletions: lhs.deletions + rhs.deletions,
                  insertions: lhs.insertions + rhs.insertions,
                  referenceWords: lhs.referenceWords + rhs.referenceWords)
        }
    }

    /// Scoring normalization: case-folded, punctuation stripped, whitespace
    /// collapsed. Apostrophes and inner hyphens survive because "dont" vs
    /// "don't" and "on-device" vs "on device" are real recognizer differences
    /// we want to keep measuring — only surrounding punctuation is noise.
    public static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { chunk -> String in
                String(chunk.unicodeScalars.filter { scalar in
                    let ch = Character(scalar)
                    return ch.isLetter || ch.isNumber || ch == "'" || ch == "-"
                })
                .trimmingCharacters(in: CharacterSet(charactersIn: "-'"))
            }
            .filter { !$0.isEmpty }
    }

    public static func score(reference: String, hypothesis: String) -> Score {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        var score = Score(referenceWords: ref.count)
        for step in WordAlignment.align(reference: ref, hypothesis: hyp) {
            switch step.operation {
            case .match: break
            case .substitution: score.substitutions += 1
            case .deletion: score.deletions += 1
            case .insertion: score.insertions += 1
            }
        }
        return score
    }

    /// Human-readable diff, e.g. `the [quick→brown] fox (-jumps) (+ran)`.
    public static func diff(reference: String, hypothesis: String) -> String {
        let steps = WordAlignment.align(reference: normalize(reference), hypothesis: normalize(hypothesis))
        return steps.map { step in
            switch step.operation {
            case .match: return step.reference ?? ""
            case .substitution: return "[\(step.reference ?? "")→\(step.hypothesis ?? "")]"
            case .deletion: return "(-\(step.reference ?? ""))"
            case .insertion: return "(+\(step.hypothesis ?? ""))"
            }
        }.joined(separator: " ")
    }
}
