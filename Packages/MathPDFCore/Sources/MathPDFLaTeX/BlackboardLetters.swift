import AppKit
import CoreText
import Foundation
import SwiftMath

/// `\mathbb` capitals in the AMS font, as LaTeX draws them, instead of Latin
/// Modern's thinner ones. SwiftMath lays a formula out in one font, and the
/// letters' widths differ by up to a fifth of an em, so before layout each
/// letter gets a line of its own and a space that makes up the difference.
/// After layout, that line is replaced.
@MainActor
enum BlackboardLetters {
    private static let ams: CTFont? = {
        guard
            let url = Bundle.module.url(
                forResource: "KaTeX_AMS-Regular", withExtension: "ttf",
                subdirectory: "Resources"),
            let data = try? Data(contentsOf: url),
            let descriptor = CTFontManagerCreateFontDescriptorFromData(
                data as CFData)
        else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, emSize, nil)
    }()

    private static let latinModern = MathFont.latinModernFont.ctFont(
        withSize: emSize)
    private static let emSize: CGFloat = 1000
    /// A math unit is 1/18 of an em.
    private static let unitsPerEm: CGFloat = 18

    /// The capitals by the character SwiftMath typesets them with.
    private static let capitals: [Unicode.Scalar: Character] = {
        let outsideTheBlock: [Character: UInt32] = [
            "C": 0x2102, "H": 0x210D, "N": 0x2115, "P": 0x2119, "Q": 0x211A,
            "R": 0x211D, "Z": 0x2124,
        ]
        var capitals: [Unicode.Scalar: Character] = [:]
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            let code = outsideTheBlock[letter] ?? 0x1D538 + UInt32(offset)
            if let scalar = Unicode.Scalar(code) { capitals[scalar] = letter }
        }
        return capitals
    }()

    // MARK: Before layout

    static func reserveWidths(in list: MTMathList) {
        guard ams != nil else { return }
        var atoms: [MTMathAtom] = []
        for atom in list.atoms {
            atom.innerLists.forEach(reserveWidths(in:))
            guard isCapital(atom), let extra = extraWidth(of: atom.nucleus)
            else {
                atoms.append(atom)
                continue
            }
            atoms += [makeSpace(0), atom, makeSpace(extra)].compactMap { $0 }
            if let scripts = takeScripts(of: atom) { atoms.append(scripts) }
        }
        list.atoms = atoms
    }

    /// An atom's font style isn't public, but printing it shows it.
    private static func isCapital(_ atom: MTMathAtom) -> Bool {
        atom.type == .variable && atom.nucleus.count == 1
            && atom.nucleus.first?.isUppercase == true
            && atom.nucleus.first?.isASCII == true
            && MTMathListBuilder.mathListToString(MTMathList(atom: atom))
                .hasPrefix(#"\mathbb{"#)
    }

    /// In math units: how much wider the AMS letter is. Negative if narrower.
    private static func extraWidth(of letter: String) -> CGFloat? {
        guard let ams, let new = glyph(for: letter, in: ams),
            let typeset = capitals.first(where: {
                String($0.value) == letter
            })?.key,
            let old = glyph(for: String(typeset), in: latinModern)
        else { return nil }
        let difference =
            advance(of: new, in: ams) - advance(of: old, in: latinModern)
        return difference / emSize * unitsPerEm
    }

    private static func glyph(for text: String, in font: CTFont) -> CGGlyph? {
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard
            CTFontGetGlyphsForCharacters(
                font, characters, &glyphs, characters.count)
        else { return nil }
        return glyphs[0]
    }

    private static func advance(of glyph: CGGlyph, in font: CTFont) -> CGFloat
    {
        var glyph = glyph
        return CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
    }

    /// Its initialiser isn't public, so the parser makes one.
    private static func makeSpace(_ width: CGFloat) -> MTMathSpace? {
        let space =
            MTMathListBuilder.build(fromString: #"\,"#)?.atoms.first
            as? MTMathSpace
        space?.space = width
        return space
    }

    /// Scripts go after a letter's space, so they clear the wider letter: on
    /// an empty atom, as with `{}^n` in LaTeX.
    private static func takeScripts(of atom: MTMathAtom) -> MTMathAtom? {
        guard atom.subScript != nil || atom.superScript != nil,
            let carrier = MTMathListBuilder.build(fromString: "^{}")?.atoms
                .first
        else { return nil }
        carrier.superScript = atom.superScript
        carrier.subScript = atom.subScript
        atom.superScript = nil
        atom.subScript = nil
        return carrier
    }

    // MARK: After layout

    static func useAMSLetters(in display: MTDisplay) {
        if let line = display as? MTCTLineDisplay { replaceLetter(of: line) }
        children(of: display).forEach(useAMSLetters(in:))
    }

    private static func replaceLetter(of display: MTCTLineDisplay) {
        guard let ams, display.atoms.count == 1,
            let scalars = display.atoms.first?.nucleus.unicodeScalars,
            scalars.count == 1,
            let letter = capitals[scalars[scalars.startIndex]],
            let run = (CTLineGetGlyphRuns(display.line) as? [CTRun])?.first,
            var attributes = CTRunGetAttributes(run)
                as? [NSAttributedString.Key: Any],
            let font = attributes[.font] as? NSFont
        else { return }
        attributes[.font] = CTFontCreateCopyWithAttributes(
            ams, font.pointSize, nil, nil)
        display.line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: String(letter), attributes: attributes))
    }

    /// Radicals, accents and limits keep their parts in types SwiftMath
    /// doesn't make public, so they can only be found by reflection. The
    /// dependency is pinned to one version, and the tests cover each kind of
    /// part.
    private static func children(of display: MTDisplay) -> [MTDisplay] {
        var children: [MTDisplay] = []
        var mirror: Mirror? = Mirror(reflecting: display)
        while let current = mirror {
            for child in current.children {
                if let part = child.value as? MTDisplay {
                    children.append(part)
                } else if let parts = child.value as? [MTDisplay] {
                    children += parts
                }
            }
            mirror = current.superclassMirror
        }
        return children
    }
}
