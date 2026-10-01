import AppKit
import Metal
import QuartzCore
import SQRender

/// Draws `ScopeGraticule` over the plot rect (labels, circle, target boxes, skin-tone line, histogram axes).
@MainActor
final class ScopeOverlayView: NSView {
    var kind: ScopeKind = .waveform { didSet { needsDisplay = true } }
    static let labelMargin: CGFloat = 28
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func plot() -> CGRect {
        let r = ScopeGraticule.plotRect(kind, in: (bounds.width, bounds.height), labelMargin: Self.labelMargin)
        return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = plot()
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: p.minX + x * p.width, y: p.minY + y * p.height) }
        let line = Theme.white(0.16), major = Theme.white(0.30)
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.meter, .foregroundColor: Theme.Colors.label3]

        switch kind {
        case .waveform, .parade:
            for l in ScopeGraticule.ireLines {
                let y = pt(0, l.y).y
                (l.isMajor ? major : line).setFill()
                NSRect(x: p.minX, y: min(max(y - 0.5, p.minY), p.maxY - 1), width: p.width, height: 1).fill()
                let s = NSAttributedString(string: "\(l.ire)", attributes: attrs)
                let size = s.size()
                s.draw(at: CGPoint(x: p.minX - size.width - 4, y: min(max(y - size.height / 2, 0), bounds.height - size.height)))
            }
            if kind == .parade {
                line.setFill()
                for i in 1...2 { NSRect(x: p.minX + p.width * CGFloat(i) / 3 - 0.5, y: p.minY, width: 1, height: p.height).fill() }
            }
        case .vectorscope:
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.setLineWidth(1)
            ctx.setStrokeColor(major.cgColor)
            ctx.strokeEllipse(in: p.insetBy(dx: 0.5, dy: 0.5))
            ctx.setStrokeColor(line.cgColor)
            ctx.strokeEllipse(in: CGRect(x: p.midX - p.width / 4, y: p.midY - p.height / 4, width: p.width / 2, height: p.height / 2))
            ctx.move(to: CGPoint(x: p.minX, y: p.midY)); ctx.addLine(to: CGPoint(x: p.maxX, y: p.midY))
            ctx.move(to: CGPoint(x: p.midX, y: p.minY)); ctx.addLine(to: CGPoint(x: p.midX, y: p.maxY))
            ctx.strokePath()
            // Skin-tone line.
            let e = ScopeGraticule.skinToneLineEnd
            ctx.setStrokeColor(Theme.Colors.yellow.withAlphaComponent(0.55).cgColor)
            ctx.move(to: pt(0.5, 0.5)); ctx.addLine(to: pt(e.x, e.y)); ctx.strokePath()
            // 75 % and 100 % target boxes.
            let half = max(3, p.width * 0.028)
            for (amp, alpha) in [(0.75, 0.75), (1.0, 0.40)] {
                ctx.setStrokeColor(Theme.white(alpha).cgColor)
                for t in ScopeGraticule.vectorscopeTargets(amplitude: amp) {
                    let c = pt(t.center.x, t.center.y)
                    ctx.stroke(CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2))
                }
            }
            for t in ScopeGraticule.vectorscopeTargets(amplitude: 1) {
                let c = pt(t.center.x, t.center.y)
                let s = NSAttributedString(string: t.name, attributes: attrs)
                let size = s.size()
                // Push labels outward from the centre.
                let dx = c.x - p.midX, dy = c.y - p.midY, n = max((dx * dx + dy * dy).squareRoot(), 1)
                let off = half + 5
                s.draw(at: CGPoint(x: c.x + dx / n * off - size.width / 2, y: c.y + dy / n * off - size.height / 2))
            }
        case .histogram:
            for v in ScopeGraticule.histogramVerticals {
                let x = pt(v, 0).x
                (v == 0 || v == 1 ? major : line).setFill()
                NSRect(x: min(max(x - 0.5, p.minX), p.maxX - 1), y: p.minY, width: 1, height: p.height).fill()
            }
            for (i, label) in ["0", "25", "50", "75", "100"].enumerated() {
                let s = NSAttributedString(string: label, attributes: attrs)
                let size = s.size()
                let x = pt(ScopeGraticule.histogramVerticals[i], 0).x
                s.draw(at: CGPoint(x: min(max(x - size.width / 2, 2), p.maxX - size.width - 2), y: p.maxY - size.height - 2))
            }
        }
    }
}

/// CAMetalLayer-backed surface for the scope texture.
@MainActor
final class ScopeMetalView: NSView {
    let metalLayer = CAMetalLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.pixelFormat = ScopeRenderer.colorFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = Theme.Colors.viewer.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { metalLayer }
    func syncDrawableSize() {
        let s = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = s
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncDrawableSize() }
    override func layout() { super.layout(); syncDrawableSize() }
}

private final class BusyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func tryAcquire() -> Bool { lock.lock(); defer { lock.unlock() }; if value { return false }; value = true; return true }
    func release() { lock.lock(); value = false; lock.unlock() }
}

/// Scopes panel content: segmented picker (Waveform, Parade, Vectorscope, Histogram) over a GPU-drawn scope with graticule overlay.
/// Feed it with `update(frame:)` (working-linear texture: rgba16Float/32Float, `.shaderRead`).
@MainActor
public final class ScopesView: NSView {
    public let picker = NSSegmentedControl(labels: ScopeKind.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    public private(set) var kind: ScopeKind = .waveform
    /// Trace brightness multiplier.
    public var intensity: Float = 1 { didSet { redraw() } }
    /// Sample every Nth pixel in x and y when accumulating (performance knob for 4K).
    public var pixelStride: Int = 2

    private let metalView = ScopeMetalView(frame: .zero)
    private let overlay = ScopeOverlayView(frame: .zero)
    private let queue: MTLCommandQueue
    private let scopes: ScopesGPU
    private let renderer: ScopeRenderer
    private let resources: ScopeResources
    private let busy = BusyFlag()
    private var hasData = false

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let q = device.makeCommandQueue(),
              let s = try? ScopesGPU(device: device), let r = try? ScopeRenderer(device: device),
              let res = s.makeResources() else { return nil }
        queue = q; scopes = s; renderer = r; resources = res
        super.init(frame: .zero)
        metalView.metalLayer.device = device
        picker.segmentStyle = .texturedRounded
        picker.controlSize = .small
        picker.font = NSFont.systemFont(ofSize: 11)
        picker.selectedSegment = kind.rawValue
        picker.target = self
        picker.action = #selector(pickerChanged)
        addSubview(metalView); addSubview(overlay); addSubview(picker)
        overlay.kind = kind
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    public func select(_ k: ScopeKind) {
        kind = k
        picker.selectedSegment = k.rawValue
        overlay.kind = k
        needsLayout = true
        redraw()
    }

    @objc private func pickerChanged() {
        if let k = ScopeKind(rawValue: picker.selectedSegment) { select(k) }
    }

    public override func layout() {
        super.layout()
        let headerH = Theme.Metrics.panelHeader
        picker.sizeToFit()
        let pw = min(bounds.width - 2 * Theme.Spacing.sm, max(picker.frame.width, 280))
        picker.frame = CGRect(x: (bounds.width - pw) / 2, y: bounds.height - headerH + (headerH - picker.frame.height) / 2,
                              width: pw, height: picker.frame.height)
        let area = CGRect(x: Theme.Spacing.sm, y: Theme.Spacing.sm,
                          width: max(0, bounds.width - 2 * Theme.Spacing.sm),
                          height: max(0, bounds.height - headerH - Theme.Spacing.sm))
        overlay.frame = area
        let p = overlay.plot()
        // Overlay is flipped (origin top-left); convert to this view's bottom-left coordinates.
        metalView.frame = CGRect(x: area.minX + p.minX, y: area.minY + (area.height - p.maxY), width: p.width, height: p.height)
        redraw()
    }

    /// Runs the SQRender scopes on `frame` and draws.
    public func update(frame: MTLTexture) {
        guard busy.tryAcquire() else { return }      // previous frame still in flight: drop
        guard let cb = queue.makeCommandBuffer() else { busy.release(); return }
        scopes.encode(source: frame, into: resources, scopes: .all, pixelStride: pixelStride, commandBuffer: cb)
        hasData = true
        drawPass(commandBuffer: cb)
        let flag = busy
        cb.addCompletedHandler { _ in flag.release() }
        cb.commit()
    }

    /// Redraws the last computed scope (resize, picker change).
    public func redraw() {
        guard hasData, busy.tryAcquire() else { return }
        guard let cb = queue.makeCommandBuffer() else { busy.release(); return }
        drawPass(commandBuffer: cb)
        let flag = busy
        cb.addCompletedHandler { _ in flag.release() }
        cb.commit()
    }

    private func drawPass(commandBuffer cb: MTLCommandBuffer) {
        let layer = metalView.metalLayer
        guard layer.drawableSize.width >= 1, let drawable = layer.nextDrawable() else { return }
        renderer.encode(kind: kind, resources: resources, target: drawable.texture, intensity: intensity, commandBuffer: cb)
        cb.present(drawable)
    }
}
