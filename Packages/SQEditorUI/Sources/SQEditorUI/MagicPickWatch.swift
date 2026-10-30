import Foundation
import SQCore

/// Decides after every project change which Magic pick must be followed again: a pick that came back (undo, redo, a
/// removed mask that returns) with its own frame stored but its mattes not reaching both edges of its clip. The
/// decision reads the project and the matte store only, never whether a run was just stopped: undo then redo of a
/// pick with nothing running, or a pick that returns after another pick's run ended, are followed like any other.
///
/// What starts a run is the pick's key being new since the last look (it was not a key of the project one change
/// earlier) with nothing but the pick's own frame on record, not the missing frames alone: a pick the user stopped,
/// a track that lost its subject, tracked frames deleted by hand or a split clip stay as they are when something
/// else in the project changes, and also when their clip is deleted and comes back. Looking twice at the same
/// project therefore never starts a second run.
///
/// A pick that returns while the one track slot is taken (or another tool is active) waits (`waiting`) and gets its
/// run when the slot is free: one run at a time, no run is pushed out.
public struct MagicPickWatch: Sendable {
    public struct Ref: Hashable, Sendable {
        public var clip: Clip.ID
        public var mask: ClipMask.ID
        public init(clip: Clip.ID, mask: ClipMask.ID) { self.clip = clip; self.mask = mask }
    }

    /// One direction of a run, in source seconds. `forward`: towards later source times.
    public struct Leg: Equatable, Sendable {
        public var from: Double
        public var to: Double
        public var forward: Bool
        public init(from: Double, to: Double, forward: Bool) { self.from = from; self.to = to; self.forward = forward }
    }

    /// A Magic mask with a pick, as the project has it now.
    public struct Pick: Equatable, Sendable {
        public var ref: Ref
        /// The cache key of the pick's mattes.
        public var key: String
        /// Source seconds of the frame the pick was made on.
        public var anchor: Double
        /// Source seconds of the earliest and the latest frame the clip shows (a reversed clip: still `low` < `high`).
        public var low: Double
        public var high: Double
        /// Source seconds a stored frame may be away from an edge or from the pick's frame and still count as there
        /// (the tracker stores at the file's frame times, the edges come from the sequence's frame grid).
        public var slack: Double
        public init(ref: Ref, key: String, anchor: Double, low: Double, high: Double, slack: Double) {
            self.ref = ref; self.key = key; self.anchor = anchor; self.low = low; self.high = high; self.slack = slack
        }
    }

    public struct Restart: Equatable, Sendable {
        public var ref: Ref
        public var key: String
        public var legs: [Leg]
    }

    /// The project looked at last and the keys its picks had.
    private var project: Project.ID?
    private var keys: Set<String> = []

    /// The picks that came back and have no run yet, oldest first: the track slot was taken or the Magic tool was
    /// not active when they returned. They wait here until `started` (the caller gave one its run), until the
    /// project loses the pick, a run follows it or frames beyond its own are on record.
    public private(set) var waiting: [Restart] = []

    /// The keys whose own track was cut off by the project, not by the user (the mask went away or got another pick:
    /// undo, Delete Mask, a deleted clip): when such a pick comes back, its track goes on towards the edges not
    /// reached, although frames are on record. Until any run starts for that pick (`started`): a Stop of that run is
    /// the user's. Only the pick's own track is noted; a run started with a track button is never resumed (it had
    /// one direction the user asked for, and asking again is one click).
    /// A note also ends when nothing is left to go on with: the pick is in the project with mattes that reach both
    /// edges, or the pick is not in the project and nothing can bring it back (`look(canReturn:)`).
    private var cut: Set<String> = []
    /// The keys with a cut-off note (tests, logs).
    public var cutOffKeys: Set<String> { cut }
    /// The user's Stop seen last (`MaskTrackActivity.userStop`) and whether it holds the waiting picks back.
    private var seenStop: Int?
    public private(set) var isHeld = false
    /// The mask whose run that Stop ended (`MaskTrackActivity.userStopMask`): a subject-mask run for it ends the hold.
    private var heldMask: ClipMask.ID?
    /// The clip of that run, when it named one (the halves of a split clip share their mask ids).
    private var heldClip: Clip.ID?

    public init() {}

    /// The run under `key` was stopped because its mask is gone or has another pick now. `automatic`: it was the
    /// pick's own track (`MaskTrackActivity.Run.automatic`); a track-button run leaves no note.
    public mutating func cutOff(_ key: String, automatic: Bool) {
        if automatic { cut.insert(key) }
    }

    /// The picks that came back with this change of `project`; they are in `waiting` from now on. `times`: the
    /// source times on record for a key, in memory or in its file (`MagicMatteStore.times`); `following`: a run
    /// already stores frames for that pick; `userStop`: `MaskTrackActivity.userStop`, `stopped`: the mask of the
    /// run it ended (`MaskTrackActivity.userStopMask`). `canReturn`: the project has a step to undo or redo, so a
    /// pick it does not hold now may come back; false drops the cut-off notes of such picks.
    /// The first look at a project only notes its picks: opening a project follows nothing by itself. Looking again
    /// at an unchanged project (a run ended, the tool changed) returns nothing and brings `waiting` up to date.
    public mutating func look(at project: Project, userStop: Int? = nil, stopped: ClipMask.ID? = nil, stoppedClip: Clip.ID? = nil,
                              canReturn: Bool = true,
                              times: (String) -> [Double], following: (Ref, String) -> Bool) -> [Restart] {
        let picks = Self.picks(in: project)
        let before = self.project == project.id ? keys : nil
        self.project = project.id
        keys = Set(picks.map(\.key))
        guard let before else { waiting = []; cut = []; isHeld = false; heldMask = nil; heldClip = nil; seenStop = userStop; return [] }
        if !canReturn { cut.formIntersection(keys) }
        // A noted pick whose mattes reach both edges has nothing to go on with.
        for p in picks where cut.contains(p.key) && Self.isComplete(p, times: times(p.key)) { cut.remove(p.key) }
        // A pick with frames on record beyond its own was followed before (stopped by the user, lost its subject,
        // frames deleted by hand): it is never tracked over again, however it comes back. Only a track the project
        // cut off goes on.
        func restart(_ p: Pick) -> Restart? {
            guard !following(p.ref, p.key) else { return nil }
            let stored = times(p.key)
            guard cut.contains(p.key) || stored.allSatisfy({ abs($0 - p.anchor) <= p.slack / 3 }) else { return nil }
            let legs = Self.legs(p, times: stored)
            return legs.isEmpty ? nil : Restart(ref: p.ref, key: p.key, legs: legs)
        }
        waiting = waiting.compactMap { w in picks.first { $0.ref == w.ref && $0.key == w.key }.flatMap(restart) }
        // The user's Stop ends tracking: the picks that wait at that moment do not start by themselves. A
        // subject-mask run for the stopped mask or for a waiting pick's mask (`started`), or choosing the Magic
        // tool, lets them go; any other run (a path track, another mask) leaves them held. A Stop with no pick
        // waiting holds nothing: a pick that comes back after it is followed.
        if userStop != seenStop {
            seenStop = userStop
            if userStop != nil { isHeld = !waiting.isEmpty; heldMask = stopped; heldClip = stoppedClip }
        }
        if waiting.isEmpty { isHeld = false }
        if !isHeld { heldMask = nil; heldClip = nil }
        var out: [Restart] = []
        for p in picks where !before.contains(p.key) && !waiting.contains(where: { $0.key == p.key }) {
            if let r = restart(p) { out.append(r); waiting.append(r) }
        }
        return out
    }

    /// The waiting pick that gets the track slot now, and waits no longer: none while the slot is taken, another
    /// tool is active or the user's Stop holds them. `toolChosen`: the Magic tool was just chosen, which ends the
    /// hold. `shown`: the clip Effect Controls shows goes first, else the pick that waits longest.
    public mutating func next(slotFree: Bool, toolIsMagic: Bool, toolChosen: Bool = false, shown: Clip.ID? = nil) -> Restart? {
        if toolChosen { isHeld = false; heldMask = nil; heldClip = nil }
        guard slotFree, toolIsMagic, !isHeld, let r = waiting.first(where: { $0.ref.clip == shown }) ?? waiting.first else { return nil }
        started(r.key, mask: r.ref.mask, clip: r.ref.clip)
        return r
    }

    /// A subject-mask run started for the pick with `key` of `mask`, whoever started it (the watch, a fresh click,
    /// a correction, a track button): it waits no longer, and a Stop of that run is the user's. The user's hold
    /// ends when `mask` is the one whose run was stopped or one a waiting pick is on: tracking it again is the
    /// user's word that tracking goes on. A path track never comes here. `clip`: the clip the mask is on; the
    /// halves of a split clip share their mask ids, so with a clip named on both sides it has to be the same one.
    public mutating func started(_ key: String, mask: ClipMask.ID? = nil, clip: Clip.ID? = nil) {
        if isHeld, let mask {
            let stopped = mask == heldMask && (clip == nil || heldClip == nil || clip == heldClip)
            if stopped || waiting.contains(where: { $0.ref.mask == mask && (clip == nil || $0.ref.clip == clip) }) { isHeld = false }
        }
        waiting.removeAll { $0.key == key }
        cut.remove(key)
        if waiting.isEmpty { isHeld = false }
        if !isHeld { heldMask = nil; heldClip = nil }
    }

    /// True when the pick's own frame is stored and its mattes reach both edges of its clip.
    public static func isComplete(_ p: Pick, times: [Double]) -> Bool {
        times.contains { abs($0 - p.anchor) <= p.slack / 3 } && legs(p, times: times).isEmpty
    }

    /// The directions a pick still has to be followed in, from its own frame: none when that frame is not stored
    /// (nothing to start from: a fresh click follows itself once its matte is in) or the mattes reach both edges.
    public static func legs(_ p: Pick, times: [Double]) -> [Leg] {
        guard let first = times.min(), let last = times.max(),
              times.contains(where: { abs($0 - p.anchor) <= p.slack / 3 }) else { return [] }
        var legs: [Leg] = []
        if p.high > p.anchor + 1e-6, last < p.high - p.slack { legs.append(Leg(from: p.anchor, to: p.high, forward: true)) }
        if p.low < p.anchor - 1e-6, first > p.low + p.slack { legs.append(Leg(from: p.anchor, to: p.low, forward: false)) }
        return legs
    }

    /// Every Magic pick of the project that a track can follow (a video clip from a file).
    public static func picks(in project: Project) -> [Pick] {
        var out: [Pick] = []
        for tl in project.timelines {
            for track in tl.tracks {
                for c in track.clips where !c.masks.isEmpty && c.sequence == nil && !c.isGenerator && !c.isStill && c.holdFrame == nil {
                    for m in c.masks where m.source == .magic {
                        guard let sel = m.magic, !sel.points.isEmpty, let anchor = sel.anchorTime,
                              let media = project.media(c.media) else { continue }
                        let fd = tl.frameDuration
                        let a = seconds(c.sourceInstant(atLocal: .zero))
                        let b = seconds(c.sourceInstant(atLocal: max(c.duration - fd, .zero)))
                        let frame = max(seconds(fd), media.info?.video.map { seconds($0.nominalFrameDuration) } ?? 0)
                        out.append(Pick(ref: Ref(clip: c.id, mask: m.id), key: sel.cacheKey(media: c.media), anchor: seconds(anchor),
                                        low: min(a, b), high: max(a, b), slack: 1.5 * frame))
                    }
                }
            }
        }
        return out
    }

    /// Mask `id` on clip `clip` of the project; `clip` nil: on the first clip that has a mask with that id (the
    /// halves of a split clip share their mask ids, so a run names its clip).
    public static func mask(_ id: ClipMask.ID, clip: Clip.ID?, in project: Project) -> (clip: Clip, mask: ClipMask)? {
        for tl in project.timelines {
            for track in tl.tracks {
                for c in track.clips where clip == nil || c.id == clip {
                    if let m = c.mask(id) { return (c, m) }
                }
            }
        }
        return nil
    }

    /// The cache key of that mask's pick; nil without the mask or without a pick.
    public static func key(_ id: ClipMask.ID, clip: Clip.ID?, in project: Project) -> String? {
        mask(id, clip: clip, in: project).flatMap { found in
            found.mask.magic.flatMap { $0.points.isEmpty ? nil : $0.cacheKey(media: found.clip.media) }
        }
    }

    private static func seconds(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }
}
