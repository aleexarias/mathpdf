import Foundation
import Observation

/// Autosave for one document. The first change after a save starts a wait (30
/// seconds), and then everything changed in the meantime is saved at once.
/// Later changes don't push the save back, so constant editing saves twice a
/// minute. Call `changed(_:)` after every edit, and `flush()` to save right
/// away: ⌘S, closing the window, going to the background, quitting.
///
/// Saves run one after another and always write the latest state, and the
/// store ignores anything older than what it already wrote, so rapid edits
/// can't lose updates or land out of order. The disk work happens on the store
/// actor, never on the main thread.
@MainActor @Observable
public final class Autosaver {
    public private(set) var lastError: (any Error)?
    public private(set) var lastSavedRevision: Int?

    @ObservationIgnored private let store: AnnotationStore
    @ObservationIgnored private let delay: Duration
    // observed, so `hasUnsavedChanges` updates the UI
    private var latest: AnnotationSet?
    /// The save that the first unsaved change scheduled.
    @ObservationIgnored private var scheduledSave: Task<Void, Never>?
    @ObservationIgnored private var saveChain: Task<Void, Never>?

    public init(store: AnnotationStore, delay: Duration = .seconds(30)) {
        self.store = store
        self.delay = delay
    }

    public var hasUnsavedChanges: Bool { latest != nil }

    public func changed(_ set: AnnotationSet) {
        latest = set
        // that save will write this change too
        guard scheduledSave == nil else { return }
        scheduledSave = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.scheduledSave = nil
            self.enqueueSave()
        }
    }

    /// Saves any pending change now and waits until everything queued so far
    /// is on disk.
    public func flush() async {
        scheduledSave?.cancel()
        scheduledSave = nil
        await enqueueSave().value
    }

    @discardableResult
    private func enqueueSave() -> Task<Void, Never> {
        let previous = saveChain
        let task = Task { [weak self] in
            await previous?.value
            guard let self, let set = self.latest else { return }
            self.latest = nil
            do {
                if try await self.store.save(set) {
                    self.lastSavedRevision = set.revision
                }
                self.lastError = nil
            } catch {
                // keep it for the next attempt
                if self.latest == nil { self.latest = set }
                self.lastError = error
            }
        }
        saveChain = task
        return task
    }
}
