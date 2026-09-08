import AppKit

// Borderless, non-activating panel pinned to the top-center of the screen —
// the codenotch approach: floats over everything (menu bar, full-screen apps),
// never steals focus from whatever the user is doing.

final class NotchPanel: NSPanel {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let view = contentView,
              view.hitTest(event.locationInWindow) != nil
        else { return super.mouseDown(with: event) }
        onClick?()
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }
}
