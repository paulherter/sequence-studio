import Foundation
import Observation
import SQCore
import Synchronization

/// The mask track that is running (path or Magic; one at a time): the mask row shows Stop and the progress while it runs,
/// whichever clip Effect Controls shows. It also owns the run's task, so the one slot can never stay taken by a run that
/// nobody can end: `stop` frees the slot at once (it does not wait for the task), a run only ever clears its own slot
/// (`finish` with its token), and a run whose mask is gone is stopped (`stopIfMaskGone`: Delete Mask, undo, deleted
/// effect or clip, another project).
///
/// What a stopped run may still write, three endings:
/// - the user's stop (Stop, the track button again, Background Jobs: `keeps`): the run may write what it did so far to
///   the project once (`mayWrite`: undo step, status line) and saves its frames;
/// - its mask is gone (`stopIfMaskGone`: `discards`): nothing more, no undo step and no file;
/// - every other stop (tool switched, a correction or another run takes over, its pick changed, its project closes or
///   another opens): no undo step and no status line, but the frames tracked so far are saved under the run's own
///   key, at once (`save`, given at `start`) and again by the run when its last frame is in (`keepsFrames`). So frames
///   are never in memory only while their key is still a mask's, and a pick that comes back (undo, redo) finds them.
@MainActor @Observable
public final class MaskTrackActivity {
    public static let shared = MaskTrackActivity()

    public struct Run: Equatable, Sendable {
        public var mask: ClipMask.ID
        public var forward: Bool
        /// 0...100, -1 until the first progress report.
        public var percent: Int
        /// Started by a pick, not by a track button: follows the pick in both directions (`turn`), and a tool switch
        /// or a new click ends it (`stopAutomatic`).
        public var automatic: Bool
        /// The clip whose mask is tracked. The halves of a split clip share their mask ids: every lookup of the run's
        /// mask goes by clip and mask (`MagicPickWatch.mask`). nil: found by the mask id alone.
        public var clip: Clip.ID?
        public init(mask: ClipMask.ID, forward: Bool, percent: Int = -1, automatic: Bool = false, clip: Clip.ID? = nil) {
            self.mask = mask; self.forward = forward; self.percent = percent; self.automatic = automatic; self.clip = clip
        }
    }

    public var run: Run?
    /// The Magic mask's explicit track controls (step, run, Stop) and their state line.
    public var magic = MagicTrackControl()
    public var isRunning: Bool { run != nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var owner: ObjectIdentifier?
    /// The run the user stopped: it may write what it did so far.
    @ObservationIgnored private var kept: Int?
    /// The mask of that run.
    @ObservationIgnored private var keptMask: ClipMask.ID?
    @ObservationIgnored private var keptClip: Clip.ID?
    @ObservationIgnored private var writes: WriteSwitch?
    /// The cache key the run stores its frames under (a Magic track: the pick's key when it started).
    @ObservationIgnored private var key: String?
    /// Saves the frames the run stored so far.
    @ObservationIgnored private var save: (@MainActor () -> Void)?

    /// Readable from the run's own thread: false once the run was stopped with `discards`.
    private final class WriteSwitch: Sendable {
        private let on = Mutex(true)
        var isOn: Bool { on.withLock { $0 } }
        func off() { on.withLock { $0 = false } }
    }

    public init() {}

    /// Takes the slot for a track of `mask` (a run still in it is stopped) and returns the run's token. `owner`: whose
    /// project the mask lives in (the editor session), so another window's edits do not stop it. `key`: the cache key
    /// its frames are stored under (`stopIfKeyChanged`); `save`: writes the frames stored so far, called when the run
    /// is stopped and its frames stay. `clip`: the clip the mask is on (`Run.clip`).
    @discardableResult
    public func start(mask: ClipMask.ID, forward: Bool, owner: AnyObject? = nil, automatic: Bool = false,
                      key: String? = nil, clip: Clip.ID? = nil, save: (@MainActor () -> Void)? = nil) -> Int {
        if run != nil || task != nil { stop(reason: "another track starts") }
        token += 1
        kept = nil
        keptMask = nil
        keptClip = nil
        writes = WriteSwitch()
        self.key = key
        self.save = save
        self.owner = owner.map(ObjectIdentifier.init)
        run = Run(mask: mask, forward: forward, automatic: automatic, clip: clip)
        NSLog("[Magic] track %d started (%@%@)", token, forward ? "forward" : "backward", automatic ? ", by the pick" : "")
        return token
    }

    /// Track `token` goes on in the other direction (the pick's own track: forward first, then backward) in the same
    /// slot; its progress starts over. False when it is not the current run.
    @discardableResult
    public func turn(forward: Bool, token: Int) -> Bool {
        guard isCurrent(token) else { return false }
        run?.forward = forward
        run?.percent = -1
        return true
    }

    /// Stops the running track when a pick started it (the tool was switched, a correction takes over); its frames are
    /// saved. A track the user started with a track button goes on. False when no automatic track ran.
    @discardableResult
    public func stopAutomatic(reason: String, keeps: Bool = false) -> Bool {
        guard run?.automatic == true else { return false }
        return stop(reason: reason, keeps: keeps)
    }

    /// The task that runs track `token`; `stop` cancels it. Ignored when that run is no longer the current one (the task
    /// is canceled then: it must not go on writing).
    public func attach(_ task: Task<Void, Never>, to token: Int) {
        guard isCurrent(token) else { task.cancel(); return }
        self.task = task
    }

    public func isCurrent(_ token: Int) -> Bool { run != nil && token == self.token }

    /// The cache key the running track stores its frames under; nil without a run or for a path track.
    public var runKey: String? { run == nil ? nil : key }

    /// The token of the run the user stopped (Stop, the track button again, Background Jobs) while no run started
    /// since; nil otherwise. `MagicPickWatch` holds its waiting picks back on it.
    public var userStop: Int? { run == nil ? kept : nil }

    /// The mask whose run that was; nil with `userStop` nil.
    public var userStopMask: ClipMask.ID? { run == nil && kept != nil ? keptMask : nil }
    /// The clip that run named; nil when it named none.
    public var userStopClip: Clip.ID? { run == nil && kept != nil ? keptClip : nil }

    /// True while a run of `owner` stores frames under `key` for `mask` of `clip`: that pick needs no second run.
    public func isFollowing(clip: Clip.ID, mask: ClipMask.ID, key: String, owner: AnyObject?) -> Bool {
        guard let r = run, self.owner == owner.map(ObjectIdentifier.init) else { return false }
        return r.mask == mask && (r.clip ?? clip) == clip && self.key == key
    }

    /// True when track `token` may write to the project and its files: it is the running one, or the user stopped it
    /// (what it did so far is kept) and no other run started since.
    public func mayWrite(_ token: Int) -> Bool { isCurrent(token) || (run == nil && kept == token) }

    /// Whether the run's frames stay, for the run's own thread (a Magic track saves its mattes file when it ends):
    /// false only once the run was stopped because its mask is gone. A token that is not the current run: always false.
    public func keepsFrames(_ token: Int) -> @Sendable () -> Bool {
        guard isCurrent(token), let writes else { return { false } }
        return { writes.isOn }
    }

    /// Progress of track `token` in percent; false when it is not the current run or the value did not change.
    @discardableResult
    public func progress(_ percent: Int, token: Int) -> Bool {
        guard isCurrent(token), run?.percent != percent else { return false }
        run?.percent = percent
        return true
    }

    /// Track `token` ended by itself: frees the slot unless a newer run took it.
    public func finish(_ token: Int) {
        guard token == self.token else { return }
        task = nil; run = nil; owner = nil; key = nil; save = nil
    }

    /// Stops the running track: the slot is free when this returns, the task is canceled and ends at its next frame
    /// without tracking more. Nothing waits for it. `keeps` (the user's Stop): the run may still write what it did so
    /// far to the project. `discards` (its mask is gone): it writes nothing at all, no file either. Otherwise the
    /// frames it stored are saved (here and by the run itself at its end), the project is not touched. False when no
    /// track ran.
    @discardableResult
    public func stop(reason: String, keeps: Bool = false, discards: Bool = false) -> Bool {
        guard run != nil || task != nil else { return false }
        NSLog("[Magic] track %d stopped: %@%@", token, reason, discards ? " (frames not saved)" : "")
        task?.cancel()
        kept = keeps && !discards ? token : nil
        keptMask = kept == nil ? nil : run?.mask
        keptClip = kept == nil ? nil : run?.clip
        if discards { writes?.off() } else { save?() }
        writes = nil
        task = nil; run = nil; owner = nil; key = nil; save = nil
        return true
    }

    /// Stops the running track when its mask no longer exists (`exists` looks for the run's mask on the run's clip in
    /// the project of `owner`). Called after every project change of that owner; a run of another owner is left
    /// alone. Its frames are not saved.
    @discardableResult
    public func stopIfMaskGone(owner: AnyObject?, exists: (Clip.ID?, ClipMask.ID) -> Bool) -> Bool {
        guard let r = run, self.owner == owner.map(ObjectIdentifier.init), !exists(r.clip, r.mask) else { return false }
        return stop(reason: "its mask was removed", discards: true)
    }

    /// Stops the running track when its mask's cache key is no longer the one it started with (`current` looks for
    /// the run's mask on the run's clip in the project of `owner`, not for the first clip with that mask id: the
    /// other half of a split clip has the same ids. A new click, undo or redo of a point changed the pick), so a run never goes on storing
    /// frames for a pick the mask does not have. The frames it stored are saved under its own key: the pick can come
    /// back (undo, redo) and finds them. Returns the stopped run; nil when nothing was stopped (also a run without a
    /// key: a path track).
    @discardableResult
    public func stopIfKeyChanged(owner: AnyObject?, current: (Clip.ID?, ClipMask.ID) -> String?) -> Run? {
        guard let r = run, let key, self.owner == owner.map(ObjectIdentifier.init), current(r.clip, r.mask) != key else { return nil }
        stop(reason: "its pick changed")
        return r
    }

    /// Stops the running track of `owner` (its window or project closes); its frames are saved.
    @discardableResult
    public func stop(owner: AnyObject?, reason: String) -> Bool {
        guard run != nil, self.owner == owner.map(ObjectIdentifier.init) else { return false }
        return stop(reason: reason)
    }
}
