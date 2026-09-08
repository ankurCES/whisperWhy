import Cocoa
import Carbon.HIToolbox // kVK_Escape
import os.log

// Global hotkey via CGEvent tap. The configured COMBINATION (e.g. ⌥Space,
// ⌘⇧D, Fn alone) is the trigger: pressing it toggles recording on/off.
// Press once → record starts; press again → record stops and the pipeline
// (transcribe → LLM cleanup → paste) runs. Esc while recording cancels.
//
// A non-Fn trigger requires at least one modifier — a bare letter or Space
// would fire while typing. Fn alone is the only allowed unmodified trigger
// because it produces no text. Needs Accessibility + Input Monitoring.

enum ShortcutEvent: Equatable {
    case startHold   // toggle-press: begin recording
    case endHold     // toggle-press: stop recording → run pipeline
    case cancel      // Esc during recording: discard
    case toggle      // unused by the controller; kept for API stability
}

final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDown = false
    private var recording = false

    /// Required modifier set for the combination (from SettingsStore.ShortcutConfig).
    var requireCommand = true
    var requireOption = false
    var requireControl = false
    var requireShift = false

    var onEvent: ((ShortcutEvent) -> Void)?

    /// The trigger key this manager listens for, as a CGKeyCode.
    /// Default 99 = Fn/Globe.
    private(set) var triggerKeyCode: CGKeyCode = 99

    private var triggerIsFn: Bool { triggerKeyCode == 99 }

    /// A combination is only valid if it includes a modifier — except Fn.
    /// Bare Space/letters would hijack normal typing globally.
    var combinationIsValid: Bool {
        triggerIsFn || requireCommand || requireOption || requireControl || requireShift
    }

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

    /// Whether the event tap is actually live. The tap silently fails to
    /// deliver events without Accessibility/Input Monitoring, so the UI
    /// checks this to warn the user instead of looking dead.
    var isActive: Bool { eventTap != nil }

    private func requiredModsSatisfied(_ flags: CGEventFlags) -> Bool {
        if requireCommand && !flags.contains(.maskCommand) { return false }
        if requireOption && !flags.contains(.maskAlternate) { return false }
        if requireControl && !flags.contains(.maskControl) { return false }
        if requireShift && !flags.contains(.maskShift) { return false }
        return true
    }

    func setTriggerKeyCode(_ keyCode: CGKeyCode) {
        dispatchPrecondition(condition: .onQueue(.main))
        triggerKeyCode = keyCode
        if recording {
            recording = false
            fnDown = false
            onEvent?(.endHold)
        }
    }

    private func toggleRecording() {
        if recording {
            recording = false
            fnDown = false
            onEvent?(.endHold)
        } else {
            recording = true
            onEvent?(.startHold)
        }
    }

    private func cancelRecording() {
        guard recording else { return }
        recording = false
        fnDown = false
        onEvent?(.cancel)
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        switch event.type {
        case .flagsChanged:
            let newFn = event.flags.contains(.maskSecondaryFn)
            // Fn/Globe trigger: toggle on each Fn press edge, provided the
            // required modifiers (if any) are held at that moment.
            if triggerIsFn, newFn != fnDown {
                fnDown = newFn
                if newFn && requiredModsSatisfied(event.flags) {
                    toggleRecording()
                }
            }
        case .keyDown:
            if recording && keyCode == CGKeyCode(kVK_Escape) {
                cancelRecording()
                break
            }
            // Combination trigger: the key arrives as keyDown with its
            // modifiers already in flags. Key repeat is ignored so holding
            // the combo doesn't flicker on/off.
            if !triggerIsFn, keyCode == triggerKeyCode,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               combinationIsValid, requiredModsSatisfied(event.flags) {
                toggleRecording()
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// True when a recording session is active.
    var isRecording: Bool { recording }

    enum HotkeyError: LocalizedError {
        case tapUnavailable
        var errorDescription: String? {
            "Hotkey monitoring couldn't start. Grant Accessibility + Input Monitoring in System Settings → Privacy & Security, then relaunch WhisperWhy."
        }
    }
}
