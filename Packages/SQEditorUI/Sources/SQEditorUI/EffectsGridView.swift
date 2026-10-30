import AppKit
import SQCore
import SQInspectorUI
import SQText

/// Thumbnails and hover loops of the Effects grid. All pixels are made off the main thread (`Task.detached`) from the
/// procedural samples in `EffectPreviewPlan`, then cached for the session: hovering only picks a cached frame.
@MainActor
final class EffectPreviewStore {
    private final class Frames: @unchecked Sendable {
        let images: [CGImage]
        init(_ i: [CGImage]) { images = i }
    }
    private(set) var stills: [String: CGImage] = [:]
    private(set) var loops: [String: [CGImage]] = [:]
    private var stillsRequested = false
    private var loopsInFlight: Set<String> = []
    /// Milliseconds spent building the last batch of stills / the last loop (off the main thread).
    private(set) var lastStillsMillis = 0.0, lastLoopMillis = 0.0
    var onChange: (() -> Void)?

    private nonisolated static let w = EffectPreviewPlan.sampleWidth
    private nonisolated static let h = EffectPreviewPlan.sampleHeight
    private nonisolated static let samples = EffectPreviewPlan.sampleImages(width: w, height: h)

    func requestStills(ids: [String]) {
        guard !stillsRequested else { return }
        stillsRequested = true
        Task.detached(priority: .utility) { [weak self] in
            let t0 = ContinuousClock.now
            var out: [String: Frames] = [:]
            for id in ids { if let s = Self.buildStill(id) { out[id] = Frames([s]) } }
            let ms = Self.millis(since: t0)
            await MainActor.run {
                guard let self else { return }
                for (id, f) in out { self.stills[id] = f.images[0] }
                self.lastStillsMillis = ms
                self.onChange?()
            }
        }
    }

    func requestLoop(id: String) {
        guard loops[id] == nil, !loopsInFlight.contains(id) else { return }
        loopsInFlight.insert(id)
        Task.detached(priority: .utility) { [weak self] in
            let t0 = ContinuousClock.now
            let frames = Self.buildLoop(id)
            let ms = Self.millis(since: t0)
            await MainActor.run {
                guard let self else { return }
                self.loopsInFlight.remove(id)
                if let frames { self.loops[id] = frames.images }
                self.lastLoopMillis = ms
                self.onChange?()
            }
        }
    }

    private nonisolated static func millis(since t: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private nonisolated static func image(_ bytes: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private nonisolated static func buildStill(_ id: String) -> CGImage? {
        switch EffectPreviewPlan.style(forID: id) {
        case .videoTransition(let k):
            return image(EffectPreviewPlan.blend(samples.a, samples.b, kind: k, weight: k == .crossDissolve ? 0.5 : 0.3))
        case .effect(let e):
            return image(EffectPreviewPlan.effectAfter(e, source: EffectPreviewPlan.effectBefore(e, sample: samples.a, width: w, height: h), width: w, height: h))
        case .textPreset(let t):
            return TextPresetPreview.still(t, background: samples.a, width: w, height: h).flatMap(image)
        case .audioTransition, nil:
            return nil      // drawn as curves
        }
    }

    private nonisolated static func buildLoop(_ id: String) -> Frames? {
        switch EffectPreviewPlan.style(forID: id) {
        case .videoTransition(let k):
            guard let a = image(samples.a), let b = image(samples.b) else { return nil }
            var cache: [Double: CGImage] = [0: a, 1: b]
            var out: [CGImage] = []
            for wgt in EffectPreviewPlan.transitionLoop {
                if let c = cache[wgt] { out.append(c); continue }
                guard let img = image(EffectPreviewPlan.blend(samples.a, samples.b, kind: k, weight: wgt)) else { return nil }
                cache[wgt] = img; out.append(img)
            }
            return Frames(out)
        case .effect(let e):
            let before = EffectPreviewPlan.effectBefore(e, sample: samples.a, width: w, height: h)
            guard let b = image(before), let a = image(EffectPreviewPlan.effectAfter(e, source: before, width: w, height: h)) else { return nil }
            let half = Int(EffectPreviewPlan.fps * 0.9)
            return Frames([CGImage](repeating: b, count: half) + [CGImage](repeating: a, count: half))
        case .textPreset(let t):
            guard let frames = TextPresetPreview.loop(t, fps: EffectPreviewPlan.fps, background: samples.a, width: w, height: h) else { return nil }
            return Frames(frames.compactMap(image))
        case .audioTransition, nil:
            return nil
        }
    }
}

/// The Effects panel's grid: category headers and 16:9 tiles. Hovering a tile plays its preview (cached frames, 30 Hz
/// timer only while hovered, redraws only that tile). Click selects, double-click applies, drag starts the same effect-id
/// drag as the list.
@MainActor
final class EffectsGridView: NSView, NSDraggingSource {
    override var isFlipped: Bool { true }
    var onApply: ((String) -> Void)?
    var onSelect: ((String?) -> Void)?
    var rows: [TemplateListPanelView.Row] = [] { didSet { relayout(); needsDisplay = true } }
    private(set) var selectedID: String?
    private var layoutInfo = EffectsGridLayout(rows: [], width: 100, tileWidth: 104)
    private let tileWidth: CGFloat = 104
    private let store = EffectPreviewStore()
    private var hoveredID: String?
    private var hoverStart: Date?
    private var timer: Timer?
    private var downPoint: CGPoint?
    private var downID: String?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        store.onChange = { [weak self] in self?.needsDisplay = true }
        setAccessibilityLabel("Effects grid")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func select(id: String?) { selectedID = id; needsDisplay = true }

    /// Lays out for the width of the enclosing scroll view and returns the document height.
    @discardableResult func relayout() -> CGFloat {
        layoutInfo = EffectsGridLayout(rows: rows, width: max(frame.width, 1), tileWidth: tileWidth)
        let h = layoutInfo.contentHeight
        if abs(frame.height - h) > 0.5 { setFrameSize(NSSize(width: frame.width, height: h)) }
        store.requestStills(ids: rows.filter { !$0.isHeader }.map(\.id))
        return h
    }
    override func setFrameSize(_ s: NSSize) {
        let widthChanged = abs(s.width - frame.width) > 0.5
        super.setFrameSize(s)
        if widthChanged { layoutInfo = EffectsGridLayout(rows: rows, width: max(s.width, 1), tileWidth: tileWidth); needsDisplay = true }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for item in layoutInfo.items where item.frame.intersects(dirtyRect) {
            if item.isHeader { drawHeader(item); continue }
            drawTile(item, ctx)
        }
    }

    private func drawHeader(_ item: EffectsGridLayout.Item) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label2]
        let s = NSAttributedString(string: item.title, attributes: attrs)
        s.draw(at: CGPoint(x: EffectsGridLayout.pad, y: item.frame.midY - s.size().height / 2))
    }

    private func drawTile(_ item: EffectsGridLayout.Item, _ ctx: CGContext) {
        let hovered = item.id == hoveredID, selected = item.id == selectedID
        let thumb = item.thumb
        let path = NSBezierPath(roundedRect: thumb, xRadius: LibraryTile.thumbRadius, yRadius: LibraryTile.thumbRadius)
        ctx.saveGState()
        path.addClip()
        Theme.Colors.field.setFill(); thumb.fill()
        let style = EffectPreviewPlan.style(forID: item.id)
        if case .audioTransition(let kind) = style {
            drawCurves(kind, in: thumb, progress: hovered ? loopProgress(period: 1) : nil)
        } else if let img = currentImage(item.id, hovered: hovered) {
            ctx.saveGState()
            ctx.translateBy(x: thumb.minX, y: thumb.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(origin: .zero, size: thumb.size))
            ctx.restoreGState()
        } else {
            drawPlaceholder(item.symbol, in: thumb)
        }
        ctx.restoreGState()
        if selected {
            Theme.Colors.yellow.setStroke()          // sq.css `.tile.on`: 2 pt yellow ring, same as the Library tiles
            let w = LibraryTile.ringWidth
            let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: w / 2, dy: w / 2),
                                    xRadius: LibraryTile.thumbRadius - w / 2, yRadius: LibraryTile.thumbRadius - w / 2)
            ring.lineWidth = w; ring.stroke()
        } else if hovered {
            Theme.Colors.fillPressed.setStroke()
            let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: LibraryTile.thumbRadius - 0.5, yRadius: LibraryTile.thumbRadius - 0.5)
            ring.lineWidth = 1; ring.stroke()
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail; para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .paragraphStyle: para,
                                                    .foregroundColor: selected ? Theme.Colors.label : Theme.Colors.label2]
        NSAttributedString(string: item.title, attributes: attrs)
            .draw(in: CGRect(x: item.frame.minX, y: thumb.maxY + 5, width: item.frame.width, height: 13))   // sq.css `.tile` gap 5
    }

    private func drawPlaceholder(_ symbol: SQIcon, in r: CGRect) {
        let tinted = symbol.image(size: 18, color: Theme.Colors.label3)
        tinted.draw(in: CGRect(x: r.midX - tinted.size.width / 2, y: r.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
    }

    /// Audio crossfade: outgoing and incoming gain curves, with a moving line while hovered.
    private func drawCurves(_ kind: TransitionKind, in r: CGRect, progress: Double?) {
        let box = r.insetBy(dx: 10, dy: 12)
        func curve(_ pick: (Double, Double) -> Double, _ color: NSColor) {
            let p = NSBezierPath()
            for i in 0...32 {
                let t = Double(i) / 32
                let g = TransitionMix.audioGains(kind, progress: t)
                let pt = CGPoint(x: box.minX + box.width * t, y: box.maxY - box.height * pick(g.outgoing, g.incoming))
                i == 0 ? p.move(to: pt) : p.line(to: pt)
            }
            color.setStroke(); p.lineWidth = 1.5; p.stroke()
        }
        curve({ o, _ in o }, Theme.Colors.clipAudioWave)
        curve({ _, i in i }, Theme.Colors.accent)
        if let p = progress {
            let x = box.minX + box.width * p
            Theme.Colors.label2.setStroke()
            let l = NSBezierPath(); l.move(to: CGPoint(x: x, y: r.minY + 4)); l.line(to: CGPoint(x: x, y: r.maxY - 4)); l.lineWidth = 1; l.stroke()
        }
    }

    private func loopProgress(period: Double) -> Double {
        guard let t = hoverStart else { return 0 }
        return (Date().timeIntervalSince(t) / period).truncatingRemainder(dividingBy: 1)
    }

    private func currentImage(_ id: String, hovered: Bool) -> CGImage? {
        if hovered, let loop = store.loops[id], !loop.isEmpty, let t = hoverStart {
            let f = Int(Date().timeIntervalSince(t) * EffectPreviewPlan.fps) % loop.count
            return loop[f]
        }
        return store.stills[id]
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) { setHover(layoutInfo.hit(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func setHover(_ id: String?) {
        guard id != hoveredID else { return }
        let old = hoveredID
        hoveredID = id
        if let old, let it = layoutInfo.items.first(where: { $0.id == old }) { setNeedsDisplay(it.frame) }
        if let id {
            hoverStart = Date()
            store.requestLoop(id: id)
            if let it = layoutInfo.items.first(where: { $0.id == id }) { setNeedsDisplay(it.frame) }
            if timer == nil {
                let t = Timer(timeInterval: 1 / EffectPreviewPlan.fps, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            hoverStart = nil
            timer?.invalidate(); timer = nil
        }
    }

    private func tick() {
        guard let id = hoveredID, window != nil, let it = layoutInfo.items.first(where: { $0.id == id }) else { return }
        setNeedsDisplay(it.thumb)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { setHover(nil) } }
    override func viewDidHide() { super.viewDidHide(); setHover(nil) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        downID = layoutInfo.hit(p)
        selectedID = downID
        onSelect?(downID)
        needsDisplay = true
        if event.clickCount == 2, let id = downID { onApply?(id) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let id = downID, let item = layoutInfo.items.first(where: { $0.id == id }) else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downPoint = nil
        let pb = NSPasteboardItem()
        pb.setString(id, forType: .sequenceEffectID)
        let drag = NSDraggingItem(pasteboardWriter: pb)
        let img = NSImage(size: item.thumb.size, flipped: false) { [weak self] r in
            if let c = self?.store.stills[id], let ctx = NSGraphicsContext.current?.cgContext { ctx.draw(c, in: r) }
            else { Theme.Colors.fill.setFill(); r.fill() }
            return true
        }
        drag.setDraggingFrame(item.thumb, contents: img)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
