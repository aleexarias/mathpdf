import CoreGraphics
import Foundation

/// One annotation on one page. Geometry is in PDF page space (points, origin
/// at the bottom-left of the page), which is what PDFKit uses for annotation
/// bounds.
public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case underline
        case highlight
        /// `anchorRects` holds the selected lines for a note anchored to a
        /// selection. Empty means the note is anchored to a point: the origin
        /// of `bounds`.
        case note(text: String, anchorRects: [CGRect])
        /// The source is what was typed, and what the editor shows. `expanded`
        /// is that source with the user's own commands replaced, worked out
        /// once when it's entered and drawn from then on, so changing a
        /// command later doesn't alter the formula. Nil if it used none.
        case latex(source: String, fontSize: Double, expanded: String? = nil)
        /// Text placed on the page, drawn in Helvetica at `fontSize`, with
        /// LaTeX between `$` signs typeset in place. `expanded` is the text
        /// with the user's own commands replaced in its formulas, as for a
        /// formula. Nil if it used none.
        case textBox(text: String, fontSize: Double, expanded: String? = nil)
    }

    public var id: UUID
    public var kind: Kind
    public var pageIndex: Int
    public var bounds: CGRect
    public var color: RGBAColor
    /// Shared by the per-line annotations made from one multi-line selection,
    /// so they can be selected, recoloured and deleted together.
    public var groupID: UUID?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        pageIndex: Int,
        bounds: CGRect,
        color: RGBAColor,
        groupID: UUID? = nil,
        createdAt: Date = Timestamp.now(),
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.color = color
        self.groupID = groupID
        self.createdAt = Timestamp.normalized(createdAt)
        self.modifiedAt = Timestamp.normalized(modifiedAt ?? createdAt)
    }
}

/// An sRGB colour with components in 0...1, stored as `[r, g, b, a]`.
public struct RGBAColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Double].self)
        guard values.count == 4 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "A colour needs 4 components, got \(values.count)")
        }
        self.init(
            red: values[0], green: values[1], blue: values[2], alpha: values[3]
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([red, green, blue, alpha])
    }
}

/// Everything stored for one PDF. This is the payload of the current store
/// file and of every snapshot.
public struct AnnotationSet: Codable, Equatable, Sendable {
    /// Hex SHA-256 of the PDF's bytes: the key the set is stored under.
    public var documentHash: String
    /// Where the PDF was last seen. Hints only: used to suggest relinks, never
    /// to find data.
    public var fileNameHint: String
    public var pathHint: String
    public var pageCount: Int
    /// Goes up with every change. The store ignores saves older than what it
    /// has written.
    public var revision: Int
    public var savedAt: Date
    /// Set when the annotations were copied over from another PDF's set.
    public var relinkedFrom: String?
    public var annotations: [Annotation]

    public init(
        documentHash: String,
        fileNameHint: String,
        pathHint: String,
        pageCount: Int,
        revision: Int = 0,
        savedAt: Date = Timestamp.now(),
        relinkedFrom: String? = nil,
        annotations: [Annotation] = []
    ) {
        self.documentHash = documentHash
        self.fileNameHint = fileNameHint
        self.pathHint = pathHint
        self.pageCount = pageCount
        self.revision = revision
        self.savedAt = Timestamp.normalized(savedAt)
        self.relinkedFrom = relinkedFrom
        self.annotations = annotations
    }
}

// MARK: - Coding

extension Annotation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, type, pageIndex, bounds, color, groupID, createdAt, modifiedAt
        case text, anchorRects  // note
        // latex; a text box has text, fontSize, expanded
        case source, fontSize, expanded
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func rect(_ values: [Double], _ key: CodingKeys) throws -> CGRect {
            guard let rect = CGRect(components: values) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: c,
                    debugDescription:
                        "A rect needs 4 numbers, got \(values.count)")
            }
            return rect
        }

        id = try c.decode(UUID.self, forKey: .id)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        bounds = try rect(c.decode([Double].self, forKey: .bounds), .bounds)
        color = try c.decode(RGBAColor.self, forKey: .color)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)

        switch try c.decode(String.self, forKey: .type) {
        case "underline":
            kind = .underline
        case "highlight":
            kind = .highlight
        case "note":
            let anchors = try c.decode([[Double]].self, forKey: .anchorRects)
                .map { try rect($0, .anchorRects) }
            kind = .note(
                text: try c.decode(String.self, forKey: .text),
                anchorRects: anchors)
        case "textbox":
            kind = .textBox(
                text: try c.decode(String.self, forKey: .text),
                fontSize: try c.decode(Double.self, forKey: .fontSize),
                expanded: try c.decodeIfPresent(
                    String.self, forKey: .expanded))
        case "latex":
            kind = .latex(
                source: try c.decode(String.self, forKey: .source),
                fontSize: try c.decode(Double.self, forKey: .fontSize),
                expanded: try c.decodeIfPresent(
                    String.self, forKey: .expanded))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown annotation type \"\(other)\"")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pageIndex, forKey: .pageIndex)
        try c.encode(bounds.components, forKey: .bounds)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)

        switch kind {
        case .underline:
            try c.encode("underline", forKey: .type)
        case .highlight:
            try c.encode("highlight", forKey: .type)
        case let .note(text, anchorRects):
            try c.encode("note", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(anchorRects.map(\.components), forKey: .anchorRects)
        case let .textBox(text, fontSize, expanded):
            try c.encode("textbox", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encodeIfPresent(expanded, forKey: .expanded)
        case let .latex(source, fontSize, expanded):
            try c.encode("latex", forKey: .type)
            try c.encode(source, forKey: .source)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encodeIfPresent(expanded, forKey: .expanded)
        }
    }
}

extension CGRect {
    /// `[x, y, width, height]`, the form rects take in store files.
    var components: [Double] {
        [
            Double(origin.x), Double(origin.y), Double(size.width),
            Double(size.height),
        ]
    }

    init?(components values: [Double]) {
        guard values.count == 4 else { return nil }
        self.init(
            x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
