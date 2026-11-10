import SwiftUI

@main
struct MathPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(viewing: PDFFile.self) { file in
            DocumentWindow(file: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1180, height: 850)
        .commands {
            AppCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        addUndoShortcuts()
    }

    /// Besides the standard ⌘Z and ⇧⌘Z: ⌃Z undoes, and ⌘Y or ⌃Y redoes. They
    /// go through the same responder chain as Edit > Undo and Redo, so typing
    /// in a text field undoes the typing, and anywhere else it undoes
    /// annotation and page changes. While a page change is being written,
    /// they all do nothing: the step under it can't be undone until it's
    /// done.
    private func addUndoShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([
                .command, .control, .option, .shift,
            ])
            let key = event.charactersIgnoringModifiers?.lowercased()
            let action: String? =
                switch (key, modifiers) {
                case ("z", .control), ("z", .command): "undo:"
                case ("y", .control), ("y", .command),
                    ("z", [.command, .shift]):
                    "redo:"
                default: nil
                }
            guard let action else { return event }
            let handled = MainActor.assumeIsolated {
                if OpenDocuments.shared.isChangingPages { return true }
                // the menu handles its own shortcuts
                if key == "z", modifiers.contains(.command) { return false }
                _ = NSApp.sendAction(Selector(action), to: nil, from: nil)
                return true
            }
            return handled ? nil : event
        }
    }

    /// Quitting asks about unsaved LaTeX commands, then waits until exports
    /// are done and every document's annotations are on disk.
    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply
    {
        guard SettingsWindow.shared.confirmClosing() else {
            return .terminateCancel
        }
        Task {
            await OpenDocuments.shared.flushAll()
            NSApp.reply(
                toApplicationShouldTerminate: OpenDocuments.shared
                    .confirmQuitIfAnythingUnsaved())
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        OpenDocuments.shared.checkFiles()
    }

    func applicationDidResignActive(_ notification: Notification) {
        OpenDocuments.shared.flushAllInBackground()
    }

    func applicationDidHide(_ notification: Notification) {
        OpenDocuments.shared.flushAllInBackground()
    }
}
