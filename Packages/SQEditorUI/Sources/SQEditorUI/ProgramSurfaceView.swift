import AppKit
import CoreText
import SQCore
import SQRender
import SQText

/// The Program monitor's picture area: the Metal viewer with the transform overlay on top, the Hand and Type tools,
/// trackpad pan/zoom of the monitor view, and in-place text editing. All view-mapping maths is in
/// `MonitorViewMapping`; the picture's own transform is never touched by pan and zoom (Hand tool / scroll / pinch).
@MainActor
public final class ProgramSurfaceView: NSView, NSTextViewDelegate {
    public enum Tool: Sendable, Equatable { case select, hand, type }

    public let viewer: NSView
    public let overlay = TransformOverlayView()

    public var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            if tool != .type { endTextEditing() }
            overlay.showsOverlay = tool == .select && textEditor == nil && hasTarget
            window?.invalidateCursorRects(for: self)
        }
    }
    public var sequenceSize = CGSize(width: 1920, height: 1080) { didSet { updateCanvas() } }
    /// What the viewer shows. Set by the host (popup, engine); gestures report through `onZoomGesture`.
    public var zoom: ViewerZoom = .fit { didSet { updateCanvas() } }
    /// Pan / pinch / Hand drag produced a new zoom: the host forwards it to the engine and the zoom popup.
    public var onZoomGesture: ((ViewerZoom) -> Void)?
    /// Type tool click: position (sequence px from the canvas centre) of the new text.
    public var onTypeClick: ((Vec2) -> Void)?
    /// Type tool drag: the box (centre from the canvas centre, size, sequence px) of a new area text.
    public var onTypeBox: ((Vec2, TextBox) -> Void)?
    /// Text edited in place / editing finished (Esc, Cmd+Return, click away, tool change).
    public var onTextEdited: ((String) -> Void)?
    public var onTextEditEnded: ((String) -> Void)?
    /// Double-click on a caption's text (select tool): the position (sequence px from the canvas centre); the host edits it.
    public var onCaptionDoubleClick: ((Vec2) -> Void)?
    /// Asked on a double-click: does a caption lie under this position? (Routes the click here instead of the overlay.)
    public var captionHitTest: ((Vec2) -> Bool)?
    /// Cmd+B / Cmd+I while editing.
    public enum StyleToggle: Sendable { case bold, italic }
    public var onStyleToggle: ((StyleToggle) -> Void)?

    private var hasTarget = false
    private var textEditor: NSTextView?
    private var editorStyle: TextStyle?
    private var editorBox: TextBox?
    private var handLast: CGPoint?
    private var typeStart: CGPoint?
    private let rubberBand = RubberBandView()
    /// Smallest drag (view points) that makes an area text box; anything shorter is a click.
    static let minBoxDrag: CGFloat = 6

    public var mapping: MonitorViewMapping {
        MonitorViewMapping(viewSize: bounds.size, backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                           sequenceSize: sequenceSize, zoom: zoom)
    }
    public var isEditingText: Bool { textEditor != nil }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }

    public init(viewer: NSView) {
        self.viewer = viewer
        super.init(frame: .zero)
        viewer.frame = bounds
        viewer.autoresizingMask = [.width, .height]
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(viewer)
        addSubview(overlay)
        rubberBand.isHidden = true
        addSubview(rubberBand)
        NotificationCenter.default.addObserver(self, selector: #selector(pickStateChanged), name: .colorPickStateChanged, object: nil)
    }

    @objc private func pickStateChanged() { window?.invalidateCursorRects(for: self) }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    // MARK: Overlay state

    /// The clip under manipulation (nil hides the overlay), its drawing transform and the snap lines.
    public func setTarget(_ t: OverlayTarget?, snap: SnapGuides.Targets?) {
        hasTarget = t != nil
        overlay.snapTargets = snap
        if let t {
            overlay.mediaPixelSize = t.size
            overlay.positionTrack = t.positionTrack
            overlay.transform = t.displayTransform
        }
        overlay.showsOverlay = t != nil && tool == .select && textEditor == nil
        if let t, textEditor != nil { layoutEditor(t) }
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
        updateCanvas()
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateCanvas() }

    private func updateCanvas() {
        overlay.sequenceSize = sequenceSize
        overlay.canvasRect = mapping.canvasRect
    }

    // MARK: Hit routing and tools

    public override func hitTest(_ point: NSPoint) -> NSView? {
        if ColorPickHub.shared.isPicking, bounds.contains(convert(point, from: superview)) { return self }
        if isCaptionDoubleClick(at: convert(point, from: superview)) { return self }
        guard tool != .select || textEditor != nil else { return super.hitTest(point) }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if let tv = textEditor, tool != .hand, tv.frame.contains(p) { return super.hitTest(point) }
        return self
    }

    /// A double-click on a caption's text belongs to the caption, not to the clip overlay in front of the picture.
    private func isCaptionDoubleClick(at p: CGPoint) -> Bool {
        guard tool == .select, textEditor == nil, let hit = captionHitTest,
              let e = NSApp.currentEvent, e.type == .leftMouseDown, e.clickCount == 2,
              let pos = TypeToolPlacement.position(forClick: p, mapping: mapping) else { return false }
        return hit(pos)
    }

    public override func resetCursorRects() {
        if ColorPickHub.shared.isPicking { addCursorRect(bounds, cursor: .crosshair); return }
        switch tool {
        case .hand: addCursorRect(bounds, cursor: .openHand)
        case .type: addCursorRect(bounds, cursor: .iBeam)
        case .select: break
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
        case .select:
            if textEditor != nil { endTextEditing() }
            if event.clickCount == 2, let pos = TypeToolPlacement.position(forClick: p, mapping: mapping), captionHitTest?(pos) == true {
                onCaptionDoubleClick?(pos)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if tool == .type, let a = typeStart {
            let p = convert(event.locationInWindow, from: nil)
            if abs(p.x - a.x) >= Self.minBoxDrag || abs(p.y - a.y) >= Self.minBoxDrag {
                rubberBand.frame = bounds
                rubberBand.rect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
                rubberBand.isHidden = false
            }
            return
        }
        guard tool == .hand, let last = handLast else { return }
        let p = convert(event.locationInWindow, from: nil)
        onZoomGesture?(mapping.panned(byViewDelta: CGSize(width: p.x - last.x, height: p.y - last.y)))
        handLast = p
    }

    public override func mouseUp(with event: NSEvent) {
        if tool == .hand { handLast = nil; NSCursor.openHand.set() }
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
    public func beginTextEditing(text: String, style: TextStyle, box: TextBox? = nil, target: OverlayTarget, selectAll: Bool) {
        endTextEditing()
        let tv = EditorTextView(frame: .zero)
        tv.onCommit = { [weak self] in self?.endTextEditing() }
        tv.onToggle = { [weak self] in self?.onStyleToggle?($0) }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textColor = .clear
        tv.insertionPointColor = .white
        tv.selectedTextAttributes = [.backgroundColor: Theme.Colors.accent.withAlphaComponent(0.5), .foregroundColor: NSColor.clear]
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
        overlay.showsOverlay = false
        layoutEditor(target)
        window?.makeFirstResponder(tv)
        if selectAll { tv.selectAll(nil) } else { tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) }
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
        applyEditorAttributes(tv, style: style, scale: k * s)
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
        para.lineSpacing = CGFloat(style.lineSpacing) * scale
        var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: para, .kern: CGFloat(style.tracking) * scale]
        if let f = tv.font { attrs[.font] = f }
        tv.typingAttributes = attrs
        if let ts = tv.textStorage, ts.length > 0 { ts.addAttributes(attrs, range: NSRange(location: 0, length: ts.length)) }
        tv.defaultParagraphStyle = para
    }

    public func endTextEditing() {
        guard let tv = textEditor else { return }
        textEditor = nil
        let text = tv.string
        tv.delegate = nil
        if window?.firstResponder === tv { window?.makeFirstResponder(nil) }
        tv.removeFromSuperview()
        overlay.showsOverlay = hasTarget && tool == .select
        onTextEditEnded?(text)
    }

    public func textDidChange(_ notification: Notification) {
        guard let tv = textEditor else { return }
        if let style = editorStyle, let box = editorBox {
            let k = tv.frame.height / max(CGFloat(box.height), 1)
            tv.textContainerInset = NSSize(width: 0, height: verticalInset(tv, style: style, box: box, k: k))
        }
        if let style = editorStyle { applyEditorAttributes(tv, style: style, scale: (tv.font?.pointSize ?? 1) / CGFloat(max(style.size, 1))) }
        onTextEdited?(tv.string)
    }

    public func textDidEndEditing(_ notification: Notification) { endTextEditing() }

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
        NSColor.black.withAlphaComponent(0.5).setStroke(); path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.white.setStroke(); path.stroke()
    }
}
