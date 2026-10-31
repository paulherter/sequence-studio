import Foundation
import SQCore
import SQDrawKit

/// One layer of the selected graphic as the monitor draws it: its four corners in sequence px from the canvas center
/// (order of `GraphicsCorner`), already through the layer's Motion and the graphic's own.
public struct GraphicsLayerOutline: Sendable, Equatable {
    public var id: UUID
    public var corners: [Vec2]
    public var isSelected: Bool
    public init(id: UUID, corners: [Vec2], isSelected: Bool) { self.id = id; self.corners = corners; self.isSelected = isSelected }
}

/// Snap lines of a running layer drag, in sequence px from the canvas center.
public struct GraphicsLayerGuides: Sendable, Equatable {
    public var vertical: [Double]
    public var horizontal: [Double]
    public init(vertical: [Double] = [], horizontal: [Double] = []) { self.vertical = vertical; self.horizontal = horizontal }
    public static let none = GraphicsLayerGuides()
}

/// What the Program monitor's layer overlay needs from the Graphics editor (the shell adapts `GraphicsEditor`; the
/// overlay itself knows only sequence px). Every point is sequence px from the canvas center, y down.
@MainActor
public protocol GraphicsLayerSource: AnyObject {
    /// Layers drawn at the playhead (visible, inside their range), bottom first.
    var outlines: [GraphicsLayerOutline] { get }
    /// The single selected unlocked layer that has corner handles; nil: no handles.
    var handled: GraphicsLayerOutline? { get }
    var selection: Set<UUID> { get }
    /// The Draw tool is armed: a drag records a freeform stroke.
    var isDrawing: Bool { get }
    func layer(atSequence p: Vec2) -> UUID?
    /// Command-click: the layer under `p` below `current` (deep select).
    func layer(below current: UUID?, atSequence p: Vec2) -> UUID?
    /// Layers touched by the marquee spanned by two sequence points.
    func layers(inSequenceRect a: Vec2, _ b: Vec2) -> Set<UUID>
    func select(_ ids: Set<UUID>)
    func beginGesture()
    /// A move drag starts at `p`; `viewScale` is view points per sequence px (the snap distance in view points).
    func beginMove(atSequence p: Vec2, viewScale: Double)
    func move(toSequence p: Vec2, snapping: Bool) -> GraphicsLayerGuides
    func resize(_ id: UUID, corner: GraphicsCorner, toSequence p: Vec2, snapping: Bool, keepAspect: Bool,
                viewScale: Double) -> GraphicsLayerGuides
    func addPath(_ points: [Vec2])
}

/// The layers of the selected graphics clip on the Program monitor (the Mac `GraphicsOverlayView` translated): every
/// layer's outline, the selected layers' boxes, corner handles on the single selected one. A click picks the single
/// layer (Shift toggles, Command goes through to the one below), a drag moves the selection, a corner handle resizes
/// (Shift keeps the aspect), the Draw tool records a stroke. A text in a graphic is thus picked, boxed and moved alone,
/// never as the whole clip. Clicks beside the layers fall through to the clip's own transform overlay.
@MainActor
public final class GraphicsLayerOverlay {
    public weak var source: (any GraphicsLayerSource)?
    /// A graphic is selected under the playhead and the monitor is not playing.
    public var isShown = false
    public var sequenceSize = CGSize(width: 1920, height: 1080)
    static let handleSize: CGFloat = 8

    enum Drag {
        case move, resize(UUID, GraphicsCorner), draw([Vec2])
        /// Empty canvas: a click clears the layers, a drag draws a marquee (start and current point).
        case marquee(Vec2, Vec2, extend: Set<UUID>)
    }
    var drag: Drag?
    private var guides = GraphicsLayerGuides.none
    private var canvasRect: CGRect = .zero
    private var pressModifiers: InputModifiers = []

    public init() {}

    public var isDragging: Bool { drag != nil }

    // MARK: Mapping

    private func k(_ r: CGRect) -> Double { sequenceSize.width > 0 ? Double(r.width / sequenceSize.width) : 1 }

    func sequence(_ p: CGPoint, in r: CGRect) -> Vec2 {
        let s = max(k(r), 1e-9)
        return Vec2(Double(p.x - r.midX) / s, Double(p.y - r.midY) / s)
    }

    func view(_ q: Vec2, in r: CGRect) -> CGPoint {
        let s = k(r)
        return CGPoint(x: Double(r.midX) + q.x * s, y: Double(r.midY) + q.y * s)
    }

    private func handle(at p: CGPoint, in r: CGRect) -> (UUID, GraphicsCorner)? {
        guard let h = source?.handled, h.corners.count == 4 else { return nil }
        for c in GraphicsCorner.allCases {
            let v = view(h.corners[c.rawValue], in: r)
            if hypot(v.x - p.x, v.y - p.y) <= Self.handleSize { return (h.id, c) }
        }
        return nil
    }

    private func layer(at p: CGPoint, in r: CGRect) -> UUID? { source?.layer(atSequence: sequence(p, in: r)) }

    // MARK: Hit test

    /// True when a press at `p` is the layers' (else it falls through to the clip's transform box).
    public func hits(_ p: CGPoint, canvasRect r: CGRect, modifiers: InputModifiers = []) -> Bool {
        guard isShown, !r.isEmpty, let source else { return false }
        if source.isDrawing { return r.contains(p) }
        if handle(at: p, in: r) != nil || layer(at: p, in: r) != nil { return true }
        // Empty canvas belongs to the layers while some are selected (click clears, drag is a marquee), or with Option.
        return (!source.selection.isEmpty || modifiers.contains(.option)) && r.contains(p)
    }

    /// The pointer over the selected layer: the move cursor (nothing elsewhere; the monitor's own stays).
    public func hoverCursor(at p: CGPoint, canvasRect r: CGRect) -> DrawCursor? {
        guard isShown, !r.isEmpty, let source else { return nil }
        if source.isDrawing { return r.contains(p) ? .crosshair : nil }
        guard let h = source.handled, h.corners.count == 4 else { return nil }
        let v = h.corners.map { view($0, in: r) }
        let box = CGRect(x: v.map(\.x).min()!, y: v.map(\.y).min()!, width: v.map(\.x).max()! - v.map(\.x).min()!,
                         height: v.map(\.y).max()! - v.map(\.y).min()!)
        return box.contains(p) ? .move : nil
    }

    // MARK: Input

    /// A left press; true when the overlay took it.
    public func mouseDown(_ p: CGPoint, modifiers: InputModifiers, canvasRect r: CGRect) -> Bool {
        guard hits(p, canvasRect: r, modifiers: modifiers), let source else { return false }
        canvasRect = r
        pressModifiers = modifiers
        let q = sequence(p, in: r)
        if source.isDrawing { drag = .draw([q]); return true }
        if let (id, corner) = handle(at: p, in: r) {
            source.beginGesture()
            drag = .resize(id, corner)
            return true
        }
        guard let id = layer(at: p, in: r) else {
            drag = .marquee(q, q, extend: modifiers.contains(.shift) ? source.selection : [])
            return true
        }
        // Command-click selects through to the layer underneath (deep select); Shift toggles.
        if modifiers.contains(.command), !modifiers.contains(.shift) {
            let current = source.selection.count == 1 ? source.selection.first : nil
            if let deeper = source.layer(below: current, atSequence: q) { source.select([deeper]) }
            return true
        }
        if modifiers.contains(.shift) {
            var s = source.selection
            if s.contains(id) { s.remove(id) } else { s.insert(id) }
            source.select(s)
            return true
        }
        if !source.selection.contains(id) { source.select([id]) }
        source.beginGesture()
        source.beginMove(atSequence: q, viewScale: k(r))
        drag = .move
        return true
    }

    public func mouseDragged(_ p: CGPoint, modifiers now: InputModifiers? = nil) {
        let modifiers = now ?? pressModifiers
        guard let d = drag, let source else { return }
        let q = sequence(p, in: canvasRect)
        let plain = modifiers.intersection([.shift, .option]).isEmpty      // Shift or Option switches snapping off
        switch d {
        case .move:
            guides = source.move(toSequence: q, snapping: plain)
        case .resize(let id, let corner):
            guides = source.resize(id, corner: corner, toSequence: q, snapping: plain, keepAspect: modifiers.contains(.shift),
                                   viewScale: k(canvasRect))
        case .marquee(let a, _, let keep):
            drag = .marquee(a, q, extend: keep)
            source.select(keep.union(source.layers(inSequenceRect: a, q)))
        case .draw(var pts):
            if let l = pts.last, hypot(l.x - q.x, l.y - q.y) < 2 { return }
            pts.append(q)
            drag = .draw(pts)
        }
    }

    public func mouseUp(_ p: CGPoint) {
        if case .draw(let pts) = drag { source?.addPath(pts) }
        // A click on empty canvas (no movement) clears the layers and keeps the clip: back to clip level.
        if case .marquee(let a, let b, let keep) = drag, a == b, keep.isEmpty { source?.select([]) }
        drag = nil
        guides = .none
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, canvasRect r: CGRect, theme t: DrawTheme) {
        guard isShown, !r.isEmpty, let source else { return }
        let stroke = t.onPictureStroke, shadow = t.onPictureShadow
        for o in source.outlines where o.corners.count == 4 {
            let v = o.corners.map { view($0, in: r) }
            if o.isSelected { c.stroke(polygon: v, width: 1.5, t.accent) }
            else { Self.dashed(&c, v, dash: 3, gap: 3, stroke.alpha(0.25)) }
        }
        if let h = source.handled, h.corners.count == 4 {
            let s = Self.handleSize
            for corner in h.corners {
                let v = view(corner, in: r)
                let rect = CGRect(x: v.x - s / 2, y: v.y - s / 2, width: s, height: s)
                c.fill(rect, stroke)
                c.stroke(polygon: Self.rectCorners(rect), width: 1, t.accent)
            }
        }
        for x in guides.vertical {
            let a = view(Vec2(x, 0), in: r)
            c.strokeLine(from: CGPoint(x: a.x, y: r.minY), to: CGPoint(x: a.x, y: r.maxY), width: 1, t.accent)
        }
        for y in guides.horizontal {
            let a = view(Vec2(0, y), in: r)
            c.strokeLine(from: CGPoint(x: r.minX, y: a.y), to: CGPoint(x: r.maxX, y: a.y), width: 1, t.accent)
        }
        switch drag {
        case .marquee(let a, let b, _):
            let va = view(a, in: r), vb = view(b, in: r)
            let rect = CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y), width: abs(va.x - vb.x), height: abs(va.y - vb.y))
            c.fill(rect, t.accent.alpha(0.15))
            c.stroke(polygon: Self.rectCorners(rect), width: 1, t.accent)
        case .draw(let pts) where pts.count >= 2:
            let v = pts.map { view($0, in: r) }
            for i in 1..<v.count { c.strokeLine(from: v[i - 1], to: v[i], width: 2, stroke) }
        default: break
        }
    }

    static func rectCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    private static func dashed(_ c: inout Canvas, _ poly: [CGPoint], dash: CGFloat, gap: CGFloat, _ color: DrawColor) {
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { continue }
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            var s: CGFloat = 0
            while s < len {
                let e = min(s + dash, len)
                c.strokeLine(from: CGPoint(x: a.x + ux * s, y: a.y + uy * s), to: CGPoint(x: a.x + ux * e, y: a.y + uy * e), width: 1, color)
                s = e + gap
            }
        }
    }
}
