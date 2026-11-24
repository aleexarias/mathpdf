import AppKit
import MathPDFCore

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

    private var order = EditingOrder<DocumentSession>()
    private var sessions: [DocumentSession] { order.windows }
    /// Saves started by closing windows. Each task keeps its session alive
    /// until it finishes.
    private var closingSaves: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Closed documents whose last save failed, kept so quitting can warn
    /// about them.
    private var failedClosedSessions: [DocumentSession] = []

    func register(_ session: DocumentSession) {
        guard !session.isWindowClosed else { return }
        // Another window on the file changed its pages while this one loaded.
        let hash = session.annotationSet?.documentHash
        if sessions.contains(where: {
            !$0.isStale && $0.annotationSet?.documentHash != hash
                && $0.showsSameFile(as: session)
        }) {
            return session.becomeStale()
        }
        order.add(session)
        assignEditors()
    }

    /// The PDF as shown in a window already open on the file at `url`, for a
    /// new window on it: the file's document keeps the PDF as it was opened,
    /// before any page change.
    func shownData(ofFileAt url: URL) -> Data? {
        sessions.first {
            !$0.isStale && !$0.isWindowClosed
                && $0.currentFileURL?.standardizedFileURL
                    == url.standardizedFileURL
        }?.data
    }

    private func assignEditors() {
        for (session, editor) in order.assignments(
            hash: { $0.annotationSet?.documentHash })
        {
            session.follow(editor)
        }
    }

    /// Whether `session` may write its PDF's annotations: it edits them, or
    /// it's a closed window and no open one shows that PDF.
    func isWriter(_ session: DocumentSession) -> Bool {
        guard let hash = session.annotationSet?.documentHash else {
            return false
        }
        let assignments = order.assignments(
            hash: { $0.annotationSet?.documentHash })
        if let own = assignments.first(where: { $0.window === session }) {
            return own.editor == nil
        }
        return !assignments.contains {
            $0.window.annotationSet?.documentHash == hash
        }
    }

    func annotationsChanged(in editor: DocumentSession) {
        for session in sessions where session.editingSession === editor {
            session.showAnnotations(of: editor)
        }
    }

    /// Whoever just arrived at a PDF has written its annotations, so that's
    /// the window to go on editing them. Other windows on the same file
    /// arrive there too; windows on copies stay where they were.
    func pagesChanged(in changer: DocumentSession, newIndices: [Int?]) {
        for session in sessions
        where session.editingSession === changer
            && session.showsSameFile(as: changer)
        {
            if !session.followPages(of: changer, newIndices: newIndices) {
                order.remove(session)
            }
        }
        order.moveToFront(changer)
        assignEditors()
    }

    func flushSessions(showing hash: String) async {
        for session in sessions
        where session.annotationSet?.documentHash == hash {
            // a window about to follow can't apply what's being written
            session.closeEditor?()
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
            let followers = sessions.filter { $0.editingSession === session }
            closingSaves[id] = nil
            order.remove(session)
            assignEditors()
            guard session.autosaver.hasUnsavedChanges else { return }
            // Only one window may save these annotations: the one now
            // editing them, if any.
            let heir = followers.first { $0.editingSession == nil }
            if heir?.saveForClosedEditor() != true {
                failedClosedSessions.append(session)
            }
        }
    }

    /// Before quitting, so the last save doesn't keep a new formula or text
    /// box that's still being written and would be removed as empty or
    /// invalid.
    func closeEditors() {
        for session in sessions { session.closeEditor?() }
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
