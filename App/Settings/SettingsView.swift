import SwiftUI

enum SettingsTab: Hashable {
    case latexCommands, colors
}

/// What's in the Settings window, one tab per kind of setting.
struct SettingsView: View {
    @State var tab: SettingsTab
    let library: LaTeXCommandLibrary
    let close: () -> Void

    var body: some View {
        TabView(selection: $tab) {
            LaTeXCommandsEditor(library: library, close: close)
                .tabItem { Text("LaTeX Commands") }
                .tag(SettingsTab.latexCommands)
            ColorSettings(close: close)
                .tabItem { Text("Colours") }
                .tag(SettingsTab.colors)
        }
        .padding(.top, 8)
        .frame(minWidth: 560, minHeight: 440)
    }
}

/// Which colours ⌥⇥ switches between. A tick applies at once, in every
/// window, and is kept between launches.
struct ColorSettings: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colours to switch between with ⌥⇥")
                .font(.headline)
            Text(
                """
                ⌥⇥ gives the highlighter or underliner that's on, or the \
                selected highlight or underline, the next of the colours \
                ticked here. ⌥⇧⇥ goes back.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Palette.entries) { entry in
                    Toggle(isOn: inRotation(entry)) {
                        Label {
                            Text(entry.name)
                        } icon: {
                            Image(nsImage: Palette.swatch(entry.color))
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.top, 4)
            Spacer()
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut("w")
            }
        }
        .padding(16)
    }

    private func inRotation(_ entry: Palette.Entry) -> Binding<Bool> {
        Binding {
            ColorRotation.shared.contains(entry)
        } set: {
            ColorRotation.shared.set(entry, included: $0)
        }
    }
}
