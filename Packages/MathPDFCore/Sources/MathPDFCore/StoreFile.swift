import CryptoKit
import Foundation

/// The on-disk format shared by `store.json` and every snapshot:
///
///     {"schemaVersion":4,"sha256":"<hex>","payload":{ …AnnotationSet… }}
///
/// The checksum covers the exact payload bytes as written, so checking it
/// never depends on re-encoding. The payload is always the last key, which
/// lets `decode` slice it back out. A file that was reformatted by hand
/// therefore fails the check and is treated as damaged.
///
/// Schema history:
/// - 1: the first format, read through `MigrationV1`
/// - 2: one annotation per line, sRGB colours, font sizes, notes anchored to
///   text
/// - 3: adds text boxes (`"type": "textbox"`). Nothing else changed, so a v2
///   payload is a valid v3 payload. An app that only knows v2 refuses v3 files
///   instead of overwriting them.
/// - 4: a formula can carry `expanded`, its source with the user's own
///   commands replaced. A v3 payload is a valid v4 payload, and an app that
///   only knows v3 refuses v4 files rather than draw and save them without it.
enum StoreFile {
    static let currentSchemaVersion = 4

    struct Decoded: Sendable {
        var set: AnnotationSet
        /// The schema version found on disk, before any migration.
        var schemaVersion: Int
    }

    static func encode(_ set: AnnotationSet) throws -> Data {
        let payload = try makeEncoder().encode(set)
        let header =
            "{\"schemaVersion\":\(currentSchemaVersion),"
            + "\"sha256\":\"\(sha256Hex(payload))\",\"payload\":"
        var data = Data(header.utf8)
        data.append(payload)
        data.append(contentsOf: Array("}\n".utf8))
        return data
    }

    static func decode(_ data: Data) throws -> Decoded {
        guard
            let envelope = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw StoreFileError.malformed("not a JSON object")
        }
        guard let version = envelope["schemaVersion"] as? Int,
            let checksum = envelope["sha256"] as? String
        else {
            throw StoreFileError.malformed("missing schemaVersion or sha256")
        }
        guard version <= currentSchemaVersion else {
            throw StoreFileError.newerSchema(version)
        }

        let marker = Data("\"payload\":".utf8)
        guard let start = data.range(of: marker)?.upperBound,
            let end = data.lastIndex(of: UInt8(ascii: "}")), start < end
        else { throw StoreFileError.malformed("payload not found") }
        let payload = Data(data[start..<end])
        guard sha256Hex(payload) == checksum else {
            throw StoreFileError.checksumMismatch
        }

        do {
            switch version {
            case 1:
                return Decoded(
                    set: try MigrationV1.migrate(
                        payload, using: makeDecoder()), schemaVersion: 1)
            case 2, 3, 4:
                return Decoded(
                    set: try makeDecoder().decode(
                        AnnotationSet.self, from: payload),
                    schemaVersion: version)
            default:
                throw StoreFileError.malformed(
                    "unknown schemaVersion \(version)")
            }
        } catch let error as StoreFileError {
            throw error
        } catch {
            throw StoreFileError.malformed(String(describing: error))
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Timestamp.string(date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = Timestamp.parse(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid timestamp \"\(string)\"")
            }
            return date
        }
        return decoder
    }
}

enum StoreFileError: Error, Equatable, LocalizedError {
    case malformed(String)
    case checksumMismatch
    /// Written by a newer version of the app; must not be read with this
    /// schema or overwritten.
    case newerSchema(Int)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): "The file is damaged (\(detail))."
        case .checksumMismatch:
            "The file's checksum doesn't match its contents."
        case .newerSchema(let version):
            """
            The file was written by a newer version of mathpdf (schema \
            \(version)).
            """
        }
    }
}

/// Lowercase hex SHA-256. Used both to key a PDF's annotations and to checksum
/// store files.
public func sha256Hex(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
}

/// The same for a file another app might be writing. It's read in pieces, as
/// reading a mapped file crashes if it's cut short along the way.
public func sha256Hex(ofFileAt url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hasher = SHA256()
    while let piece = try file.read(upToCount: 1 << 20), !piece.isEmpty {
        hasher.update(data: piece)
    }
    return hex(hasher.finalize())
}

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}
