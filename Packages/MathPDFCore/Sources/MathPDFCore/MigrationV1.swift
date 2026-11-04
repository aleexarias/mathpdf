import CoreGraphics
import CryptoKit
import Foundation

/// Schema v1 → v2. What changed:
/// - an underline or highlight was one record with several `rects` (one per
///   line); v2 stores one annotation per line, and the lines share a `groupID`
/// - `page` became `pageIndex`
/// - colours were `#RRGGBB` strings; v2 stores sRGB components plus alpha
/// - `originalPath` became `pathHint` plus `fileNameHint`
/// - LaTeX annotations had no `fontSize` (they were always 14 pt)
/// - notes could only be anchored to a point
enum MigrationV1 {
    private struct Payload: Decodable {
        let documentHash: String
        let originalPath: String
        let pageCount: Int
        let revision: Int
        let savedAt: Date
        let annotations: [Item]
    }

    private struct Item: Decodable {
        let id: UUID
        let type: String
        let page: Int
        let rects: [[Double]]
        let color: String
        let createdAt: Date
        let modifiedAt: Date
        let text: String?
        let source: String?
    }

    static func migrate(_ payload: Data, using decoder: JSONDecoder) throws
        -> AnnotationSet
    {
        let old = try decoder.decode(Payload.self, from: payload)
        return AnnotationSet(
            documentHash: old.documentHash,
            fileNameHint: URL(fileURLWithPath: old.originalPath)
                .lastPathComponent,
            pathHint: old.originalPath,
            pageCount: old.pageCount,
            revision: old.revision,
            savedAt: old.savedAt,
            annotations: try old.annotations.flatMap(migrate)
        )
    }

    private static func migrate(_ item: Item) throws -> [Annotation] {
        let rects = try item.rects.map { values in
            guard let rect = CGRect(components: values) else {
                throw StoreFileError.malformed(
                    "bad rect in v1 annotation \(item.id)")
            }
            return rect
        }
        guard let first = rects.first else {
            throw StoreFileError.malformed(
                "v1 annotation \(item.id) has no rects")
        }
        let color = try color(fromHex: item.color)

        func make(
            _ kind: Annotation.Kind, id: UUID, bounds: CGRect,
            groupID: UUID? = nil
        ) -> Annotation {
            Annotation(
                id: id, kind: kind, pageIndex: item.page, bounds: bounds,
                color: color,
                groupID: groupID, createdAt: item.createdAt,
                modifiedAt: item.modifiedAt)
        }

        switch item.type {
        case "underline", "highlight":
            let kind: Annotation.Kind =
                item.type == "underline" ? .underline : .highlight
            let groupID = rects.count > 1 ? derivedID(item.id, "group") : nil
            return rects.enumerated().map { index, rect in
                make(
                    kind,
                    id: index == 0
                        ? item.id : derivedID(item.id, "line\(index)"),
                    bounds: rect, groupID: groupID)
            }
        case "note":
            return [
                make(
                    .note(text: item.text ?? "", anchorRects: []), id: item.id,
                    bounds: first)
            ]
        case "latex":
            guard let source = item.source else {
                throw StoreFileError.malformed(
                    "v1 LaTeX annotation \(item.id) has no source")
            }
            return [
                make(
                    .latex(source: source, fontSize: 14), id: item.id,
                    bounds: first)
            ]
        default:
            throw StoreFileError.malformed(
                "unknown v1 annotation type \"\(item.type)\"")
        }
    }

    /// IDs for the extra annotations a v1 record splits into. Derived from the
    /// original ID, so migrating the same file twice gives identical results.
    static func derivedID(_ base: UUID, _ salt: String) -> UUID {
        var b = Array(
            SHA256.hash(data: Data("\(base.uuidString)/\(salt)".utf8)).prefix(
                16))
        b[6] = (b[6] & 0x0F) | 0x80  // version 8 (custom)
        b[8] = (b[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(
            uuid: (
                b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
            ))
    }

    static func color(fromHex hex: String) throws -> RGBAColor {
        guard hex.count == 7, hex.hasPrefix("#"),
            let value = UInt32(hex.dropFirst(), radix: 16)
        else {
            throw StoreFileError.malformed("bad v1 colour \"\(hex)\"")
        }
        return RGBAColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
