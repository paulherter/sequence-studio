import Foundation
import SQCore
import SQMedia

/// The bookkeeping behind the project folder watcher and the background copies, kept apart from the App wiring so it
/// can be tested. Rules:
/// - Work that must keep the watcher away (copies, Collect, card import, a relink waiting for playback) holds a token;
///   every token is released exactly once, in any order, and releasing an unknown token does nothing. When the last one
///   goes, `onIdle` fires so the watcher catches up.
/// - A sync that is requested while one runs is not lost: it runs again when the current one ends.
/// - `reset()` is the one place that forgets a project: it bumps the generation, drops the prompt queue, the scan memory
///   and every relink that was waiting for playback (their copies are discarded, their tokens released).
@MainActor
public final class MediaWorkState {
    public typealias Token = UUID

    public private(set) var generation = 0
    /// Bumped whenever the watcher restarts or the project resets: a sync that started earlier drops its result.
    public private(set) var watchEpoch = 0
    public var onIdle: (() -> Void)?

    public var pendingAsk: [ProjectPanelModel.ImportedFile] = []
    /// What the previous scan saw of each new file: a file is imported after two scans that agree.
    public var lastSeen: [String: MediaManagement.SeenFile] = [:]
    /// Frames of image sequences found earlier: the sync does not walk them again.
    public var sequenceFrames: Set<String> = []

    private var holders: Set<Token> = []
    private var pauses: [Token] = []
    public private(set) var syncRunning = false
    private var syncAgain = false

    public struct Deferred {
        public var token: Token
        public var map: [MediaRef.ID: String]
        public var projectID: UUID
        public var generation: Int
        /// Removes the copies of this relink when it is dropped.
        public var discard: @MainActor () -> Void
        public var completion: (([MediaRef.ID: String]) -> Void)?
    }
    public private(set) var deferred: [Deferred] = []

    /// What the user's answer to the "outside the project folder" prompt applies to: the queued files, but only when the
    /// project is still the one the prompt was shown for (`generation` is `generation` at show time). A stale answer
    /// (Revert, open, close while the prompt was up) gets nil and leaves the queue to `reset()`.
    public func takePendingAsk(promptGeneration: Int) -> [ProjectPanelModel.ImportedFile]? {
        guard promptGeneration == generation else { return nil }
        defer { pendingAsk = [] }
        return pendingAsk
    }

    /// Files of Imported/ or Library/ that a clip or media item has been linked to, or that another batch reused, in
    /// this session. A batch that ends in a mismatch never deletes these (ownership moved to whoever links them).
    public private(set) var claimed: Set<String> = []
    public func claim(_ paths: [String]) { claimed.formUnion(paths.map(MediaFileOps.identityKey(path:))) }   // by file identity, not spelling

    /// Which of the copies a dropped batch created may be deleted. When in doubt the file stays: nothing that is claimed,
    /// used by a media item of the open project, or possibly being reused by a batch that is still running.
    public func discardable(_ created: [String], inUse: Set<String>, otherBatchesRunning: Bool) -> [String] {
        guard !otherBatchesRunning else { return [] }
        // Compare by file identity (a case variant of a name is the same file). Only media with a candidate's name are looked up.
        let names = Set(created.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
        let used = Set(inUse.filter { names.contains(URL(fileURLWithPath: $0).lastPathComponent.lowercased()) }
            .map(MediaFileOps.identityKey(path:)))
        return created.filter { let k = MediaFileOps.identityKey(path: $0); return !claimed.contains(k) && !used.contains(k) }
    }

    private var lastWatchSetting: Bool?
    /// The project's watch setting as the watcher last saw it; true when `on` differs (undo, redo, revert, menu).
    public func watchSettingChanged(to on: Bool) -> Bool {
        defer { lastWatchSetting = on }
        return lastWatchSetting != on
    }

    public init() {}

    public var isBusy: Bool { !holders.isEmpty }
    public var holderCount: Int { holders.count }

    // MARK: Tokens

    public func hold() -> Token {
        let t = Token()
        holders.insert(t)
        return t
    }

    public func release(_ t: Token) {
        guard holders.remove(t) != nil else { return }
        if holders.isEmpty { onIdle?() }
    }

    /// The watcher waits while paused (card import, Collect Files). Calls pair up; an extra `resume` does nothing.
    public func pause() { pauses.append(hold()) }
    public func resume() { if let t = pauses.popLast() { release(t) } }

    // MARK: Relinks that wait for playback

    public func deferRelink(map: [MediaRef.ID: String], projectID: UUID, discard: @escaping @MainActor () -> Void,
                            completion: (([MediaRef.ID: String]) -> Void)?) {
        deferred.append(Deferred(token: hold(), map: map, projectID: projectID, generation: generation,
                                 discard: discard, completion: completion))
    }

    /// Playback paused: every waiting relink that still belongs to the open project is applied through `apply`; the
    /// others are dropped (their copies discarded). Each token is released either way.
    public func flushDeferred(projectID: UUID, apply: ([MediaRef.ID: String]) -> [MediaRef.ID: String]) {
        let list = deferred
        deferred = []
        for d in list {
            if d.generation == generation, d.projectID == projectID {
                d.completion?(apply(d.map))
            } else {
                d.discard()
            }
            release(d.token)
        }
    }

    // MARK: Sync

    /// False when a sync is already running: it will run once more when it ends.
    public func beginSync() -> Bool {
        if syncRunning { syncAgain = true; return false }
        syncRunning = true
        return true
    }

    /// True when a sync was requested meanwhile.
    public func endSync() -> Bool {
        syncRunning = false
        defer { syncAgain = false }
        return syncAgain
    }

    public func noteWatchRestart() { watchEpoch += 1 }

    // MARK: Reset

    /// A different project (open, new, import, revert) or quit: forget everything that belonged to the old one.
    public func reset() {
        generation += 1
        watchEpoch += 1
        pendingAsk = []
        lastSeen = [:]
        sequenceFrames = []
        lastWatchSetting = nil
        let list = deferred
        deferred = []
        for d in list { d.discard() }
        for d in list { release(d.token) }
    }
}
