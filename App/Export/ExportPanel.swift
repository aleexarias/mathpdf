import AppKit
import MathPDFRendering
import UniformTypeIdentifiers

/// File ▸ Export…: asks where to save the copy with annotations. It suggests
/// `<name>_annotated.pdf` next to the original, and won't accept the original
/// itself.
@MainActor
enum ExportPanel {
    static func run(for session: DocumentSession, in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "Export with Annotations"
        panel.message =
            """
            Saves a copy of the PDF with your annotations, which other apps \
            can show and edit. The original is never changed.
            """
        panel.prompt = "Export"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let suggested = session.quickExportURL {
            panel.directoryURL = suggested.deletingLastPathComponent()
            panel.nameFieldStringValue = suggested.lastPathComponent
        } else {
            panel.nameFieldStringValue =
                (session.fileName as NSString).deletingPathExtension
                + "_annotated.pdf"
        }
        let guardian = OriginalGuard(original: session.fileURL)
        panel.delegate = guardian
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = {
            response in
            // the panel only holds its delegate weakly
            withExtendedLifetime(guardian) {}
            guard response == .OK, let url = panel.url else { return }
            Task { await session.export(to: url) }
        }
        if let window {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(panel.runModal())
        }
    }
}

/// Turns down the original PDF as the destination, in the panel itself, saying
/// why.
@MainActor
private final class OriginalGuard: NSObject, NSOpenSavePanelDelegate {
    let original: URL?

    init(original: URL?) {
        self.original = original
    }

    func panel(_ sender: Any, validate url: URL) throws {
        if let original, PDFExporter.isSameFile(url, original) {
            throw PDFExporter.Failure.wouldReplaceOriginal
        }
    }
}
