import AppKit
import SQCore

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
    /// Snap lines for moves (canvas center and edges, other layers); nil = no smart guides.
    public var snapTargets: SnapGuides.Targets?
    /// Bounds of the other layers (offset space): spacing guides snap the moved layer to equal gaps between them.
    public var neighborBounds: [CGRect] = []
    private var activeGaps: [SpacingGuides.Gap] = []
    /// Evaluated transform at the playhead. Ignored for display while a gesture is running.
    public var transform = ClipTransform.identity { didSet { if drag == nil { needsDisplay = true } } }
    public var positionTrack = KeyframeTrack<Vec2>() { didSet { needsDisplay = true } }
    public var selectedKey: UUID? { didSet { needsDisplay = true } }
    /// The clip's Uniform Scale flag (Effect Controls): on = every handle scales proportionally.
    public var uniformScale = true
    /// Point parameters (effect centers etc.) of the selected clip, drawn as draggable handles.
    public var pointHandles: [PointHandle] = [] { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// Point handle gesture: new offset (sequence px from the canvas center) for the handle id.
    public var onPointHandle: ((Phase, String, Vec2) -> Void)?
    /// Title / action safe frames drawn on the canvas.
    public var safeAreas: [SafeArea] = [] { didSet { needsDisplay = true } }
    /// W6.7: the selected clip's masks (paths at the playhead), drawn on the layer; vertices drag (frame fractions).
    public var masks: [MaskOverlay] = [] { didSet { needsDisplay = true } }
    public var onMaskVertex: ((Phase, ClipMask.ID, Int, Vec2) -> Void)?
    /// Pen handles of the active mask. Drags send began (nothing to apply yet), changed..., ended; a click sends began + ended.
    public var onMaskEdit: ((Phase, MaskEdit) -> Void)?

    /// One pen-handle edit of a mask (frame fractions): the shared `MaskHandleEdit` (SQDrawMonitor), so the canvas
    /// overlay on Windows sends the same edits.
    public typealias MaskEdit = MaskHandleEdit
    /// Crop handles: the insets of the clip's selected Crop effect (fractions of its frame); nil = no crop mode. In crop
    /// mode the four edge handles drag, the scale and rotate handles rest, and the picture still moves.
    public var cropInsets: CropInsets? { didSet { if cropInsets != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    /// One crop gesture: `began` with the edge's inset, `changed` and `ended` with the new inset (fraction 0...1).
    public var onCrop: ((Phase, CropEdge, Double) -> Void)?
    public var showsOverlay = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// False = the frame is only drawn (Type tool, while editing text): no hit testing, no hover cursor, no drags.
    public var isInteractive = true { didSet { if !isInteractive { hoverHit = nil; drag = nil } } }
    /// Mask tool mode (nil = Selection tool). The transform box is hidden and takes no clicks; in Pen mode the mask handles
    /// still edit; every other click on the picture reports `onMaskToolClick` (frame fraction, modifier keys).
    public var maskTool: MaskToolMode? {
        didSet { if maskTool != oldValue { magicHover = nil; magicPreview = nil; magicPointer = nil; needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    }
    public var onMaskToolClick: ((Vec2, NSEvent.ModifierFlags) -> Void)?
    /// Ellipse / Rectangle: a drag drew this shape (rubber band, Shift = square / circle, Option = from the center);
    /// sent once on release. A press without a drag is an `onMaskToolClick` (default-size shape) instead.
    public var onMaskShapeDrawn: ((MaskShapeKind, MaskPath) -> Void)?
    /// A click picked mask `id` on the picture (its handles, or inside a mask with a shape mode): select it.
    public var onMaskSelect: ((ClipMask.ID) -> Void)?
    /// Magic mode: the pointer moved to this frame fraction of the layer (nil = left the picture).
    public var onMagicHover: ((Vec2?) -> Void)?
    /// False while the targeted clip is one Magic cannot work on (a title, a still, a nested sequence): presses then go to
    /// the monitor below, which selects the video clip under the pointer.
    public var magicUsable = true
    /// Magic mode with no usable clip targeted: the pointer moved (window point). The monitor targets the clip under it.
    public var onMagicPointerWithoutTarget: ((NSPoint) -> Void)?
    /// Magic highlights on the layer: the object under the pointer and the current pick (row 0 = top of the frame).
    public var magicHover: CGImage? { didSet { needsDisplay = true } }
    public var magicPick: CGImage? { didSet { needsDisplay = true } }
    /// Where the picture of a clip lies that Magic previews without it being selected (`magicPreview`).
    public struct MagicPreviewLayer: Equatable {
        public var transform: ClipTransform
        public var mediaPixelSize: CGSize?
        public init(transform: ClipTransform, mediaPixelSize: CGSize?) {
            self.transform = transform; self.mediaPixelSize = mediaPixelSize
        }
    }
    public var magicPreviewLayer: MagicPreviewLayer? { didSet { if magicPreviewLayer != oldValue { needsDisplay = true } } }
    /// Magic's highlight on a clip that is not selected (hover never selects): drawn over `magicPreviewLayer`, also
    /// while the overlay itself shows nothing.
    public var magicPreview: CGImage? { didSet { needsDisplay = true } }
    /// The pointer over this view with the Magic tool (window point; nil = outside).
    public private(set) var magicPointer: NSPoint?
    private func previewGeometry(_ layer: MagicPreviewLayer) -> MaskOverlayGeometry {
        let aspect = layer.mediaPixelSize.map { $0.height > 0 ? $0.width / $0.height : mediaAspect } ?? mediaAspect
        return MaskOverlayGeometry(quad: TransformOverlayGeometry(sequenceSize: sequenceSize, viewRect: canvasRect,
                                                                  mediaAspect: aspect, transform: layer.transform,
                                                                  mediaPixelSize: layer.mediaPixelSize).quad)
    }
    /// Frame fraction of `layer`'s picture under the pointer; nil beside it or with the pointer outside.
    public func magicPreviewPoint(_ layer: MagicPreviewLayer) -> Vec2? {
        guard let w = magicPointer, !canvasRect.isEmpty,
              let n = previewGeometry(layer).framePoint(convert(w, from: nil)),
              (0...1).contains(n.x), (0...1).contains(n.y) else { return nil }
        return n
    }
    /// Magic: the click points of the active mask on the shown frame.
    public var magicMarkers: [MagicMarker] = [] { didSet { if magicMarkers != oldValue { needsDisplay = true } } }
    /// Magic: what a click does (the monitor's Add | Remove switch); Option flips it while held.
    public var magicMode: MagicClickMode = .add { didSet { shownMagicMode = nil } }
    /// Magic: the mode a click would use now changed (Option pressed or released): the switch shows it.
    public var onMagicModeShown: ((MagicClickMode) -> Void)?
    private var shownMagicMode: MagicClickMode?
    /// Reports the mode with Option held or not (pointer moves and key changes carry the modifier keys).
    private func noteMagicFlags(_ flags: NSEvent.ModifierFlags) {
        let m = magicMode.effective(option: flags.contains(.option))
        guard m != shownMagicMode else { return }
        shownMagicMode = m
        onMagicModeShown?(m)
    }
    /// Matte tints of the clip's tracked masks (Program monitor Mask Tint), under the pick and hover highlights.
    public var maskTints: [CGImage] = [] { didSet { needsDisplay = true } }

    private enum Drag {
        case body(start: CGPoint, geo: TransformOverlayGeometry)
        case scale(TransformOverlayGeometry.Handle, start: CGPoint, geo: TransformOverlayGeometry)
        case rotate(start: CGPoint, geo: TransformOverlayGeometry, last: Double)
        case anchor(start: CGPoint, geo: TransformOverlayGeometry)
        case key(UUID)
        case point(PointHandle, grab: CGPoint)
        case maskVertex(ClipMask.ID, Int)
        case maskTangent(ClipMask.ID, Int, out: Bool, last: Vec2, independent: Bool)
        case maskMove(ClipMask.ID, start: Vec2, base: MaskPath, last: Vec2)
        case maskPen(ClipMask.ID, segment: Int, t: Double, base: MaskPath, last: Vec2, independent: Bool)
        case tangent(UUID, MotionPathGeometry.Hit, current: (in: Vec2, out: Vec2))
        /// Mask tool press (Pen / shapes): nothing is placed until release; shapes rubber-band while dragging.
        case maskTool(MaskToolMode, start: Vec2, startView: CGPoint, flags: NSEvent.ModifierFlags, moved: Bool)
        case crop(CropEdge)

        /// A drag that rewrites a mask path live (vertex, tangent, pen handle, move).
        var isMaskEdit: Bool {
            switch self {
            case .maskVertex, .maskTangent, .maskMove, .maskPen: true
            default: false
            }
        }
    }
    private var drag: Drag? {
        didSet {
            // A mask drag edits `masks` live; Esc puts them back as they were at the press.
            if oldValue == nil, drag?.isMaskEdit == true { masksAtPress = masks }
            updateEscapeMonitor()
        }
    }
    private var masksAtPress: [MaskOverlay]?
    /// Esc during a transform, anchor, path-key, tangent, point, crop or mask drag (also a shape being drawn): the host
    /// puts the clip back as it was at the press.
    public var onDragCancelled: (() -> Void)?
    private var escapeMonitor: Any?
    /// The shape being drawn (live preview, frame fractions).
    private var drawPreview: MaskPath?
    /// Smart guides of the running move (drawn while dragging).
    private var activeGuides = SnapGuides.Result.none
    public static let snapDistance: Double = 6   // view px
    private var liveTransform: ClipTransform?
    private var livePoints: [String: Vec2] = [:]
    private var liveCrop: CropInsets?
    private var hoverHit: TransformOverlayGeometry.Hit?
    private var tracking: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }

    private var dragIsCancellable: Bool {
        switch drag {
        case .body, .scale, .rotate, .anchor, .key, .point, .tangent, .crop,
             .maskVertex, .maskTangent, .maskMove, .maskPen, .maskTool: true
        default: false
        }
    }

    private func updateEscapeMonitor() {
        if dragIsCancellable, escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                let consumed = MainActor.assumeIsolated { self?.cancelDragFromEscape() == true }
                return consumed ? nil : event
            }
        } else if !dragIsCancellable, let m = escapeMonitor {
            NSEvent.removeMonitor(m)
            escapeMonitor = nil
        }
    }

    /// Leaving the window ends a running gesture: the Escape monitor must not outlive the view, and the host puts the
    /// clip back (the release can no longer arrive).
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, drag != nil { _ = cancelDragFromEscape() }
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
    }

    /// True when a drag was canceled (the key is consumed). The following drag and release events are ignored.
    private func cancelDragFromEscape() -> Bool {
        guard dragIsCancellable else { return false }
        let drawing: Bool
        if case .maskTool = drag { drawing = true } else { drawing = false }   // nothing was applied yet: no host revert
        let wasMaskEdit = drag?.isMaskEdit == true
        drag = nil
        if wasMaskEdit, let saved = masksAtPress { masks = saved }
        masksAtPress = nil
        drawPreview = nil
        liveTransform = nil
        livePoints = [:]
        liveCrop = nil
        activeGuides = .none; activeGaps = []
        if !drawing { onDragCancelled?() }
        needsDisplay = true
        return true
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var geometry: TransformOverlayGeometry {
        TransformOverlayGeometry(sequenceSize: sequenceSize, viewRect: canvasRect, mediaAspect: mediaAspect,
                                 transform: liveTransform ?? transform,
                                 mediaPixelSize: mediaPixelSize)
    }
    private var pointGeometry: PointHandleGeometry {
        PointHandleGeometry(sequenceSize: sequenceSize, viewRect: canvasRect)
    }
    private var displayedPoints: [PointHandle] {
        pointHandles.map { PointHandle(id: $0.id, offset: livePoints[$0.id] ?? $0.offset) }
    }
    private var maskGeometry: MaskOverlayGeometry { MaskOverlayGeometry(quad: geometry.quad) }
    private var pathGeometry: MotionPathGeometry? {
        positionTrack.isEmpty ? nil
            : MotionPathGeometry(track: positionTrack, sequenceSize: sequenceSize, viewRect: canvasRect)
    }

    // MARK: Hit routing

    /// Clicks outside every handle and the layer fall through to the monitor below.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard showsOverlay, isInteractive, !canvasRect.isEmpty else { return nil }
        let p = convert(point, from: superview)
        if drag != nil { return self }
        if let mode = maskTool {
            // The tool works on the targeted clip's picture (Pen and shapes also on their handles beside it); a press
            // anywhere else goes to the monitor below, which selects the clip there.
            guard bounds.contains(p) else { return nil }
            if mode == .magic, !magicUsable { return nil }
            if mode != .magic, !masks.isEmpty, maskHit(p) != nil { return self }
            return maskFramePoint(p) != nil ? self : nil
        }
        if pointGeometry.hitTest(p, handles: displayedPoints) != nil { return self }
        if cropEdge(at: p) != nil { return self }
        if !masks.isEmpty, maskHit(p) != nil { return self }
        if pathGeometry?.hitTest(p, selectedKey: selectedKey) != nil { return self }
        return transformHit(p) != nil ? self : nil
    }

    private var cropGeometry: CropHandleGeometry { CropHandleGeometry(quad: geometry.quad) }
    private func cropEdge(at p: CGPoint) -> CropEdge? {
        guard let i = liveCrop ?? cropInsets, maskTool == nil else { return nil }
        return cropGeometry.hit(p, i)
    }
    /// The transform box hit under `p`; in crop mode only the picture moves (no scale or rotate handles).
    private func transformHit(_ p: CGPoint) -> TransformOverlayGeometry.Hit? {
        let hit = geometry.hitTest(p)
        guard cropInsets != nil, let hit else { return hit }
        switch hit {
        case .handle: return .body
        case .rotate: return nil
        default: return hit
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    /// Frame fraction of the targeted layer under view point `p`; nil beside the picture.
    func maskFramePoint(_ p: CGPoint) -> Vec2? {
        guard let n = maskGeometry.framePoint(p), (0...1).contains(n.x), (0...1).contains(n.y) else { return nil }
        return n
    }

    /// A Mask tool press at window point `w` that reached the monitor instead (no clip was targeted there): once the host
    /// has targeted a clip, Magic picks at that point with the same press.
    func forwardMagicPress(atWindowPoint w: NSPoint, flags: NSEvent.ModifierFlags) {
        guard maskTool == .magic, magicUsable, showsOverlay, isInteractive, let n = maskFramePoint(convert(w, from: nil)) else { return }
        onMaskToolClick?(n, flags)
    }

    public override func mouseMoved(with event: NSEvent) {
        magicPointer = maskTool == .magic ? event.locationInWindow : nil
        if maskTool == .magic, !showsOverlay || !magicUsable { onMagicPointerWithoutTarget?(event.locationInWindow) }
        guard showsOverlay, isInteractive else { return }   // the monitor's own cursor (I-beam with the Type tool) stays
        let p = convert(event.locationInWindow, from: nil)
        if let mode = maskTool {
            if mode != .magic, !masks.isEmpty, let h = maskHit(p) {
                if case .inside = h { OverlayCursors.move.set() } else { NSCursor.crosshair.set() }
            } else { NSCursor.crosshair.set() }
            if mode == .magic { noteMagicFlags(event.modifierFlags) }
            if mode == .magic { onMagicHover?(maskGeometry.framePoint(p).flatMap { (0...1).contains($0.x) && (0...1).contains($0.y) ? $0 : nil }) }
            return
        }
        if pointGeometry.hitTest(p, handles: displayedPoints) != nil { NSCursor.crosshair.set(); hoverHit = nil; return }
        if let e = cropEdge(at: p) {
            (e.isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            hoverHit = nil
            return
        }
        if !masks.isEmpty, let h = maskHit(p) {
            if case .inside = h { OverlayCursors.move.set() } else { NSCursor.crosshair.set() }
            hoverHit = nil
            return
        }
        let hit = transformHit(p)
        if hit != hoverHit { hoverHit = hit; updateCursor(hit) }
    }
    public override func mouseExited(with event: NSEvent) {
        hoverHit = nil; if showsOverlay, isInteractive { NSCursor.arrow.set() }
        magicPointer = nil
        if magicPreview != nil { magicPreview = nil }
        if maskTool == .magic { onMagicHover?(nil); noteMagicFlags([]) }
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if maskTool == .magic { noteMagicFlags(event.modifierFlags) }
    }

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

    private enum MaskHit { case tangent(Int, Int, Bool), vertex(Int, Int), segment(Int, Int, Double), inside(Int) }

    /// Mask handles under `p`, nearest kind first: tangent handles and vertices, then the active outline, then its inside.
    private func maskHit(_ p: CGPoint) -> MaskHit? {
        let g = maskGeometry
        if let h = g.hitTangent(p, masks: masks) { return .tangent(h.mask, h.vertex, h.out) }
        if let h = g.hitVertex(p, masks: masks) { return .vertex(h.mask, h.vertex) }
        if let h = g.hitSegment(p, masks: masks) { return .segment(h.mask, h.segment, h.t) }
        if let i = g.hitInside(p, masks: masks) { return .inside(i) }
        return nil
    }

    /// A press on mask handles: starts a pen drag or sends a click edit. False for a plain vertex drag (the caller's).
    private func beginMaskEdit(_ hit: MaskHit, at p: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        switch hit {
        case .tangent(let mi, let vi, let isOut):
            let m = masks[mi], v = m.path.vertices[vi]
            let offset = isOut ? v.outTangent : v.inTangent, independent = flags.contains(.option)
            drag = .maskTangent(m.id, vi, out: isOut, last: offset, independent: independent)
            onMaskEdit?(.began, .tangent(m.id, vertex: vi, out: isOut, offset: offset, independent: independent))
        case .vertex(let mi, let vi):
            let id = masks[mi].id
            if flags.contains(.command) { click(.remove(id, vertex: vi)) }
            else if flags.contains(.option) { click(.toggleSmooth(id, vertex: vi)) }
            else { return false }
        case .segment(let mi, let seg, let t):
            let id = masks[mi].id
            drag = .maskPen(id, segment: seg, t: t, base: masks[mi].path, last: .zero, independent: false)
            onMaskEdit?(.began, .pen(id, segment: seg, t: t, handle: .zero, independent: false))
            onMaskEdit?(.changed, .pen(id, segment: seg, t: t, handle: .zero, independent: false))
            masks[mi].path = masks[mi].path.splitting(segment: seg, at: t)
        case .inside(let mi):
            guard let n = maskGeometry.framePoint(p) else { return true }
            drag = .maskMove(masks[mi].id, start: n, base: masks[mi].path, last: .zero)
            onMaskEdit?(.began, .move(masks[mi].id, delta: .zero))
            NSCursor.closedHand.set()
        }
        return true
    }

    private func click(_ e: MaskEdit) {
        onMaskEdit?(.began, e)
        onMaskEdit?(.ended, e)
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let mode = maskTool {
            // Pen and shapes: the masks' own handles keep working (Pen: vertices, tangents, outline, move; shapes:
            // vertices, tangents and moving the active mask); anything else is a tool press.
            if mode != .magic, !masks.isEmpty, let hit = maskHit(p) {
                var usable = true
                if mode != .pen, case .segment = hit { usable = false }   // shapes: the outline is no pen target
                if usable {
                    if case .vertex(let mi, _) = hit { onMaskSelect?(masks[mi].id) }
                    if beginMaskEdit(hit, at: p, flags: event.modifierFlags) { return }
                    if case .vertex(let mi, let vi) = hit {
                        let m = masks[mi]
                        drag = .maskVertex(m.id, vi)
                        onMaskVertex?(.began, m.id, vi, m.path.vertices[vi].point)
                        return
                    }
                }
            }
            guard let n = maskGeometry.framePoint(p), (0...1).contains(n.x), (0...1).contains(n.y) else { return }
            // Magic picks on the press (hover already shows what it takes); Pen and shapes act on release.
            if mode == .magic { onMaskToolClick?(n, event.modifierFlags); return }
            drag = .maskTool(mode, start: n, startView: p, flags: event.modifierFlags, moved: false)
            return
        }
        // Point-parameter handles sit on top of everything else.
        if let id = pointGeometry.hitTest(p, handles: displayedPoints), let h = displayedPoints.first(where: { $0.id == id }) {
            drag = .point(h, grab: p)
            onPointHandle?(.began, id, h.offset)
            return
        }
        if let edge = cropEdge(at: p), let i = cropInsets {
            drag = .crop(edge)
            liveCrop = i
            onCrop?(.began, edge, edge.value(in: i))
            return
        }
        if !masks.isEmpty, let hit = maskHit(p) {
            if case .vertex(let mi, _) = hit { onMaskSelect?(masks[mi].id) }
            if beginMaskEdit(hit, at: p, flags: event.modifierFlags) { return }
            if case .vertex(let mi, let vi) = hit {
                let m = masks[mi]
                drag = .maskVertex(m.id, vi)
                onMaskVertex?(.began, m.id, vi, m.path.vertices[vi].point)
                return
            }
        }
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
        guard var hit = transformHit(p) else { return }
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
        case .crop(let edge):
            guard let base = liveCrop else { return }
            let v = cropGeometry.inset(edge, at: p, current: base)
            liveCrop = edge.setting(v, in: base)
            needsDisplay = true
            onCrop?(.changed, edge, v)
        case .point(let h, let grab):
            let snap = snapTargets.map { PointHandleGeometry.Snap(targets: $0, viewThreshold: Self.snapDistance) }
            let r = pointGeometry.dragged(h, grabbedAt: grab, to: p, lockAxis: shift,
                                          snap: flags.contains(.command) ? nil : snap)
            activeGuides = r.guides
            livePoints[h.id] = r.offset
            needsDisplay = true
            onPointHandle?(.changed, h.id, r.offset)
        case .maskVertex(let id, let i):
            guard let n = maskGeometry.framePoint(p) else { return }
            if let mi = masks.firstIndex(where: { $0.id == id }) { masks[mi].path.moveVertex(i, to: n) }
            onMaskVertex?(.changed, id, i, n)
        case .maskTangent(let id, let i, let isOut, _, _):
            guard let n = maskGeometry.framePoint(p), let mi = masks.firstIndex(where: { $0.id == id }),
                  masks[mi].path.vertices.indices.contains(i) else { return }
            let offset = n - masks[mi].path.vertices[i].point
            masks[mi].path.setTangent(i, out: isOut, to: offset, independent: option)
            drag = .maskTangent(id, i, out: isOut, last: offset, independent: option)
            onMaskEdit?(.changed, .tangent(id, vertex: i, out: isOut, offset: offset, independent: option))
        case .maskPen(let id, let seg, let t, let base, _, _):
            guard let n = maskGeometry.framePoint(p), let mi = masks.firstIndex(where: { $0.id == id }),
                  base.vertices.indices.contains(seg) else { return }
            let handle = n - base.splitting(segment: seg, at: t).vertices[seg + 1].point
            masks[mi].path = base.placingVertex(segment: seg, at: t, handle: handle, independent: option)
            drag = .maskPen(id, segment: seg, t: t, base: base, last: handle, independent: option)
            onMaskEdit?(.changed, .pen(id, segment: seg, t: t, handle: handle, independent: option))
        case .maskMove(let id, let start, let base, _):
            guard let n = maskGeometry.framePoint(p) else { return }
            var delta = n - start
            if shift { if abs(delta.x) >= abs(delta.y) { delta.y = 0 } else { delta.x = 0 } }   // Shift: one axis
            if let mi = masks.firstIndex(where: { $0.id == id }) { masks[mi].path = base.translated(by: delta) }
            drag = .maskMove(id, start: start, base: base, last: delta)
            onMaskEdit?(.changed, .move(id, delta: delta))
        case .maskTool(let mode, let start, let sv, let downFlags, let moved):
            let far = !MaskShapeDrag.isClick(viewDistance: Double(hypot(p.x - sv.x, p.y - sv.y)))
            guard moved || far else { return }
            if !moved { drag = .maskTool(mode, start: start, startView: sv, flags: downFlags, moved: true) }
            guard let kind = mode.shapeKind, let n = maskGeometry.framePoint(p) else { return }
            drawPreview = MaskShapeDrag(kind: kind, start: start).path(to: n, square: shift, fromCenter: option,
                                                                          frame: maskGeometry.frameExtent)
            needsDisplay = true
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
        case .crop(let edge):
            let v = cropGeometry.inset(edge, at: p, current: liveCrop ?? cropInsets ?? .none)
            onCrop?(.ended, edge, v)
            liveCrop = nil
        case .point(let h, _):
            onPointHandle?(.ended, h.id, livePoints[h.id] ?? h.offset)
            livePoints[h.id] = nil
            activeGuides = .none; activeGaps = []
        case .maskVertex(let id, let i):
            let n = maskGeometry.framePoint(p) ?? masks.first(where: { $0.id == id })?.path.vertices[i].point ?? .zero
            onMaskVertex?(.ended, id, i, n)
        case .maskTangent(let id, let i, let isOut, let last, let independent):
            onMaskEdit?(.ended, .tangent(id, vertex: i, out: isOut, offset: last, independent: independent))
        case .maskPen(let id, let seg, let t, _, let last, let independent):
            onMaskEdit?(.ended, .pen(id, segment: seg, t: t, handle: last, independent: independent))
        case .maskMove(let id, _, _, let last):
            onMaskEdit?(.ended, .move(id, delta: last))
        case .key(let id):
            onPathEdit?(.ended, PathEdit(key: id, position: pathGeometry?.keyValue(at: p), tangents: nil))
        case .tangent(let id, _, let current):
            onPathEdit?(.ended, PathEdit(key: id, position: nil, tangents: current))
        case .maskTool(let mode, let start, let sv, let downFlags, let moved):
            let shape = drawPreview
            drawPreview = nil
            needsDisplay = true
            NSCursor.crosshair.set()
            if moved, let kind = mode.shapeKind {
                if let shape { onMaskShapeDrawn?(kind, shape) }
                return
            }
            // A click: inside another mask with a shape mode selects that mask, else the tool's click (Pen point,
            // default-size shape centered there).
            if mode != .pen, let mi = maskGeometry.hitAnyInside(sv, masks: masks) {
                onMaskSelect?(masks[mi].id)
                return
            }
            onMaskToolClick?(start, downFlags)
            return
        default:
            if let t = liveTransform { onTransform?(.ended, t) }
            liveTransform = nil
            activeGuides = .none; activeGaps = []
        }
        needsDisplay = true
        if maskTool != nil { NSCursor.crosshair.set() } else { updateCursor(transformHit(p)) }
    }

    /// Smart guides: the moved layer's edges and center snap to the canvas and the other layers.
    private func snapped(_ t: ClipTransform, geo g: TransformOverlayGeometry, disabled: Bool, lockAxis: Bool) -> ClipTransform {
        guard !disabled, let targets = snapTargets, g.viewScale > 0 else { activeGuides = .none; activeGaps = []; return t }
        let box = LayerBounds.rect(size: g.fittedSize, transform: t)
        // Shift axis lock: the locked axis did not move, so it must not snap either.
        let r = SnapGuides.snap(box: box, targets: targets, threshold: Self.snapDistance / g.viewScale)
            .locking(x: lockAxis && t.position.x == g.transform.position.x, y: lockAxis && t.position.y == g.transform.position.y)
        activeGuides = r
        var out = t
        out.position = Vec2(t.position.x + r.dx, t.position.y + r.dy)
        // Equal spacing between two neighbors, only on an axis the layer edges did not already snap.
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
        needsDisplay = true
        onTransform?(.changed, t)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard !canvasRect.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        if maskTool == .magic, let img = magicPreview, let layer = magicPreviewLayer {
            drawStretched([img], over: previewGeometry(layer), ctx)
        }
        guard showsOverlay else { return }
        let g = geometry
        drawSafeAreas(g)
        if let path = pathGeometry { drawMotionPath(path, ctx) }
        drawGuides(g)
        if maskTool != nil {
            drawMagic(ctx)
            drawMasks()
            drawShapePreview()
            return
        }
        defer { drawPointHandles() }
        drawMasks()

        // Quad
        let q = g.quad
        let outline = NSBezierPath()
        outline.move(to: q[0]); q.dropFirst().forEach { outline.line(to: $0) }; outline.close()
        // Board "Transform box": white 1 pt frame, white 8 pt squares with a dark edge, a white ring at the anchor.
        Theme.OnPicture.stroke.setStroke(); outline.lineWidth = 1; outline.stroke()

        if let i = liveCrop ?? cropInsets {
            drawCrop(i, g)
            return
        }

        // Handles
        for h in TransformOverlayGeometry.Handle.allCases {
            let c = g.viewPoint(of: h)
            let r: CGFloat = 4
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            let sq = NSBezierPath(rect: rect)
            Theme.OnPicture.stroke.setFill(); sq.fill()
            Theme.OnPicture.shadow.setStroke(); sq.lineWidth = 1; sq.stroke()
        }

        // Anchor ring (grab radius 10 pt).
        let a = g.anchorViewPoint
        let ring = NSBezierPath(ovalIn: CGRect(x: a.x - 5, y: a.y - 5, width: 10, height: 10))
        Theme.OnPicture.stroke.setStroke(); ring.lineWidth = 1.2; ring.stroke()
    }

    /// Crop mode: the kept rectangle (dashed, on the dimmed removed part) and an edge handle in the middle of each side.
    private func drawCrop(_ i: CropInsets, _ g: TransformOverlayGeometry) {
        let cg = CropHandleGeometry(quad: g.quad)
        let kept = cg.corners(i)
        let outer = NSBezierPath()
        outer.move(to: g.quad[0]); g.quad.dropFirst().forEach { outer.line(to: $0) }; outer.close()
        if !i.isIdentity {
            let inner = NSBezierPath()
            inner.move(to: kept[0]); kept.dropFirst().forEach { inner.line(to: $0) }; inner.close()
            let removed = NSBezierPath()
            removed.append(outer); removed.append(inner)
            removed.windingRule = .evenOdd
            Theme.OnPicture.shadow.withAlphaComponent(0.45).setFill(); removed.fill()
            inner.setLineDash([4, 3], count: 2, phase: 0)
            Theme.OnPicture.shadow.setStroke(); inner.lineWidth = 3; inner.stroke()
            Theme.Colors.yellow.setStroke(); inner.lineWidth = 1; inner.stroke()
        }
        for e in CropEdge.allCases {
            let c = cg.handlePoint(e, i)
            let w: CGFloat = e.isVertical ? 5 : 11, h: CGFloat = e.isVertical ? 11 : 5
            let r = NSBezierPath(rect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
            Theme.Colors.yellow.setFill(); r.fill()
            Theme.OnPicture.shadow.setStroke(); r.lineWidth = 1; r.stroke()
        }
    }

    private func drawSafeAreas(_ g: TransformOverlayGeometry) {
        for a in safeAreas {
            let r = a.rect(in: sequenceSize)
            let tl = g.viewPoint(fromOffset: Vec2(Double(r.minX), Double(r.minY)))
            let br = g.viewPoint(fromOffset: Vec2(Double(r.maxX), Double(r.maxY)))
            let path = NSBezierPath(rect: CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y))
            path.setLineDash([4, 3], count: 2, phase: 0)
            Theme.OnPicture.shadow.setStroke(); path.lineWidth = 3; path.stroke()
            Theme.OnPicture.stroke.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    /// Magic pick and hover highlights, stretched over the layer quad.
    private func drawMagic(_ ctx: CGContext) {
        let imgs = maskTints + [magicPick, magicHover].compactMap { $0 }
        guard !imgs.isEmpty || !magicMarkers.isEmpty else { return }
        let mg = maskGeometry
        drawStretched(imgs, over: mg, ctx)
        for m in magicMarkers { m.draw(at: mg.viewPoint(m.position)) }
    }

    private func drawStretched(_ imgs: [CGImage], over mg: MaskOverlayGeometry, _ ctx: CGContext) {
        guard !imgs.isEmpty else { return }
        ctx.saveGState()
        ctx.concatenate(CGAffineTransform(a: mg.xAxis.dx, b: mg.xAxis.dy, c: mg.yAxis.dx, d: mg.yAxis.dy, tx: mg.origin.x, ty: mg.origin.y))
        // Unit square, y down (flipped view): flip so the image's top row lands at the frame's top.
        ctx.translateBy(x: 0, y: 1); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        for i in imgs { ctx.draw(i, in: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        ctx.restoreGState()
    }

    /// Mask outlines (flattened paths) and their vertices, on the layer.
    private func drawMasks() {
        guard !masks.isEmpty else { return }
        let mg = maskGeometry
        for m in masks {
            let pts = mg.outline(m.path)
            guard pts.count > 1 else { continue }
            let line = NSBezierPath()
            line.move(to: pts[0]); pts.dropFirst().forEach { line.line(to: $0) }; line.close()
            Theme.OnPicture.shadow.setStroke(); line.lineWidth = 3; line.stroke()
            Theme.Colors.yellow.setStroke(); line.lineWidth = 1; line.stroke()
            if m.active { drawTangentHandles(m.path, mg) }
            for v in m.path.vertices {
                let c = mg.viewPoint(v.point)
                let sq = NSBezierPath(rect: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7))
                // Active mask: filled squares; the others hollow (their vertices still drag).
                if m.active { Theme.Colors.yellow.setFill(); sq.fill() } else { Theme.OnPicture.shadow.setFill(); sq.fill() }
                Theme.OnPicture.shadow.setStroke(); sq.lineWidth = 1; sq.stroke()
                if !m.active {
                    let inner = NSBezierPath(rect: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
                    Theme.Colors.yellow.setStroke(); inner.lineWidth = 1; inner.stroke()
                }
            }
        }
    }

    /// The Rectangle / Ellipse being dragged out: its outline, as a committed mask will look.
    private func drawShapePreview() {
        guard let path = drawPreview else { return }
        let pts = maskGeometry.outline(path)
        guard pts.count > 1 else { return }
        let line = NSBezierPath()
        line.move(to: pts[0]); pts.dropFirst().forEach { line.line(to: $0) }; line.close()
        Theme.OnPicture.shadow.setStroke(); line.lineWidth = 3; line.stroke()
        Theme.Colors.yellow.setStroke(); line.lineWidth = 1; line.stroke()
    }

    /// Bezier handles of the active mask: a stem from each curved vertex to a round handle (same look as the motion path).
    private func drawTangentHandles(_ path: MaskPath, _ mg: MaskOverlayGeometry) {
        let stems = NSBezierPath()
        var dots: [CGPoint] = []
        for v in path.vertices {
            let c = mg.viewPoint(v.point)
            for t in [v.inTangent, v.outTangent] where t != .zero {
                let h = mg.viewPoint(v.point + t)
                stems.move(to: c); stems.line(to: h)
                dots.append(h)
            }
        }
        Theme.Colors.label2.setStroke(); stems.lineWidth = 1; stems.stroke()
        for h in dots {
            let dot = NSBezierPath(ovalIn: CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7))
            Theme.Colors.yellow.setFill(); dot.fill()
            Theme.OnPicture.shadow.setStroke(); dot.lineWidth = 1; dot.stroke()
        }
    }

    private func drawPointHandles() {
        let geo = pointGeometry
        for h in displayedPoints {
            let c = geo.viewPoint(fromOffset: h.offset)
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            Theme.OnPicture.shadow.setStroke(); ring.lineWidth = 3; ring.stroke()
            Theme.Colors.accent.setFill(); ring.fill()
            Theme.OnPicture.stroke.setStroke(); ring.lineWidth = 1.5; ring.stroke()
        }
    }

    private func drawGuides(_ g: TransformOverlayGeometry) {
        guard drag != nil else { return }
        let r = canvasRect
        let gapLine = NSBezierPath()
        for gap in activeGaps {
            let a = CGFloat(gap.from * g.viewScale), b = CGFloat(gap.to * g.viewScale), c = CGFloat(gap.cross * g.viewScale)
            if gap.vertical {
                gapLine.move(to: CGPoint(x: r.midX + c, y: r.midY + a)); gapLine.line(to: CGPoint(x: r.midX + c, y: r.midY + b))
            } else {
                gapLine.move(to: CGPoint(x: r.midX + a, y: r.midY + c)); gapLine.line(to: CGPoint(x: r.midX + b, y: r.midY + c))
            }
        }
        if !activeGaps.isEmpty { Self.guideColor.setStroke(); gapLine.lineWidth = 2; gapLine.stroke() }
        guard !(activeGuides.verticalLines.isEmpty && activeGuides.horizontalLines.isEmpty) else { return }
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
    public static let guideColor = Theme.OnPicture.guideSnap

    private func drawMotionPath(_ path: MotionPathGeometry, _ ctx: CGContext) {
        let line = NSBezierPath()
        for seg in path.segments where seg.count > 1 {
            line.move(to: seg[0]); seg.dropFirst().forEach { line.line(to: $0) }
        }
        Theme.OnPicture.shadow.setStroke(); line.lineWidth = 3; line.stroke()
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
                Theme.OnPicture.shadow.setStroke(); dot.lineWidth = 1; dot.stroke()
            }
            let r: CGFloat = 4.5
            let rect = CGRect(x: k.point.x - r, y: k.point.y - r, width: r * 2, height: r * 2)
            let diamond = NSBezierPath()
            diamond.move(to: CGPoint(x: rect.midX, y: rect.minY)); diamond.line(to: CGPoint(x: rect.maxX, y: rect.midY))
            diamond.line(to: CGPoint(x: rect.midX, y: rect.maxY)); diamond.line(to: CGPoint(x: rect.minX, y: rect.midY))
            diamond.close()
            (k.id == selectedKey ? Theme.Colors.accent : Theme.Colors.yellow).setFill(); diamond.fill()
            Theme.OnPicture.shadow.setStroke(); diamond.lineWidth = 1; diamond.stroke()
        }
    }
}
