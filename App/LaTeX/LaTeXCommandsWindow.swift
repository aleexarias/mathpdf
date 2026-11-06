import AppKit
import SwiftUI

/// The window for the user's own LaTeX commands. The rest of the app waits
/// until it's closed. What's in it is only saved when the user says so, so
/// closing it asks first, however it's closed.
@MainActor
final class LaTeXCommandsWindow: NSObject, NSWindowDelegate {
    static let shared = LaTeXCommandsWindow()

    private var window: NSWindow?

    /// Returns once the window is closed.
    func show() {
        guard window == nil else { return }
        let editor = LaTeXCommandsEditor(library: Persistence.latexCommands) {
            [weak self] in self?.window?.performClose(nil)
        }
        let host = NSHostingController(rootView: editor)
        // any size above the editor's minimum
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "LaTeX Commands"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 560, height: 440))
        window.center()
        self.window = window
        NSApp.runModal(for: window)
    }

    /// Returns whether what's in the window can be left behind, asking about
    /// any unsaved changes. If they can't be saved, the window stays to say
    /// why.
    func confirmClosing() -> Bool {
        guard window != nil, Persistence.latexCommands.hasUnsavedChanges else {
            return true
        }
        let library = Persistence.latexCommands
        let alert = NSAlert()
        alert.messageText = "Save your changes to the LaTeX commands?"
        alert.informativeText = "If you don't, they'll be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            library.save()
            return !library.hasUnsavedChanges
        case .alertSecondButtonReturn:
            library.discardChanges()
            return true
        default:
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClosing()
    }

    /// A PDF opened from Finder while this is up appears behind it, but takes
    /// the keyboard, which would leave this window's shortcuts dead.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, NSApp.modalWindow === window,
                NSApp.isActive, !window.isKeyWindow
            else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.stopModal()
        // the modal loop only notices when it next gets an event
        if let wake = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0,
            data2: 0)
        {
            NSApp.postEvent(wake, atStart: false)
        }
    }
}
