import SwiftUI
import UniformTypeIdentifiers

/// The PDF as opened. Documents are opened for viewing only: the app never
/// writes to the original file. Annotations live in the annotation store
/// instead.
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
