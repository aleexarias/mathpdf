import Foundation
import MathPDFCore
import Observation

/// The palette colours ⌥⇥ cycles through. Shared by all windows and kept in
/// user defaults.
@MainActor @Observable
final class ColorRotation {
    static let shared = ColorRotation()

    private static let key = "ColourRotation"
    /// Yellow and light red.
    private static let defaultIDs: Set = ["Yellow", "Red"]

    /// Palette entries' `id`s.
    private var ids: Set<String>

    private init() {
        ids =
            UserDefaults.standard.stringArray(forKey: Self.key).map(Set.init)
            ?? Self.defaultIDs
    }

    func contains(_ entry: Palette.Entry) -> Bool {
        ids.contains(entry.id)
    }

    func set(_ entry: Palette.Entry, included: Bool) {
        if included {
            ids.insert(entry.id)
        } else {
            ids.remove(entry.id)
        }
        UserDefaults.standard.set(
            Palette.entries.map(\.id).filter(ids.contains), forKey: Self.key)
    }

    /// The colour after `color` among those ticked, in palette order (see
    /// `cycling`).
    func color(after color: RGBAColor, backwards: Bool) -> RGBAColor? {
        Palette.entries.filter(contains).map(\.color).cycling(
            from: color, backwards: backwards)
    }
}
