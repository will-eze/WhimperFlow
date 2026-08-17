import Testing
import Foundation
@testable import WhimperFlowKit

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("whimperflow-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SettingsStore persistence")
@MainActor
struct SettingsStoreTests {
    @Test func savesAndReloads() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.settings.hotkey = .fn
        store.settings.dictionary = [DictionaryEntry(pattern: "gh", replacement: "GitHub")]

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.hotkey == .fn)
        #expect(reloaded.settings.dictionary.first?.replacement == "GitHub")
    }

    @Test func customHotkeyRoundTrips() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.settings.hotkey = .custom
        store.settings.customKeyCode = 105
        store.settings.customKeyLabel = "F13"

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.hotkey == .custom)
        #expect(reloaded.settings.customKeyCode == 105)
        #expect(reloaded.settings.hotkeyDisplayName == "F13")
    }

    @Test func settingsWithoutCustomKeyFieldsStillDecode() throws {
        // A settings.json written before customKeyCode/customKeyLabel existed
        // must load without falling back to defaults.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var legacy = FlowSettings()
        legacy.hotkey = .fn
        legacy.localeIdentifier = "en-GB"
        let encoder = JSONEncoder()
        var json = try JSONSerialization.jsonObject(
            with: encoder.encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "customKeyCode")
        json.removeValue(forKey: "customKeyLabel")
        try JSONSerialization.data(withJSONObject: json)
            .write(to: dir.appendingPathComponent("settings.json"))

        let store = SettingsStore(directory: dir)
        #expect(store.settings.hotkey == .fn)
        #expect(store.settings.localeIdentifier == "en-GB")
        #expect(store.settings.customKeyCode == nil)
        #expect(store.settings.hotkeyDisplayName == "fn (Globe)")
    }

    @Test func corruptFileFallsBackToDefaults() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("settings.json"))

        let store = SettingsStore(directory: dir)
        #expect(store.settings == FlowSettings())
    }

    @Test func personalizationImportMerges() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        store.settings.dictionary = [DictionaryEntry(pattern: "jira", replacement: "Jira")]
        let exported = try store.exportPersonalization()

        let other = SettingsStore(directory: tempDir())
        other.settings.dictionary = [DictionaryEntry(pattern: "JIRA", replacement: "Different")]
        other.settings.snippets = [Snippet(trigger: "sig", expansion: "s")]
        try other.importPersonalization(from: exported)

        // Case-insensitive duplicate pattern not overwritten; nothing lost.
        #expect(other.settings.dictionary.count == 1)
        #expect(other.settings.dictionary[0].replacement == "Different")
        #expect(other.settings.snippets.count == 1)
    }
}

@Suite("HistoryStore")
@MainActor
struct HistoryStoreTests {
    private func record(_ text: String, words: Int? = nil, seconds: Double = 5, date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> DictationRecord {
        DictationRecord(date: date, appBundleID: "com.apple.mail", appName: "Mail",
                        rawText: text, processedText: text, durationSeconds: seconds)
    }

    @Test func appendAndReload() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        store.add(record("First one here"))
        store.add(record("Second one here"))
        #expect(store.records.count == 2)
        #expect(store.records[0].processedText == "Second one here")

        let reloaded = HistoryStore(directory: dir)
        #expect(reloaded.records.count == 2)
        #expect(reloaded.records[0].processedText == "Second one here")
    }

    @Test func capEnforced() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir, cap: 3)
        for i in 1...5 { store.add(record("utterance number \(i)")) }
        #expect(store.records.count == 3)
        #expect(store.records[0].processedText == "utterance number 5")

        let reloaded = HistoryStore(directory: dir, cap: 3)
        #expect(reloaded.records.count == 3)
    }

    @Test func deleteAndClear() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        let r = record("delete me please now")
        store.add(r)
        store.add(record("keep me around here"))
        store.delete(id: r.id)
        #expect(store.records.count == 1)

        store.clear()
        #expect(store.records.isEmpty)
        #expect(HistoryStore(directory: dir).records.isEmpty)
    }

    @Test func searchMatchesTextAndApp() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        store.add(record("hello world sample text"))
        store.add(record("completely different words"))
        #expect(store.search("Hello").count == 1)
        #expect(store.search("mail").count == 2) // app name match
        #expect(store.search("").count == 2)
    }

    @Test func statsComputation() {
        // 3 records × 4 words / 5s each = 12 words in 15s → 48 WPM.
        let records = (0..<3).map { _ in record("one two three four", seconds: 5) }
        let stats = DictationStats.compute(from: records, typingWPMBaseline: 45)
        #expect(stats.totalUtterances == 3)
        #expect(stats.totalWords == 12)
        #expect(stats.totalSeconds == 15)
        #expect(abs(stats.averageWPM - 48) < 0.001)
        // Typing 12 words at 45wpm = 0.2667min; spoke for 0.25min → saved ≈ 0.0167min.
        #expect(abs(stats.minutesSaved - (12.0 / 45 - 0.25)) < 0.001)
    }

    @Test func statsEmpty() {
        let stats = DictationStats.compute(from: [], typingWPMBaseline: 45)
        #expect(stats.totalWords == 0)
        #expect(stats.averageWPM == 0)
        #expect(stats.minutesSaved == 0)
    }
}
