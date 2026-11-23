import CoreGraphics
import Foundation
import MathPDFCore
import os

/// Images decoded for drawing, at about the size they're shown. Pages are
/// drawn in tiles, at every zoom, so full-size images would be decoded and
/// held over and over. Sizes go in powers of two, so zooming
/// doesn't decode anew at every step. Safe to use from any thread, as PDFKit
/// draws on several.
public final class ImageCache: @unchecked Sendable {
    /// Posted on the main thread with the image's `hash` in `userInfo`, once
    /// a size of it is ready or it's found to be missing.
    public static let didLoad = Notification.Name("ImageCacheDidLoad")

    public enum Lookup {
        case image(CGImage)
        case loading
        /// Not stored, or damaged.
        case missing
    }

    private static let smallestSide = 64
    private static let largestSide = 4096

    private let store: ImageStore
    private let decoder = Decoder()
    private let images = NSCache<NSString, CGImage>()
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var loading: [String: Task<Void, Never>] = [:]
        var missing: Set<String> = []
    }

    public init(store: ImageStore, memoryLimit: Int = 200_000_000) {
        self.store = store
        images.totalCostLimit = memoryLimit
    }

    /// The image with a longer side of at least `pixels`, if it's ready.
    /// While it loads, the nearest size already decoded, if any.
    public func image(_ image: ImageReference, longestSide pixels: CGFloat)
        -> Lookup
    {
        let hash = image.hash
        if state.withLock({ $0.missing.contains(hash) }) { return .missing }
        let wanted = Self.size(showing: pixels, of: image)
        if let ready = images.object(forKey: key(hash, wanted)) {
            return .image(ready)
        }
        load(hash, longestSide: wanted)
        let nearest = Self.sizes(upTo: image).reversed().lazy.compactMap {
            self.images.object(forKey: self.key(hash, $0))
        }.first
        return nearest.map(Lookup.image) ?? .loading
    }

    /// Returns once the image is decoded to be shown `pixels` big, or found
    /// to be missing.
    public func prepare(_ image: ImageReference, longestSide pixels: CGFloat)
        async
    {
        let wanted = Self.size(showing: pixels, of: image)
        guard images.object(forKey: key(image.hash, wanted)) == nil else {
            return
        }
        await load(image.hash, longestSide: wanted).value
    }

    /// Lets an image that was missing be looked for again, once it's stored.
    public func stored(_ hash: String) {
        state.withLock { _ = $0.missing.remove(hash) }
    }

    /// Powers of two from the smallest, ending with the image's own size
    /// when that's smaller than the largest. A larger image goes up to at
    /// most half its own size: anything over half takes decoding all of it,
    /// for a moment over twice its memory, while a JPEG or HEIC decodes at a
    /// half, quarter or eighth for little.
    static func sizes(upTo image: ImageReference) -> [Int] {
        let own = Int(max(image.pixelSize.width, image.pixelSize.height))
        let top = own <= largestSide ? own : min(own / 2, largestSide)
        var sizes = Array(
            sequence(first: smallestSide) { $0 * 2 }.prefix { $0 < top })
        sizes.append(top)
        return sizes
    }

    /// The smallest size at least `pixels`, or the largest.
    private static func size(showing pixels: CGFloat, of image: ImageReference)
        -> Int
    {
        let sizes = sizes(upTo: image)
        return sizes.first { CGFloat($0) >= pixels } ?? sizes[sizes.count - 1]
    }

    private func key(_ hash: String, _ side: Int) -> NSString {
        "\(hash)-\(side)" as NSString
    }

    /// The decoding of that size, started unless it already is.
    @discardableResult
    private func load(_ hash: String, longestSide side: Int)
        -> Task<Void, Never>
    {
        let name = key(hash, side) as String
        return state.withLock { state in
            if let loading = state.loading[name] { return loading }
            let loading = Task.detached(priority: .userInitiated) { [self] in
                let decoded: CGImage? =
                    if let data = await store.data(for: hash) {
                        await decoder.upright(data, longestSide: side)
                    } else { nil }
                if let decoded {
                    images.setObject(
                        decoded, forKey: name as NSString,
                        cost: decoded.bytesPerRow * decoded.height)
                }
                self.state.withLock {
                    $0.loading[name] = nil
                    if decoded == nil { $0.missing.insert(hash) }
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.didLoad, object: self,
                        userInfo: ["hash": hash])
                }
            }
            state.loading[name] = loading
            return loading
        }
    }
}

/// One image at a time: decoding can take several times the memory of the
/// result for a moment, and zooming asks for several sizes at once.
private actor Decoder {
    func upright(_ data: Data, longestSide: Int) -> CGImage? {
        ImageDecoding.upright(data, longestSide: longestSide)
    }
}
