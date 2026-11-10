import Foundation
import MathPDFCore
import Observation

/// The palette colours ⌥⇥ cycles through. Shared by all windows and kept in
/// user defaults.
@MainActor @Observable
final class ColorRotation {
    static let shared = ColorRotation()

    private static let key = "ColourRotation"
    private static let defaultNames: Set = ["Yellow", "Red"]

    /// Palette entry names.
    private var names: Set<String>

    private init() {
        names =
            UserDefaults.standard.stringArray(forKey: Self.key).map(Set.init)
            ?? Self.defaultNames
    }

    func contains(_ entry: Palette.Entry) -> Bool {
        names.contains(entry.name)
    }

    func set(_ entry: Palette.Entry, included: Bool) {
        if included {
            names.insert(entry.name)
        } else {
            names.remove(entry.name)
        }
        UserDefaults.standard.set(
            Palette.entries.map(\.name).filter(names.contains),
            forKey: Self.key)
    }

    /// The colour after `color`, or before it going backwards, in palette
    /// order and wrapping round. One that isn't ticked goes to the first (or
    /// last) that is. Nil if none are.
    func color(after color: RGBAColor, backwards: Bool) -> RGBAColor? {
        let colors = Palette.entries.filter(contains).map(\.color)
        guard !colors.isEmpty else { return nil }
        guard let index = colors.firstIndex(of: color) else {
            return backwards ? colors.last : colors.first
        }
        let step = backwards ? colors.count - 1 : 1
        return colors[(index + step) % colors.count]
    }
}
