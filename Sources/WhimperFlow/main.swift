import AppKit

@MainActor
func runApp() {
    let app = NSApplication.shared
    if SelfTest.runIfRequested() {
        app.setActivationPolicy(.prohibited)
        app.run()
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run() // never returns; `delegate` stays alive in this frame
}

MainActor.assumeIsolated { runApp() }
