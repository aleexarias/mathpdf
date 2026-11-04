import MathPDFCore
import SwiftUI

/// Banners above the page: recovery, blocked data, relink suggestions and save
/// errors.
struct NoticeBar: View {
    let session: DocumentSession

    var body: some View {
        VStack(spacing: 0) {
            if let notice = session.notice {
                banner(for: notice)
            }
            if let error = session.autosaver.lastError {
                Banner(
                    style: .error,
                    text:
                        """
                        Couldn't save annotations: \
                        \(error.localizedDescription) Your changes are kept \
                        in memory and will be retried.
                        """
                ) {
                    revealButton
                }
            }
        }
    }

    @ViewBuilder
    private func banner(for notice: DocumentSession.Notice) -> some View {
        switch notice {
        case let .recovered(problem, snapshotDate, count):
            let saved = snapshotDate.formatted(
                date: .abbreviated, time: .standard)
            Banner(
                style: .warning,
                text:
                    """
                    Annotations were restored from a backup. \(problem) \
                    Restored the version saved \(saved), with \(count) \
                    annotation\(count == 1 ? "" : "s").
                    """
            ) {
                revealButton
                dismissButton
            }
        case .blocked(.newerSchema):
            Banner(
                style: .error,
                text:
                    """
                    The annotations for this PDF were saved by a newer \
                    version of mathpdf and can't be opened here. They won't \
                    be changed.
                    """
            ) {
                revealButton
            }
        case .blocked(.noValidData):
            Banner(
                style: .error,
                text:
                    """
                    Saved annotations for this PDF exist, but none of the \
                    files can be read. They've been left untouched and \
                    saving is paused.
                    """
            ) {
                revealButton
                Button("Start Fresh") { Task { await session.startFresh() } }
                    .help(
                        """
                        Start with no annotations. The unreadable files stay \
                        in the data folder.
                        """
                    )
            }
        case .relinkSuggested(let candidate):
            Banner(
                style: .info,
                text:
                    """
                    No saved annotations match this exact file; it may have \
                    been edited elsewhere. A set saved for \
                    “\(candidate.fileNameHint)” has \
                    \(candidate.annotationCount) \
                    annotation\(candidate.annotationCount == 1 ? "" : "s").
                    """
            ) {
                Button("Relink…") { session.isShowingRelinkSheet = true }
                dismissButton
            }
        case let .relinked(fileName, count):
            Banner(
                style: .success,
                text:
                    """
                    Copied \(count) annotation\(count == 1 ? "" : "s") from \
                    “\(fileName)”. The original set is unchanged.
                    """
            ) {
                dismissButton
            }
        case let .exported(url, count, _):
            Banner(
                style: .success,
                text:
                    """
                    Exported “\(url.lastPathComponent)” with \(count) \
                    annotation\(count == 1 ? "" : "s"). The original PDF is \
                    unchanged.
                    """
            ) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                dismissButton
            }
        case .error(let message):
            Banner(style: .error, text: message) {
                dismissButton
            }
        }
    }

    private var revealButton: some View {
        Button("Show Data Folder") {
            DataFolder.reveal(
                session.dataFolderURL ?? Persistence.store.rootURL)
        }
    }

    private var dismissButton: some View {
        Button("Dismiss") { session.notice = nil }
    }
}

private struct Banner<Actions: View>: View {
    enum Style {
        case info, success, warning, error

        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: .blue
            case .success: .green
            case .warning: .orange
            case .error: .red
            }
        }
    }

    let style: Style
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: style.icon).foregroundStyle(style.tint)
            // No fixedSize here: measured at the window's minimum width, a
            // vertically fixed text becomes thousands of points tall and
            // pushes the whole window off-screen.
            Text(text).lineLimit(4).textSelection(.enabled)
            Spacer(minLength: 8)
            actions.controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Solid underneath: the page can scroll beneath the banner.
        .background(style.tint.opacity(0.12))
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
