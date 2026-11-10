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

    /// The colour after `color` among those ticked, in palette order (see
    /// `cycling`).
    func color(after color: RGBAColor, backwards: Bool) -> RGBAColor? {
        Palette.entries.filter(contains).map(\.color).cycling(
            from: color, backwards: backwards)
    }
}
