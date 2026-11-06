import SwiftMath

/// Formulas SwiftMath would crash on, changed once parsed so it doesn't.
@MainActor
enum MathListRepairs {
    static func apply(to list: MTMathList) {
        for (index, atom) in list.atoms.enumerated() {
            if index > 0, let colored = atom as? MTMathTextColor {
                giveTextToStartWith(colored)
            }
            atom.innerLists.forEach(apply(to:))
        }
    }

    /// After anything else, `\textcolor` takes it for granted that its group
    /// starts with plain text, and crashes on a fraction, a root, a sum or
    /// nothing at all. An empty atom with empty scripts is drawn as text.
    private static func giveTextToStartWith(_ colored: MTMathTextColor) {
        let list = colored.innerList ?? MTMathList()
        colored.innerList = list
        let first = list.atoms.first { atom in
            atom.type != .space && atom.type != .style
        }
        guard !startsWithText(first),
            let empty = MTMathListBuilder.build(fromString: "^{}")?.atoms.first
        else { return }
        list.atoms.insert(empty, at: 0)
    }

    private static func startsWithText(_ atom: MTMathAtom?) -> Bool {
        switch atom?.type {
        case .ordinary, .variable, .number, .binaryOperator, .unaryOperator,
            .relation, .open, .close, .punctuation, .placeholder:
            return true
        default:
            return false
        }
    }
}

extension MTMathAtom {
    /// The lists inside an atom, which are laid out with it.
    var innerLists: [MTMathList] {
        var lists = [subScript, superScript]
        switch self {
        case let atom as MTFraction:
            lists += [atom.numerator, atom.denominator]
        case let atom as MTRadical: lists += [atom.radicand, atom.degree]
        case let atom as MTInner: lists.append(atom.innerList)
        case let atom as MTOverLine: lists.append(atom.innerList)
        case let atom as MTUnderLine: lists.append(atom.innerList)
        case let atom as MTAccent: lists.append(atom.innerList)
        case let atom as MTMathColor: lists.append(atom.innerList)
        case let atom as MTMathTextColor: lists.append(atom.innerList)
        case let atom as MTMathColorbox: lists.append(atom.innerList)
        case let atom as MTMathTable: lists += atom.cells.flatMap { $0 }
        default: break
        }
        return lists.compactMap { $0 }
    }
}
