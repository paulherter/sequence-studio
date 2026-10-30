import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The Pro page's Curves, Qualifier, Window, LUT and Effects tabs (the Mac `ColorStepDetailView` and the LUT rows of
/// `ColorGraphPage`). The sliders and curves are the Simple page's own drawing; the range bars and chips are drawn here.
extension ColorGradeDraw {
    static let rangeRowHeight: CGFloat = 34
    static let rangeTrackHeight: CGFloat = 14
    static let rgbCurveHeight: CGFloat = 150
    static let hueCurveHeight: CGFloat = 90
    static let groupHeight: CGFloat = 24
    static let channelTitles = ["Luma", "Red", "Green", "Blue"]

    func proOtherTabRows(_ model: ColorInspectorModel, id: UUID, step: ColorStep?, add: (Row) -> Void) {
        let w = size.width, inset = Mac.inset, cap = CGFloat(DrawTheme.Metrics.capsule), fh = Self.formRowHeight
        let sm = CGFloat(DrawTheme.Spacing.sm), none = step == nil
        func mid(_ h: CGFloat, _ ch: CGFloat) -> CGFloat { ((h - ch) / 2).rounded() }
        func form(_ c: [(Control, CGRect)], dim: Bool = false) { add(Row(label: nil, y: 0, height: fh, controls: c, dim: dim)) }
        func note(_ text: String) {
            let lines = wrapLines(text, width: max(w - 2 * inset, 0), size: CGFloat(DrawTheme.TypeSize.caption))
            add(Row(label: nil, style: .footnote, y: 0, height: CGFloat(lines.count) * Self.footnoteLine + 16, controls: [], lines: lines))
        }
        func curveBox(_ h: CGFloat) -> CGRect { CGRect(x: inset, y: 6, width: max(w - 2 * inset, 0), height: h) }
        func srow(_ label: String, _ s: Slider, dim: Bool) {
            add(Row(label: label, y: 0, height: Mac.row, controls: [(.slider(s), sliderBox())], dim: dim))
        }
        switch proTab {
        case 1:
            add(Row(label: nil, y: 0, height: 6 + Self.rgbCurveHeight + sm, controls: [(.curve(.stepRGB(id)), curveBox(Self.rgbCurveHeight))], dim: none))
            var x = inset
            var chips: [(Control, CGRect)] = []
            for (i, t) in Self.channelTitles.enumerated() {
                let cw = textWidth(t, size: CGFloat(DrawTheme.TypeSize.body)) + 20
                chips.append((.curveChip(i), CGRect(x: x, y: mid(fh, cap), width: cw, height: cap)))
                x += cw + 2
            }
            let rw = buttonWidth("Reset")
            chips.append((.curveReset, CGRect(x: w - inset - rw, y: mid(fh, cap), width: rw, height: cap)))
            form(chips, dim: none)
            add(Row(label: "Hue Saturation Curves", style: .groupHead, y: 0, height: Self.groupHeight, controls: [], dim: none))
            add(Row(label: "Curve", y: 0, height: Mac.popupRow,
                    controls: [(.stepHueKind, CGRect(x: Mac.controlX, y: mid(Mac.popupRow, cap), width: max(w - inset - Mac.controlX, 0), height: cap))], dim: none))
            add(Row(label: nil, y: 0, height: 6 + Self.hueCurveHeight + sm, controls: [(.curve(.stepHue(id)), curveBox(Self.hueCurveHeight))], dim: none))
        case 2:
            let hasQ = step?.qualifier != nil, hasW = step?.window != nil
            let cb: CGFloat = 14
            func check(_ k: Control, _ title: String, x: CGFloat) -> (Control, CGRect, CGFloat) {
                let cw = cb + 6 + textWidth(title, size: CGFloat(DrawTheme.TypeSize.body))
                return (k, CGRect(x: x, y: mid(fh, cb), width: cw, height: cb), cw)
            }
            let q = check(.qualOn, "Limit to a color range", x: inset)
            form([(q.0, q.1)], dim: none)
            let pw = buttonWidth("Pick color")
            let mt = check(.matte, "Show matte", x: inset + pw + sm)
            let iv = check(.qualInvert, "Invert", x: mt.1.maxX + sm)
            add(Row(label: nil, y: 0, height: fh, controls: [(.pickColor, CGRect(x: inset, y: mid(fh, cap), width: pw, height: cap)),
                                                              (mt.0, mt.1), (iv.0, iv.1)], dim: none))
            let right = w - inset - 56
            for kind in StepRangeKind.allCases {
                let h = Self.rangeRowHeight
                add(Row(label: kind.title, y: 0, height: h,
                        controls: [(.rangeBar(kind), CGRect(x: Mac.controlX, y: mid(h, Self.rangeTrackHeight), width: max(right - Mac.controlX, 1),
                                                           height: Self.rangeTrackHeight))], dim: !hasQ))
            }
            _ = hasW
            srow(ColorRangeParam.softness.title, .stepQual(id, .softness), dim: !hasQ)
        case 3:
            let hasW = step?.window != nil
            var x = inset
            var chips: [(Control, CGRect)] = []
            for (i, s) in StepWindow.Shape.allCases.enumerated() {
                let cw = textWidth(s.chipTitle, size: CGFloat(DrawTheme.TypeSize.body)) + 20
                chips.append((.shapeChip(i), CGRect(x: x, y: mid(fh, cap), width: cw, height: cap)))
                x += cw + 2
            }
            form(chips, dim: none)
            let tw = CGFloat(Mac.icon)
            add(Row(label: step?.window.map { "Window \u{00B7} \($0.shape.chipTitle)" } ?? "No window", style: .title, y: 0, height: fh,
                    controls: [(.windowRemove, CGRect(x: w - inset - tw, y: mid(fh, cap), width: tw, height: cap))], dim: none, open: hasW))
            for p in StepWindowParam.allCases { srow(p == .softness ? "Feather" : p.title, .window(id, p), dim: !hasW) }
            let iv = check2(.windowInvert, "Invert", fh)
            add(Row(label: nil, y: 0, height: fh, controls: [(.windowInvert, iv)], dim: !hasW))
            note("Windows use the same shapes as masks on the timeline.")
        case 4:
            let ib = buttonWidth("Import\u{2026}")
            form([(.lutPill, CGRect(x: inset, y: mid(fh, cap), width: max(w - 2 * inset - ib - sm, 0), height: cap)),
                  (.lutImport, CGRect(x: w - inset - ib, y: mid(fh, cap), width: ib, height: cap))], dim: none)
            srow(StepParam.lutIntensity.title, .step(id, .lutIntensity), dim: step?.lut == nil)
            note("Supports .cube and .3dl. Imported files are kept with the project.")
        default:
            form([(.addEffect, CGRect(x: inset, y: mid(fh, cap), width: max(w - 2 * inset, 0), height: cap))])
            note("No effects on this Step. Effects run after the Step\u{2019}s color work, in the order listed.")
        }
    }

    private func check2(_ k: Control, _ title: String, _ h: CGFloat) -> CGRect {
        let cw = 14 + 6 + textWidth(title, size: CGFloat(DrawTheme.TypeSize.body))
        return CGRect(x: Mac.inset, y: ((h - 14) / 2).rounded(), width: cw, height: 14)
    }

    // MARK: Drawing

    private func drawCheck(_ c: inout Canvas, _ f: CGRect, _ title: String, _ on: Bool, _ k: Control, enabled: Bool) {
        let t = theme
        let box = CGRect(x: f.minX, y: f.midY - 7, width: 14, height: 14)
        InspectorDraw.checkbox(&c, on ? .on : .off, box: box, hovering: hover == k, pressed: pressed == k, enabled: enabled, t)
        c.draw(SQL10n.string(title), in: CGRect(x: box.maxX + 6, y: f.minY - 4, width: f.width, height: f.height + 8), fontSize: CGFloat(DrawTheme.TypeSize.body),
               t.label.alpha(enabled ? 1 : InspectorTokens.disabledAlpha))
    }

    private func drawChip(_ c: inout Canvas, _ f: CGRect, _ title: String, on: Bool, hover h: Bool, enabled: Bool) {
        let t = theme, a: Float = enabled ? 1 : InspectorTokens.disabledAlpha
        if on { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.selection.alpha(t.selection.a * a)) }
        else if h && enabled { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
        c.draw(SQL10n.string(title), in: f, fontSize: CGFloat(DrawTheme.TypeSize.body), (on ? t.label : t.label2).alpha(a), align: .center)
    }

    func drawProTabControl(_ c: inout Canvas, _ k: Control, _ f: CGRect, enabled: Bool) -> Bool {
        let t = theme, m = model, hov = hover == k, prs = pressed == k
        let step = m?.selectedStep.flatMap { m?.step($0) }
        switch k {
        case .curveChip(let i):
            drawChip(&c, f, Self.channelTitles[i], on: channel(.stepRGB(step?.id ?? Self.noStep)) == i, hover: hov, enabled: enabled)
        case .curveReset: InspectorDraw.button(&c, title: SQL10n.string("Reset"), in: f, hovering: hov, pressed: prs, enabled: enabled, t)
        case .stepHueKind: InspectorDraw.popup(&c, title: SQL10n.string(stepHueKind.title), in: f, hovering: hov, open: false, enabled: enabled, t)
        case .qualOn: drawCheck(&c, f, "Limit to a color range", step?.qualifier != nil, k, enabled: step != nil)
        case .pickColor: InspectorDraw.button(&c, title: SQL10n.string("Pick color"), in: f, hovering: false, pressed: false, enabled: false, t)
        case .matte: drawCheck(&c, f, "Show matte", m?.showsMatte == true, k, enabled: step?.qualifier != nil || step?.window != nil)
        case .qualInvert: drawCheck(&c, f, "Invert", step?.qualifier?.invert == true, k, enabled: step?.qualifier != nil)
        case .windowInvert: drawCheck(&c, f, "Invert", step?.window?.invert == true, k, enabled: step?.window != nil)
        case .rangeBar(let kind): drawRange(&c, kind, f, enabled: enabled)
        case .shapeChip(let i):
            let sel = step?.window.flatMap { w in StepWindow.Shape.allCases.firstIndex(of: w.shape) } ?? -1
            drawChip(&c, f, StepWindow.Shape.allCases[i].chipTitle, on: sel == i, hover: hov, enabled: step != nil)
        case .windowRemove:
            let live = step?.window != nil
            if live, hov { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: .trash, at: CGPoint(x: f.midX - 6, y: f.midY - 6), size: 12, live ? t.label2 : t.label3.alpha(0.5))
        case .lutPill:
            let name = step.flatMap { m?.stepLUTChoice($0.id) }?.name ?? "Choose LUT\u{2026}"
            InspectorDraw.button(&c, title: name, in: f, hovering: hov, pressed: prs, enabled: step != nil, t)
        case .lutImport: InspectorDraw.button(&c, title: SQL10n.string("Import\u{2026}"), in: f, hovering: hov, pressed: prs, enabled: step != nil, t)
        case .addEffect: InspectorDraw.popup(&c, title: SQL10n.string("Add effect"), in: f, hovering: false, open: false, enabled: false, t)
        default: return false
        }
        return true
    }

    /// The range bar (ColorRangeRow.draw): the gradient track, the selection frame and the two edge handles; the value at the right.
    private func drawRange(_ c: inout Canvas, _ kind: StepRangeKind, _ f: CGRect, enabled: Bool) {
        let t = theme
        let (lo, hi) = rangeBounds(kind)
        let math = RangeBarMath(maximum: kind.maximum, minX: f.minX, width: f.width)
        let r = CGFloat(DrawTheme.Radius.small)
        c.saveGState()
        c.clip(to: f)
        let n = 24
        let dim: Float = enabled ? 1 : InspectorTokens.disabledAlpha
        for i in 0..<n {
            let u = Double(i) / Double(n - 1)
            let col: DrawColor
            switch kind {
            case .hue: let v = Self.hsb(u, 0.5, 0.62); col = DrawColor(v.0, v.1, v.2, 1)
            case .saturation: let v = Self.hsb(0.08, 0.8 * u, 0.45 + 0.25 * u); col = DrawColor(v.0, v.1, v.2, 1)
            case .luma: let v = 0.08 + 0.87 * Float(u); col = DrawColor(v, v, v, 1)
            }
            c.fill(CGRect(x: f.minX + f.width * CGFloat(i) / CGFloat(n), y: f.minY, width: f.width / CGFloat(n) + 0.5, height: f.height), col.alpha(dim))
        }
        c.restoreGState()
        let sel = CGRect(x: math.x(lo), y: f.minY - 3, width: max(math.x(hi) - math.x(lo), 0), height: f.height + 6)
        c.stroke(roundedRect: sel, radius: r, width: 1.5, t.label.alpha(dim))
        for edge in [sel.minX, sel.maxX] { c.fill(roundedRect: CGRect(x: edge - 2, y: f.minY - 4, width: 4, height: f.height + 8), radius: r, t.label.alpha(dim)) }
        c.draw(RangeBarMath.text(lo, hi), in: CGRect(x: size.width - Mac.inset - 58, y: f.minY - 10, width: 56, height: f.height + 20),
               fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label.alpha(enabled ? 1 : InspectorTokens.disabledAlpha), align: .right)
    }

    func rangeBounds(_ kind: StepRangeKind) -> (Double, Double) {
        guard let m = model, let id = m.selectedStep else { return (0, kind.maximum) }
        let (a, b) = StepRangeKind.pair(kind)
        let (lo, hi) = StepRangeKind.bounds(kind, first: Double(m.stepQualifierValue(id, a)), second: Double(m.stepQualifierValue(id, b)))
        let l = min(max(lo, 0), kind.maximum)
        return (l, min(max(hi, l), kind.maximum))
    }

    // MARK: Pointer

    func proTabMouseDown(_ k: Control, at q: CGPoint, modifiers: InputModifiers) {
        guard let m = model, let id = m.selectedStep else { pressed = nil; return }
        switch k {
        case .curveChip(let i): channels[.stepRGB(id)] = i; pressed = nil
        case .stepHueKind:
            menu(HueCurveKind.allCases.map { kind in
                SQMenuItem(title: kind.title, isChecked: stepHueKind == kind, help: kind.explanation) { [weak self] in self?.stepHueKind = kind }
            }, at: k)
            pressed = nil
        case .shapeChip(let i):
            let shapes = StepWindow.Shape.allCases
            if shapes.indices.contains(i) {
                if m.step(id)?.window == nil { m.setStepWindowEnabled(id, true) }
                m.setStepWindowShape(id, shapes[i])
            }
            pressed = nil
        case .lutPill: menu(stepMenus?.lutItems(.step) ?? [], at: k); pressed = nil
        case .rangeBar(let kind):
            guard m.step(id)?.qualifier != nil, let f = frame(k) else { pressed = nil; return }
            let math = RangeBarMath(maximum: kind.maximum, minX: f.minX, width: f.width)
            let (lo, hi) = rangeBounds(kind)
            rangeDrag = (kind, math.grab(at: q.x, low: lo, high: hi))
            m.onGestureBegan?()
            proRangeDragged(q)
        default: break
        }
    }

    @discardableResult
    func proRangeDragged(_ q: CGPoint) -> Bool {
        guard let d = rangeDrag, let m = model, let id = m.selectedStep, let f = frame(.rangeBar(d.kind)) else { return false }
        let math = RangeBarMath(maximum: d.kind.maximum, minX: f.minX, width: f.width)
        let (lo, hi) = rangeBounds(d.kind)
        let r = math.apply(d.grab, at: q.x, low: lo, high: hi)
        for (p, v) in StepRangeKind.params(d.kind, low: r.low, high: r.high) { m.setStepQualifier(id, p, v) }
        return true
    }

    func proRangeUp() -> Bool {
        guard rangeDrag != nil else { return false }
        rangeDrag = nil
        model?.onGestureEnded?()
        return true
    }

    func proTabClicked(_ k: Control) {
        guard let m = model, let id = m.selectedStep else { return }
        let step = m.step(id)
        switch k {
        case .curveReset:
            var c = m.stepCurves(id)
            let flat = RGBCurves()
            switch channel(.stepRGB(id)) { case 1: c.red = flat.red; case 2: c.green = flat.green; case 3: c.blue = flat.blue; default: c.master = flat.master }
            m.setStepCurves(id, c)
        case .qualOn: m.setStepQualifierEnabled(id, step?.qualifier == nil)
        case .matte: if step?.qualifier != nil || step?.window != nil { m.showsMatte.toggle() }
        case .qualInvert: if step?.qualifier != nil { m.setStepQualifierInvert(id, !(step?.qualifier?.invert ?? false)) }
        case .windowInvert: if step?.window != nil { m.setStepWindowInvert(id, !(step?.window?.invert ?? false)) }
        case .windowRemove: m.setStepWindowEnabled(id, false)
        case .lutImport:
            chooseLUTFiles?(false) { paths in if let p = paths.first { m.setStepLUT(id, .file(p)) } }
        default: break
        }
    }
}
