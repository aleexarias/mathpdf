import CoreGraphics

/// A page as it's shown. Annotations are stored in page coordinates, which
/// turn with a rotated page, but what's written on a page stays upright on
/// screen: a box's width on screen can be its height on the page, and its top
/// left corner on screen any of its four. This converts between the two. Shown
/// coordinates start at the bottom left of the page as displayed.
public struct PageFrame: Equatable, Sendable {
    public let box: CGRect
    /// Clockwise, in degrees: 0, 90, 180 or 270.
    public let rotation: Int

    public init(box: CGRect, rotation: Int = 0) {
        self.box = box
        self.rotation = ((rotation % 360) + 360) % 360
    }

    public var shownSize: CGSize { turned(box.size) }

    /// A size on screen as a size on the page, or the other way round.
    public func turned(_ size: CGSize) -> CGSize {
        rotation % 180 == 0
            ? size : CGSize(width: size.height, height: size.width)
    }

    public func shown(_ point: CGPoint) -> CGPoint {
        let x = point.x - box.minX
        let y = point.y - box.minY
        switch rotation {
        case 90: return CGPoint(x: y, y: box.width - x)
        case 180: return CGPoint(x: box.width - x, y: box.height - y)
        case 270: return CGPoint(x: box.height - y, y: x)
        default: return CGPoint(x: x, y: y)
        }
    }

    public func onPage(_ point: CGPoint) -> CGPoint {
        let relative: CGPoint
        switch rotation {
        case 90: relative = CGPoint(x: box.width - point.y, y: point.x)
        case 180:
            relative = CGPoint(x: box.width - point.x, y: box.height - point.y)
        case 270: relative = CGPoint(x: point.y, y: box.height - point.x)
        default: relative = point
        }
        return CGPoint(x: relative.x + box.minX, y: relative.y + box.minY)
    }

    public func shown(_ rect: CGRect) -> CGRect {
        Self.rect(
            shown(rect.origin), shown(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    public func onPage(_ rect: CGRect) -> CGRect {
        Self.rect(
            onPage(rect.origin), onPage(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    /// A movement on the page as a movement on screen.
    public func shown(_ offset: CGSize) -> CGSize {
        switch rotation {
        case 90: CGSize(width: offset.height, height: -offset.width)
        case 180: CGSize(width: -offset.width, height: -offset.height)
        case 270: CGSize(width: -offset.height, height: offset.width)
        default: offset
        }
    }

    /// `rect`'s corners, on the page, in the order they have on screen.
    public func shownCorners(of rect: CGRect) -> (
        topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint,
        bottomRight: CGPoint
    ) {
        let low = CGPoint(x: rect.minX, y: rect.minY)
        let high = CGPoint(x: rect.maxX, y: rect.maxY)
        let lowHigh = CGPoint(x: rect.minX, y: rect.maxY)
        let highLow = CGPoint(x: rect.maxX, y: rect.minY)
        switch rotation {
        case 90: return (low, lowHigh, highLow, high)
        case 180: return (highLow, low, high, lowHigh)
        case 270: return (high, highLow, lowHigh, low)
        default: return (lowHigh, high, low, highLow)
        }
    }

    /// `rect`, in shown coordinates, moved in as little as needed to stay on
    /// the page.
    public func keptOnPage(_ rect: CGRect) -> CGRect {
        let size = shownSize
        var kept = rect
        kept.origin.x = max(0, min(rect.minX, size.width - rect.width))
        kept.origin.y = max(0, min(rect.minY, size.height - rect.height))
        return kept
    }

    /// A box of `size` on screen centred on `centre`, a point on the page,
    /// moved in where it would leave the page. On the page, as it's stored.
    public func box(ofShownSize size: CGSize, centredAt centre: CGPoint)
        -> CGRect
    {
        let point = shown(centre)
        return onPage(
            keptOnPage(
                CGRect(
                    x: point.x - size.width / 2, y: point.y - size.height / 2,
                    width: size.width, height: size.height)))
    }

    /// The middle of a line of text, leaving out what's above and below it, so
    /// looking up the text under `rect` doesn't reach the lines around it.
    public func middleOfLine(_ rect: CGRect) -> CGRect {
        let line = shown(rect)
        return onPage(line.insetBy(dx: 0, dy: line.height * 0.3))
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x),
            height: abs(a.y - b.y))
    }
}
