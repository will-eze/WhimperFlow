import Foundation
import AVFoundation
import AppKit
import AudioSupport

/// One prompt: the sentence to read, and the recording of it (if any).
/// The files on disk are the source of truth — this is just a view of them,
/// so clips recorded here and clips dropped in by hand behave identically.
struct Prompt: Identifiable, Equatable {
    var name: String
    var text: String
    var audio: URL?

    var id: String { name }
    var isRecorded: Bool { audio != nil }
}

@MainActor
final class RecorderModel: NSObject, ObservableObject {
    @Published var folder: URL
    @Published private(set) var prompts: [Prompt] = []
    @Published var selection: Prompt.ID?
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    /// Normalized 0…1 mic level, for the meter.
    @Published private(set) var level: Double = 0
    @Published private(set) var micAuthorized = false
    @Published var status = ""

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?

    static let audioExtensions: Set<String> = ["wav", "m4a", "aiff", "aif", "caf", "mp3", "flac"]
    private static let folderDefaultsKey = "clipsFolderBookmarkPath"

    override init() {
        folder = RecorderModel.defaultFolder()
        super.init()
        reload()
        Task { await refreshMicrophoneAuthorization() }
    }

    // MARK: - Folder

    /// Prefer the folder used last; otherwise find `Eval/clips` by walking up
    /// from the app bundle, which is where it sits in a checkout.
    private static func defaultFolder() -> URL {
        if let saved = UserDefaults.standard.string(forKey: folderDefaultsKey) {
            let url = URL(fileURLWithPath: saved, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        var directory = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Eval/clips", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhimperFlow clips", isDirectory: true)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func setFolder(_ url: URL) {
        stopEverything()
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderDefaultsKey)
        reload()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: - Loading

    /// Rebuild the prompt list from the `.txt` files in the folder, pairing
    /// each with an audio file of the same basename.
    func reload() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []

        var audioByName: [String: URL] = [:]
        for url in entries where Self.audioExtensions.contains(url.pathExtension.lowercased()) {
            audioByName[url.deletingPathExtension().lastPathComponent] = url
        }

        var loaded: [Prompt] = []
        for url in entries where url.pathExtension.lowercased() == "txt" {
            let name = url.deletingPathExtension().lastPathComponent
            let text = (try? String(contentsOf: url, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            loaded.append(Prompt(name: name, text: text, audio: audioByName[name]))
        }
        prompts = loaded.sorted { $0.name < $1.name }

        if selection == nil || !prompts.contains(where: { $0.id == selection }) {
            selection = prompts.first(where: { !$0.isRecorded })?.id ?? prompts.first?.id
        }
    }

    var recordedCount: Int { prompts.filter(\.isRecorded).count }

    var selectedPrompt: Prompt? {
        guard let selection else { return nil }
        return prompts.first { $0.id == selection }
    }

    // MARK: - Editing prompts

    func loadStarterPrompts() {
        for item in StarterPrompts.all {
            let url = folder.appendingPathComponent("\(item.name).txt")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? item.text.write(to: url, atomically: true, encoding: .utf8)
        }
        reload()
        status = "Loaded the starter set — edit any sentence to make it yours."
    }

    func addPrompt() {
        let name = uniqueName(base: "clip")
        let url = folder.appendingPathComponent("\(name).txt")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        reload()
        selection = name
    }

    private func uniqueName(base: String) -> String {
        var index = prompts.count + 1
        while prompts.contains(where: { $0.name == "\(base)-\(String(format: "%02d", index))" }) {
            index += 1
        }
        return "\(base)-\(String(format: "%02d", index))"
    }

    /// The reference text is what you *meant* to say; it is written straight
    /// to disk so the pairing can never drift from what the harness scores.
    func updateText(_ text: String, for id: Prompt.ID) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        prompts[index].text = text
        let url = folder.appendingPathComponent("\(prompts[index].name).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func deletePrompt(_ id: Prompt.ID) {
        guard let prompt = prompts.first(where: { $0.id == id }) else { return }
        stopEverything()
        if let audio = prompt.audio { try? FileManager.default.removeItem(at: audio) }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(prompt.name).txt"))
        reload()
    }

    func deleteRecording(_ id: Prompt.ID) {
        guard let prompt = prompts.first(where: { $0.id == id }), let audio = prompt.audio else { return }
        stopEverything()
        try? FileManager.default.removeItem(at: audio)
        reload()
        status = "Deleted the recording for \(prompt.name)."
    }

    func selectNextUnrecorded() {
        stopEverything()
        // Look after the current prompt first so a pass runs top to bottom.
        let startIndex = prompts.firstIndex { $0.id == selection }.map { $0 + 1 } ?? 0
        let ordered = Array(prompts[min(startIndex, prompts.count)...]) + Array(prompts[..<min(startIndex, prompts.count)])
        if let next = ordered.first(where: { !$0.isRecorded }) {
            selection = next.id
        } else {
            status = "Every prompt has a recording — run `make eval`."
        }
    }

    // MARK: - Microphone

    func refreshMicrophoneAuthorization() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micAuthorized = true
        case .notDetermined:
            micAuthorized = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            micAuthorized = false
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard let prompt = selectedPrompt else { return }
        guard micAuthorized else {
            status = "Microphone access is needed before recording."
            Task { await refreshMicrophoneAuthorization() }
            return
        }
        guard !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Write the sentence first — it's the reference the score is measured against."
            return
        }
        stopPlayback()

        // Replace any previous take, including one in a different format.
        if let existing = prompt.audio { try? FileManager.default.removeItem(at: existing) }
        let url = folder.appendingPathComponent("\(prompt.name).wav")

        // Mono 16-bit PCM: what the recognizer wants, no conversion in the path.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                status = "The recorder wouldn't start. Check the input device in System Settings → Sound."
                return
            }
            self.recorder = recorder
            isRecording = true
            status = "Recording \(prompt.name) — read the sentence, then stop."
            startMetering()
        } catch {
            status = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        isRecording = false
        stopMetering()

        // The gap between finishing the sentence and reaching for the button is
        // enough to lose the clip: ≥2s of trailing silence makes the recognizer
        // return nothing at all. Trim it now so the saved file is always usable.
        var note = "Saved. Play it back, or move to the next prompt."
        if let url, let outcome = (try? SilenceTrimmer.trimInPlace(url)) ?? nil {
            note = String(format: "Saved (trimmed %.1fs of silence off the end).", outcome.trimmedSeconds)
        }

        reload()
        status = note
    }

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLevel() }
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sampleLevel() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        // dBFS (about -60 silent, 0 peak) mapped onto 0…1.
        let power = Double(recorder.averagePower(forChannel: 0))
        let normalized = max(0, min(1, (power + 60) / 60))
        level = normalized
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    // MARK: - Playback

    func togglePlayback() {
        isPlaying ? stopPlayback() : play()
    }

    func play() {
        guard let audio = selectedPrompt?.audio else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: audio)
            player.delegate = self
            player.play()
            self.player = player
            isPlaying = true
        } catch {
            status = "Couldn't play that clip: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    func stopEverything() {
        if isRecording { stopRecording() }
        stopPlayback()
    }
}

extension RecorderModel: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag { self.status = "That recording didn't finish cleanly — please record it again." }
            self.reload()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.player = nil
        }
    }
}
