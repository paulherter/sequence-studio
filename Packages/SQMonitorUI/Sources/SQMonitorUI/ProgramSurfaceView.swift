import AppKit
import CoreText
import SQCore
import SQDrawMonitor
import SQRender
import SQText

/// The Program monitor's picture area: the Metal viewer with the transform overlay on top, the Hand and Type tools,
/// trackpad pan/zoom of the monitor view, and in-place text editing. All view-mapping maths is in
/// `MonitorViewMapping`; the picture's own transform is never touched by pan and zoom (Hand tool / scroll / pinch).
@MainActor
public final class ProgramSurfaceView: NSView, NSTextViewDelegate {
    public enum Tool: Sendable, Equatable {
        case select, hand, type
        /// Mask tool: clicks on the selected clip's picture make masks (`overlay.onMaskToolClick`).
        case mask(MaskToolMode)
        /// Create tool in a shape mode (Rectangle, Ellipse, Line, Draw): a drag on the picture makes an item of a Graphic.
        /// Text mode is `type`.
        case create(CreateToolMode)
        var maskMode: MaskToolMode? { if case .mask(let m) = self { m } else { nil } }
        var createMode: CreateToolMode? { if case .create(let m) = self { m } else { nil } }
        /// The overlay above the picture takes the clicks (transform box or mask tool).
        var usesOverlay: Bool { self == .select || maskMode != nil }
    }

    public let viewer: NSView
    public let overlay = TransformOverlayView()
    /// Magic mode: Add | Remove, top left on the picture area (Option flips it while held; the switch shows the flip).
    public let magicSwitch = SQSegmented(labels: ["Add", "Remove"], segmentWidth: 64)
    /// The Add | Remove switch changed (the host keeps it for the session).
    public var onMagicModeChange: ((MagicClickMode) -> Void)?
    public var magicMode: MagicClickMode {
        get { overlay.magicMode }
        set { overlay.magicMode = newValue; magicSwitch.selectedSegment = newValue.rawValue }
    }

    public var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            if tool != .type { endTextEditing() }
            cancelCreateDrag()                      // also a change of mode in the middle of a drag
            overlay.maskTool = tool.maskMode
            magicSwitch.isHidden = tool != .mask(.magic)
            refreshOverlay()
        }
    }
    public var sequenceSize = CGSize(width: 1920, height: 1080) { didSet { updateCanvas() } }
    /// Color page Split compare: a thin line where the ungraded left part meets the graded right part. Monitor only,
    /// never in the rendered picture (export, frame capture).
    public var showsSplitDivider = false { didSet { if oldValue != showsSplitDivider { updateCanvas() } } }
    let splitDivider = SplitDividerView()
    /// What the viewer shows. Set by the host (popup, engine); gestures report through `onZoomGesture`.
    public var zoom: ViewerZoom = .fit { didSet { updateCanvas() } }
    /// Pan / pinch / Hand drag produced a new zoom: the host forwards it to the engine and the zoom popup.
    public var onZoomGesture: ((ViewerZoom) -> Void)?
    /// Type tool click: position (sequence px from the canvas center) of the new text.
    public var onTypeClick: ((Vec2) -> Void)?
    /// Select tool, double-click on the picture (not on a caption): the host edits the text under the pointer, if any.
    public var onTextDoubleClick: ((Vec2) -> Void)?
    /// Type tool drag: the box (center from the canvas center, size, sequence px) of a new area text.
    public var onTypeBox: ((Vec2, TextBox) -> Void)?
    /// Text edited in place / editing finished (Esc, Cmd+Return, click away, tool change).
    public var onTextEdited: ((String) -> Void)?
    public var onTextEditEnded: ((String) -> Void)?
    /// Double-click on a caption's text (select tool): the position (sequence px from the canvas center); the host edits it.
    public var onCaptionDoubleClick: ((Vec2) -> Void)?
    /// Asked on a double-click: does a caption lie under this position? (Routes the click here instead of the overlay.)
    public var captionHitTest: ((Vec2) -> Bool)?
    /// A press on a caption's text (select tool): position (sequence px from the canvas center). True = the host took it
    /// (selected the caption) and the drag moves it.
    public var onCaptionDragBegan: ((Vec2) -> Bool)?
    /// The running caption drag: distance moved (sequence px) and the snap distance (sequence px; 0 = snapping off, Option
    /// held). Returns the guide lines to draw.
    public var onCaptionDragMoved: ((Vec2, Double) -> SnapGuides.Result)?
    public var onCaptionDragEnded: (() -> Void)?
    /// A plain click on the picture with the Selection tool (outside the overlay's handles): select the clip there.
    public var onPickClip: ((Vec2) -> Void)?
    /// Magic mode, no clip targeted, the pointer moved over the picture (canvas position): the host targets the clip there.
    public var onMagicNeedsClip: ((Vec2) -> Void)?
    /// The pointer over the monitor with the Magic tool, in sequence px from the canvas center (nil = outside, or text
    /// is being typed).
    public var magicPointerPosition: Vec2? {
        guard let w = overlay.magicPointer, textEditor == nil, bounds.contains(convert(w, from: nil)) else { return nil }
        return TypeToolPlacement.position(forClick: convert(w, from: nil), mapping: mapping)
    }
    /// Cmd+B / Cmd+I while editing.
    public enum StyleToggle: Sendable { case bold, italic }
    public var onStyleToggle: ((StyleToggle) -> Void)?

    /// Create tool, Rectangle / Ellipse: the dragged box as two opposite corners (sequence px from the canvas center).
    /// Line: its two ends. Shift and Option are already applied.
    public var onCreateShape: ((ShapeKind, Vec2, Vec2) -> Void)?
    /// Create tool, Draw: the stroke as recorded (sequence px from the canvas center) and the smoothing tolerance in the
    /// same unit.
    public var onCreateStroke: (([Vec2], Double) -> Void)?

    private var hasTarget = false
    /// The overlay's target is a text layer (set by the host): its frame also shows with the Type tool and while editing.
    public var targetIsText = false { didSet { refreshOverlay() } }
    private(set) var textEditor: NSTextView?
    private var focusProtectedUntil: TimeInterval?
    private var editorStyle: TextStyle?
    /// View points per sequence pixel of the open text field (set by `layoutEditor`). Kept, never read back from
    /// `tv.font`: the 6 pt minimum and the second-line font would make that ratio wrong.
    private var editorScale: CGFloat = 1
    private var editorBox: TextBox?
    private var handLast: CGPoint?
    private var typeStart: CGPoint?
    private let rubberBand = RubberBandView()
    private var createDrag: CreateToolDrag?
    private let createPreview = CreateToolPreviewView()
    private var createEscapeMonitor: Any?
    private let captionGuides = GuideLinesView()
    private var captionDragStart: CGPoint?
    private var captionDragMoved = false
    /// Smallest drag (view points) that moves a caption; a click on the text only selects it.
    static let minCaptionDrag: CGFloat = 3
    /// Smallest drag (view points) that makes an area text box; anything shorter is a click.
    static let minBoxDrag: CGFloat = 6

    public var mapping: MonitorViewMapping {
        MonitorViewMapping(viewSize: bounds.size, backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                           sequenceSize: sequenceSize, zoom: zoom)
    }
    public var isEditingText: Bool { textEditor != nil }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    /// VoiceOver: the picture's size in sequence pixels (the label is "Program picture").
    public override func accessibilityValue() -> Any? {
        "\(Int(sequenceSize.width)) by \(Int(sequenceSize.height)) pixels"
    }

    public init(viewer: NSView) {
        self.viewer = viewer
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Program picture")
        // The transform box may lie partly outside the picture; it must never draw over the tab strip above.
        clipsToBounds = true
        overlay.clipsToBounds = true
        viewer.frame = bounds
        viewer.autoresizingMask = [.width, .height]
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(viewer)
        splitDivider.isHidden = true
        addSubview(splitDivider)
        addSubview(overlay)
        rubberBand.isHidden = true
        addSubview(rubberBand)
        captionGuides.isHidden = true
        addSubview(captionGuides)
        createPreview.isHidden = true
        addSubview(createPreview)
        magicSwitch.isHidden = true
        magicSwitch.target = self
        magicSwitch.action = #selector(magicSwitchChanged)
        magicSwitch.setToolTip("Click adds the area under the pointer (hold Option to remove)", forSegment: 0)
        magicSwitch.setToolTip("Click removes the area under the pointer (hold Option to add)", forSegment: 1)
        addSubview(magicSwitch)
        overlay.onMagicModeShown = { [weak self] m in self?.magicSwitch.selectedSegment = m.rawValue }
        overlay.onMagicPointerWithoutTarget = { [weak self] w in
            guard let self, textEditor == nil, bounds.contains(convert(w, from: nil)),
                  let pos = TypeToolPlacement.position(forClick: convert(w, from: nil), mapping: mapping) else { return }
            onMagicNeedsClip?(pos)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pickStateChanged), name: .colorPickStateChanged, object: nil)
        magnifier.isHidden = true
        addSubview(magnifier)
    }

    /// Loupe next to the pointer during a color pick (the picker passes a hover sampler to `ColorPickHub.begin`).
    private let magnifier = MagnifierView()
    private var pickTracking: NSTrackingArea?

    @objc private func pickStateChanged() {
        window?.invalidateCursorRects(for: self)
        if !ColorPickHub.shared.isPicking { magnifier.isHidden = true; magnifier.grid = nil }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = pickTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        pickTracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        guard ColorPickHub.shared.isPicking else { super.mouseMoved(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        ColorPickHub.shared.hover(at: ColorPickHub.position(forClick: p, mapping: mapping)) { [weak self] grid in
            guard let self, ColorPickHub.shared.isPicking else { return }
            guard let grid, grid.width > 0 else { self.magnifier.isHidden = true; return }
            self.magnifier.grid = grid
            self.magnifier.frame = MagnifierView.frame(size: MagnifierView.size(for: grid), pointer: p, in: self.bounds)
            self.magnifier.isHidden = false
        }
    }

    public override func mouseExited(with event: NSEvent) { magnifier.isHidden = true }
    @objc private func magicSwitchChanged() {
        let m = MagicClickMode(rawValue: magicSwitch.selectedSegment) ?? .add
        overlay.magicMode = m
        onMagicModeChange?(m)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    // MARK: Overlay state

    /// The clip under manipulation (nil hides the overlay), its drawing transform and the snap lines.
    /// Point-parameter handles of the selected clip (effect centers etc.) and their drag callback.
    public func setPointHandles(_ handles: [PointHandle], onChange: ((TransformOverlayView.Phase, String, Vec2) -> Void)?) {
        overlay.pointHandles = handles
        overlay.onPointHandle = onChange
    }
    /// Crop edge handles of the selected clip's Crop effect (nil = none); `onChange` gets the new inset as a fraction.
    public func setCrop(_ insets: CropInsets?, onChange: ((TransformOverlayView.Phase, CropEdge, Double) -> Void)?) {
        overlay.cropInsets = insets
        overlay.onCrop = onChange
    }
    /// Safe-area frames shown on the canvas (and snapped to when passed to `SnapGuides.targets`).
    /// Bounds of the other layers (offset space) for spacing guides.
    public func setNeighborBounds(_ rects: [CGRect]) { overlay.neighborBounds = rects }
    public func setSafeAreas(_ areas: [SafeArea]) { overlay.safeAreas = areas }

    public func setTarget(_ t: OverlayTarget?, snap: SnapGuides.Targets?) {
        hasTarget = t != nil
        overlay.snapTargets = snap
        if let t {
            overlay.mediaPixelSize = t.size
            overlay.positionTrack = t.positionTrack
            overlay.transform = t.displayTransform
        }
        refreshOverlay()
        if let t, textEditor != nil { layoutEditor(t) }
    }

    /// Frame visibility and interactivity come from `MonitorTextInteraction` (text layers) or the plain overlay rule.
    private func refreshOverlay() {
        let editing = textEditor != nil
        if targetIsText {
            overlay.showsOverlay = MonitorTextInteraction.frameVisible(tool: tool, hasTextTarget: hasTarget, editing: editing)
        } else {
            overlay.showsOverlay = hasTarget && tool.usesOverlay && !editing
        }
        overlay.isInteractive = MonitorTextInteraction.frameIsInteractive(tool: tool, editing: editing)
        window?.invalidateCursorRects(for: self)
    }

    /// The style changed while editing (Cmd+B / Cmd+I): the field follows.
    public func updateEditorStyle(_ style: TextStyle, box: TextBox?, target: OverlayTarget?) {
        guard textEditor != nil else { return }
        editorStyle = style; editorBox = box
        if let target { layoutEditor(target) }
    }

    public override func layout() {
        super.layout()
        viewer.frame = bounds
        overlay.frame = bounds
        let s = magicSwitch.intrinsicContentSize
        magicSwitch.frame = CGRect(x: Theme.Spacing.sm, y: Theme.Spacing.sm, width: s.width, height: s.height)
        updateCanvas()
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateCanvas() }
    /// Leaving its window ends a running Create drag (its Escape monitor must not outlive the view).
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        cancelCreateDrag()
    }

    /// Called when the picture's place may have changed (zoom, pan, sequence size, layout); never per frame.
    public var onCanvasChange: (() -> Void)?

    private func updateCanvas() {
        defer { onCanvasChange?() }
        overlay.sequenceSize = sequenceSize
        overlay.canvasRect = mapping.canvasRect
        splitDivider.isHidden = !showsSplitDivider
        if showsSplitDivider {
            splitDivider.frame = Self.splitDividerFrame(canvas: mapping.canvasRect, sequenceWidth: sequenceSize.width,
                                                        bounds: bounds, lineWidth: SplitDividerView.lineWidth)
        }
    }

    /// The divider's frame: centered on the split column (`ColorBypass.splitWidth` of the sequence width, mapped onto
    /// the canvas), spanning the visible part of the picture.
    static func splitDividerFrame(canvas: CGRect, sequenceWidth: CGFloat, bounds: CGRect, lineWidth: CGFloat) -> CGRect {
        let w = max(Int(sequenceWidth.rounded()), 1)
        let x = canvas.minX + canvas.width * CGFloat(ColorBypass.splitWidth(w)) / CGFloat(w)
        let visible = canvas.intersection(bounds)
        guard !visible.isNull else { return .zero }
        return CGRect(x: (x - lineWidth / 2).rounded(), y: visible.minY, width: lineWidth, height: visible.height)
    }

    // MARK: Hit routing and tools

    public override func hitTest(_ point: NSPoint) -> NSView? {
        if ColorPickHub.shared.isPicking, bounds.contains(convert(point, from: superview)) { return self }
        if isCaptionPress(at: convert(point, from: superview)) { return self }
        guard !tool.usesOverlay || textEditor != nil else { return super.hitTest(point) }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if let tv = textEditor, tool != .hand, tv.frame.contains(p) { return super.hitTest(point) }
        return self
    }

    /// A press on a caption's text (double-click edits it, a drag moves it) belongs to the caption, not to the clip overlay
    /// in front of the picture.
    private func isCaptionPress(at p: CGPoint) -> Bool {
        guard tool == .select, textEditor == nil, let hit = captionHitTest,
              let e = NSApp.currentEvent, e.type == .leftMouseDown,
              let pos = TypeToolPlacement.position(forClick: p, mapping: mapping) else { return false }
        return hit(pos)
    }

    public override func resetCursorRects() {
        if ColorPickHub.shared.isPicking { addCursorRect(bounds, cursor: .crosshair); return }
        switch tool {
        case .hand: addCursorRect(bounds, cursor: .openHand)
        case .type: addCursorRect(bounds, cursor: .iBeam)
        case .create: addCursorRect(bounds, cursor: .crosshair)
        case .select, .mask: break
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if ColorPickHub.shared.isPicking {
            ColorPickHub.shared.complete(at: ColorPickHub.position(forClick: p, mapping: mapping))
            return
        }
        switch tool {
        case .hand:
            if event.clickCount == 2 { onZoomGesture?(.fit); return }
            handLast = p
            NSCursor.closedHand.set()
        case .type:
            if textEditor != nil { endTextEditing() }
            typeStart = p
        case .create(let mode):
            if textEditor != nil { endTextEditing() }
            beginCreateDrag(mode, at: p)
        case .select:
            if textEditor != nil { endTextEditing() }
            if let pos = TypeToolPlacement.position(forClick: p, mapping: mapping), captionHitTest?(pos) == true {
                if event.clickCount == 2 { onCaptionDoubleClick?(pos) }
                else if onCaptionDragBegan?(pos) == true { captionDragStart = p; captionDragMoved = false }
            }
            else if let pos = TypeToolPlacement.position(forClick: p, mapping: mapping) {
                if event.clickCount == 1 { onPickClip?(pos) } else if event.clickCount == 2 { onTextDoubleClick?(pos) }
            }
        case .mask:
            // The press is not on the targeted clip's picture (or no clip is targeted): it selects the clip under the
            // pointer, and Magic picks there with the same press.
            if textEditor != nil { endTextEditing() }
            if let pos = TypeToolPlacement.position(forClick: p, mapping: mapping) {
                onPickClip?(pos)
                overlay.forwardMagicPress(atWindowPoint: event.locationInWindow, flags: event.modifierFlags)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if createDrag != nil {
            createDrag?.move(to: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
            showCreatePreview()
            return
        }
        if tool == .type, let a = typeStart {
            let p = convert(event.locationInWindow, from: nil)
            if abs(p.x - a.x) >= Self.minBoxDrag || abs(p.y - a.y) >= Self.minBoxDrag {
                rubberBand.frame = bounds
                rubberBand.rect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
                rubberBand.isHidden = false
            }
            return
        }
        if tool == .select, let a = captionDragStart {
            let p = convert(event.locationInWindow, from: nil)
            if !captionDragMoved, abs(p.x - a.x) < Self.minCaptionDrag, abs(p.y - a.y) < Self.minCaptionDrag { return }
            captionDragMoved = true
            let k = max(mapping.canvasRect.width / max(sequenceSize.width, 1), 0.0001)
            let snap = event.modifierFlags.contains(.option) ? 0 : Double(TransformOverlayView.snapDistance / k)
            if let r = onCaptionDragMoved?(Vec2(Double((p.x - a.x) / k), Double((p.y - a.y) / k)), snap) {
                captionGuides.frame = bounds
                captionGuides.canvasRect = mapping.canvasRect
                captionGuides.sequenceSize = sequenceSize
                captionGuides.guides = r
                captionGuides.isHidden = r.verticalLines.isEmpty && r.horizontalLines.isEmpty
            }
            return
        }
        guard tool == .hand, let last = handLast else { return }
        let p = convert(event.locationInWindow, from: nil)
        onZoomGesture?(mapping.panned(byViewDelta: CGSize(width: p.x - last.x, height: p.y - last.y)))
        handLast = p
    }

    public override func mouseUp(with event: NSEvent) {
        if var d = createDrag {
            d.move(to: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
            cancelCreateDrag()
            finishCreateDrag(d)
            return
        }
        if tool == .hand { handLast = nil; NSCursor.openHand.set() }
        if captionDragStart != nil {
            captionDragStart = nil
            captionGuides.isHidden = true
            if captionDragMoved { onCaptionDragEnded?() }
            captionDragMoved = false
            return
        }
        guard tool == .type, let a = typeStart else { return }
        typeStart = nil
        rubberBand.isHidden = true
        let p = convert(event.locationInWindow, from: nil)
        if let (centre, box) = TypeToolPlacement.box(from: a, to: p, mapping: mapping, minDrag: Self.minBoxDrag) {
            onTypeBox?(centre, box)
        } else if let pos = TypeToolPlacement.position(forClick: a, mapping: mapping) {
            onTypeClick?(pos)
        }
    }

    // MARK: Create tool drag

    private func beginCreateDrag(_ mode: CreateToolMode, at p: CGPoint) {
        cancelCreateDrag()                          // a drag whose release never arrived: its Escape monitor goes first
        createDrag = CreateToolDrag(mode: mode, start: p)
        createEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.createDrag != nil else { return false }
                self.cancelCreateDrag()
                return true
            }
            return consumed ? nil : event
        }
    }

    /// Ends the running Create drag without making anything (Escape, tool change, or just before the release is used).
    private func cancelCreateDrag() {
        createDrag = nil
        createPreview.isHidden = true
        createPreview.outline = nil
        if let m = createEscapeMonitor { NSEvent.removeMonitor(m); createEscapeMonitor = nil }
    }

    private func showCreatePreview() {
        guard let d = createDrag, d.isDrag(minimum: Self.minBoxDrag) else { createPreview.isHidden = true; return }
        let k = max(Double(mapping.scale / mapping.backingScale), 1e-6)
        createPreview.frame = bounds
        createPreview.outline = d.outline
        createPreview.label = d.sizeLabel(viewPointsPerPixel: k)
        createPreview.isHidden = false
    }

    private func finishCreateDrag(_ d: CreateToolDrag) {
        guard d.isDrag(minimum: Self.minBoxDrag) else { return }
        let m = mapping
        func seq(_ p: Vec2) -> Vec2 { m.sequenceOffset(fromView: CGPoint(x: p.x, y: p.y)) }
        switch d.outline {
        case .box(let r, let ellipse):
            onCreateShape?(ellipse ? .ellipse : .rectangle, seq(Vec2(r.minX, r.minY)), seq(Vec2(r.maxX, r.maxY)))
        case .line(let a, let b): onCreateShape?(.line, seq(a), seq(b))
        case .stroke(let pts):
            let k = max(Double(m.scale / m.backingScale), 1e-6)
            onCreateStroke?(pts.map(seq), CreateToolDrag.strokeTolerance / k)
        }
    }

    // MARK: Trackpad: scroll pans, pinch and Cmd/Option + scroll zoom about the cursor

    public override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            onZoomGesture?(mapping.zoomed(by: CGFloat(exp(Double(dy) * 0.01)), about: p))
            return
        }
        guard !mapping.isFit else { super.scrollWheel(with: event); return }   // nothing to pan at Fit
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        onZoomGesture?(mapping.panned(byViewDelta: CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k)))
    }

    public override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onZoomGesture?(mapping.zoomed(by: 1 + event.magnification, about: p))
    }

    // MARK: In-place text editing

    /// Opens a text field over the clip's text. The real (rendered) text stays visible; the field only shows the
    /// caret and selection. Every edit is reported through `onTextEdited`.
    public func beginTextEditing(text: String, style: TextStyle, box: TextBox? = nil, target: OverlayTarget, selectAll: Bool,
                                  caretAt: Vec2? = nil) {
        endTextEditing()
        let tv = EditorTextView(frame: .zero)
        tv.onCommit = { [weak self] in self?.endTextEditing() }
        tv.onToggle = { [weak self] in self?.onStyleToggle?($0) }
        // A plain-text field gives every insertion one font; a two-style text needs a font per paragraph. Only the
        // string is read back (attributes are re-applied after every edit), so pasted styles never reach the clip.
        tv.isRichText = style.secondLine != nil
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textColor = .clear
        tv.insertionPointColor = Theme.OnPicture.stroke
        tv.selectedTextAttributes = [.backgroundColor: Theme.Colors.accentTint, .foregroundColor: NSColor.clear]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = self
        tv.string = text
        tv.setAccessibilityLabel("Text")
        editorStyle = style
        editorBox = box
        textEditor = tv
        addSubview(tv)
        refreshOverlay()
        layoutEditor(target)
        window?.makeFirstResponder(tv)
        if selectAll {
            tv.selectAll(nil)
        } else if let pos = caretAt {
            let m = mapping, k = m.canvasRect.width / max(sequenceSize.width, 1)
            let viewPt = CGPoint(x: m.canvasRect.midX + CGFloat(pos.x) * k, y: m.canvasRect.midY + CGFloat(pos.y) * k)
            let idx = min(tv.characterIndexForInsertion(at: tv.convert(viewPt, from: self)), (text as NSString).length)
            tv.setSelectedRange(NSRange(location: idx, length: 0))
        } else {
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        NSLog("TextEdit begin: tool=\(tool) selectAll=\(selectAll) caretAtClick=\(caretAt != nil) sel=\(tv.selectedRange) frameVisible=\(overlay.showsOverlay)")
    }

    private func layoutEditor(_ t: OverlayTarget) {
        guard let tv = textEditor, let style = editorStyle else { return }
        let m = mapping
        let k = m.canvasRect.width / max(sequenceSize.width, 1)
        let s = CGFloat(max(t.displayTransform.scale.y, 0.01))
        let sx = CGFloat(max(t.displayTransform.scale.x, 0.01))
        let pt = max(6, CGFloat(style.size) * k * s)
        let base = FontResolver.font(for: style)
        tv.font = NSFont(descriptor: CTFontCopyFontDescriptor(base) as NSFontDescriptor, size: pt) ?? .systemFont(ofSize: pt)
        let c = CGPoint(x: m.canvasRect.midX + CGFloat(t.displayTransform.position.x) * k,
                        y: m.canvasRect.midY + CGFloat(t.displayTransform.position.y) * k)
        if let box = editorBox {
            // Area text: the field is the box; the text wraps inside it exactly like the renderer.
            let w = CGFloat(box.width) * k * sx, h = CGFloat(box.height) * k * s
            tv.frame = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            tv.textContainerInset = NSSize(width: 0, height: verticalInset(tv, style: style, box: box, k: k * s))
        } else {
            let w = max(t.size.width * k * sx + 80, 180)
            let h = max(t.size.height * k * s + 12, pt * 1.5)
            tv.textContainerInset = .zero
            tv.frame = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        }
        editorScale = k * s
        applyEditorAttributes(tv, style: style, scale: editorScale)
        // The field edits the text as stored. With All Caps the picture shows capitals, whose widths differ from the
        // typed letters, so the field is drawn visibly (dark backing, white text) instead of an invisible caret layer
        // over the capitals: what you see in the field is what is stored.
        let visible = style.allCaps
        tv.drawsBackground = visible
        tv.backgroundColor = Theme.OnPicture.hudFill
        tv.textColor = visible ? Theme.OnPicture.stroke : .clear
        tv.selectedTextAttributes = [.backgroundColor: Theme.Colors.accentTint,
                                     .foregroundColor: visible ? Theme.OnPicture.stroke : NSColor.clear]
    }

    /// Top inset that mirrors `TextStyle.verticalAlignment` inside the box.
    private func verticalInset(_ tv: NSTextView, style: TextStyle, box: TextBox, k: CGFloat) -> CGFloat {
        guard style.verticalAlignment != .top else { return 0 }
        let r = TextLayout.layout(text: tv.string, style: style, maxWidth: box.width, boxHeight: box.height)
        return CGFloat(r.lines.first?.y ?? 0) * k
    }

    /// Alignment, tracking and font for the whole string, so the caret sits where the renderer puts the glyphs.
    private func applyEditorAttributes(_ tv: NSTextView, style: TextStyle, scale: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = style.alignment == .left ? .left : style.alignment == .right ? .right : .center
        // Writing direction as the renderer resolves it: pinned by the style, else natural (per paragraph, first strong
        // character), so the caret moves and mixed runs order like the drawn text.
        switch style.direction {
        case .leftToRight?: para.baseWritingDirection = .leftToRight
        case .rightToLeft?: para.baseWritingDirection = .rightToLeft
        case nil: para.baseWritingDirection = .natural
        }
        para.lineSpacing = CGFloat(style.lineSpacing) * scale
        var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: para, .kern: CGFloat(style.tracking) * scale]
        let fonts = editorFonts(style, scale: scale)
        attrs[.font] = fonts.first
        tv.typingAttributes = attrs
        if let ts = tv.textStorage, ts.length > 0 { ts.addAttributes(attrs, range: NSRange(location: 0, length: ts.length)) }
        tv.defaultParagraphStyle = para
        // Two-style text (N4): every paragraph after the first in the second-line font, as the renderer draws it.
        // Re-applied after every edit (`textDidChange`), so typing never spreads one paragraph's font to the other.
        if let second = fonts.second, let ts = tv.textStorage {
            let nl = (tv.string as NSString).range(of: "\n")
            let start = nl.location == NSNotFound ? ts.length : nl.location + 1
            if start < ts.length { ts.addAttribute(.font, value: second, range: NSRange(location: start, length: ts.length - start)) }
        }
        setTypingFont(tv)
    }

    /// The field's fonts at `scale` view points per sequence pixel: the clip style's and, for a two-style text, the
    /// second-line style's (both at least 6 pt, like the field itself).
    private func editorFonts(_ style: TextStyle, scale: CGFloat) -> (first: NSFont, second: NSFont?) {
        func ns(_ s: TextStyle) -> NSFont {
            let pt = max(6, CGFloat(s.size) * scale)
            return NSFont(descriptor: CTFontCopyFontDescriptor(FontResolver.font(for: s)) as NSFontDescriptor, size: pt)
                ?? .systemFont(ofSize: pt)
        }
        return (ns(style.lineStyle(0)), style.secondLine == nil ? nil : ns(style.lineStyle(1)))
    }

    /// Typing attributes follow the caret's paragraph, so a letter typed into the first paragraph never takes the
    /// second-line font (or the other way round).
    private func setTypingFont(_ tv: NSTextView, at location: Int? = nil) {
        guard let style = editorStyle else { return }
        let fonts = editorFonts(style, scale: editorScale)
        let nl = (tv.string as NSString).range(of: "\n")
        let inSecond = nl.location != NSNotFound && (location ?? tv.selectedRange().location) > nl.location
        let f = inSecond ? (fonts.second ?? fonts.first) : fonts.first
        if (tv.typingAttributes[.font] as? NSFont) != f { tv.typingAttributes[.font] = f }
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = textEditor, notification.object as? NSTextView === tv else { return }
        setTypingFont(tv)
    }

    /// Right before an edit lands: AppKit may refresh the typing attributes after the selection notification, so the
    /// paragraph font is set again here, for the place the text goes.
    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if textView === textEditor { setTypingFont(textView, at: affectedCharRange.location) }
        return true
    }

    public func endTextEditing() {
        guard let tv = textEditor else { return }
        textEditor = nil
        let text = tv.string
        tv.delegate = nil
        if window?.firstResponder === tv { window?.makeFirstResponder(nil) }
        tv.removeFromSuperview()
        refreshOverlay()
        NSLog("TextEdit end: tool=\(tool) frameVisible=\(overlay.showsOverlay)")
        onTextEditEnded?(text)
    }

    public func textDidChange(_ notification: Notification) {
        guard let tv = textEditor else { return }
        if let style = editorStyle, let box = editorBox {
            let k = tv.frame.height / max(CGFloat(box.height), 1)
            tv.textContainerInset = NSSize(width: 0, height: verticalInset(tv, style: style, box: box, k: k))
        }
        if let style = editorStyle { applyEditorAttributes(tv, style: style, scale: editorScale) }
        onTextEdited?(tv.string)
    }

    /// Set by the host right after it creates a text: for `seconds` a focus loss that nobody asked for is undone.
    public func protectTextFocus(seconds: TimeInterval) {
        focusProtectedUntil = ProcessInfo.processInfo.systemUptime + seconds
    }

    public func textDidEndEditing(_ notification: Notification) {
        if let tv = textEditor, notification.object as? NSTextView === tv, let w = window {
            let down = [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(NSApp.currentEvent?.type)
            let next = w.firstResponder
            let isText = next is NSText || (next as? NSView)?.isDescendant(of: tv) == true
            if MonitorTextInteraction.reclaimsFocus(protectedUntil: focusProtectedUntil, now: ProcessInfo.processInfo.systemUptime,
                                                    causedByMouseDown: down, newResponderIsText: isText) {
                DispatchQueue.main.async { [weak self, weak tv] in
                    guard let self, let tv, textEditor === tv else { return }
                    window?.makeFirstResponder(tv)
                }
                return
            }
        }
        endTextEditing()
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { endTextEditing(); return true }
        return false
    }
}


/// The in-place editor: Cmd+Return ends editing (Esc does too), Cmd+B / Cmd+I toggle the layer's style.
final class EditorTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onToggle: ((ProgramSurfaceView.StyleToggle) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.keyCode {
        case 36, 76: onCommit?(); return true                 // Return, keypad Enter
        case 11: onToggle?(.bold); return true                // B
        case 34: onToggle?(.italic); return true              // I
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// Dashed rectangle drawn while a Type tool drag defines an area text box.
final class RubberBandView: NSView {
    var rect: CGRect = .zero { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard !rect.isEmpty else { return }
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        Theme.OnPicture.shadow.setStroke(); path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        Theme.OnPicture.stroke.setStroke(); path.stroke()
    }
}

/// Guide lines drawn while a caption is dragged (canvas center, safe zones): offset space mapped onto the canvas rect.
final class GuideLinesView: NSView {
    var guides = SnapGuides.Result.none { didSet { needsDisplay = true } }
    var canvasRect = CGRect.zero
    var sequenceSize = CGSize(width: 1920, height: 1080)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard !canvasRect.isEmpty, sequenceSize.width > 0 else { return }
        let k = canvasRect.width / sequenceSize.width
        Theme.Colors.accent.setStroke()
        for x in guides.verticalLines {
            let vx = canvasRect.midX + CGFloat(x) * k
            let l = NSBezierPath(); l.lineWidth = 1
            l.move(to: CGPoint(x: vx, y: canvasRect.minY)); l.line(to: CGPoint(x: vx, y: canvasRect.maxY)); l.stroke()
        }
        for y in guides.horizontalLines {
            let vy = canvasRect.midY + CGFloat(y) * k
            let l = NSBezierPath(); l.lineWidth = 1
            l.move(to: CGPoint(x: canvasRect.minX, y: vy)); l.line(to: CGPoint(x: canvasRect.maxX, y: vy)); l.stroke()
        }
    }
}

/// The Split compare line on the monitor; it never takes clicks.
@MainActor
final class SplitDividerView: NSView {
    static let lineWidth: CGFloat = 1
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.OnPicture.stroke.cgColor
        layer?.shadowColor = Theme.OnPicture.shadow.cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 1
        layer?.shadowOffset = .zero
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
