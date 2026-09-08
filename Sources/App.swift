import AppKit
import SwiftUI

// Entry point. The app is a menu-bar agent (LSUIElement) whose visible chrome
// is a notch-style panel pinned top-center plus a status item tray menu.
@main
struct WhisperWhyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All windows (settings) are created by the delegate. `App` needs one scene to exist.
        Settings { EmptyView() }
    }
}
