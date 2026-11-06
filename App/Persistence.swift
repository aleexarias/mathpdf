import AppKit
import MathPDFCore

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
