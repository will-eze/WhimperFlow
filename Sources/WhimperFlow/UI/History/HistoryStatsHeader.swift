import AppKit
import SwiftUI
import WhimperFlowKit

/// Row of four clean stat tiles summarizing dictation activity.
struct HistoryStatsHeader: View {
    let stats: DictationStats

    var body: some View {
        HStack(spacing: 12) {
            StatTile(value: HistoryFormat.grouped(stats.totalWords), caption: "Words dictated")
            StatTile(value: HistoryFormat.grouped(stats.totalUtterances), caption: "Dictations")
            StatTile(value: HistoryFormat.wpm(stats.averageWPM), caption: "Avg speed")
            StatTile(value: HistoryFormat.minutesSaved(stats.minutesSaved), caption: "Time saved vs typing")
        }
    }
}

private struct StatTile: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}
