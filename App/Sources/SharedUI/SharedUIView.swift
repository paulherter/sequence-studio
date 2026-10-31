import AppKit
import Metal
import QuartzCore
import SQAppShell
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// The AppKit host view of the shared UI: one DrawList per frame from `SharedUIController.frame`, replayed through
/// `CoreGraphicsRenderer` into this flipped view's context (pixels = points x backing scale). NSEvents become the portable
/// `InputEvent`s (pixels, y down), keys go through `MacKeys` and the input method (NSTextInputClient: marked text, dead keys,
/// IME), Finder file drops go to the shell's import. The Program picture is not drawn here: the playback engine presents
/// into a CAMetalLayer view under this one (`SharedUIController.viewer`); the picture quad is cleared to transparent so it
/// shows through, and whatever the panels draw after it (overlays, menus) stays on top.
/// Drawing: the GPU quad renderer (`MetalDrawListRenderer`, the shared DrawQuads.slang shader) into a non-opaque
/// CAMetalLayer sublayer, driven from the display link (AppKit never runs `updateLayer`/`display` for a CAMetalLayer
/// backing layer: the round-9 window stayed empty). `CoreGraphicsRenderer` into the view's context where Metal is missing,
/// with `SQ_SHARED_UI_CG=1`, or after the live self-check (no GPU frame completed within `selfCheckTicks`) fell back.
/// `SQ_SHARED_UI_DUMP=<file.png>`: reads the presented drawable back once (frame 30) and writes it, then quits: proof that
/// the live path, not only the offscreen shot, draws.
@MainActor
final class SharedUIView: NSView, @preconcurrency NSTextInputClient {
    /// Which window this view fills: the editor, or the start window (`SharedUIStartWindow`: start screen, its dialogs
    /// and menus only; no picture, no window title, the arrow pointer), or a floating panel's window.
    /// A floating panel's window shows its part of the editor canvas and sends its events moved onto it
    /// (`SharedUIController+Floating.swift`).
    enum Role: Equatable { case editor, start, floating(PanelID) }
    let role: Role
    let controller: SharedUIController
    private var mask: CGImage?
    private var maskGeneration = -1
    private var link: CADisplayLink?
    private var probeTimer: Timer?
    private var resignObserver: NSObjectProtocol?
    private var dirty = true
    private var lastDraw = Date.distantPast
    private var marked = NSMutableAttributedString()
    private var collecting: String?
    private var mouseIsDown = false
    /// nil: CoreGraphics draws (`draw(_:)`).
    private var metal: MetalDrawListRenderer?
    private var metalLayer: CAMetalLayer?
    /// Display-link ticks since the window came up, GPU frames that completed without error.
    private var ticks = 0
    private var completedFrames = 0
    private var presentedFrames = 0
    private let dumpPath = ProcessInfo.processInfo.environment["SQ_SHARED_UI_DUMP"]
    /// Ticks (about 2 s at 60 Hz) the window gives the GPU path to complete its first frame before CoreGraphics takes over.
    static let selfCheckTicks = 120

    init(controller: SharedUIController, role: Role = .editor) {
        self.controller = controller
        self.role = role
        metal = ProcessInfo.processInfo.environment["SQ_SHARED_UI_CG"] == "1" ? nil : MetalDrawListRenderer()
        if metal == nil, ProcessInfo.processInfo.environment["SQ_SHARED_UI_CG"] != "1" {
            SQLog.error("shared UI: Metal draw-list renderer unavailable (no device or shader failed), CoreGraphics draws")
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        HostScroll.shared.systemMomentum = true      // the system sends the momentum tail; the bodies add the bounce
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        if let metal {
            let l = CAMetalLayer()
            l.device = metal.device
            l.pixelFormat = metal.pixelFormat
            l.isOpaque = false
            l.framebufferOnly = dumpPath == nil
            l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            l.presentsWithTransaction = false
            l.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            layer?.addSublayer(l)
            metalLayer = l
        }
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        if let w = window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.releaseHeldKeys(); self?.dirty = true }
            }
        }
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        // The float probe must run with the screen locked or asleep (no display link ticks then): a timer drives the main view.
        if SharedUIController.floatProbeEnabled, case .editor = role {
            probeTimer?.invalidate()
            probeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        }
        viewDidChangeBackingProperties()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The one frame is drawn at the largest scale of the main and the floating windows (`ShellFloating.drawScale`); a
        // window on a display with a smaller scale shows it reduced by the layer, never enlarged.
        controller.syncDrawScale()
        metalLayer?.contentsScale = window?.backingScaleFactor ?? 2
        dirty = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metalLayer?.frame = bounds
        CATransaction.commit()
        dirty = true
    }

    /// Redraw on input, while playing, and a few times a second for work that finishes on its own (decodes, saves, flashes).
    /// The Metal path draws right here; CoreGraphics through `needsDisplay` and `draw(_:)`.
    /// Something outside this view changed what the editor frame shows (a floating window got input).
    func markDirty() { dirty = true }

    @objc private func tick() {
        ticks += 1
        let playing = !controller.engine.rate.isPaused
        var due = dirty || playing || Date().timeIntervalSince(lastDraw) > 0.2
        if HostHover.shared.needsFrame(now: ProcessInfo.processInfo.systemUptime) { due = true }   // a tip comes due
        if HostScroll.shared.needsFrame() { due = true }                 // a list flings or springs back (rubber band)
        if controller.timelinePanel.isSpringingBack || controller.timelinePanel.isZooming || controller.timelinePanel.isAutoscrolling { due = true }   // rubber band, zoom ease and edge autoscroll run every frame
        if controller.library.model.preview.isPlaying { due = true }    // the Library preview's picture and scrub bar move
        if controller.shell.exportPreviewPlaying { due = true }          // the Export sheet's picture plays
        if metal != nil, ticks >= Self.selfCheckTicks, completedFrames == 0 {
            fallBackToCoreGraphics("no GPU frame completed in \(ticks) display ticks (\(presentedFrames) encoded)")
        }
        guard due else { return }
        if metal != nil { drawMetal() } else { needsDisplay = true }
    }

    /// Metal draws into the sublayer from `tick`: the view's own layer stays without a backing store.
    override var wantsUpdateLayer: Bool { metal != nil }
    override func updateLayer() {}

    /// Live self-check failed: drop the Metal layer, draw with CoreGraphics from now on.
    private func fallBackToCoreGraphics(_ why: String) {
        SQLog.error("shared UI: Metal live path failed (\(why)), falling back to CoreGraphics")
        metal = nil
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        dirty = true
        needsDisplay = true
    }

    /// The Metal path: one DrawList into the next drawable of the CAMetalLayer.
    private func drawMetal() {
        guard let metal, let layer = metalLayer, window != nil else { return }
        let scale = CGFloat(controller.screen.theme.scale)
        let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0 else { return }
        if layer.frame != bounds { CATransaction.begin(); CATransaction.setDisableActions(true); layer.frame = bounds; CATransaction.commit() }
        let list = controller.frame(width: w, height: h, role: role)
        if layer.drawableSize != CGSize(width: w, height: h) { layer.drawableSize = CGSize(width: w, height: h) }
        metal.setAtlas(controller.atlas)
        for (slot, img, gen) in controller.imageSources() { metal.setImage(slot: slot, img, generation: gen) }
        if let drawable = layer.nextDrawable(),
           let cb = metal.encode(list, into: drawable.texture, clear: controller.screen.theme.divider.alpha(1), punchesVideo: true) {
            presentedFrames += 1
            if let dumpPath, presentedFrames == 30, window?.isVisible == true { dump(drawable.texture, cb, to: dumpPath) }
            cb.addCompletedHandler { [weak self] b in
                let ok = b.status == .completed && b.error == nil
                let err = b.error.map { "\($0)" }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if ok { self.completedFrames += 1 } else if let err { SQLog.error("shared UI: GPU frame failed: \(err)") }
                }
            }
            cb.present(drawable)
            cb.commit()
        }
        finishFrame(list, scale: scale)
    }

    /// `SQ_SHARED_UI_DUMP`: copies the drawable into a CPU buffer on the frame's command buffer, writes the PNG, quits.
    private func dump(_ tex: MTLTexture, _ cb: MTLCommandBuffer, to path: String) {
        let (w, h) = (tex.width, tex.height)
        guard let buf = tex.device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        let bgra = tex.pixelFormat == .bgra8Unorm
        cb.addCompletedHandler { _ in
            var px = [UInt8](UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt8.self), count: w * h * 4))
            if bgra { for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) } }
            let opaque = stride(from: 3, to: px.count, by: 4).reduce(0) { $0 + (px[$1] > 0 ? 1 : 0) }
            try? RGBAImage(width: w, height: h, pixels: px).pngData().write(to: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                SQLog.info("shared UI dump: \(w)x\(h) -> \(path), \(opaque) non-transparent pixels")
                NSApp.terminate(nil)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard metal == nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = CGFloat(controller.screen.theme.scale)
        let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0 else { return }
        let list = controller.frame(width: w, height: h, role: role)
        if maskGeneration != controller.atlas.generation {
            mask = CoreGraphicsRenderer.mask(controller.atlas)
            maskGeneration = controller.atlas.generation
        }
        ctx.saveGState()
        ctx.scaleBy(x: 1 / scale, y: 1 / scale)
        ctx.setFillColor(CGColor(srgbRed: CGFloat(controller.screen.theme.divider.r), green: CGFloat(controller.screen.theme.divider.g),
                                 blue: CGFloat(controller.screen.theme.divider.b), alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        CoreGraphicsRenderer.draw(list, in: ctx, glyphs: mask, images: controller.imageSlots(), punchesVideo: true)
        ctx.restoreGState()
        finishFrame(list, scale: scale)
    }

    /// After either renderer: the picture view under the quad, the pointer, the window title.
    private func finishFrame(_ list: DrawList, scale: CGFloat) {
        dirty = false
        lastDraw = Date()
        controller.windowsFollowShell()
        guard role != .start else { return }
        updateCursor()
        guard role == .editor else { return }
        for w in controller.floatingWindows.values { w.uiView.markDirty() }     // they show parts of this frame
        controller.placePicture(Self.pictureRect(controller.canvasFrame ?? list, scale: scale))
        if let win = window {
            let title = controller.shell.windowTitle
            if win.title != title { win.title = title }
            win.isDocumentEdited = controller.session.isDirty
            if win.representedURL != controller.session.fileURL { win.representedURL = controller.session.fileURL }   // the title bar's proxy icon
        }
    }

    /// The picture quad and its visible part (the clip) in view points; nil: no picture this frame. A monitor zoom above
    /// Fit makes the quad larger than the card: the viewer covers the whole quad inside a container cut to the clip.
    static func pictureRect(_ list: DrawList, scale: CGFloat) -> (quad: CGRect, clip: CGRect)? {
        guard let q = list.quads.last(where: { DrawQuad.Kind(rawValue: $0.kind) == .video }) else { return nil }
        let r = CGRect(x: CGFloat(q.x), y: CGFloat(q.y), width: CGFloat(q.w), height: CGFloat(q.h))
        let clip = CGRect(x: CGFloat(q.clipX0), y: CGFloat(q.clipY0), width: CGFloat(q.clipX1 - q.clipX0),
                          height: CGFloat(q.clipY1 - q.clipY0))
        let v = r.intersection(clip)
        guard !v.isNull, v.width > 1, v.height > 1 else { return nil }
        func pt(_ x: CGRect) -> CGRect { CGRect(x: x.minX / scale, y: x.minY / scale, width: x.width / scale, height: x.height / scale) }
        return (pt(r), pt(v))
    }

    // MARK: Pointer shape

    private var shape: AppPointerShape = .arrow

    /// The shared rules' shape at the pointer (after each move and each frame).
    private func updateCursor() {
        guard role != .start, let w = window else { return }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(p) else { return }
        let (x, y) = canvasPixels(p)
        let next = controller.pointerShape(x: x, y: y)
        guard next != shape else { return }
        shape = next
        Self.cursor(next).set()
    }

    /// System shapes as NSCursor; the timeline tool shapes, zoom and copy as the Mac timeline's drawn cursors.
    static func cursor(_ s: AppPointerShape) -> NSCursor {
        switch s {
        case .arrow: .arrow
        case .crosshair: .crosshair
        case .iBeam: .iBeam
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .pointingHand: .pointingHand
        case .notAllowed: .operationNotAllowed
        case .dragCopy: TimelineCursors.cursor(for: .copy)
        case .zoomIn: TimelineCursors.cursor(for: .zoom)
        case .trimIn: TimelineCursors.cursor(for: .trimIn)
        case .trimOut: TimelineCursors.cursor(for: .trimOut)
        case .rippleIn: TimelineCursors.cursor(for: .rippleIn)
        case .rippleOut: TimelineCursors.cursor(for: .rippleOut)
        case .rateIn: TimelineCursors.cursor(for: .rateIn)
        case .rateOut: TimelineCursors.cursor(for: .rateOut)
        case .roll: TimelineCursors.cursor(for: .roll)
        case .slip: TimelineCursors.cursor(for: .slip)
        case .slide: TimelineCursors.cursor(for: .slide)
        case .razor: TimelineCursors.cursor(for: .razor)
        case .trackSelect: TimelineCursors.cursor(for: .trackSelect)
        case .resizeDiagonalDown: OverlayCursors.resize(angle: 45)
        case .resizeDiagonalUp: OverlayCursors.resize(angle: 135)
        case .move: OverlayCursors.move
        case .rotateBottomRight, .rotateBottomLeft, .rotateTopLeft, .rotateTopRight:
            OverlayCursors.rotate(angle: s.rotateAngle ?? 45)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.cursor(shape))
    }

    // MARK: Mouse

    /// A point of this view in canvas pixels: a floating window's view starts at its rectangle on the shared canvas.
    private func canvasPixels(_ p: CGPoint) -> (Float, Float) {
        let s = CGFloat(controller.screen.theme.scale)
        var o = CGPoint.zero
        if case .floating(let panel) = role { o = controller.floatingOrigin(panel) }
        return (Float((p.x + o.x) * s), Float((p.y + o.y) * s))
    }

    private func pixels(_ e: NSEvent) -> (Float, Float) { canvasPixels(convert(e.locationInWindow, from: nil)) }

    private func send(_ e: InputEvent) {
        controller.handle(e, role: role)
        dirty = true
        needsDisplay = true
        if case .floating = role { controller.view?.markDirty() }
    }

    override func mouseDown(with e: NSEvent) {
        if case .floating(let panel) = role, floatingMouseDown(e, panel) { return }
        window?.makeFirstResponder(self)
        let (x, y) = pixels(e), flags = e.modifierFlags.rawValue
        var m = MacKeys.modifiers(flags: flags)
        if MacKeys.secondaryClick(flags: flags) {
            // Control-click is a right click: the press opens the menu, the release follows at once (no drag).
            m.insert(.secondary)
            send(.mouseDown(x: x, y: y, modifiers: m)); send(.mouseUp(x: x, y: y))
            return
        }
        mouseIsDown = true
        send(.mouseDown(x: x, y: y, modifiers: m))
    }

    override func rightMouseDown(with e: NSEvent) {
        let (x, y) = pixels(e)
        send(.mouseDown(x: x, y: y, modifiers: MacKeys.modifiers(flags: e.modifierFlags.rawValue).union(.secondary)))
        send(.mouseUp(x: x, y: y))
    }

    /// The Mac `ScrubField` hides and pins the pointer while a value scrubs: `HostRequests.pointerLock` asks for it, the
    /// raw event deltas then drive a virtual position (the drag is not bounded by the screen edge).
    private var pointerLock = PointerLockTracker()
    private var pointerPinned = false

    private func releasePointer() {
        guard pointerPinned else { return }
        pointerPinned = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    override func mouseDragged(with e: NSEvent) {
        guard mouseIsDown else { return }
        var (x, y) = pixels(e)
        let s = Float(controller.screen.theme.scale)
        let locked = HostRequests.shared.pointerLock
        (x, y) = pointerLock.drag(x: x, y: y, dx: Float(e.deltaX) * s, dy: Float(e.deltaY) * s, locked: locked)
        if locked, !pointerPinned {
            pointerPinned = true
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(0)
        }
        send(.mouseDragged(x: x, y: y))
        if !HostRequests.shared.pointerLock { releasePointer() }
    }

    override func mouseUp(with e: NSEvent) {
        guard mouseIsDown else { return }
        mouseIsDown = false
        var (x, y) = pixels(e)
        (x, y) = pointerLock.release(x: x, y: y)
        releasePointer()
        send(.mouseUp(x: x, y: y))
    }

    override func mouseMoved(with e: NSEvent) {
        let (x, y) = pixels(e)
        send(.mouseMoved(x: x, y: y))
        updateCursor()
    }

    override func mouseExited(with e: NSEvent) {
        HostHover.shared.pointerExited(now: ProcessInfo.processInfo.systemUptime)
        // A move far outside every panel ends their hover highlights (Windows WM_MOUSELEAVE; the Mac views clear on exit).
        if !mouseIsDown { send(.mouseMoved(x: -100_000, y: -100_000)) }
        dirty = true
        needsDisplay = true
    }

    override func scrollWheel(with e: NSEvent) {
        let g = MacScroll.scroll(deltaX: Double(e.scrollingDeltaX), deltaY: Double(e.scrollingDeltaY),
                                 precise: e.hasPreciseScrollingDeltas, phase: UInt(e.phase.rawValue),
                                 momentumPhase: UInt(e.momentumPhase.rawValue))
        sendGesture(g, e)
    }

    /// Pinch: a zero-pixel scroll with the gesture, so it reaches the panel under the pointer (`TimelineView.magnify`).
    override func magnify(with e: NSEvent) {
        sendGesture(MacScroll.magnify(Double(e.magnification), phase: UInt(e.phase.rawValue)), e)
    }

    /// Two-finger double tap (Fast Cut: zoom to fit).
    override func smartMagnify(with e: NSEvent) {
        sendGesture(ScrollGesture(kind: .smartMagnify, precise: true), e)
    }

    /// AppKit signs and sizes (`MacScroll.pixels`); the panels that port an AppKit view read the raw gesture.
    private func sendGesture(_ g: ScrollGesture, _ e: NSEvent) {
        let (x, y) = pixels(e)
        let px = MacScroll.pixels(g, scale: Float(controller.screen.theme.scale))
        HostGesture.shared.with(g) {
            send(.scroll(x: x, y: y, dx: px.dx, dy: px.dy, modifiers: MacKeys.modifiers(flags: e.modifierFlags.rawValue)))
        }
    }

    // MARK: Keys and text

    override func keyDown(with e: NSEvent) {
        let mods = MacKeys.keyModifiers(flags: e.modifierFlags.rawValue)
        // Shortcuts follow the cap, not the key position (Cmd-Z, Cmd-+, Cmd-- on a German QWERTZ keyboard).
        let key = MacKeys.key(code: e.keyCode, base: e.characters(byApplyingModifiers: []))
        var committed = "", composing = hasMarkedText()
        if !mods.contains(.command) {
            collecting = ""
            interpretKeyEvents([e])
            committed = collecting ?? ""
            collecting = nil
            composing = composing || hasMarkedText()
        }
        HostKeyRepeat.shared.with(e.isARepeat) {
            for ev in MacKeys.events(key: key, modifiers: mods, committed: committed, composing: composing) { send(ev) }
        }
    }

    override func keyUp(with e: NSEvent) {
        guard let k = MacKeys.key(code: e.keyCode) else { return }
        controller.keyUp(k)
        dirty = true
    }

    /// Every key press goes to the shell's key map (focus-scoped, as on Windows) before the system menu bar sees it, so
    /// a shortcut the menu also shows runs once. Only the system's Hide and Quit (Cmd-H, Cmd-Q) pass to the menu.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard let w = window, e.type == .keyDown else { return false }
        if w.firstResponder !== self {
            // Focus drifted off the view (a closed panel or dialog left the window itself as responder): take it back, or
            // Cmd-Z would reach the menu bar's stale Undo row and do nothing. A system text editor keeps its keys.
            if w.firstResponder is NSText || w.attachedSheet != nil || w.isSheet || !w.makeFirstResponder(self) { return false }
        }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, ["q", "h"].contains(e.charactersIgnoringModifiers ?? "") { return false }
        keyDown(with: e)
        return true
    }

    override func doCommand(by selector: Selector) {}   // arrows, return, delete: the key map's keys already carry them

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSMutableAttributedString()
        HostRequests.shared.composition = ""
        dirty = true
        if collecting != nil { collecting? += s; return }
        // Committed outside a key press (the IME candidate window clicked): type it.
        for c in s { send(.keyDown(.character(c), modifiers: [])) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Drawn inline at the focused field's caret (`HostRequests.drawComposition`); the candidate window sits under it.
        marked = NSMutableAttributedString(attributedString: (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? ""))
        HostRequests.shared.composition = marked.string
        dirty = true
    }

    func unmarkText() { marked = NSMutableAttributedString(); HostRequests.shared.composition = ""; dirty = true }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// The candidate window opens at the focused field's caret (`HostRequests.caret`, device pixels), else under the
    /// pointer.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let w = window else { return .zero }
        let r: NSRect
        if let c = HostRequests.shared.caret {
            let s = CGFloat(controller.screen.theme.scale)
            r = NSRect(x: CGFloat(c.x) / s, y: CGFloat(c.y) / s, width: max(CGFloat(c.w) / s, 1), height: CGFloat(c.h) / s)
        } else {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            r = NSRect(x: p.x, y: p.y, width: 1, height: 18)
        }
        return w.convertToScreen(convert(r, to: nil))
    }

    // MARK: File drops

    private func droppedURLs(_ sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func dropPixels(_ sender: any NSDraggingInfo) -> (Float, Float) { canvasPixels(convert(sender.draggingLocation, from: nil)) }

    private func fileHover(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard role != .start else { return .copy }
        let (x, y) = dropPixels(sender)
        controller.fileDrag(droppedURLs(sender), phase: .moved, x: x, y: y)
        dirty = true; needsDisplay = true
        return .copy
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { fileHover(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { fileHover(sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard role != .start else { return }
        controller.fileDrag([], phase: .canceled, x: -1, y: -1)
        dirty = true; needsDisplay = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        let (x, y) = dropPixels(sender)
        if role == .start || !controller.fileDrag(urls, phase: .ended, x: x, y: y) { controller.drop(urls) }
        dirty = true
        return true
    }
}
