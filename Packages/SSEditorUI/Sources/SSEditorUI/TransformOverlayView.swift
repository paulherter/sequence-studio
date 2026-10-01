import AppKit
import SSCore

/// Transparent overlay above the Program monitor: layer quad, scale/rotate handles, anchor crosshair and the
/// motion path of the selected clip's position keyframes. Pure drawing and event routing; all maths lives in
/// `TransformOverlayGeometry` / `MotionPathGeometry`. One gesture = begin, changed..., ended (one undo step).
@MainActor
public final class TransformOverlayView: NSView {
    public enum Phase: Sendable { case began, changed, ended }

    /// Edit of a position key from the motion path. `tangents` is set for handle drags.
    public struct PathEdit: Sendable, Equatable {
        public var key: UUID
        public var position: Vec2?
        public var tangents: (in: Vec2, out: Vec2)?
        public static func == (a: PathEdit, b: PathEdit) -> Bool {
            a.key == b.key && a.position == b.position && a.tangents?.in == b.tangents?.in && a.tangents?.out == b.tangents?.out
        }
    }

    /// Transform gesture: began with the start transform, changed/ended with the new one.
    public var onTransform: ((Phase, ClipTransform) -> Void)?
    public var onPathEdit: ((Phase, PathEdit) -> Void)?
    /// Double click on the picture (text clips: edit the text in place).
    public var onBodyDoubleClick: (() -> Void)?

    public var sequenceSize = CGSize(width: 1920, height: 1080) { didSet { needsDisplay = true } }
    /// Where the sequence canvas is drawn inside this view (aspect-fitted by the host).
    public var canvasRect = CGRect.zero { didSet { needsDisplay = true } }
    public var mediaAspect = 16.0 / 9 { didSet { needsDisplay = true } }
    /// Upright native size of the picture (or the text raster) in sequence px: scale 1 = this size (source pixels).
    public var mediaPixelSize: CGSize? { didSet { needsDisplay = true } }
    /// Snap lines for moves (canvas centre and edges, other layers); nil = no smart guides.
    public var snapTargets: SnapGuides.Targets?
    /// Evaluated transform at the playhead. Ignored for display while a gesture is running.
    public var transform = ClipTransform.identity { didSet { if drag == nil { needsDisplay = true } } }
    public var positionTrack = KeyframeTrack<Vec2>() { didSet { needsDisplay = true } }
    public var selectedKey: UUID? { didSet { needsDisplay = true } }
    /// The clip's Uniform Scale flag (Effect Controls): on = every handle scales proportionally.
    public var uniformScale = true
    public var showsOverlay = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    private enum Drag {
        case body(start: CGPoint, geo: TransformOverlayGeometry)
        case scale(TransformOverlayGeometry.Handle, start: CGPoint, geo: TransformOverlayGeometry)
        case rotate(start: CGPoint, geo: TransformOverlayGeometry, last: Double)
        case anchor(start: CGPoint, geo: TransformOverlayGeometry)
        case key(UUID)
        case tangent(UUID, MotionPathGeometry.Hit, current: (in: Vec2, out: Vec2))
    }
    private var drag: Drag?
    /// Smart guides of the running move (drawn while dragging).
    private var activeGuides = SnapGuides.Result.none
    public static let snapDistance: Double = 6   // view px
    private var liveTransform: ClipTransform?
    private var hoverHit: TransformOverlayGeometry.Hit?
    private var tracking: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var geometry: TransformOverlayGeometry {
        TransformOverlayGeometry(sequenceSize: sequenceSize, viewRect: canvasRect, mediaAspect: mediaAspect,
                                 transform: liveTransform ?? transform,
                                 mediaPixelSize: mediaPixelSize)
    }
    private var pathGeometry: MotionPathGeometry? {
        positionTrack.isEmpty ? nil
            : MotionPathGeometry(track: positionTrack, sequenceSize: sequenceSize, viewRect: canvasRect)
    }

    // MARK: Hit routing

    /// Clicks outside every handle and the layer fall through to the monitor below.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard showsOverlay, !canvasRect.isEmpty else { return nil }
        let p = convert(point, from: superview)
        if drag != nil { return self }
        if pathGeometry?.hitTest(p, selectedKey: selectedKey) != nil { return self }
        return geometry.hitTest(p) != nil ? self : nil
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = geometry.hitTest(p)
        if hit != hoverHit { hoverHit = hit; updateCursor(hit) }
    }
    public override func mouseExited(with event: NSEvent) { hoverHit = nil; NSCursor.arrow.set() }

    private func updateCursor(_ hit: TransformOverlayGeometry.Hit?) {
        let g = geometry
        switch hit {
        case .anchor?: NSCursor.crosshair.set()
        case .rotate(let h)?: OverlayCursors.rotate(angle: g.viewAngle(of: h)).set()
        case .handle(let h)?: OverlayCursors.resize(angle: g.viewAngle(of: h)).set()
        case .body?: OverlayCursors.move.set()
        case nil: NSCursor.arrow.set()
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let path = pathGeometry, let hit = path.hitTest(p, selectedKey: selectedKey) {
            switch hit {
            case .key(let id):
                drag = .key(id)
                onPathEdit?(.began, PathEdit(key: id, position: path.keyValue(at: p), tangents: nil))
            case .inTangent(let id), .outTangent(let id):
                let k = positionTrack.key(id: id)
                drag = .tangent(id, hit, current: (k?.inTangent ?? .zero, k?.outTangent ?? .zero))
                onPathEdit?(.began, PathEdit(key: id, position: nil, tangents: (k?.inTangent ?? .zero, k?.outTangent ?? .zero)))
            }
            return
        }
        let g = geometry
        guard var hit = g.hitTest(p) else { return }
        if hit == .body, event.clickCount == 2 { onBodyDoubleClick?(); return }
        // Option-drag on the picture moves the anchor point, not the picture (Premiere).
        if hit == .body, event.modifierFlags.contains(.option) { hit = .anchor }
        switch hit {
        case .body: drag = .body(start: p, geo: g); NSCursor.closedHand.set()
        case .handle(let h): drag = .scale(h, start: p, geo: g)
        case .rotate: drag = .rotate(start: p, geo: g, last: g.transform.rotation)
        case .anchor: drag = .anchor(start: p, geo: g)
        }
        liveTransform = g.transform
        onTransform?(.began, g.transform)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        let shift = flags.contains(.shift), option = flags.contains(.option)
        switch d {
        case .body(let s, let g):
            emit(snapped(g.moved(from: s, to: p, lockAxis: shift), geo: g, disabled: flags.contains(.command), lockAxis: shift))
        case .scale(let h, let s, let g):
            emit(g.scaled(handle: h, from: s, to: p, modifiers: .init(shift: shift, option: option, uniformScale: uniformScale)))
        case .rotate(let s, let g, let last):
            let t = g.rotated(from: s, to: p, snap: shift, continuingFrom: last)
            drag = .rotate(start: s, geo: g, last: t.rotation)
            emit(t)
        case .anchor(let s, let g):
            emit(g.anchorMoved(from: s, to: p))
        case .key(let id):
            guard let path = pathGeometry else { return }
            onPathEdit?(.changed, PathEdit(key: id, position: path.keyValue(at: p), tangents: nil))
        case .tangent(let id, let side, let current):
            guard let path = pathGeometry else { return }
            let t = path.tangents(forKey: id, dragging: side, to: p, independent: option, current: current)
            drag = .tangent(id, side, current: t)
            onPathEdit?(.changed, PathEdit(key: id, position: nil, tangents: t))
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        drag = nil
        switch d {
        case .key(let id):
            onPathEdit?(.ended, PathEdit(key: id, position: pathGeometry?.keyValue(at: p), tangents: nil))
        case .tangent(let id, _, let current):
            onPathEdit?(.ended, PathEdit(key: id, position: nil, tangents: current))
        default:
            if let t = liveTransform { onTransform?(.ended, t) }
            liveTransform = nil
            activeGuides = .none
        }
        needsDisplay = true
        updateCursor(geometry.hitTest(p))
    }

    /// Smart guides: the moved layer's edges and centre snap to the canvas and the other layers.
    private func snapped(_ t: ClipTransform, geo g: TransformOverlayGeometry, disabled: Bool, lockAxis: Bool) -> ClipTransform {
        guard !disabled, let targets = snapTargets, g.viewScale > 0 else { activeGuides = .none; return t }
        let box = LayerBounds.rect(size: g.fittedSize, transform: t)
        // Shift axis lock: the locked axis did not move, so it must not snap either.
        let r = SnapGuides.snap(box: box, targets: targets, threshold: Self.snapDistance / g.viewScale)
            .locking(x: lockAxis && t.position.x == g.transform.position.x, y: lockAxis && t.position.y == g.transform.position.y)
        activeGuides = r
        var out = t
        out.position = Vec2(t.position.x + r.dx, t.position.y + r.dy)
        return out
    }

    private func emit(_ t: ClipTransform) {
        liveTransform = t
        needsDisplay = true
        onTransform?(.changed, t)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard showsOverlay, !canvasRect.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = geometry
        let accent = Theme.Colors.accent

        if let path = pathGeometry { drawMotionPath(path, ctx) }
        drawGuides(g)

        // Quad
        let q = g.quad
        let outline = NSBezierPath()
        outline.move(to: q[0]); q.dropFirst().forEach { outline.line(to: $0) }; outline.close()
        Theme.black(0.5).setStroke(); outline.lineWidth = 3; outline.stroke()
        accent.setStroke(); outline.lineWidth = 1; outline.stroke()

        // Handles
        for h in TransformOverlayGeometry.Handle.allCases {
            let c = g.viewPoint(of: h)
            let r: CGFloat = 4
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            let sq = NSBezierPath(rect: rect)
            NSColor.white.setFill(); sq.fill()
            accent.setStroke(); sq.lineWidth = 1; sq.stroke()
        }

        // Anchor crosshair: always drawn, white with a dark halo, ring plus cross (grab radius 10 pt).
        let a = g.anchorViewPoint
        let arm: CGFloat = 9
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: a.x - arm, y: a.y)); cross.line(to: CGPoint(x: a.x + arm, y: a.y))
        cross.move(to: CGPoint(x: a.x, y: a.y - arm)); cross.line(to: CGPoint(x: a.x, y: a.y + arm))
        let ring = NSBezierPath(ovalIn: CGRect(x: a.x - 5, y: a.y - 5, width: 10, height: 10))
        Theme.black(0.6).setStroke(); cross.lineWidth = 3.5; cross.stroke(); ring.lineWidth = 3.5; ring.stroke()
        NSColor.white.setStroke(); cross.lineWidth = 1.5; cross.stroke(); ring.lineWidth = 1.5; ring.stroke()
    }

    private func drawGuides(_ g: TransformOverlayGeometry) {
        guard drag != nil, !(activeGuides.verticalLines.isEmpty && activeGuides.horizontalLines.isEmpty) else { return }
        let r = canvasRect
        let line = NSBezierPath()
        for x in activeGuides.verticalLines {
            let vx = r.midX + CGFloat(x * g.viewScale)
            line.move(to: CGPoint(x: vx, y: r.minY)); line.line(to: CGPoint(x: vx, y: r.maxY))
        }
        for y in activeGuides.horizontalLines {
            let vy = r.midY + CGFloat(y * g.viewScale)
            line.move(to: CGPoint(x: r.minX, y: vy)); line.line(to: CGPoint(x: r.maxX, y: vy))
        }
        Self.guideColor.setStroke()
        line.lineWidth = 1
        line.stroke()
    }
    public static let guideColor = NSColor(srgbRed: 1, green: 0.25, blue: 0.62, alpha: 1)

    private func drawMotionPath(_ path: MotionPathGeometry, _ ctx: CGContext) {
        let line = NSBezierPath()
        for seg in path.segments where seg.count > 1 {
            line.move(to: seg[0]); seg.dropFirst().forEach { line.line(to: $0) }
        }
        Theme.black(0.5).setStroke(); line.lineWidth = 3; line.stroke()
        Theme.Colors.yellow.setStroke(); line.lineWidth = 1; line.stroke()

        for k in path.keys {
            let showIn = k.id == selectedKey || k.hasInTangent
            let showOut = k.id == selectedKey || k.hasOutTangent
            let stems = NSBezierPath()
            if showIn, k.inHandle != k.point { stems.move(to: k.point); stems.line(to: k.inHandle) }
            if showOut, k.outHandle != k.point { stems.move(to: k.point); stems.line(to: k.outHandle) }
            Theme.Colors.label2.setStroke(); stems.lineWidth = 1; stems.stroke()
            for (show, h) in [(showIn, k.inHandle), (showOut, k.outHandle)] where show && h != k.point {
                let dot = NSBezierPath(ovalIn: CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7))
                Theme.Colors.yellow.setFill(); dot.fill()
                Theme.black(0.6).setStroke(); dot.lineWidth = 1; dot.stroke()
            }
            let r: CGFloat = 4.5
            let rect = CGRect(x: k.point.x - r, y: k.point.y - r, width: r * 2, height: r * 2)
            let diamond = NSBezierPath()
            diamond.move(to: CGPoint(x: rect.midX, y: rect.minY)); diamond.line(to: CGPoint(x: rect.maxX, y: rect.midY))
            diamond.line(to: CGPoint(x: rect.midX, y: rect.maxY)); diamond.line(to: CGPoint(x: rect.minX, y: rect.midY))
            diamond.close()
            (k.id == selectedKey ? Theme.Colors.accent : Theme.Colors.yellow).setFill(); diamond.fill()
            Theme.black(0.7).setStroke(); diamond.lineWidth = 1; diamond.stroke()
        }
    }
}
