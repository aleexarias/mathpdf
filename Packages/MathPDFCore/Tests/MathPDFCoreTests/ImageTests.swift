import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MathPDFCore

/// Images as annotations: how they're recorded, stored and brought in.
struct ImageReferenceTests {
    let image = ImageReference(
        hash: String(repeating: "a", count: 64),
        pixelSize: CGSize(width: 400, height: 200))
    let landscape = CGRect(x: 10, y: 10, width: 100, height: 50)

    @Test func storeFilesSayWhichSchemaHasImages() throws {
        let set = makeSet(revision: 1, annotations: [Samples.image()])
        let decoded = try StoreFile.decode(StoreFile.encode(set))
        #expect(decoded.schemaVersion == 6)
        #expect(decoded.set.annotations == set.annotations)
    }

    @Test func aVersion5FileStillReads() throws {
        let set = makeSet(revision: 1, annotations: Samples.everyKind())
        let v5 = try #require(
            String(data: StoreFile.encode(set), encoding: .utf8)?
                .replacingOccurrences(
                    of: "\"schemaVersion\":6", with: "\"schemaVersion\":5"))
        let decoded = try StoreFile.decode(Data(v5.utf8))
        #expect(decoded.schemaVersion == 5)
        #expect(decoded.set == set)
    }

    @Test(arguments: [
        #""hash":"../../../../etc/passwd""#,
        #""hash":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA""#,
        #""pixelSize":[0,10]"#,
        #""pixelSize":[10]"#,
        #""crop":[0.5,0,0.75,1]"#,
        #""crop":[0,0,0,1]"#,
    ])
    func damagedImageRecordsAreRefused(damage: String) throws {
        let valid = try String(
            decoding: StoreFile.makeEncoder().encode(Samples.image()),
            as: UTF8.self)
        let key = String(damage.prefix { $0 != ":" })
        let field = try #require(
            valid.range(
                of: key + #" : (\[[^\]]*\]|"[^"]*")"#,
                options: .regularExpression))
        let damaged = valid.replacingCharacters(in: field, with: damage)
        #expect(throws: DecodingError.self) {
            try StoreFile.makeDecoder().decode(
                Annotation.self, from: Data(damaged.utf8))
        }
    }

    @Test func imagesMoveButKeepTheirColours() {
        let annotation = Samples.image()
        #expect(annotation.isMovable)
        #expect(!annotation.isRecolorable)
    }

    @Test func anAddedImageIsUndistorted() throws {
        let added = try #require(
            [Annotation]().addingImage(
                image, pageIndex: 2, bounds: landscape))
        #expect(added.edit.actionName == "Add Image")
        #expect(added.edit.undo == .toPrevious)
        #expect(added.edit.annotations.map(\.id) == [added.id])
        #expect(
            [Annotation]().addingImage(
                image, pageIndex: 2,
                bounds: CGRect(x: 10, y: 10, width: 100, height: 100)) == nil)
        var invalid = image
        invalid.hash = "../secret"
        #expect(
            [Annotation]().addingImage(
                invalid, pageIndex: 2, bounds: landscape) == nil)
    }

    @Test(arguments: [90, 270])
    func onASidewaysPageItsShapeIsAsShown(rotation: Int) {
        let page = PageFrame(
            box: CGRect(x: 0, y: 0, width: 612, height: 792),
            rotation: rotation)
        let turned = CGRect(x: 10, y: 10, width: 50, height: 100)
        #expect(
            [Annotation]().addingImage(
                image, pageIndex: 0, bounds: turned, within: page) != nil)
        #expect(
            [Annotation]().addingImage(
                image, pageIndex: 0, bounds: landscape, within: page) == nil)
    }

    @Test func resizingKeepsTheShape() throws {
        let added = try #require(
            [Annotation]().addingImage(
                image, pageIndex: 0, bounds: landscape))
        let bigger = CGRect(x: 10, y: 10, width: 200, height: 100)
        let edit = try #require(
            added.edit.annotations.resizingImage(added.id, to: bigger))
        #expect(edit.actionName == "Resize Image")
        #expect(edit.annotations[0].bounds == bigger)
        #expect(
            added.edit.annotations.resizingImage(
                added.id, to: CGRect(x: 10, y: 10, width: 200, height: 150))
                == nil)
        #expect(
            added.edit.annotations.resizingImage(added.id, to: landscape)
                == nil)
    }

    @Test func croppingShowsPartOfTheImageAtItsScale() throws {
        let added = try #require(
            [Annotation]().addingImage(
                image, pageIndex: 0, bounds: landscape))
        let leftHalf = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let edit = try #require(
            added.edit.annotations.croppingImage(
                added.id, to: leftHalf,
                bounds: CGRect(x: 10, y: 10, width: 50, height: 50)))
        #expect(edit.actionName == "Crop Image")
        guard case .image(let cropped) = edit.annotations[0].kind else {
            Issue.record("Not an image any more")
            return
        }
        #expect(cropped.crop == leftHalf)
        #expect(cropped.hash == image.hash)
        // beyond the image's right edge
        #expect(
            added.edit.annotations.croppingImage(
                added.id, to: CGRect(x: 0.6, y: 0, width: 0.5, height: 1),
                bounds: CGRect(x: 10, y: 10, width: 50, height: 50)) == nil)
        // not the crop's shape
        #expect(
            added.edit.annotations.croppingImage(
                added.id, to: leftHalf, bounds: landscape) == nil)
    }
}

@Suite final class ImageStoreTests: Sendable {
    let root = makeTemporaryRoot()

    deinit { try? FileManager.default.removeItem(at: root) }

    func files(in store: ImageStore) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: store.folderURL.path))?.sorted() ?? []
    }

    @Test func anImageIsStoredOnceUnderItsHash() async throws {
        let store = ImageStore(rootURL: root)
        let image = try ImageImport.prepare(SampleImages.png())
        try await store.store(image)
        try await store.store(image)
        #expect(files(in: store) == ["\(image.hash).png"])
        #expect(await store.data(for: image.hash) == image.data)
    }

    @Test func onlyIntactImagesAreStored() async throws {
        let store = ImageStore(rootURL: root)
        let image = try ImageImport.prepare(SampleImages.png())
        let page = Data("<html>not an image</html>".utf8)
        for (data, hash) in [
            (image.data, String(repeating: "0", count: 64)),
            (page, sha256Hex(page)), (image.data, "../\(image.hash)"),
        ] {
            await #expect(throws: ImageStoreError.invalidImage) {
                try await store.store(data, hash: hash)
            }
        }
        #expect(files(in: store).isEmpty)
    }

    @Test func copiedImagesAreStoredByTheirType() async throws {
        let store = ImageStore(rootURL: root)
        let photo = try ImageImport.prepare(SampleImages.encoded(as: .jpeg))
        try await store.store(photo.data, hash: photo.hash)
        #expect(files(in: store) == ["\(photo.hash).jpg"])
    }

    @Test func namesThatArentHashesAreNeverLookedUp() async throws {
        let outside = root.appending(path: "secret.png")
        try Data("secret".utf8).write(to: outside)
        let store = ImageStore(rootURL: root.appending(path: "data"))
        #expect(await store.data(for: "../secret") == nil)
        #expect(await store.data(for: "../../secret") == nil)
    }

    @Test func aDamagedImageIsSetAsideNotDeleted() async throws {
        let clock = FakeClock()
        let store = ImageStore(rootURL: root, now: clock.now)
        let image = try ImageImport.prepare(SampleImages.png())
        try await store.store(image)
        let url = store.folderURL.appending(path: "\(image.hash).png")
        var damaged = image.data
        damaged[damaged.count / 2] ^= 0xFF
        try damaged.write(to: url)

        #expect(await store.data(for: image.hash) == nil)
        let kept = files(in: store)
        #expect(kept.count == 1)
        #expect(kept[0].hasPrefix("\(image.hash).corrupt-"))
        #expect(
            try Data(contentsOf: store.folderURL.appending(path: kept[0]))
                == damaged)

        try await store.store(image)
        #expect(await store.data(for: image.hash) == image.data)
    }

    @Test func aCrashWhileWritingLeavesNoImage() async throws {
        let store = ImageStore(rootURL: root)
        let image = try ImageImport.prepare(SampleImages.png())
        await store.setBeforeReplace { throw SimulatedCrash() }
        await #expect(throws: ImageStoreError.self) {
            try await store.store(image)
        }
        #expect(await store.data(for: image.hash) == nil)
        #expect(
            files(in: store).allSatisfy { $0.contains(AtomicFile.tempMarker) })

        await store.setBeforeReplace(nil)
        try await store.store(image)
        #expect(await store.data(for: image.hash) == image.data)
    }
}

struct ImageImportTests {
    @Test func screenshotsBecomePNG() throws {
        for data in [
            SampleImages.png(), SampleImages.encoded(as: .tiff),
            SampleImages.encoded(as: .bmp),
        ] {
            let image = try ImageImport.prepare(data)
            #expect(image.pixelSize == CGSize(width: 40, height: 30))
            #expect(image.hash == sha256Hex(image.data))
            #expect(SampleImages.type(of: image.data) == .png)
        }
    }

    @Test func photosKeepTheirEncodingButNotTheirMetadata() throws {
        let photo = SampleImages.encoded(
            as: .jpeg,
            properties: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 40.4168,
                    kCGImagePropertyGPSLatitudeRef: "N",
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Camera Maker"
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "a private note"
                ],
            ])
        #expect(
            SampleImages.properties(of: photo)[kCGImagePropertyGPSDictionary]
                != nil)

        let image = try ImageImport.prepare(photo)
        #expect(SampleImages.type(of: image.data) == .jpeg)
        // turned a quarter by its orientation
        #expect(image.pixelSize == CGSize(width: 30, height: 40))
        let kept = SampleImages.properties(of: image.data)
        #expect(kept[kCGImagePropertyOrientation] as? Int == 6)
        #expect(kept[kCGImagePropertyGPSDictionary] == nil)
        let tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        let exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
    }

    @Test func turnedScreenshotsAreStoredUpright() throws {
        let image = try ImageImport.prepare(
            SampleImages.encoded(
                as: .tiff, properties: [kCGImagePropertyOrientation: 8]))
        #expect(SampleImages.type(of: image.data) == .png)
        #expect(image.pixelSize == CGSize(width: 30, height: 40))
        let stored = SampleImages.properties(of: image.data)
        #expect(stored[kCGImagePropertyPixelWidth] as? Int == 30)
        #expect((stored[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func onlyTheFirstFrameOfAnAnimationIsKept() throws {
        let image = try ImageImport.prepare(
            SampleImages.encoded(as: .gif, frames: 3))
        #expect(SampleImages.type(of: image.data) == .png)
        #expect(SampleImages.frameCount(of: image.data) == 1)
    }

    @Test func cmykBecomesRGB() throws {
        let image = try ImageImport.prepare(SampleImages.cmykTIFF())
        #expect(SampleImages.type(of: image.data) == .png)
        #expect(SampleImages.colorModel(of: image.data) == .rgb)
    }

    @Test func pdfsAndOtherFilesArentImages() {
        for data in [
            SampleImages.pdf(), Data("not an image".utf8), Data(),
        ] {
            #expect(throws: ImageImportProblem.notAnImage) {
                try ImageImport.prepare(data)
            }
        }
    }

    @Test func aSmallFileOfTooManyPixelsIsRefused() throws {
        let side = 7_072  // just over the limit, squared
        let bomb = SampleImages.blankPNG(width: side, height: side)
        #expect(bomb.count < 10_000)
        #expect(throws: ImageImportProblem.tooManyPixels) {
            try ImageImport.prepare(bomb)
        }
        let fine = try ImageImport.prepare(
            SampleImages.blankPNG(width: 7_000, height: 7_000))
        #expect(fine.pixelSize == CGSize(width: 7_000, height: 7_000))
    }

    @Test func overlyLargeFilesAreRefused() {
        #expect(throws: ImageImportProblem.fileTooLarge) {
            try ImageImport.prepare(
                Data(count: ImageImport.largestFile + 1))
        }
    }
}

/// Small images made on the spot, in each format.
enum SampleImages {
    static func cgImage(shade: CGFloat, width: Int = 40, height: Int = 30)
        -> CGImage
    {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: shade, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return context.makeImage()!
    }

    static func png() -> Data { encoded(as: .png) }

    /// A different PNG for each shade.
    static func png(shade: CGFloat) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage(shade: shade), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func encoded(
        as type: UTType, properties: [CFString: Any] = [:], frames: Int = 1
    ) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, frames, nil)!
        for frame in 0..<frames {
            CGImageDestinationAddImage(
                destination, cgImage(shade: CGFloat(frame) / 4),
                properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func cmykTIFF() -> Data {
        let context = CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceCMYK(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(
            CGColor(
                genericCMYKCyan: 1, magenta: 0, yellow: 0, black: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = CGContext(
            consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A valid all-black PNG, one bit a pixel, so even a huge one is a small
    /// file.
    static func blankPNG(width: Int, height: Int) -> Data {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return bigEndian(UInt32(body.count)) + typed
                + bigEndian(crc32(typed))
        }
        let header =
            bigEndian(UInt32(width)) + bigEndian(UInt32(height))
            + [1, 0, 0, 0, 0]
        // each row: a filter byte, then the pixels
        let rows = height * (1 + (width + 7) / 8)
        let deflated = try! (Data(count: rows) as NSData).compressed(
            using: .zlib)
        let adler32 = UInt32(rows % 65_521) << 16 | 1
        let zlib = [0x78, 0x01] + Array(deflated as Data) + bigEndian(adler32)
        return Data(
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
                + chunk("IHDR", header) + chunk("IDAT", zlib)
                + chunk("IEND", []))
    }

    static func properties(of data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] ?? [:]
    }

    static func type(of data: Data) -> UTType? {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
    }

    static func frameCount(of data: Data) -> Int {
        CGImageSourceGetCount(
            CGImageSourceCreateWithData(data as CFData, nil)!)
    }

    static func colorModel(of data: Data) -> CGColorSpaceModel? {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)?.colorSpace?
            .model
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

struct ImageGeometryTests {
    let page = PageFrame(box: CGRect(x: 0, y: 0, width: 612, height: 792))
    /// 200 × 100, its bottom left at (100, 300).
    let bounds = CGRect(x: 100, y: 300, width: 200, height: 100)

    @Test func draggingACornerKeepsTheOppositeOneAndTheShape() {
        let resized = ImageGeometry.resized(
            bounds, dragging: .topRight, by: CGSize(width: 100, height: 50),
            on: page)
        #expect(resized == CGRect(x: 100, y: 300, width: 300, height: 150))
    }

    @Test func draggingSidewaysResizesToo() {
        let resized = ImageGeometry.resized(
            bounds, dragging: .bottomRight, by: CGSize(width: -100, height: 0),
            on: page)
        #expect(resized.maxX < bounds.maxX)
        #expect(resized.origin.x == 100)
        #expect(resized.maxY == bounds.maxY)
        #expect(abs(resized.width / resized.height - 2) < 1e-9)
    }

    @Test func itStaysOnThePageAndNoSmallerThanTheSmallest() {
        let huge = ImageGeometry.resized(
            bounds, dragging: .topRight, by: CGSize(width: 5000, height: 5000),
            on: page)
        #expect(huge.maxX <= 612 + 1e-9)
        #expect(huge.origin == bounds.origin)
        let tiny = ImageGeometry.resized(
            bounds, dragging: .topRight,
            by: CGSize(width: -5000, height: -5000), on: page)
        #expect(tiny.height == ImageGeometry.smallestSide)
        #expect(tiny.origin == bounds.origin)
    }

    @Test(arguments: [0, 90, 180, 270])
    func onARotatedPageItsResizedAsSeen(rotation: Int) throws {
        let page = PageFrame(
            box: CGRect(x: 0, y: 0, width: 612, height: 792),
            rotation: rotation)
        let shownStart = CGRect(x: 100, y: 300, width: 200, height: 100)
        let start = page.onPage(shownStart)
        // a drag of (+60, +30) on screen
        let corner = page.onPage(
            CGPoint(x: shownStart.maxX, y: shownStart.maxY))
        let dragged = page.onPage(
            CGPoint(x: shownStart.maxX + 60, y: shownStart.maxY + 30))
        let resized = ImageGeometry.resized(
            start, dragging: .topRight,
            by: CGSize(
                width: dragged.x - corner.x, height: dragged.y - corner.y),
            on: page)
        let shown = page.shown(resized)
        #expect(abs(shown.minX - 100) < 1e-9 && abs(shown.minY - 300) < 1e-9)
        #expect(abs(shown.width - 260) < 1e-9)
        #expect(abs(shown.height - 130) < 1e-9)

        let image = ImageReference(
            hash: String(repeating: "c", count: 64),
            pixelSize: CGSize(width: 400, height: 200))
        let added = try #require(
            [Annotation]().addingImage(
                image, pageIndex: 0, bounds: start, within: page))
        #expect(
            added.edit.annotations.resizingImage(
                added.id, to: resized, within: page) != nil)
    }
}

struct ImageCropTests {
    let page = PageFrame(box: CGRect(x: 0, y: 0, width: 612, height: 792))
    /// A 400 × 200 image, uncropped, at half size.
    let bounds = CGRect(x: 100, y: 300, width: 200, height: 100)
    let uncropped = ImageReference.uncropped

    func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
            && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test func croppingASideHidesItAtTheSameScale() {
        let right = ImageGeometry.cropped(
            bounds, crop: uncropped, moving: .right,
            by: CGSize(width: -50, height: 0), on: page)
        #expect(
            isClose(
                right.bounds, CGRect(x: 100, y: 300, width: 150, height: 100)))
        #expect(
            isClose(right.crop, CGRect(x: 0, y: 0, width: 0.75, height: 1)))
        // the crop counts from the image's top
        let top = ImageGeometry.cropped(
            bounds, crop: uncropped, moving: .top,
            by: CGSize(width: 0, height: -20), on: page)
        #expect(
            isClose(
                top.bounds, CGRect(x: 100, y: 300, width: 200, height: 80)))
        #expect(
            isClose(top.crop, CGRect(x: 0, y: 0.2, width: 1, height: 0.8)))
    }

    @Test func revealingStopsAtTheImagesEdge() {
        let revealed = ImageGeometry.cropped(
            CGRect(x: 100, y: 300, width: 150, height: 100),
            crop: CGRect(x: 0, y: 0, width: 0.75, height: 1), moving: .right,
            by: CGSize(width: 500, height: 0), on: page)
        #expect(isClose(revealed.bounds, bounds))
        #expect(isClose(revealed.crop, uncropped))
    }

    @Test func revealingStopsAtThePagesEdge() {
        // the whole image would reach x = 700
        let atEdge = CGRect(x: 500, y: 300, width: 100, height: 100)
        let revealed = ImageGeometry.cropped(
            atEdge, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1),
            moving: .right, by: CGSize(width: 300, height: 0), on: page)
        #expect(revealed.bounds.maxX == 612)
        #expect(abs(revealed.crop.width - 0.56) < 1e-9)
    }

    @Test func theKeptPartIsNoSmallerThanTheSmallest() {
        let tiny = ImageGeometry.cropped(
            bounds, crop: uncropped, moving: [.top, .right],
            by: CGSize(width: -1000, height: -1000), on: page)
        #expect(tiny.bounds.origin == bounds.origin)
        #expect(
            tiny.bounds.size
                == CGSize(
                    width: ImageGeometry.smallestSide,
                    height: ImageGeometry.smallestSide))
    }

    @Test(arguments: [0, 90, 180, 270])
    func onARotatedPageItsCroppedAsSeen(rotation: Int) throws {
        let page = PageFrame(
            box: CGRect(x: 0, y: 0, width: 612, height: 792),
            rotation: rotation)
        let start = page.onPage(bounds)
        // the left side dragged 50 to the right on screen
        let side = page.onPage(CGPoint(x: bounds.minX, y: bounds.midY))
        let dragged = page.onPage(CGPoint(x: bounds.minX + 50, y: bounds.midY))
        let cropped = ImageGeometry.cropped(
            start, crop: uncropped, moving: .left,
            by: CGSize(width: dragged.x - side.x, height: dragged.y - side.y),
            on: page)
        #expect(
            isClose(
                page.shown(cropped.bounds),
                CGRect(x: 150, y: 300, width: 150, height: 100)))
        #expect(
            isClose(
                cropped.crop, CGRect(x: 0.25, y: 0, width: 0.75, height: 1)))

        let image = ImageReference(
            hash: String(repeating: "d", count: 64),
            pixelSize: CGSize(width: 400, height: 200))
        let added = try #require(
            [Annotation]().addingImage(
                image, pageIndex: 0, bounds: start, within: page))
        #expect(
            added.edit.annotations.croppingImage(
                added.id, to: cropped.crop, bounds: cropped.bounds,
                within: page) != nil)
    }

    @Test func resettingTheCropShowsTheWholeImageAtTheSameScale() {
        let cropped = ImageGeometry.cropped(
            bounds, crop: uncropped, moving: [.left, .bottom],
            by: CGSize(width: 40, height: 20), on: page)
        #expect(
            isClose(
                ImageGeometry.whole(
                    cropped.bounds, crop: cropped.crop, on: page), bounds))
        let reset = ImageGeometry.uncropped(
            cropped.bounds, crop: cropped.crop, on: page)
        #expect(reset.size == bounds.size)
        #expect(abs(reset.midX - cropped.bounds.midX) < 1e-9)
        #expect(abs(reset.midY - cropped.bounds.midY) < 1e-9)
    }
}

@Suite final class ImageCleanupTests: Sendable {
    let root = makeTemporaryRoot()

    deinit { try? FileManager.default.removeItem(at: root) }

    func stored(_ shade: CGFloat, daysOld: Double, in images: ImageStore)
        async throws -> String
    {
        let image = try ImageImport.prepare(SampleImages.png(shade: shade))
        try await images.store(image)
        try age(images.folderURL.appending(path: "\(image.hash).png"), daysOld)
        return image.hash
    }

    func age(_ url: URL, _ days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date() - days * 24 * 60 * 60],
            ofItemAtPath: url.path)
    }

    func showing(_ hash: String) -> Annotation {
        Annotation(
            kind: .image(
                ImageReference(
                    hash: hash, pixelSize: CGSize(width: 40, height: 30))),
            pageIndex: 0, bounds: CGRect(x: 10, y: 10, width: 40, height: 30),
            color: RGBAColor(red: 0, green: 0, blue: 0))
    }

    func files(in images: ImageStore) -> Set<String> {
        Set(
            (try? FileManager.default.contentsOfDirectory(
                atPath: images.folderURL.path)) ?? [])
    }

    @Test func unusedImagesGoOnceTheGracePeriodIsOver() async throws {
        let store = AnnotationStore(rootURL: root)
        let images = ImageStore(rootURL: root)
        let used = try await stored(0.1, daysOld: 30, in: images)
        _ = try await stored(0.2, daysOld: 8, in: images)
        let recent = try await stored(0.3, daysOld: 6, in: images)
        try await store.save(
            makeSet(revision: 1, annotations: [showing(used)]))

        let referenced = try await store.referencedImages()
        #expect(referenced == [used])
        #expect(await images.removeUnused(keeping: referenced) == 1)
        #expect(files(in: images) == ["\(used).png", "\(recent).png"])
    }

    @Test func imagesInSnapshotsAndUnreadableStoresStillCount() async throws {
        let store = AnnotationStore(rootURL: root)
        let images = ImageStore(rootURL: root)
        let inSnapshot = try await stored(0.4, daysOld: 30, in: images)
        let inDamaged = try await stored(0.5, daysOld: 30, in: images)
        let inNewer = try await stored(0.6, daysOld: 30, in: images)
        try await store.save(
            makeSet(revision: 1, annotations: [showing(inSnapshot)]))
        try await store.save(makeSet(revision: 2))
        let folder = store.folderURL(testHash)
        try Data(#"{"broken": {"hash" : "\#(inDamaged)""#.utf8).write(
            to: folder.appending(path: "store.corrupt-20261101T000000Z.json"))
        let other = root.appending(path: "documents/other")
        try FileManager.default.createDirectory(
            at: other, withIntermediateDirectories: true)
        try Data(
            #"{"schemaVersion":99,"payload":{"hash":"\#(inNewer)"}}"#.utf8
        ).write(to: other.appending(path: "store.json"))

        let referenced = try await store.referencedImages()
        #expect(referenced == [inSnapshot, inDamaged, inNewer])
        #expect(await images.removeUnused(keeping: referenced) == 0)
    }

    @Test func anUnreadableFileStopsTheCleanup() async throws {
        let store = AnnotationStore(rootURL: root)
        try await store.save(makeSet(revision: 1))
        let file = store.storeURL(testHash)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        await #expect(throws: (any Error).self) {
            try await store.referencedImages()
        }
    }

    @Test func storingAnImageAgainRestartsItsGracePeriod() async throws {
        let images = ImageStore(rootURL: root)
        let hash = try await stored(0.7, daysOld: 30, in: images)
        try await images.store(
            ImageImport.prepare(SampleImages.png(shade: 0.7)))
        #expect(await images.removeUnused(keeping: []) == 0)
        #expect(files(in: images) == ["\(hash).png"])
    }

    @Test func oldLeftoversGoButDamagedImagesStay() async throws {
        let images = ImageStore(rootURL: root)
        _ = try await stored(0.8, daysOld: 1, in: images)
        let leftover = images.folderURL.appending(
            path: ".x.png\(AtomicFile.tempMarker)\(UUID().uuidString)")
        let damaged = images.folderURL.appending(
            path: "\(String(repeating: "a", count: 64)).corrupt-1.png")
        for url in [leftover, damaged] {
            try Data([1, 2, 3]).write(to: url)
            try age(url, 30)
        }
        #expect(await images.removeUnused(keeping: []) == 1)
        #expect(files(in: images).contains(damaged.lastPathComponent))
        #expect(!files(in: images).contains(leftover.lastPathComponent))
    }
}
