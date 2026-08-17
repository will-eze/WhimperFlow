import AppKit

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run() // never returns; `delegate` stays alive in this frame
}

MainActor.assumeIsolated { runApp() }
