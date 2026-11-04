import AppKit

/// What follows the pointer while pages are dragged: a small sheet of
/// paper with a folded corner, or three stacked, over "Page 4" or "3 Pages".
struct PageDragImage {
    let image: NSImage

    private static let sheet = CGSize(width: 14, height: 18)
    private static let fold: CGFloat = 4
    private static let stackOffset: CGFloat = 2.5
    private static let margin: CGFloat = 3

    init(label: String, stacked: Bool) {
        let sheets = stacked ? 3 : 1
        let behind = CGFloat(sheets - 1) * Self.stackOffset
        let text = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
        let pill = CGSize(
            width: text.size().width.rounded(.up) + 10,
            height: text.size().height.rounded(.up) + 2)
        let stack = CGSize(
            width: Self.sheet.width + behind,
            height: Self.sheet.height + behind)
        let size = CGSize(
            width: max(stack.width, pill.width) + 2 * Self.margin,
            height: stack.height + 3 + pill.height + 2 * Self.margin)
        // The front sheet is the lowest and leftmost of the stack.
        let front = CGPoint(
            x: (size.width - stack.width) / 2, y: Self.margin + behind)

        image = NSImage(size: size, flipped: true) { _ in
            for index in (0..<sheets).reversed() {
                let offset = CGFloat(index) * Self.stackOffset
                Self.drawSheet(
                    at: CGPoint(x: front.x + offset, y: front.y - offset))
            }
            let pillRect = CGRect(
                x: (size.width - pill.width) / 2,
                y: front.y + Self.sheet.height + 3, width: pill.width,
                height: pill.height)
            NSColor(white: 0.15, alpha: 0.85).setFill()
            NSBezierPath(
                roundedRect: pillRect, xRadius: pill.height / 2,
                yRadius: pill.height / 2
            ).fill()
            text.draw(at: CGPoint(x: pillRect.minX + 5, y: pillRect.minY + 1))
            return true
        }
    }

    /// A white sheet with its top-right corner folded over.
    private static func drawSheet(at origin: CGPoint) {
        let rect = CGRect(origin: origin, size: sheet)
        let outline = NSBezierPath()
        outline.move(to: CGPoint(x: rect.minX, y: rect.minY))
        outline.line(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        outline.line(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        outline.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        outline.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        outline.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.55, alpha: 1).setStroke()
        outline.lineWidth = 0.75
        outline.stroke()

        let flap = NSBezierPath()
        flap.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        flap.line(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        flap.line(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        flap.close()
        NSColor(white: 0.85, alpha: 1).setFill()
        flap.fill()
        flap.lineWidth = 0.75
        flap.stroke()
    }
}
