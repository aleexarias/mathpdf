import AppKit

/// The outline and handles of the selected image, over the pages and the
/// same size at any zoom. Clicks go through it to the pages.
final class SelectionOutline: NSView {
    private static let lineWidth: CGFloat = 1.5
    private static let handleSide: CGFloat = 8

    /// In this view's coordinates; nil shows nothing.
    private(set) var outlined: CGRect?
    /// A handle in the middle of each side too, for cropping.
    private(set) var hasSideHandles = false

    func show(_ rect: CGRect?, sideHandles: Bool) {
        guard rect != outlined || sideHandles != hasSideHandles else { return }
        outlined = rect
        hasSideHandles = sideHandles
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let outlined else { return }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: outlined)
        outline.lineWidth = Self.lineWidth
        outline.stroke()
        let xs = [outlined.minX, outlined.midX, outlined.maxX]
        let ys = [outlined.minY, outlined.midY, outlined.maxY]
        for (column, x) in xs.enumerated() {
            for (row, y) in ys.enumerated() where row != 1 || column != 1 {
                let isCorner = row != 1 && column != 1
                guard isCorner || hasSideHandles else { continue }
                drawHandle(at: CGPoint(x: x, y: y))
            }
        }
    }

    private func drawHandle(at centre: CGPoint) {
        let side = Self.handleSide
        let handle = NSBezierPath(
            rect: CGRect(
                x: centre.x - side / 2, y: centre.y - side / 2,
                width: side, height: side))
        NSColor.white.setFill()
        handle.fill()
        handle.lineWidth = Self.lineWidth
        handle.stroke()
    }
}
