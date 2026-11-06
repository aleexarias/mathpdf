import AppKit
import MathPDFCore
import MathPDFLaTeX
import Observation

/// The user's own LaTeX commands, for the whole app: the definitions as
/// they're being written, and what the saved file defines, which is all that
/// formulas use. Nothing is checked or written while typing, only on saving,
/// and nothing with errors in it is saved.
@MainActor @Observable
final class LaTeXCommandLibrary {
    /// What's in the editor.
    var text = "" {
        didSet { if text == saved { refused = nil } }
    }
    /// What's on disk.
    private(set) var saved = ""
    private(set) var current = LaTeXCommands()
    /// Why the file can't be read. It's then left alone, and isn't offered for
    /// editing.
    private(set) var readError: String?
    private(set) var saveError: String?
    /// What stopped the text in the editor from being saved.
    private var refused: [LaTeXCommands.Issue]?
    /// What's wrong with the file as it is, which can only come from an edit
    /// made elsewhere.
    private var savedIssues: [LaTeXCommands.Issue] = []
    @ObservationIgnored private var checked: String?

    @ObservationIgnored private let file: LaTeXCommandsFile

    init(file: LaTeXCommandsFile) {
        self.file = file
        reload()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var hasUnsavedChanges: Bool { text != saved }

    var issues: [LaTeXCommands.Issue] { refused ?? savedIssues }

    /// Picks up edits made to the file elsewhere, unless there are unsaved
    /// ones here. Done whenever the app comes back to the front.
    func reload() {
        guard !hasUnsavedChanges else { return }
        do {
            let contents = try file.read()
            readError = nil
            guard contents != saved else { return }
            text = contents
            saved = contents
            current = LaTeXCommands(definitions: contents)
        } catch {
            readError = error.localizedDescription
        }
    }

    /// Writes what's in the editor, unless something in it is wrong. Then
    /// nothing changes until that's resolved, and `issues` says what it is.
    func save() {
        guard hasUnsavedChanges, readError == nil else { return }
        let commands = LaTeXCommands(definitions: text)
        let problems = Self.issues(in: commands)
        saveError = nil
        refused = problems.isEmpty ? nil : problems
        guard problems.isEmpty else { return }
        do {
            try file.write(text)
            saved = text
            current = commands
            savedIssues = []
            checked = text
        } catch {
            saveError = error.localizedDescription
        }
    }

    func discardChanges() {
        text = saved
        saveError = nil
    }

    /// Tries out each saved command, which typesets it, unless this text has
    /// been checked already.
    func checkSaved() {
        guard checked != saved else { return }
        checked = saved
        savedIssues = Self.issues(in: current)
    }

    private static func issues(in commands: LaTeXCommands)
        -> [LaTeXCommands.Issue]
    {
        Set(commands.issues + commands.typesetIssues()).sorted {
            ($0.line, $0.message) < ($1.line, $1.message)
        }
    }
}
