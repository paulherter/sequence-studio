import Foundation
import Synchronization

// G11 Follow (docs/audits/GRAPHICS-PANEL-2026-10.md, Premiere's position pins under our own name). A layer's chosen edges
// stay at the same edges of another layer or of the frame, `padding` px apart: outside a layer (a box behind a title grows
// with it), inside the frame (a safe margin). Shapes and paths pinned on both edges of an axis take the target's extent;
// text layers only move (both edges = centered). Resolved per instant into static values, so playback, export and the
// Graphics overlay draw from the same `resolvingFollow` result. The stored layer is never changed.

/// Which edges of a layer follow. Stored in the project file as its raw value: never renumber.
public struct GraphicsEdges: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = GraphicsEdges(rawValue: 1)
    public static let top = GraphicsEdges(rawValue: 2)
    public static let right = GraphicsEdges(rawValue: 4)
    public static let bottom = GraphicsEdges(rawValue: 8)
    public static let all: GraphicsEdges = [.left, .top, .right, .bottom]
}

/// A layer pinned to another layer or to the frame. Stored in the project file (v63): never rename cases or labels.
public struct GraphicsFollow: Sendable, Hashable, Codable {
    public enum Target: Sendable, Hashable, Codable {
        /// The graphic's canvas (the sequence frame, or the format variant's).
        case frame
        /// Another layer of the same graphic. An unknown id draws the follower as authored.
        case layer(id: UUID)
    }
    public var target: Target
    public var edges: GraphicsEdges
    /// Canvas px between the follower's edge and the target's: outside a layer, inside the frame. Negative = the other way.
    public var padding: Double
    /// Padding per edge (v85); nil = `padding` on every edge. Stored only when the four values differ.
    public var edgePadding: GraphicsEdgePadding?

    public init(target: Target, edges: GraphicsEdges = .all, padding: Double = 0, edgePadding: GraphicsEdgePadding? = nil) {
        self.target = target; self.edges = edges; self.padding = padding; self.edgePadding = edgePadding
    }

    /// The four paddings in effect.
    public var resolvedPadding: GraphicsEdgePadding { edgePadding ?? GraphicsEdgePadding(all: padding) }

    /// Replaces one edge's padding; four equal values collapse back to the single `padding`.
    public mutating func setPadding(_ v: Double, for edge: GraphicsEdges) {
        var p = resolvedPadding
        if edge == .left { p.left = v } else if edge == .top { p.top = v }
        else if edge == .right { p.right = v } else if edge == .bottom { p.bottom = v } else { return }
        if p.left == p.top, p.top == p.right, p.right == p.bottom { padding = p.left; edgePadding = nil } else { edgePadding = p }
    }

    private enum CodingKeys: String, CodingKey { case target, edges, padding, edgePadding }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        target = try c.decode(Target.self, forKey: .target)
        edges = try c.decode(GraphicsEdges.self, forKey: .edges)
        padding = try c.decode(Double.self, forKey: .padding)
        edgePadding = try c.decodeIfPresent(GraphicsEdgePadding.self, forKey: .edgePadding)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target); try c.encode(edges, forKey: .edges); try c.encode(padding, forKey: .padding)
        if let edgePadding {
            try c.encode(edgePadding, forKey: .edgePadding)
            (e.userInfo[FollowEdgePaddingSeen.key] as? FollowEdgePaddingSeen)?.mark()   // v85 gate (`ProjectFile.encode`)
        }
    }
}

/// Canvas px per followed edge (v85).
public struct GraphicsEdgePadding: Sendable, Hashable, Codable {
    public var left: Double, top: Double, right: Double, bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public init(all v: Double) { self.init(left: v, top: v, right: v, bottom: v) }
}

/// Text bounds for Follow at evaluation time. SQCore cannot lay out text, so SQText installs this
/// (`TextGenerator.installFollowMeasure()`; the playback loop, the exporter and the Graphics editor call it). Same box as
/// the editor's `GraphicsTextMeasure`: the raster at the identity transform, offset from the canvas center.
public enum GraphicsTextBounds {
    /// `clip` + `layer`: the graphics clip and the text layer's id (a text not laid out yet may be stood in for by that
    /// layer's last measured text; layers of clips made from one template share ids, so the clip is part of the key).
    /// `exact`: lay the text out on the calling thread if needed (export); otherwise a text that is not laid out yet is
    /// never laid out on the caller (the render thread): the provider answers with a stand-in or nil and warms it in the
    /// background.
    public typealias Provider = @Sendable (_ ref: GeneratorRef, _ clip: UUID, _ layer: UUID, _ localTime: Time, _ clipDuration: Time,
                                           _ canvas: SequenceFormat, _ exact: Bool) -> GraphicsRect?
    private static let provider = Mutex<Provider?>(nil)

    public static func install(_ p: @escaping Provider) { provider.withLock { $0 = p } }
    public static var current: Provider? { provider.withLock { $0 } }

    /// True inside an evaluation that must measure every text (export): `$exact.withValue(true) { videoLayers(...) }`.
    /// Playback, prefetch and scopes evaluate with false (a text not laid out yet is measured later, never on their thread).
    @TaskLocal public static var exact = false

    /// The installed provider for one graphics clip (nil when none is installed: text targets then have no size).
    static func measure(clip: UUID, clipDuration: Time, canvas: SequenceFormat) -> GraphicsKeyedTextMeasure? {
        guard let m = current else { return nil }
        let exact = exact
        return { ref, layer, t in m(ref, clip, layer, t.local, t.duration ?? clipDuration, canvas, exact) }
    }
}

/// A text measure that also gets the text layer's id (evaluation's stand-in for a text not laid out yet).
typealias GraphicsKeyedTextMeasure = @Sendable (GeneratorRef, UUID, GraphicsTextTime) -> GraphicsRect?

extension GraphicsDocument {
    /// Longest follow chain that resolves (a layer following a layer following ... the frame). Deeper layers draw as authored.
    public static let maxFollowDepth = 16

    /// Any layer follows something (cheap: no allocation; evaluation checks it every frame).
    public var hasFollow: Bool { layers.contains { $0.follow.map { !$0.edges.isEmpty } ?? false } }

    /// The document as drawn at clip-local `t`: every following layer's position (and, for shapes, Width / Height) replaced
    /// by static values that put its edges at the target's. `canvas`: the graphic's canvas in px (frame target). Unchanged
    /// when nothing follows. Order: targets before their followers; cycles, chains deeper than `maxFollowDepth`, unknown
    /// targets and targets without a size (empty text, a switched-off shape) leave the follower as authored.
    public func resolvingFollow(atLocal t: Time, canvas: Vec2, text: GraphicsTextMeasure?) -> GraphicsDocument {
        guard hasFollow else { return self }
        var keyed: GraphicsKeyedTextMeasure?
        if let text { keyed = { ref, _, t in text(ref, t) } }
        return resolvingFollow(atLocal: t, canvas: canvas, keyed: keyed)
    }

    /// Evaluation's variant: the measure also gets the text layer's id.
    func resolvingFollow(atLocal t: Time, canvas: Vec2, keyed: GraphicsKeyedTextMeasure?) -> GraphicsDocument {
        resolvedFollow(atLocal: t, canvas: canvas, keyed: keyed).document
    }

    /// `resolvingFollow` plus the ids of the layers Follow actually placed (a follower of an empty or switched-off target,
    /// a cycle member or a too deep chain is not among them: it is drawn as authored).
    func resolvedFollow(atLocal t: Time, canvas: Vec2, keyed: GraphicsKeyedTextMeasure?)
        -> (document: GraphicsDocument, placed: Set<UUID>) {
        guard hasFollow else { return (self, []) }
        var placed = Set<UUID>()
        var out = self
        let frame = GraphicsRect(minX: -canvas.x / 2, minY: -canvas.y / 2, maxX: canvas.x / 2, maxY: canvas.y / 2)
        func text(_ l: GraphicsLayer) -> GraphicsTextMeasure? {
            guard l.isText, let keyed else { return nil }
            let id = l.id
            return { ref, t in keyed(ref, id, t) }
        }
        for (i, j) in followPlan() {
            guard let f = layers[i].follow else { continue }
            let ref: GraphicsRect
            if j < 0 { ref = frame } else {
                guard let b = out.layers[j].bounds(atLocal: t, text: text(out.layers[j])) else { continue }
                ref = b
            }
            out.layers[i].applyFollow(f, to: ref, inside: j < 0, atLocal: t, text: text(out.layers[i]))
            placed.insert(out.layers[i].id)
        }
        return (out, placed)
    }

    /// Runs a geometric edit (align, distribute, corner resize) on what is drawn at `t`: `body` edits the document with
    /// Follow resolved, then the result is carried back to the stored layers. A layer whose follow resolves keeps what
    /// Follow sets: its position on a pinned axis (left/right = x, top/bottom = y) and a stretched Width / Height; its
    /// other position changes (as an offset), Scale and the rest of its size are taken. Other layers take the result as is
    /// (they are drawn as stored). Plain `body` when nothing follows.
    public mutating func editingResolved(atLocal t: Time, canvas: Vec2, text: GraphicsTextMeasure?,
                                         _ body: (inout GraphicsDocument) -> Void) {
        guard hasFollow else { body(&self); return }
        var keyed: GraphicsKeyedTextMeasure?
        if let text { keyed = { ref, _, t in text(ref, t) } }
        let (before, placed) = resolvedFollow(atLocal: t, canvas: canvas, keyed: keyed)
        var after = before
        body(&after)
        var pinned: [UUID: GraphicsEdges] = [:]
        for (i, _) in followPlan() where placed.contains(layers[i].id) { pinned[layers[i].id] = layers[i].follow?.edges }
        var out = after
        for k in out.layers.indices {
            let id = out.layers[k].id
            guard let e = pinned[id], let stored = layer(id), let b = before.layer(id) else { continue }
            let a = out.layers[k]
            var l = stored
            if a != b {
                var d = a.animation.position.value(atLocal: t) - b.animation.position.value(atLocal: t)
                if !e.isDisjoint(with: [.left, .right]) { d.x = 0 }
                if !e.isDisjoint(with: [.top, .bottom]) { d.y = 0 }
                if d != .zero { l.animation.position = l.animation.position.offset(by: d) }
                l.animation.scale = a.animation.scale
                let stretch = !stored.isText && abs(stored.animation.rotation.value(atLocal: t)) < 1e-9
                if let ka = a.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }),
                   let ks = l.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }) {
                    if !(stretch && e.contains([.left, .right])) {
                        l.effects[ks].parameters[ClipEffect.shapeWidthKey] = a.effects[ka].parameters[ClipEffect.shapeWidthKey]
                    }
                    if !(stretch && e.contains([.top, .bottom])) {
                        l.effects[ks].parameters[ClipEffect.shapeHeightKey] = a.effects[ka].parameters[ClipEffect.shapeHeightKey]
                    }
                }
            }
            out.layers[k] = l
        }
        self = out
    }

    /// Monitor drag: moves `ids` (and their groups) by `delta`. A pinned layer's dragged axis (left/right = x, top/bottom =
    /// y) is unpinned: the layer first takes the place and stretched size Follow gives it at `t`, so it moves from where it is
    /// drawn; the other axis stays pinned. A follow left without edges is removed. Plain `translate` when nothing follows.
    public mutating func moveEditingResolved(_ ids: some Sequence<UUID>, by delta: Vec2, atLocal t: Time, canvas: Vec2,
                                             text: GraphicsTextMeasure?) {
        let all = Array(ids)
        guard hasFollow, delta != .zero else { translate(all, by: delta); return }
        var keyed: GraphicsKeyedTextMeasure?
        if let text { keyed = { ref, _, t in text(ref, t) } }
        let (shown, placed) = resolvedFollow(atLocal: t, canvas: canvas, keyed: keyed)
        for id in expanded(all) where placed.contains(id) {
            guard let i = index(of: id), !layers[i].isLocked, var f = layers[i].follow, let r = shown.layer(id) else { continue }
            var unpin: GraphicsEdges = []
            if delta.x != 0, !f.edges.isDisjoint(with: [.left, .right]) { unpin.formUnion([.left, .right]) }
            if delta.y != 0, !f.edges.isDisjoint(with: [.top, .bottom]) { unpin.formUnion([.top, .bottom]) }
            guard !unpin.isEmpty else { continue }
            var l = layers[i]
            let d = r.animation.position.value(atLocal: t) - l.animation.position.value(atLocal: t)
            if d != .zero { l.animation.position = l.animation.position.offset(by: d) }
            if let ks = l.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }),
               let kr = r.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }) {
                if f.edges.contains([.left, .right]), unpin.contains(.left) {
                    l.effects[ks].parameters[ClipEffect.shapeWidthKey] = r.effects[kr].parameters[ClipEffect.shapeWidthKey]
                }
                if f.edges.contains([.top, .bottom]), unpin.contains(.top) {
                    l.effects[ks].parameters[ClipEffect.shapeHeightKey] = r.effects[kr].parameters[ClipEffect.shapeHeightKey]
                }
            }
            f.edges.subtract(unpin)
            l.follow = f.edges.isEmpty ? nil : f
            layers[i] = l
        }
        translate(all, by: delta)
    }

    /// Layers `id` may follow without a cycle, front first (the Follows popup). Empty for an unknown id.
    public func followCandidates(for id: UUID) -> [GraphicsLayer] {
        guard index(of: id) != nil else { return [] }
        return layers.reversed().filter { $0.id != id && !leadsTo(id, from: $0.id) }
    }

    /// Following `from`'s chain reaches `id` (bounded by the layer count).
    private func leadsTo(_ id: UUID, from start: UUID) -> Bool {
        var cur = start
        for _ in 0...layers.count {
            guard case .layer(let next)? = layer(cur)?.follow?.target else { return false }
            if next == id { return true }
            cur = next
        }
        return false
    }

    /// (follower index, target index or -1 for the frame), targets first; only follows that resolve.
    func followPlan() -> [(Int, Int)] {
        let n = layers.count
        // -1 = none, -2 = frame, else the target's index.
        var target = [Int](repeating: -1, count: n)
        for i in 0..<n {
            guard let f = layers[i].follow, !f.edges.isEmpty else { continue }
            switch f.target {
            case .frame: target[i] = -2
            case .layer(let id): if let j = index(of: id), j != i { target[i] = j }
            }
        }
        // A cycle member's follow is ignored (each layer has at most one target, so a walk of n steps that does not return
        // to the start never will). Members are found against the raw targets, so the result does not depend on order.
        var eff = target
        for i in 0..<n where target[i] >= 0 {
            var k = target[i], steps = 0
            while k >= 0, k != i, steps < n { k = target[k]; steps += 1 }
            if k == i { eff[i] = -1 }
        }
        // Depth = links down to an anchor (the frame, or a layer that follows nothing that resolves).
        var plan: [(depth: Int, i: Int)] = []
        for i in 0..<n where eff[i] != -1 {
            var d = 1, k = eff[i]
            while k >= 0, eff[k] != -1, d <= n { d += 1; k = eff[k] }
            if d <= Self.maxFollowDepth { plan.append((d, i)) }
        }
        plan.sort { $0.depth != $1.depth ? $0.depth < $1.depth : $0.i < $1.i }
        return plan.map { ($0.i, eff[$0.i] == -2 ? -1 : eff[$0.i]) }
    }
}

extension GraphicsLayer {
    /// Puts the followed edges at `r` grown by the padding (`inside`: shrunk, the frame). Static values at `t` only.
    mutating func applyFollow(_ f: GraphicsFollow, to r: GraphicsRect, inside: Bool, atLocal t: Time,
                              text: GraphicsTextMeasure?) {
        let pad = f.resolvedPadding, sign = inside ? -1.0 : 1.0
        let want = GraphicsRect(minX: r.minX - sign * pad.left, minY: r.minY - sign * pad.top,
                                maxX: r.maxX + sign * pad.right, maxY: r.maxY + sign * pad.bottom)
        let e = f.edges
        let bothX = e.contains([.left, .right]), bothY = e.contains([.top, .bottom])
        // Size: shapes and paths stretch to the extent in their own (unscaled) px; a line keeps its thickness. A rotated
        // layer only moves (its box is not its Width x Height, so sizing would not fit the target).
        if !isText, bothX || bothY, abs(animation.rotation.value(atLocal: t)) < 1e-9, let st = shapeStyle(atLocal: t),
           let k = effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }) {
            let s = animation.scale.value(atLocal: t)
            let isLine = st.kind == .line && st.path == nil
            if bothX, s.x > 1e-6 {
                effects[k].parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(max(want.width / s.x, 1))
            }
            if bothY, !isLine, s.y > 1e-6 {
                effects[k].parameters[ClipEffect.shapeHeightKey] = AnimatedProperty(max(want.height / s.y, 1))
            }
        }
        // Position: the bounding box (Motion applied) moves onto the followed edges; both edges = centered.
        guard let b = bounds(atLocal: t, text: text) else { return }
        var d = Vec2.zero
        if bothX { d.x = want.midX - b.midX } else if e.contains(.left) { d.x = want.minX - b.minX }
        else if e.contains(.right) { d.x = want.maxX - b.maxX }
        if bothY { d.y = want.midY - b.midY } else if e.contains(.top) { d.y = want.minY - b.minY }
        else if e.contains(.bottom) { d.y = want.maxY - b.maxY }
        animation.position = AnimatedProperty(animation.position.value(atLocal: t) + d)
    }
}
