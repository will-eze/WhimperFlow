import Foundation

/// Small, shared text-formatting helpers for the History & Stats window.
/// Kept dependency-free (no external libraries) so every view in this
/// directory can reuse the exact same phrasing.
enum HistoryFormat {
    /// e.g. 1234 -> "1,234"
    static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// e.g. 118.6 -> "119 wpm"
    static func wpm(_ value: Double) -> String {
        "\(Int(value.rounded())) wpm"
    }

    /// Minutes saved vs. typing, e.g. 92.4 -> "1h 32m", 8.1 -> "8 min".
    static func minutesSaved(_ minutes: Double) -> String {
        let totalMinutes = Int(minutes.rounded())
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return "\(hours)h \(mins)m"
        }
        return "\(totalMinutes) min"
    }

    /// e.g. 3.2 -> "3.2s"
    static func duration(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }

    /// e.g. 1 -> "1 word", 12 -> "12 words"
    static func wordCount(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count) words"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// e.g. "3 min ago", "yesterday"
    static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
