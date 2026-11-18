import AppKit
import MathPDFCore
import MathPDFRendering

enum Palette {
    struct Entry: Identifiable {
        let name: String
        let color: RGBAColor
        /// What the colour rotation saves it under: its name, or the one it
        /// had before a rename, so it stays ticked.
        let id: String

        init(name: String, color: RGBAColor, savedAs id: String? = nil) {
            self.name = name
            self.color = color
            self.id = id ?? name
        }
    }

    // Soft tones, so highlights don't overpower the text.
    static let yellow = RGBAColor(red: 1, green: 0.88, blue: 0.32)
    static let orange = RGBAColor(red: 1, green: 0.72, blue: 0.38)
    static let lightRed = RGBAColor(
        red: 249 / 255, green: 135 / 255, blue: 128 / 255)
    static let pink = RGBAColor(red: 1, green: 0.62, blue: 0.82)
    static let purple = RGBAColor(red: 0.78, green: 0.64, blue: 1)
    static let blue = RGBAColor(red: 0.52, green: 0.76, blue: 1)
    static let green = RGBAColor(red: 0.52, green: 0.86, blue: 0.56)
    static let noteYellow = RGBAColor(red: 1, green: 0.95, blue: 0.62)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    /// Vivid, yet dark enough to read as text on a white page.
    static let red = RGBAColor(
        red: 214 / 255, green: 40 / 255, blue: 40 / 255)
    static let darkBlue = RGBAColor(
        red: 27 / 255, green: 54 / 255, blue: 102 / 255)
    static let grey = RGBAColor(
        red: 77 / 255, green: 82 / 255, blue: 91 / 255)
    static let white = RGBAColor(
        red: 242 / 255, green: 240 / 255, blue: 232 / 255)

    /// Retired colours, mapped to the ones that replace them.
    static let replaced = [
        RGBAColor(red: 1, green: 0.48, blue: 0.45): lightRed
    ]

    static let entries: [Entry] = [
        Entry(name: "Red", color: red, savedAs: "Vibrant Red"),
        Entry(name: "Light Red", color: lightRed, savedAs: "Red"),
        Entry(name: "Orange", color: orange),
        Entry(name: "Yellow", color: yellow),
        Entry(name: "Light Yellow", color: noteYellow),
        Entry(name: "Green", color: green),
        Entry(name: "Blue", color: blue),
        Entry(name: "Dark Blue", color: darkBlue),
        Entry(name: "Purple", color: purple),
        Entry(name: "Pink", color: pink),
        Entry(name: "White", color: white),
        Entry(name: "Grey", color: grey),
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
