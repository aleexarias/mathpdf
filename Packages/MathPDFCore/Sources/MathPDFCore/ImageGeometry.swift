import CoreGraphics

/// Where an image goes as it's resized or cropped, worked out as seen on
/// screen, so it's right on rotated pages too.
public enum ImageGeometry {
    /// The shortest an image's shorter side can be, in points.
    public static let smallestSide: CGFloat = 16

    /// A corner of a box, as seen on screen.
    public enum Corner: CaseIterable, Sendable {
        case bottomLeft, bottomRight, topLeft, topRight

        public var isRight: Bool { self == .bottomRight || self == .topRight }
        public var isTop: Bool { self == .topLeft || self == .topRight }

        public func point(of rect: CGRect) -> CGPoint {
            CGPoint(
                x: isRight ? rect.maxX : rect.minX,
                y: isTop ? rect.maxY : rect.minY)
        }

        public var sides: Sides {
            [isRight ? .right : .left, isTop ? .top : .bottom]
        }

        var opposite: Corner {
            switch self {
            case .bottomLeft: .topRight
            case .bottomRight: .topLeft
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            }
        }
    }

    /// `bounds` with `corner` dragged by `offset` on the page. The opposite
    /// corner stays put and the shape is kept: the drag counts as far as it
    /// goes along the diagonal, so dragging sideways resizes too. It stays on
    /// the page, no smaller than `smallestSide`.
    public static func resized(
        _ bounds: CGRect, dragging corner: Corner, by offset: CGSize,
        on page: PageFrame
    ) -> CGRect {
        let shown = page.shown(bounds)
        let moved = page.shown(offset)
        let anchor = corner.opposite.point(of: shown)
        let start = corner.point(of: shown)
        let diagonal = CGVector(dx: start.x - anchor.x, dy: start.y - anchor.y)
        let pointer = CGVector(
            dx: diagonal.dx + moved.width, dy: diagonal.dy + moved.height)
        let along =
            (pointer.dx * diagonal.dx + pointer.dy * diagonal.dy)
            / (diagonal.dx * diagonal.dx + diagonal.dy * diagonal.dy)

        let aspect = shown.width / shown.height
        let room = page.shownSize
        let widest = min(
            corner.isRight ? room.width - anchor.x : anchor.x,
            (corner.isTop ? room.height - anchor.y : anchor.y) * aspect)
        let narrowest = min(smallestSide * max(aspect, 1), widest)
        let width = max(min(shown.width * along, widest), narrowest)
        let height = width / aspect
        return page.onPage(
            CGRect(
                x: corner.isRight ? anchor.x : anchor.x - width,
                y: corner.isTop ? anchor.y : anchor.y - height,
                width: width, height: height))
    }

    /// The sides of the kept part of an image that a crop handle moves.
    public struct Sides: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let left = Sides(rawValue: 1)
        public static let right = Sides(rawValue: 2)
        public static let top = Sides(rawValue: 4)
        public static let bottom = Sides(rawValue: 8)

        /// One on each corner and side; corners first, as they win where
        /// they're close.
        public static let cropHandles: [Sides] =
            Corner.allCases.map(\.sides) + [.left, .right, .top, .bottom]

        /// Where its handle is on `rect`.
        public func point(of rect: CGRect) -> CGPoint {
            CGPoint(
                x: contains(.left)
                    ? rect.minX : contains(.right) ? rect.maxX : rect.midX,
                y: contains(.bottom)
                    ? rect.minY : contains(.top) ? rect.maxY : rect.midY)
        }
    }

    /// The whole image that `bounds` shows the `crop` of, on the page.
    public static func whole(
        _ bounds: CGRect, crop: CGRect, on page: PageFrame
    ) -> CGRect {
        page.onPage(whole(shown: page.shown(bounds), crop: crop))
    }

    /// `sides` of the kept part dragged by `offset` on the page. The image
    /// keeps its scale and place, so what's dragged over is hidden or
    /// revealed. The kept part stays within the image and the page, no
    /// smaller than `smallestSide`.
    public static func cropped(
        _ bounds: CGRect, crop: CGRect, moving sides: Sides,
        by offset: CGSize, on page: PageFrame
    ) -> (bounds: CGRect, crop: CGRect) {
        let shown = page.shown(bounds)
        let moved = page.shown(offset)
        let whole = whole(shown: shown, crop: crop)
        let limit = whole.intersection(
            CGRect(origin: .zero, size: page.shownSize))
        /// A side moved by `delta`, between `low` and `high`, or left where
        /// it is if there's no room.
        func moving(
            _ side: CGFloat, by delta: CGFloat, from low: CGFloat,
            to high: CGFloat
        ) -> CGFloat {
            low <= high ? min(max(side + delta, low), high) : side
        }
        var kept = (
            left: shown.minX, right: shown.maxX, bottom: shown.minY,
            top: shown.maxY
        )
        if sides.contains(.left) {
            kept.left = moving(
                kept.left, by: moved.width, from: limit.minX,
                to: kept.right - smallestSide)
        }
        if sides.contains(.right) {
            kept.right = moving(
                kept.right, by: moved.width, from: kept.left + smallestSide,
                to: limit.maxX)
        }
        if sides.contains(.bottom) {
            kept.bottom = moving(
                kept.bottom, by: moved.height, from: limit.minY,
                to: kept.top - smallestSide)
        }
        if sides.contains(.top) {
            kept.top = moving(
                kept.top, by: moved.height, from: kept.bottom + smallestSide,
                to: limit.maxY)
        }
        let rect = CGRect(
            x: kept.left, y: kept.bottom, width: kept.right - kept.left,
            height: kept.top - kept.bottom)
        return (
            page.onPage(rect),
            CGRect(
                x: (rect.minX - whole.minX) / whole.width,
                y: (whole.maxY - rect.maxY) / whole.height,
                width: rect.width / whole.width,
                height: rect.height / whole.height)
        )
    }

    /// The whole image again, at the same scale around the same centre,
    /// moved in to stay on the page, and made smaller if it can't fit.
    public static func uncropped(
        _ bounds: CGRect, crop: CGRect, on page: PageFrame
    ) -> CGRect {
        let shown = page.shown(bounds)
        let whole = whole(shown: shown, crop: crop)
        let room = page.shownSize
        let fit = min(1, room.width / whole.width, room.height / whole.height)
        let size = CGSize(
            width: whole.width * fit, height: whole.height * fit)
        return page.onPage(
            page.keptOnPage(
                CGRect(
                    x: shown.midX - size.width / 2,
                    y: shown.midY - size.height / 2,
                    width: size.width, height: size.height)))
    }

    /// The crop is from the image's top left; shown coordinates from the
    /// bottom left.
    private static func whole(shown: CGRect, crop: CGRect) -> CGRect {
        let width = shown.width / crop.width
        let height = shown.height / crop.height
        return CGRect(
            x: shown.minX - crop.minX * width,
            y: shown.maxY + crop.minY * height - height,
            width: width, height: height)
    }
}
