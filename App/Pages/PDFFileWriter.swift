import Foundation
import MathPDFCore

/// Writes the PDF file itself, which only page changes do.
enum PDFFileWriter {
    enum Failure: LocalizedError {
        case changedElsewhere

        var errorDescription: String? {
            """
            The file was changed by another app since it was opened. Close it \
            and open it again to change its pages.
            """
        }
    }

    /// The window's document, which the coordinator leaves out of the
    /// notifications about the write. The coordinator only compares it with
    /// the presenters it knows, so it's safe to hand to another thread.
    struct Presenter: @unchecked Sendable {
        let presenter: (any NSFilePresenter)?

        init(_ presenter: (any NSFilePresenter)?) {
            self.presenter = presenter
        }
    }

    /// Never write over a change another app made.
    static func checkUnchanged(_ url: URL, hash: String) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard sha256Hex(data) == hash else { throw Failure.changedElsewhere }
    }

    /// Replaces the file in one step. The write is coordinated, so iCloud
    /// Drive and apps watching the file see it as a proper change.
    static func replace(
        _ url: URL, with data: Data, by presenter: Presenter
    ) throws {
        var coordinationError: NSError?
        var writeError: (any Error)?
        NSFileCoordinator(filePresenter: presenter.presenter).coordinate(
            writingItemAt: url, options: .forReplacing,
            error: &coordinationError
        ) { url in
            do { try AtomicFile.write(data, to: url) } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    /// `data`, mapped from a temporary file that's deleted straight away. The
    /// versions of the PDF kept for undo then take disk space rather than
    /// memory, and nothing is left behind.
    static func mappedCopy(of data: Data) -> Data {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "mathpdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil,
            let mapped = try? Data(contentsOf: url, options: .alwaysMapped)
        else { return data }
        return mapped
    }
}
