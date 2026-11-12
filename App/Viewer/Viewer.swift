import MathPDFCore
import Observation
import PDFKit

/// Owns the PDFView for one window: page tracking, zoom, search, page
/// changes, and the annotation editor.
@MainActor @Observable
final class Viewer: NSObject {
    @ObservationIgnored let pdfView: AnnotationPDFView
    @ObservationIgnored let editor: AnnotationEditor
    @ObservationIgnored let session: DocumentSession
    @ObservationIgnored lazy var sidebar = PageSidebar(viewer: self)
    private(set) var pageCount: Int
    private(set) var pageIndex = 0

    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex: Int?
    /// The text of the last search, so the toolbar can say "No matches".
    private(set) var searchedText = ""
    /// The toolbar's search field, so Edit > Find can focus it.
    @ObservationIgnored weak var searchField: NSSearchField?
    @ObservationIgnored private var zoomAnimation: Task<Void, Never>?
    @ObservationIgnored private var searchItemObservation:
        NSKeyValueObservation?
    @ObservationIgnored private let versionsWindow = VersionsWindow()

    init(document: PDFDocument, session: DocumentSession) {
        pageCount = document.pageCount
        self.session = session
        pdfView = AnnotationPDFView()
        // before the editor, which draws the annotations onto its pages
        pdfView.document = document
        editor = AnnotationEditor(session: session, pdfView: pdfView)
        super.init()
        // Since macOS 14 views don't clip by default, and PDFView would
        // otherwise paint over the sidebar and the banners around it.
        pdfView.clipsToBounds = true
        pdfView.backgroundColor = Self.pageBackground
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        // the view fits the pages itself (see `fit`)
        pdfView.autoScales = false
        // Selector-based, so it's removed automatically when the viewer goes
        // away.
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged,
            object: pdfView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentUnlocked),
            name: .PDFDocumentDidUnlock, object: document)
        pdfView.viewer = self
        session.onPagesChanged = { [weak self] in
            self?.showChangedPages(newIndices: $0)
        }
        session.fileDocumentProvider = { [weak self] in
            self?.pdfView.window.flatMap(
                NSDocumentController.shared.document(for:))
        }
        editor.onPagesRedrawn = { [weak self] in
            self?.sidebar.pagesRedrawn($0)
        }
        sidebar.reload()
    }

    /// Around the pages: a mid grey in dark mode, lighter than PDFView's
    /// near-black default.
    static let pageBackground = NSColor(name: "PageBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.27, alpha: 1) : NSColor(white: 0.86, alpha: 1)
    }

    @objc private func documentUnlocked() {
        session.readProtection()
        editor.redrawAnnotations()
        sidebar.reload()
    }

    @objc private func pageChanged() {
        guard let page = pdfView.currentPage, let document = pdfView.document
        else { return }
        pageIndex = document.index(for: page)
        sidebar.showCurrentPage()
    }

    func go(toPage index: Int) {
        guard (0..<pageCount).contains(index),
            let page = pdfView.document?.page(at: index)
        else { return }
        pdfView.go(to: page)
    }

    func turnPage(by offset: Int) {
        go(toPage: pageIndex + offset)
    }

    // MARK: Versions

    func showVersions() {
        versionsWindow.show(
            session: session, startPage: pageIndex, over: pdfView.window)
    }

    func closeVersions() {
        versionsWindow.close()
    }

    // MARK: Pages

    /// Shows the document after a page change where the old one was, or at
    /// the page that took a deleted page's place.
    private func showChangedPages(newIndices: [Int?]) {
        guard let document = session.pdf else { return }
        let anchor = pdfView.zoomAnchor()
        let oldIndex = anchor.flatMap { pdfView.document?.index(for: $0.page) }
        let scale = pdfView.scaleFactor
        zoomAnimation?.cancel()
        clearSearch()
        closeVersions()
        editor.documentReplaced()
        pdfView.document = document
        pageCount = document.pageCount
        if pdfView.fit == nil { pdfView.scaleFactor = scale }
        pdfView.layoutDocumentView()
        pdfView.updateGeometry()
        if let anchor, let oldIndex {
            let newIndex =
                newIndices.indices.contains(oldIndex)
                ? newIndices[oldIndex] : nil
            if let newIndex, let page = document.page(at: newIndex) {
                pdfView.restore(
                    AnnotationPDFView.ZoomAnchor(
                        page: page, pagePoint: anchor.pagePoint,
                        viewPoint: anchor.viewPoint))
            } else {
                go(toPage: min(oldIndex, pageCount - 1))
            }
        }
        pageChanged()
        sidebar.reload()
    }

    // MARK: Export

    func export() {
        // what's being typed goes in too
        guard editor.finishEditing() else { return }
        ExportPanel.run(for: session, in: pdfView.window)
    }

    func quickExport() {
        guard editor.finishEditing() else { return }
        Task { await session.quickExport() }
    }

    // MARK: Zoom

    func zoomIn() { animateZoom(to: pdfView.scaleFactor * 2.squareRoot()) }
    func zoomOut() { animateZoom(to: pdfView.scaleFactor / 2.squareRoot()) }
    func actualSize() { animateZoom(to: 1) }

    /// Alternates between fitting the width and a whole page. The page a
    /// whole-page fit is made on is then shown in full.
    func zoomToFit() {
        let fit = PageFit.next(after: pdfView.fit)
        animateZoom(to: pdfView.fitScale(for: fit)) { [weak self] in
            guard let self else { return }
            pdfView.fit = fit
            if fit == .page { go(toPage: pageIndex) }
        }
    }

    /// Eases the zoom to `target` over about a third of a second instead of
    /// jumping. It moves evenly on a log scale, so zooming in and out feel the
    /// same, and is timed by the clock, so it takes the same time even when
    /// the Mac is busy.
    private func animateZoom(
        to target: CGFloat, then completion: (() -> Void)? = nil
    ) {
        guard !editor.isEditingItem else { return NSSound.beep() }
        zoomAnimation?.cancel()
        pdfView.fit = nil
        // Zoom around the centre of what's visible, not counting what's under
        // the sidebar.
        let anchor = pdfView.zoomAnchor()
        let start = pdfView.scaleFactor
        let end = min(
            max(target, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        guard start > 0, abs(end - start) > 0.001 else {
            completion?()
            return
        }
        zoomAnimation = Task { [weak self] in
            let duration = Duration.milliseconds(320)
            let clock = ContinuousClock()
            let started = clock.now
            while true {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                let time = min(1, (clock.now - started) / duration)
                // ease in and out: no sudden start or stop
                let progress = time * time * (3 - 2 * time)
                self.pdfView.scaleFactor = start * pow(end / start, progress)
                // the sidebar margin follows the zoom
                self.pdfView.updateGeometry()
                if let anchor { self.pdfView.restore(anchor) }
                if time >= 1 { break }
            }
            completion?()
        }
    }

    // MARK: Search

    /// The search field stays in the toolbar however narrow the window is;
    /// other items go into the overflow menu first. SwiftUI has no setting for
    /// this, and it resets the toolbar item's priority whenever it updates the
    /// toolbar, so the priority is put back each time.
    func keepSearchFieldVisible() async {
        // The toolbar and the field are put together a moment after the window
        // opens.
        for _ in 0..<30 {
            if let searchField,
                let item = pdfView.window?.toolbar?.items.first(where: {
                    $0.view.map(searchField.isDescendant(of:)) == true
                })
            {
                item.visibilityPriority = .user
                searchItemObservation = item.observe(\.visibilityPriority) {
                    item, _ in
                    MainActor.assumeIsolated {
                        if item.visibilityPriority != .user {
                            item.visibilityPriority = .user
                        }
                    }
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func focusSearchField() {
        guard let searchField, let window = searchField.window else { return }
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// Return in the search field: search for new text, or step to the next
    /// match if the text hasn't changed.
    func submitSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            clearSearch()
        } else if query == searchedText, !matches.isEmpty {
            nextMatch()
        } else {
            search(query)
        }
    }

    private func search(_ query: String) {
        guard let document = pdfView.document else { return }
        clearSearch()
        searchedText = query
        matches = document.findString(
            query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches { match.color = .findHighlightColor }
        pdfView.highlightedSelections = matches
        matchIndex = matches.isEmpty ? nil : 0
        showCurrentMatch()
    }

    /// The ✕ in the results bar: empties the search field too.
    func endSearch() {
        searchField?.stringValue = ""
        clearSearch()
    }

    /// Esc in the search field: end the search and go back to the page.
    func leaveSearch() {
        endSearch()
        pdfView.window?.makeFirstResponder(pdfView)
    }

    /// Removes every trace of the search: the highlights and the selected
    /// current match.
    func clearSearch() {
        if matchIndex != nil { pdfView.clearSelection() }
        matches = []
        matchIndex = nil
        searchedText = ""
        pdfView.highlightedSelections = nil
    }

    func nextMatch() { step(by: 1) }
    func previousMatch() { step(by: -1) }

    private func step(by offset: Int) {
        guard let index = matchIndex, !matches.isEmpty else { return }
        matchIndex = (index + offset + matches.count) % matches.count
        showCurrentMatch()
    }

    private func showCurrentMatch() {
        guard let index = matchIndex else { return }
        pdfView.setCurrentSelection(matches[index], animate: true)
        pdfView.go(to: matches[index])
    }
}
