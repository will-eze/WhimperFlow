import SwiftUI
import WhimperFlowKit

/// A page split into a few tabs by a segmented control under the title.
private struct TabbedPage<Tab: Hashable & CaseIterable & RawRepresentable, Content: View>: View
where Tab.AllCases: RandomAccessCollection, Tab.RawValue == String {
    @Binding var tab: Tab
    @ViewBuilder let content: (Tab) -> Content

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Array(Tab.allCases), id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            .padding(.bottom, 4)
            content(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// How text comes out: cleanup rules, per-app styles, voice functions.
struct StyleView: View {
    enum Tab: String, CaseIterable { case formatting = "Formatting", apps = "Per App", functions = "Voice Functions" }

    @ObservedObject var settingsStore: SettingsStore
    @State private var tab: Tab = .formatting

    var body: some View {
        TabbedPage(tab: $tab) { tab in
            switch tab {
            case .formatting: FormattingSettingsView(settingsStore: settingsStore)
            case .apps: AppsSettingsView(settingsStore: settingsStore)
            case .functions: FunctionsSettingsView(settingsStore: settingsStore)
            }
        }
    }
}

/// Everything else: keys and audio, the engine, permissions, version.
struct SettingsView: View {
    enum Tab: String, CaseIterable { case general = "General", engine = "Engine", permissions = "Permissions", about = "About" }

    let context: AppContext
    @State private var tab: Tab = .general

    var body: some View {
        TabbedPage(tab: $tab) { tab in
            switch tab {
            case .general: GeneralSettingsView(settingsStore: context.settingsStore)
            case .engine: EngineSettingsView(settingsStore: context.settingsStore, engineMonitor: context.engineMonitor)
            case .permissions: PermissionsSettingsView(permissions: context.permissions)
            case .about: AboutSettingsView()
            }
        }
    }
}

/// Which recogniser turns speech into text, and the server's address.
struct EngineSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var engineMonitor: EngineMonitor

    @State private var serverURLText = ""
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Picker("Speech to text", selection: $settingsStore.settings.transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(engineCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settingsStore.settings.transcriptionEngine == .server {
                Section("Fix misheard words") {
                    Toggle(isOn: $settingsStore.settings.fixMishearsEnabled) {
                        Text("Fix misheard jargon with a small AI model on Jarvis")
                        Text("It turns “public reaper” into “public repo”. It may only swap a few words for one of your terms (Words → Terms you use), so it can't reword anything else. Adds about half a second after you let go.")
                    }
                    if settingsStore.settings.fixMishearsEnabled {
                        LabeledContent("Status") {
                            Text(fixerStatus).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Server") {
                    TextField("Address", text: $serverURLText, prompt: Text(FlowSettings.defaultServerURL))
                        .onSubmit(commitServerURL)
                    HStack {
                        Button(testing ? "Testing…" : "Test Connection", action: testConnection)
                            .disabled(testing)
                        if let testResult {
                            Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testResult.ok ? Color.green : Color.red)
                                .font(.callout)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { serverURLText = settingsStore.settings.serverURL ?? "" }
        .onDisappear(perform: commitServerURL)
    }

    private var fixerStatus: String {
        if !engineMonitor.serverReachable { return "Server unreachable" }
        if !engineMonitor.serverCorrector { return "Not running on the server" }
        let count = settingsStore.settings.correctionVocabulary.count
        return "Running · \(count) terms"
    }

    private var engineCaption: String {
        switch settingsStore.settings.transcriptionEngine {
        case .server:
            return "Parakeet on your Jarvis server, reached only over Tailscale. It's about twice as accurate as Apple's. If the server doesn't answer within about 2 seconds, Apple's recogniser on this Mac types that part instead, and a recording neither can read is kept and transcribed into History later."
        case .apple:
            return "Apple's recogniser, entirely on this Mac, with live text while you speak. Needs Speech Recognition allowed and the language's on-device model (System Settings → Keyboard → Dictation)."
        }
    }

    private func commitServerURL() {
        let text = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.settings.serverURL = text.isEmpty ? nil : text
    }

    private func testConnection() {
        commitServerURL()
        testing = true
        testResult = nil
        let client = DictationServerClient(baseURL: settingsStore.settings.dictationServerURL)
        Task { @MainActor in
            let started = Date()
            let health = await client.health(timeout: 5)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            testing = false
            testResult = health != nil
                ? (true, "Connected in \(ms) ms")
                : (false, "No answer. Is Tailscale on?")
            engineMonitor.check()
        }
    }
}
