import SwiftUI
import UniformTypeIdentifiers

/// The PDF as opened. Documents are opened for viewing: annotations live in
/// the annotation store, and the only writes to the file are page changes,
/// which `DocumentSession` makes itself.
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [] }

    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // never called for a viewing-only DocumentGroup
        throw CocoaError(.featureUnsupported)
    }
}
