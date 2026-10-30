import Foundation

// Item lanes: every item (layer) of a Graphic can show for only a part of the clip. `GraphicsLayer.range` is in the clip's
// local time, end exclusive, nil = the whole clip. Rules:
// - Render, export and the monitor hit test skip an item outside its range (one gate: `isShown(atLocal:)`).
// - Trimming the clip keeps every range on its frames and clamps it to the clip. A range that falls wholly outside stays
//   as an empty range at that edge: the item is never drawn but stays in the Graphic (its lane can be trimmed out again).
// - Cutting the clip (split, razor, overwrite and lift pieces: `Clip.cropped`) gives each piece the part of the range
//   inside it and drops an item with nothing left to show in that piece. That is the only place an item is dropped. A
//   piece never loses its last items: if nothing would be left, they all stay as empty-range stubs.
// - A retime scales ranges like keys. nil stays nil everywhere.
// - A text item's In and Out animation runs on its range (In when the item appears, Out when it disappears): evaluation
//   hands the text generator range-local time and the range's length. Keyframes stay on clip time.
// - Item keyframes follow the clip's own keys on every edit (`remapItemKeys`): they stay on their frames through a head
//   trim and a cut, scale with a retime and mirror with a reverse.
// - The halves of a cut keep the same item ids. Ids are only ever resolved inside one clip (selection is clip + items,
//   Follow targets are looked up in the item's own Graphic), like the copies a paste or a duplicate makes.

extension GraphicsLayer {
    /// The layer shows at clip-local `t`. Evaluation runs this per layer and frame: no allocation.
    @inline(__always)
    public func isShown(atLocal t: Time) -> Bool {
        guard let r = range else { return true }
        return t >= r.start && t < r.end
    }

    /// The time base of the item's text generator at clip-local `t`: THE one place that decides it. Render (evaluation's
    /// layer request), Follow's measure and the monitor's measure (outline, handles, hit test, align) all take it from
    /// here, so the picture and its box cannot run on different clocks.
    @inline(__always)
    public func textTime(atLocal t: Time) -> GraphicsTextTime {
        guard let r = range else { return GraphicsTextTime(local: t, duration: nil) }
        return GraphicsTextTime(local: t - r.start, duration: r.duration)
    }
}

/// When a text item's generator runs: `local` since the item appeared, `duration` how long it shows (nil = the clip's
/// length: the item has no range). In and Out animations are anchored to these.
public struct GraphicsTextTime: Sendable, Equatable {
    public var local: Time
    public var duration: Time?
    public init(local: Time, duration: Time? = nil) { self.local = local; self.duration = duration }
}

extension GraphicsDocument {
    /// Some layer has a range (gates ProjectFile v74 and the work in the clip hooks).
    public var hasItemRanges: Bool { layers.contains { $0.range != nil } }

    /// The part of a clip of `clipDuration` the layer shows in.
    public func shownRange(of layer: GraphicsLayer, clipDuration: Time) -> TimeRange {
        layer.range ?? TimeRange(start: .zero, duration: clipDuration)
    }

    /// `r` limited to 0..<`d`; a range wholly outside becomes an empty one at the nearer edge.
    static func clamped(_ r: TimeRange, to d: Time) -> TimeRange {
        let a = min(max(r.start, .zero), d), b = min(max(r.end, .zero), d)
        return TimeRange(start: a, end: max(a, b))
    }

    /// Clip trim: ranges move by `g` (the head grew by it) and are clamped to the new clip duration `d`.
    mutating func rebaseItemRanges(by g: Time, clipDuration d: Time) {
        for i in layers.indices {
            guard let r = layers[i].range else { continue }
            layers[i].range = GraphicsDocument.clamped(TimeRange(start: r.start + g, duration: r.duration), to: d)
        }
    }

    /// Clip cut: the piece from clip-local `a` lasting `d`. Ranges move into the piece; an item with nothing left to show
    /// there is removed (with its group and Follow links, like `remove`). A piece never ends up without items: when
    /// nothing would be left, every item stays with an empty range at its edge (the stub rule of a trim).
    func croppingItemRanges(from a: Time, duration d: Time) -> GraphicsDocument {
        guard hasItemRanges else { return self }
        var out = self
        var dropped: Set<UUID> = []
        for i in out.layers.indices {
            guard let r = out.layers[i].range else { continue }
            let c = GraphicsDocument.clamped(TimeRange(start: r.start - a, duration: r.duration), to: d)
            out.layers[i].range = c
            if c.isEmpty { dropped.insert(out.layers[i].id) }
        }
        if !dropped.isEmpty, dropped.count < out.layers.count { out.remove(dropped) }
        return out
    }

    /// Every item's key times (Motion, Opacity, effects) through `f`. Item keys are in the clip's local time like the
    /// clip's own keys, so every edit that moves the clip's keys moves them the same way (`Clip.remapVariantKeys`): a head
    /// trim and a cut keep them on their frames, a retime scales and a reverse mirrors them.
    mutating func remapItemKeys(_ f: (Time) -> Time) {
        for i in layers.indices {
            layers[i].animation = layers[i].animation.remapped(f)
            for j in layers[i].effects.indices { layers[i].effects[j] = layers[i].effects[j].remapped(f) }
        }
    }

    /// Retime: ranges scale with the clip from `old` to `new` duration; `mirror` flips them inside the clip.
    mutating func rescaleItemRanges(from old: Time, to new: Time, mirror: Bool) {
        for i in layers.indices {
            guard let r = layers[i].range else { continue }
            var a = Time.scaled(r.start, by: new, over: old), b = Time.scaled(r.end, by: new, over: old)
            if mirror { (a, b) = (new - b, new - a) }
            layers[i].range = GraphicsDocument.clamped(TimeRange(start: a, end: max(a, b)), to: new)
        }
    }

    // MARK: Editing (item lanes in the timeline)

    /// A range filling the clip is stored as nil, so the item keeps following the clip's trims.
    private static func normalized(_ r: TimeRange, clipDuration d: Time) -> TimeRange? {
        r.start <= .zero && r.end >= d ? nil : r
    }

    /// Moves the item's range so it starts at clip-local `start`, keeping its length and staying inside the clip.
    public mutating func moveItemRange(_ id: UUID, toStart start: Time, clipDuration d: Time) {
        guard let i = index(of: id), let r = layers[i].range, r.duration < d else { return }
        let a = min(max(start, .zero), d - r.duration)
        layers[i].range = Self.normalized(TimeRange(start: a, duration: r.duration), clipDuration: d)
    }

    /// Moves one edge of the item's range to clip-local `t`, inside the clip and never shorter than `minimum`.
    public mutating func trimItemRange(_ id: UUID, edge: ClipEdge, to t: Time, clipDuration d: Time, minimum: Time) {
        guard let i = index(of: id), d > .zero else { return }
        let r = shownRange(of: layers[i], clipDuration: d)
        let least = min(minimum, d)
        let out: TimeRange
        switch edge {
        case .head:
            let end = max(r.end, least)
            out = TimeRange(start: min(max(t, .zero), end - least), end: end)
        case .tail:
            let start = min(r.start, d - least)
            out = TimeRange(start: start, end: max(min(t, d), start + least))
        }
        layers[i].range = Self.normalized(out, clipDuration: d)
    }
}

extension Clip {
    /// After a trim that grew the head by `g` (0 for the tail): item ranges follow (no work without ranges).
    mutating func rebaseItemRanges(by g: Time) {
        guard graphicsStore?.hasItemRanges == true else { return }
        let d = duration
        graphicsStore?.rebaseItemRanges(by: g, clipDuration: d)
    }
}

extension GraphicsDocument {
    /// Item lane Cmd+V: gives every item in `ids` the range `r` (clamped to the clip; nil = whole clip).
    public mutating func setRange(_ r: TimeRange?, for ids: Set<UUID>, clipDuration d: Time) {
        let value = r.map { GraphicsDocument.clamped($0, to: d) }
        for i in layers.indices where ids.contains(layers[i].id) { layers[i].range = value }
    }
}
