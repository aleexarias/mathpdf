import CoreGraphics

/// A zoom that follows the view's size.
public enum PageFit: String, Codable, Sendable {
    /// The pages are as wide as the view.
    case width
    /// A whole page is in view.
    case page

    /// The zoom at which pages of this size fit `area` this way. The height
    /// is only worked out if it matters.
    public func scale(
        width: CGFloat, height: @autoclosure () -> CGFloat, in area: CGSize
    ) -> CGFloat {
        let widthScale = area.width / width
        switch self {
        case .width: return widthScale
        case .page: return min(widthScale, area.height / height())
        }
    }

    /// The fit that Zoom to Fit goes to from `current`: the width first, then
    /// it alternates with the whole page.
    public static func next(after current: PageFit?) -> PageFit {
        current == .width ? .page : .width
    }
}
