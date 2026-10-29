import AppKit
import Carbon.HIToolbox

/// ⌃⌥V anywhere: type the last dictation again. A Carbon system hotkey, so it
/// needs no extra permission and never reaches the frontmost app.
@MainActor
final class PasteLastShortcut {
    static let displayName = "⌃⌥V"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let shortcut = Unmanaged<PasteLastShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.fireWhenReleased(tries: 20) }
            return noErr
        }, 1, &spec, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x5746_4C57), id: 1) // "WFLW"
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    /// Waits (up to a second) for ⌃ and ⌥ to come up, so apps that read the
    /// live keyboard state don't see the synthetic paste as ⌃⌥⌘V.
    private func fireWhenReleased(tries: Int) {
        let held = NSEvent.modifierFlags.intersection([.control, .option])
        guard held.isEmpty || tries == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.fireWhenReleased(tries: tries - 1)
            }
            return
        }
        action()
    }
}
