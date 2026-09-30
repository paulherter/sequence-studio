import CoreGraphics
import Foundation
import SSCore

/// Limits for time edits (clip-local times).
public struct GraphEditLimits: Sendable, Equatable {
    public var frameDuration: Time
    public var minTime: Time
    public var maxTime: Time?
    public init(frameDuration: Time, minTime: Time = .zero, maxTime: Time? = nil) {
        self.frameDuration = frameDuration; self.minTime = minTime; self.maxTime = maxTime
    }
}

/// Pure edit math for the keyframe graph. Every function takes the track as it was at mouse-down (`base`)
/// and returns the new track, so a drag never accumulates rounding.
public enum KeyframeGraphEditing {
    /// Smallest time influence a dragged handle can have. dx == 0 would collapse the handle onto its key
    /// (and lose the speed value in the speed graph), so the drag stops just short of it.
    public static let minInfluence = 0.01

    /// Moves all selected keys by the same frame-snapped delta. The anchor key decides the snap.
    /// The group is clamped so it never crosses or touches a non-selected neighbour (one frame apart at least)
    /// and stays within `limits`.
    public static func moveKeys(base: KeyframeTrack<Double>, selected: Set<UUID>, anchor: UUID,
                                deltaSeconds: Double, limits: GraphEditLimits) -> KeyframeTrack<Double> {
        guard let anchorKey = base.key(id: anchor), selected.contains(anchor) else { return base }
        let fd = limits.frameDuration
        let fdSecs = GraphMath.seconds(fd)
        let frames = ((GraphMath.seconds(anchorKey.time) + deltaSeconds) / fdSecs).rounded()
        guard frames.isFinite, abs(frames) < 1e12 else { return base }
        var delta = Time.frames(Int64(frames), frameDuration: fd) - anchorKey.time

        var lo: Time?, hi: Time?
        func tighten(lo l: Time? = nil, hi h: Time? = nil) {
            if let l { lo = lo.map { max($0, l) } ?? l }
            if let h { hi = hi.map { min($0, h) } ?? h }
        }
        let keys = base.keys
        for (i, k) in keys.enumerated() where selected.contains(k.id) {
            tighten(lo: limits.minTime - k.time)
            if let m = limits.maxTime { tighten(hi: m - k.time) }
            if i > 0, !selected.contains(keys[i - 1].id) { tighten(lo: keys[i - 1].time + fd - k.time) }
            if i + 1 < keys.count, !selected.contains(keys[i + 1].id) { tighten(hi: keys[i + 1].time - fd - k.time) }
        }
        if let l = lo, let h = hi, l > h { return base }
        if let l = lo { delta = max(delta, l) }
        if let h = hi { delta = min(delta, h) }
        if delta == .zero { return base }

        return KeyframeTrack(keys: keys.map { k in
            var k = k
            if selected.contains(k.id) { k.time = k.time + delta }
            return k
        })
    }

    /// Adds `delta` to the value of every selected key (relative multi-key editing).
    public static func offsetValues(base: KeyframeTrack<Double>, selected: Set<UUID>, delta: Double) -> KeyframeTrack<Double> {
        guard delta != 0, delta.isFinite else { return base }
        var t = base
        for id in selected { t.update(id) { $0.value += delta } }
        return t
    }

    /// Converts a handle dragged to `target` (graph data space) to an SSCore handle.
    /// Value graph: dx = time fraction of the segment, dy = value fraction of the segment delta.
    /// Speed graph: influence from time, speed from the vertical position, converted with
    /// `EaseHandle(speedHandle:valueDelta:duration:)`. dx is clamped to `minInfluence...1`, dy is free.
    /// A segment with zero value delta keeps dy (value graph) or gets dy 0 (speed graph; speed is meaningless there).
    public static func dragHandle(base: KeyframeTrack<Double>, keyID: UUID, side: GraphHandleSide,
                                  to target: GraphDataPoint, mode: GraphMode) -> KeyframeTrack<Double> {
        guard let i = base.keys.firstIndex(where: { $0.id == keyID }) else { return base }
        let segIndex = side == .outSide ? i : i - 1
        guard let s = GraphMath.segment(base, from: segIndex), s.a.interpolation != .hold else { return base }
        let secs = GraphMath.seconds(s.dur)
        guard secs > 0 else { return base }
        let k = base.keys[i]

        let timeOffset = side == .outSide ? target.seconds - GraphMath.seconds(k.time)
                                          : GraphMath.seconds(k.time) - target.seconds
        let influence = min(max(timeOffset / secs, minInfluence), 1)
        let old = side == .outSide ? s.a.outHandle : s.b.inHandle

        let handle: EaseHandle
        switch mode {
        case .value:
            let dy: Double
            if s.delta == 0 {
                dy = old.dy
            } else {
                dy = (side == .outSide ? target.value - k.value : k.value - target.value) / s.delta
            }
            handle = EaseHandle(dx: influence, dy: dy)
        case .speed:
            handle = EaseHandle(speedHandle: SpeedHandle(speed: target.value, influence: influence),
                                valueDelta: s.delta, duration: s.dur)
        }
        guard handle.dx.isFinite, handle.dy.isFinite else { return base }

        var t = base
        t.update(keyID) {
            if side == .outSide { $0.outHandle = handle } else { $0.inHandle = handle }
            if $0.interpolation == .linear { $0.interpolation = .bezier }
        }
        return t
    }
}

// MARK: - Gesture reducer

/// One mouse gesture (down, drag..., up). Pure: the view feeds it points and applies the results.
public struct GraphGestureState: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case key(UUID)
        case handle(UUID, GraphHandleSide)
        case marquee(additive: Bool)
        /// Click on a segment or a toggled-off key: no drag.
        case none
    }

    public static let dragThreshold: CGFloat = 3

    public private(set) var kind: Kind
    public let origin: CGPoint
    public let base: KeyframeTrack<Double>
    public let baseSelection: Set<UUID>
    /// Geometry frozen at mouse-down (the graph must not rescale while dragging).
    public let geometry: KeyframeGraphGeometry
    public let limits: GraphEditLimits
    public private(set) var moved = false
    /// Plain press on an already-selected key: a click without drag collapses the selection to it.
    private var collapseTo: UUID?
    private var selection: Set<UUID>

    public struct Result: Sendable, Equatable {
        public var selection: Set<UUID>
        /// Preview track (equals the base until something changed).
        public var track: KeyframeTrack<Double>
        public var marquee: CGRect?
        /// True on `end` when the gesture changed the track: call `onEdit` once.
        public var commit: Bool
    }

    public init(at p: CGPoint, shift: Bool, geometry: KeyframeGraphGeometry, track: KeyframeTrack<Double>,
                selection: Set<UUID>, limits: GraphEditLimits) {
        self.origin = p; self.base = track; self.baseSelection = selection
        self.geometry = geometry; self.limits = limits
        self.selection = selection
        switch geometry.hitTest(p, track: track, selected: selection) {
        case .handle(let id, let side):
            kind = .handle(id, side)
        case .key(let id):
            if shift {
                if selection.contains(id) { self.selection.remove(id); kind = .none }
                else { self.selection.insert(id); kind = .key(id) }
            } else {
                if selection.contains(id) { collapseTo = id } else { self.selection = [id] }
                kind = .key(id)
            }
        case .segment(let a, let b):
            self.selection = shift ? selection.union([a, b]) : [a, b]
            kind = .none
        case .empty:
            if !shift { self.selection = [] }
            kind = .marquee(additive: shift)
        }
    }

    public var current: Result { Result(selection: selection, track: base, marquee: nil, commit: false) }

    public mutating func drag(to p: CGPoint) -> Result {
        if !moved {
            guard hypot(p.x - origin.x, p.y - origin.y) >= Self.dragThreshold else { return current }
            moved = true
        }
        switch kind {
        case .key(let id):
            let dxSecs = Double(p.x - origin.x) / geometry.pointsPerSecond
            var t = KeyframeGraphEditing.moveKeys(base: base, selected: selection, anchor: id,
                                                  deltaSeconds: dxSecs, limits: limits)
            if geometry.mode == .value {
                let dv = geometry.value(atY: p.y) - geometry.value(atY: origin.y)
                t = KeyframeGraphEditing.offsetValues(base: t, selected: selection, delta: dv)
            }
            return Result(selection: selection, track: t, marquee: nil, commit: false)
        case .handle(let id, let side):
            guard let hp = geometry.handlePoint(track: base, keyID: id, side: side) else { return current }
            // Keep the grab offset: the handle follows the pointer's movement, it does not jump under it.
            let target = geometry.data(CGPoint(x: hp.x + p.x - origin.x, y: hp.y + p.y - origin.y))
            let t = KeyframeGraphEditing.dragHandle(base: base, keyID: id, side: side, to: target, mode: geometry.mode)
            return Result(selection: selection, track: t, marquee: nil, commit: false)
        case .marquee(let additive):
            let rect = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                              width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            let hit = geometry.keys(in: rect, track: base)
            selection = additive ? baseSelection.union(hit) : hit
            return Result(selection: selection, track: base, marquee: rect, commit: false)
        case .none:
            return current
        }
    }

    /// Finishes the gesture. `commit` is true only if the track differs from the base.
    public mutating func end(at p: CGPoint) -> Result {
        var r = drag(to: p)
        if !moved, let id = collapseTo { selection = [id] }
        r.selection = selection
        r.marquee = nil
        r.commit = moved && r.track != base
        return r
    }
}
