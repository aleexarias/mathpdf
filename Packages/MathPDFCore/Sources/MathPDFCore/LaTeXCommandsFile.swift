import Foundation

/// The user's own LaTeX commands on disk: `latex-commands.tex` in the data
/// folder, as plain text, so it can be read, backed up or edited anywhere.
public struct LaTeXCommandsFile: Sendable {
    public let url: URL

    public init(rootURL: URL) {
        url = rootURL.appending(path: "latex-commands.tex")
    }

    /// Empty if there's no file yet. Throws if there is one that can't be
    /// read, which must then not be overwritten.
    public func read() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try AtomicFile.write(Data(text.utf8), to: url)
    }
}
