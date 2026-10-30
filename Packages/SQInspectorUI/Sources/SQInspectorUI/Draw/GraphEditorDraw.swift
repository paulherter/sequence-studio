import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The Graph Editor on the shared toolkit: `GraphEditorView` and its toolbar translated (curves, hit test and the
/// gesture stay in `GraphEditorGeometry` / `GraphEditorGesture`; every edit goes through `EffectControlsModel`). Fills
/// the keyframe area while on: the speed curves of the selected rows in one plot, keys as small squares, handles of
/// selected keys, the hover readout, and the bottom toolbar (Fit | Snap | Steady, Smooth, Smooth In, Smooth Out | Hold,
/// Hold Ahead). Coordinates: points, y down, (0, 0) = the area's top-left.
@MainActor public final class GraphEditorDraw {
    public let model: EffectControlsModel
    public var theme = DrawTheme()
    public var size: CGSize = .zero
    /// The key menu (the lanes' menu, so both offer the same entries); set by the panel.
    var keyMenu: ((Bool) -> [SQMenuItem])?

    private var gesture: GraphEditorGesture?
    public private(set) var marquee: CGRect?
    private var escapeCancelled = false
    private var hoverPoint: CGPoint?
    private var toolbarHover: Int?

    public init(model: EffectControlsModel) { self.model = model }

    // MARK: Curves

    private var cache: (revision: Int, properties: [EffectProperty], samples: Int, curves: [GraphEditorCurve])?

    /// Sampled again only when the clip, the drawn properties or the zoom's sample count change (as the Mac cache).
    var curves: [GraphEditorCurve] {
        let n = model.graphSampleCount(pointsPerSecond: model.laneGeometry(width: size.width).pointsPerSecond)
        if let c = cache, c.revision == model.clipRevision, c.properties == model.graphEditorProperties, c.samples == n { return c.curves }
        let v = model.graphEditorCurves(samples: n)
        cache = (model.clipRevision, model.graphEditorProperties, n, v)
        return v
    }

    /// Live geometry; while a drag runs the axis only grows.
    var geometry: GraphEditorGeometry {
        let g = GraphEditorGeometry(lane: model.laneGeometry(width: size.width), height: size.height, curves: curves)
        return gesture.map { g.growing(from: $0.geometry) } ?? g
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme, g = geometry, bounds = CGRect(origin: .zero, size: size), sel = model.selection
        c.saveGState()
        c.clip(to: bounds)
        c.fill(bounds, t.lane)
        for s in g.timeTicks() {
            c.fill(CGRect(x: g.lane.x(seconds: s).rounded(), y: g.plotTop, width: 1, height: g.plotBottom - g.plotTop), t.separator)
        }
        let fs = CGFloat(DrawTheme.TypeSize.caption)
        for v in g.speedTicks() {
            let y = g.y(speed: v).rounded()
            c.fill(CGRect(x: 0, y: y, width: size.width, height: 1), t.separator)
            c.draw(ControlsNumberText.format(v, decimals: v.rounded() == v ? 0 : 1) + "\u{00D7}", at: CGPoint(x: 4, y: y + 1), fontSize: fs, t.label3)
        }
        if model.playheadInClip {
            let x = model.laneGeometry(width: size.width).x(for: model.localPlayhead).rounded()
            c.fill(CGRect(x: x - 1, y: 0, width: 2, height: max(size.height - GraphEditorGeometry.bottomInset, 0)), t.playhead)
        }
        c.fill(CGRect(x: 0, y: g.plotBottom.rounded(), width: size.width, height: 1), t.label3)
        for cv in g.curves {
            let color = t.graphCurve[cv.colorIndex % t.graphCurve.count]
            for line in g.polylines(cv) { c.strokePolyline(line, width: 1.5, color) }
        }
        for cv in g.curves {
            for h in cv.curve.handles where sel.contains(SummaryMember(property: cv.property, keyID: h.keyID)) {
                guard let k = cv.curve.keys.first(where: { $0.id == h.keyID }), let hp = g.handlePoint(cv, h) else { continue }
                c.strokeLine(from: g.keyPoint(cv, k), to: hp, width: 1, t.yellow)
                c.fill(ellipseIn: CGRect(x: hp.x - 3, y: hp.y - 3, width: 6, height: 6), t.yellow)
            }
        }
        // Plain keys: lane-colored square with a white outline; selected keys: solid white.
        for cv in g.curves {
            for k in cv.curve.keys {
                let kp = g.keyPoint(cv, k), r = CGRect(x: kp.x - 3.5, y: kp.y - 3.5, width: 7, height: 7)
                if sel.contains(SummaryMember(property: cv.property, keyID: k.id)) { c.fill(r, .white) }
                else { c.fill(r, .white); c.fill(r.insetBy(dx: 1, dy: 1), t.lane) }
            }
        }
        if g.curves.isEmpty {
            let text = SQL10n.string(model.graphShowAll ? "No animated properties" : "Select properties on the left to show their speed")
            c.draw(text, in: CGRect(x: 0, y: (g.plotTop + g.plotBottom) / 2 - 8, width: size.width, height: 16),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3, align: .center)
        }
        if let m = marquee {
            c.fill(m, t.accentTint)
            let e = m.insetBy(dx: 0.5, dy: 0.5)
            c.stroke(polygon: [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.maxX, y: e.maxY),
                               CGPoint(x: e.minX, y: e.maxY)], width: 1, t.accent)
        }
        if let text = readout(g) { drawReadout(&c, at: text.at, text: text.text) }
        drawToolbar(&c)
        c.restoreGState()
    }

    /// The handle readout while dragging or hovering a handle, else the speed of the hovered curve.
    func readout(_ g: GraphEditorGeometry) -> (at: CGPoint, text: String)? {
        if let gs = gesture, gs.moved, case .handle(let m, let side) = gs.kind, let c = g.curve(m.property),
           let h = c.curve.handles.first(where: { $0.keyID == m.keyID && $0.side == side }), let hp = g.handlePoint(c, h) {
            return (hp, GraphHandleReadout.text(title: c.title, speed: abs(h.speed), influence: h.influence, unit: c.unit))
        }
        guard gesture == nil, let p = hoverPoint, p.y < size.height - GraphEditorGeometry.toolbarHeight else { return nil }
        if case .handle(let m, let side) = g.hitTest(p, selected: model.selection), let c = g.curve(m.property),
           let h = c.curve.handles.first(where: { $0.keyID == m.keyID && $0.side == side }) {
            return (p, GraphHandleReadout.text(title: c.title, speed: h.speed * c.scale, influence: h.influence, unit: c.unit))
        }
        if let hit = g.hover(at: p), let c = g.curve(hit.property) {
            return (p, "\(model.clip?.name ?? "Clip") \u{00B7} \(c.title)\n\(ControlsNumberText.format(hit.speed, decimals: 2)) \(c.unit)/s")
        }
        return nil
    }

    private func drawReadout(_ c: inout Canvas, at p: CGPoint, text: String) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.caption), lines = text.split(separator: "\n").map(String.init)
        let w = lines.map { c.size(of: $0, fontSize: fs).width }.max() ?? 0, lh: CGFloat = 14
        var r = CGRect(x: p.x + 10, y: p.y - CGFloat(lines.count) * lh - 14, width: w + 10, height: CGFloat(lines.count) * lh + 6)
        if r.maxX > size.width { r.origin.x = p.x - r.width - 10 }
        if r.minY < 0 { r.origin.y = p.y + 12 }
        let radius = CGFloat(InspectorTokens.controlRadius)
        c.fill(roundedRect: r, radius: radius, t.overlay)
        c.stroke(roundedRect: r, radius: radius, width: 0.5, t.inkFill(0.14))
        for (i, l) in lines.enumerated() {
            c.draw(l, in: CGRect(x: r.minX + 5, y: r.minY + 3 + CGFloat(i) * lh, width: w + 2, height: lh), fontSize: fs, t.label)
        }
    }

    // MARK: Toolbar (GraphEditorToolbar)

    /// Fit, Snap, then the six eases; a gap before the groups at 1, 2, 5 and 6 (the Mac layout).
    static let easeChoices: [(KeyInterpolationChoice, String)] = [
        (.linear, EaseName.steady), (.easyEase, EaseName.smooth), (.easeIn, EaseName.smoothIn), (.easeOut, EaseName.smoothOut),
        (.hold, EaseName.hold), (.holdAhead, EaseName.holdAhead),
    ]
    private static let groupStarts: Set<Int> = [1, 2, 5, 6]
    static let toolbarSlot: CGFloat = 26

    /// Frames of the eight toolbar buttons, centered in the bottom strip.
    func toolbarFrames() -> [CGRect] {
        let h = GraphEditorGeometry.toolbarHeight, slot = Self.toolbarSlot, gap: CGFloat = 12, n = 2 + Self.easeChoices.count
        let total = CGFloat(n) * slot + CGFloat(Self.groupStarts.count) * gap
        var x = max((size.width - total) / 2, 4)
        return (0..<n).map { i in
            if Self.groupStarts.contains(i) { x += gap }
            defer { x += slot }
            return CGRect(x: x, y: size.height - h + 2, width: slot, height: h - 4)
        }
    }

    private func toolbarEnabled(_ i: Int) -> Bool {
        guard i >= 2 else { return true }
        let hasKeys = !model.selection.isEmpty
        return i == 1 + Self.easeChoices.count ? hasKeys && model.selectionTakesHoldAhead : hasKeys
    }

    public func toolbarTitle(_ i: Int) -> String { i == 0 ? "Fit" : i == 1 ? "Snap" : Self.easeChoices[i - 2].1 }

    private func runToolbar(_ i: Int) {
        guard toolbarEnabled(i) else { return }
        switch i {
        case 0: model.fitGraph()
        case 1: model.graphSnap.toggle()
        default: model.applyGraphEase(Self.easeChoices[i - 2].0)
        }
    }

    private func drawToolbar(_ c: inout Canvas) {
        let t = theme, h = GraphEditorGeometry.toolbarHeight
        c.fill(CGRect(x: 0, y: size.height - h, width: size.width, height: h), t.panel)
        c.fill(CGRect(x: 0, y: size.height - h, width: size.width, height: 1), t.separator)
        for (i, f) in toolbarFrames().enumerated() {
            let on = toolbarEnabled(i)
            if toolbarHover == i, on { c.fill(roundedRect: f, radius: CGFloat(InspectorTokens.controlRadius), t.fillHover) }
            var tint = i == 1 && model.graphSnap ? t.accent : (toolbarHover == i ? t.label : t.label2)
            if !on { tint = tint.alpha(InspectorTokens.disabledAlpha) }
            switch i {
            case 0: c.draw(icon: .moveHorizontal, at: CGPoint(x: (f.midX - 7).rounded(), y: (f.midY - 7).rounded()), size: 14, tint)
            case 1: c.draw(icon: .snap, at: CGPoint(x: (f.midX - 7).rounded(), y: (f.midY - 7).rounded()), size: 14, tint)
            default: Self.easeGlyph(&c, Self.easeChoices[i - 2].0, in: CGRect(x: f.midX - 8, y: f.midY - 6, width: 16, height: 12), tint)
            }
        }
    }

    /// The small curve glyph of an ease button (value over time: step, line, S-curves), y down.
    static func easeGlyph(_ c: inout Canvas, _ choice: KeyInterpolationChoice, in r: CGRect, _ color: DrawColor) {
        let a = CGPoint(x: r.minX + 1.5, y: r.maxY - 1.5), b = CGPoint(x: r.maxX - 1.5, y: r.minY + 1.5), w = b.x - a.x
        func bezier(_ c1: CGPoint, _ c2: CGPoint) -> [CGPoint] {
            (0...16).map { i in
                let s = CGFloat(i) / 16, u = 1 - s
                return CGPoint(x: u * u * u * a.x + 3 * u * u * s * c1.x + 3 * u * s * s * c2.x + s * s * s * b.x,
                               y: u * u * u * a.y + 3 * u * u * s * c1.y + 3 * u * s * s * c2.y + s * s * s * b.y)
            }
        }
        let line: [CGPoint]
        switch choice {
        case .hold: line = [a, CGPoint(x: b.x - 2, y: a.y), CGPoint(x: b.x - 2, y: b.y), b]
        case .holdAhead: line = [a, CGPoint(x: a.x + 2, y: a.y), CGPoint(x: a.x + 2, y: b.y), b]
        case .linear: line = [a, b]
        case .easyEase: line = bezier(CGPoint(x: a.x + w * 0.6, y: a.y), CGPoint(x: b.x - w * 0.6, y: b.y))
        case .easeIn: line = bezier(CGPoint(x: a.x + w * 0.3, y: a.y - 3), CGPoint(x: b.x - w * 0.6, y: b.y))
        default: line = bezier(CGPoint(x: a.x + w * 0.6, y: a.y), CGPoint(x: b.x - w * 0.3, y: b.y + 3))
        }
        c.strokePolyline(line, width: 1.3, color)
        for q in [a, b] { c.fill(CGRect(x: q.x - 1.5, y: q.y - 1.5, width: 3, height: 3), color) }
    }

    // MARK: Input

    private func toolbarIndex(at p: CGPoint) -> Int? { toolbarFrames().firstIndex { $0.contains(p) } }

    public func help(at p: CGPoint) -> String? { toolbarIndex(at: p).map(toolbarTitle) }

    public func mouseMoved(to p: CGPoint?) {
        hoverPoint = p
        toolbarHover = p.flatMap(toolbarIndex(at:))
    }

    public func mouseDown(at p: CGPoint, modifiers: InputModifiers) {
        escapeCancelled = false
        if p.y >= size.height - GraphEditorGeometry.toolbarHeight {
            if let i = toolbarIndex(at: p) { runToolbar(i) }
            return
        }
        let g = GraphEditorGesture(at: p, shift: modifiers.contains(.shift), geometry: geometry, selection: model.selection)
        gesture = g
        if g.selection != model.selection { model.select(Array(g.selection), extend: false) }
    }

    /// shortcut: every drag event commits at once (the Mac coalesces to one commit per display frame with
    /// `LiveDragCoalescer`); upgrade when the Windows host has a frame clock for panels.
    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers) {
        guard !escapeCancelled, var g = gesture else { return }
        let wasMoved = g.moved
        let action = g.drag(to: p, constrain: modifiers.contains(.shift))
        gesture = g
        if g.moved && !wasMoved {
            switch g.kind { case .keys, .handle: model.beginGesture(); default: break }
        }
        switch action {
        case .moveKeys(let s):
            let tol = modifiers.contains(.command) ? nil : 6 / max(g.geometry.lane.pointsPerSecond, 1e-9)   // Ctrl: no snapping
            model.moveGraphSelection(bySeconds: s, snapTolerance: tol)
        case .setHandle(let h, let side): model.setGraphHandle(h, side: side)
        case .select(let s, let rect):
            marquee = rect
            if s != model.selection { model.select(Array(s), extend: false) }
        case .nothing: break
        }
    }

    public func mouseUp(at p: CGPoint) {
        defer { gesture = nil; marquee = nil; mouseMoved(to: p) }
        if escapeCancelled { escapeCancelled = false; return }
        guard let g = gesture else { return }
        if g.moved {
            switch g.kind {
            case .keys: model.endGraphKeyMove()
            case .handle: model.endGesture()
            default: break
            }
        } else {
            let s = g.endSelection()
            if s != model.selection { model.select(Array(s), extend: false) }
        }
    }

    public var isDragging: Bool { gesture != nil }

    /// Escape drops a marquee or undoes a running drag; F / Shift-F / Ctrl-A / F9 run the editor's commands; + / - / \
    /// zoom; Delete removes the selected keys.
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        if k == .escape, let g = gesture {
            if case .marquee = g.kind {
                if g.baseSelection != model.selection { model.select(Array(g.baseSelection), extend: false) }
            } else if g.moved {
                switch g.kind {
                case .keys: _ = model.moveSelection(by: .zero); model.endGraphKeyMove()
                case .handle: model.cancelGesture()
                default: break
                }
            }
            gesture = nil; marquee = nil; escapeCancelled = true
            return true
        }
        if let sc = GraphEditorShortcut.resolve(k, modifiers: modifiers) { model.perform(sc); return true }
        if KeyframeZoomInput.key(k, modifiers: modifiers, model: model) { return true }
        if k == .delete || k == .backspace { model.deleteSelectionOrEffect(); return true }
        return false
    }

    public func scroll(at p: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: InputModifiers) -> Bool {
        let lane = model.laneGeometry(width: size.width)
        switch KeyframeZoomInput.classify(dx: dx, dy: dy, modifiers: modifiers) {
        case .zoom(let f): model.zoom(by: f, around: lane.seconds(atX: p.x)); return true
        case .pan(let pts): model.panViewport(bySeconds: -Double(pts) / max(lane.pointsPerSecond, 1e-6)); return true
        case .none: return false
        }
    }

    /// Right click: selects the key under the pointer, then the lanes' key menu.
    public func contextMenu(at p: CGPoint) -> [SQMenuItem] {
        let hit = geometry.hitTest(p, selected: model.selection)
        var onKey = false
        if case .key(let m) = hit {
            onKey = true
            if !model.selection.contains(m) { model.select([m], extend: false) }
        }
        if case .handle = hit { onKey = true }
        return keyMenu?(onKey) ?? []
    }
}
