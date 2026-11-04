import Foundation

/// Page orders: the PDFs a document has had between page changes, the IDs
/// that tie their folders together, and the copies of the PDF kept for them.
extension AnnotationStore {
    /// How much room the copies of a document's PDF, kept for its earlier
    /// page orders, may take.
    public struct CopyLimits: Sendable {
        /// Copies of a PDF bigger than this thin out on the large schedule.
        public var largeSize: Int
        /// All copies of one document's PDF together stay within this.
        public var totalSize: Int

        public init(largeSize: Int, totalSize: Int) {
            self.largeSize = largeSize
            self.totalSize = totalSize
        }

        public static let standard = CopyLimits(
            largeSize: 100_000_000, totalSize: 500_000_000)
    }

    /// One page order of a document: the PDF between two page changes.
    public struct PageOrder: Sendable {
        public let documentHash: String
        public let identity: PageIdentity
        /// The PDF with these pages. Nil if no page change has left them yet,
        /// or if the copy was thinned out.
        public let pdfURL: URL?
        /// When a page change last left these pages.
        public let leftAt: Date?
    }

    private struct PagesFile: Codable {
        var version = 1
        var identity: PageIdentity
    }

    public func pageIdentity(documentHash hash: String) -> PageIdentity? {
        guard let data = try? Data(contentsOf: pagesURL(hash)),
            let file = try? JSONDecoder().decode(PagesFile.self, from: data),
            file.version == 1
        else { return nil }
        return file.identity
    }

    public func savePageIdentity(
        _ identity: PageIdentity, documentHash hash: String
    ) throws {
        let previous = pageIdentity(documentHash: hash)?.documentID
        try FileManager.default.createDirectory(
            at: folderURL(hash), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(
            encoder.encode(PagesFile(identity: identity)), to: pagesURL(hash))
        if let previous { foldersByDocument?[previous]?.remove(hash) }
        foldersByDocument?[identity.documentID, default: []].insert(hash)
    }

    /// Before a page change: keeps the PDF with the pages it leaves, their
    /// IDs, and `set`, their annotations, if nothing was saved for them yet.
    /// So every page order has a version, and the document's first version
    /// is in its first page order, which then is never deleted. Returns
    /// `set` as saved; the next order's set must have a higher revision, so
    /// this version stays the older even if both are saved in the same
    /// millisecond.
    @discardableResult
    public func leavePages(
        _ set: AnnotationSet, identity: PageIdentity, pdf: Data
    ) throws -> AnnotationSet {
        let hash = set.documentHash
        if pageIdentity(documentHash: hash) != identity {
            try savePageIdentity(identity, documentHash: hash)
        }
        var set = set
        if newestSet(documentHash: hash) == nil {
            set = try saveAfterPageChange(set)
        }
        let url = keptPDFURL(hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try AtomicFile.write(pdf, to: url)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: now()], ofItemAtPath: url.path)
        return set
    }

    /// Every page order of a document whose IDs are stored, the most
    /// recently left first.
    public func pageOrders(of documentID: UUID) -> [PageOrder] {
        folders(of: documentID).compactMap { hash -> PageOrder? in
            guard let identity = pageIdentity(documentHash: hash),
                identity.documentID == documentID
            else { return nil }
            let url = keptPDFURL(hash)
            let leftAt =
                try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return PageOrder(
                documentHash: hash, identity: identity,
                pdfURL: leftAt == nil ? nil : url, leftAt: leftAt)
        }
        .sorted {
            ($0.leftAt ?? .distantFuture) > ($1.leftAt ?? .distantFuture)
        }
    }

    func folders(of documentID: UUID) -> Set<String> {
        if foldersByDocument == nil {
            var index: [UUID: Set<String>] = [:]
            let names =
                (try? FileManager.default.contentsOfDirectory(
                    atPath: documentsURL.path)) ?? []
            for hash in names {
                if let id = pageIdentity(documentHash: hash)?.documentID {
                    index[id, default: []].insert(hash)
                }
            }
            foldersByDocument = index
        }
        return foldersByDocument?[documentID] ?? []
    }

    /// The copies of the PDF kept for a document's page orders. A big PDF's
    /// thin out on the large schedule, and together they stay within the
    /// limit: the current order's copy goes first (it's the PDF itself), then
    /// the oldest, and the first order's only if it alone is too big.
    func pruneCopies(
        of documentID: UUID, current: String, first: String?
    ) {
        struct Copy {
            let hash: String
            let url: URL
            let date: Date
            let size: Int
        }
        var copies = pageOrders(of: documentID).compactMap {
            order -> Copy? in
            guard let url = order.pdfURL, let date = order.leftAt,
                let size = try? url.resourceValues(forKeys: [.fileSizeKey])
                    .fileSize
            else { return nil }
            return Copy(
                hash: order.documentHash, url: url, date: date, size: size)
        }
        if copies.contains(where: { $0.size > limits.largeSize }) {
            let thinned = copies.filter { $0.hash != first }.map {
                SnapshotInfo(url: $0.url, date: $0.date, revision: 0)
            }
            let doomed = Set(
                RetentionPolicy.snapshotsToDelete(
                    thinned, now: now(), schedule: .large, keepingFirst: false
                ).map(\.url))
            var kept: [Copy] = []
            for copy in copies {
                if doomed.contains(copy.url), remove(copy.url) { continue }
                kept.append(copy)
            }
            copies = kept
        }
        func rank(_ copy: Copy) -> Int {
            copy.hash == current ? 0 : copy.hash == first ? 2 : 1
        }
        var total = copies.map(\.size).reduce(0, +)
        for copy in copies.sorted(by: {
            (rank($0), $0.date) < (rank($1), $1.date)
        })
        where total > limits.totalSize {
            if remove(copy.url) { total -= copy.size }
        }
    }

    nonisolated func pagesURL(_ hash: String) -> URL {
        folderURL(hash).appending(path: "pages.json")
    }

    nonisolated func keptPDFURL(_ hash: String) -> URL {
        folderURL(hash).appending(path: "document.pdf")
    }
}
