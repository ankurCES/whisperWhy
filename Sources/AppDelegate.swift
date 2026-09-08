import AppKit
import ApplicationServices
import Combine
import SwiftUI

// Owns the app lifetime: status item (tray), notch panel, dictation controller,
// pipeline, settings. Everything is wired here once and kept alive for the
// process lifetime.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?
    private var store: SettingsStore?
    private var dictation: DictationController?
    private var notchController: NotchWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SettingsStore()
        self.store = store

        let dictation = DictationController(settings: store)
        self.dictation = dictation
        let notch = NotchWindowController(model: dictation.notchModel)
        notch.show()
        self.notchController = notch
        dictation.start()
        // Request + watch Accessibility trust; without it the event tap never
        // receives keystrokes, which is why the hotkey looked dead.
        watchAccessibilityTrust(model: dictation.notchModel)

        // Push hotkey changes to the manager live, the moment Settings saves.
        store.$hotkey
            .dropFirst() // initial value already applied by dictation.start()
            .receive(on: RunLoop.main)
            .sink { [weak dictation] _ in dictation?.applyShortcut() }
            .store(in: &cancellables)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = StatusIcon.template()
            button.toolTip = "WhisperWhy"
        }
        statusItem.menu = buildMenu()
        self.statusItem = statusItem

        // Keep the agent app alive even with no windows.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.shutdown()
    }

    // MARK: - Accessibility (hotkey-listening) permission

    /// Request Accessibility trust on first launch, then watch it so the notch
    /// can show an actionable banner while the permission is missing. This is
    /// the call that actually makes macOS show the grant dialog; nothing else
    /// in the app ever triggers it, which is why the prompt never appeared.
    private func watchAccessibilityTrust(model: NotchViewModel) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("WhisperWhy accessibility: trusted=\(trusted)")
        MainActor.assumeIsolated { model.accessibilityDenied = !trusted }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak model] _ in
            let now = AXIsProcessTrusted()
            Task { @MainActor [weak model] in
                guard let model else { return }
                if now != !model.accessibilityDenied {
                    model.accessibilityDenied = !now
                    NSLog("WhisperWhy accessibility: trusted changed -> \(now)")
                }
            }
        }
    }

    // MARK: - Tray menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }
}

extension AppDelegate: NSMenuDelegate {
    // Menu is rebuilt on open so hotkey + provider state are always fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "WhisperWhy", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(store: store ?? SettingsStore())
        }
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
