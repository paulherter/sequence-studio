import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// Value graph of one scalar component on the shared toolkit: `KeyframeGraphView` translated (fit, hit test and the
/// gesture stay in SQUIKit's `KeyframeGraphGeometry` / `GraphGestureState`). Grid, curve, handles of selected keys,
/// small key markers, the top / bottom value and the graph kind; a gesture previews locally and calls `onEdit` once on
/// release (one undo step). Coordinates: points, y down, (0, 0) = the graph's top-left.
@MainActor public final class KeyframeGraphDraw {
    public var theme = DrawTheme()
    public var size: CGSize = .zero
    public var track = KeyframeTrack<Double>() { didSet { if gesture == nil { refit() } } }
    public var mode: GraphMode = .value { didSet { refit() } }
    public var selectedKeyIDs = Set<UUID>()
    public var playheadSeconds: Double?
    public var frameDuration = Time(1, 30)
    public var minTime = Time.zero
    public var maxTime: Time? { didSet { if gesture == nil, maxTime != oldValue { refit() } } }
    public var easingLibrary = EasingLibrary()
    public var visibleTime: ClosedRange<Double>? { didSet { if gesture == nil, visibleTime != oldValue { refit() } } }
    public var displayScale: Double = 1
    public var insets = GraphInsets()
    /// Width of the label area painted as panel (0 in Effect Controls: the left pane is the rows column's).
    public var leadingPanelWidth: CGFloat = 0

    public var onEdit: ((KeyframeTrack<Double>) -> Void)?
    public var onSelectionChange: ((Set<UUID>) -> Void)?
    public var onLibraryChange: ((EasingLibrary) -> Void)?
    public var onModeChange: ((GraphMode) -> Void)?
    public var onZoom: ((Double, Double) -> Void)?
    public var onPan: ((Double) -> Void)?
    /// Asks for a preset name (Save Curve); nil leaves the item out of the menu.
    public var onPrompt: (@MainActor (_ prompt: KeyToolPrompt, _ done: @escaping @MainActor ([String]?) -> Void) -> Void)?

    private var fit = GraphFit(time: 0...1, value: 0...1)
    private var gesture: GraphGestureState?
    private var preview: KeyframeTrack<Double>?
    public private(set) var marquee: CGRect?
    private var easeSide = EaseSide.both
    private(set) var hoverHit: GraphHit = .empty

    public init() {}

    private var shownTrack: KeyframeTrack<Double> { preview ?? track }
    func refit() {
        let range = maxTime.map { GraphMath.seconds(minTime)...max(GraphMath.seconds($0), GraphMath.seconds(minTime)) }
        fit = GraphFit.make(track: track, mode: mode, timeRange: range, visibleTime: visibleTime)
    }
    var geometry: KeyframeGraphGeometry { KeyframeGraphGeometry(size: size, insets: insets, fit: fit, mode: mode) }
    private var limits: GraphEditLimits { GraphEditLimits(frameDuration: frameDuration, minTime: minTime, maxTime: maxTime) }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let g = geometry, t = theme, bounds = CGRect(origin: .zero, size: size)
        c.saveGState()
        c.clip(to: bounds)
        c.fill(bounds, t.lane)
        if leadingPanelWidth > 0 { c.fill(CGRect(x: 0, y: 0, width: min(leadingPanelWidth, size.width), height: size.height), t.panel) }
        let plot = g.plot
        if let ph = playheadSeconds {
            let x = g.x(seconds: ph).rounded()
            if x >= leadingPanelWidth, x < size.width { c.fill(CGRect(x: x - 1, y: 0, width: 2, height: size.height), t.playhead) }
        }
        c.saveGState()
        c.clip(to: plot.insetBy(dx: -1, dy: -4))
        for v in g.gridValues(targetCount: 3) {
            c.fill(CGRect(x: plot.minX, y: g.y(value: v).rounded(), width: plot.width, height: 1), v == 0 ? t.label3 : t.separator)
        }
        let tr = shownTrack
        let curve = mode == .value ? DrawColor(hex: 0xFF9F0A) : DrawColor(hex: 0x64D2FF)     // Theme.Colors.curveX / curveY
        for seg in g.curvePolylines(track: tr) { c.strokePolyline(seg.points, width: 1.5, curve) }
        for k in tr.keys where selectedKeyIDs.contains(k.id) {
            guard let i = tr.keys.firstIndex(where: { $0.id == k.id }) else { continue }
            let kp = g.keyPoint(track: tr, index: i)
            for side in [GraphHandleSide.inSide, .outSide] {
                guard let hp = g.handlePoint(track: tr, keyID: k.id, side: side) else { continue }
                c.strokeLine(from: kp, to: hp, width: KeyframeGraphGeometry.handleLineWidth, t.accent)
                let d = KeyframeGraphGeometry.handleKnobDiameter
                c.fill(ellipseIn: CGRect(x: hp.x - d / 2, y: hp.y - d / 2, width: d, height: d), t.accent)
            }
        }
        if let p = hoverPoint(g, tr) {
            c.fill(roundedRect: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12), radius: CGFloat(DrawTheme.Radius.small), t.fillHover)
        }
        for (i, k) in KeyGlyph.glyphs(of: tr).enumerated() {
            let p = g.keyPoint(track: tr, index: i)
            c.fill(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6), selectedKeyIDs.contains(k.id) ? t.accent : t.keyframe)
        }
        c.restoreGState()
        // Axis labels: the top and bottom of the visible range and the graph kind, right-aligned left of the plot.
        let right = (leadingPanelWidth > 0 ? leadingPanelWidth : plot.minX) - 10, fs = CGFloat(DrawTheme.TypeSize.caption)
        if right > 0 {
            let hi = GraphAxisLabels.format(fit.value.upperBound, scale: displayScale), lo = GraphAxisLabels.format(fit.value.lowerBound, scale: displayScale)
            c.draw(hi, in: CGRect(x: 0, y: plot.minY - 2, width: right, height: 13), fontSize: fs, t.accent, align: .right)
            c.draw(lo, in: CGRect(x: 0, y: plot.maxY - 11, width: right, height: 13), fontSize: fs, t.accent, align: .right)
            c.draw(SQL10n.string(mode == .speed ? "Speed" : "Value"), in: CGRect(x: 0, y: size.height / 2 - 6.5, width: right, height: 13),
                   fontSize: fs, t.label3, align: .right)
        }
        if let m = marquee {
            c.fill(m, t.accentTint)
            let e = m.insetBy(dx: 0.5, dy: 0.5)
            c.stroke(polygon: [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.maxX, y: e.maxY),
                               CGPoint(x: e.minX, y: e.maxY)], width: 1, t.accent)
        }
        c.restoreGState()
    }

    private func hoverPoint(_ g: KeyframeGraphGeometry, _ t: KeyframeTrack<Double>) -> CGPoint? {
        guard gesture == nil else { return nil }
        switch hoverHit {
        case .key(let id): return t.keys.firstIndex { $0.id == id }.map { g.keyPoint(track: t, index: $0) }
        case .handle(let id, let side): return g.handlePoint(track: t, keyID: id, side: side)
        case .segment, .empty: return nil
        }
    }

    // MARK: Mouse

    public func mouseMoved(to p: CGPoint?) {
        guard gesture == nil else { return }
        guard let p else { hoverHit = .empty; return }
        let h = geometry.hitTest(p, track: track, selected: selectedKeyIDs)
        switch h { case .key, .handle: hoverHit = h; case .segment, .empty: hoverHit = .empty }
    }

    public func mouseDown(at p: CGPoint, shift: Bool) {
        refit()
        gesture = GraphGestureState(at: p, shift: shift, geometry: geometry, track: track, selection: selectedKeyIDs, limits: limits)
        apply(gesture!.current)
    }

    public func mouseDragged(to p: CGPoint, shift: Bool) {
        if let r = gesture?.drag(to: p, free: shift) { apply(r) }
    }

    public func mouseUp(at p: CGPoint) {
        guard var g = gesture else { return }
        let r = g.end(at: p)
        gesture = nil; preview = nil; marquee = nil
        setSelection(r.selection)
        if r.commit { track = r.track; onEdit?(r.track) } else { refit() }
        mouseMoved(to: p)
    }

    public var isDragging: Bool { gesture != nil }

    private func apply(_ r: GraphGestureState.Result) {
        preview = r.track == track ? nil : r.track
        marquee = r.marquee
        setSelection(r.selection)
    }

    private func setSelection(_ s: Set<UUID>) {
        guard s != selectedKeyIDs else { return }
        selectedKeyIDs = s
        onSelectionChange?(s)
    }

    /// Wheel (KeyframeZoomInput rules): Option / Ctrl zooms around the pointer, horizontal pans.
    public func scroll(at p: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: InputModifiers) -> Bool {
        switch KeyframeZoomInput.classify(dx: dx, dy: dy, modifiers: modifiers) {
        case .zoom(let f): onZoom?(f, geometry.seconds(atX: p.x)); return true
        case .pan(let pts): onPan?(-Double(pts) / max(geometry.pointsPerSecond, 1e-6)); return true
        case .none: return false
        }
    }

    // MARK: Easing menu

    /// Right click: selects the key under the pointer (if not selected) and returns the easing menu.
    public func contextMenu(at p: CGPoint) -> [SQMenuItem] {
        refit()
        if case .key(let id) = geometry.hitTest(p, track: track, selected: selectedKeyIDs), !selectedKeyIDs.contains(id) {
            setSelection([id])
        }
        return makeEasingItems()
    }

    /// Rows: graph mode, side choice (applies to in / out / both), built-in curves, user presets, Save Curve.
    public func makeEasingItems() -> [SQMenuItem] {
        let spec = EasingMenuSpec(library: easingLibrary, side: easeSide, hasSelection: !selectedKeyIDs.isEmpty)
        var items: [SQMenuItem] = []
        for (m, title) in [(GraphMode.speed, "Speed"), (.value, "Value")] {
            items.append(SQMenuItem(title: title, isChecked: mode == m) { [weak self] in self?.onModeChange?(m) })
        }
        items.append(.separator)
        for entry in spec.entries {
            switch entry {
            case .header(let title): items.append(.header(title))
            case .side(let s, let title, let checked):
                items.append(SQMenuItem(title: title, isChecked: checked) { [weak self] in self?.easeSide = s })
            case .curve(let c, let enabled):
                items.append(SQMenuItem(title: EasingMenuSpec.title(of: c), isEnabled: enabled) { [weak self] in self?.applyEasingCurve(c) })
            case .separator: items.append(.separator)
            case .saveCurve(let enabled):
                guard onPrompt != nil else { continue }
                items.append(SQMenuItem(title: "Save as preset\u{2026}", isEnabled: enabled) { [weak self] in self?.saveSelectedCurve() })
            }
        }
        return items
    }

    private func applyEasingCurve(_ c: EasingCurve) {
        guard !selectedKeyIDs.isEmpty else { return }
        var t = track
        t.apply(c, to: selectedKeyIDs, side: easeSide)
        guard t != track else { return }
        track = t
        onEdit?(t)
    }

    private func saveSelectedCurve() {
        guard let key = track.keys.first(where: { selectedKeyIDs.contains($0.id) }), let ask = onPrompt else { return }
        ask(.saveCurve) { [weak self] texts in
            guard let self, let name = texts?.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            easingLibrary.saveCurve(from: key, name: name)
            onLibraryChange?(easingLibrary)
        }
    }
}
