import Foundation
import os

private let log = Logger(subsystem: "mathpdf", category: "images")

/// The images annotations show, each stored once under the SHA-256 of its file
/// and shared by every document, so relinking, page changes and copied pages
/// need no copies:
///
///     images/<sha256>.<png|jpg|heic>
///     images/<sha256>.corrupt-<time>.<extension>   damaged, never deleted
///
/// An image is written, durably, before any annotation refers to it, so a
/// crash can leave an unused file but never an annotation without its image.
/// Unused files are deleted at launch, after `gracePeriod`.
public actor ImageStore {
    /// How long an image goes unused, and untouched, before it's deleted: an
    /// image just stored for an annotation, in another window or another copy
    /// of the app, is never deleted under it.
    public static let gracePeriod: TimeInterval = 7 * 24 * 60 * 60

    public nonisolated let rootURL: URL
    let now: @Sendable () -> Date
    private var beforeReplace: (@Sendable () throws -> Void)?

    public init(
        rootURL: URL, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL
        self.now = now
    }

    nonisolated var folderURL: URL {
        rootURL.appending(path: "images", directoryHint: .isDirectory)
    }

    /// Returns once the image is on disk. One already there isn't written
    /// again.
    public func store(_ image: PreparedImage) throws(ImageStoreError) {
        try store(image.data, hash: image.hash)
    }

    /// An image's file as it was stored, wherever it comes from: copied pages
    /// bring theirs along. Its hash and type are checked.
    public func store(_ data: Data, hash: String) throws(ImageStoreError) {
        guard ImageReference.isHash(hash), sha256Hex(data) == hash,
            let fileExtension = StoredImageType.fileExtension(of: data)
        else { throw .invalidImage }
        if let stored = file(for: hash), self.data(for: hash) != nil {
            // used again: the grace period starts anew
            try? FileManager.default.setAttributes(
                [.modificationDate: now()], ofItemAtPath: stored.path)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: true)
            try AtomicFile.write(
                data, to: url(hash, fileExtension),
                beforeReplace: beforeReplace)
        } catch {
            throw .couldntWrite(error.localizedDescription)
        }
    }

    /// The image's bytes, if its file is there and intact. A damaged one is
    /// set aside: kept, but never read again.
    public func data(for hash: String) -> Data? {
        // mapped, as a stored file is only ever replaced, never changed
        guard let url = file(for: hash),
            let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else { return nil }
        guard sha256Hex(data) == hash else {
            setAside(url, hash: hash)
            return nil
        }
        return data
    }

    public var hasImages: Bool {
        !((try? FileManager.default.contentsOfDirectory(
            atPath: folderURL.path)) ?? []).isEmpty
    }

    /// Deletes images not in `referenced`, and leftovers of interrupted
    /// writes, once they've gone untouched for `gracePeriod`. Damaged files
    /// set aside are kept. Returns how many files were deleted.
    @discardableResult
    public func removeUnused(keeping referenced: Set<String>) -> Int {
        let names =
            (try? FileManager.default.contentsOfDirectory(
                atPath: folderURL.path)) ?? []
        var removed = 0
        for name in names where !name.contains(".corrupt-") {
            let isLeftover = name.contains(AtomicFile.tempMarker)
            let hash = String(name.prefix { $0 != "." })
            guard isLeftover || !referenced.contains(hash) else { continue }
            let url = folderURL.appending(path: name)
            guard
                let touched = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate,
                now().timeIntervalSince(touched) > Self.gracePeriod,
                (try? FileManager.default.removeItem(at: url)) != nil
            else { continue }
            removed += 1
        }
        if removed > 0 { log.info("Removed \(removed) unused image files") }
        return removed
    }

    /// The file of the image named `hash`, if there is one. Only a hash, so
    /// nothing from a damaged store can name a path elsewhere.
    private func file(for hash: String) -> URL? {
        guard ImageReference.isHash(hash) else { return nil }
        return StoredImageType.all.lazy.map {
            self.url(hash, $0.fileExtension)
        }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private nonisolated func url(_ hash: String, _ fileExtension: String)
        -> URL
    {
        folderURL.appending(path: "\(hash).\(fileExtension)")
    }

    private func setAside(_ url: URL, hash: String) {
        let name =
            "\(hash).corrupt-\(Timestamp.string(now(), compact: true))."
            + url.pathExtension
        log.error("Image \(hash, privacy: .public) is damaged")
        do {
            try FileManager.default.moveItem(
                at: url, to: folderURL.appending(path: name))
        } catch {
            log.error(
                """
                Couldn't set aside \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    // MARK: Testing

    /// Runs between writing the temp file and swapping it into place, for
    /// crash simulation.
    func setBeforeReplace(_ hook: (@Sendable () throws -> Void)?) {
        beforeReplace = hook
    }
}

public enum ImageStoreError: Error, Equatable, LocalizedError {
    case invalidImage
    case couldntWrite(String)

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "The image couldn't be stored."
        case .couldntWrite(let detail):
            "The image couldn't be saved (\(detail))."
        }
    }
}
