import SwiftUI
import AppKit

/// Shows the live status of the three permissions WhimperFlow needs, with
/// request / open-System-Settings actions for whichever aren't granted.
///
/// Status is polled by `PermissionsManager`, so a switch flipped in System
/// Settings shows up here within a couple of seconds without reopening the
/// window or restarting the app.
struct PermissionsSettingsView: View {
    @ObservedObject var permissions: PermissionsManager

    var body: some View {
        Form {
            Section {
                Text("WhimperFlow needs three permissions to work: the microphone to capture audio, Speech Recognition to transcribe it fully on-device, and Accessibility to watch for your hotkey and type text into other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !permissions.blockedServices.isEmpty {
                Section {
                    blockedGrantNotice
                }
            }

            Section("Microphone") {
                row(
                    service: .microphone,
                    status: permissions.microphone,
                    explanation: "Used to record what you say while dictating."
                )
            }

            Section("Speech Recognition") {
                row(
                    service: .speechRecognition,
                    status: permissions.speechRecognition,
                    explanation: "Powers fully local, on-device transcription of your speech."
                )
            }

            Section("Accessibility") {
                row(
                    service: .accessibility,
                    status: permissions.accessibility ? .granted : .notDetermined,
                    explanation: "Lets WhimperFlow watch for your hotkey and type text into the frontmost app.",
                    grantTitle: "Grant Access\u{2026}"
                )
            }

            Section {
                Button("Refresh") { permissions.refresh() }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(
        service: PermissionsManager.Service,
        status: PermissionsManager.Status,
        explanation: String,
        grantTitle: String = "Request Access"
    ) -> some View {
        let blocker = permissions.blocker(for: service)
        HStack(alignment: .top, spacing: 12) {
            statusIcon(for: status, blocked: blocker != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(status: status, blocker: blocker))
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // A blocked service always gets the reset route, because that is
            // the only action that can actually change anything: asking again
            // is ignored by macOS while a decision bound to an older
            // signature is on file, and the System Settings switch the user
            // would find already looks correct.
            if let blocker, permissions.canResetGrants {
                let fix = Button(blocker == .staleGrant ? "Fix" : "Reset & Ask Again") {
                    permissions.resetAndRequest(service)
                }
                if blocker == .staleGrant {
                    fix.buttonStyle(.borderedProminent)
                } else {
                    fix
                }
                Button("Open System Settings") { permissions.openSystemSettings(for: service) }
            } else if status == .notDetermined {
                Button(grantTitle) { request(service) }
                if service == .accessibility {
                    // Accessibility can't be granted from the prompt itself,
                    // only in System Settings — offer the direct route too.
                    Button("Open System Settings") { permissions.openSystemSettings(for: service) }
                }
            } else if status == .denied {
                Button("Open System Settings") { permissions.openSystemSettings(for: service) }
            }
        }
    }

    /// Never claim a permission was "not requested yet" when the app can't
    /// actually tell — on an ad-hoc build that state is indistinguishable
    /// from a grant the last rebuild invalidated.
    private func headline(
        status: PermissionsManager.Status,
        blocker: PermissionsManager.Blocker?
    ) -> String {
        switch blocker {
        case .staleGrant:
            return "Granted to an older build — needs re-approving"
        case .possiblyStaleGrant:
            return status == .denied
                ? "Denied — or granted to an older build"
                : "Not in force — if you already allowed it, this build lost it"
        case nil:
            return status.label
        }
    }

    private func request(_ service: PermissionsManager.Service) {
        switch service {
        case .microphone: permissions.requestMicrophone()
        case .speechRecognition: permissions.requestSpeechRecognition()
        case .accessibility: permissions.promptAccessibility()
        }
    }

    // MARK: - Blocked grants

    /// The confusing case: System Settings shows WhimperFlow switched on, but
    /// the app doesn't have the permission and macOS won't re-prompt, because
    /// the grant was bound to a previous build's signature.
    @ViewBuilder
    private var blockedGrantNotice: some View {
        let names = permissions.blockedServices
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: ", ")
        let confirmed = permissions.blockers.values.contains(.staleGrant)
        VStack(alignment: .leading, spacing: 6) {
            Label(
                confirmed
                    ? "Permissions were lost when the app was rebuilt"
                    : "If you already allowed these, this build can't use them",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            Text("macOS ties an approval to the exact build it was given to. This copy of WhimperFlow is ad-hoc signed, so every rebuild counts as a different app and inherits none of them. If you switched \(names) on for an earlier build, System Settings still shows WhimperFlow allowed — but that switch belongs to the old build, and macOS will never prompt again while it's there.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\u{201C}Reset & Ask Again\u{201D} clears the stored approval so macOS asks properly. You'll need to allow it once more.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if permissions.signatureIsAdHoc {
                Text("To stop this happening on every rebuild, sign the app with a stable identity: run `make signing-identity` once, then `make app`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if permissions.canResetGrants {
                Button("Reset All & Ask Again") { permissions.resetBlockedGrants() }
            }
        }
    }

    // MARK: - Icons

    @ViewBuilder
    private func statusIcon(for status: PermissionsManager.Status, blocked: Bool) -> some View {
        if blocked {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            switch status {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .notDetermined:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        }
    }
}
