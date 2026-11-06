import AppKit

/// The documents open in windows, so their annotations get saved when a window
/// closes, when the app goes to the background, and before it quits.
///
/// Annotations belong to a PDF's bytes, so identical files share them. Two
/// windows writing them would lose each other's work, so one edits, the first
/// opened, and any other shows its annotations as they change, until that
/// window closes or its pages change.
@MainActor
final class OpenDocuments {
    static let shared = OpenDocuments()

    /// In the order they were opened.
    private var sessions: [DocumentSession] = []
    /// Saves started by closing windows. Each task keeps its session alive
    /// until it finishes.
    private var closingSaves: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Closed documents whose last save failed, kept so quitting can warn
    /// about them.
    private var failedClosedSessions: [DocumentSession] = []

    func register(_ session: DocumentSession) {
        guard !session.isWindowClosed else { return }
        sessions.append(session)
        assignEditors()
    }

    private func assignEditors() {
        var editors: [String: DocumentSession] = [:]
        for session in sessions {
            guard let hash = session.annotationSet?.documentHash else {
                continue
            }
            session.follow(editors[hash])
            editors[hash] = editors[hash] ?? session
        }
    }

    func annotationsChanged(in editor: DocumentSession) {
        for session in sessions where session.editingSession === editor {
            session.showAnnotations(of: editor)
        }
    }

    /// Whoever just arrived at a PDF has written its annotations, so that's
    /// the window to go on editing them.
    func pagesChanged(in session: DocumentSession) {
        sessions.removeAll { $0 === session }
        sessions.insert(session, at: 0)
        assignEditors()
    }

    func flushSessions(showing hash: String) async {
        for session in sessions
        where session.annotationSet?.documentHash == hash {
            await session.flush()
        }
    }

    func checkFiles() {
        for session in sessions {
            Task { await session.checkFile() }
        }
    }

    var isChangingPages: Bool {
        sessions.contains(where: \.isChangingPages)
    }

    /// An open document, for pages dragged from its window.
    func session(_ id: UUID) -> DocumentSession? {
        sessions.first { $0.id == id }
    }

    func windowClosed(_ session: DocumentSession) {
        session.isWindowClosed = true
        let id = ObjectIdentifier(session)
        closingSaves[id] = Task {
            await session.finishPageChanges()
            await session.finishExports()
            await session.flush()
            if session.autosaver.hasUnsavedChanges {
                failedClosedSessions.append(session)
            }
            closingSaves[id] = nil
            sessions.removeAll { $0 === session }
            assignEditors()
        }
    }

    func flushAllInBackground() {
        for session in sessions {
            Task { await session.flush() }
        }
    }

    func flushAll() async {
        for session in sessions + failedClosedSessions {
            await session.finishPageChanges()
            await session.finishExports()
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
        let unsaved = (sessions + failedClosedSessions).filter {
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
