import AppKit
import SwiftUI

/// The version browser's window: a window rather than a sheet, so it can be
/// moved and resized. One per document; asking again brings it to the front.
@MainActor
final class VersionsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(session: DocumentSession, startPage: Int, over parent: NSWindow?)
    {
        if let window { return window.makeKeyAndOrderFront(nil) }
        let browser = VersionBrowser(session: session, startPage: startPage) {
            [weak self] in self?.close()
        }
        let host = NSHostingController(rootView: browser)
        // any size above the browser's minimum
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Versions of “\(session.fileName)”"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1150, height: 760))
        if let parent {
            // Near the top of the document window, horizontally centred on it.
            let frame = parent.frame
            window.setFrameTopLeftPoint(
                NSPoint(
                    x: frame.midX - window.frame.width / 2, y: frame.maxY - 40)
            )
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
