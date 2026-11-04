import AppKit
import SwiftMath

/// Typesets LaTeX math with SwiftMath, for the page and for checking what's
/// typed in the editor.
@MainActor
public enum LaTeXRenderer {
    /// A laid-out formula. `display` is positioned inside a box of `size`,
    /// origin bottom-left, and draws itself as vector glyphs and lines into
    /// any graphics context.
    public struct Typeset {
        let display: MTMathListDisplay
        public let size: CGSize
    }

    public enum Result {
        case formula(Typeset)
        case empty
        /// The source can't be typeset; `message` says why.
        case invalid(message: String)
    }

    static let padding: CGFloat = 2

    /// Results by source, size and colour, so redrawing or moving a formula
    /// doesn't typeset it again. Typesetting is pure, and drawing doesn't
    /// change a display, so they can be shared.
    private static let cache: NSCache<NSString, CachedResult> = {
        let cache = NSCache<NSString, CachedResult>()
        cache.countLimit = 500
        return cache
    }()

    private final class CachedResult {
        let result: Result
        init(_ result: Result) { self.result = result }
    }

    public static func typeset(
        _ source: String, fontSize: CGFloat, color: NSColor
    ) -> Result {
        let key = "\(fontSize) \(colorKey(color)) \(source)" as NSString
        if let cached = cache.object(forKey: key) { return cached.result }
        let result = makeTypeset(source, fontSize: fontSize, color: color)
        cache.setObject(CachedResult(result), forKey: key)
        return result
    }

    private static func makeTypeset(
        _ source: String, fontSize: CGFloat, color: NSColor
    ) -> Result {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .empty }
        let prepared: String
        do {
            prepared = try LaTeXCompatibility.rewrite(source)
        } catch {
            return .invalid(message: error.message)
        }
        // SwiftMath's typesetter is only public through its label view, used
        // here off screen.
        let label = MTMathUILabel()
        label.labelMode = .display
        label.fontSize = fontSize
        label.textColor = color
        label.contentInsets = NSEdgeInsets(
            top: padding, left: padding, bottom: padding, right: padding)
        label.latex = prepared
        if let error = label.error {
            return .invalid(message: message(for: error))
        }
        let size = label.fittingSize
        guard size.width > 0, size.height > 0 else {
            return .invalid(message: "This formula has nothing to show.")
        }
        label.frame = CGRect(origin: .zero, size: size)
        label.layout()
        guard let display = label.displayList else {
            return .invalid(message: "This formula couldn't be laid out.")
        }
        return .formula(Typeset(display: display, size: size))
    }

    /// SwiftMath's own message, except that a command or environment it
    /// doesn't know is reported as not supported.
    static func message(for error: NSError) -> String {
        let text = error.localizedDescription
        switch error.code {
        case invalidCommandCode:
            return "Command not supported: \\"
                + text.replacingOccurrences(of: "Invalid command \\", with: "")
        case invalidEnvironmentCode:
            return "Environment not supported: "
                + text.replacingOccurrences(
                    of: "Unknown environment ", with: "")
        default:
            return text
        }
    }

    /// SwiftMath's error codes (its enum of them isn't public).
    private static let invalidCommandCode = 2
    private static let invalidEnvironmentCode = 8

    private static func colorKey(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return color.description
        }
        let components = [
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent,
            rgb.alphaComponent,
        ]
        return components.map { "\($0)" }.joined(separator: ",")
    }

    /// The size on the page: the formula's own, or a box big enough to show
    /// the source when it can't be typeset, so nothing typed is ever hidden.
    public static func size(of source: String, fontSize: CGFloat) -> CGSize {
        if case .formula(let typeset) = typeset(
            source, fontSize: fontSize, color: .black)
        {
            return typeset.size
        }
        let text = source.isEmpty ? "LaTeX" : source
        let width = (text as NSString).size(withAttributes: [
            .font: errorFont(fontSize: fontSize)
        ]).width
        return CGSize(
            width: min(max(width + 12, 60), 500), height: fontSize * 1.6)
    }

    /// Draws a formula with the bottom-left corner of its box at the context's
    /// origin.
    nonisolated static func draw(
        _ display: MTMathListDisplay, in context: CGContext
    ) {
        // SwiftMath strokes fraction bars, the bars of roots and over- and
        // underlines with NSBezierPath, which draws into AppKit's current
        // context, not the one it's given: without this they'd be missing.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        // CoreText would otherwise inherit the caller's text matrix
        context.textMatrix = .identity
        display.draw(context)
    }

    nonisolated static func errorFont(fontSize: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: max(8, fontSize * 0.7), weight: .regular)
    }
}
