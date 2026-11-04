import SwiftUI

extension FocusedValues {
    @Entry var viewer: Viewer?
    @Entry var session: DocumentSession?
}

struct AppCommands: Commands {
    @FocusedValue(\.viewer) private var viewer
    @FocusedValue(\.session) private var session

    private var canEdit: Bool { viewer != nil && session?.canEdit == true }

    private func brush(_ tool: AnnotationEditor.Tool) -> Binding<Bool> {
        Binding {
            viewer?.editor.tool == tool
        } set: { _ in
            viewer?.editor.toggleTool(tool)
        }
    }

    var body: some Commands {
        // Replaces Save As, Duplicate, Rename and Revert. Annotations are
        // saved in their own store, and page changes are written as they're
        // made.
        CommandGroup(replacing: .saveItem) {
            Button("Save") { Task { await session?.flush() } }
                .keyboardShortcut("s")
                .disabled(session == nil)
            Button("Browse All Versions…") { viewer?.showVersions() }
                .disabled(!canEdit)
            Divider()
            Button("Export…") { viewer?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!canEdit)
            Button(
                session?.quickExportURL.map {
                    "Quick Export to “\($0.lastPathComponent)”"
                } ?? "Quick Export"
            ) { viewer?.quickExport() }
            .keyboardShortcut("e", modifiers: [.command, .option, .shift])
            .disabled(!canEdit || session?.quickExportURL == nil)
            Divider()
            Button("Relink Annotations…") {
                session?.isShowingRelinkSheet = true
            }
            .disabled(session?.canRelink != true)
            Button("Reveal Data Folder in Finder") {
                DataFolder.reveal(
                    session?.dataFolderURL ?? Persistence.store.rootURL)
            }
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find…") { viewer?.focusSearchField() }
                .keyboardShortcut("f")
            Button("Find Next") { viewer?.nextMatch() }
                .keyboardShortcut("g")
            Button("Find Previous") { viewer?.previousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandMenu("Annotate") {
            Group {
                Toggle("Highlighter", isOn: brush(.highlight))
                    .keyboardShortcut("h", modifiers: [.control, .command])
                Toggle("Underliner", isOn: brush(.underline))
                    .keyboardShortcut("u", modifiers: [.control, .command])
                Toggle("Note Tool", isOn: brush(.note))
                    .keyboardShortcut("n", modifiers: [.control, .command])
                Toggle("LaTeX Tool", isOn: brush(.latex))
                    .keyboardShortcut("l", modifiers: [.control, .command])
                Toggle("Text Tool", isOn: brush(.text))
                    .keyboardShortcut("t", modifiers: [.control, .command])
            }
            .disabled(!canEdit)
            Divider()
            Button("Delete Annotation") { viewer?.editor.deleteSelection() }
                .disabled(!canEdit || session?.selection == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Actual Size") { viewer?.actualSize() }
                .keyboardShortcut("0")
            Button("Zoom In") { viewer?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { viewer?.zoomOut() }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { viewer?.zoomToFit() }
                .keyboardShortcut("9")
            Divider()
        }
    }
}
