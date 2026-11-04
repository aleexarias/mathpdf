import Foundation
import os

private let log = Logger(subsystem: "mathpdf", category: "persistence")

/// Owns every read and write of annotation data. Being an actor serialises all
/// disk work, and each method does its file work without suspending, so two
/// writes can never interleave.
///
/// Layout under `rootURL`, one folder per PDF, keyed by the SHA-256 of the
/// PDF's bytes:
///
///     documents/<hash>/store.json                  current state
///     documents/<hash>/snapshots/<time>-r<n>.json  immutable history
///     documents/<hash>/store.corrupt-<time>.json   damaged, never deleted
///     documents/<hash>/pages.json                  page IDs (`PageIdentity`)
///     documents/<hash>/document.pdf                the PDF, once a page
///                                                  change left these pages
public actor AnnotationStore {
    public enum LoadResult: Sendable {
        /// Nothing has ever been saved for this PDF.
        case fresh
        case loaded(AnnotationSet, migratedFrom: Int?)
        /// The current file was missing or damaged, so the set comes from
        /// `snapshot`.
        case recovered(AnnotationSet, snapshot: SnapshotInfo, problem: String)
        /// Data exists but can't be used. Saving is refused, so nothing gets
        /// overwritten.
        case blocked(BlockReason)

        public var set: AnnotationSet? {
            switch self {
            case .loaded(let set, _), .recovered(let set, _, _): set
            case .fresh, .blocked: nil
            }
        }
    }

    public enum BlockReason: Sendable, Equatable {
        /// Written by a newer version of the app. Never overwritten.
        case newerSchema(Int)
        /// The current file and every snapshot are damaged. See
        /// `allowFreshStart`.
        case noValidData
    }

    public nonisolated let rootURL: URL
    let now: @Sendable () -> Date
    private var lastWrittenRevision: [String: Int] = [:]
    private var blocked: [String: BlockReason] = [:]
    private var beforeStoreReplace: (@Sendable () throws -> Void)?
    /// The folders of each document whose page IDs are stored. Built on first
    /// use, then kept up to date by this store's own writes.
    var foldersByDocument: [UUID: Set<String>]?
    let limits: CopyLimits

    public static var defaultRootURL: URL {
        URL.applicationSupportDirectory.appending(
            path: "mathpdf", directoryHint: .isDirectory)
    }

    public init(
        rootURL: URL = AnnotationStore.defaultRootURL,
        now: @escaping @Sendable () -> Date = { Date() },
        limits: CopyLimits = .standard
    ) {
        self.rootURL = rootURL
        self.now = now
        self.limits = limits
    }

    // MARK: Loading

    public func load(documentHash hash: String) -> LoadResult {
        let folder = folderURL(hash)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return .fresh
        }
        removeLeftoverTempFiles(hash)

        let storeURL = storeURL(hash)
        let problem: String
        if let data = try? Data(contentsOf: storeURL) {
            do {
                let decoded = try StoreFile.decode(data)
                lastWrittenRevision[hash] = decoded.set.revision
                let migratedFrom =
                    decoded.schemaVersion < StoreFile.currentSchemaVersion
                    ? decoded.schemaVersion : nil
                return .loaded(decoded.set, migratedFrom: migratedFrom)
            } catch StoreFileError.newerSchema(let version) {
                blocked[hash] = .newerSchema(version)
                return .blocked(.newerSchema(version))
            } catch {
                let keptAs = setAside(storeURL)
                problem =
                    """
                    The annotations file couldn't be read. \
                    \(error.localizedDescription) It was kept as \(keptAs).
                    """
                log.error(
                    """
                    Damaged store for \(hash, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        } else {
            problem = "The annotations file was missing."
        }

        for snapshot in snapshots(documentHash: hash) {
            guard let data = try? Data(contentsOf: snapshot.url),
                let decoded = try? StoreFile.decode(data)
            else {
                log.error(
                    """
                    Skipping damaged snapshot \
                    \(snapshot.url.lastPathComponent, privacy: .public)
                    """
                )
                continue
            }
            // Put the recovered state back as the current file, so the next
            // launch loads it normally.
            do { try AtomicFile.write(data, to: storeURL) } catch {
                log.error(
                    """
                    Couldn't restore store from snapshot: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
            lastWrittenRevision[hash] = decoded.set.revision
            return .recovered(
                decoded.set, snapshot: snapshot, problem: problem)
        }

        if !hasAnyData(hash) { return .fresh }
        blocked[hash] = .noValidData
        return .blocked(.noValidData)
    }

    /// After `.blocked(.noValidData)`, lets the user start again from empty.
    /// The unreadable files stay where they are.
    public func allowFreshStart(documentHash hash: String) {
        if blocked[hash] == .noValidData { blocked[hash] = nil }
    }

    // MARK: Saving

    /// Writes `set` as the current state and as a new snapshot, then prunes
    /// old snapshots. Returns false, without writing, when a newer or equal
    /// revision is already on disk.
    @discardableResult
    public func save(_ set: AnnotationSet) throws -> Bool {
        let hash = set.documentHash
        if let reason = blocked[hash] {
            throw AnnotationStoreError.savingBlocked(reason)
        }
        if let onDisk = try revisionOnDisk(hash), set.revision <= onDisk {
            return false
        }

        var set = set
        set.savedAt = Timestamp.normalized(now())
        let data = try StoreFile.encode(set)
        try FileManager.default.createDirectory(
            at: snapshotsURL(hash), withIntermediateDirectories: true)

        try AtomicFile.write(
            data, to: storeURL(hash), beforeReplace: beforeStoreReplace)
        lastWrittenRevision[hash] = set.revision

        // The current file is written first, so it is never older than the
        // newest snapshot. A failed snapshot write costs one history entry,
        // not the save.
        let snapshotURL = snapshotsURL(hash).appending(
            path: SnapshotInfo.fileName(
                date: set.savedAt, revision: set.revision))
        do { try AtomicFile.write(data, to: snapshotURL) } catch {
            log.error(
                """
                Snapshot write failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        prune(hash)
        return true
    }

    /// Saves the annotations of a PDF whose pages just changed, under its new
    /// hash. That PDF may have been seen before (undoing a change brings back
    /// earlier bytes), so the revision is raised past anything stored for it.
    public func saveAfterPageChange(_ set: AnnotationSet) throws
        -> AnnotationSet
    {
        var set = set
        set.revision =
            max(set.revision, try revisionOnDisk(set.documentHash) ?? 0) + 1
        try save(set)
        return set
    }

    /// The revision of the current file on disk, if it can be read. Also
    /// refuses to touch a file written by a newer app version.
    private func revisionOnDisk(_ hash: String) throws -> Int? {
        if let known = lastWrittenRevision[hash] { return known }
        let storeURL = storeURL(hash)
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        do {
            let revision = try StoreFile.decode(data).set.revision
            lastWrittenRevision[hash] = revision
            return revision
        } catch StoreFileError.newerSchema(let version) {
            blocked[hash] = .newerSchema(version)
            throw AnnotationStoreError.savingBlocked(.newerSchema(version))
        } catch {
            setAside(storeURL)
            return nil
        }
    }

    /// Thins out the versions of the document `hash` belongs to. The
    /// snapshots of all its page orders count as one history, and a page
    /// order left with none goes entirely, its kept PDF too. Then the copies
    /// of the PDF are kept within `limits`.
    private func prune(_ hash: String) {
        let documentID = pageIdentity(documentHash: hash)?.documentID
        let orders = documentID.map { folders(of: $0).union([hash]) } ?? [hash]
        var all: [SnapshotInfo] = []
        var orderOfSnapshot: [URL: String] = [:]
        for order in orders {
            for snapshot in snapshots(documentHash: order) {
                all.append(snapshot)
                orderOfSnapshot[snapshot.url] = order
            }
        }
        // It holds the first version, which is never deleted.
        let firstOrder = all.min {
            ($0.date, $0.revision) < ($1.date, $1.revision)
        }.flatMap { orderOfSnapshot[$0.url] }
        for snapshot in RetentionPolicy.snapshotsToDelete(all, now: now()) {
            remove(snapshot.url)
        }
        for order in orders where order != hash && isEmpty(order) {
            guard remove(folderURL(order)) else { continue }
            lastWrittenRevision[order] = nil
            if let documentID {
                foldersByDocument?[documentID]?.remove(order)
            }
        }
        if let documentID {
            pruneCopies(of: documentID, current: hash, first: firstOrder)
        }
    }

    /// Deletes a file or folder, and logs it if that fails.
    @discardableResult
    func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            log.error(
                """
                Couldn't delete \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
    }

    /// No versions left, and no damaged file, which is kept for inspection.
    private func isEmpty(_ hash: String) -> Bool {
        let names =
            (try? FileManager.default.contentsOfDirectory(
                atPath: folderURL(hash).path)) ?? []
        return snapshots(documentHash: hash).isEmpty
            && !names.contains { $0.hasPrefix("store.corrupt") }
    }

    // MARK: History

    /// All snapshots for a PDF, newest first.
    public func snapshots(documentHash hash: String) -> [SnapshotInfo] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: snapshotsURL(hash), includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap(SnapshotInfo.init(url:)).sorted {
            ($0.date, $0.revision) > ($1.date, $1.revision)
        }
    }

    public func readSnapshot(_ snapshot: SnapshotInfo) throws -> AnnotationSet
    {
        try StoreFile.decode(Data(contentsOf: snapshot.url)).set
    }

    // MARK: Relinking

    public struct StoredSetSummary: Identifiable, Sendable {
        public let documentHash: String
        public let fileNameHint: String
        public let pathHint: String
        public let pageCount: Int
        public let annotationCount: Int
        public let savedAt: Date
        public var id: String { documentHash }
    }

    /// Every annotation set on disk that can be read, newest first. Used to
    /// offer a relink when a PDF's hash matches nothing (e.g. it was edited
    /// elsewhere).
    public func storedSets() -> [StoredSetSummary] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: documentsURL, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let hash = folder.lastPathComponent
            guard let set = newestSet(documentHash: hash) else { return nil }
            return StoredSetSummary(
                documentHash: hash, fileNameHint: set.fileNameHint,
                pathHint: set.pathHint,
                pageCount: set.pageCount,
                annotationCount: set.annotations.count, savedAt: set.savedAt)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    /// Copies the annotations stored for `sourceHash` onto another PDF,
    /// described by `target` (its hash, hints and page count). The source set
    /// is left untouched.
    public func relink(from sourceHash: String, to target: AnnotationSet)
        throws -> AnnotationSet
    {
        guard let source = newestSet(documentHash: sourceHash) else {
            throw AnnotationStoreError.nothingToRelink(sourceHash)
        }
        var set = target
        set.annotations = source.annotations
        set.relinkedFrom = sourceHash
        set.revision =
            max(source.revision, try revisionOnDisk(target.documentHash) ?? 0)
            + 1
        try save(set)
        return set
    }

    /// The current file if it can be read, otherwise the newest readable
    /// snapshot. Writes nothing.
    public func newestSet(documentHash hash: String) -> AnnotationSet? {
        if let data = try? Data(contentsOf: storeURL(hash)),
            let decoded = try? StoreFile.decode(data)
        {
            return decoded.set
        }
        return snapshots(documentHash: hash).lazy.compactMap {
            try? self.readSnapshot($0)
        }.first
    }

    // MARK: Files

    var documentsURL: URL {
        rootURL.appending(path: "documents", directoryHint: .isDirectory)
    }

    public nonisolated func folderURL(_ hash: String) -> URL {
        rootURL.appending(path: "documents", directoryHint: .isDirectory)
            .appending(path: hash, directoryHint: .isDirectory)
    }

    nonisolated func storeURL(_ hash: String) -> URL {
        folderURL(hash).appending(path: "store.json")
    }

    nonisolated func snapshotsURL(_ hash: String) -> URL {
        folderURL(hash).appending(
            path: "snapshots", directoryHint: .isDirectory)
    }

    /// Renames a damaged file so it is kept but no longer read. Returns its
    /// new name.
    @discardableResult
    private func setAside(_ url: URL) -> String {
        let name =
            "store.corrupt-\(Timestamp.string(now(), compact: true)).json"
        do {
            try FileManager.default.moveItem(
                at: url,
                to: url.deletingLastPathComponent().appending(path: name))
        } catch {
            log.error(
                """
                Couldn't set aside \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        return name
    }

    private func removeLeftoverTempFiles(_ hash: String) {
        for folder in [folderURL(hash), snapshotsURL(hash)] {
            let names =
                (try? FileManager.default.contentsOfDirectory(
                    atPath: folder.path)) ?? []
            for name in names where name.contains(AtomicFile.tempMarker) {
                try? FileManager.default.removeItem(
                    at: folder.appending(path: name))
            }
        }
    }

    /// Whether anything was ever committed for this PDF, readable or not.
    private func hasAnyData(_ hash: String) -> Bool {
        let names =
            (try? FileManager.default.contentsOfDirectory(
                atPath: folderURL(hash).path)) ?? []
        let snapshotNames =
            (try? FileManager.default.contentsOfDirectory(
                atPath: snapshotsURL(hash).path)) ?? []
        return names.contains { $0.hasPrefix("store") }
            || !snapshotNames.isEmpty
    }

    // MARK: Testing

    /// Runs between writing the temp file and swapping it into place, for
    /// crash simulation.
    func setBeforeStoreReplace(_ hook: (@Sendable () throws -> Void)?) {
        beforeStoreReplace = hook
    }
}

public enum AnnotationStoreError: Error, LocalizedError {
    case savingBlocked(AnnotationStore.BlockReason)
    case nothingToRelink(String)

    public var errorDescription: String? {
        switch self {
        case .savingBlocked(.newerSchema(let version)):
            """
            These annotations were saved by a newer version of mathpdf \
            (schema \(version)), so this version won't overwrite them.
            """
        case .savingBlocked(.noValidData):
            """
            The saved annotations for this PDF can't be read, so saving is \
            paused to avoid overwriting them.
            """
        case .nothingToRelink(let hash):
            "No readable annotations were found for \(hash)."
        }
    }
}
