import Foundation
import SQDrawKit
import SQGPUKernels
import SQUIKit

/// The Scopes panel on the canvas (the Mac `ScopesView` stacked arrangement of the Edit page translated): one scope
/// under its popup, a second below when the card is tall enough (waveform, then vectorscope), each a dark box with the
/// scope picture (an image slot) and the graticule over it. The counts come from the shown NV12 frame
/// (`ScopeBinning.compute`, the CPU form of the Metal accumulation), binned off the main thread, or straight from the
/// GPU when the platform measures the composite there (`ScopeCountsSource`, `update(counts:generation:)`).
@MainActor
public final class ScopesPanel {
    public var theme = DrawTheme()
    public private(set) var kinds: [ScopeKind] = [.waveform, .vectorscope]
    /// The card in points.
    public private(set) var frame: CGRect = .zero
    /// Per shown scope: popup rect and box rect (points).
    public private(set) var slots: [(popup: CGRect, box: CGRect)] = []
    /// The scope pictures for the boxes (index = shown scope) and a counter that changes with them.
    public private(set) var images: [RGBAImage?] = [nil, nil]
    public private(set) var imageGeneration = 0
    /// No picture to measure: the first box says so.
    public var emptyText: (title: String, hint: String)?
    /// "On screen: X" from the Color page (the scopes measure X, not the graded clip); nil hides the line. The Mac
    /// `ScopesPanelView.hint`: a warning-colored caption line above the scopes that pushes them down.
    public var hint: String?
    /// The hint line's frame (points; nil = no line).
    public private(set) var hintFrame: CGRect?
    /// Caption text (10 pt) line height: the Mac label's intrinsic height.
    static let hintLineHeight: CGFloat = 13
    public var onMenu: ((_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    private var scale: Float = 1
    private var counts: ScopeCounts?
    private var pending: Task<Void, Never>?
    private var measuredGeneration = -1
    /// The Mac `SQPopup` intrinsic height.
    static let popupHeight: CGFloat = 22
    /// Sample every Nth pixel in x and y (the Mac `ScopesView.pixelStride` knob).
    public var pixelStride = 2
    /// The waveform settings (trace intensity of the Waveform and RGB Parade), shared with every scopes view.
    public var settings = ScopeTraceSettings.shared
    /// The settings button's side (points), at the right end of a Waveform / Parade popup row.
    static let settingsButtonSize: CGFloat = 16

    public init() {}

    /// ScopesView.layout (stacked).
    public func layout(_ r: DrawRect, scale: Float) {
        self.scale = max(scale, 0.01)
        let k = CGFloat(self.scale)
        frame = CGRect(x: CGFloat(r.x) / k, y: CGFloat(r.y) / k, width: CGFloat(r.w) / k, height: CGFloat(r.h) / k)
        let L = ScopeBoxLayout.self
        // ScopesPanelView.layout: the hint line at (md, xs), the scopes below it with their own insets.
        let xs = CGFloat(DrawTheme.Spacing.xs), md = CGFloat(DrawTheme.Spacing.md)
        let lead: CGFloat = hint == nil ? 0 : Self.hintLineHeight + xs
        hintFrame = hint == nil ? nil : CGRect(x: frame.minX + md, y: frame.minY + xs, width: max(frame.width - 2 * md, 0),
                                               height: Self.hintLineHeight)
        let body = CGRect(x: frame.minX, y: frame.minY + lead, width: frame.width, height: max(frame.height - lead, 0))
        let x = body.minX + L.side, w = max(body.width - 2 * L.side, 0)
        let h = max(body.height - 2 * L.top, 0)
        func slot(_ y: CGFloat, _ height: CGFloat) -> (CGRect, CGRect) {
            let popup = CGRect(x: x, y: y, width: w, height: Self.popupHeight)
            return (popup, CGRect(x: x, y: popup.maxY + L.gap, width: w, height: max(height - Self.popupHeight - L.gap, 0)))
        }
        let top = body.minY + L.top
        if emptyText == nil, L.showsTwo(height: body.height, popup: Self.popupHeight) {
            let first = Self.popupHeight + L.gap + L.firstBox
            let y = top + first + L.gap
            slots = [slot(top, first), slot(y, max(top + h - y, 0))]
        } else {
            slots = [slot(top, emptyText == nil ? h : min(h, Self.popupHeight + L.gap + L.firstBox))]
        }
        // The host lays out on every window frame: redraw the pictures only when what they show changed.
        if imageKey != requestedKey { renderImages() }
    }

    /// What the scope pictures depend on besides the counts: plot pixel sizes, kinds and trace gains.
    private struct ImageKey: Equatable { var sizes: [Int]; var kinds: [ScopeKind]; var gains: [Float] }
    /// The key of the newest render asked for (layout asks again only when it changes) and of the one shown.
    private var requestedKey: ImageKey?
    private var renderedKey: ImageKey?
    private var renderTask: Task<Void, Never>?
    private var renderDirty = false
    private var renderEpoch = 0
    private var imageKey: ImageKey {
        var sizes: [Int] = []
        for (i, s) in slots.enumerated() {
            let p = ScopeBoxLayout.plot(kinds[i], in: s.box.size)
            sizes += [Int((p.width * CGFloat(scale)).rounded()), Int((p.height * CGFloat(scale)).rounded())]
        }
        return ImageKey(sizes: sizes, kinds: kinds, gains: kinds.map { settings.intensity(for: $0) })
    }

    /// The hint line's text (`ScopesPanelView.hint`): "Measuring X, not the graded clip".
    public static func hintText(_ hint: String) -> String {
        let what = hint.hasPrefix("On screen: ") ? String(hint.dropFirst("On screen: ".count)) : hint
        return "Measuring \(what), not the graded clip"
    }

    /// A new shown frame (8-bit NV12, or RGBA with `rgba`): bins it off the main thread when `generation` changed, then
    /// redraws the pictures.
    public func update(nv12 bytes: [UInt8], width: Int, height: Int, fullRange: Bool, rgba: Bool = false, generation: Int) {
        guard generation != measuredGeneration, pending == nil else { return }
        measuredGeneration = generation
        let stride = pixelStride
        pending = Task { [weak self] in
            let c = await Task.detached(priority: .utility) {
                rgba ? ScopeBinning.compute(rgba: bytes, width: width, height: height, layout: ScopeLayout(), pixelStride: stride)
                     : ScopeBinning.compute(nv12: bytes, width: width, height: height, fullRange: fullRange,
                                            layout: ScopeLayout(), pixelStride: stride)
            }.value
            guard let self else { return }
            pending = nil
            counts = c
            renderImages()
        }
    }

    /// Counts measured elsewhere (the GPU scope passes on the shown composite): redraws the pictures when `generation`
    /// changed.
    public func update(counts c: ScopeCounts, generation: Int) {
        guard generation != measuredGeneration else { return }
        measuredGeneration = generation
        counts = c
        renderImages()
    }

    /// GPU counts from `source` (once per generation); false when it has none (the host bins the readback instead).
    public func measure(from source: any ScopeCountsSource, generation: Int) -> Bool {
        if generation == measuredGeneration { return true }
        guard let c = source.scopeCounts(pixelStride: pixelStride) else { return false }
        update(counts: c, generation: generation)
        return true
    }

    /// Clears the scopes (no picture).
    public func clear() {
        counts = nil; measuredGeneration = -1
        images = [nil, nil]; imageGeneration += 1
        renderEpoch += 1; renderDirty = false; requestedKey = nil
    }

    /// The scope pictures at the plots' pixel sizes. Drawn off the main thread (160-250 ms stalls on the Color page when
    /// done inline) and coalesced: asks that arrive while a render runs make one more render with the newest state.
    /// The old pictures stay until the new ones are ready.
    private func renderImages() {
        guard counts != nil else { return }
        requestedKey = imageKey
        renderDirty = true
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while let self, renderDirty {
                renderDirty = false
                guard let counts else { break }
                let epoch = renderEpoch, key = imageKey
                var jobs: [(kind: ScopeKind, w: Int, h: Int, gain: Float)?] = []
                for (i, s) in slots.enumerated() {
                    let p = ScopeBoxLayout.plot(kinds[i], in: s.box.size)
                    let w = Int((p.width * CGFloat(scale)).rounded()), h = Int((p.height * CGFloat(scale)).rounded())
                    jobs.append(w > 1 && h > 1 ? (kinds[i], w, h, settings.intensity(for: kinds[i])) : nil)
                }
                let list = jobs
                let out: [RGBAImage?] = await Task.detached(priority: .userInitiated) {
                    var out: [RGBAImage?] = [nil, nil]
                    for (i, j) in list.enumerated() {
                        guard let j else { continue }
                        var img = ScopeImage.render(j.kind, counts, width: j.w, height: j.h, intensity: j.gain)
                        if j.kind == .vectorscope { Self.cutToCircle(&img) }
                        out[i] = img
                    }
                    return out
                }.value
                guard epoch == renderEpoch else { continue }
                images = out
                imageGeneration += 1
                renderedKey = key
            }
            self?.renderTask = nil
        }
    }

    /// Waits until no render is running or queued (tests).
    public func settle() async {
        while let t = renderTask { await t.value }
    }

    /// `slotBase`: the first of the two image slots the host uploads `images` to.
    public func draw(_ c: inout Canvas, slotBase: Int) {
        guard frame.width > 0, frame.height > 0 else { return }
        let t = theme
        c.fill(roundedRect: frame, radius: CGFloat(DrawTheme.Radius.panel), t.panel)
        if let hint, let r = hintFrame {
            c.draw(Self.hintText(hint), in: r, fontSize: CGFloat(DrawTheme.TypeSize.caption), MonitorPanel.color(t.palette.warning),
                   inset: 0)
        }
        for (i, s) in slots.enumerated() {
            let kind = kinds[i]
            // ScopeSlotView.apply: only a shown vectorscope is a bare disc with the legend; an empty slot is a box.
            let circle = kind == .vectorscope && !(i == 0 && emptyText != nil)
            // `SQPopup` at its intrinsic width (10 inset, the title, 8 gap, 7 chevron, 7 inset), 22 high at the top of the slot:
            // the AppKit render shows the filled button, not bare text.
            let title = ScopeBoxLayout.title(kind)
            // Every popup takes the width of the widest scope title (the Mac stack aligns them on one width).
            let pw = ceil(ScopeKind.allCases.map { c.size(of: ScopeBoxLayout.title($0), fontSize: 11).width }.max() ?? 0) + 32
            InspectorDraw.popup(&c, title: title, in: CGRect(x: s.popup.minX, y: s.popup.minY, width: pw, height: 22),
                                hovering: false, open: false, enabled: true, fontSize: 11, t)
            if circle {
                // The skin tone legend right of the popup.
                let lw = c.size(of: "Skin tone", fontSize: 11).width
                c.draw("Skin tone", in: CGRect(x: s.popup.maxX - lw, y: s.popup.minY, width: lw, height: s.popup.height),
                       fontSize: 11, t.label2)
                c.fill(CGRect(x: s.popup.maxX - lw - 6 - 12, y: s.popup.midY.rounded(), width: 12, height: 1), MonitorPanel.color(t.palette.warning))
            } else {
                if let b = settingsButton(i) {
                    if hoverSettings == i { c.fill(roundedRect: b, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
                    c.draw(icon: .slidersHorizontal, at: CGPoint(x: b.midX - 6, y: b.midY - 6), size: 12, hoverSettings == i ? t.label : t.label2)
                }
                // `Theme.Colors.scopeBox` with the hairline edge and the control radius.
                let radius = CGFloat(DrawTheme.Radius.control)
                c.fill(roundedRect: s.box, radius: radius, DrawColor(hex: 0x0A0A0A))
                c.stroke(roundedRect: s.box, radius: radius, width: 1, t.separator)
            }
            if i == 0, let e = emptyText {
                c.draw(e.title, in: CGRect(x: s.box.minX, y: s.box.midY - 18, width: s.box.width, height: 18), fontSize: 13,
                       t.label2, align: .center)
                c.draw(e.hint, in: CGRect(x: s.box.minX, y: s.box.midY + 2, width: s.box.width, height: 16), fontSize: 11,
                       t.label3, align: .center)
                continue
            }
            // The vectorscope's disc and rings go under its trace (cut to the circle), the other graticules over theirs.
            if kind == .vectorscope { ScopeOverlay.draw(&c, kind, box: s.box, theme: t) }
            if images[i] != nil {
                var p = ScopeBoxLayout.plot(kind, in: s.box.size)
                p.origin.x += s.box.minX; p.origin.y += s.box.minY
                c.draw(imageSlot: slotBase + i, in: p)
            }
            if kind != .vectorscope { ScopeOverlay.draw(&c, kind, box: s.box, theme: t) }
        }
    }

    /// The Mac clips the vectorscope layer to its ring (`cornerRadius`); the canvas has no round clip, so the pixels
    /// outside the circle turn transparent.
    nonisolated static func cutToCircle(_ img: inout RGBAImage) {
        let cx = Double(img.width) / 2, cy = Double(img.height) / 2, r2 = cx * cx
        for y in 0..<img.height {
            for x in 0..<img.width {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy > r2 { img.pixels[(y * img.width + x) * 4 + 3] = 0 }
            }
        }
    }


    /// The settings button of scope `i` (points): only a shown Waveform or RGB Parade has one.
    public func settingsButton(_ i: Int) -> CGRect? {
        guard slots.indices.contains(i), ScopeTraceSettings.hasSettings(kinds[i]), !(i == 0 && emptyText != nil) else { return nil }
        let p = slots[i].popup, d = Self.settingsButtonSize
        return CGRect(x: p.maxX - d, y: (p.midY - d / 2).rounded(), width: d, height: d)
    }

    private func settingsIndex(at p: CGPoint) -> Int? { slots.indices.first { settingsButton($0)?.contains(p) == true } }
    private var hoverSettings: Int?

    /// The tip under the pointer (points).
    public func help(at p: CGPoint) -> String? {
        if settingsIndex(at: p) != nil { return SQL10n.string(ScopeTraceSettings.buttonTip) }
        return nil
    }

    /// Which scope's popup is at `p` (points).
    func popupIndex(at p: CGPoint) -> Int? {
        slots.firstIndex { s in s.popup.insetBy(dx: 0, dy: -2).contains(p) }
    }

    /// The scope choices (ScopesView's popup).
    public func menuItems(for i: Int) -> [SQMenuItem] {
        ScopeKind.allCases.map { k in
            SQMenuItem(title: ScopeBoxLayout.title(k), isChecked: kinds[i] == k, action: { [weak self] in self?.select(k, at: i) })
        }
    }

    public func select(_ k: ScopeKind, at i: Int) {
        guard kinds.indices.contains(i), kinds[i] != k else { return }
        kinds[i] = k
        renderImages()
    }

    /// A press in pixels; true when it was on the card.
    public func handle(_ e: InputEvent) -> Bool {
        let k = CGFloat(scale)
        if case .mouseMoved(let x, let y) = e {
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            hoverSettings = frame.contains(p) ? settingsIndex(at: p) : nil
            if hoverSettings != nil { HostHover.current.offerTip(help(at: p)) }
            return false
        }
        guard case .mouseDown(let x, let y, let mods) = e else { return false }
        let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
        guard frame.contains(p) else { return false }
        if let i = settingsIndex(at: p) {
            onMenu?(settings.menuItems(), settingsButton(i) ?? slots[i].popup)
        } else if mods.contains(.secondary), let i = slots.indices.first(where: { slots[$0].box.contains(p) }),
                  settingsButton(i) != nil {
            // A right-click on a Waveform / Parade box: the same settings menu at the pointer.
            onMenu?(settings.menuItems(), CGRect(x: p.x, y: p.y, width: 1, height: 1))
        } else if let i = popupIndex(at: p) {
            onMenu?(menuItems(for: i), slots[i].popup)
        }
        return true
    }
}

/// A picture source that measures the scopes of its shown composite on the GPU (Windows: the shared `ScopePasses` on
/// D3D12): the host asks it before falling back to the CPU binning of the readback.
@MainActor
public protocol ScopeCountsSource: AnyObject {
    /// The counts of the shown picture, every `pixelStride`-th pixel; nil when the picture is not on the GPU.
    func scopeCounts(pixelStride: Int) -> ScopeCounts?
}
