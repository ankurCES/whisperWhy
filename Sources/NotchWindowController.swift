import AppKit
import SwiftUI
import Combine

// Places and shows/hides the notch panel at the top-center of the screen,
// flush with the very top edge (snug against the hardware notch on notched
// MacBooks, still centered where there is none).

@MainActor
final class NotchWindowController {
    static let collapsedSize = NSSize(width: 190, height: 34)

    let model: NotchViewModel
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
        let root = NotchRootView(model: model)
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        panel.onClick = { [weak self] in self?.model.toggleExpanded() }
        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    /// Re-frame the panel when the state changes size.
    private func relayout() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = Self.size(for: model.state)
        panel.setFrame(Self.frame(for: size, in: screen), display: true, animate: false)
    }

    static func size(for state: NotchState) -> NSSize {
        switch state {
        case .idle: return collapsedSize
        case .recording: return NSSize(width: 230, height: 40)
        case .transcribing, .cleaning: return NSSize(width: 230, height: 40)
        case .done, .error: return NSSize(width: 340, height: 40)
        }
    }

    static func frame(for size: NSSize, in screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
