import AppKit
import WhimperFlowKit

/// `WhimperFlow --snapshot <dir> [--appearance dark|light]`: renders every
/// page of the window (and the fix-a-word sheet) to PNGs, then quits. For
/// checking the layout without screen-recording permission.
@MainActor
enum Snapshot {
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(window: MainWindowController, router: MainRouter, history: HistoryStore, to directory: URL) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var steps: [() -> Void] = MainSection.allCases.map { section in
            { window.show(section) }
        }
        steps.append { if let first = history.records.first { router.teaching = first } }
        var names = MainSection.allCases.map(\.rawValue) + ["teach"]

        func next() {
            guard !steps.isEmpty else { exit(0) }
            steps.removeFirst()()
            let name = names.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let target = NSApp.windows.first { $0.isSheet && $0.isVisible } ?? NSApp.windows.first { $0.frameAutosaveName == "WhimperFlowMain" }
                if let view = target?.contentView?.superview ?? target?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent(name + ".png"))
                }
                next()
            }
        }
        next()
    }
}
