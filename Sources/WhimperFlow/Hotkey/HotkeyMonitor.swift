import AppKit
import WhimperFlowKit

/// Global push-to-talk key monitor built on a CGEvent tap (requires the
/// Accessibility permission). Watches `flagsChanged` for modifier hotkeys,
/// `keyDown`/`keyUp` for custom non-modifier hotkeys, and Escape while
/// dictating.
///
/// The watched hotkey's own events are swallowed so the system never acts on
/// them — critically, pressing fn (Globe) must not also open the emoji picker
/// or switch input sources, which would steal focus from the field the user
/// is dictating into.
final class HotkeyMonitor {
    /// All callbacks fire on the main queue.
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    /// Return true to swallow the Escape key press.
    var onEscape: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchedKeyCode: Int64 = HotkeyChoice.rightCommand.keyCode
    private var watchedIsModifier = true
    /// Non-nil when the configured hotkey is a chord (currently only
    /// fn + Control) rather than a single watched key code. Combo state is
    /// read straight off the flags on every `flagsChanged` event and is
    /// never swallowed — see `handle(type:event:)` for why that's safe.
    private var watchedComboFlags: CGEventFlags?
    private var isDown = false

    var isRunning: Bool { tap != nil }

    func setHotkey(_ choice: HotkeyChoice, customKeyCode: Int64? = nil) {
        isDown = false
        if choice == .fnControl {
            watchedComboFlags = [.maskSecondaryFn, .maskControl]
            watchedKeyCode = -1
            watchedIsModifier = true
            return
        }
        watchedComboFlags = nil
        if choice == .custom {
            // No recorded key yet: watch nothing (-1 matches no event).
            watchedKeyCode = customKeyCode ?? -1
            watchedIsModifier = false
        } else {
            watchedKeyCode = choice.keyCode
            watchedIsModifier = true
        }
    }

    /// Starts the tap. Returns false if the tap could not be created
    /// (missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        tap = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            if let combo = watchedComboFlags {
                let pressed = event.flags.isSuperset(of: combo)
                if pressed != isDown {
                    isDown = pressed
                    let callback = pressed ? onKeyDown : onKeyUp
                    DispatchQueue.main.async { callback?() }
                }
                // Never swallow a combo: macOS already cancels fn's own tap
                // gesture (emoji picker / input-source switch) the instant
                // Control is pressed alongside it, so passing every event
                // through keeps a lone fn tap working normally while the
                // chord still reaches us cleanly.
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard watchedIsModifier, keyCode == watchedKeyCode else {
                return Unmanaged.passUnretained(event)
            }
            let pressed = modifierIsActive(flags: event.flags)
            if pressed != isDown {
                isDown = pressed
                let callback = pressed ? onKeyDown : onKeyUp
                DispatchQueue.main.async { callback?() }
            }
            // Swallow the hotkey so the system doesn't also act on it (fn is
            // bound to the emoji picker / input-source switcher by default).
            return nil

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if !watchedIsModifier, keyCode == watchedKeyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat, !isDown {
                    isDown = true
                    let callback = onKeyDown
                    DispatchQueue.main.async { callback?() }
                }
                return nil // swallow, including auto-repeats while held
            }
            if keyCode == 53, let onEscape { // Escape
                var swallow = false
                // The tap callback runs on the main run loop already.
                swallow = onEscape()
                if swallow { return nil }
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if !watchedIsModifier, keyCode == watchedKeyCode {
                if isDown {
                    isDown = false
                    let callback = onKeyUp
                    DispatchQueue.main.async { callback?() }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func modifierIsActive(flags: CGEventFlags) -> Bool {
        switch watchedKeyCode {
        case HotkeyChoice.fn.keyCode:
            return flags.contains(.maskSecondaryFn)
        case HotkeyChoice.rightCommand.keyCode:
            return flags.contains(.maskCommand)
        case HotkeyChoice.rightOption.keyCode:
            return flags.contains(.maskAlternate)
        case HotkeyChoice.rightControl.keyCode, HotkeyChoice.leftControl.keyCode:
            return flags.contains(.maskControl)
        default:
            return false
        }
    }
}
