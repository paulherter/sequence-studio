import Foundation
import SQAnalysis
import SQCore

/// Source times (seconds) of the tracked frames of Magic masks, by matte cache key, for the keyframe lanes (Effect Controls
/// and the timeline clip lane). The store is read off the main thread the first time a key is asked for and then served
/// from memory, so a draw never touches the disk; `forget()` after a Track run reloads. Every change posts `changed`.
@MainActor
public final class MagicTrackedFrames {
    public static let changed = Notification.Name("SQMagicTrackedFramesChanged")
    /// The app's: reads `MagicMatteStore.shared`.
    public static let shared = MagicTrackedFrames(store: .shared)

    public let store: MagicMatteStore
    /// false (tests): reads synchronously on first ask.
    let loadsInBackground: Bool
    private var cache: [String: [Double]] = [:]
    private var pending: Set<String> = []
    private var generation = 0
    /// Bumped on every change (lane display caches compare it).
    public private(set) var revision = 0

    public init(store: MagicMatteStore, loadsInBackground: Bool = true) {
        self.store = store; self.loadsInBackground = loadsInBackground
    }

    /// Sorted source seconds of the frames tracked under `key`; empty while they are being read.
    public func times(key: String) -> [Double] {
        if let t = cache[key] { return t }
        guard loadsInBackground else {
            let t = store.times(key: key)
            cache[key] = t
            return t
        }
        guard pending.insert(key).inserted else { return [] }
        let store = store, gen = generation
        Task.detached(priority: .utility) { [weak self] in
            let t = store.times(key: key)
            await MainActor.run {
                guard let self else { return }
                self.pending.remove(key)
                guard gen == self.generation else { return }      // forgotten meanwhile: the next ask reads again
                self.cache[key] = t
                self.bump()
            }
        }
        return []
    }

    /// Tracking (or anything else) changed the stored mattes: every key is read again on its next ask.
    public func forget() {
        cache.removeAll(); pending.removeAll(); generation += 1
        bump()
    }

    /// Deletes the mattes at `times` (source seconds) of `key` from the store and its file. Returns what went (for undo).
    @discardableResult
    public func remove(key: String, times: [Double]) -> MagicFrameSnapshot {
        let snap = store.snapshotFrames(key: key, times: times)
        guard !times.isEmpty else { return snap }
        store.removeFrames(key: key, times: times)
        persist(key)
        if let t = cache[key] { cache[key] = t.filter { p in !times.contains { abs($0 - p) < 1e-6 } } }
        bump()
        return snap
    }

    /// Redo of a delete: removes the frames of `snapshot` (by time and matte, see `MagicMatteStore.removeFrames(matching:)`),
    /// leaving a frame that was tracked again at the same time since the undo.
    public func remove(matching snapshot: MagicFrameSnapshot) {
        let gone = store.removeFrames(matching: snapshot)
        guard !gone.isEmpty else { return }
        persist(snapshot.storeKey)
        if let t = cache[snapshot.storeKey] { cache[snapshot.storeKey] = t.filter { p in !gone.contains { abs($0 - p) < 1e-6 } } }
        bump()
    }

    /// Puts back frames `remove` returned (undo of a delete).
    public func restore(_ snapshot: MagicFrameSnapshot) {
        guard !snapshot.isEmpty else { return }
        store.restore(snapshot)
        persist(snapshot.storeKey)
        cache[snapshot.storeKey] = nil          // read again on the next ask
        pending.remove(snapshot.storeKey)
        generation += 1
        if !loadsInBackground { cache[snapshot.storeKey] = store.times(key: snapshot.storeKey) }
        bump()
    }

    private func persist(_ key: String) {
        let store = store
        if loadsInBackground { store.saveLater(key: key) } else { store.save(key: key) }
    }

    // MARK: Lane key cache

    private struct KeyEntry { var revision: Int; var clip: Clip; var frameDuration: Time; var keys: [MagicFrameKey] }
    private var keyCache: [UUID: KeyEntry] = [:]
    /// How often the lane keys were really built (tests).
    private(set) var keyBuilds = 0

    /// `MagicFrameKey.keys` of `mask` under `key`, built once per revision of the frames, clip and frame duration: a draw or
    /// hit test sorts nothing.
    public func keys(clip: Clip, mask: ClipMask, key: String, frameDuration: Time) -> [MagicFrameKey] {
        let t = times(key: key)       // may start a load, which bumps `revision` when done
        if let e = keyCache[mask.id], e.revision == revision, e.frameDuration == frameDuration, e.clip == clip { return e.keys }
        keyBuilds += 1
        let built = MagicFrameKey.keys(clip: clip, mask: mask, times: t, frameDuration: frameDuration)
        keyCache[mask.id] = KeyEntry(revision: revision, clip: clip, frameDuration: frameDuration, keys: built)
        return built
    }

    private func bump() {
        revision += 1
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

/// One tracked frame of a Magic mask as a key in the lanes. Not movable or easable; deletable.
public struct MagicFrameKey: Sendable, Hashable {
    /// Stable per mask and frame (the selection holds it).
    public var id: UUID
    /// Clip-local.
    public var time: Time
    /// Source seconds as stored (`MagicMatteStore`).
    public var pts: Double
    /// A correction point (a `MagicPoint` on another frame than the pick's) was set on this frame: drawn as a normal key,
    /// deleting it also drops the point. Never true for the pick's own frame: its points are the pick.
    public var isCorrection: Bool
    /// Seconds this source frame is shown (to the next frame of the file): points stored inside it were made on it.
    public var span: Double = 0

    /// Whether `p` is a correction point made on this frame. The pick's own points (those at `anchor`, the pick's frame)
    /// never are.
    public func holdsCorrection(_ p: MagicPoint, anchor: Time?) -> Bool {
        guard p.sourceTime != anchor else { return false }
        return MagicFollower.belongs(point: Double(p.sourceTime.value) / Double(max(p.sourceTime.timescale, 1)), pts: pts, span: span)
    }

    /// The tracked frames `times` (source seconds) of `mask` that fall inside `clip`, one per clip frame, as lane keys.
    public static func keys(clip: Clip, mask: ClipMask, times: [Double], frameDuration: Time) -> [MagicFrameKey] {
        let points = mask.magic?.points ?? []
        let anchor = mask.magic?.anchorTime
        let fd = frameDuration > .zero ? frameDuration : Time(1, 30)
        // The file's frame spacing: the smallest step between tracked frames (the sequence's frame when that says nothing).
        let sorted = times.sorted()
        let step = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 1e-6 }.min() ?? .infinity
        let span = step <= 0.1 ? step : Double(fd.value) / Double(max(fd.timescale, 1))
        var out: [MagicFrameKey] = []
        var seen = Set<Time>()
        for pts in times {
            let src = Time(Int64((pts * 1_000_000).rounded()), 1_000_000)
            let local = (clip.timelineTime(forSource: src, frameDuration: frameDuration) - clip.start).snapped(to: fd)
            guard local >= .zero, local < clip.duration, seen.insert(local).inserted else { continue }
            var key = MagicFrameKey(id: id(mask: mask.id, pts: pts), time: local, pts: pts, isCorrection: false, span: span)
            key.isCorrection = points.contains { key.holdsCorrection($0, anchor: anchor) }
            out.append(key)
        }
        return out.sorted { $0.time < $1.time }
    }

    /// The mask's id with the frame's time mixed into its last 8 bytes.
    static func id(mask: UUID, pts: Double) -> UUID {
        var u = mask.uuid
        let bits = UInt64(bitPattern: Int64((pts * 1_000_000).rounded()))
        withUnsafeMutableBytes(of: &u) { b in
            for i in 0 ..< 8 { b[8 + i] ^= UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i))) }
        }
        return UUID(uuid: u)
    }
}
