import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit

/// The Program monitor's transform overlay on the canvas: the Mac `TransformOverlayView` translated (layer quad, scale
/// and rotate handles, anchor ring, smart and spacing guides, Crop edge handles, the motion path of the position keys).
/// All math is the shared `TransformOverlayGeometry` / `MotionPathGeometry` / `CropHandleGeometry`; this class only
/// routes presses and draws. One gesture = began, changed..., ended (the host makes it one undo step); Esc cancels it.
/// Coordinates: window points (the monitor panel converts from pixels); `canvasRect` is where the sequence is shown.
/// Effect point handles (an effect's center, Corner Warp corners) sit on top of everything else. The selected clip's
/// masks are drawn and edited on the layer (TransformOverlay+Masks); with the Mask tool on, the box rests and presses
/// draw masks.
/// Text editing and Magic picks live in MonitorPanel+Text and the Mask tool half of this class.
@MainActor
public final class TransformOverlay {
    public enum Phase: Sendable, Equatable { case began, changed, ended }

    /// Edit of a position key from the motion path. `tangents` is set for handle drags.
    public struct PathEdit: Sendable, Equatable {
        public var key: UUID
        public var position: Vec2?
        public var tangents: (in: Vec2, out: Vec2)?
        public init(key: UUID, position: Vec2?, tangents: (in: Vec2, out: Vec2)?) {
            self.key = key; self.position = position; self.tangents = tangents
        }
        public static func == (a: PathEdit, b: PathEdit) -> Bool {
            a.key == b.key && a.position == b.position && a.tangents?.in == b.tangents?.in && a.tangents?.out == b.tangents?.out
        }
    }

    /// Transform gesture: began with the start transform, changed / ended with the new one (display space).
    public var onTransform: ((Phase, ClipTransform) -> Void)?
    public var onPathEdit: ((Phase, PathEdit) -> Void)?
    /// Crop edge drag: the edge and its inset (fraction of the frame).
    public var onCrop: ((Phase, CropEdge, Double) -> Void)?
    /// Point-parameter handle drag: the handle id and its offset (sequence px from the canvas center).
    public var onPointHandle: ((Phase, String, Vec2) -> Void)?
    /// Esc during a drag: the host puts the clip back as it was at the press.
    public var onDragCanceled: (() -> Void)?
    /// Modifier keys held now (drags carry none); nil = the keys held at the press.
    public var modifiersNow: (() -> InputModifiers)?

    /// Shown and grabbable (a picture clip is selected under the playhead, not playing).
    public var isShown = false
    public var sequenceSize = CGSize(width: 1920, height: 1080)
    /// Upright native size of the picture in sequence px (scale 1 = this size).
    public var mediaPixelSize: CGSize?
    /// The target's display transform at the playhead; ignored for drawing while a gesture runs.
    public var transform = ClipTransform.identity
    public var positionTrack = KeyframeTrack<Vec2>()
    public var selectedKey: UUID?
    public var uniformScale = true
    /// Smart guide targets for moves; nil = none.
    public var snapTargets: SnapGuides.Targets?
    public var neighborBounds: [CGRect] = []
    /// Dashed action / title safe frames while Safe Margins is on (drawn with the layer).
    public var safeAreas: [SafeArea] = []
    /// Crop effect selected in Effect Controls: edge handles instead of scale and rotate handles.
    public var cropInsets: CropInsets?
    /// Point parameters of the selected clip's effects (the host maps them through the clip's transform).
    public var pointHandles: [PointHandle] = []

    /// The selected clip's masks at the playhead (frame fractions); the active one shows its tangent handles.
    public var masks: [MaskOverlay] = []
    /// Mask tool mode (nil = Selection tool): the transform box rests, the masks' handles still edit, every other press
    /// on the layer is a tool press (Pen point, Ellipse / Rectangle click or drag).
    public var maskTool: MaskToolMode?
    /// Mask Tint (the Mac `maskTints`): the image slot holding the Magic mattes' coverage (white, alpha), drawn yellow
    /// over the layer under the mask outlines while the Mask tool is on. nil: no tint.
    public var maskTintSlot: Int?
    /// A vertex drag (frame fraction of the vertex).
    public var onMaskVertex: ((Phase, ClipMask.ID, Int, Vec2) -> Void)?
    /// Pen handles of a mask: drags send began, changed..., ended; a click sends began + ended.
    public var onMaskEdit: ((Phase, MaskHandleEdit) -> Void)?
    /// A Mask tool click on the layer (frame fraction, modifier keys at the press).
    public var onMaskToolClick: ((Vec2, InputModifiers) -> Void)?
    /// Magic mode only: the pointer moved over the layer (frame fraction), or left it (nil); sent when that changes.
    public var onMaskToolHover: ((Vec2?) -> Void)?
    /// Magic mode: the Add | Remove switch (top left of the picture). true = Remove; Option at the click flips it.
    public var magicSubtract = false
    var magicHoverPoint: Vec2?
    /// Ellipse / Rectangle dragged out with the Mask tool: the shape, sent once on release.
    public var onMaskShapeDrawn: ((MaskShapeKind, MaskPath) -> Void)?
    /// A press picked mask `id` (its vertex, or inside it with a shape mode): the host selects it in Effect Controls.
    public var onMaskSelect: ((ClipMask.ID) -> Void)?

    public static let snapDistance: Double = 6

    enum Drag {
        case body(start: CGPoint, geo: TransformOverlayGeometry)
        case scale(TransformOverlayGeometry.Handle, start: CGPoint, geo: TransformOverlayGeometry)
        case rotate(start: CGPoint, geo: TransformOverlayGeometry, last: Double)
        case anchor(start: CGPoint, geo: TransformOverlayGeometry)
        case key(UUID)
        case tangent(UUID, MotionPathGeometry.Hit, current: (in: Vec2, out: Vec2))
        case crop(CropEdge)
        case point(PointHandle, grab: CGPoint)
        case maskVertex(ClipMask.ID, Int)
        case maskTangent(ClipMask.ID, Int, out: Bool, last: Vec2, independent: Bool)
        case maskMove(ClipMask.ID, start: Vec2, base: MaskPath, last: Vec2)
        case maskPen(ClipMask.ID, segment: Int, t: Double, base: MaskPath, last: Vec2, independent: Bool)
        /// Mask tool press (Pen / shapes): nothing is placed until release; shapes rubber-band while dragging.
        case maskTool(MaskToolMode, start: Vec2, startView: CGPoint, modifiers: InputModifiers, moved: Bool)

        /// A drag that rewrites a mask path live (Esc puts the masks back as they were at the press).
        var isMaskEdit: Bool {
            switch self {
            case .maskVertex, .maskTangent, .maskMove, .maskPen: true
            default: false
            }
        }
    }
    var drag: Drag? {
        didSet { if oldValue == nil, drag?.isMaskEdit == true { masksAtPress = masks } }
    }
    var masksAtPress: [MaskOverlay]?
    /// The Ellipse / Rectangle being dragged out.
    var drawPreview: MaskPath?
    private var pressModifiers: InputModifiers = []
    /// The hover cursor at the press: a handle drag keeps it (the Mac sets it on hover and leaves it during the drag).
    private var heldCursor: DrawCursor?
    var canvasRect: CGRect = .zero
    private var liveTransform: ClipTransform?
    private var liveCrop: CropInsets?
    private var livePoints: [String: Vec2] = [:]
    private var activeGuides = SnapGuides.Result.none
    private var activeGaps: [SpacingGuides.Gap] = []

    public init() {}

    public var isDragging: Bool { drag != nil }

    // MARK: Geometry

    func geometry(in r: CGRect) -> TransformOverlayGeometry {
        let aspect = mediaPixelSize.map { $0.height > 0 ? Double($0.width / $0.height) : 16.0 / 9 } ?? 16.0 / 9
        return TransformOverlayGeometry(sequenceSize: sequenceSize, viewRect: r, mediaAspect: aspect,
                                        transform: liveTransform ?? transform, mediaPixelSize: mediaPixelSize)
    }
    private func pointGeometry(in r: CGRect) -> PointHandleGeometry {
        PointHandleGeometry(sequenceSize: sequenceSize, viewRect: r)
    }
    /// The handles where they are shown now (a running drag shows its live offset).
    var displayedPoints: [PointHandle] {
        pointHandles.map { PointHandle(id: $0.id, offset: livePoints[$0.id] ?? $0.offset) }
    }
    private func pointHit(_ p: CGPoint, in r: CGRect) -> PointHandle? {
        let shown = displayedPoints
        guard let id = pointGeometry(in: r).hitTest(p, handles: shown) else { return nil }
        return shown.first { $0.id == id }
    }
    private func pathGeometry(in r: CGRect) -> MotionPathGeometry? {
        positionTrack.isEmpty ? nil : MotionPathGeometry(track: positionTrack, sequenceSize: sequenceSize, viewRect: r)
    }
    private func cropEdge(at p: CGPoint, _ g: TransformOverlayGeometry) -> CropEdge? {
        guard let i = liveCrop ?? cropInsets else { return nil }
        return CropHandleGeometry(quad: g.quad).hit(p, i)
    }
    /// The box hit under `p`; in crop mode only the picture moves (no scale or rotate handles).
    private func transformHit(_ p: CGPoint, _ g: TransformOverlayGeometry) -> TransformOverlayGeometry.Hit? {
        let hit = g.hitTest(p)
        guard cropInsets != nil, let hit else { return hit }
        switch hit {
        case .handle: return .body
        case .rotate: return nil
        default: return hit
        }
    }

    /// True when a press at `p` lands on the overlay (else it falls through to the monitor below).
    public func hits(_ p: CGPoint, canvasRect r: CGRect) -> Bool {
        guard isShown, !r.isEmpty else { return false }
        if let mode = maskTool {
            if mode == .magic, magicSwitchHit(p, in: r) != nil { return true }
            if mode != .magic, maskHit(p, in: r) != nil { return true }
            return maskFramePoint(p, in: r) != nil
        }
        if pointHit(p, in: r) != nil { return true }
        let g = geometry(in: r)
        if cropEdge(at: p, g) != nil { return true }
        if maskHit(p, in: r) != nil { return true }
        if pathGeometry(in: r)?.hitTest(p, selectedKey: selectedKey) != nil { return true }
        return transformHit(p, g) != nil
    }

    // MARK: Hover cursor (TransformOverlayView.mouseMoved / updateCursor)

    /// The pointer shape over the overlay at `p`, nil when it is not on a handle (the monitor's own cursor stays).
    /// Like the Mac `TransformOverlayView.updateCursor`: rotate arrows toward the corner, a resize arrow along the
    /// handle, the four-way move over the body, the crosshair on the anchor.
    public func hoverCursor(at p: CGPoint, canvasRect r: CGRect) -> DrawCursor? {
        guard isShown, !r.isEmpty else { return nil }
        if maskTool == .magic, magicSwitchHit(p, in: r) != nil { return nil }
        if let mode = maskTool {
            // Mask tool: the whole overlay is a crosshair, the active mask's inside moves it (Pen / shapes).
            if mode != .magic, case .inside? = maskHit(p, in: r) { return .move }
            return maskFramePoint(p, in: r) != nil ? .crosshair : nil
        }
        if pointHit(p, in: r) != nil { return .crosshair }
        let g = geometry(in: r)
        if let e = cropEdge(at: p, g) { return e.isVertical ? .resizeLeftRight : .resizeUpDown }
        if let h = maskHit(p, in: r) { if case .inside = h { return .move }; return .crosshair }
        guard let hit = transformHit(p, g) else { return nil }
        switch hit {
        case .anchor: return .crosshair
        case .rotate(let h): return DrawCursor.rotate(angle: g.viewAngle(of: h))
        case .body: return .move
        case .handle(let h): return Self.resizeCursor(angle: g.viewAngle(of: h))
        }
    }

    /// The pointer shape while a drag runs (HostHover forgets the request on every drag event): the closed hand for a
    /// picture or mask move, the hover shape kept for handles, nil for motion path keys.
    public var dragCursor: DrawCursor? {
        switch drag {
        case nil, .key?, .tangent?: return nil
        case .body?, .maskMove?: return .closedHand
        default: return heldCursor
        }
    }

    /// Edge handles resize along their axis, corner handles along a diagonal.
    static func resizeCursor(angle: Double) -> DrawCursor { DrawCursor.resize(angle: angle) }

    // MARK: Input (TransformOverlayView's mouse handling)

    /// A left press; true when the overlay took it.
    public func mouseDown(_ p: CGPoint, modifiers: InputModifiers, canvasRect r: CGRect) -> Bool {
        guard hits(p, canvasRect: r) else { return false }
        canvasRect = r
        pressModifiers = modifiers
        heldCursor = hoverCursor(at: p, canvasRect: r)
        if maskTool == .magic, let remove = magicSwitchHit(p, in: r) { magicSubtract = remove; return true }
        if maskTool != nil { return maskToolDown(p, modifiers: modifiers) }
        // Point-parameter handles sit on top of everything else.
        if let h = pointHit(p, in: r) {
            drag = .point(h, grab: p)
            onPointHandle?(.began, h.id, h.offset)
            return true
        }
        let g = geometry(in: r)
        if let edge = cropEdge(at: p, g), let i = cropInsets {
            drag = .crop(edge)
            liveCrop = i
            onCrop?(.began, edge, edge.value(in: i))
            return true
        }
        if maskHandlesDown(p, modifiers: modifiers) { return true }
        if let path = pathGeometry(in: r), let hit = path.hitTest(p, selectedKey: selectedKey) {
            switch hit {
            case .key(let id):
                drag = .key(id)
                onPathEdit?(.began, PathEdit(key: id, position: path.keyValue(at: p), tangents: nil))
            case .inTangent(let id), .outTangent(let id):
                let k = positionTrack.key(id: id)
                let current = (k?.inTangent ?? .zero, k?.outTangent ?? .zero)
                drag = .tangent(id, hit, current: current)
                onPathEdit?(.began, PathEdit(key: id, position: nil, tangents: current))
            }
            return true
        }
        guard var hit = transformHit(p, g) else { return false }
        // Alt-drag on the picture moves the anchor point, not the picture.
        if hit == .body, modifiers.contains(.option) { hit = .anchor }
        switch hit {
        case .body: drag = .body(start: p, geo: g)
        case .handle(let h): drag = .scale(h, start: p, geo: g)
        case .rotate: drag = .rotate(start: p, geo: g, last: g.transform.rotation)
        case .anchor: drag = .anchor(start: p, geo: g)
        }
        liveTransform = g.transform
        onTransform?(.began, g.transform)
        return true
    }

    public func mouseDragged(_ p: CGPoint) {
        guard let d = drag else { return }
        let mods = modifiersNow?() ?? pressModifiers
        let shift = mods.contains(.shift), option = mods.contains(.option)
        switch d {
        case .body(let s, let g):
            emit(snapped(g.moved(from: s, to: p, lockAxis: shift), geo: g, disabled: mods.contains(.command), lockAxis: shift))
        case .scale(let h, let s, let g):
            emit(g.scaled(handle: h, from: s, to: p, modifiers: .init(shift: shift, option: option, uniformScale: uniformScale)))
        case .rotate(let s, let g, let last):
            let t = g.rotated(from: s, to: p, snap: shift, continuingFrom: last)
            drag = .rotate(start: s, geo: g, last: t.rotation)
            emit(t)
        case .anchor(let s, let g):
            emit(g.anchorMoved(from: s, to: p))
        case .crop(let edge):
            guard let base = liveCrop else { return }
            let v = CropHandleGeometry(quad: geometry(in: canvasRect).quad).inset(edge, at: p, current: base)
            liveCrop = edge.setting(v, in: base)
            onCrop?(.changed, edge, v)
        case .key(let id):
            guard let path = pathGeometry(in: canvasRect) else { return }
            onPathEdit?(.changed, PathEdit(key: id, position: path.keyValue(at: p), tangents: nil))
        case .tangent(let id, let side, let current):
            guard let path = pathGeometry(in: canvasRect) else { return }
            let t = path.tangents(forKey: id, dragging: side, to: p, independent: option, current: current)
            drag = .tangent(id, side, current: t)
            onPathEdit?(.changed, PathEdit(key: id, position: nil, tangents: t))
        case .point(let h, let grab):
            let snap = snapTargets.map { PointHandleGeometry.Snap(targets: $0, viewThreshold: Self.snapDistance) }
            let r = pointGeometry(in: canvasRect).dragged(h, grabbedAt: grab, to: p, lockAxis: shift,
                                                          snap: mods.contains(.command) ? nil : snap)
            activeGuides = r.guides
            livePoints[h.id] = r.offset
            onPointHandle?(.changed, h.id, r.offset)
        case .maskVertex, .maskTangent, .maskPen, .maskMove, .maskTool:
            maskDragged(d, to: p, shift: shift, option: option)
        }
    }

    public func mouseUp(_ p: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .crop(let edge):
            let g = geometry(in: canvasRect)
            let v = CropHandleGeometry(quad: g.quad).inset(edge, at: p, current: liveCrop ?? cropInsets ?? .none)
            onCrop?(.ended, edge, v)
            liveCrop = nil
        case .key(let id):
            onPathEdit?(.ended, PathEdit(key: id, position: pathGeometry(in: canvasRect)?.keyValue(at: p), tangents: nil))
        case .tangent(let id, _, let current):
            onPathEdit?(.ended, PathEdit(key: id, position: nil, tangents: current))
        case .point(let h, _):
            onPointHandle?(.ended, h.id, livePoints[h.id] ?? h.offset)
            livePoints[h.id] = nil
            activeGuides = .none; activeGaps = []
        case .maskVertex, .maskTangent, .maskPen, .maskMove, .maskTool:
            maskUp(d, at: p)
        default:
            if let t = liveTransform { onTransform?(.ended, t) }
            liveTransform = nil
            activeGuides = .none; activeGaps = []
        }
    }

    /// Esc: drops the running drag; true when there was one (the key is consumed).
    public func cancelDrag() -> Bool {
        guard let d = drag else { return false }
        drag = nil
        if d.isMaskEdit, let saved = masksAtPress { masks = saved }
        masksAtPress = nil
        drawPreview = nil
        if case .maskTool = d { return true }   // nothing was applied yet: no host revert
        liveTransform = nil
        liveCrop = nil
        livePoints = [:]
        activeGuides = .none; activeGaps = []
        onDragCanceled?()
        return true
    }

    /// Smart guides: the moved layer's edges and center snap to the canvas and the other layers.
    private func snapped(_ t: ClipTransform, geo g: TransformOverlayGeometry, disabled: Bool, lockAxis: Bool) -> ClipTransform {
        guard !disabled, let targets = snapTargets, g.viewScale > 0 else { activeGuides = .none; activeGaps = []; return t }
        let box = LayerBounds.rect(size: g.fittedSize, transform: t)
        let r = SnapGuides.snap(box: box, targets: targets, threshold: Self.snapDistance / g.viewScale)
            .locking(x: lockAxis && t.position.x == g.transform.position.x, y: lockAxis && t.position.y == g.transform.position.y)
        activeGuides = r
        var out = t
        out.position = Vec2(t.position.x + r.dx, t.position.y + r.dy)
        activeGaps = []
        if !lockAxis, !neighborBounds.isEmpty {
            let moved = LayerBounds.rect(size: g.fittedSize, transform: out)
            let s = SpacingGuides.snap(box: moved, others: neighborBounds, threshold: Self.snapDistance / g.viewScale)
            let useX = r.verticalLines.isEmpty && s.dx != 0, useY = r.horizontalLines.isEmpty && s.dy != 0
            if useX { out.position.x += s.dx }
            if useY { out.position.y += s.dy }
            activeGaps = s.gaps.filter { $0.vertical ? useY : useX }
        }
        return out
    }

    private func emit(_ t: ClipTransform) {
        liveTransform = t
        onTransform?(.changed, t)
    }

    // MARK: Drawing (TransformOverlayView.draw)

    public func draw(_ c: inout Canvas, canvasRect r: CGRect, theme t: DrawTheme) {
        guard isShown, !r.isEmpty else { return }
        let stroke = t.onPictureStroke, shadow = t.onPictureShadow, yellow = t.yellow
        defer { drawPointHandles(&c, in: r, theme: t) }
        let g = geometry(in: r)
        for a in safeAreas {
            let s = a.rect(in: sequenceSize)
            let tl = g.viewPoint(fromOffset: Vec2(Double(s.minX), Double(s.minY)))
            let br = g.viewPoint(fromOffset: Vec2(Double(s.maxX), Double(s.maxY)))
            let rect = CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
            MonitorPanel.dashedRect(&c, rect, dash: 4, gap: 3, stroke.alpha(0.7))
        }
        if let path = pathGeometry(in: r) { drawMotionPath(&c, path, theme: t) }
        if drag != nil { drawGuides(&c, g, in: r, theme: t) }
        if maskTool != nil {                   // Mask tool: masks and the shape being drawn, no box
            drawMaskTint(&c, in: r, theme: t)
            drawMasks(&c, in: r, theme: t)
            drawShapePreview(&c, in: r, theme: t)
            if maskTool == .magic { drawMagicSwitch(&c, in: r, theme: t) }
            return
        }
        drawMasks(&c, in: r, theme: t)

        let q = g.quad
        c.stroke(polygon: q, width: 1, stroke)
        if let i = liveCrop ?? cropInsets {
            let cg = CropHandleGeometry(quad: q)
            let kept = cg.corners(i)
            if !i.isIdentity {
                c.stroke(polygon: kept, width: 3, shadow)
                c.stroke(polygon: kept, width: 1, yellow)
            }
            for e in CropEdge.allCases {
                let p = cg.handlePoint(e, i)
                let w: CGFloat = e.isVertical ? 5 : 11, h: CGFloat = e.isVertical ? 11 : 5
                let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
                c.fill(rect, yellow)
                c.stroke(polygon: Self.corners(rect), width: 1, shadow)
            }
            return
        }
        // Board "Transform box": white 1 pt frame, white 8 pt squares with a dark edge, a white ring at the anchor.
        for h in TransformOverlayGeometry.Handle.allCases {
            let p = g.viewPoint(of: h)
            let rect = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            c.fill(rect, stroke)
            c.stroke(polygon: Self.corners(rect), width: 1, shadow)
        }
        let a = g.anchorViewPoint
        c.stroke(ellipseIn: CGRect(x: a.x - 5, y: a.y - 5, width: 10, height: 10), width: 1.2, stroke)
    }

    /// Accent dots with a white edge over a soft dark ring (TransformOverlayView.drawPointHandles).
    private func drawPointHandles(_ c: inout Canvas, in r: CGRect, theme t: DrawTheme) {
        let geo = pointGeometry(in: r)
        for h in displayedPoints {
            let p = geo.viewPoint(fromOffset: h.offset)
            let ring = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            c.stroke(ellipseIn: ring, width: 3, t.onPictureShadow)
            c.fill(ellipseIn: ring, t.accent)
            c.stroke(ellipseIn: ring, width: 1.5, t.onPictureStroke)
        }
    }

    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    private func drawGuides(_ c: inout Canvas, _ g: TransformOverlayGeometry, in r: CGRect, theme t: DrawTheme) {
        let color = t.guideSnap
        let k = CGFloat(g.viewScale)
        for gap in activeGaps {
            let a = CGFloat(gap.from) * k, b = CGFloat(gap.to) * k, x = CGFloat(gap.cross) * k
            if gap.vertical {
                c.strokeLine(from: CGPoint(x: r.midX + x, y: r.midY + a), to: CGPoint(x: r.midX + x, y: r.midY + b), width: 2, color)
            } else {
                c.strokeLine(from: CGPoint(x: r.midX + a, y: r.midY + x), to: CGPoint(x: r.midX + b, y: r.midY + x), width: 2, color)
            }
        }
        for x in activeGuides.verticalLines {
            let vx = r.midX + CGFloat(x) * k
            c.strokeLine(from: CGPoint(x: vx, y: r.minY), to: CGPoint(x: vx, y: r.maxY), width: 1, color)
        }
        for y in activeGuides.horizontalLines {
            let vy = r.midY + CGFloat(y) * k
            c.strokeLine(from: CGPoint(x: r.minX, y: vy), to: CGPoint(x: r.maxX, y: vy), width: 1, color)
        }
    }

    private func drawMotionPath(_ c: inout Canvas, _ path: MotionPathGeometry, theme t: DrawTheme) {
        let shadow = t.onPictureShadow
        for seg in path.segments where seg.count > 1 {
            c.strokePolyline(seg, width: 3, shadow)
            c.strokePolyline(seg, width: 1, t.yellow)
        }
        for k in path.keys {
            let showIn = k.id == selectedKey || k.hasInTangent
            let showOut = k.id == selectedKey || k.hasOutTangent
            for (show, h) in [(showIn, k.inHandle), (showOut, k.outHandle)] where show && h != k.point {
                c.strokeLine(from: k.point, to: h, width: 1, t.label2)
                let dot = CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7)
                c.fill(ellipseIn: dot, t.yellow)
                c.stroke(ellipseIn: dot, width: 1, shadow)
            }
            let r: CGFloat = 4.5
            let diamond = [CGPoint(x: k.point.x, y: k.point.y - r), CGPoint(x: k.point.x + r, y: k.point.y),
                           CGPoint(x: k.point.x, y: k.point.y + r), CGPoint(x: k.point.x - r, y: k.point.y)]
            c.fill(polygon: diamond, k.id == selectedKey ? t.accent : t.yellow)
            c.stroke(polygon: diamond, width: 1, shadow)
        }
    }
}
