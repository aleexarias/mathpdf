import AppKit
import MathPDFCore
import MathPDFRendering

enum Palette {
    struct Entry: Identifiable {
        let name: String
        let color: RGBAColor
        var id: String { name }
    }

    // Soft tones, so highlights don't overpower the text.
    static let yellow = RGBAColor(red: 1, green: 0.88, blue: 0.32)
    static let orange = RGBAColor(red: 1, green: 0.72, blue: 0.38)
    static let red = RGBAColor(red: 1, green: 0.48, blue: 0.45)
    static let pink = RGBAColor(red: 1, green: 0.62, blue: 0.82)
    static let purple = RGBAColor(red: 0.78, green: 0.64, blue: 1)
    static let blue = RGBAColor(red: 0.52, green: 0.76, blue: 1)
    static let green = RGBAColor(red: 0.52, green: 0.86, blue: 0.56)
    static let noteYellow = RGBAColor(red: 1, green: 0.95, blue: 0.62)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)

    static let entries: [Entry] = [
        Entry(name: "Yellow", color: yellow),
        Entry(name: "Orange", color: orange), Entry(name: "Red", color: red),
        Entry(name: "Pink", color: pink), Entry(name: "Purple", color: purple),
        Entry(name: "Blue", color: blue),
        Entry(name: "Green", color: green),
        Entry(name: "Light Yellow", color: noteYellow),
        Entry(name: "Black", color: black),
    ]

    /// A coloured dot for menus. Not a template image, so menus keep its
    /// colour.
    static func swatch(_ color: RGBAColor) -> NSImage {
        let image = NSImage(
            size: NSSize(width: 12, height: 12), flipped: false
        ) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
