import AppKit
import SwiftUI

// A button that, while armed, captures the next key press (or Fn press) and
// turns it into a ShortcutConfig. This is how the user changes the dictation
// hotkey without knowing key codes. Esc cancels the capture.

struct HotkeyRecorderButton: View {
    @Binding var shortcut: ShortcutConfig
    @State private var capturing = false
    @State private var monitor: Any?
    @State private var flagsMonitor: Any?

    var body: some View {
        Button(action: startCapture) {
            Text(capturing ? "Press a key…  (Esc to cancel)" : shortcut.displayName)
                .font(.system(size: 12, weight: .medium).monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(capturing ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(capturing ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stopCapture)
    }

    private func startCapture() {
        stopCapture()
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // kVK_Escape
                stopCapture()
                return nil
            }
            capture(keyCode: UInt32(event.keyCode), flags: event.modifierFlags)
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            // Fn/Globe arrives as flagsChanged with keyCode 99; its NSEvent
            // flag (maskSecondaryFn, raw 1<<23) is not exposed on
            // NSEvent.ModifierFlags, so match by keyCode + the raw bit.
            if event.keyCode == 99, event.modifierFlags.rawValue & (1 << 23) != 0 {
                capture(keyCode: UInt32(event.keyCode), flags: event.modifierFlags)
            }
            return event
        }
    }

    private func capture(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        // The trigger key itself never counts as a modifier.
        var config = ShortcutConfig.default
        config.keyCode = keyCode
        config.requireCommand = flags.contains(.command)
        config.requireOption = flags.contains(.option)
        config.requireControl = flags.contains(.control)
        config.requireShift = flags.contains(.shift)
        // Fn/Globe as trigger: don't require it as a modifier, just the key.
        shortcut = config
        stopCapture()
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor); self.flagsMonitor = nil }
        capturing = false
    }
}

extension ShortcutConfig {
    /// Human-readable name: "⌘Fn", "⌥F5", "⌘⇧Space", etc.
    var displayName: String {
        var parts = ""
        if requireControl { parts += "⌃" }
        if requireOption { parts += "⌥" }
        if requireShift { parts += "⇧" }
        if requireCommand { parts += "⌘" }
        parts += Self.keyName(for: keyCode)
        return parts
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 99: return "Fn"
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"
        case 100: return "F8"; case 101: return "F9"; case 103: return "F11"; case 105: return "F13"
        case 109: return "F10"; case 111: return "F12"
        case 122: return "F1"; case 120: return "F2"; case 118: return "F4"
        default:
            // Letters/digits: keyCode → character via UCKeyTranslate is overkill
            // here; the common ANSI letter block is contiguous from 0.
            let letters: [UInt32: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
                8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
                38: "J", 40: "K", 45: "N", 46: "M",
                18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
                28: "8", 25: "9", 29: "0",
            ]
            return letters[keyCode] ?? "Key \(keyCode)"
        }
    }
}
