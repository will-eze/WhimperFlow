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
                    Text("Fully local, deterministic dictation \u{2014} no cloud, no AI models shipped.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text("Version 1.0.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Text("Built with SwiftUI and Apple's on-device Speech framework. No network requests, no telemetry, and no third-party dependencies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
