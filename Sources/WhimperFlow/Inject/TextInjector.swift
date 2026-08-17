import AppKit
import ApplicationServices
import WhimperFlowKit

/// Delivers text into the frontmost app and reads the text around the cursor
/// so the engine can join utterances with correct spacing/capitalization.
@MainActor
final class TextInjector {
    enum InjectedKey {
        case returnKey, tab

        var keyCode: CGKeyCode {
            switch self {
            case .returnKey: return 36
            case .tab: return 48
            }
        }
    }

    private let pasteRestoreDelay: TimeInterval = 0.4
    /// Above this length, `auto` switches from typing to pasting.
    private let autoPasteThreshold = 120

    func inject(_ text: String, method: InjectionMethod) {
        guard !text.isEmpty else { return }
        switch method {
        case .paste:
            pasteInject(text)
        case .type:
            typeInject(text)
        case .auto:
            text.count > autoPasteThreshold ? pasteInject(text) : typeInject(text)
        }
    }

    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            postKey(51, source: source)
        }
    }

    func press(_ key: InjectedKey) {
        postKey(key.keyCode, source: CGEventSource(stateID: .combinedSessionState))
    }

    // MARK: - Typing

    /// Synthetic unicode keystrokes, chunked to the CGEvent payload limit.
    private func typeInject(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            let end = min(index + 18, utf16.count)
            var chunk = Array(utf16[index..<end])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                // Synthetic events inherit the *current* hardware modifier
                // state from the source; if the push-to-talk key is still
                // held, plain text would arrive as ⌘/fn shortcuts. Clear it.
                down.flags = []
                up.flags = []
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            index = end
        }
    }

    // MARK: - Pasting

    private func pasteInject(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteRestoreDelay) {
            self.restorePasteboard(pasteboard, items: saved)
        }
    }

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    // MARK: - Keys

    private func postKey(_ keyCode: CGKeyCode, source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        // Clear inherited hardware modifier state (see typeInject).
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Reads the text immediately before the insertion point of the focused UI
/// element via the Accessibility API. Returns nil when the app doesn't expose
/// its text (the caller falls back to remembered context).
enum AXContextReader {
    static func precedingText(maxLength: Int = 120) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return nil }

        let caret = min(max(0, range.location), text.utf16.count)
        guard caret > 0 else { return "" }
        let start = max(0, caret - maxLength)
        let utf16 = Array(text.utf16)
        return String(decoding: utf16[start..<caret], as: UTF16.self)
    }
}
