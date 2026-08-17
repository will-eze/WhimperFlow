import SwiftUI

/// A development tool, deliberately separate from WhimperFlow.app: it records
/// the reference clip set that `whimpereval` scores, writing each recording
/// beside the sentence it was read from so the pairing can't drift.
@main
struct RecorderApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup("Clip Recorder") {
            RecorderView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Prompt") { model.addPrompt() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
