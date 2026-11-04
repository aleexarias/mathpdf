import AppKit
import SwiftUI

/// Hosts a note or LaTeX editor in a popover with its own undo history.
/// Otherwise the text view's typing steps land in the window's history and
/// outlive the text view: ⌘Z after the editor closed would then undo typing in
/// a text view that no longer exists, and crash. Undo and Redo reach this view
/// (it's in the responder chain before the window) while the editor is open,
/// so they undo typing there.
final class EditorPopoverHost<Content: View>: NSHostingView<Content>,
    NSMenuItemValidation
{
    private let typingUndoManager = UndoManager()
    /// Shows this view in the popover; it's resized to follow the content,
    /// e.g. when an error message appears.
    private weak var owner: NSViewController?

    override var undoManager: UndoManager? { typingUndoManager }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        Task { @MainActor [weak self] in
            guard let self, let owner,
                owner.preferredContentSize != intrinsicContentSize
            else { return }
            owner.preferredContentSize = intrinsicContentSize
        }
    }

    @objc func undo(_ sender: Any?) { typingUndoManager.undo() }
    @objc func redo(_ sender: Any?) { typingUndoManager.redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:))?:
            menuItem.title = typingUndoManager.undoMenuItemTitle
            return typingUndoManager.canUndo
        case #selector(redo(_:))?:
            menuItem.title = typingUndoManager.redoMenuItemTitle
            return typingUndoManager.canRedo
        default:
            return true
        }
    }

    static func controller(for content: Content) -> NSViewController {
        let host = EditorPopoverHost(rootView: content)
        let controller = NSViewController()
        controller.view = host
        host.owner = controller
        controller.preferredContentSize = host.fittingSize
        return controller
    }
}
