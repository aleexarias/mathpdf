import AppKit
import MathPDFCore
import MathPDFRendering

/// The one store for the whole app; it serialises all annotation reads and
/// writes. Launching with `-MathPDFDataRoot <folder>` uses another data
/// folder, for testing.
enum Persistence {
    static let store = AnnotationStore(
        rootURL: UserDefaults.standard.string(forKey: "MathPDFDataRoot").map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
            ?? AnnotationStore.defaultRootURL
    )

    static let images = ImageStore(rootURL: store.rootURL)
    static let imageCache = ImageCache(store: images)

    /// Deletes images no annotation or saved version refers to any more, if
    /// that can be told for sure. At launch only: the undo history of a
    /// window can bring a deleted image back.
    static func removeUnusedImages() async {
        guard await images.hasImages,
            let referenced = try? await store.referencedImages()
        else { return }
        await images.removeUnused(keeping: referenced)
    }

    /// The user's own LaTeX commands, for every window.
    @MainActor static let latexCommands = LaTeXCommandLibrary(
        file: LaTeXCommandsFile(rootURL: store.rootURL))

    /// Shows in Finder the folder of `session`'s annotations, or all of them.
    @MainActor static func revealDataFolder(of session: DocumentSession?) {
        let url = session?.dataFolderURL ?? store.rootURL
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
