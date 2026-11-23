import AppKit
import MathPDFRendering
import PDFKit

/// The image being moved, resized or cropped, shown above the pages. Drawn
/// with its page, it would be drawn again tile by tile at every step, which
/// on a busy page shows it in pieces. Put back, it stays until the page has
/// drawn all that's visible of it where it now is, so it never blinks out.
/// Where it was is covered meanwhile with a picture of the page without it,
/// as PDFKit starts drawing the page again only a tenth of a second after
/// it's asked to. Clicks go through it to the pages.
///
/// PDFKit misses a redraw asked for while it's still drawing the same part
/// of the page, which a busy page makes likely. So if the page hasn't drawn
/// it after `longest`, where it was and where it is are drawn once more, and
/// where it was is drawn again once it's done, in case lifting it was
/// missed.
final class LiftedImage: NSView {
    /// How long it waits for the page to draw it once put back.
    private static let longest: TimeInterval = 1.5
    /// It's shown from an image no bigger than this on its longer side, as
    /// Core Animation keeps a copy of it: zoomed in, it's a little soft until
    /// it's put back, rather than tens of megabytes more.
    private static let mostPixels: CGFloat = 2048

    weak var pdfView: PDFView?
    private(set) var mark: ImageAnnotation?
    /// Where it was on its page when it was lifted, and where it is put
    /// back, on `page`.
    private var start = CGRect.null
    private var end = CGRect.null
    private weak var page: ImagePage?
    private var isPutBack = false
    private var isRedrawn = false
    /// The parts of the page drawn with it where it now is, since it was put
    /// back.
    private var covered: [CGRect] = []
    private var timer: Timer?
    /// Over where it was.
    private let coverLayer = CALayer()
    private let imageLayer = CALayer()
    /// Over what's cropped off, while cropping.
    private let dimLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // hosting its own layers, which AppKit leaves alone
        layer = CALayer()
        wantsLayer = true
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        for sublayer in [coverLayer, imageLayer, dimLayer] {
            layer?.addSublayer(sublayer)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageDrewImages(_:)),
            name: ImagePage.didDrawImages, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(imageLoaded),
            name: ImageCache.didLoad, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `start` is where it was on its page before the gesture.
    func lift(_ mark: ImageAnnotation, from start: CGRect) {
        guard mark !== self.mark || isPutBack else { return }
        // the page may not have drawn the one put back yet
        if isPutBack { page?.redrawImages(in: start.union(end)) }
        clear()
        self.mark = mark
        self.start = start
        update()
    }

    /// Covers where it was with the page as it'll be drawn without it.
    private func coverStart() {
        guard let page = mark?.page as? ImagePage, let pdfView else { return }
        let start = start
        page.picture(
            of: start, in: pdfView.displayBox,
            scale: pdfView.scaleFactor * backingScale
        ) { [weak self] picture in
            guard let self, self.start == start else { return }
            withoutAnimation { self.coverLayer.contents = picture }
        }
    }

    /// Puts the lifted image back on its page, and shows `mark`, now drawn
    /// for it there, until the page has drawn it. Should `mark` be replaced
    /// meanwhile, it stays where it was on the page.
    func putBack(showing mark: ImageAnnotation?) {
        guard let lifted = self.mark, !isPutBack else { return }
        lifted.isLifted = false
        guard let mark, let page = mark.page as? ImagePage else {
            return clear()
        }
        self.mark = mark
        self.page = page
        end = mark.bounds
        isPutBack = true
        covered = []
        restartTimer(Self.longest)
        update()
    }

    func clear() {
        timer?.invalidate()
        timer = nil
        if !isPutBack { mark?.isLifted = false }
        mark = nil
        start = .null
        end = .null
        page = nil
        isPutBack = false
        isRedrawn = false
        covered = []
        withoutAnimation {
            coverLayer.contents = nil
            show(nil, part: .zero, kept: nil, cover: .zero)
        }
    }

    /// Where the image is now: it moves with the page and while it's dragged.
    /// One not loaded yet stays drawn with its page.
    func update() {
        guard let mark, let pdfView else { return clear() }
        let page: PDFPage
        if isPutBack {
            guard let shownOn = self.page else { return clear() }
            page = shownOn
            if mark.page != nil { end = mark.bounds }
        } else {
            guard let liftedFrom = mark.page else {
                // replaced as a gesture's change is saved, just before it's
                // put back; gone if it's still lifted after that
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isPutBack, self.mark?.page == nil
                    else { return }
                    self.clear()
                }
                return
            }
            page = liftedFrom
        }
        func shown(_ rect: CGRect) -> CGRect {
            convert(pdfView.convert(rect, from: page), from: pdfView)
        }
        let frame = shown(isPutBack ? end : mark.bounds)
        let contents = mark.contents(
            showing: frame.size, scale: backingScale, largest: Self.mostPixels)
        if !isPutBack, mark.isLifted != (contents != nil) {
            mark.isLifted = contents != nil
            if mark.isLifted { coverStart() }
        }
        show(
            contents.map { ($0.image, frame) }, part: contents?.part ?? .zero,
            kept: mark.editingCrop, cover: shown(start))
    }

    /// `part` and `kept` are fractions from the top left. The cover goes
    /// with the image: without one, the page still draws it.
    private func show(
        _ image: (CGImage, frame: CGRect)?, part: CGRect, kept: CGRect?,
        cover: CGRect
    ) {
        withoutAnimation {
            coverLayer.isHidden = image == nil
            coverLayer.frame = cover
            imageLayer.isHidden = image == nil
            dimLayer.isHidden = image == nil || kept == nil
            guard let (contents, frame) = image else {
                imageLayer.contents = nil
                return
            }
            imageLayer.contents = contents
            imageLayer.frame = frame
            imageLayer.contentsRect = CGRect(
                x: part.minX, y: 1 - part.maxY, width: part.width,
                height: part.height)
            guard let kept else { return }
            let path = CGMutablePath()
            path.addRect(frame)
            path.addRect(
                CGRect(
                    x: frame.minX + kept.minX * frame.width,
                    y: frame.maxY - kept.maxY * frame.height,
                    width: kept.width * frame.width,
                    height: kept.height * frame.height))
            dimLayer.path = path
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    @objc private func pageDrewImages(_ notification: Notification) {
        guard isPutBack, let page, let info = notification.userInfo,
            info["page"] as? ObjectIdentifier == ObjectIdentifier(page),
            let rect = info["rect"] as? CGRect,
            let images = info["images"] as? [CGRect],
            let scale = info["scale"] as? CGFloat,
            images.contains(where: { Self.isSame($0, end) }),
            let pdfView,
            scale >= pdfView.scaleFactor * backingScale * 0.9
        else { return }
        covered.append(rect)
        if isDrawn { finish() }
    }

    /// Whether all that's visible of it has been drawn where it now is,
    /// checked at points spread over it.
    private var isDrawn: Bool {
        guard let page, let pdfView else { return true }
        let visible = pdfView.convert(pdfView.bounds, to: page)
            .intersection(end)
        guard !visible.isEmpty else { return true }
        let fractions: [CGFloat] = (0..<10).map { (CGFloat($0) + 0.5) / 10 }
        return fractions.allSatisfy { across in
            fractions.allSatisfy { up in
                let point = CGPoint(
                    x: visible.minX + visible.width * across,
                    y: visible.minY + visible.height * up)
                return covered.contains { $0.contains(point) }
            }
        }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private static func isSame(_ a: CGRect, _ b: CGRect) -> Bool {
        let differences = [
            a.minX - b.minX, a.minY - b.minY, a.width - b.width,
            a.height - b.height,
        ]
        return differences.allSatisfy { abs($0) < 0.01 }
    }

    private func finish() {
        let (page, start) = (page, start)
        clear()
        if !start.isNull { page?.redrawImages(in: start) }
    }

    @objc private func imageLoaded() {
        if mark != nil { update() }
    }

    private func timedOut() {
        guard !isRedrawn, let page else { return clear() }
        isRedrawn = true
        covered = []
        page.redrawImages(in: start.union(end))
        restartTimer(Self.longest)
    }

    private func restartTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: false
        ) {
            [weak self] _ in MainActor.assumeIsolated { self?.timedOut() }
        }
    }
}
