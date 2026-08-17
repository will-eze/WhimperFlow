import AppKit
import AVFoundation
import Speech
import ApplicationServices
import Combine

/// Live view of the three permissions WhimperFlow needs, with request helpers.
///
/// Every value here is polled from the system rather than cached from launch:
/// macOS gives an app no notification when the user flips a switch in System
/// Settings, so anything read once goes stale the moment they do.
@MainActor
final class PermissionsManager: ObservableObject {
    enum Status: Equatable {
        case granted, denied, notDetermined

        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied — enable in System Settings"
            case .notDetermined: return "Not requested yet"
            }
        }
    }

    /// The three TCC services the app needs, named as `tccutil` names them.
    enum Service: String, CaseIterable {
        case microphone = "Microphone"
        case speechRecognition = "SpeechRecognition"
        case accessibility = "Accessibility"

        var displayName: String {
            switch self {
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech Recognition"
            case .accessibility: return "Accessibility"
            }
        }
    }

    /// Why a permission that isn't in force might be stuck — i.e. why asking
    /// for it again, the obvious thing to offer, would do nothing.
    enum Blocker: Equatable {
        /// Observed: this app held the permission under a different signature
        /// of the same bundle. TCC's decision is bound to that old signature,
        /// so the app reads "not granted", System Settings still shows the
        /// switch on, and no prompt will ever appear again.
        case staleGrant

        /// Inferred: the same failure mode, but we never got to watch it
        /// happen. This build is ad-hoc signed, so any grant the user made
        /// died with the last rebuild — and nothing in the API distinguishes
        /// "a decision exists for an older cdhash" from "never asked".
        case possiblyStaleGrant
    }

    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var speechRecognition: Status = .notDetermined
    @Published private(set) var accessibility: Bool = false

    /// Services that aren't in force and won't come back by asking again,
    /// with the reason. Keyed by service so the UI can word each row honestly.
    @Published private(set) var blockers: [Service: Blocker] = [:]

    /// True when rebuilds will keep invalidating grants (see `CodeSignatureInfo`).
    let signatureIsAdHoc = CodeSignatureInfo.isAdHoc

    /// True when this build's signature differs from the one that ran last
    /// time, i.e. the app was rebuilt since the user last used it. Recorded
    /// per launch, so unlike a grant it can be observed even when every
    /// permission is already stuck.
    let signatureChangedSinceLastLaunch: Bool

    /// False in unbundled dev runs, where `tccutil` has no bundle ID to target.
    var canResetGrants: Bool { Bundle.main.bundleIdentifier != nil }

    private var pollTimer: Timer?
    private var pollTick = 0

    private static let launchSignatureKey = "permissions.lastLaunchSignature"

    private static func grantKey(_ service: Service) -> String {
        "permissions.grantedUnderSignature.\(service.rawValue)"
    }

    var allGranted: Bool {
        microphone == .granted && speechRecognition == .granted && accessibility
    }

    func status(of service: Service) -> Status {
        switch service {
        case .microphone: return microphone
        case .speechRecognition: return speechRecognition
        case .accessibility: return accessibility ? .granted : .notDetermined
        }
    }

    /// Services with any blocker, for the summary banner.
    var blockedServices: Set<Service> { Set(blockers.keys) }

    func blocker(for service: Service) -> Blocker? { blockers[service] }

    init() {
        // Record the running build's signature before anything reads it, so a
        // rebuild is detectable on the *next* launch even if every permission
        // is already stuck and there is nothing else left to observe.
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.launchSignatureKey)
        let current = CodeSignatureInfo.cdHash
        signatureChangedSinceLastLaunch = previous != nil && previous != current
        if let current, previous != current {
            defaults.set(current, forKey: Self.launchSignatureKey)
        }

        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Reading

    /// Re-reads all three permissions from the system. Cheap; call freely.
    func refresh() {
        set(\.microphone, Self.liveMicrophoneStatus())
        set(\.speechRecognition, Self.liveSpeechStatus())
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility { accessibility = trusted }
        updateStaleGrants()
    }

    private static func liveMicrophoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func liveSpeechStatus() -> Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Assigns only on change, so polling doesn't churn SwiftUI every 2s.
    private func set(_ keyPath: ReferenceWritableKeyPath<PermissionsManager, Status>, _ value: Status) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Polls every permission, not just Accessibility: macOS has no change
    /// notification for any of them, so a grant made in System Settings while
    /// the app is running is invisible until we look again.
    ///
    /// The timer runs in common run loop modes — in `.default` alone it stalls
    /// while a menu or a scroll is tracking, which is exactly when the user is
    /// looking at the Permissions tab waiting for it to notice.
    func beginPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.pollTick += 1
                // Everything granted: drop to a 10s heartbeat that still
                // notices a revocation, without polling TCC constantly.
                if self.allGranted, self.pollTick % 5 != 0 { return }
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Stale grant detection

    /// Works out, per service, whether "not granted" is a state the user can
    /// get out of by being asked again.
    ///
    /// The obvious implementation — remember the signature the app held the
    /// permission under, and call it stale if that signature has changed — is
    /// self-defeating, and was the bug this replaced: the only place it could
    /// record a signature was the branch where the service reads `.granted`,
    /// but a grant invalidated by a re-sign *never reads granted again*.
    /// Nothing is ever recorded, so nothing is ever flagged, so the reset
    /// affordance never appears and the user is left pressing a "Request
    /// Access" button that macOS silently ignores.
    ///
    /// So evidence is taken from two directions instead. The observation is
    /// kept because when it does fire it is certain. Alongside it sits the
    /// inference that matters in practice: on an ad-hoc signed build, TCC
    /// binds decisions to a cdhash that every rebuild changes, and the
    /// authorization APIs report a decision bound to an old cdhash
    /// identically to no decision at all. That ambiguity is not resolvable
    /// from in here — so rather than guess, treat any missing permission on
    /// an ad-hoc build as possibly stuck and always offer the way out.
    private func updateStaleGrants() {
        guard let cdHash = CodeSignatureInfo.cdHash else { return }
        var found: [Service: Blocker] = [:]
        for service in Service.allCases {
            let key = Self.grantKey(service)
            let recorded = UserDefaults.standard.string(forKey: key)
            guard status(of: service) != .granted else {
                if recorded != cdHash { UserDefaults.standard.set(cdHash, forKey: key) }
                continue
            }
            if let recorded, recorded != cdHash {
                found[service] = .staleGrant
            } else if signatureIsAdHoc {
                found[service] = .possiblyStaleGrant
            }
        }
        if found != blockers { blockers = found }
    }

    // MARK: - Requesting

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func requestSpeechRecognition() {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Asks for whatever is still missing, one dialog at a time — TCC drops
    /// prompts that are raised while another one is already on screen.
    func requestMissing() {
        refresh()
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    self.refresh()
                    self.requestMissing()
                }
            }
            return
        }
        if speechRecognition == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in
                DispatchQueue.main.async {
                    self.refresh()
                    self.requestMissing()
                }
            }
            return
        }
        if !accessibility { promptAccessibility() }
    }

    /// Clears the system's stored decision for a service and asks again.
    ///
    /// This is the only way out of the stale-grant state: while TCC holds a
    /// decision made against an older signature of this bundle, the app reads
    /// "not granted", the System Settings switch looks (and is) on, and no
    /// prompt will ever appear. `tccutil reset` drops that row so the normal
    /// request flow works again.
    func resetAndRequest(_ service: Service) {
        guard reset(service) else {
            openSystemSettings(for: service)
            return
        }
        refresh()
        switch service {
        case .microphone: requestMicrophone()
        case .speechRecognition: requestSpeechRecognition()
        case .accessibility: promptAccessibility()
        }
    }

    /// Clears every blocked decision at once, then re-requests them in sequence.
    func resetBlockedGrants() {
        for service in blockedServices.sorted(by: { $0.rawValue < $1.rawValue }) {
            _ = reset(service)
        }
        refresh()
        requestMissing()
    }

    /// Runs `tccutil reset <service> <bundle id>`. Returns false if it
    /// couldn't be run at all (unbundled dev run, or tccutil failed).
    @discardableResult
    private func reset(_ service: Service) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service.rawValue, bundleID]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        guard task.terminationStatus == 0 else { return false }
        UserDefaults.standard.removeObject(
            forKey: "permissions.grantedUnderSignature.\(service.rawValue)"
        )
        return true
    }

    // MARK: - System Settings

    enum SettingsPane: String {
        case microphone = "Privacy_Microphone"
        case speech = "Privacy_SpeechRecognition"
        case accessibility = "Privacy_Accessibility"
    }

    func openSystemSettings(_ pane: SettingsPane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    func openSystemSettings(for service: Service) {
        switch service {
        case .microphone: openSystemSettings(.microphone)
        case .speechRecognition: openSystemSettings(.speech)
        case .accessibility: openSystemSettings(.accessibility)
        }
    }
}
