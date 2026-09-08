import AppKit
import SwiftUI
import QuartzCore
import Combine

// Places and shows/hides the notch panel at the top-center of the screen,
// flush with the very top edge (snug against the hardware notch on notched
// MacBooks, still centered where there is none).

/// NSHostingView that accepts first-mouse clicks so the notch pill works
/// with a single click even when the app isn't the active (key) window —
/// without this, the first click only activates the panel and the user has
/// to click twice to start/stop recording.
final class ClickThroughHostingView: NSHostingView<NotchRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchWindowController {
    static let collapsedSize = NSSize(width: 132, height: 34)

    let model: NotchViewModel
    /// Called when the user taps the mic button in the notch. Wired to
    /// DictationController.toggleRecording by AppDelegate.
    var onMicButton: (() -> Void)?
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchRootView>?
    private var cancellables = Set<AnyCancellable>()

    init(model: NotchViewModel) {
        self.model = model
        model.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
    }

    func show() {
        guard panel == nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = Self.frame(for: Self.size(for: model.state), in: screen)
        let panel = NotchPanel(contentRect: frame)
        var root = NotchRootView(model: model)
        root.onMicButton = { [weak self] in self?.onMicButton?() }
        let hosting = ClickThroughHostingView(rootView: root)
        panel.contentView = hosting
        // Don't intercept clicks at the panel level — SwiftUI buttons inside
        // the hosting view handle their own hit-testing.
        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    /// Re-frame the panel when the state changes size. Animates the resize so
    /// the pill springs open on hotkey press and settles closed on release —
    /// this is the visual feedback the user asked for.
    private func relayout() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = Self.size(for: model.state)
        let target = Self.frame(for: size, in: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.4, 0.4, 1.0) // overshoot spring
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true, animate: true)
        }
    }

    static func size(for state: NotchState) -> NSSize {
        switch state {
        case .idle: return collapsedSize
        case .recording: return NSSize(width: 170, height: 40)
        case .transcribing, .cleaning: return NSSize(width: 170, height: 40)
        case .done: return NSSize(width: 54, height: 40)
        case .error: return NSSize(width: 340, height: 40)
        }
    }

    static func frame(for size: NSSize, in screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
