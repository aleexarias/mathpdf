import Foundation

/// Which document a PDF belongs to, and an ID for each of its pages. A page
/// change gives the PDF new bytes, and so a new hash and data folder; the
/// IDs tie those folders together, and say where each page went.
public struct PageIdentity: Codable, Equatable, Sendable {
    public var documentID: UUID
    public var pageIDs: [UUID]

    public init(documentID: UUID = UUID(), pageIDs: [UUID]) {
        self.documentID = documentID
        self.pageIDs = pageIDs
    }

    /// For a PDF seen for the first time.
    public init(pageCount: Int) {
        self.init(pageIDs: (0..<pageCount).map { _ in UUID() })
    }
}
