import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The Color panel on the shared toolkit: `ColorInspectorView` translated. The Simple grade (the effects with their
/// foldable sections: Basic with the Input LUT, white balance and Sharpen, Creative with the look and the tint wheels,
/// RGB and hue curves, the three wheels, the Zone Board, Color Range, Vignette) and the Pro grade's selected Step (the
/// four primary wheels, its sliders and curves). The logic is the shared `ColorGradeController` and its
/// `ColorInspectorModel`; this draws them and turns pointer and keys into their setters. Coordinates: points, y down,
/// (0, 0) = the panel's top-left; the panel scrolls itself (`scrollY`).
@MainActor public final class ColorGradeDraw {
    public let controller: ColorGradeController
    public var theme = DrawTheme()
    public var size = CGSize(width: 320, height: 600)
    /// The color wheels' wedge spans (static art, replayed each frame).
    private let wheelSpans = PolygonSpanCache()
    /// A popup opened: the host shows the SQ menu at `anchor` (panel coordinates).
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// Choose File… / Add LUTs to Library…: the host's file chooser for .cube files (paths, empty = canceled).
    /// Import Color Decision… in the Step menu (see `ColorStepsDraw`).
    public var chooseDecisionFile: (@MainActor (@escaping @MainActor (URL?) -> Void) -> Void)?
    public var tellUser: (@MainActor (String, String) -> Void)?
    public var chooseLUTFiles: (@MainActor (_ multiple: Bool, _ done: @escaping @MainActor ([String]) -> Void) -> Void)?
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    public private(set) var scrollY: CGFloat = 0

    public init(controller: ColorGradeController) { self.controller = controller }

    var model: ColorInspectorModel? { controller.model }

    // MARK: Controls

    enum Slider: Hashable {
        case param(Int, ColorParam), range(Int, ColorRangeParam), sharpen, zoneSat(Int, BoardZone), step(UUID, StepParam)
        /// The Pro page's own rows: Saturation / Contrast / Pivot (scaled), a Qualifier softness, a window value, a list row's Mix field.
        case primary(UUID, StepPrimaryRow), stepQual(UUID, ColorRangeParam), window(UUID, StepWindowParam), mix(UUID)
    }
    enum Wheel: Hashable { case slot(Int, ColorWheelSlot), zone(Int, BoardZone), step(UUID, PrimaryWheel) }
    enum Curve: Hashable { case rgb(Int), hue(Int), stepRGB(UUID), stepHue(UUID) }

    enum Control: Hashable {
        case effectMenu(Int)
        case section(Int, ColorSectionKind), sectionMenu(Int, ColorSectionKind)
        case lut(Int, ColorLUTSlot), lutStar(Int, ColorLUTSlot)
        case eyedropper(Int)
        case slider(Slider)
        case wheel(Wheel), master(Wheel)
        case channel(Curve, Int)
        case curve(Curve)
        case hueKind(Int), maskMode(Int), invert(Int)
        /// "Input color" below the sections (ColorGradeDraw+Input.swift): its header, popups and HDR switch.
        case inputSection, input(InputRow), conform
        /// The Pro page (ColorGradeDraw+Pro.swift): layer list, path line, tabs and the tab bodies.
        case listRow(UUID), listEye(UUID), listBlend(UUID), listMix(UUID), listAdd, listChip(GraphLUTSlot)
        case pathEye, pathMore, turnOn, startEmpty, startFromSimple, proTab(Int)
        case curveChip(Int), curveReset, stepHueKind
        case qualOn, pickColor, matte, qualInvert, rangeBar(StepRangeKind)
        case shapeChip(Int), windowRemove, windowInvert
        case lutPill, lutImport, addEffect
    }
    enum InputRow: Hashable { case interpret, logMode, deliver, project }

    struct Row {
        enum Style {
            case plain, effect, section, group, note
            /// Pro page: the empty state (label = title, summary = hint), a list row (open = selected, summary = has a LUT),
            /// the list's foot, the Step's path line, a warning band, a caption (lines), an upper-case group head, a form title.
            case empty, listItem, listFoot, path, warning, footnote, groupHead, title
        }
        var label: String?
        var style: Style = .plain
        var y: CGFloat
        var height: CGFloat
        var controls: [(Control, CGRect)]
        var dim = false
        var summary: String?
        var open = true
        var lines: [String] = []
        /// Where a plain row's label starts (nil = the Simple grid's label column); a group row's rule above it.
        var labelX: CGFloat?
        var rule = true
    }

    /// The Mac `ColorGrid` of the Simple page, in points: the panel inset, the label column (inset + chevron slot), the
    /// control column (label 96 + gap), the value column (the 48 wide number + gap), the rows and the section header.
    enum Mac {
        static let inset: CGFloat = 12
        static let labelX: CGFloat = 28
        static let controlX: CGFloat = 124
        static let valueWidth: CGFloat = 48
        static let valueColumn: CGFloat = 56
        static let row: CGFloat = 24
        static let popupRow: CGFloat = 28
        /// The hue box in its group stack (measured on the Mac PNG, `window-color-expanded-online`): the "Curve" row is a
        /// default `ColorControlRow` (30 high, `ColorGrid.controlRow`) whose label and popup land where a 28 pt popup row
        /// puts them, the box starts 7 pt below that and 8.5 pt of room follow it; the RGB box keeps 6 / 8.
        static let hueCurveTop: CGFloat = 7
        static let hueCurveBottom: CGFloat = 8.5
        static let slider: CGFloat = 20
        static let section: CGFloat = 25
        static let sectionGap: CGFloat = 4
        static let icon: CGFloat = 24
        static let chevronX: CGFloat = 12
        static let chevronGlyph: CGFloat = 8
        /// A popup row's popup ends here before the panel's right inset (the star sits in the gap).
        static let popupTrailing: CGFloat = 65
        static let group: CGFloat = 22
        static let rgbCurve: CGFloat = 150
        static let hueCurve: CGFloat = 90
        static let curveTop: CGFloat = 6
        static let curveBottom: CGFloat = 8
        static let wheel: CGFloat = 96
        /// The Input color rows sit on the "top" grid: label at the inset, controls from here.
        static let topControlX: CGFloat = 104
        /// The channel dots row: 9 pt dots 10 apart in a 19 pt row, the dots' top 6 pt down.
        static let dot: CGFloat = 9
        static let dotGap: CGFloat = 10
        static let dotRow: CGFloat = 19
    }
    static let fieldWidth: CGFloat = Mac.valueWidth
    static let sliderGap = CGFloat(DrawTheme.Spacing.sm)
    static let headerHeight: CGFloat = 28
    static let wheelMax: CGFloat = 132
    static let masterHeight: CGFloat = 14
    static let curveMax: CGFloat = 220
    static let puck: CGFloat = 10
    static let menuSide: CGFloat = 22

    /// The RGB curve's channel (0 master, 1 red, 2 green, 3 blue) and the hue curve shown, per effect / Step (view state).
    var channels: [Curve: Int] = [:]
    var hueKinds: [Int: HueCurveKind] = [:]
    /// "Input color" is unfolded (view state; the Mac `inputOpen`, closed at start).
    public var inputOpen = false
    /// The Pro page's tab (0 Primaries ... 5 Effects), the Step hue curve shown, and the text probe the layout measures with.
    public var proTab = 0
    var stepHueKind = HueCurveKind.hueVsSat
    /// The last frame's glyph atlas and scale: the layout measures text with it (a rough estimate before the first frame).
    var measure: (atlas: GlyphAtlas?, scale: Float)?
    var listPress: (id: UUID, y: CGFloat)?
    var listDrag: (id: UUID, target: Int)?
    var rangeDrag: (kind: StepRangeKind, grab: RangeBarMath.Grab)?

    func channel(_ c: Curve) -> Int { channels[c] ?? 0 }
    func hueKind(_ e: Int) -> HueCurveKind { hueKinds[e] ?? .hueVsSat }
    func hueKind(of c: Curve) -> HueCurveKind { if case .hue(let e) = c { hueKind(e) } else { stepHueKind } }

    // MARK: Layout

    var rows: [Row] {
        let rh = ControlsGrid.rowHeight, x0 = ControlsGrid.valueX, x1 = max(size.width - ControlsGrid.trailing, x0)
        let ch = ControlsGrid.controlHeight
        // The Simple page's own columns (the Mac `ColorGrid`): label 28, controls 124 to the inset, values 56 from the right.
        let mx1 = max(size.width - Mac.inset, Mac.controlX)
        func box(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat = ch, rowH: CGFloat = rh) -> CGRect {
            CGRect(x: x, y: ((rowH - h) / 2).rounded(), width: max(w, 0), height: h)
        }
        let full = box(x0, x1 - x0)
        var out: [Row] = []
        var y: CGFloat = 0
        func add(_ r: Row) { var r = r; r.y = y; out.append(r); y += r.height }
        func row(_ label: String?, _ c: [(Control, CGRect)], height: CGFloat = rh, style: Row.Style = .plain, dim: Bool = false) {
            add(Row(label: label, style: style, y: 0, height: height, controls: c, dim: dim))
        }
        guard let model else { return out }
        if model.shownGrade == .pro {
            proRows(model, add: add)
            inputRows(model, add: add, full: full, box: box)
            return out
        }
        // Simple rows: 24 high, the slider 20 in the middle; a popup row is 28 with the 22 high popup and its star.
        let slider = box(Mac.controlX, mx1 - Mac.controlX, Mac.slider, rowH: Mac.row)
        let popup = box(Mac.controlX, size.width - Mac.popupTrailing - Mac.controlX, CGFloat(DrawTheme.Metrics.capsule), rowH: Mac.popupRow)
        let star = box(mx1 - Mac.icon, Mac.icon, CGFloat(DrawTheme.Metrics.capsule), rowH: Mac.popupRow)
        let fullPopup = box(Mac.controlX, size.width - Mac.inset - Mac.controlX, CGFloat(DrawTheme.Metrics.capsule), rowH: Mac.popupRow)
        func group(_ title: String, rule: Bool = true, dim: Bool) {
            // The hairline is a pixel row of its own above the 22 pt label band.
            add(Row(label: title, style: .group, y: 0, height: Mac.group + (rule ? 1 : 0), controls: [], dim: dim, rule: rule))
        }
        func srow(_ label: String, _ s: Slider, dim: Bool) { row(label, [(.slider(s), slider)], height: Mac.row, dim: dim) }
        let primaryID = model.effects.first?.id
        for (n, e) in model.effects.enumerated() {
            let id = e.id
            // One effect is the grade itself (no band); more get a numbered band with their "..." (the Mac effect header).
            if model.effects.count > 1 {
                add(Row(label: model.effectTitle(id, number: n + 1), style: .effect, y: 0, height: Self.headerHeight,
                        controls: [(.effectMenu(id), box(mx1 - Self.menuSide, Self.menuSide, rowH: Self.headerHeight))]))
            }
            for kind in ColorSectionText.order {
                let open = !model.isCollapsed(ColorPanelKey(id, kind))
                let on = e.isEnabled(kind)
                let hh = Mac.sectionGap + Mac.section
                var hc: [(Control, CGRect)] = []
                // Basic's header carries the white balance picker (the Mac eyedropper button).
                if kind == .basicCorrection {
                    hc.append((.eyedropper(id), CGRect(x: mx1 - Mac.icon, y: Mac.sectionGap + ((Mac.section - Mac.icon) / 2).rounded(),
                                                       width: Mac.icon, height: Mac.icon)))
                }
                hc.append((.section(id, kind), CGRect(x: 0, y: 0, width: size.width, height: hh)))
                add(Row(label: kind.title, style: .section, y: 0, height: hh, controls: hc,
                        dim: !on, summary: ColorSectionText.summary(kind, channel: channel(.rgb(id)), effect: e), open: open))
                guard open else { continue }
                let dim = !on
                switch kind {
                case .basicCorrection:
                    row("Source LUT", [(.lut(id, .input), popup), (.lutStar(id, .input), star)], height: Mac.popupRow, dim: dim)
                    let hasLUT = e.inputLUT != nil && e.inputLUT != .automatic
                    let primary = id == primaryID
                    if !primary && hasLUT { srow(ColorParam.inputLUTIntensity.title, .param(id, .inputLUTIntensity), dim: dim) }
                    for g in ColorParam.layout(for: kind) {
                        for p in g.params where p != .inputLUTIntensity { srow(p.title, .param(id, p), dim: dim) }
                    }
                    if id == primaryID { srow("Sharpen", .sharpen, dim: dim) }
                case .creative:
                    row("Look LUT", [(.lut(id, .look), popup), (.lutStar(id, .look), star)], height: Mac.popupRow, dim: dim)
                    if e.creative.look != nil { srow(ColorParam.lookIntensity.title, .param(id, .lookIntensity), dim: dim) }
                    for g in ColorParam.layout(for: kind) {
                        for p in g.params { srow(p.title, .param(id, p), dim: dim) }
                    }
                case .curves:
                    let curve = Curve.rgb(id)
                    group("RGB Curves", rule: false, dim: dim)
                    let n = CGFloat(4 * Mac.dot + 3 * Mac.dotGap), x0 = ((size.width - n) / 2).rounded()
                    let dots: [(Control, CGRect)] = (0..<4).map { i in
                        (.channel(curve, i), CGRect(x: x0 + CGFloat(i) * (Mac.dot + Mac.dotGap) - Mac.dotGap / 2, y: 0,
                                                    width: Mac.dot + Mac.dotGap, height: Mac.dotRow))
                    }
                    row(nil, dots, height: Mac.dotRow, dim: dim)
                    curveRow(curve, dim: dim, add: add)
                    group("Hue Saturation Curves", dim: dim)
                    row("Curve", [(.hueKind(id), fullPopup)], height: Mac.popupRow, dim: dim)
                    curveRow(.hue(id), dim: dim, add: add)
                case .wheels:
                    wheelsRow([.slot(id, .shadows), .slot(id, .midtones), .slot(id, .highlights)], masters: true, dim: dim, add: add)
                    srow(ColorParam.wheelsSaturation.title, .param(id, .wheelsSaturation), dim: dim)
                case .zoneBoard:
                    wheelsRow(BoardZone.allCases.map { .zone(id, $0) }, masters: true, dim: dim, add: add)
                    group("Saturation", dim: dim)
                    for z in BoardZone.allCases { srow(z.title, .zoneSat(id, z), dim: dim) }
                case .hslSecondary:
                    let mode = model.rangeMaskMode(id)
                    group("Range", dim: dim)
                    row("Mask", [(.maskMode(id), fullPopup)], height: Mac.popupRow, dim: dim)
                    for p in ColorRangeParam.allCases where p.isShown(in: mode) && !p.isCorrection { srow(p.title, .range(id, p), dim: dim) }
                    row("Invert", [(.invert(id), box(Mac.controlX, size.width - Mac.inset - Mac.controlX, Mac.row, rowH: Mac.popupRow))],
                        height: Mac.popupRow, dim: dim)
                    group("Correction", dim: dim)
                    for p in ColorRangeParam.allCases where p.isShown(in: mode) && p.isCorrection { srow(p.title, .range(id, p), dim: dim) }
                case .vignette:
                    var first = true
                    for g in ColorParam.layout(for: kind) {
                        if let title = g.group { group(title, rule: !first, dim: dim) }
                        first = false
                        for p in g.params { srow(p.title, .param(id, p), dim: dim) }
                    }
                }
            }
        }
        inputRows(model, add: add, full: full, box: box)
        return out
    }

    private func channelControls(_ curve: Curve, x0: CGFloat, box: (CGFloat, CGFloat, CGFloat) -> CGRect) -> [(Control, CGRect)] {
        (0..<4).map { i in (.channel(curve, i), box(x0 + CGFloat(i) * 26, 18, 18)) }
    }
    private func channelControls(_ curve: Curve, x0: CGFloat, box: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect) -> [(Control, CGRect)] {
        channelControls(curve, x0: x0, box: { x, w, h in box(x, w, h, ControlsGrid.rowHeight) })
    }

    /// A Mac curve box: 6 pt above, 8 below, the inset on both sides (`ColorGrid.rgbCurve` / `hueCurve` high).
    private func curveRow(_ c: Curve, dim: Bool, add: (Row) -> Void) {
        let h = c.isHue ? Mac.hueCurve : Mac.rgbCurve
        let top = c.isHue ? Mac.hueCurveTop : Mac.curveTop, bottom = c.isHue ? Mac.hueCurveBottom : Mac.curveBottom
        add(Row(label: nil, y: 0, height: top + h + bottom,
                controls: [(.curve(c), CGRect(x: Mac.inset, y: top, width: max(size.width - 2 * Mac.inset, 0), height: h))], dim: dim))
    }

    /// The Mac wheel row (`wheelRow` / `buildZoneBoard`): cells of 86 x 112 (zone 66 x 92) spread edge to edge, the title at
    /// the cell's top, the disc `cell - 24` wide centered in the 96 (76) pt below the title band, the master slider at its right.
    private func wheelsRow(_ wheels: [Wheel], masters: Bool, dim: Bool, add: (Row) -> Void) {
        let zone: Bool = if case .zone = wheels.first { true } else { false }
        let side: CGFloat = zone ? 76 : Mac.wheel
        let cellW = side - 10, cellH = side + CGFloat(DrawTheme.Spacing.lg), band: CGFloat = 16
        let d = min(cellW - 14 - 10, side), top = CGFloat(DrawTheme.Spacing.xs)
        let avail = max(size.width - 2 * Mac.inset, 0), n = CGFloat(max(wheels.count, 1))
        let step = n > 1 ? (avail - cellW) / (n - 1) : 0
        var controls: [(Control, CGRect)] = []
        for (i, w) in wheels.enumerated() {
            let x = Mac.inset + (n > 1 ? CGFloat(i) * step : (avail - cellW) / 2)
            let y = top + band + ((cellH - band - d) / 2)
            controls.append((.wheel(w), CGRect(x: x, y: y, width: d, height: d)))
            if masters { controls.append((.master(w), CGRect(x: x + d + 10, y: y, width: 14, height: d))) }
        }
        // The zone row's stack is 8 pt taller than its 92 pt wheels (inset height 100), which centers them 4 pt lower.
        let lift: CGFloat = zone ? CGFloat(DrawTheme.Spacing.sm) : 0
        add(Row(label: nil, y: 0, height: cellH + lift + 2 * top,
                controls: controls.map { ($0.0, $0.1.offsetBy(dx: 0, dy: lift / 2)) }, dim: dim))
    }

    public var contentHeight: CGFloat { rows.last.map { $0.y + $0.height } ?? 0 }

    func frame(_ c: Control, in rs: [Row]? = nil) -> CGRect? {
        for r in rs ?? rows { if let f = r.controls.first(where: { $0.0 == c })?.1 { return f.offsetBy(dx: 0, dy: r.y) } }
        return nil
    }

    /// The slider's track and its number: the value column is 56 wide (48 for the number, 8 gap) at the row's right end.
    func sliderParts(_ r: CGRect) -> (track: CGRect, field: CGRect) {
        let fw = min(Self.fieldWidth, r.width)
        let field = CGRect(x: r.maxX - fw, y: r.minY, width: fw, height: r.height)
        let track = CGRect(x: r.minX, y: r.minY, width: max(r.width - Mac.valueColumn, 0), height: r.height)
        return (track, field)
    }

    // MARK: Values

    struct SliderSpec { var range: ClosedRange<Double>; var neutral: Double; var decimals: Int }
    func spec(_ s: Slider) -> SliderSpec {
        func of(_ r: ClosedRange<Float>, _ n: Float, _ d: Int) -> SliderSpec {
            SliderSpec(range: Double(r.lowerBound)...Double(r.upperBound), neutral: Double(n),
                       decimals: ColorValueText.shownDecimals(range: r, decimals: d))
        }
        switch s {
        case .param(_, let p): return of(p.range, p.neutral, p.decimals)
        case .range(_, let p): return of(p.range, p.neutral, p.decimals)
        case .sharpen: return of(Clip.sharpenRowRange, 0, 0)
        case .zoneSat: return of(0...200, 100, 0)
        case .step(_, let p): return of(p.range, p.neutral, p.decimals)
        case .primary(_, let r): return of(r.range, r.neutral, 0)
        case .stepQual(_, let p): return of(p.range, p.neutral, 0)
        case .window(_, let p): return of(p.range, p.neutral, 0)
        case .mix: return of(0...100, 100, 0)
        }
    }
    func value(_ s: Slider) -> Double {
        guard let m = model else { return spec(s).neutral }
        switch s {
        case .param(let e, let p): return Double(m.value(e, p))
        case .range(let e, let p): return Double(m.rangeValue(e, p))
        case .sharpen: return Double(m.sharpen)
        case .zoneSat(let e, let z): return Double(m.zoneSaturationPercent(e, z))
        case .step(let id, let p): return Double(m.stepValue(id, p))
        case .primary(let id, let r): return Double(m.stepValue(id, r.param) * r.scale)
        case .stepQual(let id, let p): return Double(m.stepQualifierValue(id, p))
        case .window(let id, let p): return Double(m.stepWindowValue(id, p))
        case .mix(let id): return Double(m.stepValue(id, .mix))
        }
    }
    func set(_ s: Slider, _ v: Double) {
        guard let m = model else { return }
        let f = Float(v)
        switch s {
        case .param(let e, let p): m.set(e, p, f)
        case .range(let e, let p): m.setRange(e, p, f)
        case .sharpen: m.setSharpen(f)
        case .zoneSat(let e, let z): m.setZoneSaturation(e, z, percent: f)
        case .step(let id, let p): m.setStep(id, p, f)
        case .primary(let id, let r): m.setStep(id, r.param, f / r.scale)
        case .stepQual(let id, let p): m.setStepQualifier(id, p, f)
        case .window(let id, let p): m.setStepWindow(id, p, f)
        case .mix(let id): m.setStep(id, .mix, f)
        }
    }

    /// Wheel state: puck (hue in degrees, amount 0…1) and master (-1…1).
    func wheelValue(_ w: Wheel) -> (puck: ColorWheelMath.Value, master: Double) {
        guard let m = model else { return (ColorWheelMath.reset, 0) }
        switch w {
        case .slot(let e, let s):
            let v = m.wheel(e, s)
            return (ColorWheelMath.Value(hue: Double(v.value.hue), amount: Double(v.value.amount)), Double(v.luma / 100))
        case .zone(let e, let z):
            let v = m.zonePuckWheel(e, z)
            return (ColorWheelMath.Value(hue: Double(v.hue), amount: Double(v.amount)), Double(m.zoneExposureSlider(e, z)))
        case .step(let id, let p): return m.stepWheel(id, p)
        }
    }
    func setPuck(_ w: Wheel, _ v: ColorWheelMath.Value) {
        guard let m = model else { return }
        switch w {
        case .slot(let e, let s): m.setWheel(e, s, hue: Float(v.hue), amount: Float(v.amount))
        case .zone(let e, let z): m.setZonePuck(e, z, hue: Float(v.hue), amount: Float(v.amount))
        case .step(let id, let p): m.setStepWheel(id, p, puck: v, master: wheelValue(w).master)
        }
    }
    func setMaster(_ w: Wheel, _ v: Double) {
        guard let m = model else { return }
        switch w {
        case .slot(let e, let s): m.setWheelLuma(e, s, Float(v * 100))
        case .zone(let e, let z): m.setZoneExposure(e, z, slider: Float(v))
        case .step(let id, let p): m.setStepWheel(id, p, puck: wheelValue(w).puck, master: v)
        }
    }
    func resetWheel(_ w: Wheel) {
        guard let m = model else { return }
        switch w {
        case .slot(let e, let s): m.resetWheel(e, s)
        case .zone(let e, let z): m.resetZone(e, z)
        case .step(let id, let p): m.gesture { m.setStepWheel(id, p, puck: ColorWheelMath.reset, master: 0) }
        }
    }
    func wheelTitle(_ w: Wheel) -> String {
        switch w {
        case .slot(_, let s): s.title
        case .zone(_, let z): z.title
        case .step(_, let p): p.title
        }
    }
    func hasMaster(_ w: Wheel) -> Bool { if case .slot(_, let s) = w { s.hasLuma } else { true } }

    func points(_ c: Curve) -> [CurvePoint] {
        guard let m = model else { return RGBCurves.diagonal }
        switch c {
        case .rgb(let e): return Self.channelPoints(m.curves(e), channel(c))
        case .hue(let e): return m.hueCurve(e, hueKind(e))
        case .stepRGB(let id): return Self.channelPoints(m.stepCurves(id), channel(c))
        case .stepHue(let id): return m.stepHueCurve(id, stepHueKind)
        }
    }
    func setPoints(_ c: Curve, _ pts: [CurvePoint]) {
        guard let m = model else { return }
        switch c {
        case .rgb(let e): var v = m.curves(e); Self.write(pts, channel(c), into: &v); m.setCurves(e, v)
        case .hue(let e): m.setHueCurve(e, hueKind(e), pts)
        case .stepRGB(let id): var v = m.stepCurves(id); Self.write(pts, channel(c), into: &v); m.setStepCurves(id, v)
        case .stepHue(let id): m.setStepHueCurve(id, stepHueKind, pts)
        }
    }
    static func channelPoints(_ c: RGBCurves, _ ch: Int) -> [CurvePoint] {
        switch ch { case 1: c.red; case 2: c.green; case 3: c.blue; default: c.master }
    }
    static func write(_ pts: [CurvePoint], _ ch: Int, into c: inout RGBCurves) {
        switch ch { case 1: c.red = pts; case 2: c.green = pts; case 3: c.blue = pts; default: c.master = pts }
    }
    func curveColor(_ c: Curve) -> DrawColor {
        if c.isHue { return theme.label }
        switch channel(c) { case 1: return theme.red; case 2: return theme.green; case 3: return theme.accent; default: return theme.label }
    }

    /// One scrub field per slider; refilled from the model unless it is in a gesture or being typed into.
    var fields: [Slider: ScrubFieldControl] = [:]
    var focused: Slider?
    func field(_ s: Slider) -> ScrubFieldControl {
        let sp = spec(s)
        var f = fields[s] ?? ScrubFieldControl(value: value(s))
        f.range = sp.range; f.decimals = sp.decimals; f.defaultValue = sp.neutral
        f.step = sp.decimals == 0 ? 1 : pow(10, -Double(min(sp.decimals, 2)))
        if !f.isDragging, !f.isEditing { f.value = value(s) }
        return f
    }

    func apply(_ events: [ScrubFieldControl.Event], _ s: Slider) {
        guard let m = model else { return }
        for e in events {
            switch e {
            case .begin: m.onGestureBegan?()
            case .live(let v), .change(let v): set(s, v)
            case .end(let v): set(s, v); m.onGestureEnded?()
            case .cancel(let v): set(s, v); m.onGestureCancelled?()
            }
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        measure = (c.atlas, c.scale)
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        clampScroll()
        c.saveGState()
        c.clip(to: CGRect(origin: .zero, size: size))
        c.translateBy(x: 0, y: -scrollY)
        let rs = rows
        for r in rs where r.y + r.height >= scrollY && r.y <= scrollY + size.height {
            let a: Float = r.dim ? InspectorTokens.disabledAlpha : 1
            switch r.style {
            case .effect:
                c.fill(CGRect(x: 0, y: r.y, width: size.width, height: r.height), t.inkFill(0.04))
                c.draw(SQL10n.string(r.label ?? ""), in: CGRect(x: Mac.inset, y: r.y, width: size.width * 0.7, height: r.height),
                       fontSize: fs, t.label.alpha(a), face: c.semibold)
            case .section:
                // The Mac header: a 4 pt gap, then 25 pt with the chevron, the bold title and the summary at the right.
                let band = CGRect(x: 0, y: r.y + Mac.sectionGap, width: size.width, height: Mac.section)
                InspectorDraw.chevron(&c, in: CGRect(x: Mac.chevronX + 1.5, y: band.minY - 1, width: Mac.chevronGlyph, height: band.height),
                                      direction: r.open ? .down : .right, t.label3, size: 5)
                c.draw(SQL10n.string(r.label ?? ""), in: CGRect(x: Mac.labelX, y: band.minY, width: size.width / 2, height: band.height),
                       fontSize: fs, t.label.alpha(a), face: c.semibold)
                if let s = r.summary, !s.isEmpty, !r.open {
                    c.draw(SQL10n.string(s), in: CGRect(x: size.width / 2, y: band.minY, width: size.width / 2 - Mac.inset, height: band.height),
                           fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3, align: .right)
                }
            case .group:
                // ColorGroupLabel: an optional hairline above, the upper-case caption at the inset.
                if r.rule { c.fill(CGRect(x: 0, y: r.y, width: size.width, height: 1), t.separator.alpha(t.separator.a * a)) }
                c.draw(SQL10n.string(r.label ?? "").uppercased(), in: CGRect(x: Mac.inset, y: r.y + (r.rule ? 0 : 0.5), width: size.width, height: r.height),
                       fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3.alpha(a), face: c.semibold)
            case .note:
                c.draw(SQL10n.string(r.label ?? ""), in: CGRect(x: ControlsGrid.labelX, y: r.y, width: size.width, height: r.height),
                       fontSize: fs, t.label3)
            case .empty, .listItem, .listFoot, .path, .warning, .footnote, .groupHead, .title: drawProRow(&c, r, alpha: a)
            case .plain:
                if let l = r.label {
                    c.draw(SQL10n.string(l), in: CGRect(x: r.labelX ?? Mac.labelX, y: r.y, width: Mac.controlX - (r.labelX ?? Mac.labelX) - Mac.inset / 2, height: r.height),
                           fontSize: fs, t.label2.alpha(a))
                }
            }
            for (k, f0) in r.controls { drawControl(&c, k, f0.offsetBy(dx: 0, dy: r.y), enabled: !r.dim) }
        }
        c.restoreGState()
    }

    private func drawControl(_ c: inout Canvas, _ k: Control, _ f: CGRect, enabled: Bool) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        if drawProControl(&c, k, f, enabled: enabled) { return }
        switch k {
        case .effectMenu, .sectionMenu:
            if hover == k { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: .ellipsis, at: CGPoint(x: f.midX - 7, y: f.midY - 7), size: 14, t.label2)
        case .section: break
        case .lut(let e, let slot):
            InspectorDraw.popup(&c, title: SQL10n.string(lutTitle(e, slot)), in: f, hovering: hover == k, open: false, enabled: enabled, t)
        case .lutStar(let e, let slot):
            let c0 = model?.lutChoice(e, slot), on = c0.map { model?.isFavouriteLUT($0) == true } ?? false
            let live = enabled && c0?.filePath != nil
            if live, hover == k { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: on ? .starFilled : .star, at: CGPoint(x: f.midX - 7, y: f.midY - 7), size: 14, live ? t.label2 : t.label3.alpha(0.5))
        case .eyedropper:
            let live = enabled && model?.samplingBlock == nil && model?.onPickWhiteBalance != nil
            if live, pressed == k { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillPressed) }
            else if live, hover == k { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: .eyedropper, at: CGPoint(x: f.midX - 7, y: f.midY - 7), size: 14, live ? t.label2 : t.label3.alpha(0.5))
        case .slider(let s):
            let p = sliderParts(f), sp = spec(s)
            let frac = (value(s) - sp.range.lowerBound) / max(sp.range.upperBound - sp.range.lowerBound, 1e-9)
            let centred = sp.range.lowerBound < 0 && sp.range.lowerBound < sp.neutral && sp.neutral < sp.range.upperBound
            let nf = (sp.neutral - sp.range.lowerBound) / max(sp.range.upperBound - sp.range.lowerBound, 1e-9)
            InspectorDraw.colorSlider(&c, fraction: frac, neutral: centred ? nf : nil, ramp: ramp(s), in: p.track, enabled: enabled, t)
            var fd = field(s)
            fd.isEnabled = enabled
            // The Mac shows the number as plain right-aligned text in the label color (no field box until typed into).
            fd.isPlain = true
            fd.valueTint = enabled ? t.label : t.label.alpha(t.label.a * InspectorTokens.disabledAlpha)
            fd.hovering = hover == k
            fd.draw(&c, in: p.field, theme: t, focused: focused == s)
        case .wheel(let w): drawWheel(&c, w, f, active: wheelDrag?.wheel == w && wheelDrag?.master == false || hover == k)
        case .master(let w): drawMaster(&c, w, f, active: wheelDrag?.wheel == w && wheelDrag?.master == true || hover == k)
        case .channel(let curve, let i):
            let colors = [t.label.alpha(0.9), t.red, t.green, DrawTheme.marker(.blue)]
            let dot = CGRect(x: f.midX - Mac.dot / 2, y: f.minY + 6, width: Mac.dot, height: Mac.dot)
            c.fill(ellipseIn: dot, colors[i].alpha(enabled ? 1 : InspectorTokens.disabledAlpha))
            if channel(curve) == i { c.stroke(ellipseIn: dot.insetBy(dx: -2.5, dy: -2.5), width: 1, t.label) }
        case .curve(let curve): drawCurve(&c, curve, f)
        case .hueKind(let e):
            InspectorDraw.popup(&c, title: SQL10n.string(hueKind(e).title), in: f, hovering: hover == k, open: false, enabled: enabled, t)
        case .maskMode(let e):
            InspectorDraw.popup(&c, title: SQL10n.string(model?.rangeMaskMode(e).title ?? ""), in: f, hovering: hover == k, open: false,
                                enabled: enabled, t)
        case .invert(let e):
            let on = model?.colorRange(e)?.invert == true
            InspectorDraw.checkbox(&c, on ? .on : .off, box: CGRect(x: f.minX, y: f.midY - 7, width: 14, height: 14),
                                   hovering: hover == k, pressed: pressed == k, enabled: enabled, t)
            c.draw("Correct outside (Inside / Outside)", in: CGRect(x: f.minX + 20, y: f.minY, width: max(f.width - 20, 0), height: f.height),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label.alpha(enabled ? 1 : InspectorTokens.disabledAlpha))
        case .inputSection: break
        case .input(let r):
            InspectorDraw.popup(&c, title: SQL10n.string(inputTitle(r)), in: f, hovering: hover == k, open: false, enabled: enabled, t)
        case .conform:
            InspectorDraw.checkbox(&c, model?.hdrConform == true ? .on : .off, box: CGRect(x: f.minX, y: f.midY - 7, width: 14, height: 14),
                                   hovering: hover == k, pressed: pressed == k, enabled: enabled, t)
            c.draw("Convert HDR automatically", in: CGRect(x: f.minX + 20, y: f.minY, width: max(f.width - 20, 0), height: f.height),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label.alpha(enabled ? 1 : InspectorTokens.disabledAlpha))
        default: break
        }
    }

    /// Distance from the Mac wheel view's top (where the title is drawn) to the disc: 20 with the master below, else 33 (the Simple cell centers its smaller disc).
    func titleLead(_ w: Wheel) -> CGFloat {
        if case .step = w { return 20 }
        return 33        // 16 title band + the disc centered in the rest of the 96 / 76 pt cell
    }

    /// ColorWheelControl.draw: field disc, hue wedges fading to the center, crosshair, puck; the title above.
    private func drawWheel(_ c: inout Canvas, _ w: Wheel, _ disc: CGRect, active: Bool) {
        let t = theme
        c.draw(SQL10n.string(wheelTitle(w)), in: CGRect(x: disc.minX - 10, y: disc.minY - titleLead(w), width: disc.width + 20, height: 14),
               fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2, align: .center)
        c.fill(ellipseIn: disc, t.field)
        let ctr = CGPoint(x: disc.midX, y: disc.midY), r = disc.width / 2
        // The 192 wedges rasterize to thousands of row spans: built once per disc size, replayed (round 6 profile).
        c.fill(polygons: Self.wedges(radius: r), at: disc.origin, key: Double(r), cache: wheelSpans)
        c.stroke(ellipseIn: disc.insetBy(dx: 0.5, dy: 0.5), width: 1, t.fieldEdge)
        c.strokeLine(from: CGPoint(x: disc.minX + 6, y: ctr.y), to: CGPoint(x: disc.maxX - 6, y: ctr.y), width: 0.5, t.fieldEdge)
        c.strokeLine(from: CGPoint(x: ctr.x, y: disc.minY + 6), to: CGPoint(x: ctr.x, y: disc.maxY - 6), width: 0.5, t.fieldEdge)
        let pr = puckRect(w, disc: disc)
        c.fill(ellipseIn: pr.insetBy(dx: -1, dy: -1), t.onPictureShadow)
        c.fill(ellipseIn: pr, t.fillPressed)
        c.stroke(ellipseIn: pr, width: 1.5, active ? t.accent : t.label)
    }

    /// The puck's frame on `disc` (content coordinates).
    func puckRect(_ w: Wheel, disc: CGRect) -> CGRect {
        let o = ColorWheelMath.offset(of: wheelValue(w).puck, radius: Double(disc.width / 2))
        let pc = CGPoint(x: disc.midX + CGFloat(o.dx), y: disc.midY - CGFloat(o.dy))
        return CGRect(x: pc.x - Self.puck / 2, y: pc.y - Self.puck / 2, width: Self.puck, height: Self.puck)
    }

    /// The hue wedges fading to the center, relative to the disc's top-left. The Mac draws 120 full sectors at 0.55 and a
    /// black radial gradient (0.85 at the center to 0) over them. That is one "over" layer per ring: with the dark field
    /// below, alpha `1 - 0.45 (1 - k)` and color `hue * 0.55 (1 - k) / alpha` give the same pixel, `k` the gradient's black.
    /// One ring per point of radius (smooth), and fewer sectors on the inner rings (a ring has less arc to cover); the
    /// spans are built once per size by `PolygonSpanCache`, so nothing is allocated per frame.
    static func wedges(radius r: CGFloat) -> [([CGPoint], DrawColor)] {
        let bands = max(12, Int((r * 1.5).rounded())), maxSteps = 120, ctr = CGPoint(x: r, y: r)
        var out: [([CGPoint], DrawColor)] = []
        out.reserveCapacity(bands * maxSteps * 2 / 3)
        for b in 0..<bands {
            let r0 = r * CGFloat(b) / CGFloat(bands), r1 = r * CGFloat(b + 1) / CGFloat(bands)
            let t = (Double(b) + 0.5) / Double(bands), k = 0.85 * (1 - t)
            let alpha = 1 - 0.45 * (1 - k), gain = 0.55 * (1 - k) / alpha
            let steps = max(24, Int((Double(maxSteps) * t).rounded(.up) / 4) * 4)
            for i in 0..<steps {
                let a0 = Double(i) / Double(steps) * 2 * .pi, a1 = Double(i + 1) / Double(steps) * 2 * .pi
                let rgb = hsb(((Double(i) + 0.5) / Double(steps) - 0.5 / Double(maxSteps) + 1).truncatingRemainder(dividingBy: 1), 0.85, 0.75)
                func p(_ a: Double, _ rr: CGFloat) -> CGPoint { CGPoint(x: ctr.x + rr * CGFloat(cos(a)), y: ctr.y - rr * CGFloat(sin(a))) }
                out.append(([p(a0, r0), p(a0, r1), p(a1, r1), p(a1, r0)],
                            DrawColor(Float(Double(rgb.0) * gain), Float(Double(rgb.1) * gain), Float(Double(rgb.2) * gain), Float(alpha))))
            }
        }
        return out
    }

    /// The version 9 slider below the disc: a 3 pt track with the accent fill from the center, a 4 x 14 bar thumb.
    private func drawMaster(_ c: inout Canvas, _ w: Wheel, _ r: CGRect, active: Bool) {
        let t = theme
        if r.height > r.width {      // ColorWheelControl.drawSlider: a 4 pt field track, center tick, 8 pt knob
            let track = CGRect(x: r.midX - 2, y: r.minY, width: 4, height: r.height)
            c.fill(roundedRect: track, radius: CGFloat(DrawTheme.Radius.small), t.field)
            c.stroke(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), radius: CGFloat(DrawTheme.Radius.small), width: 1, t.fieldEdge)
            c.fill(CGRect(x: r.minX + 1, y: r.midY - 0.5, width: r.width - 2, height: 1), t.label3)
            let ky = r.minY + CGFloat(ColorWheelMath.y(forMaster: wheelValue(w).master, height: Double(r.height)))
            let knob = CGRect(x: r.minX, y: ky - 4, width: r.width, height: 8)
            c.fill(roundedRect: knob.insetBy(dx: -1, dy: -1), radius: CGFloat(DrawTheme.Radius.control), t.onPictureShadow)
            c.fill(roundedRect: knob, radius: CGFloat(DrawTheme.Radius.control), active ? t.accentFill : t.label)
            return
        }
        let th: CGFloat = 3, y = r.midY.rounded()
        c.fill(roundedRect: CGRect(x: r.minX, y: y - th / 2, width: r.width, height: th), radius: th / 2, t.fill)
        let kx = r.minX + CGFloat(ColorWheelMath.x(forMaster: wheelValue(w).master, width: Double(r.width)))
        c.fill(roundedRect: CGRect(x: min(r.midX, kx), y: y - th / 2, width: abs(kx - r.midX), height: th), radius: th / 2, t.accent)
        c.fill(roundedRect: CGRect(x: (kx - 2).rounded(), y: y - 7, width: 4, height: 14), radius: 2, active ? t.accent : t.label)
    }

    /// The plot inside a curve box: the Mac editor insets its bounds by 6 pt on every side.
    static func curvePlot(_ f: CGRect) -> CGRect { f.insetBy(dx: 6, dy: 6) }

    /// ColorCurveEditor.draw: field, quarter grid, the diagonal (RGB) or middle line (hue), the curve and its points.
    private func drawCurve(_ c: inout Canvas, _ curve: Curve, _ box: CGRect) {
        let t = theme, f = Self.curvePlot(box)
        c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small), t.field)
        if curve.isHue, hueKind(of: curve).isHueKeyed {
            // The Mac's hue strip: a smooth 6 pt ribbon along the plot's bottom edge.
            let n = max(Int(f.width / 2), 36)
            for i in 0..<n {
                let rgb = Self.hsb(Double(i) / Double(n), 0.9, 0.95)
                c.fill(CGRect(x: f.minX + f.width * CGFloat(i) / CGFloat(n), y: f.maxY - 6, width: f.width / CGFloat(n) + 0.5, height: 6),
                       DrawColor(rgb.0, rgb.1, rgb.2, 1))
            }
        }
        for i in 1..<4 {
            let x = f.minX + f.width * CGFloat(i) / 4, y = f.minY + f.height * CGFloat(i) / 4
            c.strokeLine(from: CGPoint(x: x, y: f.minY), to: CGPoint(x: x, y: f.maxY), width: 0.5, t.fieldEdge)
            c.strokeLine(from: CGPoint(x: f.minX, y: y), to: CGPoint(x: f.maxX, y: y), width: 0.5, t.fieldEdge)
        }
        if curve.isHue {
            c.strokeLine(from: CGPoint(x: f.minX, y: f.midY), to: CGPoint(x: f.maxX, y: f.midY), width: 0.5, t.fieldEdge)
        } else {
            c.strokeLine(from: CGPoint(x: f.minX, y: f.maxY), to: CGPoint(x: f.maxX, y: f.minY), width: 0.5, t.fieldEdge)
        }
        let pts = points(curve)
        let samples = CurveMath.sample(pts, max(Int(f.width / 2), 16))
        let line = samples.enumerated().map { i, v in
            CGPoint(x: f.minX + f.width * CGFloat(i) / CGFloat(max(samples.count - 1, 1)), y: f.maxY - f.height * CGFloat(min(max(v, 0), 1)))
        }
        c.saveGState()
        c.clip(to: f)
        c.strokePolyline(line, width: 1.5, curveColor(curve))
        c.restoreGState()
        for (i, p) in pts.enumerated() {
            let q = CGPoint(x: f.minX + CGFloat(p.x) * f.width, y: f.maxY - CGFloat(p.y) * f.height)
            let dot = CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)
            c.fill(ellipseIn: dot, curveDrag?.curve == curve && curveDrag?.index == i ? t.accent : t.label)
        }
    }

    /// HSB to RGB (the wheel backdrop's wedge colors).
    static func hsb(_ h: Double, _ s: Double, _ v: Double) -> (Float, Float, Float) {
        let i = Int((h * 6).rounded(.down)) % 6, f = h * 6 - (h * 6).rounded(.down)
        let p = v * (1 - s), q = v * (1 - f * s), u = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (v, u, p)
        case 1: (q, v, p)
        case 2: (p, v, u)
        case 3: (p, q, v)
        case 4: (u, p, v)
        default: (v, p, q)
        }
        return (Float(r), Float(g), Float(b))
    }

    func lutTitle(_ e: Int, _ slot: ColorLUTSlot) -> String {
        guard let m = model else { return "None" }
        return m.lutChoice(e, slot)?.name ?? "None"
    }

    // MARK: Pointer

    private(set) var hover: Control?
    var pressed: Control?
    var sliderDrag: Slider?
    var fieldPress: Slider?
    private struct WheelDrag: Equatable {
        var wheel: Wheel; var master: Bool; var fine: Bool
        var start: ColorWheelMath.Value; var startMaster: Double; var startPoint: (Double, Double)
        static func == (a: WheelDrag, b: WheelDrag) -> Bool { a.wheel == b.wheel && a.master == b.master }
    }
    private var wheelDrag: WheelDrag?
    private struct CurveDrag: Equatable { var curve: Curve; var index: Int }
    private var curveDrag: CurveDrag?
    private var counter = ClickCounter()

    func control(at p: CGPoint) -> Control? {
        let q = CGPoint(x: p.x, y: p.y + scrollY)
        for r in rows where q.y >= r.y && q.y < r.y + r.height {
            for (k, f) in r.controls {
                let hit = f.offsetBy(dx: 0, dy: r.y)
                let wide: CGRect
                switch k {
                case .slider, .lut, .hueKind, .maskMode, .input, .stepHueKind: wide = CGRect(x: hit.minX, y: r.y, width: hit.width, height: r.height)
                default: wide = hit
                }
                if wide.contains(q) { return k }
            }
            if r.style == .section { return nil }
        }
        return nil
    }

    public func mouseMoved(to p: CGPoint?) {
        if let p { HostHover.current.request(cursor(at: p)) }
        guard sliderDrag == nil, fieldPress == nil, wheelDrag == nil, curveDrag == nil else { return }
        hover = p.flatMap(control(at:))
    }

    /// The pointer shape at `p` (view points), the Mac cursor rects: the open hand on a wheel's puck and a curve's
    /// points (the closed hand while dragging them), the crosshair over a curve, side arrows on a master slider and a
    /// number field (the I-beam while it is typed into); nil = the arrow.
    func cursor(at p: CGPoint) -> DrawCursor? {
        if curveDrag != nil || wheelDrag?.master == false { return .closedHand }
        if let d = wheelDrag, d.master { return frame(.master(d.wheel)).map { $0.height > $0.width } == true ? .resizeUpDown : .resizeLeftRight }
        if let s = fieldPress { return field(s).isEditing ? .iBeam : .resizeLeftRight }
        guard let k = control(at: p), let f = frame(k) else { return nil }
        let q = CGPoint(x: p.x, y: p.y + scrollY)
        switch k {
        case .wheel(let w): return puckRect(w, disc: f).contains(q) ? .openHand : nil
        case .master(let w): return frame(.master(w)).map { $0.height > $0.width } == true ? .resizeUpDown : .resizeLeftRight
        case .curve(let curve):
            let pl = Self.curvePlot(f)
            return CurveEditing.hit(points(curve), x: q.x - pl.minX, y: q.y - pl.minY, size: pl.size) != nil ? .openHand : .crosshair
        case .slider(let s):
            guard sliderParts(f).field.contains(q) else { return nil }
            return field(s).isEditing ? .iBeam : .resizeLeftRight
        default: return nil
        }
    }

    public func scroll(dy: CGFloat) {
        scrollY -= dy
        clampScroll()
    }
    private func clampScroll() { scrollY = min(max(scrollY, 0), max(contentHeight - size.height, 0)) }

    public func mouseDown(at p: CGPoint, modifiers: InputModifiers = [], clickCount: Int? = nil) {
        defer { HostHover.current.request(cursor(at: p)) }
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let k = control(at: p)
        if let s = focused, k != .slider(s) { resignFocus() }
        guard let k, let m = model else { return }
        let q = CGPoint(x: p.x, y: p.y + scrollY)
        pressed = k
        if modifiers.contains(.secondary) {
            switch k {
            case .section(let e, let kind): openSectionMenu(e, kind, anchor: frame(.sectionMenu(e, kind)) ?? .zero)
            case .slider(let s): resetSlider(s)
            case .wheel(let w), .master(let w): resetWheel(w)
            case .listRow, .pathMore: proSecondary(k)
            default: break
            }
            pressed = nil
            return
        }
        switch k {
        case .lutStar(let e, let slot):
            if let c = m.lutChoice(e, slot), c.filePath != nil { m.toggleFavouriteLUT(c) }
            pressed = nil
        case .effectMenu, .sectionMenu, .lut, .hueKind, .maskMode, .input: openMenu(k); pressed = nil
        case .inputSection: inputOpen.toggle(); pressed = nil
        case .section(let e, let kind):
            let key = ColorPanelKey(e, kind)
            m.setCollapsed(key, !m.isCollapsed(key))
            pressed = nil
        case .eyedropper, .invert, .conform: break
        case .channel(let curve, let i): channels[curve] = i; pressed = nil
        case .listRow, .listEye, .listBlend, .listMix, .listAdd, .listChip, .pathEye, .pathMore, .turnOn, .startEmpty, .startFromSimple,
             .proTab, .curveChip, .curveReset, .stepHueKind, .qualOn, .pickColor, .matte, .qualInvert, .rangeBar, .shapeChip, .windowRemove,
             .windowInvert, .lutPill, .lutImport, .addEffect:
            proMouseDown(k, at: q, modifiers: modifiers, clickCount: n)
        case .slider(let s):
            guard let f = frame(k) else { return }
            let parts = sliderParts(f)
            if q.x >= parts.field.minX {
                var fd = field(s)
                apply(fd.mouseDown(x: Float(q.x), clickCount: n), s)
                fields[s] = fd
                fieldPress = s
                focused = s
            } else if n >= 2 {
                resetSlider(s)
            } else {
                sliderDrag = s
                m.onGestureBegan?()
                setFromSlider(s, x: q.x, track: parts.track)
            }
        case .wheel(let w), .master(let w):
            if n >= 2 { resetWheel(w); pressed = nil; return }
            guard let f = frame(k) else { return }
            let isMaster: Bool = if case .master = k { true } else { false }
            let v = wheelValue(w)
            let fine = modifiers.contains(.option)
            let local = isMaster ? (Double(q.x - f.minX), 0) : (Double(q.x - f.midX), Double(f.midY - q.y))
            wheelDrag = WheelDrag(wheel: w, master: isMaster, fine: fine, start: v.puck, startMaster: v.master, startPoint: local)
            m.onGestureBegan?()
            dragWheel(to: q, modifiers: modifiers)
        case .curve(let curve):
            guard let f = frame(k) else { return }
            let pts = points(curve)
            let pl = Self.curvePlot(f)
            let lx = q.x - pl.minX, ly = q.y - pl.minY
            if let i = CurveEditing.hit(pts, x: lx, y: ly, size: pl.size) {
                if n >= 2 || modifiers.contains(.option) {
                    m.gesture { setPoints(curve, CurveEditing.remove(pts, index: i)) }
                    return
                }
                m.onGestureBegan?()
                curveDrag = CurveDrag(curve: curve, index: i)
            } else {
                m.onGestureBegan?()
                let added = CurveEditing.add(pts, x: Float(lx / max(pl.width, 1)), y: Float(1 - ly / max(pl.height, 1)))
                setPoints(curve, added.points)
                curveDrag = CurveDrag(curve: curve, index: added.index)
            }
        }
    }


    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        defer { HostHover.current.request(cursor(at: p)) }
        let q = CGPoint(x: p.x, y: p.y + scrollY)
        if let s = sliderDrag, let f = frame(.slider(s)) {
            setFromSlider(s, x: q.x, track: sliderParts(f).track)
        } else if let s = fieldPress {
            var fd = field(s)
            apply(fd.mouseDragged(x: Float(q.x), modifiers: modifiers), s)
            fields[s] = fd
        } else if proMouseDragged(q) {
        } else if wheelDrag != nil {
            dragWheel(to: q, modifiers: modifiers)
        } else if let d = curveDrag, let f = frame(.curve(d.curve)) {
            let pl = Self.curvePlot(f)
            let x = Float((q.x - pl.minX) / max(pl.width, 1)), y = Float(1 - (q.y - pl.minY) / max(pl.height, 1))
            setPoints(d.curve, CurveEditing.move(points(d.curve), index: d.index, to: x, y))
        }
    }

    private func dragWheel(to q: CGPoint, modifiers: InputModifiers) {
        guard var d = wheelDrag else { return }
        let k: Control = d.master ? .master(d.wheel) : .wheel(d.wheel)
        guard let f = frame(k) else { return }
        let fine = modifiers.contains(.option)
        if d.master, f.height > f.width {        // the Mac's vertical master beside the disc
            let y = Double(q.y - f.minY)
            if fine != d.fine { d.fine = fine; d.startMaster = wheelValue(d.wheel).master; d.startPoint = (y, 0); wheelDrag = d }
            let h = Double(f.height)
            let m = fine ? ColorWheelMath.master(forY: ColorWheelMath.y(forMaster: d.startMaster, height: h) + (y - d.startPoint.0) * ColorWheelMath.fineFactor, height: h)
                : ColorWheelMath.master(forY: y, height: h)
            setMaster(d.wheel, m)
        } else if d.master {
            let x = Double(q.x - f.minX)
            if fine != d.fine {      // re-anchor so toggling Option does not jump the thumb
                d.fine = fine; d.startMaster = wheelValue(d.wheel).master; d.startPoint = (x, 0); wheelDrag = d
            }
            let w = Double(f.width)
            let m = fine ? ColorWheelMath.master(forX: ColorWheelMath.x(forMaster: d.startMaster, width: w) + (x - d.startPoint.0) * ColorWheelMath.fineFactor, width: w)
                : ColorWheelMath.master(forX: x, width: w)
            setMaster(d.wheel, m)
        } else {
            let pt = (Double(q.x - f.midX), Double(f.midY - q.y))
            if fine != d.fine { d.fine = fine; d.start = wheelValue(d.wheel).puck; d.startPoint = pt; wheelDrag = d }
            setPuck(d.wheel, ColorWheelMath.drag(start: d.start, startPoint: d.startPoint, point: pt, radius: Double(f.width / 2), fine: fine))
        }
    }

    public func mouseUp(at p: CGPoint) {
        defer { pressed = nil; mouseMoved(to: p) }
        let m = model
        if proMouseUp() { return }
        if sliderDrag != nil { sliderDrag = nil; m?.onGestureEnded?(); return }
        if wheelDrag != nil { wheelDrag = nil; m?.onGestureEnded?(); return }
        if curveDrag != nil { curveDrag = nil; m?.onGestureEnded?(); return }
        if let s = fieldPress {
            var fd = field(s)
            apply(fd.mouseUp(), s)
            fields[s] = fd
            fieldPress = nil
            return
        }
        guard let k = pressed, control(at: p) == k, let m else { return }
        switch k {
        case .eyedropper(let e): if m.samplingBlock == nil { m.onPickWhiteBalance?(e) }
        case .invert(let e): m.setRangeInvert(e, !(m.colorRange(e)?.invert ?? false))
        case .conform: m.setHDRConform(!m.hdrConform)
        default: proClicked(k)
        }
    }

    func resetSlider(_ s: Slider) {
        guard let m = model else { return }
        switch s {
        case .param(let e, let p): m.resetParameter(e, p)
        case .range(let e, let p): m.resetRangeParameter(e, p)
        case .step(let id, let p): m.gesture { m.setStep(id, p, p.neutral) }
        case .primary(let id, let r): m.gesture { m.resetStepValue(id, r.param) }
        case .stepQual(let id, let p): m.gesture { m.resetStepQualifierParameter(id, p) }
        case .window(let id, let p): m.gesture { m.resetStepWindowParameter(id, p) }
        case .mix: m.gesture { set(s, 100) }
        case .sharpen, .zoneSat: m.gesture { set(s, spec(s).neutral) }
        }
    }

    private func setFromSlider(_ s: Slider, x: CGFloat, track: CGRect) {
        let sp = spec(s)
        let raw = sp.range.lowerBound + InspectorDraw.colorSliderFraction(x: x, in: track) * (sp.range.upperBound - sp.range.lowerBound)
        let k = pow(10, Double(sp.decimals))
        set(s, (raw * k).rounded() / k)
    }

    /// Keys for the focused value field (typing, arrows, Enter, Esc); false when nothing is focused.
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        if k == .escape, let m = model, wheelDrag != nil || curveDrag != nil || sliderDrag != nil {
            wheelDrag = nil; curveDrag = nil; sliderDrag = nil
            m.onGestureCancelled?()
            return true
        }
        guard let s = focused else { return false }
        var fd = field(s)
        if k == .tab { apply(fd.resignFocus(), s); fields[s] = fd; focused = nil; return true }
        apply(fd.key(k, modifiers: modifiers, now: clock()), s)
        fields[s] = fd
        return true
    }

    public func resignFocus() {
        guard let s = focused else { return }
        var fd = field(s)
        apply(fd.resignFocus(), s)
        fields[s] = fd
        focused = nil
    }

    /// Per frame: ends arrow / wheel step bursts (one undo step each); forgets fields of a switched clip.
    public func tick() {
        for (s, f) in fields { var fd = f; apply(fd.tick(now: clock()), s); fields[s] = fd }
        if lastKey != controller.key { lastKey = controller.key; fields = [:]; focused = nil; scrollY = 0 }
    }
    private var lastKey: UUID?

    public func help(at p: CGPoint) -> String? {
        switch control(at: p) {
        case .eyedropper: model?.samplingBlock ?? SQL10n.string("Click a neutral gray or white area in the Program monitor to set the white balance")
        case .hueKind(let e), .curve(.hue(let e)): SQL10n.string(hueKind(e).explanation)
        case .lut(let e, let s): model?.lutMismatch(e, s)
        case .lutStar: SQL10n.string("Favorite LUT")
        case let k?: proHelp(k) ?? inputHelp(k).map { SQL10n.string($0) }
        default: nil
        }
    }

    // MARK: Menus

    private func openMenu(_ k: Control) {
        guard let f = frame(k) else { return }
        let anchor = f.offsetBy(dx: 0, dy: -scrollY)
        switch k {
        case .effectMenu(let e): onMenu?(effectMenu(e), anchor)
        case .sectionMenu(let e, let kind): openSectionMenu(e, kind, anchor: f)
        case .lut(let e, let slot): onMenu?(lutMenu(e, slot), anchor)
        case .hueKind(let e):
            onMenu?(HueCurveKind.allCases.map { kind in
                SQMenuItem(title: kind.title, isChecked: hueKind(e) == kind, help: kind.explanation) { [weak self] in self?.hueKinds[e] = kind }
            }, anchor)
        case .maskMode(let e):
            guard let m = model else { return }
            onMenu?(HSLSecondary.MaskMode.allCases.map { mode in
                SQMenuItem(title: mode.title, isChecked: m.rangeMaskMode(e) == mode) { m.setRangeMaskMode(e, mode) }
            }, anchor)
        case .input(let r): onMenu?(inputMenu(r), anchor)
        default: break
        }
    }

    /// The section's own menu: on / off, reset, and Hold Saturation Legal for the curves (showSectionMenu).
    func sectionMenu(_ effect: Int, _ kind: ColorSectionKind) -> [SQMenuItem] {
        guard let m = model, let e = m.effects.first(where: { $0.id == effect }) else { return [] }
        let on = e.isEnabled(kind), name = SQL10n.string(kind.title)
        var items = [
            SQMenuItem(title: SQL10n.format(on ? "Turn %@ Off" : "Turn %@ On", name)) { m.setEnabled(effect, kind, !on) },
            SQMenuItem(title: SQL10n.format("Reset %@", name)) { m.resetSection(effect, kind) },
        ]
        if kind == .curves { items.append(SQMenuItem(title: "Hold Saturation Legal") { m.holdSaturationLegal(effect) }) }
        return items
    }
    private func openSectionMenu(_ effect: Int, _ kind: ColorSectionKind, anchor: CGRect) {
        onMenu?(sectionMenu(effect, kind), anchor.offsetBy(dx: 0, dy: -scrollY))
    }

    /// The Color tab's "..." menu (the strip hosts the button): layout, grade copy and paste, and the Simple page's actions.
    public func panelMenuItems() -> [SQMenuItem] { controller.moreMenuItems(simpleExtra: simpleActionItems()) }

    /// What the panel menu adds for the Simple grade of a clip (simpleActionItems).
    func simpleActionItems() -> [SQMenuItem] {
        guard let m = model, let e = m.effects.first else { return [] }
        let id = e.id
        var items = [SQMenuItem(title: "Add Color Effect") { m.addEffect() }]
        if m.effectRangeLabels[id] != nil {
            items.append(SQMenuItem(title: "Set Range to In/Out") { m.onGradeAction?(.setRangeToInOut(id)) })
            items.append(SQMenuItem(title: "Grade Whole Clip") { m.onGradeAction?(.wholeClip(id)) })
        }
        items.append(SQMenuItem(title: "Auto Tone", isEnabled: m.autoToneBlock(id) == nil) { m.onAutoTone?(id) })
        items.append(SQMenuItem(title: "Reset Tone") { m.resetTone(id) })
        items.append(SQMenuItem(title: "Reset Section", submenu: m.sectionResets(id).map { r in
            SQMenuItem(title: r.title, isEnabled: r.enabled) { m.resetSection(id, r.kind) }
        }))
        items.append(SQMenuItem(title: "Sections", submenu: ColorSectionText.order.map { kind in
            let on = e.isEnabled(kind)
            return SQMenuItem(title: kind.title, isChecked: on) { m.setEnabled(id, kind, !on) }
        }))
        return items
    }

    /// The effect header's "..." (moreActionsPressed): grade copy and links, ranges, the Pro switch, tone and resets.
    func effectMenu(_ effect: Int) -> [SQMenuItem] {
        guard let m = model else { return [] }
        var items: [SQMenuItem] = [
            SQMenuItem(title: "Copy Grade", shortcut: "\u{2318}C") { m.onCopyColor?() },
            SQMenuItem(title: "Paste Grade", shortcut: "\u{2318}V") { m.onPasteColor?() },
            SQMenuItem(title: "Add Color Effect") { m.addEffect() },
            .separator,
            SQMenuItem(title: "Link Grade to Selected Clips") { m.onGradeAction?(.linkSelected) },
            SQMenuItem(title: "Link All Clips of This Source") { m.onGradeAction?(.linkSource) },
        ]
        if m.linkedClipCount > 1 { items.append(SQMenuItem(title: "Unlink Grade") { m.onGradeAction?(.unlink) }) }
        items.append(SQMenuItem(title: "Grade Whole Sequence") { m.onGradeWholeSequence?() })
        items.append(SQMenuItem(title: "Add Range Grade") { m.onGradeAction?(.addRange) })
        if m.effectRangeLabels[effect] != nil {
            items.append(SQMenuItem(title: "Set Range to In/Out") { m.onGradeAction?(.setRangeToInOut(effect)) })
            items.append(SQMenuItem(title: "Grade Whole Clip") { m.onGradeAction?(.wholeClip(effect)) })
        }
        items.append(.separator)
        if m.shownGrade == .pro {
            items.append(SQMenuItem(title: "Use Simple Grade") { m.setActiveGrade(.simple) })
        } else {
            items.append(SQMenuItem(title: "Use Pro Grade (Color Graph)") { m.setActiveGrade(.pro) })
            items.append(SQMenuItem(title: "Send Simple Values to Pro", isEnabled: m.canSendToPro) { m.sendToPro() })
        }
        items.append(.separator)
        items.append(SQMenuItem(title: "Auto Tone", isEnabled: m.autoToneBlock(effect) == nil) { m.onAutoTone?(effect) })
        items.append(SQMenuItem(title: "Reset Tone") { m.resetTone(effect) })
        for r in m.sectionResets(effect) {
            items.append(SQMenuItem(title: r.title, isEnabled: r.enabled) { m.resetSection(effect, r.kind) })
        }
        if m.effects.first?.id != effect {
            items.append(.separator)
            items.append(SQMenuItem(title: "Remove Effect") { m.removeEffect(effect) })
        }
        return items
    }

    /// The LUT popup in the board order (refreshLUTPopup): Automatic and Embedded (Input LUT of the first effect), None,
    /// Favorites, Library (the other library LUTs, the current file, up to 10 look choices), the two file actions, and the
    /// favorite toggle (the Mac star next to the popup).
    func lutMenu(_ effect: Int, _ slot: ColorLUTSlot) -> [SQMenuItem] {
        guard let m = model else { return [] }
        typealias Choice = ColorInspectorModel.LUTChoice
        let current = m.lutChoice(effect, slot)
        let isPrimary = m.effects.first?.id == effect
        func item(_ title: String, _ c: Choice?) -> SQMenuItem {
            SQMenuItem(title: title, isChecked: c == current) { m.setLUT(effect, slot, c) }
        }
        var items: [SQMenuItem] = []
        if slot == .input && isPrimary {
            items.append(item("Automatic", .automatic))
            if let n = m.embeddedLUTName { items.append(item("Embedded: \(n)", .embedded(name: n))) }
            else if current?.id == "embedded", let c = current { items.append(item(c.name, c)) }
        }
        items.append(item("None", nil))
        var seen = Set<String>()
        let favourites = m.libraryLUTs.filter(\.isFavourite), others = m.libraryLUTs.filter { !$0.isFavourite }
        if !favourites.isEmpty {
            items += [.separator, .header("Favorites")]
            for e in favourites { let c = Choice.file(e.path); items.append(item(e.name, c)); seen.insert(c.id) }
        }
        var library: [SQMenuItem] = []
        for e in others { let c = Choice.file(e.path); library.append(item(e.name, c)); seen.insert(c.id) }
        if let c = current, c.filePath != nil, !seen.contains(c.id) { library.append(item(c.name, c)); seen.insert(c.id) }
        var extra = 0
        for c in m.lookChoices where !seen.contains(c.id) && extra < 10 { library.append(item(c.name, c)); seen.insert(c.id); extra += 1 }
        if !library.isEmpty { items += [.separator, .header("Library")] + library }
        items.append(.separator)
        items.append(SQMenuItem(title: "Add LUTs to Library…", isEnabled: chooseLUTFiles != nil) { [weak self] in
            self?.chooseLUTFiles?(true) { paths in
                guard !paths.isEmpty else { return }
                if let first = m.importLUTs(paths.map { URL(fileURLWithPath: $0) }).first { m.setLUT(effect, slot, first) }
            }
        })
        items.append(SQMenuItem(title: "Choose File…", isEnabled: chooseLUTFiles != nil) { [weak self] in
            self?.chooseLUTFiles?(false) { paths in if let p = paths.first { m.setLUT(effect, slot, .file(p)) } }
        })
        if let c = current, let path = c.filePath, m.libraryLUTs.contains(where: { $0.path == path }) {
            let starred = m.isFavouriteLUT(c)
            items.append(SQMenuItem(title: starred ? "Remove from Favorites" : "Add to Favorites") { m.toggleFavouriteLUT(c) })
        }
        return items
    }
}

extension ColorGradeDraw.Curve {
    var isHue: Bool { switch self { case .hue, .stepHue: true; default: false } }
}
