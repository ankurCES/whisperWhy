import AppKit
import Carbon.HIToolbox // TIS* keyboard-layout APIs for layout-aware key codes

// Pastes text into whatever has keyboard focus — FreeFlow's pipeline:
// 1. Snapshot + clear the pasteboard, declare transient markers so clipboard
//    managers (Maccy, Raycast, Paste…) skip recording the dictation.
// 2. Synthesize ⌘V via CGEvent at the session tap.
// 3. Restore the previous pasteboard contents.
// Requires Accessibility permission (synthesized keystrokes).

enum PasteService {
    /// Paste `text` at the current cursor. Preserves the clipboard when
    /// `preserveClipboard` is true (default).
    static func paste(_ text: String, preserveClipboard: Bool = true) {
        let pasteboard = NSPasteboard.general
        var snapshot: PasteboardSnapshot?
        if preserveClipboard { snapshot = PasteboardSnapshot(pasteboard: pasteboard) }

        pasteboard.clearContents()
        pasteboard.declareTypes([.string] + Self.transientTypes, owner: nil)
        pasteboard.setString(text, forType: .string)
        for type in Self.transientTypes {
            pasteboard.setString("", forType: type)
        }

        Self.pressCmdV()
        if let snapshot {
            // Restore after the target app has read the pasteboard. Cmd-V is
            // synchronous, but give the foreground app a beat to swallow it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                snapshot.restore(to: NSPasteboard.general)
            }
        }
    }

    /// nspasteboard.org transient markers: well-behaved clipboard managers
    /// skip entries carrying these.
    static var transientTypes: [NSPasteboard.PasteboardType] {
        [
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"),
        ]
    }

    static func pressCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = Self.keyCodeForCharacter("v") ?? 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
    }

    /// Resolves the virtual key code for a character on the *current* keyboard
    /// layout (FreeFlow's approach — don't hardcode ANSI "V" = 9).
    static func keyCodeForCharacter(_ character: String) -> CGKeyCode? {
        guard let char = character.lowercased().utf16.first else { return nil }
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let layout = ptr.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for keyCode in UInt16(0)..<UInt16(128) {
                var chars = [UniChar](repeating: 0, count: 4)
                var charCount = 0
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &charCount, &chars
                )
                if status == noErr, charCount > 0, chars[0] == char {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }
}

// Clipboard preservation: keep string contents only (rich types would need
// full pasteboard item serialization; text-in-text-out is the dictation case).
final class PasteboardSnapshot {
    private let strings: [String]

    init(pasteboard: NSPasteboard) {
        strings = (pasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: .string)
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for s in strings where !s.isEmpty {
            pasteboard.setString(s, forType: .string)
        }
    }
}
