import PDFKit
import SwiftUI

/// The content of one document window. The session is created once, when the
/// window appears, so SwiftUI re-creating this view never re-creates (or
/// re-loads) the document.
struct DocumentWindow: View {
    let file: PDFFile
    let fileURL: URL?
    @State private var session: DocumentSession?
    @State private var viewer: Viewer?

    var body: some View {
        Group {
            if let session, let viewer {
                DocumentView(session: session, viewer: viewer)
            } else if case .failed(let message)? = session?.phase {
                ContentUnavailableView(
                    "Can't Open PDF", systemImage: "doc.questionmark",
                    description: Text(message))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            guard session == nil else { return }
            let session = DocumentSession(data: file.data, fileURL: fileURL)
            self.session = session
            if let pdf = session.pdf {
                viewer = Viewer(document: pdf, session: session)
            }
            await session.load()
            // detach the read-only document's undo manager early
            _ = viewer?.editor.windowUndoManager()
            await viewer?.keepSearchFieldVisible()
        }
        .onDisappear {
            viewer?.editor.closeEditor()
            viewer?.closeVersions()
            if let session { OpenDocuments.shared.windowClosed(session) }
        }
    }
}

private struct DocumentView: View {
    let session: DocumentSession
    let viewer: Viewer
    @State private var sidebar = SidebarContent.pages
    @State private var isHintVisible = false

    private enum SidebarContent: String, CaseIterable {
        case pages = "Pages"
        case annotations = "Annotations"
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Sidebar", selection: $sidebar) {
                    ForEach(SidebarContent.allCases, id: \.self) {
                        Text($0.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                switch sidebar {
                case .pages: PageSidebarView(sidebar: viewer.sidebar)
                case .annotations:
                    AnnotationList(session: session, editor: viewer.editor)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 320)
        } detail: {
            // The page reaches under the translucent toolbar and sidebar: it
            // starts clear of them and can be scrolled underneath.
            PDFKitView(pdfView: viewer.pdfView)
                .ignoresSafeArea()
                .safeAreaInset(edge: .top, spacing: 0) {
                    NoticeBar(session: session)
                }
                // Floating over the page rather than in the toolbar: a toolbar
                // that grows during a search pushes the search field into the
                // overflow menu.
                .overlay(alignment: .topTrailing) {
                    SearchResultsBar(viewer: viewer)
                }
                .overlay(alignment: .bottom) {
                    if isHintVisible, let tool = viewer.editor.tool {
                        Text(
                            """
                            \(tool.name) mode selected. Press ESC to exit \
                            mode.
                            """
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(16)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .task(id: viewer.editor.tool) {
                    guard viewer.editor.tool != nil else {
                        return isHintVisible = false
                    }
                    withAnimation(.easeIn(duration: 0.2)) {
                        isHintVisible = true
                    }
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.6)) {
                        isHintVisible = false
                    }
                }
        }
        .toolbar { toolbar }
        .navigationSubtitle(subtitle)
        .onChange(of: session.saveStatus) {
            viewer.pdfView.window?.isDocumentEdited =
                session.saveStatus != .saved
        }
        .focusedSceneValue(\.viewer, viewer)
        .focusedSceneValue(\.session, session)
        .sheet(isPresented: Bindable(session).isShowingRelinkSheet) {
            RelinkSheet(session: session)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            for url in pdfs {
                NSDocumentController.shared.openDocument(
                    withContentsOf: url, display: true
                ) { _, _, _ in }
            }
            return !pdfs.isEmpty
        }
    }

    private var subtitle: String {
        switch session.saveStatus {
        case .saved: ""
        case .edited: "Edited"
        case .failed: "Not Saved"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text("Page \(viewer.pageIndex + 1) of \(viewer.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, 8)
        }
        ToolbarItemGroup {
            AnnotationTools(session: session, editor: viewer.editor)
        }
        ToolbarItem {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                    viewer.zoomOut()
                }
                .help("Zoom Out")
                Button(
                    "Zoom to Fit",
                    systemImage: "arrow.up.left.and.arrow.down.right"
                ) { viewer.zoomToFit() }
                .help("Zoom to Fit")
                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                    viewer.zoomIn()
                }
                .help("Zoom In")
            }
        }
        ToolbarItem {
            SearchField(viewer: viewer)
                .frame(width: 160)
        }
    }
}
