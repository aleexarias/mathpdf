<img src="App/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png"
     width="128" alt="mathpdf icon">

# mathpdf

I couldn't find an app that satisfied me that could incorporate LaTeX
annotations, so I decided I had to vibecode a new one. Additionally, I became
tired of having the Mac Preview app lose all my annotations on papers and
lecture notes, so I made sure this one is robust.

If you have any suggestions on how to improve the app, please open an issue or
pull request.

## Features

- **Highlight and underline** text, in several colours.
- **Notes** attached to the text you select.
- **LaTeX formulas** typeset right on the page. Type `\frac{a}{b}`,
  `\sum_{n=1}^\infty`, `\begin{pmatrix}…\end{pmatrix}` and so on; drag a
  formula to move it.
- **Text boxes**: drag to move one, and drag its right edge to set how wide its
  lines wrap.
- **Search** the document and step through the matches.
- **Version history**: compare any earlier version with the current one side by
  side, and restore it.
- **Export** an annotated copy that Preview, Acrobat and other PDF apps can
  show and edit, or **Quick Export** it to `<name>_annotated.pdf` next to the
  original.

### Your PDFs are never modified

Annotations are stored separately from the PDF, in
`~/Library/Application Support/mathpdf/documents/<fingerprint of the PDF>/`
(File → Reveal Data Folder in Finder). Saving works like this:

- Changes save automatically within 30 seconds, and ⌘S saves right away. The
  title bar shows "Edited" until they're on disk.
- Quitting waits until everything is saved, and every save is written so that a
  crash or power loss can't leave a half-written file.
- Earlier versions are kept as follows: every save for 24 hours, one per hour
  for 7 days, one per day for 30 days. The first version is always kept, plus
  at least 4 others.
- If a PDF is changed by another app, it counts as a new PDF. File → Relink
  Annotations… copies the old annotations onto it.
- If you ever want to modify your PDF with another app, simply export it and it
  will be ready to go.

### LaTeX

Formulas are typeset with [SwiftMath](https://github.com/mgriebling/SwiftMath).
It covers everyday math: fractions, roots, sums, integrals, limits, matrices,
`cases`, `aligned`, Greek letters, accents, `\mathbb`, `\mathcal` and more.
mathpdf adds common commands SwiftMath lacks, such as `\dfrac`,
`\operatorname`, `\xrightarrow`, `align*`, `\not`, `\pmod` and `\tag`.

A formula is checked when you finish it (Esc, ⌘↩ or clicking away). If
something is wrong you're told what it is, for example `Command not supported:
\boxed`. If you finish again without changing anything, a new formula is
removed and an edited one goes back to how it was.

## Keyboard shortcuts

| Action | Keys |
|---|---|
| Highlighter, Underliner | ⌃⌘H, ⌃⌘U |
| Note, LaTeX and Text tools | ⌃⌘N, ⌃⌘L, ⌃⌘T |
| Leave the current tool | Esc |
| Finish editing a note, formula or text box | ⌘↩ or Esc |
| Delete the selected annotation | Delete |
| Undo, Redo | ⌘Z, ⇧⌘Z (also ⌃Z, ⌘Y, ⌃Y) |
| Save now | ⌘S |
| Export…, Quick Export | ⇧⌘E, ⌥⇧⌘E |
| Find, Find Next, Find Previous | ⌘F, ⌘G, ⇧⌘G |
| Zoom In, Zoom Out, Actual Size, Zoom to Fit | ⌘+, ⌘−, ⌘0, ⌘9 |

## Install

mathpdf is built from source. You need:

- macOS 14 Sonoma or later
- [Xcode](https://apps.apple.com/app/xcode/id497799835): the full app, not just
  the Command Line Tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`,
  or a release from its GitHub page

Then:

```sh
git clone https://github.com/aleexarias/mathpdf.git
cd mathpdf
make install
```

This builds a release copy for Apple silicon and Intel Macs and puts it in
`/Applications`. It's signed to run on the Mac that built it; to use mathpdf on
another Mac, build it there.

- **Update:** quit mathpdf, then `git pull` and `make install`. Your
  annotations are kept.
- **Uninstall:** drag mathpdf from Applications to the Trash. This doesn't
  delete your annotations. To remove them too, delete `~/Library/Application
  Support/mathpdf`.

## Development

| Command | What it does |
|---|---|
| `make run` | Builds and opens the development copy |
| `make test` | Runs the unit tests |
| `make lint`, `make format` | Checks or applies `.swift-format` |
| `make icon` | Redraws the app icon from `scripts/AppIcon.swift` |
| `make project` | Generates `mathpdf.xcodeproj`, for working in Xcode |
| `make clean` | Removes build output and the generated project |

The development copy and the installed one share the same annotations, so only
one should be open at a time. `make run` won't start while the installed copy
is open, and `make install` won't replace it while it's running.

### Layout

- `App/`: viewer, annotation tools and editors, version browser, export.
- `Packages/MathPDFCore/Sources/`, in three modules:
  - `MathPDFCore`: annotation model, crash-safe store, autosave, version
    retention, edit rules.
  - `MathPDFLaTeX`: LaTeX typesetting and the compatibility layer.
  - `MathPDFRendering`: drawing annotations as PDF annotations, and export.
- `Packages/MathPDFCore/Tests/`: unit tests, including fixtures for every past
  data format.
- `project.yml`: the Xcode project, as an XcodeGen spec.

## License

mathpdf is released under the [MIT License](LICENSE). It uses
[SwiftMath](https://github.com/mgriebling/SwiftMath), also MIT-licensed.
