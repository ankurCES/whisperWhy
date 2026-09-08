import Cocoa
import Carbon.HIToolbox // kVK_Escape
import os.log

// Global hotkey via CGEvent tap — FreeFlow's approach. Listens for flagsChanged
// (Fn and modifier presses) and keyDown/keyUp globally. Needs Accessibility
// permission (Input Monitoring for flagsChanged); the app directs the user to
// System Settings on failure.

enum ShortcutEvent: Equatable {
    case startHold      // hold-to-talk began
    case endHold        // hold-to-talk released → finalize
    case toggle         // tap-toggle started/stopped
}

final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDown = false
    private var cmdDown = false
    private var recording = false
    private var tapMode = false // latched via Cmd during a hold

    /// Modifier requirements, mirroring SettingsStore.ShortcutConfig.
    /// When requireCommand is true the *activation* is ⌘Fn (a chord), and
    /// holding keeps recording until both are released.
    var requireCommand = true
    var requireOption = false
    var requireControl = false
    var requireShift = false

    var onEvent: ((ShortcutEvent) -> Void)?

    func start() throws {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, refcon in
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                return manager.handle(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.tapUnavailable
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        fnDown = false
        cmdDown = false
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        // The tap's userInfo is an unretained self; tearing the tap down here
        // prevents a dangling callback if the manager is ever released early.
        stop()
    }

    /// Whether the event tap is actually live. The tap silently fails to
    /// deliver events without Accessibility/Input Monitoring, so the UI
    /// checks this to warn the user instead of looking dead.
    var isActive: Bool { eventTap != nil }

    /// Required modifier set for activation (from SettingsStore.ShortcutConfig).
    private func requiredModsSatisfied(_ flags: CGEventFlags) -> Bool {
        if requireCommand && !flags.contains(.maskCommand) { return false }
        if requireOption && !flags.contains(.maskAlternate) { return false }
        if requireControl && !flags.contains(.maskControl) { return false }
        if requireShift && !flags.contains(.maskShift) { return false }
        return true
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch event.type {
        case .flagsChanged:
            let newFn = event.flags.contains(.maskSecondaryFn)
            let newCmd = event.flags.contains(.maskCommand)

            if newFn != fnDown {
                fnDown = newFn
                if newFn {
                    // Fn edge. Activation only counts when the required
                    // modifiers are also held (⌘Fn, not bare Fn).
                    if !recording && requiredModsSatisfied(event.flags) {
                        recording = true
                        tapMode = false
                        onEvent?(.startHold)
                    }
                } else if recording && !tapMode {
                    recording = false
                    onEvent?(.endHold)
                }
            }

            // Releasing a required modifier while recording ends the hold —
            // otherwise lifting ⌘ before Fn would leave the mic stuck on.
            if recording && !tapMode && !requiredModsSatisfied(event.flags) {
                recording = false
                fnDown = false
                onEvent?(.endHold)
                cmdDown = newCmd
                return Unmanaged.passUnretained(event)
            }

            // While recording in hold mode, tapping the *other* modifier
            // (Cmd if it's not required) latches tap mode so you can release
            // both keys. This mirrors FreeFlow's "extend hold to latch".
            if recording, !tapMode, newCmd && !cmdDown && !requireCommand {
                tapMode = true
                onEvent?(.toggle)
            }
            cmdDown = newCmd

        case .keyDown:
            if recording && event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
                recording = false
                tapMode = false
                onEvent?(.endHold) // caller treats as cancel via pipeline hook
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// True when a recording session is active (hold or latched).
    var isRecording: Bool { recording }

    /// Called by the controller when it has finished a latched session.
    func endLatch() {
        if recording && tapMode {
            recording = false
            tapMode = false
            onEvent?(.endHold)
        }
    }

    enum HotkeyError: LocalizedError {
        case tapUnavailable
        var errorDescription: String? {
            "Hotkey monitoring couldn't start. Grant Accessibility + Input Monitoring in System Settings → Privacy & Security, then relaunch WhisperWhy."
        }
    }
}
