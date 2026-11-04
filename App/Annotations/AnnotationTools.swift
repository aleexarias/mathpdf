import MathPDFCore
import SwiftUI

struct AnnotationTools: View {
    let session: DocumentSession
    let editor: AnnotationEditor

    var body: some View {
        ControlGroup {
            Toggle(isOn: brush(.highlight)) {
                Label("Highlight", systemImage: "highlighter")
            }
            .help(
                """
                Highlight the selected text. With nothing selected, turns \
                the highlighter on: any text you then select is highlighted \
                (⌃⌘H)
                """
            )
            Toggle(isOn: brush(.underline)) {
                Label("Underline", systemImage: "underline")
            }
            .help(
                """
                Underline the selected text. With nothing selected, turns \
                the underliner on: any text you then select is underlined (⌃⌘U)
                """
            )
            Toggle(isOn: brush(.note)) {
                Label("Note", systemImage: "text.bubble")
            }
            .help(
                """
                Attach a note to the selected text. With nothing selected, \
                turns the note tool on: select text or click a word to \
                attach a note (⌃⌘N)
                """
            )
            Toggle(isOn: brush(.latex)) {
                Label("LaTeX", systemImage: "function")
            }
            .help(
                """
                LaTeX tool: while on, click on the page to place a formula. \
                Double-click a formula to edit it (⌃⌘L)
                """
            )
            Toggle(isOn: brush(.text)) {
                Label("Text", systemImage: "character.textbox")
            }
            .help(
                """
                Text tool: while on, click on the page to place a text box. \
                Double-click a text box to edit it, or drag its right edge \
                to set its width (⌃⌘T)
                """
            )
        }
        .toggleStyle(.button)
        .disabled(!session.canEdit)

        Menu {
            Picker("Colour", selection: colour) {
                ForEach(Palette.entries) { entry in
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(nsImage: Palette.swatch(entry.color))
                    }
                    .tag(entry.color)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text("Colour")
            } icon: {
                Image(
                    nsImage: Palette.swatch(
                        editor.currentColor ?? Palette.yellow))
            }
        }
        .disabled(!session.canEdit || editor.currentColor == nil)
        .help(
            """
            Colour of the selected highlight or underline, or of the \
            highlighter or underliner that's on
            """
        )

        Button("Delete", systemImage: "trash") { editor.deleteSelection() }
            .disabled(!session.canEdit || session.selection == nil)
            .help("Delete the selected annotation (⌫)")
    }

    private func brush(_ tool: AnnotationEditor.Tool) -> Binding<Bool> {
        Binding {
            editor.tool == tool
        } set: { _ in
            editor.toggleTool(tool)
        }
    }

    private var colour: Binding<RGBAColor> {
        Binding {
            editor.currentColor ?? Palette.yellow
        } set: {
            editor.chooseColor($0)
        }
    }
}
