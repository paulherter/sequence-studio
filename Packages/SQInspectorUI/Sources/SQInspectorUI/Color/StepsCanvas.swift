#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// The geometry and the drag rules of the Steps canvas (no drawing, no AppKit): where every Step, slot and wire sits, what a
/// point hits, how a Step moves, and where a dropped Step lands. Canvas units are points at zoom 1; the view point of a canvas
/// point is `canvas * zoom + pan`. A Step without a stored position sits where the automatic layout puts it: columns left to
/// right, a stack of Parallel or Layer Steps centered on the main wire.
struct StepsCanvas {
    static let node = CGSize(width: 96, height: 42)
    static let pill = CGSize(width: 34, height: 22)
    static let slot = CGSize(width: 52, height: 26)
    /// A LUT slot grows to its label: the text plus a pad each side (and the connector dots), never narrower than `slot`.
    static let slotPad: CGFloat = 14
    static let slotMax: CGFloat = 200
    static func slotWidth(textWidth: CGFloat) -> CGFloat { min(max(slot.width, ceil(textWidth) + 2 * slotPad), slotMax) }
    static let wire: CGFloat = 24
    static let stackGap: CGFloat = 4
    static let zoomRange: ClosedRange<CGFloat> = 0.4...2
    /// How near (view points) a dragged Step's center must be to a wire to land on it.
    static let wireGrab: CGFloat = 16
    static let insertButton: CGFloat = 16
    /// A drag shorter than this is a click.
    static let clickSlop: CGFloat = 3

    /// The Steps as columns, and the positions the user stored.
    var columns: [[UUID]]
    var positions: [UUID: StepPosition]
    /// Stored positions of mixer boxes, keyed by the head (serial Step) of their stack.
    var mixerPositions: [UUID: StepPosition] = [:]
    /// The image wires (nil: the ones the columns say) and the key wires.
    var links: [GraphLink]?
    var keyLinks: [GraphLink] = []
    var pan = CGPoint.zero
    var zoom: CGFloat = 1
    /// The user moved or zoomed the view: it no longer fits itself to the content.
    var userView = false
    /// Widths of the Input and Output LUT slots (their labels, `slotWidth`).
    var inSlotWidth = StepsCanvas.slot.width
    var outSlotWidth = StepsCanvas.slot.width

    init(columns: [[UUID]] = [], positions: [UUID: StepPosition] = [:]) {
        self.columns = columns
        self.positions = positions
    }

    struct Layout {
        var inPill = CGRect.zero, inSlot = CGRect.zero, outSlot = CGRect.zero, outPill = CGRect.zero
        var rects: [UUID: CGRect] = [:]
        /// Mixer boxes of the stacks, keyed by the head of the stack.
        var mixers: [UUID: CGRect] = [:]
        /// Steps in graph order.
        var order: [UUID] = []
    }

    /// Where everything sits, in canvas units (the Step being dragged at its live position).
    func layout() -> Layout {
        var l = Layout()
        var x: CGFloat = 0
        func next(_ s: CGSize) -> CGRect {
            defer { x += s.width + Self.wire }
            return CGRect(x: x, y: -s.height / 2, width: s.width, height: s.height)
        }
        l.inPill = next(Self.pill)
        l.inSlot = next(CGSize(width: inSlotWidth, height: Self.slot.height))
        for col in columns {
            let h = CGFloat(col.count) * Self.node.height + CGFloat(max(col.count - 1, 0)) * Self.stackGap
            var y = -h / 2
            for id in col {
                l.rects[id] = CGRect(origin: CGPoint(x: x, y: y), size: Self.node)
                l.order.append(id)
                y += Self.node.height + Self.stackGap
            }
            x += Self.node.width + Self.wire + (col.count > 1 ? Self.mixerSpace : 0)
        }
        l.outSlot = next(CGSize(width: outSlotWidth, height: Self.slot.height))
        l.outPill = next(Self.pill)
        for id in l.order {
            if let p = positions[id] { l.rects[id] = CGRect(origin: CGPoint(x: p.x, y: p.y), size: Self.node) }
        }
        if let d = drag, !d.isMixer {
            l.rects[d.id] = d.rect
            let delta = CGPoint(x: d.rect.minX - d.origin.x, y: d.rect.minY - d.origin.y)
            for (id, r) in d.group { l.rects[id] = r.offsetBy(dx: delta.x, dy: delta.y) }
        }
        for col in columns where col.count > 1 {
            let head = col[0]
            if let p = mixerPositions[head] {
                l.mixers[head] = CGRect(origin: CGPoint(x: p.x, y: p.y), size: Self.mixerSize)
            } else {
                // An automatic mixer box keeps clear of a Step that was placed where it would sit.
                var r = Self.mixerRect(col.compactMap { l.rects[$0] })
                var tries = 0
                while tries < 30, l.rects.values.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(r) })
                        || l.mixers.values.contains(where: { $0.intersects(r) }) {
                    r.origin.y += Self.mixerSize.height + 8
                    tries += 1
                }
                l.mixers[head] = r
            }
        }
        if let d = drag, d.isMixer { l.mixers[d.id] = d.rect }
        return l
    }

    // MARK: View transform

    func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom + pan.x, y: r.minY * zoom + pan.y, width: r.width * zoom, height: r.height * zoom)
    }
    func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y) }
    func canvasPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom) }

    /// Everything the canvas shows, in canvas units.
    func content(_ l: Layout) -> CGRect {
        var r = l.inPill.union(l.outPill)
        for s in l.rects.values { r = r.union(s) }
        for s in l.mixers.values { r = r.union(s) }
        return r
    }

    mutating func panBy(_ d: CGSize) {
        pan.x += d.width; pan.y += d.height
        userView = true
    }

    /// Zooms by `factor` keeping the canvas point under `at` (a view point) where it is.
    mutating func zoomBy(_ factor: CGFloat, at p: CGPoint) {
        let c = canvasPoint(p)
        zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        pan = CGPoint(x: p.x - c.x * zoom, y: p.y - c.y * zoom)
        userView = true
    }

    /// Fits the content into `size` (zoom 1 when it fits, smaller when not) and centers it.
    mutating func fit(in size: CGSize, margin: CGFloat) {
        let c = content(layout())
        guard c.width > 0, size.width > 0, size.height > 0 else { return }
        let z = min(1, (size.width - 2 * margin) / c.width, (size.height - 2 * margin) / max(c.height, 1))
        zoom = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        pan = CGPoint(x: (size.width - c.width * zoom) / 2 - c.minX * zoom, y: (size.height - c.height * zoom) / 2 - c.minY * zoom)
        userView = false
    }

    // MARK: Hits (view points)

    /// Where a wire starts or ends: the graph's source and sink, a Step, or the mixer box of a stack (named by its head).
    typealias Port = StepsPort

    enum Hit: Equatable {
        case input, output, step(UUID), eye(UUID), insert(UUID), mixer(UUID)
        /// A connector dot: the output (right) or the input (left) of a box.
        case dotOut(Port), dotIn(Port)
        /// A Key connector: the key output of a Step, the key input of a Step or mixer box.
        case keyOut(UUID), keyIn(Port)
    }

    /// Size (view points) of the grab area around a connector dot.
    static let dotGrab: CGFloat = 6
    static let dotSize: CGFloat = 5

    /// Canvas point of the dot of `port`: its output (right edge) or input (left edge).
    func dotCenter(_ port: Port, output: Bool, _ l: Layout) -> CGPoint? {
        let r: CGRect?
        switch port {
        case .source: r = output ? l.inSlot : nil
        case .sink: r = output ? nil : l.outSlot
        case .step(let id): r = l.rects[id]
        case .mixer(let head): r = l.mixers[head]
        }
        return r.map { output ? Self.out($0) : Self.into($0) }
    }

    /// Key input and key output dots of a Step box (canvas units): the bottom corners, drawn in the secondary style.
    static func keyDots(_ r: CGRect) -> (input: CGPoint, output: CGPoint) {
        (CGPoint(x: r.minX + 10, y: r.maxY), CGPoint(x: r.maxX - 10, y: r.maxY))
    }

    /// Canvas point of the key input (`output` false) or key output of a Step; a mixer box has a key input at its bottom middle.
    func keyDotCenter(_ port: Port, output: Bool, _ l: Layout) -> CGPoint? {
        switch port {
        case .step(let id): l.rects[id].map { output ? Self.keyDots($0).output : Self.keyDots($0).input }
        case .mixer(let head): output ? nil : l.mixers[head].map { CGPoint(x: $0.midX, y: $0.maxY) }
        case .source, .sink: nil
        }
    }

    /// The port whose input a dropped wire lands on: an input dot, or anywhere on a box that has an input.
    func inputPort(at p: CGPoint) -> Port? {
        let l = layout()
        for port in ports(l).reversed() {
            if let c = dotCenter(port, output: false, l), hypot(viewPoint(c).x - p.x, viewPoint(c).y - p.y) <= Self.dotGrab + 2 { return port }
        }
        for id in l.order.reversed() where l.rects[id].map(viewRect)?.contains(p) == true { return .step(id) }
        for (head, r) in l.mixers where viewRect(r).contains(p) { return .mixer(head) }
        if viewRect(l.outSlot).contains(p) || viewRect(l.outPill).contains(p) { return .sink }
        return nil
    }

    private func ports(_ l: Layout) -> [Port] {
        [.source, .sink] + l.order.map(Port.step) + l.mixers.keys.map(Port.mixer)
    }

    static func eyeRect(_ r: CGRect) -> CGRect { CGRect(x: r.maxX - 22, y: r.minY + 2, width: 20, height: 18) }

    func hit(at p: CGPoint) -> Hit? {
        let l = layout()
        // Key dots first: they sit on the lower edge of the box.
        for port in ports(l).reversed() {
            for output in [true, false] {
                guard let c = keyDotCenter(port, output: output, l) else { continue }
                let v = viewPoint(c)
                if hypot(v.x - p.x, v.y - p.y) <= Self.dotGrab {
                    if output, case .step(let id) = port { return .keyOut(id) }
                    if !output { return .keyIn(port) }
                }
            }
        }
        for port in ports(l).reversed() {
            for output in [true, false] {
                guard let c = dotCenter(port, output: output, l) else { continue }
                // The dot of a slot belongs to the slot's menu unless it is the wire end of the graph.
                let v = viewPoint(c)
                if hypot(v.x - p.x, v.y - p.y) <= Self.dotGrab { return output ? .dotOut(port) : .dotIn(port) }
            }
        }
        if viewRect(l.inSlot).contains(p) || viewRect(l.inPill).contains(p) { return .input }
        if viewRect(l.outSlot).contains(p) || viewRect(l.outPill).contains(p) { return .output }
        for id in l.order.reversed() {
            guard let r = l.rects[id].map(viewRect), r.contains(p) else { continue }
            return Self.eyeRect(r).contains(p) ? .eye(id) : .step(id)
        }
        for (head, r) in l.mixers where viewRect(r).contains(p) { return .mixer(head) }
        for (id, r) in insertButtons(l) where r.insetBy(dx: -2, dy: -2).contains(p) { return .insert(id) }
        return nil
    }

    // MARK: Wires

    struct Wire: Equatable {
        var from: CGPoint
        var to: CGPoint
        /// The column gap it belongs to (0 = before the first column, `columns.count` = after the last), -1 = pill and slot wires.
        var gap: Int
        /// The model wire it draws (nil: the wires of the In and Out ends).
        var link: GraphLink?
        /// A key wire.
        var isKey = false
        /// Point at `t` (0...1) on the curve: horizontal tangents at both ends.
        func point(_ t: CGFloat) -> CGPoint {
            let k = max(abs(to.x - from.x) * 0.5, 12)
            let c1 = CGPoint(x: from.x + k, y: from.y), c2 = CGPoint(x: to.x - k, y: to.y)
            let u = 1 - t
            func mix(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
            }
            return CGPoint(x: mix(from.x, c1.x, c2.x, to.x), y: mix(from.y, c1.y, c2.y, to.y))
        }
        /// Control points for drawing.
        var controls: (CGPoint, CGPoint) {
            let k = max(abs(to.x - from.x) * 0.5, 12)
            return (CGPoint(x: from.x + k, y: from.y), CGPoint(x: to.x - k, y: to.y))
        }
        func distance(to p: CGPoint) -> CGFloat {
            var best = CGFloat.greatestFiniteMagnitude
            for i in 0...20 {
                let q = point(CGFloat(i) / 20)
                best = min(best, hypot(q.x - p.x, q.y - p.y))
            }
            return best
        }
    }

    static let mixerSize = CGSize(width: 26, height: 20)
    /// Extra room a stack's mixer box needs behind its Steps.
    static let mixerSpace: CGFloat = 36

    /// The mixer box behind the Steps of a stack (canvas units).
    static func mixerRect(_ rects: [CGRect]) -> CGRect {
        let x = (rects.map(\.maxX).max() ?? 0) + 24
        let y = rects.map(\.midY).reduce(0, +) / CGFloat(max(rects.count, 1))
        return CGRect(x: x, y: y - mixerSize.height / 2, width: mixerSize.width, height: mixerSize.height)
    }

    /// Mixer boxes of the stacks: the column index, the head of the stack and the box (canvas units).
    func mixers(_ l: Layout) -> [(Int, UUID, CGRect)] {
        columns.enumerated().compactMap { c, col in
            guard col.count > 1, let r = l.mixers[col[0]] else { return nil }
            return (c, col[0], r)
        }
    }

    private static func out(_ r: CGRect) -> CGPoint { CGPoint(x: r.maxX, y: r.midY) }
    private static func into(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX, y: r.midY) }

    /// The image wires drawn: the stored ones, else the ones the columns say.
    var imageLinks: [GraphLink] { links ?? ColorGraph.derivedLinks(columns: columns) }

    /// The column a box belongs to (a mixer box counts with its stack's column).
    private func column(of p: Port) -> Int? {
        switch p {
        case .step(let id): columns.firstIndex { $0.contains(id) }
        case .mixer(let head): columns.firstIndex { $0.first == head }
        case .source, .sink: nil
        }
    }

    /// Every image wire (canvas units), plus the wires of the In and Out ends. `gap` = 1 + the column the wire leaves
    /// (0 from In); wires into a mixer box have none.
    func wires(layout l: Layout) -> [Wire] {
        var w = [Wire(from: Self.out(l.inPill), to: Self.into(l.inSlot), gap: -1)]
        for k in imageLinks {
            guard let a = dotCenter(k.from, output: true, l), let b = dotCenter(k.to, output: false, l) else { continue }
            let gap = k.to.isMixer ? -1 : (column(of: k.from).map { $0 + 1 } ?? 0)
            w.append(Wire(from: a, to: b, gap: gap, link: k))
        }
        w.append(Wire(from: Self.out(l.outSlot), to: Self.into(l.outPill), gap: -1))
        return w
    }

    func wires() -> [Wire] { wires(layout: layout()) }

    /// The key wires (canvas units): bottom corner to bottom corner.
    func keyWires() -> [Wire] {
        let l = layout()
        return keyLinks.compactMap { k in
            guard let id = k.from.stepID, let a = keyDotCenter(.step(id), output: true, l), let b = keyDotCenter(k.to, output: false, l) else { return nil }
            return Wire(from: a, to: b, gap: -1, link: k, isKey: true)
        }
    }

    /// The image wire into the input of `port`, if any (a mixer takes several: the first).
    func wire(into port: Port) -> GraphLink? { imageLinks.first { $0.to == port } }

    /// The "+" button of each column: on the first wire behind its last Step (view rects), keyed by that Step.
    func insertButtons(_ l: Layout) -> [(UUID, CGRect)] {
        let b = Self.insertButton
        let all = wires(layout: l)
        return columns.enumerated().compactMap { c, col in
            guard let last = col.last, let w = all.first(where: { $0.gap == c + 1 }) else { return nil }
            let m = viewPoint(w.point(0.5))
            return (last, CGRect(x: m.x - b / 2, y: m.y - b / 2, width: b, height: b))
        }
    }

    // MARK: Dragging a Step

    struct Drag: Equatable {
        var id: UUID
        /// Pointer offset inside the Step (canvas units).
        var grab: CGPoint
        var start: CGPoint
        var rect: CGRect
        /// Where the Step's box started (canvas units).
        var origin: CGPoint = .zero
        var moved = false
        /// The box is a mixer (`id` is the head of its stack).
        var isMixer = false
        /// The other selected Steps that move with it (their boxes at the start).
        var group: [UUID: CGRect] = [:]
        /// Shift was held: the Step comes off its wires.
        var extract = false
    }
    private(set) var drag: Drag?

    enum Drop: Equatable {
        /// Not moved: a click.
        case click
        /// Let go in free space: the Step (or mixer box) stays there.
        case place(StepPosition)
        /// Let go on a wire: the Step goes between the ends of that wire.
        case insertOnto(GraphLink)
        /// Shift-drag let go in free space: the Step comes off its wires (the gap closes) and stays there.
        case extract(StepPosition)
    }

    mutating func beginDrag(_ id: UUID, at p: CGPoint, with group: Set<UUID> = [], extract: Bool = false) {
        let l = layout()
        guard let r = l.rects[id] else { return }
        let c = canvasPoint(p)
        var d = Drag(id: id, grab: CGPoint(x: c.x - r.minX, y: c.y - r.minY), start: p, rect: r, origin: r.origin, extract: extract)
        for o in group where o != id { if let q = l.rects[o] { d.group[o] = q } }
        drag = d
    }

    mutating func beginMixerDrag(_ head: UUID, at p: CGPoint) {
        guard let r = layout().mixers[head] else { return }
        let c = canvasPoint(p)
        drag = Drag(id: head, grab: CGPoint(x: c.x - r.minX, y: c.y - r.minY), start: p, rect: r, origin: r.origin, isMixer: true)
    }

    mutating func continueDrag(to p: CGPoint) {
        guard var d = drag else { return }
        if hypot(p.x - d.start.x, p.y - d.start.y) >= Self.clickSlop { d.moved = true }
        guard d.moved else { return }
        let c = canvasPoint(p)
        d.rect.origin = CGPoint(x: c.x - d.grab.x, y: c.y - d.grab.y)
        drag = d
    }

    mutating func endDrag() -> Drop? {
        guard let d = drag else { return nil }
        let result: Drop
        let pos = StepPosition(x: Double(d.rect.minX), y: Double(d.rect.minY))
        if !d.moved {
            result = .click
        } else if !d.isMixer, d.group.isEmpty, !d.extract, let link = dropLink(for: d) {
            result = .insertOnto(link)
        } else if d.extract, d.group.isEmpty {
            result = .extract(pos)
        } else {
            result = .place(pos)
        }
        drag = nil
        return result
    }

    mutating func cancelDrag() { drag = nil }

    /// Where every moved Step of a finished drag lands (the dragged one and its group), canvas units.
    func groupPositions(_ d: Drag) -> [UUID: StepPosition] {
        let delta = CGPoint(x: d.rect.minX - d.origin.x, y: d.rect.minY - d.origin.y)
        var out = [d.id: StepPosition(x: Double(d.rect.minX), y: Double(d.rect.minY))]
        for (id, r) in d.group { out[id] = StepPosition(x: Double(r.minX + delta.x), y: Double(r.minY + delta.y)) }
        return out
    }

    /// While a Step is being dragged: the wire it would land on, drawn highlighted.
    var previewLink: GraphLink? { drag.flatMap { $0.moved && !$0.isMixer && $0.group.isEmpty && !$0.extract ? dropLink(for: $0) : nil } }

    func previewWires() -> [Wire] {
        guard let link = previewLink else { return [] }
        return wires(layout: layout()).filter { $0.link == link }
    }

    /// The image wire (not into a mixer box, not one of the Step's own) that passes the dragged Step's center, if any.
    func dropLink(for d: Drag) -> GraphLink? {
        guard !d.isMixer, columns.flatMap({ $0 }).count > 1 else { return nil }
        let l = layout()
        let center = viewPoint(CGPoint(x: d.rect.midX, y: d.rect.midY))
        var best: (GraphLink, CGFloat)?
        for w in wires(layout: l) {
            guard let k = w.link, !k.to.isMixer, k.from != .step(d.id), k.to != .step(d.id) else { continue }
            let a = Wire(from: viewPoint(w.from), to: viewPoint(w.to), gap: w.gap)
            let dist = a.distance(to: center)
            if dist <= Self.wireGrab, dist < (best?.1 ?? .greatestFiniteMagnitude) { best = (k, dist) }
        }
        return best?.0
    }

    // MARK: Selecting with a rectangle

    /// The Steps whose boxes touch the rectangle (view points).
    func steps(in rect: CGRect) -> Set<UUID> {
        let l = layout()
        return Set(l.order.filter { id in l.rects[id].map { viewRect($0).intersects(rect) } == true })
    }
}

// MARK: - Where a new Step goes

extension StepsCanvas {
    /// A position for the new Step `id` (canvas units): where the automatic layout would put it, moved down until no other
    /// box (Step or mixer) is under it. Nothing is stacked on another box.
    static func freeSpot(for id: UUID, columns: [[UUID]], positions: [UUID: StepPosition],
                         mixerPositions: [UUID: StepPosition] = [:]) -> StepPosition? {
        var c = StepsCanvas(columns: columns, positions: positions.filter { $0.key != id })
        c.mixerPositions = mixerPositions
        let l = c.layout()
        guard var r = l.rects[id] else { return nil }
        var others = l.rects.filter { $0.key != id }.map(\.value) + Array(l.mixers.values)
        others.append(contentsOf: [l.inSlot, l.outSlot, l.inPill, l.outPill])
        let step = node.height + stackGap * 2
        var tries = 0
        while tries < 40, others.contains(where: { $0.insetBy(dx: -stackGap, dy: -stackGap).intersects(r) }) {
            r.origin.y += step
            tries += 1
        }
        return StepPosition(x: Double(r.minX), y: Double(r.minY))
    }
}
