import AppKit
import SSCore
import SSRender
import SSText

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
    /// Text edited in place / editing finished (Esc, click away, tool change).
    public var onTextEdited: ((String) -> Void)?
    public var onTextEditEnded: ((String) -> Void)?

    private var hasTarget = false
    private var textEditor: NSTextView?
    private var editorStyle: TextStyle?
    private var handLast: CGPoint?

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
    }
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
        guard tool != .select || textEditor != nil else { return super.hitTest(point) }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if let tv = textEditor, tool != .hand, tv.frame.contains(p) { return super.hitTest(point) }
        return self
    }

    public override func resetCursorRects() {
        switch tool {
        case .hand: addCursorRect(bounds, cursor: .openHand)
        case .type: addCursorRect(bounds, cursor: .iBeam)
        case .select: break
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .hand:
            if event.clickCount == 2 { onZoomGesture?(.fit); return }
            handLast = p
            NSCursor.closedHand.set()
        case .type:
            if textEditor != nil { endTextEditing() }
            if let pos = TypeToolPlacement.position(forClick: p, mapping: mapping) { onTypeClick?(pos) }
        case .select: if textEditor != nil { endTextEditing() }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard tool == .hand, let last = handLast else { return }
        let p = convert(event.locationInWindow, from: nil)
        onZoomGesture?(mapping.panned(byViewDelta: CGSize(width: p.x - last.x, height: p.y - last.y)))
        handLast = p
    }

    public override func mouseUp(with event: NSEvent) {
        if tool == .hand { handLast = nil; NSCursor.openHand.set() }
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
    public func beginTextEditing(text: String, style: TextStyle, target: OverlayTarget, selectAll: Bool) {
        endTextEditing()
        let tv = NSTextView(frame: .zero)
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
        tv.alignment = .center
        tv.delegate = self
        tv.string = text
        tv.setAccessibilityLabel("Text")
        editorStyle = style
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
        let font = NSFont(name: style.fontName, size: max(6, CGFloat(style.size) * k * s)) ?? .systemFont(ofSize: max(6, CGFloat(style.size) * k * s))
        tv.font = font
        let c = CGPoint(x: m.canvasRect.midX + CGFloat(t.displayTransform.position.x) * k,
                        y: m.canvasRect.midY + CGFloat(t.displayTransform.position.y) * k)
        let w = max(t.size.width * k * CGFloat(t.displayTransform.scale.x) + 80, 180)
        let h = max(t.size.height * k * s + 12, font.pointSize * 1.5)
        tv.frame = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
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
        onTextEdited?(tv.string)
    }

    public func textDidEndEditing(_ notification: Notification) { endTextEditing() }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { endTextEditing(); return true }
        return false
    }
}
