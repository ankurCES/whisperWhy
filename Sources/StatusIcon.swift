import AppKit

// Template (monochrome) status bar icon: a small waveform glyph. Drawn in code
// so the repo needs no binary assets; macOS recolors template images to match
// the menu bar appearance.
enum StatusIcon {
    static func template() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)

            // Five vertical bars of varying height, centered — a waveform.
            let heights: [CGFloat] = [5, 9, 13, 9, 5]
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1.6
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            var x = rect.midX - totalWidth / 2
            for h in heights {
                let bar = NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
                let path = NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1)
                path.fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
