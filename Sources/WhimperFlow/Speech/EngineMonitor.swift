import AppKit
import Combine
import Network
import WhimperFlowKit

/// Knows which engine a dictation started now would get, for the menu-bar dot:
/// green = the server answers, amber = only Apple's on-device fallback, red =
/// neither. Checks `/health` at launch, on wake, on any network change, every
/// 60 s, and when a dictation starts (which also warms the TLS connection).
@MainActor
final class EngineMonitor: ObservableObject {
    enum Status: Equatable {
        case server
        case fallbackOnly
        case none
    }

    @Published private(set) var status: Status = .none
    @Published private(set) var serverModel: String?
    @Published private(set) var serverReachable = false

    /// Fired when the server comes back after being unreachable.
    var onServerBack: (() -> Void)?

    private let settingsStore: SettingsStore
    private(set) var client: DictationServerClient
    private var cancellables: Set<AnyCancellable> = []
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var checking = false

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        client = DictationServerClient(baseURL: settingsStore.settings.dictationServerURL)

        settingsStore.$settings
            .map { [$0.dictationServerURL.absoluteString, $0.transcriptionEngine.rawValue, $0.localeIdentifier] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                let url = self.settingsStore.settings.dictationServerURL
                if url != self.client.baseURL { self.client = DictationServerClient(baseURL: url) }
                self.check()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.check() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.whimperflow.path"))

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    /// Re-checks the server (deduplicated while one check is in flight).
    func check() {
        guard !checking else { return }
        checking = true
        let client = client
        Task { @MainActor in
            let health = await client.health()
            self.checking = false
            let wasReachable = self.serverReachable
            self.serverReachable = health != nil
            self.serverModel = health?.model
            self.recompute()
            if health != nil, !wasReachable { self.onServerBack?() }
        }
    }

    /// A dictation's request to the server just failed.
    func noteServerFailure() {
        serverReachable = false
        recompute()
        check()
    }

    /// Re-reads Apple's availability (it changes with permissions and model downloads).
    func recompute() {
        let settings = settingsStore.settings
        let apple = AppleBackend.isAvailable(localeIdentifier: settings.localeIdentifier)
        switch settings.transcriptionEngine {
        case .server:
            status = serverReachable ? .server : (apple ? .fallbackOnly : .none)
        case .apple:
            status = apple ? .fallbackOnly : .none
        }
    }

    /// A one-line description for the menu.
    var summary: String {
        switch (settingsStore.settings.transcriptionEngine, status) {
        case (.server, .server): return "Engine: Parakeet on \(client.baseURL.host ?? "server")"
        case (.server, .fallbackOnly): return "Engine: server unreachable, using Apple on-device"
        case (.apple, .fallbackOnly): return "Engine: Apple on-device"
        default: return "Engine: none available (recordings are kept)"
        }
    }
}
