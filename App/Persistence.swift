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
}

/// Tracks open documents so their annotations get saved when a window closes,
/// when the app goes to the background, and before it quits.
@MainActor
final class SaveCoordinator {
    static let shared = SaveCoordinator()

    private let sessions = NSHashTable<DocumentSession>.weakObjects()
    /// Saves started by closing windows. Each task keeps its session alive
    /// until it finishes.
    private var closingSaves: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Closed documents whose last save failed, kept so quitting can warn
    /// about them.
    private var failedClosedSessions: [DocumentSession] = []

    func register(_ session: DocumentSession) {
        sessions.add(session)
    }

    func windowClosed(_ session: DocumentSession) {
        let id = ObjectIdentifier(session)
        closingSaves[id] = Task {
            await session.flush()
            if session.autosaver.hasUnsavedChanges {
                failedClosedSessions.append(session)
            }
            closingSaves[id] = nil
        }
    }

    func flushAllInBackground() {
        for session in sessions.allObjects {
            Task { await session.flush() }
        }
    }

    func flushAll() async {
        for session in sessions.allObjects + failedClosedSessions {
            await session.flush()
        }
        for task in closingSaves.values {
            await task.value
        }
        failedClosedSessions.removeAll { !$0.autosaver.hasUnsavedChanges }
    }

    /// Returns whether to go ahead and quit.
    func confirmQuitIfAnythingUnsaved() -> Bool {
        var seen = Set<ObjectIdentifier>()
        let unsaved = (sessions.allObjects + failedClosedSessions).filter {
            seen.insert(ObjectIdentifier($0)).inserted
                && $0.autosaver.hasUnsavedChanges
        }
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Some annotations couldn't be saved"
        let names = unsaved.map(\.fileName).sorted().joined(separator: ", ")
        let reason =
            unsaved.compactMap { $0.autosaver.lastError?.localizedDescription }
            .first ?? ""
        alert.informativeText =
            """
            Recent changes to \(names) aren't on disk. \(reason)\n\nIf you \
            quit now, those changes will be lost.
            """
        alert.addButton(withTitle: "Don't Quit")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

enum DataFolder {
    static func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
