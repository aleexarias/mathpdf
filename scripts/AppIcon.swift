// Draws mathpdf's app icon at every size macOS needs, into
// App/Assets.xcassets/AppIcon.appiconset.
//
//     xcrun swift scripts/AppIcon.swift [--preview <file.png>]
//
// Everything is drawn in a 1024 × 1024 design space (y up) and scaled, so each
// size is drawn sharp rather than shrunk. The body follows macOS's icon grid:
// an 824-point rounded square with continuous corners, centred, with room
// around it for the shadow.

import AppKit
import CoreText
import Foundation

let iconSet = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "App/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
        green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

/// The macOS icon shape: a superellipse, which has the continuous corners of
/// Apple's squircle.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + rect.height / 2 * copysign(pow(abs(s), 2 / n), s)
        step == 0
            ? path.move(to: CGPoint(x: x, y: y))
            : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// `pixels` is the size being drawn: shadows don't scale with the context, so
/// they're scaled by hand, and the smallest sizes show only the ∑, since the
/// rest would be a smudge there.
func drawIcon(in context: CGContext, pixels: Int) {
    let shadowScale = CGFloat(pixels) / 1024
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    // The body, with the soft shadow macOS icons sit on.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10 * shadowScale),
        blur: 24 * shadowScale, color: color(0x000000, 0.28))
    context.addPath(shape)
    context.setFillColor(color(0x2B45B8))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x6C9BFF), color(0x3A5BE0), color(0x24349E)] as CFArray,
        locations: [0, 0.55, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100),
        options: [])

    // A sheet of paper with its corner folded.
    let page = CGRect(x: 277, y: 206, width: 470, height: 600),
        fold: CGFloat = 96, corner: CGFloat = 34
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: page.minX + corner, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX - corner, y: page.minY))
    outline.addQuadCurve(
        to: CGPoint(x: page.maxX, y: page.minY + corner),
        control: CGPoint(x: page.maxX, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    outline.addLine(to: CGPoint(x: page.minX + corner, y: page.maxY))
    outline.addQuadCurve(
        to: CGPoint(x: page.minX, y: page.maxY - corner),
        control: CGPoint(x: page.minX, y: page.maxY))
    outline.addLine(to: CGPoint(x: page.minX, y: page.minY + corner))
    outline.addQuadCurve(
        to: CGPoint(x: page.minX + corner, y: page.minY),
        control: CGPoint(x: page.minX, y: page.minY))
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -16 * shadowScale),
        blur: 34 * shadowScale, color: color(0x0B1450, 0.45))
    context.addPath(outline)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    flap.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    flap.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    flap.closeSubpath()
    context.addPath(flap)
    context.setFillColor(color(0xD8DEEB))
    context.fillPath()

    let isSmall = pixels <= 32
    let room =
        isSmall
        ? CGSize(width: 300, height: 420) : CGSize(width: 370, height: 400)
    drawFormula(
        in: context, fitting: room,
        centeredAt: CGPoint(x: page.midX, y: page.midY - 10),
        symbolOnly: isSmall)
    context.restoreGState()
}

/// \sum x_i, set as display math in STIX: the sum upright and centred on the
/// math axis, x italic with its index lowered, then all of it scaled to fit
/// `room`.
func drawFormula(
    in context: CGContext, fitting room: CGSize, centeredAt center: CGPoint,
    symbolOnly: Bool
) {
    let ink = color(0x1D2A6B)
    let size: CGFloat = 100, script = 0.7 * size, axis = 0.26 * size
    func font(_ style: String, _ size: CGFloat) -> CTFont {
        CTFontCreateWithName("STIXGeneral-\(style)" as CFString, size, nil)
    }
    func line(_ string: String, _ font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: string,
                attributes: [.font: font, .foregroundColor: ink]))
    }
    func glyphBounds(_ line: CTLine) -> CGRect {
        CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }

    let unit = glyphBounds(line("∑", font("Regular", size)))
    let sum = line("∑", font("Regular", size * 1.5 * size / unit.height))
    let sumBounds = glyphBounds(sum)
    let sumOrigin = CGPoint(x: -sumBounds.minX, y: axis - sumBounds.midY)
    var placed = [(line: sum, at: sumOrigin)]
    if !symbolOnly {
        let x = line("x", font("Italic", size))
        let xOrigin = CGPoint(x: sumBounds.width + 0.17 * size, y: 0)
        placed.append((x, xOrigin))
        let index = CGPoint(
            x: xOrigin.x
                + CGFloat(CTLineGetTypographicBounds(x, nil, nil, nil)),
            y: -0.18 * size)
        placed.append((line("i", font("Italic", script)), index))
    }

    let bounds = placed.map {
        CTLineGetBoundsWithOptions($0.line, .useGlyphPathBounds).offsetBy(
            dx: $0.at.x, dy: $0.at.y)
    }
    .reduce(CGRect.null) { $0.union($1) }
    let scale = min(room.width / bounds.width, room.height / bounds.height)
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.midX, y: -bounds.midY)
    context.textMatrix = .identity
    for (line, origin) in placed {
        context.textPosition = origin
        CTLineDraw(line, context)
    }
    context.restoreGState()
}

func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: context, pixels: pixels)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// The sizes a Mac app icon comes in: each point size at 1× and 2×.
try FileManager.default.createDirectory(
    at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(
            render(pixels: points * scale), to: iconSet.appending(path: name))
        images.append([
            "idiom": "mac", "size": "\(points)x\(points)",
            "scale": "\(scale)x", "filename": name,
        ])
    }
}
let contents: [String: Any] = [
    "images": images, "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(
    withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appending(path: "Contents.json"))
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(
    to: iconSet.deletingLastPathComponent().appending(path: "Contents.json"))

// --preview: the icon large, and at the sizes Finder and the Dock show it,
// side by side.
if let flag = CommandLine.arguments.firstIndex(of: "--preview"),
    CommandLine.arguments.count > flag + 1
{
    let sizes = [512, 256, 128, 64, 32, 16]
    let width = sizes.reduce(0) { $0 + $1 + 40 } + 40, height = 512 + 80
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color(0xECECEC))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    context.setFillColor(color(0x2A2A2C))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    var x = 40
    for size in sizes {
        context.draw(
            render(pixels: size),
            in: CGRect(x: x, y: (height - size) / 2, width: size, height: size)
        )
        x += size + 40
    }
    writePNG(
        context.makeImage()!,
        to: URL(filePath: CommandLine.arguments[flag + 1]))
}
print("Wrote \(images.count) icons to \(iconSet.path)")
