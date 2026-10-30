import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit
import SQLibrary

// The curve popover on the shared toolkit: `EasingCurvePopoverController` and `EaseSpeedEditorView` translated. The
// chip items, their thumbnail math and the model's ease source are shared with the Mac popover.

extension EffectControlsModel: EaseCurveSource {
    public var sessionEasingCurves: [EasingCurve] { easingLibrary.userCurves }
    public func observeEaseInputs() { _ = clip; _ = selection; _ = easingLibrary }
    public var emptyEaseHint: String { "Select keyframes to ease" }
    public var canBakeSpring: Bool { true }
}

/// The user's saved easing curves in the shared preset store (kind `.easing`, payload `EasingCurve.presetPayload()`).
public enum EasingPresets {
    public static func load(_ store: PresetStore) async -> [EasingCurve] {
        await store.presets(kind: .easing).compactMap { try? EasingCurve(presetPayload: $0.payload, name: $0.name, id: $0.id) }
    }

    /// Adds a preset (name trimmed; empty becomes "Custom Curve") and returns the curve.
    @discardableResult
    public static func save(_ shape: EaseShape, name: String, in store: PresetStore?) async throws -> EasingCurve {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let curve = EasingCurve(shape: shape, name: trimmed.isEmpty ? "Custom Curve" : trimmed)
        try await store?.add(PresetItem(id: curve.id, kind: .easing, name: curve.name, payload: try curve.presetPayload(),
                                        payloadVersion: EasingCurve.presetPayloadVersion))
        return curve
    }
}

/// One entry of the preset strip under the curve editor: a bezier curve (applies as handles) or a spring (bakes keys).
enum EasingChipItem: Equatable {
    case curve(EasingCurve)
    case spring(SpringPreset)

    var name: String {
        switch self {
        case .curve(let c): c.displayName
        case .spring(let s): s.name
        }
    }

    /// Eased progress at `count` points, straight from SQCore (`previewSamples`).
    func samples(count: Int) -> [Double] {
        switch self {
        case .curve(let c): c.previewSamples(count: count)
        case .spring(let s): s.spring.previewSamples(count: count)
        }
    }
}

/// Thumbnail of an easing curve: pure point math (testable); the Mac renders an image from it. y down.
enum EasingThumbnail {
    /// Samples mapped into `rect`. The vertical range is 0...1 widened to the samples' extent (springs overshoot), so
    /// the start and end values stay on the same two lines for every thumbnail that does not overshoot.
    static func points(samples: [Double], in rect: CGRect) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let lo = min(0, samples.min() ?? 0), hi = max(1, samples.max() ?? 1)
        let n = samples.count - 1
        return samples.enumerated().map { i, v in
            CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(n),
                    y: rect.maxY - rect.height * CGFloat((v - lo) / (hi - lo)))
        }
    }
}

enum EasingCurveChips {
    /// Built-ins first, then saved presets, then curves saved this session from the graph (no duplicates). Without
    /// `hold` no Hold curve is offered (a source that refuses it, e.g. a transition).
    static func curves(saved: [EasingCurve], session: [EasingCurve], hold: Bool = true) -> [EasingCurve] {
        var out = EasingCurve.builtIns
        if !hold { out.removeAll { $0.interpolation.isHold } }
        for c in saved + session where !out.contains(where: { $0.id == c.id }) && (hold || !c.interpolation.isHold) { out.append(c) }
        return out
    }
}

/// The speed curve of one eased stretch (`EaseSpeedEditorView`): the single-segment graph that fills the view, both
/// handles shown; sideways sets a handle's Reach, up and down (past the dead zone) the speed at its key.
@MainActor public final class EaseSpeedEditorDraw {
    public var reading: EaseReading = .empty
    public var emptyHint = "Nothing to ease"
    public var valueRange: ClosedRange<Double> = -2...3
    public var size: CGSize = .zero
    var onBegin: (() -> Void)?
    var onChange: ((EaseShape) -> Void)?
    var onEnd: (() -> Void)?

    static let inset: CGFloat = 18
    private let from = UUID(), to = UUID()
    private struct Drag {
        var side: EaseSide, base: EaseTrackSegment, grab: CGSize, origin: CGPoint
        var geometry: SpeedGraphGeometry
        var vertical = false
    }
    private var drag: Drag?
    private var dragShape: EaseShape?
    public private(set) var hovered: EaseSide?

    var shownShape: EaseShape? {
        if let dragShape { return dragShape }
        switch reading {
        case .empty: return nil
        case .common(let s): return s
        case .mixed: return .linear
        }
    }
    private var isMixed: Bool { if case .mixed = reading, dragShape == nil { return true } else { return false } }
    private func segment(_ shape: EaseShape) -> EaseTrackSegment {
        EaseTrackSegment(from: from, to: to, start: .zero, end: Time(1, 1), shape: shape)
    }
    var segment: EaseTrackSegment? { shownShape.map(segment) }
    private var ghosts: [EaseTrackSegment] {
        if case .mixed(let shapes) = reading, dragShape == nil { return shapes.map(segment) }
        return []
    }

    var geometry: SpeedGraphGeometry {
        if let g = drag?.geometry { return g }
        let all = (segment.map { [$0] } ?? []) + ghosts
        var g = SpeedGraphGeometry(lane: KeyframeLaneGeometry(width: size.width, duration: Time(1, 1), inset: Self.inset),
                                   height: size.height, peak: SpeedGraphGeometry.peak(of: all))
        g.low = SpeedGraphGeometry.low(of: all)
        return g
    }

    /// "Overshoot 12%" / "Wind-Up 8%" when the value leaves the span between its keys, else nil.
    var readout: String? {
        guard !isMixed, let e = shownShape?.valueExcursion else { return nil }
        func pct(_ v: Double) -> String? { v >= 0.005 ? "\(Int((v * 100).rounded()))%" : nil }
        let parts = [pct(e.below).map { "Wind-Up " + $0 }, pct(e.above).map { "Overshoot " + $0 }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    func handle(at p: CGPoint) -> EaseSide? {
        guard let s = segment, case .handle(_, _, let side) = geometry.hitTest(p, rows: [[s]], selected: [[from, to]]) else { return nil }
        return side
    }

    func draw(_ c: inout Canvas, _ t: DrawTheme) {
        let geo = geometry, w = size.width, b = geo.baseline
        c.fill(CGRect(x: 0, y: b.rounded(), width: w, height: 1), t.graphGrid)
        InlineSpeedGraphDraw.dashedH(&c, y: (b - geo.unitHeight).rounded(), from: 0, to: w, t.graphGrid)
        for g in ghosts {
            InlineSpeedGraphDraw.drawRow(&c, geo, width: w, theme: t, segments: [g], selected: [], color: t.label3) { _, _ in false }
        }
        guard let s = segment else {
            guard ghosts.isEmpty else { return }
            c.draw(emptyHint, in: CGRect(origin: .zero, size: size), fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3, align: .center)
            return
        }
        InlineSpeedGraphDraw.drawRow(&c, geo, width: w, theme: t, segments: [s], selected: [from, to],
                                     color: isMixed ? DrawColor(0, 0, 0, 0) : t.accent) { [hovered, drag] _, side in
            side == hovered || side == drag?.side
        }
        if let r = readout {
            let sz = c.size(of: r, fontSize: CGFloat(DrawTheme.TypeSize.caption))
            c.draw(r, at: CGPoint(x: w - sz.width - 8, y: 5), fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label2)
        }
    }

    func mouseMoved(to p: CGPoint?) { if drag == nil { hovered = p.flatMap(handle(at:)) } }

    @discardableResult
    func press(at p: CGPoint) -> Bool {
        guard let s = segment, let side = handle(at: p) else { return false }
        let geo = geometry, end = geo.handleTrueEnd(s, side: side)
        let speed = side == .in ? s.shape.speedIn : s.shape.speedOut
        let trueY = geo.baseline - CGFloat(speed) * geo.unitHeight
        drag = Drag(side: side, base: s, grab: CGSize(width: end.x - p.x, height: trueY - p.y), origin: p, geometry: geo)
        onBegin?()
        return true
    }

    func dragGesture(to p: CGPoint, shift: Bool = false) {
        guard var d = drag else { return }
        let v = EaseHandleDragMath.isVertical(wasVertical: d.vertical, pressY: d.origin.y, y: p.y, shift: shift)
        if v != d.vertical { d.vertical = v; drag = d }
        let reach = d.geometry.reach(atX: p.x + d.grab.width, d.base, side: d.side)
        var s = d.base.shape.settingReach(reach, side: d.side)
        let speed = d.vertical ? d.geometry.speed(atY: p.y + d.grab.height) : (d.side == .in ? s.speedIn : s.speedOut)
        s = s.settingSpeed(speed, side: d.side, valueRange: valueRange)
        dragShape = s
        onChange?(s)
    }

    func release() {
        guard drag != nil else { return }
        drag = nil; dragShape = nil
        onEnd?()
    }
}

/// The curve popover (`EasingCurvePopoverController`, 260 x 200): the speed curve, the preset chips under it (scroll
/// sideways), a name field with Save. Coordinates: the popover's points, (0, 0) top left, chrome included. The host
/// places it (`ColorPickerControl.frame`-style rule in `frame(anchor:in:)`), routes events and saves presets
/// (`onSave`: the shape and the typed name).
@MainActor public final class EasingPopoverDraw {
    public static let size = CGSize(width: 260, height: 200)
    static let pad: CGFloat = 8, chipWidth: CGFloat = 40, chipGap: CGFloat = 4, thumb = CGSize(width: 34, height: 22)

    public let source: any EaseCurveSource
    /// The user's saved curves (the Mac `EasingPresetLibrary.saved`); the host fills it.
    public var saved: [EasingCurve] = []
    public var onSave: (@MainActor (EaseShape, String) -> Void)?
    let editor = EaseSpeedEditorDraw()
    private(set) var chips: [EasingChipItem] = []
    private(set) var chipScroll: CGFloat = 0
    private(set) var name = TextFieldControl()
    private var hover: Part?
    private var pressed: Part?

    enum Part: Equatable { case editor, chip(Int), name, save }

    public init(source: any EaseCurveSource) {
        self.source = source
        editor.onBegin = { [source] in source.beginGesture() }
        editor.onChange = { [source] s in source.applyEaseShape(s) }
        editor.onEnd = { [source] in source.endGesture() }
        name.alignment = .left
        name.fontSize = CGFloat(DrawTheme.TypeSize.body)
        refresh()
    }

    // MARK: Layout

    static let editorFrame = CGRect(x: 0, y: 0, width: size.width, height: 126)
    static let chipStrip = CGRect(x: 0, y: 132, width: size.width, height: 26)
    static let nameFrame = CGRect(x: pad, y: 167, width: size.width - 2 * pad - 64, height: 24)
    static let saveFrame = CGRect(x: size.width - pad - 60, y: 167, width: 60, height: 24)
    func chipFrame(_ i: Int) -> CGRect {
        CGRect(x: Self.pad + CGFloat(i) * (Self.chipWidth + Self.chipGap) - chipScroll, y: Self.chipStrip.minY,
               width: Self.chipWidth, height: Self.chipStrip.height)
    }
    private var chipsWidth: CGFloat { 2 * Self.pad + CGFloat(chips.count) * (Self.chipWidth + Self.chipGap) - Self.chipGap }

    /// Below the anchor, above when it does not fit, kept inside `visible` (SQPopoverLogic: gap 4, margin 6).
    public func frame(anchor: CGRect, in visible: CGRect) -> CGRect {
        let s = Self.size, gap: CGFloat = 4, area = visible.insetBy(dx: 6, dy: 6)
        var y = anchor.maxY + gap
        if y + s.height > area.maxY, anchor.minY - gap - s.height >= area.minY { y = anchor.minY - gap - s.height }
        let x = min(max(anchor.midX - s.width / 2, area.minX), max(area.minX, area.maxX - s.width))
        return CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    func part(at p: CGPoint) -> Part? {
        if Self.editorFrame.contains(p) { return .editor }
        if Self.chipStrip.contains(p) { return chips.indices.first { chipFrame($0).contains(p) }.map(Part.chip) }
        if Self.nameFrame.contains(p) { return .name }
        if Self.saveFrame.contains(p) { return .save }
        return nil
    }

    private var common: EaseShape? { if case .common(let s) = source.easeReading { s } else { nil } }

    /// Reads the source again (call after every model change while open).
    public func refresh() {
        editor.reading = source.easeReading
        editor.emptyHint = source.emptyEaseHint
        editor.valueRange = source.handleValueRange
        editor.size = Self.editorFrame.size
        var items = EasingCurveChips.curves(saved: saved, session: source.sessionEasingCurves, hold: source.allowsHold)
            .map(EasingChipItem.curve)
        if source.canBakeSpring { items += EasingLibrary.springPresets.map(EasingChipItem.spring) }
        chips = items
        chipScroll = min(chipScroll, max(0, chipsWidth - Self.size.width))
    }

    // MARK: Input

    public func mouseDown(at p: CGPoint, modifiers: InputModifiers = []) {
        let hit = part(at: p)
        if hit != .name, name.isEditing { _ = name.commit() }
        pressed = hit
        switch hit {
        case .editor: editor.press(at: p)
        case .name: name.mouseDown()
        default: break
        }
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        if pressed == .editor { editor.dragGesture(to: p, shift: modifiers.contains(.shift)) }
    }

    public func mouseUp(at p: CGPoint) {
        defer { pressed = nil; refresh() }
        switch pressed {
        case .editor: editor.release()
        case .chip(let i) where part(at: p) == .chip(i) && source.easeReading != .empty: apply(chips[i])
        case .save where part(at: p) == .save: save()
        default: break
        }
    }

    public func mouseMoved(to p: CGPoint?) {
        hover = p.flatMap(part(at:))
        editor.mouseMoved(to: hover == .editor ? p : nil)
        name.hovering = hover == .name
    }

    /// The chip strip scrolls sideways (wheel or trackpad).
    public func scroll(at p: CGPoint, dx: CGFloat, dy: CGFloat) -> Bool {
        guard Self.chipStrip.contains(p) else { return false }
        let d = abs(dx) > abs(dy) ? dx : dy
        chipScroll = min(max(0, chipScroll - d), max(0, chipsWidth - Self.size.width))
        return true
    }

    /// Keys of the name field; Enter there saves (the Mac field's action is the Save button). False: not taken.
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        guard name.isEditing else { return false }
        if k == .enter { _ = name.commit(); save(); return true }
        _ = name.key(k, modifiers: modifiers)
        return true
    }

    func apply(_ item: EasingChipItem) {
        switch item {
        case .curve(let c): source.applyEaseShape(c.shape)
        case .spring(let s): source.applySpring(s.spring)
        }
    }

    func save() {
        guard let shape = common else { return }
        let n = name.commit() ?? name.text
        name.text = ""
        onSave?(shape, n)
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        refresh()
        let bounds = CGRect(origin: .zero, size: Self.size), radius = SQMenuLayout.cornerRadius
        c.shadow(roundedRect: bounds, radius: radius, blur: 10, dy: 4, DrawColor(0, 0, 0, 0.25))
        c.fill(roundedRect: bounds, radius: radius, t.overlay)
        // The editor's content fill under the rounded top corners (the popover window clips its content on the Mac).
        let e = Self.editorFrame
        c.fill(roundedRect: e, radius: radius, t.content)
        c.fill(CGRect(x: e.minX, y: e.minY + radius, width: e.width, height: e.height - radius), t.content)
        c.saveGState(); c.clip(to: e)
        editor.draw(&c, t)
        c.restoreGState()
        c.stroke(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), radius: radius, width: 0.5, t.inkFill(0.14))
        let enabled = source.easeReading != .empty, current = common
        c.saveGState(); c.clip(to: Self.chipStrip)
        for (i, item) in chips.enumerated() {
            let f = chipFrame(i)
            guard f.maxX > 0, f.minX < Self.size.width else { continue }
            let on: Bool = if case .curve(let cv) = item { current.map { cv.shape.isApproximatelyEqual(to: $0) } == true } else { false }
            let hot = hover == .chip(i) && enabled, down = pressed == .chip(i)
            let fill = on ? t.accentTint : down ? t.fillPressed : hot ? t.fillHover : t.fill
            let box = f.insetBy(dx: 0, dy: 1)
            c.fill(roundedRect: box, radius: InspectorTokens.radius(box), fill.alpha(fill.a * (enabled ? 1 : InspectorTokens.disabledAlpha)))
            let plot = CGRect(x: f.midX - Self.thumb.width / 2, y: f.midY - Self.thumb.height / 2, width: Self.thumb.width,
                              height: Self.thumb.height).insetBy(dx: 5, dy: 4)
            let ink = on ? t.accent : t.label
            c.strokePolyline(EasingThumbnail.points(samples: item.samples(count: 32), in: plot), width: 1.5,
                             ink.alpha(ink.a * (enabled ? 1 : InspectorTokens.disabledAlpha)))
        }
        c.restoreGState()
        name.draw(&c, in: Self.nameFrame, theme: t, focused: name.isEditing)
        if !name.isEditing, name.text.isEmpty {
            c.draw("Preset name", in: Self.nameFrame.insetBy(dx: 6, dy: 0), fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3, align: .left)
        }
        InspectorDraw.button(&c, title: "Save", in: Self.saveFrame, hovering: hover == .save, pressed: pressed == .save,
                             enabled: current != nil, t)
    }

    /// The chip's tooltip (springs bake keys), the Save button's.
    public func help(at p: CGPoint) -> String? {
        switch part(at: p) {
        case .chip(let i): if case .spring = chips[i] { chips[i].name + " (bakes keys)" } else { chips[i].name }
        case .save: "Save Curve"
        default: nil
        }
    }
}
