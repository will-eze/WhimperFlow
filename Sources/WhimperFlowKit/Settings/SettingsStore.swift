import Foundation
import Combine

/// Observable owner of `FlowSettings`, persisted as pretty-printed JSON in
/// Application Support. Every mutation saves immediately (the file is tiny).
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: FlowSettings {
        didSet { save() }
    }

    public let fileURL: URL

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhimperFlow", isDirectory: true)
    }

    public init(directory: URL? = nil) {
        let dir = directory ?? SettingsStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(FlowSettings.self, from: data) {
            settings = loaded
        } else {
            settings = FlowSettings()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Import/export (dictionary & snippets)

    public struct PersonalizationExport: Codable {
        public var dictionary: [DictionaryEntry]
        public var snippets: [Snippet]
    }

    public func exportPersonalization() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PersonalizationExport(dictionary: settings.dictionary, snippets: settings.snippets))
    }

    public func importPersonalization(from data: Data) throws {
        let imported = try JSONDecoder().decode(PersonalizationExport.self, from: data)
        var merged = settings
        for entry in imported.dictionary where !merged.dictionary.contains(where: {
            $0.pattern.caseInsensitiveCompare(entry.pattern) == .orderedSame
        }) {
            merged.dictionary.append(entry)
        }
        for snippet in imported.snippets where !merged.snippets.contains(where: {
            $0.trigger.caseInsensitiveCompare(snippet.trigger) == .orderedSame
        }) {
            merged.snippets.append(snippet)
        }
        settings = merged
    }
}
