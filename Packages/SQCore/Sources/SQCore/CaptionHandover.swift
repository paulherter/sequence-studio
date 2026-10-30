import Foundation

/// Hand-over between neighboring captions of one caption track (ENGINE-NOTES "Caption hand-over"): two captions that
/// touch, or sit at most `gapFrames` frames apart, never leave a frame without a caption. The Program monitor and the
/// export burn-in both ask here, so they draw the same picture.
///
/// - The earlier caption holds through a small gap: its clip duration runs to the next caption's start (an out look
///   ends there).
/// - While the later caption's in-animation shows nothing or is still fading in, the earlier one stays under it as a
///   tail: at its end state, at `tailOpacity`. In-animations are never shortened or skipped.
/// - A caption with nothing that close before or after it is untouched: full in, full out.
public enum CaptionHandover {
    /// Largest gap (in sequence frames) two captions still hand over across.
    public static let gapFrames: Int64 = 2

    /// How a caption shows at one instant.
    public struct Resolution: Sendable, Hashable {
        /// The caption's clip duration for its animation: its own, or up to the start of the caption it hands over to.
        public var duration: Time
        /// The playhead is past the caption's own end, inside the small gap before the next caption.
        public var held: Bool
        /// The clip duration of the caption before it when that one hands over to this one (its start to this start);
        /// nil when there is no such caption.
        public var tailDuration: Time?
    }

    /// True when `b` follows `a` closely enough to hand over (never for overlapping ranges).
    public static func handsOver(_ a: TimeRange, to b: TimeRange, frameDuration: Time) -> Bool {
        let gap = b.start - a.end
        return gap >= .zero && gap <= max(frameDuration, .zero) * gapFrames
    }

    /// How `current` shows at `t`, given its neighbors on the track (`previous` ends before it, `next` starts after
    /// it); nil when it does not show at `t`.
    public static func resolve(previous: TimeRange?, current: TimeRange, next: TimeRange?, at t: Time,
                               frameDuration: Time) -> Resolution? {
        guard t >= current.start else { return nil }
        var end = current.end
        if let next, handsOver(current, to: next, frameDuration: frameDuration) { end = next.start }
        guard t < end else { return nil }
        var tail: Time?
        if let previous, handsOver(previous, to: current, frameDuration: frameDuration) { tail = current.start - previous.start }
        return Resolution(duration: end - current.start, held: t >= current.end, tailDuration: tail)
    }

    /// Opacity factor of the tail (the caption before, drawn at its end state under the entering caption) while the
    /// entering caption is at `clipTime`: one minus what the entering caption's in-animation covers. Zero when the
    /// caption before has an out look (it is gone at its end) or the entering one covers fully.
    /// `units`: the entering caption's animator units, asked for only when its look has a text animator.
    public static func tailOpacity(previous: AnimationSet?, entering: AnimationSet?, clipTime: Time,
                                   units: () -> TextUnits?) -> Double {
        guard previous?.animationOut == nil, let entering else { return 0 }
        return 1 - entering.entranceCoverage(clipTime: clipTime, units: units)
    }

    /// The clip time the entering caption is evaluated at. When the caption before ends in an out look (it is gone at
    /// its end, so nothing stays under the cut) and the entering caption's in-animation shows nothing on its first
    /// frame, that frame is evaluated one frame into the in-animation: the picture is never empty at a hand-over.
    /// Stored data and the out look stay as they are. Monitor and export burn-in both ask here.
    ///
    /// An in-animation that is still fully hidden one frame in (a delay, a slow ease) steps on to the first frame
    /// where the caption draws anything, at most `maxEnteringShiftFrames` frames in. Every frame before that one is
    /// drawn at that time too (held until the natural time catches up), so no empty frame follows a drawn one. When no
    /// frame within the cap draws, only the first frame is shifted, by one frame. Callers ask for frames with
    /// `clipTime < frameDuration * maxEnteringShiftFrames`.
    public static func enteringClipTime(previous: AnimationSet?, entering: AnimationSet?, clipTime: Time,
                                        frameDuration: Time, units: () -> TextUnits?) -> Time {
        guard previous?.animationOut != nil, let entering, frameDuration > .zero, clipTime >= .zero,
              clipTime < frameDuration * maxEnteringShiftFrames else { return clipTime }
        // Frame index of the natural time and the time of the caption's first frame on the same grid.
        var n: Int64 = 0
        while clipTime >= frameDuration * (n + 1) { n += 1 }
        let first = clipTime - frameDuration * n
        guard entering.entranceCoverage(clipTime: first, units: units) == 0 else { return clipTime }
        for k in Int64(1)...maxEnteringShiftFrames {
            let t = first + frameDuration * k
            if entering.entranceCoverage(clipTime: t, units: units) > 0 { return n < k ? t : clipTime }
        }
        return n == 0 ? first + frameDuration : clipTime
    }

    /// Most frames `enteringClipTime` steps into a hidden in-animation.
    public static let maxEnteringShiftFrames: Int64 = 3

    /// What one entering caption asks for at one frame: the clip time its look is evaluated at and how strongly the
    /// caption before is drawn under it (0: not drawn).
    public struct Draw: Sendable, Hashable {
        public var clipTime: Time
        public var tailOpacity: Double
    }

    /// The whole per-frame hand-over request of a caption that follows `previous` closely (`Resolution.tailDuration`
    /// is set): `enteringClipTime`, then `tailOpacity` at that time while the in-animation still runs. The Program
    /// monitor and the export burn-in both call this one function, so they cannot ask for different frames.
    /// `naturalClipTime`: the playhead's time since the caption's start.
    public static func draw(previous: AnimationSet?, entering: AnimationSet?, naturalClipTime: Time, frameDuration: Time,
                            units: () -> TextUnits?) -> Draw {
        var local = naturalClipTime
        if naturalClipTime < frameDuration * maxEnteringShiftFrames {
            local = enteringClipTime(previous: previous, entering: entering, clipTime: naturalClipTime,
                                     frameDuration: frameDuration, units: units)
        }
        guard let entering, local < entering.entranceEnd else { return Draw(clipTime: local, tailOpacity: 0) }
        return Draw(clipTime: local, tailOpacity: tailOpacity(previous: previous, entering: entering, clipTime: local, units: units))
    }
}

extension AnimationSet {
    /// Clip time from which the in-animation covers fully whatever the text is (`entranceCoverage` is 1 from here on,
    /// without asking for units): the end of its block tracks, and of a text animator's first unit (the unit that
    /// starts at zero; the block is there as soon as one unit shows). Zero without an in-animation and for a loop.
    /// A caller on a hot path checks this first and skips the hand-over work for the rest of the caption.
    public var entranceEnd: Time {
        guard let a = animationIn, !a.loops else { return .zero }
        var end = a.tracks.isEmpty ? Time.zero : max(a.duration, .zero)
        if let animator = a.textAnimator { end = max(end, animator.duration) }
        return end
    }

    /// How much of the block its in-animation shows at `clipTime`, 0 (nothing) ... 1 (all of it): the in-animation's
    /// opacity, 0 while its scale is zero, and 0 while a text animator shows no unit yet. A loop, an out look and a set
    /// without an in-animation cover fully. Position, rotation and a partial scale do not count: the block is there.
    public func entranceCoverage(clipTime: Time, units: () -> TextUnits?) -> Double {
        guard let a = animationIn, !a.loops, clipTime < entranceEnd else { return 1 }
        var block = 1.0
        if !a.tracks.isEmpty {
            let opacity = min(1, max(0, a.value(of: "opacity", at: clipTime) ?? 1))
            block = (a.value(of: "scale", at: clipTime) ?? 1) > 0 ? opacity : 0
        }
        guard block > 0, let animator = a.textAnimator, let u = units() else { return block }
        let n = u.count(of: animator.unit)
        guard n > 0 else { return block }
        for i in 0..<n {
            let s = animator.inState(ofUnit: i, count: n, at: clipTime)
            if s.opacity > 0, s.scale > 0 { return block }
        }
        return 0
    }
}

/// What one caption track shows at one instant (`Timeline.captionSlots(at:)`).
public struct CaptionSlot: Sendable, Hashable {
    public var item: CaptionItem
    public var track: CaptionTrack.ID
    /// Clip duration to animate `item` with, and whether the playhead is past its own end (`CaptionHandover.Resolution`).
    public var duration: Time
    public var held: Bool
    /// The caption before `item` when it hands over to it, with its clip duration: drawn under `item` at clip time
    /// `tailDuration` with `CaptionHandover.tailOpacity`.
    public var tail: CaptionItem?
    public var tailDuration: Time
}

extension CaptionItem {
    /// No visible text: such a caption is never drawn and never takes part in a hand-over.
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension CaptionTrack {
    /// The caption this track shows at `t` with its hand-over. Blank and zero-length captions do not exist here (the
    /// export burn-in leaves them out the same way). A track whose captions overlap (only a decoded file can hold
    /// one) shows the first caption containing `t` and hands nothing over, exactly like `CaptionBurnIn`.
    public func slot(at t: Time, frameDuration: Time) -> CaptionSlot? {
        Lookup(self).slot(at: t, frameDuration: frameDuration)
    }

    /// The track prepared for lookups: checking that its captions are in order is one pass over them, done once here
    /// instead of on every lookup (a tick asks five times: its frame and the look-ahead).
    struct Lookup: Sendable {
        let id: CaptionTrack.ID
        /// The captions to search, and whether they are in order (binary search, hand-over) or overlap (linear, none).
        let items: [CaptionItem]
        let ordered: Bool

        init(_ track: CaptionTrack) {
            id = track.id
            if CaptionTrack.isOrdered(track.items) { items = track.items; ordered = true; return }
            // Not sorted or overlapping as stored: what the burn-in is given (shown captions, by start).
            items = track.items.filter { !CaptionTrack.isHidden($0) }.sorted { $0.range.start < $1.range.start }
            ordered = CaptionTrack.isOrdered(items)
        }

        func slot(at t: Time, frameDuration: Time) -> CaptionSlot? {
            if ordered { return CaptionTrack.slot(in: items, track: id, at: t, frameDuration: frameDuration) }
            return items.first { $0.range.contains(t) }.map {
                CaptionSlot(item: $0, track: id, duration: $0.range.duration, held: false, tail: nil, tailDuration: .zero)
            }
        }
    }

    private static func isHidden(_ c: CaptionItem) -> Bool { c.range.isEmpty || c.isBlank }

    /// Starts never go back and no caption starts before the one before it ends (zero-length ones only keep the order).
    private static func isOrdered(_ items: [CaptionItem]) -> Bool {
        var start: Time?, end: Time?
        for c in items {
            if let start, c.range.start < start { return false }
            start = c.range.start
            guard !c.range.isEmpty else { continue }
            if let end, c.range.start < end { return false }
            end = c.range.end
        }
        return true
    }

    /// `items` ordered (`isOrdered`): binary search for the last start at or before `t`.
    private static func slot(in items: [CaptionItem], track: CaptionTrack.ID, at t: Time, frameDuration: Time) -> CaptionSlot? {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].range.start <= t { lo = mid + 1 } else { hi = mid }
        }
        var i = lo - 1
        while i >= 0, isHidden(items[i]) { i -= 1 }
        guard i >= 0 else { return nil }
        var n = i + 1
        while n < items.count, isHidden(items[n]) { n += 1 }
        var p = i - 1
        while p >= 0, isHidden(items[p]) { p -= 1 }
        guard let r = CaptionHandover.resolve(previous: p >= 0 ? items[p].range : nil, current: items[i].range,
                                              next: n < items.count ? items[n].range : nil, at: t,
                                              frameDuration: frameDuration) else { return nil }
        return CaptionSlot(item: items[i], track: track, duration: r.duration, held: r.held,
                           tail: r.tailDuration != nil ? items[p] : nil, tailDuration: r.tailDuration ?? .zero)
    }
}

extension Timeline {
    /// What every visible caption track shows at `t`, bottom track first, with the hand-over between neighboring
    /// captions (`CaptionHandover`). Unlike `captions(at:)` a caption also shows in a small gap before its neighbor,
    /// and blank captions are left out.
    public func captionSlots(at t: Time) -> [CaptionSlot] { CaptionSlotLookup(self).slots(at: t) }
}

/// `Timeline.captionSlots(at:)` for many times on one timeline (playback makes one per timeline change, not per tick):
/// the tracks are checked once, every lookup after that is a binary search.
public struct CaptionSlotLookup: Sendable {
    private let tracks: [CaptionTrack.Lookup]
    private let frameDuration: Time
    /// The timeline this was made from.
    public let timeline: Timeline.ID

    public init(_ timeline: Timeline) {
        self.timeline = timeline.id
        tracks = timeline.captionTracks.filter(\.isVisible).map(CaptionTrack.Lookup.init)
        frameDuration = timeline.format.frameDuration
    }

    public var isEmpty: Bool { tracks.allSatisfy(\.items.isEmpty) }

    public func slots(at t: Time) -> [CaptionSlot] {
        tracks.compactMap { $0.slot(at: t, frameDuration: frameDuration) }
    }
}
