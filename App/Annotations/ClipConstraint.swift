import AppKit

/// PDFKit's clip view bounds scrolling and centres narrow pages in its
/// `constrainBoundsRect`, which AppKit consults at every layout. It takes no
/// account of a left inset: pages keep being pushed sideways by the inset's
/// width. Vertically, it shifts the range by the bottom inset, so the top of
/// the pages can't be scrolled clear of the toolbar. This gives a clip view
/// a subclass, made at run time as PDFKit's class is private, that uses
/// AppKit's own answer, which allows for insets, centring pages that fit in
/// what the inset leaves. PDFKit's vertical answer is kept where the pages
/// fit, as it centres them.
@MainActor
enum ClipConstraint {
    private typealias Constrain =
        @convention(c) (NSClipView, Selector, NSRect) -> NSRect
    private static let selector = #selector(
        NSClipView.constrainBoundsRect(_:))

    /// Does nothing if the clip view isn't PDFKit's own subclass.
    static func install(on clip: NSClipView) {
        let pdfKitClass: AnyClass = type(of: clip)
        let name = "MathPDF" + NSStringFromClass(pdfKitClass)
        if let installed = NSClassFromString(name) {
            object_setClass(clip, installed)
            return
        }
        guard pdfKitClass != NSClipView.self,
            !NSStringFromClass(pdfKitClass).hasPrefix("MathPDF"),
            let method = class_getInstanceMethod(pdfKitClass, selector),
            let standardIMP = class_getMethodImplementation(
                NSClipView.self, selector),
            let subclass = objc_allocateClassPair(pdfKitClass, name, 0)
        else { return }
        let pdfKit = unsafeBitCast(
            method_getImplementation(method), to: Constrain.self)
        let standard = unsafeBitCast(standardIMP, to: Constrain.self)
        let constrain: @convention(block) (NSClipView, NSRect) -> NSRect = {
            clip, proposed in
            MainActor.assumeIsolated {
                var bounds = pdfKit(clip, selector, proposed)
                let appKit = standard(clip, selector, proposed)
                bounds.origin.x = horizontalOrigin(of: appKit, in: clip)
                if pagesAreTaller(than: appKit, in: clip) {
                    bounds.origin.y = appKit.origin.y
                }
                return bounds
            }
        }
        class_addMethod(
            subclass, selector, imp_implementationWithBlock(constrain),
            method_getTypeEncoding(method))
        objc_registerClassPair(subclass)
        object_setClass(clip, subclass)
    }

    private static func horizontalOrigin(
        of bounds: NSRect, in clip: NSClipView
    ) -> CGFloat {
        guard let pages = clip.documentView?.frame else {
            return bounds.origin.x
        }
        // In page units, like the bounds.
        let inset = clip.contentInsets.left
        guard pages.width <= bounds.width - inset + 0.5 else {
            return bounds.origin.x
        }
        return pages.midX - (bounds.width + inset) / 2
    }

    private static func pagesAreTaller(
        than bounds: NSRect, in clip: NSClipView
    ) -> Bool {
        guard let pages = clip.documentView?.frame else { return false }
        let insets = clip.contentInsets
        return pages.height > bounds.height - insets.top - insets.bottom + 0.5
    }
}
