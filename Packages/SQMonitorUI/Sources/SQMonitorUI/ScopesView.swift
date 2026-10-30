import AppKit
import Metal
import QuartzCore
import SQRender

/// Layout of the Scopes panel (design board Panels "Scopes"): body inset 12 at the sides and 10 above and below, 8
/// between a popup and its scope and between two scopes; the first scope box is 170 high when two are shown.
enum ScopeLayout {
    static let side = Theme.Spacing.md
    static let top: CGFloat = 10
    static let gap = Theme.Spacing.sm
    static let firstBox: CGFloat = 170
    /// The least height a second scope is worth showing at.
    static let minSecondBox: CGFloat = 120
    /// Board: the vectorscope disc is 190 across and its gamut ring sits at 46 % of that (92 % of the disc).
    static let vectorDisc: CGFloat = 190
    static let vectorRing: CGFloat = 0.92

    /// The dark disc around a vectorscope ring `p`.
    static func vectorDisc(ofRing p: CGRect) -> CGRect { p.insetBy(dx: -p.width * (1 / vectorRing - 1) / 2, dy: -p.height * (1 / vectorRing - 1) / 2) }

    /// Board label positions inside the disc: R top-center, Mg right, B bottom-right, Cy bottom-left, G left, Yl top-left.
    static func vectorLabelOrigins(disc d: CGRect, textHeight h: CGFloat, widthOf: (String) -> CGFloat) -> [(String, CGPoint)] {
        [("R", CGPoint(x: d.minX + d.width * 0.5, y: d.minY + 12)),
         ("Mg", CGPoint(x: d.maxX - 16 - widthOf("Mg"), y: d.minY + d.height * 0.44)),
         ("B", CGPoint(x: d.maxX - 50 - widthOf("B"), y: d.maxY - 14 - h)),
         ("Cy", CGPoint(x: d.minX + 40, y: d.maxY - 16 - h)),
         ("G", CGPoint(x: d.minX + 14, y: d.minY + d.height * 0.5)),
         ("Yl", CGPoint(x: d.minX + 40, y: d.minY + 22))]
    }

    /// Color page row (version 9): 2 pt between the scopes, each under a caption.
    static let rowGap: CGFloat = 2
    static let rowInset = Theme.Spacing.sm
    static func caption(_ k: ScopeKind) -> String {
        switch k {
        case .waveform: "Waveform"
        case .parade: "RGB parade"
        case .vectorscope: "Vectorscope"
        case .histogram: "Histogram"
        }
    }

    /// The popup titles: the scope and what it measures.
    static func title(_ k: ScopeKind) -> String {
        switch k {
        case .waveform: "Waveform \u{00B7} Luma"
        case .parade: "Parade \u{00B7} RGB"
        case .vectorscope: "Vectorscope"
        case .histogram: "Histogram"
        }
    }

    /// The plot inside a scope box of `size` (pure, tested): waveform leaves 26 at the left for its labels, the
    /// histogram 16 below; the vectorscope is the largest centered circle with room for its labels.
    static func plot(_ k: ScopeKind, in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch k {
        case .waveform: return CGRect(x: 26, y: 8, width: max(w - 32, 0), height: max(h - 16, 0))
        case .parade: return CGRect(x: 6, y: 8, width: max(w - 12, 0), height: max(h - 16, 0))
        case .histogram: return CGRect(x: 6, y: 6, width: max(w - 12, 0), height: max(h - 22, 0))
        case .vectorscope:
            let d = max(min(vectorDisc, w, h), 0) * vectorRing
            return CGRect(x: ((w - d) / 2).rounded(), y: ((h - d) / 2).rounded(), width: d, height: d)
        }
    }

    /// Whether a second scope fits under the first in a panel `height` high with popups `popup` high.
    static func showsTwo(height: CGFloat, popup: CGFloat) -> Bool {
        height >= 2 * top + 2 * popup + 3 * gap + firstBox + minSecondBox
    }
}

/// Draws the graticule over a scope box (labels, circle, target boxes, skin tone line, histogram axis).
@MainActor
final class ScopeOverlayView: NSView {
    var kind: ScopeKind = .waveform { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func plot() -> CGRect { ScopeLayout.plot(kind, in: bounds.size) }

    override func draw(_ dirtyRect: NSRect) {
        let p = plot()
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: p.minX + x * p.width, y: p.minY + y * p.height) }
        let line = Theme.Palette.scopeLine, major = Theme.Palette.scopeMajor
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]

        switch kind {
        case .waveform, .parade:
            for ire in [100, 75, 50, 25, 0] {
                let y = pt(0, 1 - Double(ire) / 100).y
                line.setFill()
                NSRect(x: p.minX, y: min(max(y - 0.5, p.minY), p.maxY - 1), width: p.width, height: 1).fill()
                guard kind == .waveform else { continue }
                // Board label tops: 4 pt from the top, 27 %, 48 %, 70 % of the box, 4 pt from the bottom.
                let s = NSAttributedString(string: "\(ire)", attributes: attrs)
                let size = s.size()
                let top: CGFloat
                switch ire {
                case 100: top = 4
                case 75: top = bounds.height * 0.27
                case 50: top = bounds.height * 0.48
                case 25: top = bounds.height * 0.70
                default: top = bounds.height - 4 - size.height
                }
                s.draw(at: CGPoint(x: 6, y: top))
            }
            if kind == .parade {
                line.setFill()
                for i in 1...2 { NSRect(x: p.minX + p.width * CGFloat(i) / 3 - 0.5, y: p.minY, width: 1, height: p.height).fill() }
            }
        case .vectorscope:
            let ctx = NSGraphicsContext.current!.cgContext
            // Board: a dark disc, the gamut ring at 46 % of its diameter, an inner ring at 23 %, the cross, labels only.
            let disc = ScopeLayout.vectorDisc(ofRing: p)
            ctx.setFillColor(Theme.Colors.scopeBox.cgColor)
            ctx.fillEllipse(in: disc)
            ctx.setLineWidth(1)
            ctx.setStrokeColor(major.cgColor)
            ctx.strokeEllipse(in: p.insetBy(dx: 0.5, dy: 0.5))
            ctx.strokeEllipse(in: CGRect(x: p.midX - p.width / 4, y: p.midY - p.height / 4, width: p.width / 2, height: p.height / 2))
            ctx.move(to: CGPoint(x: p.minX, y: p.midY)); ctx.addLine(to: CGPoint(x: p.maxX, y: p.midY))
            ctx.move(to: CGPoint(x: p.midX, y: p.minY)); ctx.addLine(to: CGPoint(x: p.midX, y: p.maxY))
            ctx.strokePath()
            let e = ScopeGraticule.skinToneLineEnd
            ctx.setStrokeColor(Theme.Palette.scopeSkinTone.cgColor)
            ctx.move(to: pt(0.5, 0.5)); ctx.addLine(to: pt(e.x, e.y)); ctx.strokePath()
            for (name, origin) in ScopeLayout.vectorLabelOrigins(disc: disc, textHeight: ceil(NSAttributedString(string: "R", attributes: attrs).size().height), widthOf: { NSAttributedString(string: $0, attributes: attrs).size().width }) {
                NSAttributedString(string: name, attributes: attrs).draw(at: origin)
            }
        case .histogram:
            for v in ScopeGraticule.histogramVerticals {
                let x = pt(v, 0).x
                (v == 0 || v == 1 ? major : line).setFill()
                NSRect(x: min(max(x - 0.5, p.minX), p.maxX - 1), y: p.minY, width: 1, height: p.height).fill()
            }
            for (v, label) in [(0.0, "0"), (0.5, "50"), (1.0, "100")] {
                let s = NSAttributedString(string: label, attributes: attrs)
                let size = s.size()
                let x = pt(v, 0).x
                s.draw(at: CGPoint(x: min(max(x - size.width / 2, p.minX), p.maxX - size.width),
                                   y: p.maxY + ((bounds.height - p.maxY - size.height) / 2).rounded()))
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
        metalLayer.backgroundColor = Theme.Colors.scopeBox.cgColor
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

/// Two private copies of the engine's composite, written by the engine's own command buffer (render thread) and read by
/// the scopes on their queue: the engine reuses one render target, reading it from another queue could show a half-written frame.
private final class FrameCopies: @unchecked Sendable {
    private let lock = NSLock()
    private var textures: [MTLTexture] = []
    private var next = 0

    /// The copy to write next (alternating), made again when the size or format of the frame changes.
    func target(for frame: MTLTexture) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let t = textures.first, t.width != frame.width || t.height != frame.height || t.pixelFormat != frame.pixelFormat {
            textures = []
        }
        if textures.isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: frame.pixelFormat, width: frame.width, height: frame.height, mipmapped: false)
            d.usage = [.shaderRead]; d.storageMode = .private
            textures = (0..<2).compactMap { _ in frame.device.makeTexture(descriptor: d) }
            guard textures.count == 2 else { textures = []; return nil }
        }
        defer { next = (next + 1) % textures.count }
        return textures[next]
    }
}

private struct SendableTexture: @unchecked Sendable { let texture: MTLTexture }

/// One scope of the Scopes panel: the popup that picks what it measures (with the skin tone legend beside it for the
/// vectorscope) above the scope itself (a dark rounded box; the vectorscope is a circle).
@MainActor
final class ScopeSlotView: NSView {
    let popup = SQPopup(frame: .zero, pullsDown: false)
    let metalView = ScopeMetalView(frame: .zero)
    private let box = FlippedBox()
    private let overlay = ScopeOverlayView(frame: .zero)
    private let legendLine = NSView()
    private let legend = NSTextField(labelWithString: "Skin tone")
    /// Shown inside the box instead of the scope ("No picture to measure").
    let emptyState = EmptyStateView(title: "")
    private(set) var kind: ScopeKind
    var onKindChange: (() -> Void)?
    /// What sits above the box: the popup (Scopes panel), a caption (Color page row) or nothing (one scope under tabs).
    enum Title { case popup, caption, none }
    var title = Title.popup { didSet { if title != oldValue { apply() } } }
    private let caption = NSTextField(labelWithString: "")
    /// The waveform settings (trace intensity), right of the title for a Waveform / RGB Parade; a right-click on the
    /// slot opens the same menu (`ScopeTraceSettings`, shared with the drawn Scopes card).
    lazy var settingsButton = SQButton(symbol: .slidersHorizontal, label: SQL10n.string(ScopeTraceSettings.buttonTip),
                                       target: self, action: #selector(showSettings), size: 12)
    /// Nothing to measure: the box shows the empty state.
    var isEmpty = false { didSet { if isEmpty != oldValue { apply() } } }

    private final class FlippedBox: NSView { override var isFlipped: Bool { true } }

    override var isFlipped: Bool { true }

    init(kind: ScopeKind, device: MTLDevice) {
        self.kind = kind
        super.init(frame: .zero)
        metalView.metalLayer.device = device
        for k in ScopeKind.allCases { popup.addItem(withTitle: ScopeLayout.title(k)) }
        popup.font = Theme.Typography.body
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.setAccessibilityLabel("Scope")
        box.wantsLayer = true
        box.layer?.masksToBounds = true
        box.layer?.borderColor = Theme.Separator.hairline.cgColor
        legendLine.wantsLayer = true
        legendLine.layer?.backgroundColor = Theme.Colors.warning.cgColor
        legend.font = Theme.Typography.body
        legend.textColor = Theme.Colors.label2
        box.addSubview(metalView)
        box.addSubview(overlay)
        box.addSubview(emptyState)
        caption.font = Theme.Typography.caption
        caption.textColor = Theme.Colors.label2
        for v in [popup, caption, legendLine, legend, box, settingsButton] as [NSView] { addSubview(v) }
        apply()
    }

    var hasSettings: Bool { ScopeTraceSettings.hasSettings(kind) && !isEmpty }

    @objc private func showSettings() {
        let r = convert(settingsButton.frame, to: nil)
        guard let w = window else { return }
        let screen = w.convertToScreen(r)
        SQMenuController.shared.present(items: ScopeTraceSettings.shared.menuItems(), at: CGPoint(x: screen.minX, y: screen.minY),
                                        anchor: settingsButton)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard hasSettings, let w = window else { super.rightMouseDown(with: event); return }
        let p = w.convertPoint(toScreen: event.locationInWindow)
        SQMenuController.shared.present(items: ScopeTraceSettings.shared.menuItems(), at: p)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func select(_ k: ScopeKind) {
        kind = k
        apply()
    }

    @objc private func popupChanged() {
        guard let k = ScopeKind(rawValue: popup.indexOfSelectedItem), k != kind else { return }
        select(k)
        onKindChange?()
    }

    private func apply() {
        popup.selectItem(at: kind.rawValue)
        overlay.kind = kind
        let circle = kind == .vectorscope && !isEmpty
        popup.isHidden = title != .popup
        caption.isHidden = title != .caption
        caption.stringValue = ScopeLayout.caption(kind)
        legendLine.isHidden = !circle || title != .popup
        legend.isHidden = !circle || title != .popup
        box.layer?.backgroundColor = circle ? nil : Theme.Colors.scopeBox.cgColor
        box.layer?.borderWidth = circle ? 0 : Theme.Separator.width
        box.layer?.cornerRadius = circle ? 0 : Theme.Radius.control
        metalView.isHidden = isEmpty
        settingsButton.isHidden = !hasSettings
        overlay.isHidden = isEmpty
        emptyState.isHidden = !isEmpty
        needsLayout = true
    }

    var popupHeight: CGFloat { popup.intrinsicContentSize.height }
    /// The settings button's side (the drawn card's `ScopesPanel.settingsButtonSize`).
    static let settingsSize: CGFloat = 16

    override func layout() {
        super.layout()
        if title != .popup {
            let ch = title == .caption ? ceil(caption.intrinsicContentSize.height) : 0
            caption.frame = NSRect(x: 0, y: 0, width: bounds.width, height: ch)
            let top = title == .caption ? ch + Theme.Spacing.xs : 0
            box.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
            overlay.frame = box.bounds
            emptyState.frame = box.bounds
            let p = overlay.plot()
            metalView.frame = p
            metalView.layer?.cornerRadius = kind == .vectorscope ? p.width / 2 : 0
            metalView.layer?.masksToBounds = kind == .vectorscope
            // Caption row: right end of the caption line; no title (header tabs): the box's top right corner.
            let d = Self.settingsSize
            settingsButton.frame = title == .caption
                ? NSRect(x: bounds.width - d, y: ((ch - d) / 2).rounded(), width: d, height: d)
                : NSRect(x: box.frame.maxX - d - Theme.Spacing.xs, y: box.frame.minY + Theme.Spacing.xs, width: d, height: d)
            return
        }
        let ps = popup.intrinsicContentSize
        popup.frame = NSRect(x: 0, y: 0, width: min(ps.width, bounds.width), height: ps.height)
        let ls = legend.intrinsicContentSize
        let lw = ceil(ls.width) + 6          // the exact intrinsic width clipped the last glyph ("tone")
        let lx = max(bounds.width - lw, popup.frame.maxX + Theme.Spacing.sm)
        legend.frame = NSRect(x: lx, y: ((ps.height - ls.height) / 2).rounded(), width: lw, height: ceil(ls.height))
        legend.alignment = .right
        legendLine.frame = NSRect(x: lx - Theme.Spacing.iconToLabel - 12, y: (ps.height / 2).rounded(), width: 12, height: 1)
        let d = Self.settingsSize
        settingsButton.frame = NSRect(x: bounds.width - d, y: ((ps.height - d) / 2).rounded(), width: d, height: d)
        let top = ps.height + ScopeLayout.gap
        box.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
        overlay.frame = box.bounds
        emptyState.frame = box.bounds
        let p = overlay.plot()
        metalView.frame = p
        // The vectorscope is a circle: its trace is cut to the graticule's outer ring.
        metalView.layer?.cornerRadius = kind == .vectorscope ? p.width / 2 : 0
        metalView.layer?.masksToBounds = kind == .vectorscope
    }
}

/// Scopes panel content (design board Panels "Scopes"): one scope under its popup ("Waveform \u{00B7} Luma", "Parade
/// \u{00B7} RGB", "Vectorscope", "Histogram"), and a second one below it when the panel is tall enough (the vectorscope
/// with its skin tone legend by default). GPU-drawn with a graticule overlay.
/// Feed it with `update(frame:)` (working-linear texture: rgba16Float/32Float, `.shaderRead`).
@MainActor
public final class ScopesView: NSView {
    /// The first scope's kind.
    public var kind: ScopeKind { slots[0].kind }
    /// Trace brightness multiplier.
    public var intensity: Float = 1 { didSet { redraw() } }
    /// Sample every Nth pixel in x and y when accumulating (performance knob for 4K).
    public var pixelStride: Int = 2
    /// The engine keeps one frame capture per key: a second scopes view (the Color page's row) uses its own.
    public var captureKey = "scopes"
    /// Nothing to measure: the first scope's box says so (title, hint), the second is hidden.
    public var emptyText: (title: String, hint: String)? {
        didSet {
            slots[0].isEmpty = emptyText != nil
            if let e = emptyText, slots[0].emptyState.title != e.title {
                slots[0].emptyState.title = e.title
                slots[0].emptyState.hint = e.hint
            }
            needsLayout = true
        }
    }

    /// How the scopes are laid out: the Scopes panel's stack (one scope under its popup, a second below when there is
    /// room), the Color page's row (Waveform, RGB parade and Vectorscope side by side, each under its caption) or one
    /// scope that fills the view (its kind comes from the panel header's tabs: `select`).
    public enum Arrangement: Sendable { case stacked, row, single }
    public var arrangement = Arrangement.stacked {
        didSet {
            guard arrangement != oldValue else { return }
            switch arrangement {
            case .stacked: for s in slots { s.title = .popup }
            case .row:
                for (s, k) in zip(slots, [ScopeKind.waveform, .parade, .vectorscope]) { s.title = .caption; s.select(k) }
            case .single: for s in slots { s.title = .none }
            }
            needsLayout = true
        }
    }

    let slots: [ScopeSlotView]
    private let queue: MTLCommandQueue
    private let scopes: ScopesGPU
    private let renderer: ScopeRenderer
    private let resources: ScopeResources
    private let busy = BusyFlag()
    private let copies = FrameCopies()
    private var hasData = false
    /// A redraw was asked for while the GPU was busy: run it when the frame in flight is done.
    private var redrawPending = false
    nonisolated(unsafe) private var settingsObserver: (any NSObjectProtocol)?
    deinit { settingsObserver.map(NotificationCenter.default.removeObserver) }

    public override var isFlipped: Bool { true }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let q = device.makeCommandQueue(),
              let s = try? ScopesGPU(device: device), let r = try? ScopeRenderer(device: device),
              let res = s.makeResources() else { return nil }
        queue = q; scopes = s; renderer = r; resources = res
        slots = [ScopeSlotView(kind: .waveform, device: device), ScopeSlotView(kind: .vectorscope, device: device),
                 ScopeSlotView(kind: .parade, device: device)]
        slots[2].isHidden = true
        super.init(frame: .zero)
        for slot in slots {
            addSubview(slot)
            slot.onKindChange = { [weak self] in self?.redraw() }
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: ScopeTraceSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video scopes")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `k` in the first scope.
    public func select(_ k: ScopeKind) {
        slots[0].select(k)
        redraw()
    }

    /// The second scope is shown.
    var showsTwo: Bool {
        emptyText == nil && ScopeLayout.showsTwo(height: bounds.height, popup: slots[0].popupHeight)
    }

    public override func layout() {
        super.layout()
        let x = ScopeLayout.side, w = max(bounds.width - 2 * ScopeLayout.side, 0)
        let h = max(bounds.height - 2 * ScopeLayout.top, 0)
        if arrangement != .stacked {
            // Row: equal columns with the panel gap between them. Single: the first scope fills the view.
            let n = arrangement == .row && emptyText == nil ? 3 : 1
            let gap = ScopeLayout.rowGap, inset = ScopeLayout.rowInset
            let cw = ((bounds.width - 2 * inset - CGFloat(n - 1) * gap) / CGFloat(n)).rounded(.down)
            for (i, s) in slots.enumerated() {
                s.isHidden = i >= n
                s.frame = CGRect(x: inset + CGFloat(i) * (cw + gap), y: inset, width: max(cw, 0), height: max(bounds.height - 2 * inset, 0))
                s.layoutSubtreeIfNeeded()
            }
            redraw()
            return
        }
        let two = showsTwo
        slots[1].isHidden = !two
        slots[2].isHidden = true
        if two {
            let first = slots[0].popupHeight + ScopeLayout.gap + ScopeLayout.firstBox
            slots[0].frame = CGRect(x: x, y: ScopeLayout.top, width: w, height: first)
            let y = ScopeLayout.top + first + ScopeLayout.gap
            slots[1].frame = CGRect(x: x, y: y, width: w, height: max(ScopeLayout.top + h - y, 0))
        } else {
            let box = emptyText == nil ? h : min(h, slots[0].popupHeight + ScopeLayout.gap + ScopeLayout.firstBox)
            slots[0].frame = CGRect(x: x, y: ScopeLayout.top, width: w, height: box)
        }
        for s in slots { s.layoutSubtreeIfNeeded() }
        redraw()
    }

    /// Refreshes the scopes from the engine's latest finished frame: the engine blits it into this view's own texture on
    /// its command buffer (no race with its next render), then the scopes run on that copy.
    public func requestUpdate(from engine: any ProgramEngine) {
        let copies = copies
        engine.requestFrameCapture(key: captureKey) { [weak self] frame, cb in
            guard let copy = copies.target(for: frame), let blit = cb.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: frame, to: copy)
            blit.endEncoding()
            let done = SendableTexture(texture: copy)
            return { Task { @MainActor in self?.update(frame: done.texture) } }
        }
    }

    /// Runs the SQRender scopes on `frame` and draws.
    public func update(frame: MTLTexture) {
        guard busy.tryAcquire() else { return }      // previous frame still in flight: drop
        guard let cb = queue.makeCommandBuffer() else { busy.release(); return }
        scopes.encode(source: frame, into: resources, scopes: .all, pixelStride: pixelStride, commandBuffer: cb)
        hasData = true
        drawPass(commandBuffer: cb)
        let flag = busy
        cb.addCompletedHandler { [weak self] _ in
            flag.release()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.runPendingRedraw() } }
        }
        cb.commit()
    }

    private func runPendingRedraw() {
        guard redrawPending else { return }
        redrawPending = false
        redraw()
    }

    /// Redraws the last computed scopes (resize, popup change).
    public func redraw() {
        guard hasData else { return }
        guard busy.tryAcquire() else { redrawPending = true; return }
        guard let cb = queue.makeCommandBuffer() else { busy.release(); return }
        drawPass(commandBuffer: cb)
        let flag = busy
        cb.addCompletedHandler { [weak self] _ in
            flag.release()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.runPendingRedraw() } }
        }
        cb.commit()
    }

    private func drawPass(commandBuffer cb: MTLCommandBuffer) {
        for slot in slots where !slot.isHidden && !slot.isEmpty {
            let layer = slot.metalView.metalLayer
            guard layer.drawableSize.width >= 1, layer.drawableSize.height >= 1, let drawable = layer.nextDrawable() else { continue }
            renderer.encode(kind: slot.kind, resources: resources, target: drawable.texture, intensity: intensity * ScopeTraceSettings.shared.intensity(for: slot.kind), commandBuffer: cb)
            cb.present(drawable)
        }
    }
}

extension Theme.Palette {
    /// Scope graticule: minor lines, major lines, skin tone line, vectorscope target boxes.
    static let scopeLine = Theme.white(0.075)
    static let scopeMajor = Theme.white(0.12)
    static let scopeSkinTone = Theme.Colors.warning
    static func scopeTarget(_ alpha: CGFloat) -> NSColor { Theme.white(alpha) }
}
