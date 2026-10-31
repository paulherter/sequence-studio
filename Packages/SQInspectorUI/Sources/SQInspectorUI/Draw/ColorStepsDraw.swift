import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The Steps panel (the Pro grade's Color Graph) on the shared toolkit: `ColorStepsGraphView` translated. The start
/// page (Start empty / Start from Simple grade), the dotted well with In, LUT slots, Steps, mixers and wires, and the
/// footer (hint, Tidy up, Fit, count). A click selects (Command adds, Shift toggles), a double-click renames, the eye
/// bypasses, a drag moves the Step (onto a wire inserts it, Shift-drag takes it off its wires), a drag between dots
/// wires, a drag on empty canvas selects by rectangle; scroll pans, Command- or Option-scroll zooms. Geometry, hits and
/// drops are the shared `StepsCanvas`; menus are `ColorGraphMenus`. Coordinates: points, y down, (0, 0) = top-left.
@MainActor public final class ColorStepsDraw {
    public let controller: ColorGradeController
    public var theme = DrawTheme()
    public var size = CGSize(width: 480, height: 300)
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// The host's .cube / .3dl chooser (nil = Choose File… is disabled).
    public var chooseLUTFile: (@MainActor (@escaping @MainActor (String?) -> Void) -> Void)?
    /// The host's one-file chooser for Import Color Decision… (nil = the item is disabled) and its message sink.
    public var chooseDecisionFile: (@MainActor (@escaping @MainActor (URL?) -> Void) -> Void)?
    public var tellUser: (@MainActor (String, String) -> Void)?
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    public init(controller: ColorGradeController) { self.controller = controller }

    var model: ColorInspectorModel? { controller.model }

    static let footer: CGFloat = 28
    static let inset = CGFloat(DrawTheme.Spacing.sm)
    static let dotPitch: CGFloat = 18
    static let startDot: CGFloat = 7
    static let startWire: CGFloat = 80
    static let startRise: CGFloat = 40

    private(set) var canvas = StepsCanvas()
    private var lastFit = CGSize.zero

    var well: CGRect {
        CGRect(x: Self.inset, y: Self.inset, width: max(size.width - 2 * Self.inset, 0),
               height: max(size.height - Self.inset - Self.footer, 0))
    }
    var offersStart: Bool { model != nil && model?.graph == nil }
    var showsCanvas: Bool { !(model?.graph?.steps.isEmpty ?? true) && !offersStart }

    var menus: ColorGraphMenus? {
        guard let model else { return nil }
        var m = ColorGraphMenus(model: model, tidyUp: { [weak self] in self?.tidyUp() })
        m.chooseLUTFile = chooseLUTFile
        m.rename = { [weak self] id in self?.beginRename(id) }
        if let choose = chooseDecisionFile, let tell = tellUser { m.importDecision = m.makeDecisionImport(choose: choose, tell: tell) }
        return m
    }

    /// Add Step's kinds for the strip's plus button (nil while there is no graph to add to).
    public func addMenuItems() -> [SQMenuItem]? { model?.graph == nil ? nil : menus?.addMenuItems() }

    /// Feeds the canvas from the graph (ColorStepsGraphView.refresh) and fits the view until the user moves it.
    func refresh(measure: (String) -> CGFloat = { CGFloat($0.count) * 6.5 }) {
        let g = model?.graph
        canvas.links = g?.links
        canvas.keyLinks = g?.keyLinks ?? []
        canvas.mixerPositions = Dictionary(uniqueKeysWithValues: (g?.steps ?? []).compactMap { s in s.mixerPosition.map { (s.id, $0) } })
        canvas.columns = g?.columns.map { $0.map(\.id) } ?? []
        canvas.positions = Dictionary(uniqueKeysWithValues: (g?.steps ?? []).compactMap { s in s.position.map { (s.id, $0) } })
        canvas.inSlotWidth = StepsCanvas.slotWidth(textWidth: measure(model?.graphLUTChoice(.input)?.name ?? "LUT"))
        canvas.outSlotWidth = StepsCanvas.slotWidth(textWidth: measure(model?.graphLUTChoice(.output)?.name ?? "LUT"))
        if canvas.drag == nil, !canvas.userView { canvas.fit(in: well.size, margin: CGFloat(DrawTheme.Spacing.lg)) }
        if let id = model?.renamingStep {
            model?.renamingStep = nil
            beginRename(id)
        }
    }

    public func tidyUp() {
        canvas.userView = false
        model?.tidyUpSteps()
        refresh()
    }
    public func fitView() {
        canvas.userView = false
        refresh()
    }

    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - well.minX, y: p.y - well.minY) }

    // MARK: Footer and start buttons

    enum Button: Hashable { case startEmpty, startFromSimple, tidy, fit }

    func buttonFrames(_ c: Canvas? = nil) -> [Button: CGRect] {
        func width(_ s: String) -> CGFloat {
            c.map { InspectorDraw.buttonWidth($0, title: SQL10n.string(s)) } ?? CGFloat(s.count) * 7 + 22
        }
        var out: [Button: CGRect] = [:]
        let h = ControlsGrid.controlHeight
        if offersStart {
            let w = well
            let a = width("Start empty"), b = width("Start from Simple grade")
            let y = (w.midY - Self.startRise + StepsCanvas.node.height + 60).rounded()
            let x = (w.midX - (a + b + CGFloat(DrawTheme.Spacing.sm)) / 2).rounded()
            out[.startEmpty] = CGRect(x: x, y: y, width: a, height: h)
            out[.startFromSimple] = CGRect(x: x + a + CGFloat(DrawTheme.Spacing.sm), y: y, width: b, height: h)
        } else if showsCanvas {
            let fy = size.height - Self.footer + ((Self.footer - h) / 2).rounded()
            let sum = c.map { $0.size(of: summary, fontSize: CGFloat(DrawTheme.TypeSize.caption)).width } ?? CGFloat(summary.count) * 6
            var rx = size.width - CGFloat(DrawTheme.Spacing.md) - ceil(sum) - CGFloat(DrawTheme.Spacing.md)
            let fw = width("Fit"), tw = width("Tidy up")
            rx -= fw
            out[.fit] = CGRect(x: rx, y: fy, width: fw, height: h)
            rx -= CGFloat(DrawTheme.Spacing.xs) + tw
            out[.tidy] = CGRect(x: rx, y: fy, width: tw, height: h)
        }
        return out
    }

    var summary: String {
        let g = model?.graph
        let n = g?.steps.count ?? 0, s = g?.columns.count ?? 0
        return SQL10n.string("\(n) \(n == 1 ? "step" : "steps"), \(s) in series")
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        measure = (c.atlas, c.scale)
        renameRect = nil
        refresh(measure: { [c] s in c.size(of: s, fontSize: CGFloat(DrawTheme.TypeSize.caption)).width })
        let t = theme, w = well, cap = CGFloat(DrawTheme.TypeSize.caption)
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        c.fill(roundedRect: w, radius: CGFloat(DrawTheme.Radius.panel), t.content)
        c.saveGState()
        c.clip(to: w)
        drawGrid(&c, w)
        if model == nil {
            c.draw(SQL10n.string("No Pro grade here"), in: CGRect(x: w.minX, y: w.midY - 22, width: w.width, height: 20),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2, align: .center)
            c.draw(SQL10n.string("Pick a clip, then choose Pro in the Color panel."), in: CGRect(x: w.minX, y: w.midY, width: w.width, height: 18),
                   fontSize: cap, t.label3, align: .center)
        } else if offersStart {
            drawStart(&c, w)
        } else if showsCanvas {
            c.translateBy(x: w.minX, y: w.minY)
            drawGraph(&c)
        }
        c.restoreGState()
        for (b, f) in buttonFrames(c) {
            let title = switch b { case .startEmpty: "Start empty"; case .startFromSimple: "Start from Simple grade"; case .tidy: "Tidy up"; case .fit: "Fit" }
            InspectorDraw.button(&c, title: SQL10n.string(title), in: f, hovering: hoverButton == b, pressed: pressedButton == b,
                                 enabled: true, accent: b == .startEmpty, t)
        }
        guard showsCanvas else { return }
        let fy = size.height - Self.footer
        let hint = SQL10n.string("Drag a step to move it, onto a wire to insert it. Drag between dots to wire. Scroll to pan, Command-scroll to zoom.")
        let right = buttonFrames(c)[.tidy]?.minX ?? size.width
        c.draw(hint, in: CGRect(x: CGFloat(DrawTheme.Spacing.md), y: fy, width: max(right - CGFloat(DrawTheme.Spacing.md) * 2, 0), height: Self.footer),
               fontSize: cap, t.label3)
        c.draw(summary, in: CGRect(x: 0, y: fy, width: size.width - CGFloat(DrawTheme.Spacing.md), height: Self.footer), fontSize: cap, t.label3, align: .right)
    }

    private func drawGrid(_ c: inout Canvas, _ w: CGRect) {
        let pitch = Self.dotPitch * (showsCanvas ? max(canvas.zoom, 0.6) : 1)
        let ox = (showsCanvas ? canvas.pan.x : 0).truncatingRemainder(dividingBy: pitch)
        let oy = (showsCanvas ? canvas.pan.y : 0).truncatingRemainder(dividingBy: pitch)
        var y = w.minY + pitch / 2 + oy
        while y < w.maxY {
            var x = w.minX + pitch / 2 + ox
            while x < w.maxX { c.fill(CGRect(x: x.rounded(), y: y.rounded(), width: 1, height: 1), theme.separator); x += pitch }
            y += pitch
        }
    }

    private func drawStart(_ c: inout Canvas, _ w: CGRect) {
        let t = theme, cap = CGFloat(DrawTheme.TypeSize.caption)
        let iw = c.size(of: "In", fontSize: cap).width, ow = c.size(of: "Out", fontSize: cap).width
        let d = Self.startDot, gap: CGFloat = 4
        let width = d + gap + iw + Self.startWire + ow + gap + d
        var x = (w.midX - width / 2).rounded()
        let cy = (w.midY - Self.startRise).rounded() + StepsCanvas.node.height / 2
        c.fill(ellipseIn: CGRect(x: x, y: cy - d / 2, width: d, height: d), t.label3)
        x += d + gap
        c.draw("In", in: CGRect(x: x, y: cy - 8, width: iw + 2, height: 16), fontSize: cap, t.label3)
        x += iw
        c.fill(CGRect(x: x + 4, y: (cy - 0.5).rounded(), width: Self.startWire - 8, height: 1), t.separator)
        x += Self.startWire
        c.draw("Out", in: CGRect(x: x, y: cy - 8, width: ow + 2, height: 16), fontSize: cap, t.label3)
        x += ow + gap
        c.fill(ellipseIn: CGRect(x: x, y: cy - d / 2, width: d, height: d), t.label3)
        var y = cy + StepsCanvas.node.height / 2 + CGFloat(DrawTheme.Spacing.sm)
        c.draw(SQL10n.string("No Pro grade on this clip yet"), in: CGRect(x: w.minX, y: y, width: w.width, height: 18),
               fontSize: CGFloat(DrawTheme.TypeSize.body), t.label, align: .center)
        y += 22
        c.draw(SQL10n.string("The first step adds a Color Graph effect. Your Simple grade stays as it is."),
               in: CGRect(x: w.minX, y: y, width: w.width, height: 16), fontSize: cap, t.label3, align: .center)
    }

    private func wirePoints(_ w: StepsCanvas.Wire) -> [CGPoint] {
        let v = StepsCanvas.Wire(from: canvas.viewPoint(w.from), to: canvas.viewPoint(w.to), gap: w.gap, link: w.link)
        return (0...24).map { v.point(CGFloat($0) / 24) }
    }

    private func drawGraph(_ c: inout Canvas) {
        guard let g = model?.graph else { return }
        let t = theme, l = canvas.layout(), cap = CGFloat(DrawTheme.TypeSize.caption)
        let lifted = wireDrag?.replacing
        for w in canvas.wires() where w.link == nil || w.link != lifted { c.strokePolyline(wirePoints(w), width: 1.5, t.fillHover) }
        for w in canvas.keyWires() where w.link != lifted { c.strokeDashed(wirePoints(w), width: 1, on: 3, off: 3, t.label3) }
        for w in canvas.previewWires() { c.strokePolyline(wirePoints(w), width: 2, t.accent) }
        let byID = Dictionary(uniqueKeysWithValues: g.steps.map { ($0.id, $0) })
        let r0 = CGFloat(DrawTheme.Radius.small)
        for (col, head, r) in canvas.mixers(l) {
            let v = canvas.viewRect(r)
            let layer = g.columns[col].dropFirst().contains { $0.kind == .layer }
            c.fill(roundedRect: v, radius: r0, t.fill)
            if layer { c.strokeDashed(roundedRect: v, radius: r0, width: 1, on: 3, off: 3, t.label3) }
            else { c.stroke(roundedRect: v, radius: r0, width: 1, t.label3) }
            if head == model?.selectedMixer { c.stroke(roundedRect: v.insetBy(dx: -1, dy: -1), radius: r0 + 1, width: 2, t.accent) }
            c.draw(icon: layer ? .stack : .plus, at: CGPoint(x: v.midX - 5, y: v.midY - 5), size: 10, t.label2)
            dots(&c, v)
        }
        slot(&c, model?.graphLUTChoice(.input)?.name, canvas.viewRect(l.inSlot))
        slot(&c, model?.graphLUTChoice(.output)?.name, canvas.viewRect(l.outSlot))
        endpoint(&c, "In", canvas.viewRect(l.inPill), dotFirst: true)
        endpoint(&c, "Out", canvas.viewRect(l.outPill), dotFirst: false)
        let order = g.columns.flatMap { $0 }.map(\.id)
        var number: [UUID: Int] = [:]
        for (i, id) in order.enumerated() { number[id] = i + 1 }
        let keyOuts = Set(g.keyLinks.compactMap { $0.from.stepID }), keyIns = Set(g.keyLinks.map(\.to))
        let dragged = canvas.drag?.id
        for id in l.order where id != dragged { if let s = byID[id], let r = l.rects[id] { node(&c, s, number[id] ?? 0, canvas.viewRect(r), keyIn: keyIns.contains(.step(id)), keyOut: keyOuts.contains(id)) } }
        if let id = dragged, let s = byID[id], let r = l.rects[id] { node(&c, s, number[id] ?? 0, canvas.viewRect(r), keyIn: keyIns.contains(.step(id)), keyOut: keyOuts.contains(id)) }
        if let f = refusedFlash, clock() < f.until,
           let fc = (f.key ? canvas.keyDotCenter(f.port, output: false, l) : canvas.dotCenter(f.port, output: false, l)) {
            let b = canvas.viewPoint(fc)
            c.stroke(ellipseIn: CGRect(x: b.x - 6, y: b.y - 6, width: 12, height: 12), width: 2, t.red)
        }
        if let w = wireDrag { drawWireDrag(&c, w, l) }
        if let m = marquee {
            c.fill(m.rect, t.accent.alpha(0.12))
            c.stroke(polygon: [CGPoint(x: m.rect.minX, y: m.rect.minY), CGPoint(x: m.rect.maxX, y: m.rect.minY),
                               CGPoint(x: m.rect.maxX, y: m.rect.maxY), CGPoint(x: m.rect.minX, y: m.rect.maxY)], width: 1, t.accent)
        }
        if let h = hoverInsert, canvas.drag == nil, let r = canvas.insertButtons(l).first(where: { $0.0 == h })?.1 {
            c.fill(ellipseIn: r, t.fillPressed)
            c.draw(icon: .plus, at: CGPoint(x: r.midX - 4, y: r.midY - 4), size: 8, t.label)
        }
        _ = cap
    }

    private func dots(_ c: inout Canvas, _ r: CGRect, highlight: Bool = false) {
        let d = StepsCanvas.dotSize
        for x in [r.minX, r.maxX] { c.fill(ellipseIn: CGRect(x: x - d / 2, y: r.midY - d / 2, width: d, height: d), highlight ? theme.accent : theme.label2) }
    }

    private func slot(_ c: inout Canvas, _ name: String?, _ r: CGRect) {
        let t = theme, rr = CGFloat(DrawTheme.Radius.small)
        let f = r.insetBy(dx: 0.5, dy: 0.5)
        if name != nil {
            c.fill(roundedRect: f, radius: rr, t.fill)
            c.stroke(roundedRect: f, radius: rr, width: 1, t.accent)
        } else {
            c.strokeDashed(roundedRect: f, radius: rr, width: 1, on: 3, off: 3, t.label3)
        }
        c.draw(SQL10n.string(name ?? "LUT"), in: r.insetBy(dx: 3, dy: 0), fontSize: CGFloat(DrawTheme.TypeSize.caption),
               name != nil ? t.label : t.label3, align: .center)
        dots(&c, r)
    }

    private func endpoint(_ c: inout Canvas, _ s: String, _ r: CGRect, dotFirst: Bool) {
        let d = Self.startDot, gap: CGFloat = 4, cap = CGFloat(DrawTheme.TypeSize.caption)
        let tw = c.size(of: s, fontSize: cap).width
        let dotX = dotFirst ? r.maxX - d / 2 : r.minX - d / 2
        let textX = dotFirst ? dotX - gap - tw : dotX + d + gap
        c.fill(ellipseIn: CGRect(x: dotX, y: (r.midY - d / 2).rounded(), width: d, height: d), theme.label3)
        c.draw(SQL10n.string(s), in: CGRect(x: textX, y: r.midY - 8, width: tw + 2, height: 16), fontSize: cap, theme.label3)
    }

    private func node(_ c: inout Canvas, _ s: ColorStep, _ number: Int, _ r: CGRect, keyIn: Bool, keyOut: Bool) {
        let t = theme, rr = CGFloat(DrawTheme.Radius.small), cap = CGFloat(DrawTheme.TypeSize.caption)
        let sel = model?.selectedSteps.contains(s.id) == true || model?.selectedStep == s.id
        if s.enabled {
            c.fill(roundedRect: r, radius: rr, sel ? t.fillPressed : (s.id == hoverStep ? t.fillHover : t.fill))
        } else {
            c.stroke(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), radius: rr, width: 1, t.separator)
        }
        if s.kind == .layer { c.strokeDashed(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), radius: rr, width: 1, on: 3, off: 3, t.label3) }
        if sel { c.stroke(roundedRect: r.insetBy(dx: 1, dy: 1), radius: rr - 1, width: 2, t.accent) }
        dots(&c, r)
        let d = StepsCanvas.dotSize, k = StepsCanvas.keyDots(r), scale = r.width / StepsCanvas.node.width
        let pts = [CGPoint(x: r.minX + (k.input.x - r.minX) * scale, y: r.maxY), CGPoint(x: r.maxX - (r.maxX - k.output.x) * scale, y: r.maxY)]
        for (p, used) in zip(pts, [keyIn, keyOut]) {
            let o = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            c.fill(ellipseIn: o, used ? t.label2 : t.content)
            c.stroke(ellipseIn: o, width: 1, t.label3)
        }
        guard r.height >= 30 else { return }
        let pad = CGFloat(DrawTheme.Spacing.sm)
        let eye = StepsCanvas.eyeRect(r)
        if renaming?.id == s.id, var f = renaming?.field {
            f.alignment = .left
            let fr = renameFrame(r)
            renameRect = fr
            f.draw(&c, in: fr, theme: t, focused: true)
        } else {
            let nameRect = CGRect(x: r.minX + pad, y: r.minY + 4, width: max(eye.minX - r.minX - pad, 0), height: 16)
            c.draw(SQL10n.string(s.label), in: nameRect, fontSize: cap, s.enabled ? t.label : t.label3)
            if !s.enabled {
                let w = min(c.size(of: s.label, fontSize: cap).width, nameRect.width)
                c.fill(CGRect(x: nameRect.minX, y: nameRect.midY.rounded(), width: w, height: 1), t.label3)
            }
        }
        c.draw(icon: s.enabled ? .eye : .eyeOff, at: CGPoint(x: eye.minX + 3, y: eye.midY - 5), size: 10, s.enabled ? t.label2 : t.label3)
        let by = r.maxY - 6 - 12
        let num = String(format: "%02d", number)
        c.draw(num, at: CGPoint(x: r.minX + pad, y: by), fontSize: cap, t.label3)
        var x = r.minX + pad + c.size(of: num, fontSize: cap).width + 4
        let mix = s.mix < 100 ? "\(Int(s.mix.rounded()))%" : nil
        let limit = r.maxX - 4 - (mix.map { c.size(of: $0, fontSize: cap).width + CGFloat(DrawTheme.Spacing.xs) } ?? 0)
        let badge = s.enabled ? t.label2 : t.label3
        let badges: [(Bool, SQIcon)] = [(!s.primaries.isNeutral, .slidersVertical), (!(s.curves.isNeutral && s.hueCurves.isNeutral), .curve),
                                        (s.qualifier != nil, .eyedropper), (s.window != nil, .circleDashed), (s.lut != nil, .grid3)]
        for (on, icon) in badges where on {
            guard x + 9 <= limit else { break }
            c.draw(icon: icon, at: CGPoint(x: x, y: by + 1), size: 9, badge)
            x += 9 + CGFloat(DrawTheme.Spacing.xs)
        }
        if let mix { c.draw(mix, at: CGPoint(x: r.maxX - pad - c.size(of: mix, fontSize: cap).width, y: by), fontSize: cap, t.label2) }
    }

    private func drawWireDrag(_ c: inout Canvas, _ w: WireDrag, _ l: StepsCanvas.Layout) {
        let start = w.isKey ? w.from.stepID.flatMap { canvas.keyDotCenter(.step($0), output: true, l) } : canvas.dotCenter(w.from, output: true, l)
        guard let s = start else { return }
        let a = canvas.viewPoint(s)
        let color = w.refused ? theme.red : theme.accent
        if let tgt = w.target, let tc = (w.isKey ? canvas.keyDotCenter(tgt, output: false, l) : canvas.dotCenter(tgt, output: false, l)) {
            let b = canvas.viewPoint(tc)
            c.stroke(ellipseIn: CGRect(x: b.x - 6, y: b.y - 6, width: 12, height: 12), width: 2, color)
        }
        let wire = StepsCanvas.Wire(from: a, to: w.point, gap: -1, link: nil)
        let pts = (0...24).map { wire.point(CGFloat($0) / 24) }
        if w.isKey { c.strokeDashed(pts, width: 2, on: 3, off: 3, color) } else { c.strokePolyline(pts, width: 2, color) }
    }

    private func renameFrame(_ node: CGRect) -> CGRect {
        let eye = StepsCanvas.eyeRect(node)
        return CGRect(x: node.minX + 2, y: node.minY + 3, width: max(eye.minX - node.minX - 2, 40), height: 18)
    }

    // MARK: Pointer

    struct WireDrag {
        var from: StepsPort
        var point: CGPoint
        var target: StepsPort?
        var refused = false
        var isKey = false
        var replacing: GraphLink?
    }
    struct Marquee {
        var start: CGPoint, current: CGPoint, base: Set<UUID>
        var rect: CGRect {
            CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
        }
    }
    private(set) var wireDrag: WireDrag?
    /// A refused drop keeps its target ringed in red until `until` (the Mac `refusedFlash`, 0.7 s); the wire snapped back.
    private(set) var refusedFlash: (port: StepsPort, key: Bool, until: Double)?
    static let refusedFlashSeconds = 0.7
    /// The red ring of a refused drop is still up (hosts that redraw on demand keep drawing until it ends).
    public var isFlashing: Bool { refusedFlash.map { clock() < $0.until } ?? false }
    private(set) var marquee: Marquee?
    private var hoverStep: UUID?
    private var hoverInsert: UUID?
    private var hoverButton: Button?
    private var pressedButton: Button?
    private var collapseOnClick: UUID?
    private var toggleOnClick: UUID?
    private var counter = ClickCounter()
    private(set) var renaming: (id: UUID, field: TextFieldControl)?
    /// The open rename field's frame as last drawn (panel points) and the atlas it measured with: a press inside places
    /// the caret, the pointer over it is the I-beam (the Mac NSTextField).
    private(set) var renameRect: CGRect?
    private var measure: (atlas: GlyphAtlas?, scale: Float) = (nil, 1)

    func hit(at p: CGPoint) -> StepsCanvas.Hit? {
        guard showsCanvas, well.contains(p) else { return nil }
        return canvas.hit(at: local(p))
    }

    func button(at p: CGPoint) -> Button? { buttonFrames().first { $0.value.contains(p) }?.key }

    /// The tip under the pointer (HostHover): the footer buttons, a Step's full name, its eye, the connector dots,
    /// the insert buttons, the mixers and the graph's In / Out LUT slots (the Mac layer list's LUT chip tips).
    public func help(at p: CGPoint) -> String? {
        if let b = button(at: p) {
            return switch b {
            case .startEmpty: SQL10n.string("Start a Color Graph with one empty Step")
            case .startFromSimple: SQL10n.string("Start a Color Graph from the values of the Simple grade")
            case .tidy: SQL10n.string("Line the Steps up in their columns")
            case .fit: SQL10n.string("Show the whole graph")
            }
        }
        guard let h = hit(at: p) else { return nil }
        func step(_ id: UUID) -> ColorStep? { model?.graph?.steps.first { $0.id == id } }
        switch h {
        case .step(let id): return step(id).map { SQL10n.string($0.label) }
        case .eye(let id): return step(id).map { SQL10n.string($0.enabled ? "Turn this Step off" : "Turn this Step on") }
        case .insert: return SQL10n.string("Insert a Step here")
        case .mixer: return SQL10n.string("Mixer: joins the Steps of its column")
        case .dotOut, .keyOut: return SQL10n.string("Drag to an input to wire")
        case .dotIn, .keyIn: return SQL10n.string("Drag the wire away to move or remove it")
        case .input: return SQL10n.format("In LUT: %@", SQL10n.string(model?.graphLUTChoice(.input)?.name ?? "None (built-in conversion)"))
        case .output: return SQL10n.format("Out LUT: %@", SQL10n.string(model?.graphLUTChoice(.output)?.name ?? "None"))
        }
    }

    public func mouseMoved(to p: CGPoint?) {
        if renaming != nil, let p, renameRect?.contains(p) == true { HostHover.current.request(.iBeam) }
        guard canvas.drag == nil, wireDrag == nil, marquee == nil else { return }
        hoverButton = p.flatMap(button(at:))
        let h = p.flatMap(hit(at:))
        if case .insert(let id)? = h { hoverInsert = id } else { hoverInsert = nil }
        switch h { case .step(let id)?, .eye(let id)?: hoverStep = id; default: hoverStep = nil }
    }

    /// ColorStepsGraphView.scrollWheel / magnify: the host gesture's raw `scrollingDelta` when there is one.
    public func scroll(at p: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: InputModifiers) {
        guard showsCanvas else { return }
        var dx = dx, dy = dy
        if let g = ScrollGesture.published {
            switch g.kind {
            case .magnify(let m): canvas.zoomBy(1 + CGFloat(m), at: local(p)); return
            case .smartMagnify: return
            case .scroll: dx = CGFloat(g.deltaX); dy = CGFloat(g.deltaY)
            }
        }
        if modifiers.contains(.command) || modifiers.contains(.option) {
            canvas.zoomBy(exp(dy * 0.01), at: local(p))
        } else {
            canvas.panBy(CGSize(width: dx, height: dy))
        }
    }

    public func mouseDown(at p: CGPoint, modifiers: InputModifiers = [], clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        if var r = renaming, let fr = renameRect, fr.contains(p), !modifiers.contains(.secondary) {
            // Inside the open field: the caret goes under the pointer, the field stays open.
            let c = Canvas(width: 0, height: 0, atlas: measure.atlas, scale: measure.scale)
            r.field.alignment = .left
            r.field.mouseDown(caret: r.field.caretIndex(c, x: p.x, in: fr), clickCount: n)
            renaming = r
            return
        }
        if renaming != nil { endRename(commit: true) }
        refusedFlash = nil
        if modifiers.contains(.secondary) { rightClick(at: p); return }
        if let b = button(at: p) { pressedButton = b; return }
        guard let model else { return }
        let shift = modifiers.contains(.shift), command = modifiers.contains(.command)
        let q = local(p)
        switch hit(at: p) {
        case .dotOut(let port)?:
            model.selectedMixer = nil
            wireDrag = WireDrag(from: port, point: q)
        case .dotIn(let port)?:
            if let k = canvas.wire(into: port) { wireDrag = WireDrag(from: k.from, point: q, replacing: k) }
        case .keyOut(let id)?:
            wireDrag = WireDrag(from: .step(id), point: q, isKey: true)
        case .keyIn(let port)?:
            if let k = canvas.keyLinks.first(where: { $0.to == port }) { wireDrag = WireDrag(from: k.from, point: q, isKey: true, replacing: k) }
        case .mixer(let head)?:
            model.selectedMixer = head
            canvas.beginMixerDrag(head, at: q)
        case .input?: menu(menus?.lutItems(.graphInput), at: p)
        case .output?: menu(menus?.lutItems(.graphOutput), at: p)
        case .eye(let id)?:
            if let s = model.step(id) { model.setStepEnabled(id, !s.enabled) }
        case .insert(let id)?: menu(menus?.insertMenuItems(after: id), at: p)
        case .step(let id)?:
            model.selectedMixer = nil
            if n >= 2, !shift, !command { model.selectStep(id); beginRename(id); return }
            let set = model.selectedSteps
            if command {
                model.selectStep(id, extend: true)
            } else if shift {
                toggleOnClick = id
                if !set.contains(id) { model.selectStep(id) }
            } else if set.contains(id), set.count > 1 {
                collapseOnClick = id
                model.selectedStep = id
            } else {
                model.selectStep(id)
            }
            let group = model.selectedSteps.contains(id) ? model.selectedSteps : []
            canvas.beginDrag(id, at: q, with: shift ? [] : group, extract: shift)
        case nil:
            guard showsCanvas, well.contains(p) else { return }
            model.selectedMixer = nil
            marquee = Marquee(start: q, current: q, base: shift || command ? model.selectedSteps : [])
        }
    }

    private func aim(_ w: WireDrag, at q: CGPoint) -> (StepsPort?, Bool) {
        var target: StepsPort?
        if w.isKey {
            switch canvas.hit(at: q) {
            case .keyIn(let port)?: target = port
            case .step(let id)?, .eye(let id)?: target = .step(id)
            case .mixer(let head)?: target = .mixer(head)
            default: target = nil
            }
        } else {
            target = canvas.inputPort(at: q)
        }
        guard let t = target, var g = model?.graph else { return (nil, false) }
        if let k = w.replacing { if w.isKey { g.disconnectKey(k) } else { g.disconnect(k) } }
        let why = w.isKey ? w.from.stepID.flatMap { g.keyRefusal(from: $0, to: t) } : g.refusal(from: w.from, to: t)
        return (t, why != nil)
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        let q = local(p)
        if var w = wireDrag {
            w.point = q
            (w.target, w.refused) = aim(w, at: q)
            wireDrag = w
        } else if var m = marquee {
            m.current = q
            marquee = m
            model?.selectSteps(canvas.steps(in: m.rect).union(m.base))
        } else if canvas.drag != nil {
            canvas.continueDrag(to: q)
            if canvas.drag?.moved == true { collapseOnClick = nil; toggleOnClick = nil }
        }
    }

    public func mouseUp(at p: CGPoint) {
        defer { mouseMoved(to: p) }
        if let b = pressedButton {
            pressedButton = nil
            guard button(at: p) == b else { return }
            switch b {
            case .startEmpty: model?.startEmptyGraph()
            case .startFromSimple: model?.startFromSimple()
            case .tidy: tidyUp()
            case .fit: fitView()
            }
            return
        }
        if let w = wireDrag { wireDrag = nil; finish(w); return }
        if marquee != nil { marquee = nil; return }
        defer { collapseOnClick = nil; toggleOnClick = nil }
        guard let d = canvas.drag else { return }
        let frozen = positionsBeforeDrop(d)
        guard let drop = canvas.endDrag(), let model else { return }
        switch drop {
        case .click:
            if let c = collapseOnClick { model.selectStep(c) }
            if let t = toggleOnClick { model.selectStep(t, extend: true) }
        case .place(let pos):
            if d.isMixer {
                model.setMixerPosition(d.id, pos)
            } else {
                var all = canvas.groupPositions(d)
                all[d.id] = pos
                model.placeSteps(all, freezingMixers: frozen)
            }
        case .insertOnto(let link): _ = model.insertStep(d.id, onto: link)
        case .extract(let pos): model.extractStep(d.id, at: pos)
        }
    }

    private func positionsBeforeDrop(_ d: StepsCanvas.Drag) -> [UUID: StepPosition] {
        guard !d.isMixer else { return [:] }
        var still = canvas
        still.cancelDrag()
        let l = still.layout()
        let moving = Set([d.id] + d.group.keys)
        var out: [UUID: StepPosition] = [:]
        for col in canvas.columns where col.count > 1 && col.contains(where: moving.contains) {
            if let head = col.first, let r = l.mixers[head] { out[head] = StepPosition(x: Double(r.minX), y: Double(r.minY)) }
        }
        return out
    }

    /// A wire dropped: connected, moved, removed (on empty canvas) or refused (it snaps back, the target flashes red).
    private func finish(_ w: WireDrag) {
        guard let model else { return }
        guard let t = w.target else {
            if let k = w.replacing { if w.isKey { model.disconnectKey(k) } else { model.disconnect(k) } }
            return
        }
        if w.refused { refusedFlash = (t, w.isKey, clock() + Self.refusedFlashSeconds); return }
        if let k = w.replacing, k.from == w.from, k.to == t { return }
        if w.isKey {
            if let k = w.replacing { _ = model.rewireKey(k, from: w.from, to: t) } else if let id = w.from.stepID { _ = model.connectKey(from: id, to: t) }
        } else if let k = w.replacing {
            _ = model.rewire(k, from: w.from, to: t)
        } else {
            _ = model.connect(w.from, to: t)
        }
    }

    private func rightClick(at p: CGPoint) {
        guard let model else { return }
        switch hit(at: p) {
        case .step(let id)?, .eye(let id)?:
            if !model.selectedSteps.contains(id) { model.selectStep(id) } else { model.selectedStep = id }
            model.selectedMixer = nil
            menu(menus?.stepMenuItems(id), at: p)
        case .mixer(let head)?:
            model.selectedMixer = head
            menu(menus?.mixerMenuItems(head), at: p)
        case .dotOut?, .dotIn?, .keyOut?, .keyIn?: break
        case .insert(let id)?: menu(menus?.insertMenuItems(after: id), at: p)
        case .input?: menu(menus?.lutItems(.graphInput), at: p)
        case .output?: menu(menus?.lutItems(.graphOutput), at: p)
        case nil: if showsCanvas { menu(menus?.canvasMenuItems(), at: p) }
        }
    }

    private func menu(_ items: [SQMenuItem]?, at p: CGPoint) {
        guard let items, !items.isEmpty else { return }
        onMenu?(items, CGRect(x: p.x, y: p.y, width: 1, height: 1))
    }

    // MARK: Renaming

    func beginRename(_ id: UUID) {
        guard let s = model?.step(id) else { return }
        var f = TextFieldControl(text: s.label)
        f.mouseDown()
        renaming = (id, f)
    }

    func endRename(commit: Bool) {
        guard var r = renaming else { return }
        renaming = nil
        renameRect = nil
        if commit, let text = r.field.commit() { model?.renameStep(r.id, to: text) } else { r.field.cancel() }
    }

    // MARK: Keys

    /// Delete removes the selected Steps (or the mixer), Command-A selects all, Option-Left/Right moves the Step,
    /// Escape cancels a gesture. Returns false when the key is not this panel's.
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        if var r = renaming {
            switch k {
            case .enter: endRename(commit: true)
            case .escape: endRename(commit: false)
            default:
                if let done = r.field.key(k, modifiers: modifiers) {
                    renaming = nil
                    model?.renameStep(r.id, to: done)
                } else {
                    renaming = (r.id, r.field)
                }
            }
            return true
        }
        guard let model, !offersStart else { return false }
        if let head = model.selectedMixer {
            switch k {
            case .delete, .backspace: model.removeMixer(head); return true
            case .escape: cancelGesture(); model.selectedMixer = nil; return true
            default: break
            }
        }
        guard model.selectedStep != nil || !model.selectedSteps.isEmpty else { return false }
        switch k {
        case .delete, .backspace: model.removeSelectedSteps()
        case .character("a") where modifiers.contains(.command):
            model.selectSteps(Set(model.graph?.steps.map(\.id) ?? []))
        case .left where modifiers.contains(.option): if let id = model.selectedStep { model.moveStep(id, by: -1) }
        case .right where modifiers.contains(.option): if let id = model.selectedStep { model.moveStep(id, by: 1) }
        case .escape: cancelGesture()
        default: return false
        }
        return true
    }

    public func cancelGesture() {
        canvas.cancelDrag()
        wireDrag = nil
        marquee = nil
    }
}
