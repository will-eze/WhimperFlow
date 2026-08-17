import Foundation
import Combine

/// One completed dictation.
public struct DictationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var appBundleID: String?
    public var appName: String?
    public var rawText: String
    public var processedText: String
    public var durationSeconds: Double
    public var wordCount: Int

    public init(id: UUID = UUID(), date: Date, appBundleID: String?, appName: String?,
                rawText: String, processedText: String, durationSeconds: Double) {
        self.id = id
        self.date = date
        self.appBundleID = appBundleID
        self.appName = appName
        self.rawText = rawText
        self.processedText = processedText
        self.durationSeconds = durationSeconds
        self.wordCount = processedText.split(whereSeparator: \.isWhitespace).count
    }
}

/// Aggregate statistics — a pure function of the records, so it's testable.
public struct DictationStats: Equatable, Sendable {
    public var totalUtterances: Int
    public var totalWords: Int
    public var totalSeconds: Double
    /// Words per minute actually achieved while dictating.
    public var averageWPM: Double
    /// Minutes saved vs typing everything at the configured baseline WPM.
    public var minutesSaved: Double

    public static func compute(from records: [DictationRecord], typingWPMBaseline: Double) -> DictationStats {
        let words = records.reduce(0) { $0 + $1.wordCount }
        let seconds = records.reduce(0.0) { $0 + $1.durationSeconds }
        let wpm = seconds > 0 ? Double(words) / (seconds / 60) : 0
        let typingMinutes = typingWPMBaseline > 0 ? Double(words) / typingWPMBaseline : 0
        let saved = max(0, typingMinutes - seconds / 60)
        return DictationStats(
            totalUtterances: records.count,
            totalWords: words,
            totalSeconds: seconds,
            averageWPM: wpm,
            minutesSaved: saved
        )
    }
}

/// Append-only JSONL history, newest records last on disk, newest first in
/// `records`. Capped in memory; the file is compacted when it exceeds 2× cap.
@MainActor
public final class HistoryStore: ObservableObject {
    @Published public private(set) var records: [DictationRecord] = []

    public let fileURL: URL
    private let cap: Int
    private let encoder = JSONEncoder()

    public init(directory: URL? = nil, cap: Int = 2000) {
        let dir = directory ?? SettingsStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
        self.cap = cap
        encoder.dateEncodingStrategy = .iso8601
        load()
    }

    public func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
        appendToFile(record)
        if lineCountEstimate > cap * 2 { rewriteFile() }
    }

    public func delete(id: UUID) {
        records.removeAll { $0.id == id }
        rewriteFile()
    }

    public func clear() {
        records = []
        try? FileManager.default.removeItem(at: fileURL)
        lineCountEstimate = 0
    }

    public func stats(typingWPMBaseline: Double) -> DictationStats {
        DictationStats.compute(from: records, typingWPMBaseline: typingWPMBaseline)
    }

    public func search(_ query: String) -> [DictationRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.processedText.localizedCaseInsensitiveContains(q)
                || ($0.appName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    // MARK: - Disk

    private var lineCountEstimate = 0

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [DictationRecord] = []
        for line in content.split(separator: "\n") {
            if let record = try? decoder.decode(DictationRecord.self, from: Data(line.utf8)) {
                loaded.append(record)
            }
        }
        lineCountEstimate = loaded.count
        records = Array(loaded.suffix(cap).reversed())
    }

    private func appendToFile(_ record: DictationRecord) {
        guard var data = try? encoder.encode(record) else { return }
        data.append(contentsOf: [0x0A])
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
        lineCountEstimate += 1
    }

    private func rewriteFile() {
        var data = Data()
        for record in records.reversed() {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(contentsOf: [0x0A])
        }
        try? data.write(to: fileURL, options: .atomic)
        lineCountEstimate = records.count
    }
}
