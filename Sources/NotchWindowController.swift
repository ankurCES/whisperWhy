import AppKit
import SwiftUI
import QuartzCore
import Combine

// Places and shows/hides the notch panel. Anchors: the three top-edge spots,
// left/right screen edges (vertically centered), and a floating dock hovering
// just above the bottom edge. Edge positions lay the pill out vertically so
// the content reads top-to-bottom.

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
    /// Where the pill anchors on screen. Live-updatable from Settings.
    var position: NotchPosition {
        didSet { if oldValue != position { relayout() } }
    }
    /// Called when the user taps the mic button in the notch. Wired to
    /// DictationController.toggleRecording by AppDelegate.
    var onMicButton: (() -> Void)?
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchRootView>?
    private var cancellables = Set<AnyCancellable>()

    init(model: NotchViewModel, position: NotchPosition = .topRight) {
        self.model = model
        self.position = position
        model.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
    }

    func show() {
        guard panel == nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = Self.frame(for: Self.size(for: model.state, at: position), in: screen, at: position)
        let panel = NotchPanel(contentRect: frame)
        var root = NotchRootView(model: model, vertical: position.isVertical)
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

    /// Re-frame the panel when the state changes size or the position changes.
    /// Animates the resize so the pill springs open on start and settles
    /// closed on release — and glides when the user changes anchor.
    private func relayout() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = Self.size(for: model.state, at: position)
        let target = Self.frame(for: size, in: screen, at: position)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.4, 0.4, 1.0) // overshoot spring
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true, animate: true)
        }
        // Orientation only changes when the user picks a different anchor.
        hostingView?.rootView.vertical = position.isVertical
    }

    /// Size of the panel for a state at a given anchor. Vertical anchors swap
    /// width/height so the pill is tall instead of wide on the screen edges.
    static func size(for state: NotchState, at position: NotchPosition = .topCenter) -> NSSize {
        let base: NSSize
        switch state {
        case .idle: base = collapsedSize
        case .recording: base = NSSize(width: 170, height: 40)
        case .transcribing, .cleaning: base = NSSize(width: 170, height: 40)
        case .done: base = NSSize(width: 54, height: 40)
        case .error: base = NSSize(width: 340, height: 40)
        }
        return position.isVertical ? NSSize(width: base.height, height: base.width) : base
    }

    static func frame(for size: NSSize, in screen: NSScreen, at position: NotchPosition = .topCenter) -> NSRect {
        let screenFrame = screen.frame
        let margin: CGFloat = 24
        let x, y: CGFloat
        switch position {
        case .topLeft:
            x = screenFrame.minX + margin
            y = screenFrame.maxY - size.height
        case .topCenter:
            x = screenFrame.midX - size.width / 2
            y = screenFrame.maxY - size.height
        case .topRight:
            x = screenFrame.maxX - size.width - margin
            y = screenFrame.maxY - size.height
        case .leftCenter:
            x = screenFrame.minX + margin / 2
            y = screenFrame.midY - size.height / 2
        case .rightCenter:
            x = screenFrame.maxX - size.width - margin / 2
            y = screenFrame.midY - size.height / 2
        case .bottomDock:
            x = screenFrame.midX - size.width / 2
            y = screenFrame.minY + 10 // hover just above the bottom edge, Dock-style
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
