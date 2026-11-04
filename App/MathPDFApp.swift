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
    /// annotation changes.
    private func addUndoShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([
                .command, .control, .option, .shift,
            ])
            let action: String? =
                switch (
                    event.charactersIgnoringModifiers?.lowercased(), modifiers
                ) {
                case ("z", .control): "undo:"
                case ("y", .control), ("y", .command): "redo:"
                default: nil
                }
            guard let action else { return event }
            MainActor.assumeIsolated {
                _ = NSApp.sendAction(Selector(action), to: nil, from: nil)
            }
            return nil
        }
    }

    /// Quitting waits until every document's annotations are on disk.
    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply
    {
        Task {
            await SaveCoordinator.shared.flushAll()
            NSApp.reply(
                toApplicationShouldTerminate: SaveCoordinator.shared
                    .confirmQuitIfAnythingUnsaved())
        }
        return .terminateLater
    }

    func applicationDidResignActive(_ notification: Notification) {
        SaveCoordinator.shared.flushAllInBackground()
    }

    func applicationDidHide(_ notification: Notification) {
        SaveCoordinator.shared.flushAllInBackground()
    }
}
