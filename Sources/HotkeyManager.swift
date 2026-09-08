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

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch event.type {
        case .flagsChanged:
            let newFn = event.flags.contains(.maskSecondaryFn)
            let newCmd = event.flags.contains(.maskCommand)
            if newFn != fnDown {
                fnDown = newFn
                if newFn {
                    // Fn down: begin hold (or keep going if already latched).
                    if !recording {
                        recording = true
                        tapMode = false
                        onEvent?(.startHold)
                    }
                } else if recording && !tapMode {
                    recording = false
                    onEvent?(.endHold)
                }
            }
            // Cmd pressed while holding Fn latches tap mode (FreeFlow's
            // "extend your hold shortcut to latch" behavior).
            if recording, !tapMode, newCmd && !cmdDown {
                tapMode = true
                onEvent?(.toggle)
            }
            cmdDown = newCmd
        case .keyDown:
            if recording && event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
                recording = false
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
            onEvent?(.endHold)
        }
    }

    enum HotkeyError: LocalizedError {
        case tapUnavailable
        var errorDescription: String? {
            "Global hotkey monitoring could not start. WhisperWhy needs Accessibility + Input Monitoring permission (System Settings → Privacy & Security)."
        }
    }
}
