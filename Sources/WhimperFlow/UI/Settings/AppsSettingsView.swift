import SwiftUI
import AppKit
import WhimperFlowKit

/// Per-application formatting-mode overrides and enable/disable toggles.
struct AppsSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section {
                Text("Override the formatting mode or disable dictation entirely for specific apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    ForEach($settingsStore.settings.appProfiles) { $profile in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.appName.isEmpty ? "Unnamed app" : profile.appName)
                                Text(profile.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $profile.mode) {
                                ForEach(FormattingMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            Toggle("Enabled", isOn: $profile.enabled)
                                .labelsHidden()
                            Button {
                                remove(profile)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 240)

                HStack {
                    Menu("Add App\u{2026}") {
                        if addableApps.isEmpty {
                            Text("No other running apps")
                        } else {
                            ForEach(addableApps, id: \.bundleIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "Unknown") {
                                    addProfile(for: app)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 160)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Regular (Dock-visible) running apps not already covered by a profile.
    private var addableApps: [NSRunningApplication] {
        let existingIDs = Set(settingsStore.settings.appProfiles.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                guard let bundleID = app.bundleIdentifier else { return false }
                return !existingIDs.contains(bundleID)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func addProfile(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let name = app.localizedName ?? bundleID
        settingsStore.settings.appProfiles.append(AppProfile(bundleID: bundleID, appName: name))
    }

    private func remove(_ profile: AppProfile) {
        settingsStore.settings.appProfiles.removeAll { $0.id == profile.id }
    }
}
