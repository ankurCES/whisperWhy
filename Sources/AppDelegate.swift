import AppKit
import SwiftUI
import Combine

// Owns the app lifetime: status item (tray), notch panel, dictation controller,
// pipeline, settings. Everything is wired here once and kept alive for the
// process lifetime.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?
    private var store: SettingsStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SettingsStore()
        self.store = store

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
