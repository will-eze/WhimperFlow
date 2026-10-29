import SwiftUI

/// Static app-identity pane.
struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("WhimperFlow")
                        .font(.title2)
                        .bold()
                    Text("Deterministic dictation. Speech becomes text on your own server or on this Mac, never in the cloud.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text(versionLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Text("Audio goes only over Tailscale to the dictation server (Parakeet) on your Jarvis server, which keeps no audio and logs no text. Apple's on-device Speech framework is the fallback. No telemetry and no third-party dependencies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let date = info["WFBuildDate"] as? String ?? "unbundled build"
        return "Version \(version) (\(build)), built \(date)"
    }
}
