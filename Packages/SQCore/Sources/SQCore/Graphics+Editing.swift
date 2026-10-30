import Foundation

/// An axis-aligned rectangle in a graphic's canvas px: offset from the canvas center, y down.
public struct GraphicsRect: Sendable, Hashable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public func union(_ o: GraphicsRect) -> GraphicsRect {
        GraphicsRect(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }
    public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
}

/// Measures a text layer: the rectangle its raster covers at the identity transform (offset from the canvas center), at
/// the item's text time (`GraphicsLayer.textTime(atLocal:)`: range-local for an item with a range, as render draws it).
/// Supplied by SQText's owner (SQCore cannot lay out text).
public typealias GraphicsTextMeasure = @Sendable (GeneratorRef, GraphicsTextTime) -> GraphicsRect?

public enum GraphicsAlign: String, Sendable, CaseIterable {
    case left, centerX, right, top, centerY, bottom
}

public enum GraphicsAxis: Sendable { case horizontal, vertical }

public enum GraphicsReorder: Sendable { case forward, backward, front, back }
/// A corner handle of a layer's box, in `GraphicsLayer.corners` order.
public enum GraphicsCorner: Int, Sendable, CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft
    /// Side of the content center the corner is on (x, y: -1 or 1).
    var sign: (x: Double, y: Double) {
        switch self {
        case .topLeft: (-1, -1)
        case .topRight: (1, -1)
        case .bottomRight: (1, 1)
        case .bottomLeft: (-1, 1)
        }
    }
    public var opposite: GraphicsCorner { GraphicsCorner(rawValue: (rawValue + 2) % 4)! }
}

extension GraphicsDocument {
    // MARK: Layers

    /// Adds `layer` on top (or right above `above`). Returns its ID.
    @discardableResult
    public mutating func add(_ layer: GraphicsLayer, above: UUID? = nil) -> UUID {
        if let above, let i = index(of: above) { layers.insert(layer, at: i + 1) } else { layers.append(layer) }
        return layer.id
    }

    /// Removes layers; a group left with fewer than two members dissolves, and a layer that followed a removed one is
    /// unpinned (G11).
    public mutating func remove(_ ids: Set<UUID>) {
        layers.removeAll { ids.contains($0.id) }
        for i in layers.indices {
            if case .layer(let t)? = layers[i].follow?.target, ids.contains(t) { layers[i].follow = nil }
        }
        pruneGroups()
    }

    /// Copies each layer right above its original, with fresh IDs and outside any group. Returns the copies' IDs. A copy
    /// that followed another layer of the same set follows that layer's copy (G11); other targets stay.
    @discardableResult
    public mutating func duplicate(_ ids: [UUID]) -> [UUID] {
        var out: [UUID] = []
        var copyOf: [UUID: UUID] = [:]
        for id in ids {
            guard copyOf[id] == nil, let i = index(of: id) else { continue }
            var c = layers[i]
            c.id = UUID(); c.group = nil; c.name = layers[i].name + " copy"
            c.animation.position = c.animation.position.withFreshKeyIDs()
            c.animation.scale = c.animation.scale.withFreshKeyIDs()
            c.animation.rotation = c.animation.rotation.withFreshKeyIDs()
            c.animation.opacity = c.animation.opacity.withFreshKeyIDs()
            c.animation.anchor = c.animation.anchor.withFreshKeyIDs()
            c.effects = c.effects.map { var e = $0; e.id = UUID(); return e }
            layers.insert(c, at: i + 1)
            out.append(c.id)
            copyOf[id] = c.id
        }
        for cid in out {
            guard let i = index(of: cid), case .layer(let t)? = layers[i].follow?.target, let nt = copyOf[t] else { continue }
            layers[i].follow?.target = .layer(id: nt)
        }
        return out
    }

    public mutating func update(_ id: UUID, _ body: (inout GraphicsLayer) -> Void) {
        guard let i = index(of: id) else { return }
        body(&layers[i])
    }

    // MARK: Groups

    /// `ids` plus every member of a group one of them belongs to.
    public func expanded(_ ids: some Sequence<UUID>) -> Set<UUID> {
        let set = Set(ids)
        let gs = Set(layers.filter { set.contains($0.id) }.compactMap(\.group))
        return set.union(layers.filter { $0.group.map(gs.contains) ?? false }.map(\.id))
    }

    /// Groups the layers (with the groups they already belong to) under a new group; the members are gathered right below the
    /// topmost one, keeping their order. nil (nothing changed) for fewer than two layers.
    @discardableResult
    public mutating func group(_ ids: some Sequence<UUID>, name: String) -> UUID? {
        let members = expanded(ids)
        guard members.count >= 2, let top = layers.lastIndex(where: { members.contains($0.id) }) else { return nil }
        let g = GraphicsGroup(name: name)
        let old = Set(layers.filter { members.contains($0.id) }.compactMap(\.group))
        groups.removeAll { old.contains($0.id) }
        groups.append(g)
        let moving = layers.filter { members.contains($0.id) }.map { l -> GraphicsLayer in var m = l; m.group = g.id; return m }
        let below = layers[..<top].filter { !members.contains($0.id) }
        let above = layers[(top + 1)...].filter { !members.contains($0.id) }
        layers = below + moving + above
        return g.id
    }

    public mutating func ungroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for i in layers.indices where layers[i].group == id { layers[i].group = nil }
    }

    private mutating func pruneGroups() {
        var count: [UUID: Int] = [:]
        for l in layers { if let g = l.group { count[g, default: 0] += 1 } }
        let dead = Set(groups.map(\.id).filter { (count[$0] ?? 0) < 2 })
        guard !dead.isEmpty else { return }
        groups.removeAll { dead.contains($0.id) }
        for i in layers.indices where layers[i].group.map(dead.contains) ?? false { layers[i].group = nil }
    }

    /// The selection as units that move together: each group touched is one unit, every other layer its own. Bottom first.
    public func units(_ ids: some Sequence<UUID>) -> [[UUID]] {
        let set = Set(ids)
        var out: [[UUID]] = []
        var seen = Set<UUID>()
        let touched = Set(layers.filter { set.contains($0.id) }.compactMap(\.group))
        for l in layers where set.contains(l.id) || (l.group.map(touched.contains) ?? false) {
            if let g = l.group {
                guard !seen.contains(g) else { continue }
                seen.insert(g)
                out.append(layers.filter { $0.group == g }.map(\.id))
            } else {
                out.append([l.id])
            }
        }
        return out
    }

    // MARK: Order

    /// Moves the layers (whole groups when a member is named) one step or all the way up or down, keeping their order.
    public mutating func reorder(_ ids: some Sequence<UUID>, _ how: GraphicsReorder) {
        let set = expanded(ids)
        guard !set.isEmpty else { return }
        let rest = layers.filter { !set.contains($0.id) }
        switch how {
        case .front: move(set, toIndex: rest.count)
        case .back: move(set, toIndex: 0)
        case .forward, .backward:
            // One step = past the next unit (a group counts as one) above / below the selection.
            guard let lo = layers.firstIndex(where: { set.contains($0.id) }),
                  let hi = layers.lastIndex(where: { set.contains($0.id) }) else { return }
            let below = layers[..<lo].filter { !set.contains($0.id) }.count
            var target: Int
            if how == .forward {
                guard hi + 1 < layers.count else { return }
                let next = layers[hi + 1]
                let size = next.group.map { g in layers.filter { $0.group == g && !set.contains($0.id) }.count } ?? 1
                target = layers[...hi].filter { !set.contains($0.id) }.count + size
            } else {
                guard lo > 0 else { return }
                let prev = layers[lo - 1]
                let size = prev.group.map { g in layers.filter { $0.group == g && !set.contains($0.id) }.count } ?? 1
                target = below - size
            }
            target = min(max(target, 0), rest.count)
            move(set, toIndex: target)
        }
    }

    /// Moves the layers to `index` of the list without them (0 = bottom), keeping their order.
    public mutating func move(_ ids: some Sequence<UUID>, toIndex index: Int) {
        let set = Set(ids)
        let moving = layers.filter { set.contains($0.id) }
        var rest = layers.filter { !set.contains($0.id) }
        rest.insert(contentsOf: moving, at: min(max(index, 0), rest.count))
        layers = rest
    }

    /// Layer list drag: moves the layers to `index` (as `move`) and puts them into `group` (nil or an unknown id = out of
    /// any group). A group left with fewer than two members dissolves.
    public mutating func move(_ ids: some Sequence<UUID>, toIndex index: Int, group: UUID?) {
        let set = Set(ids)
        move(set, toIndex: index)
        let g = group.flatMap { g in groups.contains { $0.id == g } ? g : nil }
        for i in layers.indices where set.contains(layers[i].id) { layers[i].group = g }
        pruneGroups()
    }

    /// Option-drag in the layer list: copies of the layers go where `move(_:toIndex:group:)` would put the layers (`index`
    /// counts the list without them); the originals stay. Copies of a whole group form a new group "<name> copy". Returns
    /// the copies' IDs, bottom first.
    @discardableResult
    public mutating func copy(_ ids: some Sequence<UUID>, toIndex index: Int, group: UUID?) -> [UUID] {
        let set = Set(ids)
        let originals = layers.filter { set.contains($0.id) }.map(\.id)
        guard !originals.isEmpty else { return [] }
        let rest = layers.filter { !set.contains($0.id) }
        let anchor = rest.indices.contains(index) ? rest[index].id : nil
        var work = self
        let copies = work.duplicate(originals)
        var made = copies.compactMap { work.layer($0) }
        var g = group.flatMap { g in groups.contains { $0.id == g } ? g : nil }
        if let own = g, Set(layers.filter { $0.group == own }.map(\.id)) == set {
            let n = GraphicsGroup(name: (self.group(own)?.name ?? "Group") + " copy")
            groups.append(n)
            g = n.id
        }
        for i in made.indices { made[i].group = g }
        let at = anchor.flatMap { a in layers.firstIndex { $0.id == a } } ?? layers.count
        layers.insert(contentsOf: made, at: at)
        pruneGroups()
        return copies
    }

    /// Renames a group (trimmed; an empty name is ignored).
    public mutating func renameGroup(_ id: UUID, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = n
    }

    // MARK: Moving, bounds, align, distribute

    /// Moves the layers (and their groups' other members) by `delta` canvas px; a keyed position moves with all its keys.
    /// Locked layers stay.
    public mutating func translate(_ ids: some Sequence<UUID>, by delta: Vec2) {
        let set = expanded(ids)
        for i in layers.indices where set.contains(layers[i].id) && !layers[i].isLocked {
            layers[i].animation.position = layers[i].animation.position.offset(by: delta)
        }
    }

    /// The layer's on-canvas bounding box at clip-local `t` (Motion applied). nil when it has no size: an empty shape, or a
    /// text layer without `text` measure.
    public func bounds(of id: UUID, atLocal t: Time, text: GraphicsTextMeasure? = nil) -> GraphicsRect? {
        guard let l = layer(id) else { return nil }
        return l.bounds(atLocal: t, text: text)
    }

    /// Aligns the selection: one unit (one layer or one group) to the canvas, several to their joint bounds.
    /// `toFrame`: every unit aligns to the canvas on its own, also when there are several.
    public mutating func align(_ ids: some Sequence<UUID>, _ edge: GraphicsAlign, canvas: Vec2, atLocal t: Time = .zero,
                               text: GraphicsTextMeasure? = nil, toFrame: Bool = false) {
        let us = units(ids).compactMap { u in unitBounds(u, t, text).map { (u, $0) } }
        guard !us.isEmpty else { return }
        let ref = us.count == 1 || toFrame
            ? GraphicsRect(minX: -canvas.x / 2, minY: -canvas.y / 2, maxX: canvas.x / 2, maxY: canvas.y / 2)
            : us.dropFirst().reduce(us[0].1) { $0.union($1.1) }
        for (u, b) in us {
            let d: Vec2 = switch edge {
            case .left: Vec2(ref.minX - b.minX, 0)
            case .centerX: Vec2(ref.midX - b.midX, 0)
            case .right: Vec2(ref.maxX - b.maxX, 0)
            case .top: Vec2(0, ref.minY - b.minY)
            case .centerY: Vec2(0, ref.midY - b.midY)
            case .bottom: Vec2(0, ref.maxY - b.maxY)
            }
            if d != .zero { translateUnit(u, by: d) }
        }
    }

    /// Spreads three or more units so the gaps between them are equal; the outermost two stay.
    public mutating func distribute(_ ids: some Sequence<UUID>, _ axis: GraphicsAxis, atLocal t: Time = .zero,
                                    text: GraphicsTextMeasure? = nil) {
        let h = axis == .horizontal
        var us = units(ids).compactMap { u in unitBounds(u, t, text).map { (u, $0) } }
        guard us.count >= 3 else { return }
        us.sort { h ? $0.1.midX < $1.1.midX : $0.1.midY < $1.1.midY }
        let lo = h ? us.first!.1.minX : us.first!.1.minY
        let hi = h ? us.map(\.1.maxX).max()! : us.map(\.1.maxY).max()!
        let sizes = us.map { h ? $0.1.width : $0.1.height }
        let gap = (hi - lo - sizes.reduce(0, +)) / Double(us.count - 1)
        var cursor = lo
        for (k, (u, b)) in us.enumerated() {
            let start = h ? b.minX : b.minY
            if k > 0, k < us.count - 1 {
                let d = cursor - start
                if d != 0 { translateUnit(u, by: h ? Vec2(d, 0) : Vec2(0, d)) }
            }
            cursor += sizes[k] + gap
        }
    }

    private func unitBounds(_ u: [UUID], _ t: Time, _ text: GraphicsTextMeasure?) -> GraphicsRect? {
        let rs = u.compactMap { bounds(of: $0, atLocal: t, text: text) }
        guard let first = rs.first else { return nil }
        return rs.dropFirst().reduce(first) { $0.union($1) }
    }

    private mutating func translateUnit(_ u: [UUID], by d: Vec2) {
        let set = Set(u)
        for i in layers.indices where set.contains(layers[i].id) && !layers[i].isLocked {
            layers[i].animation.position = layers[i].animation.position.offset(by: d)
        }
    }

    /// Corner handle drag: the layer's `corner` goes to canvas point `p`, the opposite corner stays. Shapes and paths change
    /// Width x Height (a line only its length; `keepAspect`: both by one factor), text changes its Scale uniformly. Keyed
    /// properties get a key at `t`. Locked layers and layers without a size stay.
    public mutating func resize(_ id: UUID, corner: GraphicsCorner, to p: Vec2, atLocal t: Time, keepAspect: Bool = false,
                                text: GraphicsTextMeasure? = nil) {
        guard let i = index(of: id), !layers[i].isLocked, let r = layers[i].contentRect(atLocal: t, text: text) else { return }
        var l = layers[i]
        let m = l.motion(atLocal: t)
        let c = Vec2(r.midX, r.midY), hw = r.width / 2, hh = r.height / 2
        let o = corner.opposite.sign, k = corner.sign
        let fixed = m.apply(c, Vec2(o.x * hw, o.y * hh))
        // Pointer relative to the fixed corner, in the layer's rotated frame (scaled px).
        let d = m.unrotate(p - fixed)
        let sx = max(abs(m.scale.x), 1e-6), sy = max(abs(m.scale.y), 1e-6)
        if l.isText {
            let diag = Vec2(k.x * r.width * sx, k.y * r.height * sy)
            let len2 = diag.x * diag.x + diag.y * diag.y
            guard len2 > 0 else { return }
            let f = max((d.x * diag.x + d.y * diag.y) / len2, 0.01)
            let s1 = m.scale * f
            l.animation.scale.set(s1, atLocal: t)
            var m1 = m; m1.scale = s1
            l.animation.position.set(m.position + fixed - m1.apply(c, Vec2(o.x * hw, o.y * hh)), atLocal: t)
        } else {
            guard let st = l.shapeStyle(atLocal: t) else { return }
            let isLine = st.kind == .line && st.path == nil
            var w = max(k.x * d.x / sx, 1), h = isLine ? st.height : max(k.y * d.y / sy, 1)
            if keepAspect, r.width > 0, r.height > 0 {
                let f = isLine ? w / r.width : max((k.x * d.x / sx) / r.width, (k.y * d.y / sy) / r.height)
                w = max(r.width * f, 1); h = isLine ? st.height : max(r.height * f, 1)
            }
            guard let e = l.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }) else { return }
            Self.setParam(&l.effects[e], ClipEffect.shapeWidthKey, w, t)
            if !isLine { Self.setParam(&l.effects[e], ClipEffect.shapeHeightKey, h, t) }
            let hh1 = isLine ? hh : h / 2
            let q = Vec2(o.x * w / 2, o.y * hh1)
            l.animation.position.set(m.position + fixed - m.apply(.zero, q), atLocal: t)
        }
        layers[i] = l
    }

    private static func setParam(_ e: inout ClipEffect, _ key: String, _ v: Double, _ t: Time) {
        var prop = e.parameters[key] ?? AnimatedProperty(v)
        prop.set(v, atLocal: t)
        e.parameters[key] = prop
    }

    /// The topmost visible, unlocked layer whose bounds contain canvas point `p` at clip-local `t` (selection click).
    /// A locked layer cannot be picked on the monitor.
    public func hitTest(_ p: Vec2, atLocal t: Time, text: GraphicsTextMeasure? = nil) -> UUID? {
        hitStack(p, atLocal: t, text: text).first
    }

    /// Every pickable layer under `p`, topmost first (the list order of a deep select).
    public func hitStack(_ p: Vec2, atLocal t: Time, text: GraphicsTextMeasure? = nil) -> [UUID] {
        layers.reversed().filter {
            $0.isVisible && !$0.isLocked && $0.isShown(atLocal: t) && ($0.bounds(atLocal: t, text: text)?.contains(p) ?? false)
        }.map(\.id)
    }

    /// Marquee: every pickable layer whose bounds touch `rect` (canvas px).
    public func layers(touching rect: GraphicsRect, atLocal t: Time, text: GraphicsTextMeasure? = nil) -> Set<UUID> {
        Set(layers.filter { l in
            guard l.isVisible, !l.isLocked, l.isShown(atLocal: t), let b = l.bounds(atLocal: t, text: text) else { return false }
            return b.minX <= rect.maxX && b.maxX >= rect.minX && b.minY <= rect.maxY && b.maxY >= rect.minY
        }.map(\.id))
    }

    /// Deep select: the next layer under `p` below `current` (the one the last click picked); wraps to the top. Without
    /// `current` in the stack it is the topmost.
    public func hitBelow(_ current: UUID?, at p: Vec2, atLocal t: Time, text: GraphicsTextMeasure? = nil) -> UUID? {
        let stack = hitStack(p, atLocal: t, text: text)
        guard let current, let i = stack.firstIndex(of: current) else { return stack.first }
        return stack[(i + 1) % stack.count]
    }

    /// Where Select Layer Above / Below goes from `selection`: one step from the topmost (up) or lowest (down) selected
    /// layer; with nothing selected the top (up) or bottom (down) pickable layer.
    public func stepTarget(from selection: Set<UUID>, up: Bool) -> UUID? {
        let idx = selection.compactMap { index(of: $0) }
        guard let edge = up ? idx.max() : idx.min() else {
            return (up ? layers.reversed() : layers).first { $0.isVisible && !$0.isLocked }?.id
        }
        return neighbor(of: layers[edge].id, up: up)
    }

    /// The layer one step above (`up`) or below `id` in the stack that is visible and unlocked; nil at the end.
    public func neighbor(of id: UUID, up: Bool) -> UUID? {
        guard let i = index(of: id) else { return nil }
        let rest = up ? Array(layers[(i + 1)...]) : Array(layers[..<i].reversed())
        return rest.first { $0.isVisible && !$0.isLocked }?.id
    }
}

extension GraphicsLayer {
    /// The content's rectangle at the identity transform: center offset (text: where the template places it) and size.
    public func contentRect(atLocal t: Time, text: GraphicsTextMeasure? = nil) -> GraphicsRect? {
        if case .text(let ref) = content { return text?(ref, textTime(atLocal: t)) }
        guard let s = shapeStyle(atLocal: t) else { return nil }
        let w = s.width, h = s.kind == .line && s.path == nil ? s.strokeWidth : s.height
        return GraphicsRect(minX: -w / 2, minY: -h / 2, maxX: w / 2, maxY: h / 2)
    }

    /// The box corners on the canvas at clip-local `t` (top-left, top-right, bottom-right, bottom-left of the content):
    /// a content point q (relative to the content center c) lands on position + c + R S (q - anchor), as the compositor
    /// draws it.
    public func corners(atLocal t: Time, text: GraphicsTextMeasure? = nil) -> [Vec2]? {
        guard let r = contentRect(atLocal: t, text: text) else { return nil }
        let m = motion(atLocal: t)
        let c = Vec2(r.midX, r.midY), hw = r.width / 2, hh = r.height / 2
        return GraphicsCorner.allCases.map { k in m.apply(c, Vec2(k.sign.x * hw, k.sign.y * hh)) }
    }

    /// On-canvas bounding box at clip-local `t` (Motion applied).
    public func bounds(atLocal t: Time, text: GraphicsTextMeasure? = nil) -> GraphicsRect? {
        guard let cs = corners(atLocal: t, text: text) else { return nil }
        let xs = cs.map(\.x), ys = cs.map(\.y)
        // Exact for axis-aligned boxes: snap float noise of 0 / 90 degree rotations.
        return GraphicsRect(minX: Self.snap(xs.min()!), minY: Self.snap(ys.min()!), maxX: Self.snap(xs.max()!), maxY: Self.snap(ys.max()!))
    }

    struct Motion {
        var position: Vec2, scale: Vec2, anchor: Vec2, cos: Double, sin: Double
        /// R v.
        func rotate(_ v: Vec2) -> Vec2 { Vec2(v.x * cos - v.y * sin, v.x * sin + v.y * cos) }
        /// R^-1 v.
        func unrotate(_ v: Vec2) -> Vec2 { Vec2(v.x * cos + v.y * sin, -v.x * sin + v.y * cos) }
        /// Canvas point of content point q (relative to the content center c).
        func apply(_ c: Vec2, _ q: Vec2) -> Vec2 {
            position + c + rotate(Vec2((q.x - anchor.x) * max(scale.x, 0), (q.y - anchor.y) * max(scale.y, 0)))
        }
    }

    func motion(atLocal t: Time) -> Motion {
        let a = animation
        let rad = a.rotation.value(atLocal: t) * .pi / 180
        return Motion(position: a.position.value(atLocal: t), scale: a.scale.value(atLocal: t),
                      anchor: a.anchor.value(atLocal: t), cos: Foundation.cos(rad), sin: Foundation.sin(rad))
    }

    private static func snap(_ v: Double) -> Double {
        let r = v.rounded()
        return abs(v - r) < 1e-9 ? r : v
    }
}

extension AnimatedProperty where V == Vec2 {
    /// The static value and every key moved by `d` (ids and easing kept).
    public func offset(by d: Vec2) -> AnimatedProperty {
        var c = self
        c.value = value + d
        c.track.keys = track.keys.map { var k = $0; k.value = k.value + d; return k }
        return c
    }

    /// Typing or dragging the base position of a text or graphic layer: the position shown at clip-local `t` becomes
    /// `target` and the whole motion (static value and every key) moves with it, so a fly-in keeps its shape. A static
    /// position just takes the value. Keys stay; no key is added at `t`.
    public func movedBase(to target: Vec2, atLocal t: Time) -> AnimatedProperty {
        guard isAnimated else { return AnimatedProperty(target, track: track) }
        return offset(by: target - value(atLocal: t))
    }
}
