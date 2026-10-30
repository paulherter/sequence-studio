import Foundation
import SQCore

/// Crash safety between the timed history versions: a recovery snapshot soon after every edit.
/// The timed autosave (`tickAutosave`, 1 to 15 min) keeps its history; this writes one extra version, at most
/// every `minGap` seconds while the project changes, and replaces its own previous one so it never evicts history.
@MainActor
public final class RecoverySnapshotState {
    var projectID: UUID?
    var lastProject: Project?
    var lastWrite: Date?
    var lastURL: URL?
    let queue = ProjectSaveQueue()
    public init() {}
}

extension EditorSession {
    /// One poll: writes a recovery snapshot when the project changed since the last one and `minGap` has passed.
    /// Returns whether one was written.
    @discardableResult
    public func tickRecovery(_ state: RecoverySnapshotState, minGap: TimeInterval = 5, now: Date = Date()) async -> Bool {
        guard isDirty else { return false }
        let id = project.id
        let snapshot = history.current
        if state.projectID == id {
            if state.lastProject == snapshot { return false }
            if let last = state.lastWrite, now.timeIntervalSince(last) < minGap { return false }
        } else {
            state.lastURL = nil      // another project: its snapshot is not ours to replace
        }
        do {
            let v = try await state.queue.autosave(snapshot, store: autosaveStore, date: now)
            if let old = state.lastURL, old != v.url, state.projectID == id { try? FileManager.default.removeItem(at: old) }
            state.projectID = id; state.lastProject = snapshot; state.lastWrite = now; state.lastURL = v.url
            return true
        } catch {
            SQLog.error("recovery snapshot failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Polls every `poll` seconds; ends when the session is gone.
    public func startRecoveryTimer(minGap: TimeInterval = 5, poll: TimeInterval = 1) {
        let state = RecoverySnapshotState()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(poll))
                guard let self else { return }
                await self.tickRecovery(state, minGap: minGap)
            }
        }
    }
}
