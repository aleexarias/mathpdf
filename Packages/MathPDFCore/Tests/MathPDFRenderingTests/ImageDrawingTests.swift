import CoreGraphics
import Foundation
import ImageIO
import MathPDFCore
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import MathPDFRendering

/// Images drawn on pages: decoded at the size shown, cropped, upright.
@MainActor
@Suite final class ImageDrawingTests {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "mathpdf-image-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 200 × 100 pixels: the left half red, the right half blue.
    static func redAndBlue(orientation: Int = 1, as type: UTType = .png)
        -> Data
    {
        let context = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, context.makeImage()!,
            [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func stored(_ data: Data) async throws -> (ImageCache, ImageReference) {
        let store = ImageStore(rootURL: root)
        let image = try ImageImport.prepare(data)
        try await store.store(image)
        return (
            ImageCache(store: store),
            ImageReference(hash: image.hash, pixelSize: image.pixelSize)
        )
    }

    /// Waits for the size wanted to be decoded.
    func loaded(
        _ cache: ImageCache, _ image: ImageReference, longestSide: CGFloat
    ) async throws -> ImageCache.Lookup {
        for _ in 0..<300 {
            let lookup = cache.image(image, longestSide: longestSide)
            switch lookup {
            case .image(let decoded)
            where CGFloat(max(decoded.width, decoded.height))
                >= min(longestSide, image.pixelSize.width):
                return lookup
            case .missing: return lookup
            default: try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("Never loaded")
        return .loading
    }

    /// The colour at a point, as drawn in a bitmap of `size`.
    func drawn(
        _ annotation: ImageAnnotation, size: CGSize
    ) -> (CGPoint) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let width = Int(size.width), height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        annotation.drawContent(size: size, in: context)
        let pixels = Array(
            UnsafeBufferPointer(
                start: context.data!.assumingMemoryBound(to: UInt8.self),
                count: width * height * 4))
        return { point in
            // rows go from the top in memory
            let offset =
                ((height - 1 - Int(point.y)) * width + Int(point.x)) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }
    }

    @Test func anImageIsABoxUntilItsLoaded() async throws {
        let (cache, image) = try await stored(Self.redAndBlue())
        let annotation = ImageAnnotation(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 50), image: image,
            cache: cache)
        let size = CGSize(width: 100, height: 50)
        let placeholder = drawn(annotation, size: size)(CGPoint(x: 50, y: 25))
        #expect(placeholder.red == placeholder.blue && placeholder.red > 200)

        _ = try await loaded(cache, image, longestSide: 100)
        let colour = drawn(annotation, size: size)
        #expect(colour(CGPoint(x: 20, y: 25)) == (255, 0, 0))
        #expect(colour(CGPoint(x: 80, y: 25)) == (0, 0, 255))
    }

    @Test func aPreparedImageIsDrawnFromTheStart() async throws {
        let (cache, image) = try await stored(Self.redAndBlue())
        await cache.prepare(image, longestSide: 100)
        let decoded = cache.image(image, longestSide: 100)
        guard case .image(let decoded) = decoded else {
            Issue.record("Not decoded: \(decoded)")
            return
        }
        #expect(max(decoded.width, decoded.height) >= 100)

        let gone = ImageReference(
            hash: String(repeating: "0", count: 64),
            pixelSize: image.pixelSize)
        await cache.prepare(gone, longestSide: 100)
        let missing = cache.image(gone, longestSide: 100)
        guard case .missing = missing else {
            Issue.record("Not missing: \(missing)")
            return
        }
    }

    @Test func onlyTheCropIsDrawn() async throws {
        var (cache, image) = try await stored(Self.redAndBlue())
        image.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        _ = try await loaded(cache, image, longestSide: 200)
        let colour = drawn(
            ImageAnnotation(
                bounds: CGRect(x: 0, y: 0, width: 50, height: 50),
                image: image, cache: cache),
            size: CGSize(width: 50, height: 50))
        for x in [2, 25, 47] {
            #expect(colour(CGPoint(x: x, y: 25)) == (0, 0, 255))
        }
    }

    @Test func aCroppedImageIsDecodedForItsWholeSize() async throws {
        var (cache, image) = try await stored(Self.redAndBlue())
        image.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let annotation = ImageAnnotation(
            bounds: CGRect(x: 0, y: 0, width: 50, height: 50), image: image,
            cache: cache)
        var width = 0
        for _ in 0..<300 where width < 100 {
            width =
                annotation.contents(
                    showing: CGSize(width: 50, height: 50), scale: 1,
                    largest: 4096)?.image.width ?? 0
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(width == 128)
    }

    @Test func aPhotoIsDrawnUpright() async throws {
        // a quarter turn clockwise when shown: the left half ends up on top
        let (cache, image) = try await stored(
            Self.redAndBlue(orientation: 6, as: .jpeg))
        #expect(image.pixelSize == CGSize(width: 100, height: 200))
        _ = try await loaded(cache, image, longestSide: 200)
        let colour = drawn(
            ImageAnnotation(
                bounds: CGRect(x: 0, y: 0, width: 50, height: 100),
                image: image, cache: cache),
            size: CGSize(width: 50, height: 100))
        let top = colour(CGPoint(x: 25, y: 85))
        let bottom = colour(CGPoint(x: 25, y: 15))
        #expect(top.red > 200 && top.blue < 60)
        #expect(bottom.blue > 200 && bottom.red < 60)
    }

    @Test func sizesAreDecodedInPowersOfTwo() async throws {
        let (cache, image) = try await stored(Self.redAndBlue())
        guard
            case .image(let small) = try await loaded(
                cache, image, longestSide: 70)
        else { return }
        #expect(small.width == 128)
        // never larger than the image itself
        guard
            case .image(let full) = try await loaded(
                cache, image, longestSide: 5000)
        else { return }
        #expect(full.width == 200)
    }

    @Test func largeImagesDecodeAtMostHalfTheirSize() {
        func largest(_ side: CGFloat) -> Int? {
            ImageCache.sizes(
                upTo: ImageReference(
                    hash: String(repeating: "a", count: 64),
                    pixelSize: CGSize(width: side, height: side / 2))
            ).last
        }
        #expect(largest(3000) == 3000)
        #expect(largest(4096) == 4096)
        #expect(largest(7000) == 3500)
        #expect(largest(10000) == 4096)
    }

    /// A page of a blank document with a red-and-blue image on it, 200 × 100
    /// points from (100, 500) unless said otherwise. The page only holds on
    /// to its document weakly.
    func pageWithImage(
        rotation: Int = 0,
        bounds: CGRect = CGRect(x: 100, y: 500, width: 200, height: 100)
    ) async throws -> (ImageDocument, ImagePage, ImageAnnotation) {
        let (cache, image) = try await stored(Self.redAndBlue())
        _ = try await loaded(cache, image, longestSide: 400)
        let document = try #require(ImageDocument(data: Self.blankPDF()))
        let page = try #require(document.page(at: 0) as? ImagePage)
        page.rotation = rotation
        let mark = ImageAnnotation(
            bounds: bounds, image: image, cache: cache,
            pageRotation: rotation)
        page.addAnnotation(mark)
        return (document, page, mark)
    }

    /// The colour of a thumbnail drawn a point to a pixel, at a point on the
    /// page.
    func thumbnailColour(of page: ImagePage, at point: CGPoint)
        -> (red: UInt8, green: UInt8, blue: UInt8)
    {
        let image = page.thumbnail(
            of: CGSize(width: 612, height: 792), for: .mediaBox
        ).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let context = CGContext(
            data: nil, width: 612, height: 792, bitsPerComponent: 8,
            bytesPerRow: 612 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 612, height: 792))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        // rows go from the top in memory
        let offset = ((791 - Int(point.y)) * 612 + Int(point.x)) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    @Test func aPageKeepsItsImagesFromPDFKit() async throws {
        let (document, page, mark) = try await pageWithImage()
        defer { withExtendedLifetime(document) {} }
        #expect(page.annotations.isEmpty)
        #expect(mark.page === page)
        page.removeAnnotation(mark)
        #expect(mark.page == nil)
    }

    @Test func aLiftedImageIsLeftOutOfThePageButNotItsThumbnail() async throws
    {
        let (document, page, mark) = try await pageWithImage()
        defer { withExtendedLifetime(document) {} }
        #expect(
            thumbnailColour(of: page, at: CGPoint(x: 150, y: 550)) == (
                255, 0, 0
            ))
        #expect(
            thumbnailColour(of: page, at: CGPoint(x: 250, y: 550)) == (
                0, 0, 255
            ))
        // shown above the page instead, but still in thumbnails
        mark.isLifted = true
        let context = CGContext(
            data: nil, width: 612, height: 792, bitsPerComponent: 8,
            bytesPerRow: 612 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        page.draw(with: .mediaBox, to: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = ((791 - 550) * 612 + 150) * 4
        #expect(
            (pixels[offset], pixels[offset + 1], pixels[offset + 2])
                == (255, 255, 255))
        #expect(
            thumbnailColour(of: page, at: CGPoint(x: 150, y: 550))
                == (255, 0, 0))
    }

    /// The colours at the left and right of the middle row of a picture.
    func picture(
        of page: ImagePage, _ rect: CGRect
    ) async throws -> (left: UInt8, right: UInt8, blue: UInt8) {
        let image = try #require(
            await withCheckedContinuation { continuation in
                page.picture(of: rect, in: .mediaBox, scale: 1) {
                    continuation.resume(returning: $0)
                }
            })
        let width = image.width, height = image.height
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(
            image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        func red(_ x: Int) -> UInt8 { pixels[((height / 2) * width + x) * 4] }
        let blue = pixels[((height / 2) * width + width - 5) * 4 + 2]
        return (red(5), red(width - 5), blue)
    }

    @Test func aPictureOfThePageLeavesOutALiftedImage() async throws {
        let (document, page, mark) = try await pageWithImage()
        defer { withExtendedLifetime(document) {} }
        let shown = try await picture(of: page, mark.bounds)
        #expect(shown.left == 255 && shown.right == 0 && shown.blue == 255)
        mark.isLifted = true
        let lifted = try await picture(of: page, mark.bounds)
        #expect(
            lifted.left == 255 && lifted.right == 255 && lifted.blue == 255)
    }

    @Test func aPictureOfATurnedPageIsAsShown() async throws {
        // 100 × 200 on the page, so 200 × 100 on screen
        let bounds = CGRect(x: 300, y: 200, width: 100, height: 200)
        let (document, page, _) = try await pageWithImage(
            rotation: 90, bounds: bounds)
        defer { withExtendedLifetime(document) {} }
        let shown = try await picture(of: page, bounds)
        #expect(shown.left == 255 && shown.right == 0 && shown.blue == 255)
    }

    @Test func changesAskForTheirPartOfThePageToBeDrawn() async throws {
        let (document, page, mark) = try await pageWithImage()
        defer { withExtendedLifetime(document) {} }
        var asked: [CGRect] = []
        let observer = NotificationCenter.default.addObserver(
            forName: ImagePage.imagesChanged, object: page, queue: nil
        ) { notification in
            asked.append(
                (notification.userInfo?["rect"] as? NSValue)?.rectValue
                    ?? .null)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let start = mark.bounds
        mark.bounds = start.offsetBy(dx: 50, dy: 0)
        mark.bounds = mark.bounds
        #expect(asked == [start.union(start.offsetBy(dx: 50, dy: 0))])

        asked = []
        mark.isLifted = true
        mark.bounds = start
        #expect(asked == [start.offsetBy(dx: 50, dy: 0)])
        mark.isLifted = false
        #expect(asked == [start.offsetBy(dx: 50, dy: 0), start])
    }

    @Test func aMissingImageSaysSo() async throws {
        let cache = ImageCache(store: ImageStore(rootURL: root))
        let image = ImageReference(
            hash: String(repeating: "e", count: 64),
            pixelSize: CGSize(width: 10, height: 10))
        guard case .missing = try await loaded(cache, image, longestSide: 10)
        else {
            Issue.record("Expected missing")
            return
        }
        cache.stored(image.hash)
        guard case .loading = cache.image(image, longestSide: 10) else {
            Issue.record("Expected it to be looked for again")
            return
        }
    }

    /// A blank one-page PDF, US Letter.
    static func blankPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(
            consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func exported(_ annotations: [Annotation], images: ImageStore) async throws
        -> (page: PDFPage, leftOut: Int)
    {
        let url = root.appending(path: "\(UUID().uuidString).pdf")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let leftOut = try await PDFExporter.export(
            original: Self.blankPDF(), annotations: annotations, to: url,
            originalURL: nil, images: images)
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        return (page, leftOut)
    }

    @Test func anExportedCopyShowsTheCroppedImage() async throws {
        let store = ImageStore(rootURL: root)
        let prepared = try ImageImport.prepare(Self.redAndBlue())
        try await store.store(prepared)
        let image = ImageReference(
            hash: prepared.hash, pixelSize: prepared.pixelSize,
            crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let (page, leftOut) = try await exported(
            [
                Annotation(
                    kind: .image(image), pageIndex: 0,
                    bounds: CGRect(x: 100, y: 100, width: 100, height: 100),
                    color: RGBAColor(red: 0, green: 0, blue: 0))
            ], images: store)
        #expect(leftOut == 0)
        #expect(page.annotations.map(\.type) == ["Stamp"])

        let context = CGContext(
            data: nil, width: 612, height: 792, bitsPerComponent: 8,
            bytesPerRow: 612 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        page.draw(with: .mediaBox, to: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        func colour(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = ((791 - y) * 612 + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }
        // only the right, blue half of the image
        for x in [105, 150, 195] {
            let (red, _, blue) = colour(x, 150)
            #expect(blue > 200 && red < 60)
        }
        #expect(colour(50, 50) == (255, 255, 255))
    }

    @Test func aMissingImageIsLeftOutAndCounted() async throws {
        let image = ImageReference(
            hash: String(repeating: "f", count: 64),
            pixelSize: CGSize(width: 10, height: 10))
        let (page, leftOut) = try await exported(
            [
                Annotation(
                    kind: .image(image), pageIndex: 0,
                    bounds: CGRect(x: 10, y: 10, width: 10, height: 10),
                    color: RGBAColor(red: 0, green: 0, blue: 0))
            ], images: ImageStore(rootURL: root))
        #expect(leftOut == 1)
        #expect(page.annotations.isEmpty)
    }
}
