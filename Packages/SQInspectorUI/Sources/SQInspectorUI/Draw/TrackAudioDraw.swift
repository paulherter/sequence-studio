import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQAudioFX
import SQUIKit
import SQDrawKit

/// Track audio controls on the shared toolkit: `TrackAudioInspectorView` translated (role and preset popups, Denoise,
/// the compressor's Bypass and crossover strip, Noise Gate with attack / hold / release, Warmth and its mix). The model
/// is the Mac `TrackAudioInspectorModel`; this draws it and turns pointer and keys into its setters. Coordinates:
/// points, y down, (0, 0) = the block's top-left; the host reads `height` for the slot.
@MainActor public final class TrackAudioDraw {
    public let model: TrackAudioInspectorModel
    public var theme = DrawTheme()
    public var width: CGFloat = 320
    /// Text under the controls (the Mac `note`).
    public var note = ""
    /// A popup opened: the host shows the SQ menu at `anchor` (block coordinates).
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    public init(model: TrackAudioInspectorModel) { self.model = model }

    // MARK: Rows (the Mac stack, top to bottom)

    enum Control: Hashable {
        case role, preset, bypass, gate, warmth, bands
        case slider(Slider)
    }
    enum Slider: Hashable, CaseIterable { case denoise, gate, attack, hold, release, warmth, mix }

    struct Row {
        var label: String?
        var y: CGFloat
        var height: CGFloat
        var controls: [(Control, CGRect)]
    }

    static let bandsHeight = CompressorBandsGeometry.stripHeight
    static let checkSide: CGFloat = 14
    static let fieldWidth: CGFloat = 52
    static let sliderGap = CGFloat(DrawTheme.Spacing.sm)

    var rows: [Row] {
        let rh = ControlsGrid.rowHeight, x0 = ControlsGrid.valueX, x1 = max(width - ControlsGrid.trailing, x0)
        let ch = ControlsGrid.controlHeight
        func box(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat = ch) -> CGRect { CGRect(x: x, y: ((rh - h) / 2).rounded(), width: max(w, 0), height: h) }
        let full = box(x0, x1 - x0)
        let afterCheck = x0 + Self.checkSide + ControlsGrid.gap
        let slid = box(afterCheck, x1 - afterCheck)
        let check = box(x0, Self.checkSide, Self.checkSide)
        var out: [Row] = []
        var y: CGFloat = 0
        func add(_ label: String?, _ c: [(Control, CGRect)], height: CGFloat = rh) { out.append(Row(label: label, y: y, height: height, controls: c)); y += height }
        add("Role", [(.role, full)])
        add("Preset", [(.preset, full)])
        add("Denoise", [(.slider(.denoise), slid)])
        add("Compressor", [(.bypass, box(x0, x1 - x0, Self.checkSide))])
        add(nil, [(.bands, CGRect(x: ControlsGrid.labelX, y: 0, width: max(x1 - ControlsGrid.labelX, 0), height: Self.bandsHeight))],
            height: Self.bandsHeight + ControlsGrid.gap)
        add("Noise Gate", [(.gate, check), (.slider(.gate), slid)])
        add("Attack", [(.slider(.attack), slid)])
        add("Hold", [(.slider(.hold), slid)])
        add("Release", [(.slider(.release), slid)])
        add("Warmth", [(.warmth, check), (.slider(.warmth), slid)])
        add("Mix", [(.slider(.mix), slid)])
        return out
    }

    /// The note row: label column to the trailing inset, gap above and below.
    private var noteHeight: CGFloat { note.isEmpty ? 0 : CGFloat(DrawTheme.TypeSize.body) + 4 + 2 * ControlsGrid.gap }
    public var height: CGFloat { (rows.last.map { $0.y + $0.height } ?? 0) + noteHeight }

    /// Slider parts: the track left, the value field right (NumericSlider.layout).
    func sliderParts(_ r: CGRect) -> (track: CGRect, field: CGRect) {
        let fw = min(Self.fieldWidth, r.width)
        let field = CGRect(x: r.maxX - fw, y: r.minY, width: fw, height: r.height)
        return (CGRect(x: r.minX, y: r.minY, width: max(field.minX - Self.sliderGap - r.minX, 0), height: r.height), field)
    }

    func frame(_ c: Control) -> CGRect? {
        for r in rows { if let f = r.controls.first(where: { $0.0 == c })?.1 { return f.offsetBy(dx: 0, dy: r.y) } }
        return nil
    }

    // MARK: Values

    struct SliderSpec { var range: ClosedRange<Double>; var def: Double; var step: Double; var unit: String; var help: String? }
    func spec(_ s: Slider) -> SliderSpec {
        switch s {
        case .denoise: SliderSpec(range: 0...100, def: 0, step: 1, unit: "%", help: "Noise reduction")
        case .gate: SliderSpec(range: NoiseGateSettings.Limits.thresholdDB, def: -45, step: 1, unit: "dB", help: nil)
        case .attack: SliderSpec(range: NoiseGateSettings.Limits.attackMs, def: 2, step: 0.1, unit: "ms", help: "How fast the gate opens")
        case .hold: SliderSpec(range: NoiseGateSettings.Limits.holdMs, def: 80, step: 1, unit: "ms",
                               help: "How long the gate stays open after the sound drops below the threshold")
        case .release: SliderSpec(range: NoiseGateSettings.Limits.releaseMs, def: 150, step: 1, unit: "ms", help: "How fast the gate closes")
        case .warmth: SliderSpec(range: SaturationSettings.Limits.driveDB, def: 6, step: 1, unit: "dB", help: nil)
        case .mix: SliderSpec(range: 0...100, def: 100, step: 1, unit: "%",
                              help: "Warmth mix: 0 % is the dry sound, 100 % the fully warmed sound")
        }
    }
    func value(_ s: Slider) -> Double {
        switch s {
        case .denoise: model.noiseReductionPercent
        case .gate: model.gate.thresholdDB
        case .attack: model.gate.attackMs
        case .hold: model.gate.holdMs
        case .release: model.gate.releaseMs
        case .warmth: model.saturation.driveDB
        case .mix: (model.saturation.mix * 100).rounded()
        }
    }
    func isEnabled(_ s: Slider) -> Bool {
        switch s {
        case .denoise: true
        case .gate, .attack, .hold, .release: model.gate.enabled
        case .warmth, .mix: model.saturation.enabled
        }
    }
    func set(_ s: Slider, _ v: Double) {
        switch s {
        case .denoise: model.setNoiseReductionPercent(v)
        case .gate: model.setGateThresholdDB(v)
        case .attack: model.setGateAttackMs(v)
        case .hold: model.setGateHoldMs(v)
        case .release: model.setGateReleaseMs(v)
        case .warmth: model.setWarmthDriveDB(v)
        case .mix: model.setWarmthMixPercent(v)
        }
    }

    /// One scrub field per slider; refilled from the model unless it is in a gesture or being typed into.
    private var fields: [Slider: ScrubFieldControl] = [:]
    private(set) var focused: Slider?
    func field(_ s: Slider) -> ScrubFieldControl {
        var f = fields[s] ?? ScrubFieldControl(value: value(s))
        let sp = spec(s)
        f.range = sp.range; f.step = sp.step; f.unit = sp.unit; f.defaultValue = sp.def
        f.decimals = sp.step < 1 ? 1 : 0
        f.isEnabled = isEnabled(s)
        if !f.isDragging, !f.isEditing { f.value = value(s) }
        return f
    }

    private func apply(_ events: [ScrubFieldControl.Event], _ s: Slider) {
        for e in events {
            switch e {
            case .begin: model.beginChange()
            case .live(let v), .change(let v): set(s, v)
            case .end(let v), .cancel(let v): set(s, v); model.endChange()
            }
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.fill(CGRect(x: 0, y: 0, width: width, height: height), t.panel)
        for r in rows {
            if let l = r.label {
                c.draw(SQL10n.string(l), in: CGRect(x: ControlsGrid.labelX, y: r.y, width: ControlsGrid.valueX - ControlsGrid.labelX - ControlsGrid.gap,
                                                    height: r.height), fontSize: fs, t.label2)
            }
            for (k, f0) in r.controls {
                let f = f0.offsetBy(dx: 0, dy: r.y)
                switch k {
                case .role:
                    InspectorDraw.popup(&c, title: SQL10n.string(roleTitle), in: f, hovering: hover == k, open: false, enabled: true, t)
                case .preset:
                    InspectorDraw.popup(&c, title: presetTitle, in: f, hovering: hover == k, open: false, enabled: true, t)
                case .bypass:
                    InspectorDraw.checkbox(&c, model.compressor.bypass ? .on : .off, box: CGRect(x: f.minX, y: f.minY, width: Self.checkSide, height: Self.checkSide),
                                           hovering: hover == k, pressed: pressed == k, enabled: true, t)
                    c.draw(SQL10n.string("Bypass"), in: CGRect(x: f.minX + Self.checkSide + 6, y: f.minY - 4, width: 120, height: Self.checkSide + 8),
                           fontSize: fs, t.label)
                case .gate, .warmth:
                    let on = k == .gate ? model.gate.enabled : model.saturation.enabled
                    InspectorDraw.checkbox(&c, on ? .on : .off, box: f, hovering: hover == k, pressed: pressed == k, enabled: true, t)
                case .bands: drawBands(&c, f)
                case .slider(let s):
                    let p = sliderParts(f), on = isEnabled(s)
                    let sp = spec(s)
                    let frac = (value(s) - sp.range.lowerBound) / max(sp.range.upperBound - sp.range.lowerBound, 1e-9)
                    InspectorDraw.slider(&c, fraction: frac, in: p.track, enabled: on, t)
                    var fd = field(s)
                    fd.hovering = hover == k
                    fd.draw(&c, in: p.field, theme: t, focused: focused == s)
                }
            }
        }
        if !note.isEmpty, let last = rows.last {
            c.draw(SQL10n.string(note), in: CGRect(x: ControlsGrid.labelX, y: last.y + last.height + ControlsGrid.gap,
                                                   width: max(width - ControlsGrid.labelX - ControlsGrid.trailing, 0), height: fs + 4),
                   fontSize: fs, t.label3)
        }
    }

    var roleTitle: String {
        let i = model.role.flatMap { AudioTag.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        return TrackAudioInspectorModel.roleTitles[i]
    }
    var presetTitle: String {
        model.selectedPresetID.flatMap { id in model.presets.first { $0.id == id }?.name } ?? SQL10n.string("Custom")
    }

    /// CompressorBandsView.draw: field body, alternate band shading, gain-reduction bars from the top, crossover lines
    /// with their frequency under the strip.
    private func drawBands(_ c: inout Canvas, _ f: CGRect) {
        let t = theme, label: CGFloat = 14
        let g = CompressorBandsGeometry(width: f.width)
        let plot = CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height - label)
        let r = CGFloat(DrawTheme.Radius.control)
        c.fill(roundedRect: plot, radius: r, t.field)
        c.saveGState()
        c.clip(to: plot)
        let ranges = g.bandRanges(crossoversHz: model.compressor.crossoversHz)
        for (i, b) in ranges.enumerated() where i % 2 == 1 {
            c.fill(CGRect(x: plot.minX + b.lowerBound, y: plot.minY, width: b.upperBound - b.lowerBound, height: plot.height), t.inkFill(0.025))
        }
        let tint = t.accentTint
        for b in ranges {
            // As on the Mac (TrackAudioInspectorView never sets `gainReductionDB`), the track strip has no live reduction
            // feed: the bars stay at 0. The live band meters are in the Multiband setup (`MultibandEditorDraw`).
            let h = plot.height * CGFloat(CompressorBandsGeometry.barFraction(gainReductionDB: 0))
            let a: Float = model.compressor.bypass ? 0.3 : 1
            c.fill(CGRect(x: plot.minX + b.lowerBound + 1, y: plot.minY, width: max(0, b.upperBound - b.lowerBound - 2), height: h), tint.alpha(tint.a * a))
        }
        c.restoreGState()
        c.stroke(roundedRect: plot.insetBy(dx: 0.5, dy: 0.5), radius: r - 0.5, width: 1, t.fieldEdge)
        let cs = CGFloat(DrawTheme.TypeSize.caption)
        for (i, hz) in model.compressor.crossoversHz.enumerated() {
            let x = plot.minX + g.x(forHz: hz).rounded()
            let active = bandDrag == i || bandHover == i
            c.fill(CGRect(x: x, y: plot.minY, width: active ? 2 : 1, height: plot.height), active ? t.accent : t.label2)
            let text = CompressorBandsGeometry.hzText(hz)
            let w = c.size(of: text, fontSize: cs).width
            let tx = min(max(x - w / 2, f.minX), f.maxX - w)
            c.draw(text, at: CGPoint(x: tx, y: plot.maxY + 2), fontSize: cs, active ? t.label : t.label3)
        }
    }

    // MARK: Pointer

    private(set) var hover: Control?
    private var pressed: Control?
    private var bandDrag: Int?
    private var bandHover: Int?
    private var sliderDrag: Slider?
    private var fieldPress: Slider?
    private var counter = ClickCounter()

    func control(at p: CGPoint) -> Control? {
        for r in rows where p.y >= r.y && p.y < r.y + r.height {
            for (k, f) in r.controls {
                let hit = f.offsetBy(dx: 0, dy: r.y)
                // The Bypass box takes its title too; the strip and the rows take the whole row height.
                let wide = k == .bypass ? CGRect(x: hit.minX, y: r.y, width: Self.checkSide + 60, height: r.height)
                    : CGRect(x: hit.minX, y: r.y, width: hit.width, height: r.height)
                if wide.contains(p) { return k }
            }
        }
        return nil
    }

    public func mouseMoved(to p: CGPoint?) {
        guard bandDrag == nil, sliderDrag == nil, fieldPress == nil else { return }
        hover = p.flatMap(control(at:))
        bandHover = nil
        if let p, hover == .bands, let f = frame(.bands) {
            bandHover = CompressorBandsGeometry(width: f.width).handleIndex(at: p.x - f.minX, crossoversHz: model.compressor.crossoversHz)
        }
    }

    public func mouseDown(at p: CGPoint, clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let k = control(at: p)
        if let s = focused, k != .slider(s) { resignFocus() }
        guard let k else { return }
        pressed = k
        switch k {
        case .role, .preset:
            guard let f = frame(k) else { return }
            onMenu?(k == .role ? roleMenu() : presetMenu(), f)
            pressed = nil
        case .bypass, .gate, .warmth: break
        case .bands:
            guard let f = frame(.bands) else { return }
            if let i = CompressorBandsGeometry(width: f.width).handleIndex(at: p.x - f.minX, crossoversHz: model.compressor.crossoversHz) {
                bandDrag = i
                model.beginChange()
            }
        case .slider(let s):
            guard let f = frame(k), isEnabled(s) else { return }
            let parts = sliderParts(f)
            if p.x >= parts.field.minX {
                var fd = field(s)
                apply(fd.mouseDown(x: Float(p.x), clickCount: n), s)
                fields[s] = fd
                fieldPress = s
                focused = s
            } else {
                sliderDrag = s
                model.beginChange()
                setFromSlider(s, x: p.x, track: parts.track)
            }
        }
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        if let i = bandDrag, let f = frame(.bands) {
            let hz = CompressorBandsGeometry(width: f.width).draggedHz(index: i, toX: p.x - f.minX, crossoversHz: model.compressor.crossoversHz)
            model.setCrossover(i, hz: hz)
        } else if let s = sliderDrag, let f = frame(.slider(s)) {
            setFromSlider(s, x: p.x, track: sliderParts(f).track)
        } else if let s = fieldPress {
            var fd = field(s)
            apply(fd.mouseDragged(x: Float(p.x), modifiers: modifiers), s)
            fields[s] = fd
        }
    }

    public func mouseUp(at p: CGPoint) {
        defer { pressed = nil; mouseMoved(to: p) }
        if bandDrag != nil { bandDrag = nil; model.endChange(); return }
        if sliderDrag != nil { sliderDrag = nil; model.endChange(); return }
        if let s = fieldPress {
            var fd = field(s)
            apply(fd.mouseUp(), s)
            fields[s] = fd
            fieldPress = nil
            return
        }
        guard let k = pressed, control(at: p) == k else { return }
        switch k {
        case .bypass: model.setBypass(!model.compressor.bypass)
        case .gate: model.setGateEnabled(!model.gate.enabled)
        case .warmth: model.setWarmthEnabled(!model.saturation.enabled)
        default: break
        }
    }

    private func setFromSlider(_ s: Slider, x: CGFloat, track: CGRect) {
        let sp = spec(s)
        let raw = sp.range.lowerBound + InspectorDraw.sliderFraction(x: x, in: track) * (sp.range.upperBound - sp.range.lowerBound)
        set(s, (raw / sp.step).rounded() * sp.step)
    }

    /// Keys for the focused value field (typing, arrows, Enter, Esc); false when nothing is focused.
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        guard let s = focused else { return false }
        var fd = field(s)
        if k == .tab { apply(fd.resignFocus(), s); fields[s] = fd; moveFocus(from: s, backward: modifiers.contains(.shift)); return true }
        apply(fd.key(k, modifiers: modifiers, now: clock()), s)
        fields[s] = fd
        return true
    }

    /// Tab order: the enabled value fields top to bottom.
    private func moveFocus(from s: Slider, backward: Bool) {
        let order = Slider.allCases.filter(isEnabled)
        guard let i = order.firstIndex(of: s), !order.isEmpty else { focused = nil; return }
        focused = order[(i + (backward ? order.count - 1 : 1)) % order.count]
    }

    public func resignFocus() {
        guard let s = focused else { return }
        var fd = field(s)
        apply(fd.resignFocus(), s)
        fields[s] = fd
        focused = nil
    }

    /// Per frame: ends arrow / wheel step bursts (one undo step each).
    public func tick() {
        for s in Slider.allCases { guard var fd = fields[s] else { continue }; apply(fd.tick(now: clock()), s); fields[s] = fd }
    }

    public func help(at p: CGPoint) -> String? {
        switch control(at: p) {
        case .role: SQL10n.string("Dialogue, Music or SFX: loads a voiced EQ, compressor and level for this track")
        case .gate: SQL10n.string("Noise gate")
        case .warmth: SQL10n.string("Warmth")
        case .bypass: SQL10n.string("Bypass compressor")
        case .slider(let s): spec(s).help.map { SQL10n.string($0) }
        default: nil
        }
    }

    // MARK: Menus

    func roleMenu() -> [SQMenuItem] {
        let current = roleTitle
        return TrackAudioInspectorModel.roleTitles.enumerated().map { i, title in
            SQMenuItem(title: title, isChecked: title == current) { [model] in
                model.setRole(i == 0 ? nil : AudioTag.allCases[i - 1])
            }
        }
    }

    func presetMenu() -> [SQMenuItem] {
        var items = model.presets.map { p in
            SQMenuItem(title: p.name, isChecked: p.id == model.selectedPresetID) { [model] in model.selectPreset(id: p.id) }
        }
        if model.selectedPresetID.map({ id in !model.presets.contains { $0.id == id } }) ?? true {
            items.append(SQMenuItem(title: "Custom", isChecked: true) {})
        }
        return items
    }
}
