import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQAudioFX
import SQCore
import SQDrawKit
import SQUIKit

/// The Multiband Compressor setup on the shared toolkit: `MultibandEditorPanel` (the Mac floating window) translated into
/// a panel the host draws above the window. Title bar with the clip name and a close button; power, preset, link and
/// output gain; the band strip (draggable crossovers, live band input level and gain reduction from
/// `MultibandMeterTap`); crossover fields; per band Solo / Bypass, five parameter rows and the live reduction; the output
/// limiter. Every control maps to the effect's parameters through the same model calls as the Mac window, and a drag is
/// one undo step. The live spectrum (`AudioSpectrumTap`, after the compressor or at its input) is drawn behind the bars.
/// Coordinates: points, y down, (0, 0) = the panel's top-left, title bar included.
@MainActor public final class MultibandEditorDraw {
    public let effect: ClipEffect.ID
    let model: EffectControlsModel
    public var theme = DrawTheme()
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// The close button, Esc, or the effect left the clip: the host removes the panel (and calls `stopMeters`).
    public var onClose: (@MainActor () -> Void)?
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    public enum Control: Hashable {
        case close, power, preset, link, limiter, strip, spectrumInput
        case field(String)
        case solo(Int), bypass(Int)
    }

    private var fields: [String: ScrubFieldControl] = [:]
    private(set) var focused: String?
    private(set) var hover: Control?
    private var pressed: Control?
    private var stripDrag: Int?
    private var stripHover: Int?
    private var counter = ClickCounter()
    private(set) var meters = MultibandMeterDisplay()
    private var metering = false
    /// The curve behind the bars (`SpectrumDisplay.levelsDB`); the analyzer is made on the first reading.
    private(set) var spectrum = SpectrumDisplay()
    private var analyzer: SpectrumAnalyzer?
    private var spectrumSamples: [Float] = []
    static let spectrumInputDefaultsKey = "sq.multiband.spectrumAtInput"
    var spectrumAtInput: Bool { UserDefaults.standard.bool(forKey: Self.spectrumInputDefaultsKey) }

    public init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        for key in Self.fieldKeys {
            guard let s = MultibandEditor.spec(key) else { continue }
            var f = ScrubFieldControl(value: s.defaultValue)
            f.range = s.range; f.decimals = s.decimals; f.defaultValue = s.defaultValue
            f.step = max(s.step, (s.range.upperBound - s.range.lowerBound) / 400)
            f.isPlain = true
            fields[key] = f
        }
        layoutFrames()
        sync()
    }

    // MARK: Metrics (MultibandEditorPanel.layout)

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): capsule 22, Row.property + 2 = 28,
    // Spacing.sm 6 / md 10 / xs 4. Upgrade when SQUIKit's tokens move into a portable file.
    static let width: CGFloat = 560
    static let titleHeight: CGFloat = 32
    static let pad: CGFloat = 16
    static let captionW: CGFloat = 96
    static let cell: CGFloat = 4
    static let fh: CGFloat = 22
    static let row: CGFloat = ControlsGrid.rowHeight + 2
    static let ch: CGFloat = 14
    static let stripHeight: CGFloat = 96
    static let presetWidth: CGFloat = 150

    static let fieldKeys: [String] = [ClipEffect.mbOutputGainKey] + (1...3).map(ClipEffect.mbCrossoverKey)
        + MultibandEditor.bandRows.flatMap { r in (1...MultibandEditor.bandCount).map { r.key($0) } }
        + MultibandEditor.limiterRows.map(\.key)

    private(set) var frames: [Control: CGRect] = [:]
    private var captions: [(String, CGRect, Bool)] = []          // text, frame, right-aligned
    private var headingFrames: [CGRect] = []
    private var bandHeaderFrames: [CGRect] = []
    private var rangeFrames: [CGRect] = []
    private var reductionFrames: [CGRect] = []
    private var limiterReductionFrame: CGRect = .zero
    private var separators: [CGFloat] = []
    public private(set) var size = CGSize(width: width, height: 560)

    private func layoutFrames() {
        let w = Self.width, pad = Self.pad, fh = Self.fh, row = Self.row, ch = Self.ch
        let dw = w - 2 * pad, colX = pad + Self.captionW
        let colW = (dw - Self.captionW) / CGFloat(MultibandEditor.bandCount), fieldW = colW - Self.cell
        func midY(_ y: CGFloat, _ h: CGFloat, _ item: CGFloat) -> CGFloat { y + ((h - item) / 2).rounded() }
        func col(_ i: Int) -> CGFloat { colX + CGFloat(i) * colW }
        var f: [Control: CGRect] = [:], caps: [(String, CGRect, Bool)] = []
        f[.close] = CGRect(x: w - 8 - 20, y: (Self.titleHeight - 20) / 2, width: 20, height: 20)

        // Top bar: power, preset, link, output gain.
        var y = Self.titleHeight + 12
        f[.power] = CGRect(x: pad, y: y, width: fh, height: fh)
        f[.preset] = CGRect(x: pad + fh + 6, y: y, width: Self.presetWidth, height: fh)
        let linkX = pad + fh + 6 + Self.presetWidth + 10
        f[.link] = CGRect(x: linkX, y: y, width: 150, height: fh)
        f[.field(ClipEffect.mbOutputGainKey)] = CGRect(x: w - pad - fieldW, y: y, width: fieldW, height: fh)
        caps.append(("Output Gain (dB)", CGRect(x: linkX + 150 + 6, y: y, width: max(w - pad - fieldW - 6 - linkX - 156, 0), height: fh), true))
        y += fh + 12; separators = [y]; y += 1

        // Bands: heading, strip, crossover fields.
        y += 10
        headingFrames = [CGRect(x: pad, y: y, width: dw, height: ch)]
        f[.spectrumInput] = CGRect(x: w - pad - 140, y: y - 4, width: 140, height: ch + 8)
        y += ch + 6
        f[.strip] = CGRect(x: pad, y: y, width: dw, height: Self.stripHeight); y += Self.stripHeight + 8
        caps.append(("Crossover (Hz)", CGRect(x: pad, y: y, width: Self.captionW - 4, height: fh), false))
        for i in 1...3 { f[.field(ClipEffect.mbCrossoverKey(i))] = CGRect(x: col(i - 1), y: y, width: fieldW, height: fh) }
        y += fh + 12; separators.append(y); y += 1

        // Band settings: colored headers with their range, Solo / Bypass, the five rows, live reduction.
        y += 10
        headingFrames.append(CGRect(x: pad, y: y, width: dw, height: ch)); y += ch + 6
        bandHeaderFrames = (0..<4).map { CGRect(x: col($0), y: y, width: fieldW, height: ch) }
        rangeFrames = (0..<4).map { CGRect(x: col($0), y: y + ch, width: fieldW, height: ch) }
        y += 2 * ch + 4
        caps.append(("Solo / Bypass", CGRect(x: pad, y: y, width: Self.captionW - 4, height: row), false))
        let bw = (fieldW - 4) / 2
        for n in 0..<4 {
            f[.solo(n)] = CGRect(x: col(n), y: midY(y, row, fh), width: bw, height: fh)
            f[.bypass(n)] = CGRect(x: col(n) + bw + 4, y: midY(y, row, fh), width: bw, height: fh)
        }
        y += row
        for r in MultibandEditor.bandRows {
            caps.append((r.title, CGRect(x: pad, y: y, width: Self.captionW - 4, height: row), false))
            for n in 0..<4 { f[.field(r.key(n + 1))] = CGRect(x: col(n), y: midY(y, row, fh), width: fieldW, height: fh) }
            y += row
        }
        caps.append(("Reduction dB", CGRect(x: pad, y: y, width: Self.captionW - 4, height: row), false))
        reductionFrames = (0..<4).map { CGRect(x: col($0), y: y, width: fieldW, height: row) }
        y += row + 6; separators.append(y); y += 1

        // Output limiter: the switch with its title, live reduction at the right, four fields under captions.
        y += 10
        f[.limiter] = CGRect(x: pad, y: y, width: 200, height: fh)
        limiterReductionFrame = CGRect(x: pad + 206, y: y, width: max(w - pad - pad - 206, 0), height: fh)
        y += fh + 6
        for (i, r) in MultibandEditor.limiterRows.enumerated() {
            caps.append((r.title, CGRect(x: col(i), y: y, width: fieldW, height: ch), false))
        }
        y += ch + 4
        for (i, r) in MultibandEditor.limiterRows.enumerated() { f[.field(r.key)] = CGRect(x: col(i), y: y, width: fieldW, height: fh) }
        y += fh + 16
        frames = f
        captions = caps
        size = CGSize(width: w, height: y)
    }

    /// Where the panel opens: under (or above) the button, inside the visible area.
    public func frame(anchor: CGRect, in visible: CGRect) -> CGRect {
        let area = visible.insetBy(dx: 6, dy: 6)
        var y = anchor.maxY + 4
        if y + size.height > area.maxY { y = max(area.minY, area.maxY - size.height) }
        let x = min(max(anchor.minX, area.minX), max(area.minX, area.maxX - size.width))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    public func control(at p: CGPoint) -> Control? {
        frames.first { $0.value.contains(p) }?.key
    }

    // MARK: Model

    private var snapshot: [String: Double] = [:]
    private func on(_ k: String) -> Bool { (snapshot[k] ?? 0) >= 0.5 }
    var crossovers: [Double] { (1...3).map { snapshot[ClipEffect.mbCrossoverKey($0)] ?? 0 } }
    private var isEnabled: Bool { model.isEffectEnabled(.effect(effect, kind: ClipEffect.audioMultibandKind)) }

    /// Reads the effect at the playhead into the fields (a field being typed in or dragged keeps its value). False when
    /// the clip no longer has the effect: the host closes the panel.
    @discardableResult
    public func sync() -> Bool {
        guard model.multibandClipName(effect) != nil else { return false }
        snapshot = model.multibandSnapshot(effect)
        for key in Self.fieldKeys {
            guard var f = fields[key] else { continue }
            let p = model.multibandProperty(effect, key)
            if !f.isDragging, !f.isEditing { f.value = snapshot[key] ?? f.value }
            f.isMixed = model.isMixed(p)
            f.isEnabled = !MultibandEditor.limiterRows.contains { $0.key == key } || on(ClipEffect.mbLimiterOnKey)
            fields[key] = f
        }
        return true
    }

    public var clipName: String { model.multibandClipName(effect) ?? "" }

    private func set(_ key: String, _ v: Double) {
        if key.hasPrefix("x"), let i = Int(key.dropFirst()) { model.setCrossover(effect, index: i - 1, hz: v) }
        else if let r = MultibandEditor.bandRows.first(where: { r in (1...4).contains { r.key($0) == key } }),
                let n = (1...4).first(where: { r.key($0) == key }) {
            model.setMultibandBandValue(effect, key: r.key, band: n - 1, to: v)
        } else { model.setValue(model.multibandProperty(effect, key), to: v) }
    }

    private func apply(_ events: [ScrubFieldControl.Event], _ key: String) {
        for e in events {
            switch e {
            case .begin: model.beginGesture()
            case .live(let v), .change(let v): set(key, v)
            case .end(let v): set(key, v); model.endGesture()
            case .cancel: model.cancelGesture()
            }
        }
        sync()
    }

    // MARK: Meters (the engine's MultibandMeterTap, read every frame while the panel is open)

    public func startMeters() {
        MultibandMeterTap.shared.watch(effect)
        AudioSpectrumTap.shared.watch(effect, atInput: spectrumAtInput)
        meters = MultibandMeterDisplay()
        spectrum = SpectrumDisplay()
        metering = true
    }

    public func stopMeters() {
        guard metering else { return }
        metering = false
        MultibandMeterTap.shared.watch(nil)
        AudioSpectrumTap.shared.watch(nil)
        meters = MultibandMeterDisplay()
        spectrum = SpectrumDisplay()
    }

    /// Per frame: meters, idle arrow / wheel bursts. True when something to draw changed.
    public func tick() -> Bool {
        let now = clock()
        for key in Array(fields.keys) {
            guard var f = fields[key] else { continue }
            let ev = f.tick(now: now)
            fields[key] = f
            if !ev.isEmpty { apply(ev, key) }
        }
        guard metering else { return false }
        let before = meters, beforeSpectrum = spectrum
        meters.update(MultibandMeterTap.shared.reading(for: effect), at: now)
        let seq = AudioSpectrumTap.shared.snapshot(for: effect, into: &spectrumSamples)
        feedSpectrum(sequence: seq, at: now) { [self] in
            let a = analyzer ?? SpectrumAnalyzer()
            analyzer = a
            return a.magnitudesDB(spectrumSamples, sampleRate: Double(ClipAudioFXChain.sampleRate), points: SpectrumDisplay.points)
        }
        return meters != before || spectrum != beforeSpectrum
    }

    /// One spectrum reading (`sequence` nil = not watched); the host goes through `tick`, tests call it directly.
    func feedSpectrum(sequence: UInt64?, at time: Double, _ levels: () -> [Float]) {
        spectrum.update(sequence: sequence, at: time, spectrum: levels)
    }

    /// Spectrum at Input: the curve shows what goes into the compressor instead of what comes out (kept in the defaults).
    private func toggleSpectrumInput() {
        let on = !spectrumAtInput
        UserDefaults.standard.set(on, forKey: Self.spectrumInputDefaultsKey)
        spectrum = SpectrumDisplay()
        if metering { AudioSpectrumTap.shared.watch(effect, atInput: on) }
    }

    /// Feeds one reading (tests; the host goes through `tick`).
    func feed(_ r: MultibandMeterReading?, at time: Double) { meters.update(r, at: time) }

    // MARK: Drawing

    static func bandColors(_ t: DrawTheme) -> [DrawColor] {
        func c(_ p: PaletteColor) -> DrawColor { DrawColor(Float(p.r) / 255, Float(p.g) / 255, Float(p.b) / 255, Float(p.a)) }
        // Theme.Colors accent, warning, green, clipTitle (the Mac band colors).
        return [t.accent, c(t.palette.warning), t.green, DrawColor(hex: LabelColor.textDefault.rgb)]
    }

    public func draw(_ c: inout Canvas) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body), cs = CGFloat(DrawTheme.TypeSize.caption)
        let bounds = CGRect(origin: .zero, size: size), radius = SQMenuLayout.cornerRadius
        c.shadow(roundedRect: bounds, radius: radius, blur: 14, dy: 6, DrawColor(0, 0, 0, 0.3))
        c.fill(roundedRect: bounds, radius: radius, t.panel)
        // Title bar: title and clip name, close button.
        c.draw(SQL10n.string("Multiband Compressor"), in: CGRect(x: Self.pad, y: 0, width: 200, height: Self.titleHeight),
               fontSize: fs, t.label)
        let titleW = c.size(of: SQL10n.string("Multiband Compressor"), fontSize: fs).width
        c.draw(clipName, in: CGRect(x: Self.pad + titleW + 8, y: 0, width: max(Self.width - Self.pad - titleW - 8 - 40, 0),
                                    height: Self.titleHeight), fontSize: fs, t.label3)
        if let f = frames[.close] {
            if hover == .close { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
            c.draw(icon: .close, at: CGPoint(x: f.midX - 6, y: f.midY - 6), size: 12, t.label2)
        }
        c.fill(CGRect(x: 0, y: Self.titleHeight - 1, width: Self.width, height: 1), t.divider)
        for y in separators { c.fill(CGRect(x: 0, y: y, width: Self.width, height: 1), t.divider) }

        // Top bar.
        if let f = frames[.power] {
            if hover == .power { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
            c.draw(icon: .power, at: CGPoint(x: f.midX - 6, y: f.midY - 6), size: 12, isEnabled ? t.accent : t.label2)
        }
        let match = MultibandEditor.matchingPreset(snapshot)
        if let f = frames[.preset] {
            InspectorDraw.popup(&c, title: SQL10n.string(match.map { MultibandEditor.presets[$0].name } ?? "Custom"), in: f,
                                hovering: hover == .preset, open: false, enabled: true, t)
        }
        checkbox(&c, .link, "Link Band Controls", on: on(ClipEffect.mbLinkKey))
        checkbox(&c, .spectrumInput, "Spectrum at Input", on: spectrumAtInput, fontSize: CGFloat(DrawTheme.TypeSize.caption))
        for (text, f, right) in captions {
            c.draw(SQL10n.string(text), in: f, fontSize: cs, t.label3, align: right ? .right : .left)
        }
        for (i, h) in ["Bands", "Band Settings"].enumerated() where i < headingFrames.count {
            c.draw(SQL10n.string(h), in: headingFrames[i], fontSize: cs, t.label2)
        }

        // Band strip.
        if let f = frames[.strip] { drawStrip(&c, f) }

        // Band columns.
        let colors = Self.bandColors(t), xs = crossovers
        for n in 0..<4 {
            c.draw(SQL10n.format("Band %@", String(n + 1)), in: bandHeaderFrames[n], fontSize: cs, colors[n])
            c.draw(MultibandEditor.rangeText(band: n, crossovers: xs), in: rangeFrames[n], fontSize: cs, t.label3)
            toggle(&c, .solo(n), "S", on: on(ClipEffect.mbSoloKey(n + 1)), tint: colors[1])
            toggle(&c, .bypass(n), "B", on: on(ClipEffect.mbBypassKey(n + 1)), tint: t.accent)
            let live = meters.isLive
            c.draw(live ? String(format: "%.1f", meters.gainReductionDB[n]) : "–", in: reductionFrames[n], fontSize: cs, t.label2)
        }

        // Limiter.
        checkbox(&c, .limiter, "Output Limiter (Brickwall)", on: on(ClipEffect.mbLimiterOnKey))
        let lr = meters.isLive ? SQL10n.format("Reduction %@ dB", String(format: "%.1f", meters.limiterReductionDB))
                               : SQL10n.string("Reduction –")
        c.draw(lr, in: limiterReductionFrame, fontSize: cs, t.label2, align: .right)

        // Fields.
        for key in Self.fieldKeys {
            guard var fd = fields[key], let f = frames[.field(key)] else { continue }
            fd.hovering = hover == .field(key)
            fd.draw(&c, in: f, theme: t, focused: focused == key)
        }
        c.stroke(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), radius: radius, width: 0.5, t.inkFill(0.14))
    }

    private func checkbox(_ c: inout Canvas, _ k: Control, _ title: String, on: Bool,
                          fontSize: CGFloat = CGFloat(DrawTheme.TypeSize.body)) {
        guard let f = frames[k] else { return }
        let box = CGRect(x: f.minX, y: f.midY - 7, width: 14, height: 14)
        InspectorDraw.checkbox(&c, on ? .on : .off, box: box, hovering: hover == k, pressed: pressed == k, enabled: true, theme)
        c.draw(SQL10n.string(title), in: CGRect(x: box.maxX + 6, y: f.minY, width: f.width - 20, height: f.height),
               fontSize: fontSize, theme.label)
    }

    private func toggle(_ c: inout Canvas, _ k: Control, _ title: String, on: Bool, tint: DrawColor) {
        guard let f = frames[k] else { return }
        let t = theme
        c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small),
               on || pressed == k ? t.fillPressed : (hover == k ? t.fillHover : t.fill))
        c.draw(title, in: f, fontSize: CGFloat(DrawTheme.TypeSize.body), on ? tint : t.label2, align: .center)
    }

    /// CompressorBandsView.draw: field body, alternate band shading, band input level from the bottom in the band color,
    /// gain-reduction bars from the top, crossover lines with their frequency under the strip.
    private func drawStrip(_ c: inout Canvas, _ f: CGRect) {
        let t = theme, label: CGFloat = 14
        let g = CompressorBandsGeometry(width: f.width), xs = crossovers
        let plot = CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height - label)
        let r = CGFloat(DrawTheme.Radius.control)
        c.fill(roundedRect: plot, radius: r, t.field)
        c.saveGState()
        c.clip(to: plot)
        let ranges = g.bandRanges(crossoversHz: xs), colors = Self.bandColors(t)
        let anySolo = (1...4).contains { on(ClipEffect.mbSoloKey($0)) }
        for (i, b) in ranges.enumerated() where i % 2 == 1 {
            c.fill(CGRect(x: plot.minX + b.lowerBound, y: plot.minY, width: b.upperBound - b.lowerBound, height: plot.height), t.inkFill(0.025))
        }
        drawSpectrum(&c, plot)
        for (i, b) in ranges.enumerated() {
            let dimmed = !isEnabled || on(ClipEffect.mbBypassKey(i + 1)) || (anySolo && !on(ClipEffect.mbSoloKey(i + 1)))
            let a: Float = dimmed ? 0.3 : 1
            let level = CGFloat(min(max(MeterBallistics.position(dB: meters.inputDB[i]), 0), 1))
            let h = plot.height * level, bw = min(max((b.upperBound - b.lowerBound) * 0.3, 4), 14)
            if h > 0 {
                c.fill(CGRect(x: plot.minX + (b.lowerBound + b.upperBound) / 2 - bw / 2, y: plot.maxY - h, width: bw, height: h),
                       colors[i].alpha(0.55 * a))
            }
            let barH = plot.height * CGFloat(CompressorBandsGeometry.barFraction(gainReductionDB: Double(meters.gainReductionDB[i])))
            c.fill(CGRect(x: plot.minX + b.lowerBound + 1, y: plot.minY, width: max(0, b.upperBound - b.lowerBound - 2), height: barH),
                   t.accentTint.alpha(t.accentTint.a * a))
        }
        c.restoreGState()
        c.stroke(roundedRect: plot.insetBy(dx: 0.5, dy: 0.5), radius: r - 0.5, width: 1, t.fieldEdge)
        let cs = CGFloat(DrawTheme.TypeSize.caption)
        for (i, hz) in xs.enumerated() {
            let x = plot.minX + g.x(forHz: hz).rounded()
            let active = stripDrag == i || stripHover == i
            c.fill(CGRect(x: x, y: plot.minY, width: active ? 2 : 1, height: plot.height), active ? t.accent : t.label2)
            let text = CompressorBandsGeometry.hzText(hz)
            let w = c.size(of: text, fontSize: cs).width
            let tx = min(max(x - w / 2, f.minX), f.maxX - w)
            c.draw(text, at: CGPoint(x: tx, y: plot.maxY + 2), fontSize: cs, active ? t.label : t.label3)
        }
    }

    /// The spectrum as a filled curve from the bottom plus its outline, neutral so the band colors stay readable on top
    /// (CompressorBandsView.drawSpectrum). Filled per segment: each trapezoid is convex, the whole curve is not.
    private func drawSpectrum(_ c: inout Canvas, _ plot: CGRect) {
        let levels = spectrum.levelsDB, n = levels.count
        guard n > 1, plot.width > 0 else { return }
        let step = plot.width / CGFloat(n - 1)
        var points: [CGPoint] = []
        points.reserveCapacity(n)
        for (i, db) in levels.enumerated() {
            let y = plot.height * (1 - CGFloat(SpectrumDisplay.fraction(dB: db)))
            points.append(CGPoint(x: plot.minX + step * CGFloat(i), y: plot.minY + y))
        }
        let fill = theme.label3.alpha(0.16)
        for i in 0..<(n - 1) {
            let a = points[i], b = points[i + 1]
            c.fill(polygon: [a, b, CGPoint(x: b.x, y: plot.maxY), CGPoint(x: a.x, y: plot.maxY)], fill)
        }
        c.strokePolyline(points, width: 1, theme.label3.alpha(0.5))
    }

    // MARK: Pointer and keys

    public func mouseMoved(to p: CGPoint?) {
        guard pressed == nil, stripDrag == nil else { return }
        hover = p.flatMap(control)
        if let p, let f = frames[.strip], hover == .strip {
            stripHover = CompressorBandsGeometry(width: f.width).handleIndex(at: p.x - f.minX, crossoversHz: crossovers)
        } else { stripHover = nil }
    }

    public func mouseDown(at p: CGPoint, clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let k = control(at: p)
        if let key = focused, k != .field(key) { resignFocus() }
        pressed = k
        switch k {
        case .field(let key)?:
            guard var f = fields[key] else { return }
            focused = key
            if n == 2, !f.isEditing {
                // Double-click: back to the default, keys included (the Mac field's onReset → resetAll).
                pressed = nil
                model.resetAll(model.multibandProperty(effect, key))
                sync()
                return
            }
            let ev = f.mouseDown(x: Float(p.x), clickCount: n)
            fields[key] = f
            apply(ev, key)
        case .strip?:
            guard let f = frames[.strip],
                  let i = CompressorBandsGeometry(width: f.width).handleIndex(at: p.x - f.minX, crossoversHz: crossovers) else {
                pressed = nil; return
            }
            stripDrag = i
            model.beginGesture()
        case .preset?:
            pressed = nil
            let match = MultibandEditor.matchingPreset(snapshot)
            var items = MultibandEditor.presets.enumerated().map { i, pr in
                SQMenuItem(title: SQL10n.string(pr.name), isChecked: i == match) { [weak self] in
                    guard let self else { return }
                    model.applyMultibandPreset(effect, index: i)
                    sync()
                }
            }
            items.append(SQMenuItem(title: SQL10n.string("Custom"), isEnabled: false, isChecked: match == nil) {})
            if let f = frames[.preset] { onMenu?(items, f) }
        default: break
        }
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        if let i = stripDrag, let f = frames[.strip] {
            let hz = CompressorBandsGeometry(width: f.width).draggedHz(index: i, toX: p.x - f.minX, crossoversHz: crossovers)
            model.setCrossover(effect, index: i, hz: hz)
            sync()
            return
        }
        guard case .field(let key)? = pressed, var f = fields[key] else { return }
        let ev = f.mouseDragged(x: Float(p.x), modifiers: modifiers)
        fields[key] = f
        apply(ev, key)
    }

    public func mouseUp(at p: CGPoint) {
        let k = pressed
        pressed = nil
        defer { mouseMoved(to: p) }
        if stripDrag != nil { stripDrag = nil; model.endGesture(); sync(); return }
        if case .field(let key)? = k, var f = fields[key] {
            let ev = f.mouseUp()
            fields[key] = f
            apply(ev, key)
            return
        }
        guard let k, control(at: p) == k else { return }
        switch k {
        case .close: onClose?()
        case .power: model.toggleEffectEnabled(.effect(effect, kind: ClipEffect.audioMultibandKind))
        case .link: model.setMultibandLink(effect, !on(ClipEffect.mbLinkKey))
        case .spectrumInput: toggleSpectrumInput()
        case .limiter: model.setValue(model.multibandProperty(effect, ClipEffect.mbLimiterOnKey), to: on(ClipEffect.mbLimiterOnKey) ? 0 : 1)
        case .solo(let n): model.toggleMultibandSolo(effect, band: n)
        case .bypass(let n): model.toggleMultibandBypass(effect, band: n)
        default: break
        }
        sync()
    }

    /// The wheel over a field steps it (with the field's own rules).
    public func scroll(at p: CGPoint, dy: CGFloat, precise: Bool, modifiers: InputModifiers) -> Bool {
        guard case .field(let key)? = control(at: p), var f = fields[key] else { return false }
        f.hovering = true
        let r = f.scroll(delta: Double(dy), precise: precise, modifiers: modifiers, focused: focused == key, now: clock())
        fields[key] = f
        apply(r.events, key)
        return r.used
    }

    /// Keys for the focused field; Esc with nothing to cancel closes the panel. False = not taken (Space plays).
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        if let key = focused, var f = fields[key] {
            if k == .character("\t") {
                let order = Self.fieldKeys, i = order.firstIndex(of: key) ?? 0
                resignFocus()
                let next = order[(i + (modifiers.contains(.shift) ? order.count - 1 : 1)) % order.count]
                focused = next
                if var nf = fields[next] { nf.beginEditing(); fields[next] = nf }
                return true
            }
            let wasActive = f.isEditing || f.isDragging
            let ev = f.key(k, modifiers: modifiers, now: clock())
            fields[key] = f
            apply(ev, key)
            if k == .escape, !wasActive, ev.isEmpty { focused = nil; onClose?() }
            return k != .space || f.isEditing
        }
        if k == .escape { onClose?(); return true }
        return false
    }

    public func resignFocus() {
        guard let key = focused else { return }
        focused = nil
        guard var f = fields[key] else { return }
        let ev = f.resignFocus()
        fields[key] = f
        apply(ev, key)
    }

    public func help(at p: CGPoint) -> String? {
        switch control(at: p) {
        case .power: SQL10n.string("Multiband Compressor On / Off")
        case .link: SQL10n.string("Dragging one band moves all four by the same amount")
        case .spectrumInput: SQL10n.string("Show the spectrum going into the compressor instead of coming out")
        case .limiter: SQL10n.string("Output limiter: raises by margin minus threshold and holds the peaks at the margin")
        case .solo(let n): SQL10n.format("Solo Band %@", String(n + 1))
        case .bypass(let n): SQL10n.format("Bypass Band %@", String(n + 1))
        case .field(let key): MultibandEditor.spec(key)?.title
        case .close: SQL10n.string("Close")
        default: nil
        }
    }
}
