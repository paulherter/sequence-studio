import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The Pro grade page of the Color panel (the Mac `ColorGraphPage`): the empty state, the layer list, the Step's path line,
/// the warning bands, the tab row and the Primaries tab (a 2 x 2 grid of wheels, Saturation, Contrast, Pivot). The other
/// tabs are in ColorGradeDraw+ProTabs.swift. Same logic, same session actions; only the drawing is portable.
extension ColorGradeDraw {
    static let proTabTitles = ["Primaries", "Curves", "Qualifier", "Window", "LUT", "Effects"]
    static let listRowHeight: CGFloat = 28
    static let listFooterHeight: CGFloat = 36
    static let emptyHeight: CGFloat = 96
    static let tabRowHeight = CGFloat(DrawTheme.Metrics.panelHeader)
    /// A row of controls (the Mac `ColorFormRow`): the capsule plus 4 above and below.
    static let formRowHeight = CGFloat(DrawTheme.Metrics.capsule) + 8
    static let wiringNotice = "Free wiring is saved. The picture still follows the Step order."
    static let wheelSize: CGFloat = 96
    static let wheelTitleHeight: CGFloat = 20
    static let masterBelow: CGFloat = 20

    /// The Steps list shows with the strip (the Steps page, when open, shows the graph instead).
    var showsStrip: Bool { !controller.stepsShown }

    // MARK: Text measure

    func probe() -> Canvas? { measure.map { Canvas(width: 1, height: 1, atlas: $0.atlas, scale: $0.scale) } }
    func textWidth(_ s: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        guard let c = probe() else { return CGFloat(s.count) * size * 0.56 }
        return ceil(c.size(of: SQL10n.string(s), fontSize: size, face: bold ? c.semibold : 0).width)
    }
    /// `ceil(NSString.size)` of each tab title in the Mac tab strip, regular and Medium (the selected tab), at the 11 pt UI
    /// font. The atlas measures from whole font-unit advances and is up to 0.6 pt off the Mac's sub-pixel width, which
    /// moved tabs by up to 1.5 pt. shortcut: English titles only (others use the atlas), upgrade when the atlas measures
    /// like `NSString.size`.
    static let macTabWidths: [String: (regular: CGFloat, medium: CGFloat)] = [
        "Primaries": (50, 51), "Curves": (37, 38), "Qualifier": (45, 46), "Window": (42, 43), "LUT": (22, 22), "Effects": (37, 39)]
    func tabTextWidth(_ s: String, size: CGFloat, bold: Bool) -> CGFloat {
        if size == 11, SQL10n.string(s) == s, let w = Self.macTabWidths[s] { return bold ? w.medium : w.regular }
        guard let c = probe() else { return textWidth(s, size: size, bold: bold) }
        return ceil(c.size(of: SQL10n.string(s), fontSize: size, face: bold ? c.medium : 0).width)
    }
    func buttonWidth(_ s: String) -> CGFloat {
        probe().map { InspectorDraw.buttonWidth($0, title: SQL10n.string(s)) } ?? CGFloat(s.count) * 7 + 22
    }
    func wrapLines(_ s: String, width: CGFloat, size: CGFloat) -> [String] {
        guard let c = probe() else { return [SQL10n.string(s)] }
        return c.wrap(SQL10n.string(s), width: width, fontSize: size)
    }

    // MARK: Rows

    func proRows(_ model: ColorInspectorModel, add: (Row) -> Void) {
        let w = size.width, inset = Mac.inset, cap = CGFloat(DrawTheme.Metrics.capsule), fs = CGFloat(DrawTheme.TypeSize.body)
        func mid(_ h: CGFloat, _ ch: CGFloat) -> CGFloat { ((h - ch) / 2).rounded() }
        guard let g = model.graph else {
            add(Row(label: "No Pro grade yet", style: .empty, y: 0, height: Self.emptyHeight, controls: [],
                    summary: showsStrip ? "Nothing in your Simple grade changes." : "Start from the graph below. Nothing in your Simple grade changes."))
            if showsStrip {
                let h = Mac.popupRow, a = buttonWidth("Start empty"), b = buttonWidth("Start from Simple grade")
                let bx = w - inset - b, ax = bx - CGFloat(DrawTheme.Spacing.sm) - a
                add(Row(label: nil, y: 0, height: h, controls: [(.startEmpty, CGRect(x: ax, y: mid(h, cap), width: a, height: cap)),
                                                                  (.startFromSimple, CGRect(x: bx, y: mid(h, cap), width: b, height: cap))]))
            }
            return
        }
        let step = model.selectedStep.flatMap(model.step)
        if showsStrip {
            let base = g.steps.first?.id
            for st in g.listSteps {
                let h = Self.listRowHeight, q = mid(h, cap)
                let mixW: CGFloat = 60, popW: CGFloat = 96, sm = CGFloat(DrawTheme.Spacing.sm)
                let mixX = w - inset - mixW, popX = mixX - sm - popW
                var c: [(Control, CGRect)] = [(.listEye(st.id), CGRect(x: inset, y: q, width: cap, height: cap)),
                                              (.listMix(st.id), CGRect(x: mixX, y: q, width: mixW, height: cap))]
                if st.id != base { c.append((.listBlend(st.id), CGRect(x: popX, y: q, width: popW, height: cap))) }
                c.append((.listRow(st.id), CGRect(x: 0, y: 0, width: w, height: h)))
                add(Row(label: st.label, style: .listItem, y: 0, height: h, controls: c, dim: !st.enabled,
                        summary: st.lut != nil ? "lut" : nil, open: st.id == model.selectedStep))
            }
            let h = Self.listFooterHeight, q = mid(h, cap)
            let inW = max(buttonWidth("In"), cap), outW = max(buttonWidth("Out"), cap)
            add(Row(label: nil, style: .listFoot, y: 0, height: h, controls: [
                (.listChip(.input), CGRect(x: inset, y: q, width: inW, height: cap)),
                (.listChip(.output), CGRect(x: w - inset - outW, y: q, width: outW, height: cap)),
                (.listAdd, CGRect(x: (w / 2 - cap / 2).rounded(), y: q, width: cap, height: cap)),
            ]))
        }
        // The path line: "01   Name", the Step's eye and its menu.
        let number = step.flatMap { s in g.steps.firstIndex { $0.id == s.id } }.map { String(format: "%02d", $0 + 1) }
        let ph = Mac.popupRow, btn = CGFloat(Mac.icon)
        let more = CGRect(x: w - inset - btn, y: mid(ph, cap), width: btn, height: cap)
        let eye = more.offsetBy(dx: -(btn + 6), dy: 0)
        add(Row(label: step.map { "\(number ?? "")   \($0.label)" } ?? "", style: .path, y: 0, height: ph,
                controls: [(.pathEye, eye), (.pathMore, more)]))
        if let step, !step.enabled {
            let b = buttonWidth("Turn On")
            add(Row(label: "This Step is off. Its values are kept.", style: .warning, y: 0, height: ph,
                    controls: [(.turnOn, CGRect(x: w - inset - b, y: mid(ph, cap), width: b, height: cap))]))
        }
        if g.hasCustomWiring { add(Row(label: Self.wiringNotice, style: .warning, y: 0, height: ph, controls: [])) }
        // The tab row: the Mac tab strip (12 inset, 8 padding each side, the underline under the selected title).
        var x = inset - 8
        var tabs: [(Control, CGRect)] = []
        for (i, t) in Self.proTabTitles.enumerated() {
            let tw = tabTextWidth(t, size: fs, bold: i == proTab) + 16
            tabs.append((.proTab(i), CGRect(x: x, y: 0, width: tw, height: Self.tabRowHeight)))
            x += tw
        }
        add(Row(label: nil, y: 0, height: Self.tabRowHeight, controls: tabs))
        proTabRows(model, step: step, add: add)
    }

    /// The selected tab's rows (Primaries here, the others in ColorGradeDraw+ProTabs.swift).
    private func proTabRows(_ model: ColorInspectorModel, step: ColorStep?, add: (Row) -> Void) {
        let id = step?.id ?? Self.noStep
        let dim = step == nil
        switch proTab {
        case 0: primariesRows(id, dim: dim, add: add)
        default: proOtherTabRows(model, id: id, step: step, add: add)
        }
    }

    /// No Step selected: the controls draw disabled and write nowhere (the id matches no Step).
    static let noStep = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    func sliderBox(_ rowH: CGFloat = Mac.row) -> CGRect {
        CGRect(x: Mac.controlX, y: ((rowH - Mac.slider) / 2).rounded(), width: max(size.width - Mac.inset - Mac.controlX, 0), height: Mac.slider)
    }

    /// Version 9 `.wheels.four`: Lift, Gamma, Gain and Offset as a 2 x 2 grid of 96 pt wheels (title above, master slider
    /// under each), then Saturation, Contrast and Pivot.
    private func primariesRows(_ id: UUID, dim: Bool, add: (Row) -> Void) {
        let inset = Mac.inset, md = CGFloat(DrawTheme.Spacing.md), sm = CGFloat(DrawTheme.Spacing.sm), xs = CGFloat(DrawTheme.Spacing.xs)
        let cellW = max((size.width - 2 * inset - sm) / 2, 0)
        let d = Self.wheelSize, cellH = Self.wheelTitleHeight + d + xs + Self.masterBelow
        var controls: [(Control, CGRect)] = []
        for (i, p) in PrimaryWheel.allCases.enumerated() {
            let col = CGFloat(i % 2), line = CGFloat(i / 2)
            let x = inset + col * (cellW + sm) + ((cellW - d) / 2).rounded()
            let y = md + line * (cellH + md) + Self.wheelTitleHeight
            controls.append((.wheel(.step(id, p)), CGRect(x: x, y: y, width: d, height: d)))
            controls.append((.master(.step(id, p)), CGRect(x: x, y: y + d + xs, width: d, height: Self.masterBelow)))
        }
        add(Row(label: nil, y: 0, height: md + 2 * cellH + md + md, controls: controls, dim: dim))
        for r in StepPrimaryRow.allCases {
            add(Row(label: r.title, y: 0, height: Mac.row, controls: [(.slider(.primary(id, r)), sliderBox())], dim: dim))
        }
    }

    // MARK: Drawing

    func drawProRow(_ c: inout Canvas, _ r: Row, alpha a: Float) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body), cap = CGFloat(DrawTheme.TypeSize.caption), w = size.width
        let inset = Mac.inset
        switch r.style {
        case .empty:
            c.draw(SQL10n.string(r.label ?? ""), in: CGRect(x: 0, y: r.y + r.height / 2 - 22, width: w, height: 20), fontSize: 15, t.label,
                   align: .center, face: c.semibold)
            c.draw(SQL10n.string(r.summary ?? ""), in: CGRect(x: 0, y: r.y + r.height / 2 + 2, width: w, height: 16), fontSize: cap, t.label3, align: .center)
        case .listItem:
            let row = CGRect(x: 0, y: r.y, width: w, height: r.height)
            if r.open { c.fill(roundedRect: row.insetBy(dx: 4, dy: 1), radius: CGFloat(DrawTheme.Radius.control), t.selection) }
            let lx = inset + CGFloat(DrawTheme.Metrics.capsule) + 8
            let right = w - inset - 60 - 8 - 96 - 8
            let label = SQL10n.string(r.label ?? "")
            c.draw(label, in: CGRect(x: lx, y: r.y, width: max(right - lx, 0), height: r.height), fontSize: fs, r.dim ? t.label3 : t.label)
            if r.summary != nil {
                let tw = min(ceil(c.size(of: label, fontSize: fs).width) + 4, right - lx - 4)
                c.fill(ellipseIn: CGRect(x: lx + tw, y: row.midY - 2, width: 4, height: 4), t.accent)
            }
        case .listFoot:
            c.fill(CGRect(x: 0, y: r.y, width: w, height: 1), t.separator)
            if let d = listDrag, let g = model?.graph, let from = g.listSteps.firstIndex(where: { $0.id == d.id }) {
                let y = r.y - CGFloat(g.steps.count) * Self.listRowHeight + CGFloat(d.target) * Self.listRowHeight + (d.target > from ? Self.listRowHeight : 0)
                c.fill(CGRect(x: inset, y: y - 1, width: w - 2 * inset, height: 2), t.accent)
            }
        case .path:
            c.draw(SQL10n.string(r.label ?? ""), in: CGRect(x: inset, y: r.y, width: max(w - inset - 2 * 30 - 8, 0), height: r.height), fontSize: fs, t.label,
                   face: c.semibold)
        case .warning:
            c.fill(CGRect(x: 0, y: r.y, width: w, height: r.height), t.warning.alpha(0.10))
            c.draw(icon: .warning, at: CGPoint(x: inset, y: r.y + (r.height - 14) / 2), size: 14, t.warning)
            c.draw(SQL10n.string(r.label ?? ""), in: CGRect(x: inset + 20, y: r.y, width: max(w - inset - 20 - 90, 0), height: r.height), fontSize: fs,
                   t.warning, face: c.semibold)
        case .footnote:
            for (i, l) in r.lines.enumerated() {
                c.draw(l, in: CGRect(x: inset, y: r.y + 8 + CGFloat(i) * Self.footnoteLine, width: w - 2 * inset, height: Self.footnoteLine),
                       fontSize: cap, t.label3)
            }
        case .groupHead:
            c.draw(SQL10n.string(r.label ?? "").uppercased(), in: CGRect(x: inset, y: r.y, width: w - 2 * inset, height: r.height), fontSize: cap, t.label3.alpha(a),
                   face: c.semibold)
        case .title:
            c.draw(SQL10n.string(r.label ?? ""), in: CGRect(x: inset, y: r.y, width: max(w - 2 * inset - 30, 0), height: r.height), fontSize: fs,
                   r.open ? t.label : t.label3)
        default: break
        }
    }
    static let footnoteLine: CGFloat = 13

    /// Draws the Pro page's own controls; false = not one of them.
    func drawProControl(_ c: inout Canvas, _ k: Control, _ f: CGRect, enabled: Bool) -> Bool {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body), hov = hover == k, prs = pressed == k
        switch k {
        case .startEmpty: InspectorDraw.button(&c, title: SQL10n.string("Start empty"), in: f, hovering: hov, pressed: prs, enabled: true, accent: true, t)
        case .startFromSimple: InspectorDraw.button(&c, title: SQL10n.string("Start from Simple grade"), in: f, hovering: hov, pressed: prs, enabled: true, t)
        case .turnOn: InspectorDraw.button(&c, title: SQL10n.string("Turn On"), in: f, hovering: hov, pressed: prs, enabled: true, t)
        case .listEye(let id):
            let on = model?.step(id)?.enabled ?? true
            if hov { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: on ? .eye : .eyeOff, at: CGPoint(x: f.midX - 6, y: f.midY - 6), size: 12, t.label2)
        case .pathEye:
            let step = model?.selectedStep.flatMap { model?.step($0) }
            let on = step?.enabled ?? true
            if hov, step != nil { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: on ? .eye : .eyeOff, at: CGPoint(x: f.midX - 6, y: f.midY - 6), size: 12, step == nil ? t.label3.alpha(0.5) : t.label2)
        case .pathMore:
            if hov { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: .ellipsis, at: CGPoint(x: f.midX - 6, y: f.midY - 6), size: 12, t.label2)
        case .listBlend(let id):
            let b = model?.graph?.blend(of: id) ?? .series
            InspectorDraw.popup(&c, title: SQL10n.string(Self.blendTitle(b)), in: f, hovering: hov, open: false, enabled: enabled && (model?.graph?.allowsListEdit ?? true), t)
        case .listMix(let id):
            var fd = field(.mix(id))
            fd.unit = "%"
            fd.isEnabled = enabled
            fd.hovering = hov
            fd.valueTint = t.accent
            fd.draw(&c, in: f, theme: t, focused: focused == .mix(id))
        case .listAdd:
            if hov { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fillHover) }
            c.draw(icon: .plus, at: CGPoint(x: f.midX - 6, y: f.midY - 6), size: 12, t.label2)
        case .listChip(let slot):
            let name = model?.graphLUTChoice(slot)?.name
            let title = SQL10n.string(slot == .input ? "In" : "Out")
            // A loaded LUT turns the chip's text purple (the Mac layer list).
            InspectorDraw.button(&c, title: name == nil ? title : "", in: f, hovering: hov, pressed: prs, enabled: true, t)
            if name != nil {
                c.draw(title, in: f, fontSize: fs, t.accent, align: .center)
            }
        case .listRow: break
        case .proTab(let i):
            let on = i == proTab, w = tabTextWidth(Self.proTabTitles[i], size: fs, bold: on)
            c.draw(SQL10n.string(Self.proTabTitles[i]), in: CGRect(x: f.minX + 8, y: f.minY, width: w + 4, height: f.height), fontSize: fs,
                   on ? t.label : (hov ? t.label2 : t.label3), face: on ? c.medium : 0)
            if on { c.fill(roundedRect: CGRect(x: f.minX + 8, y: f.maxY - 2, width: f.width - 16, height: 2), radius: 1, t.label3) }
        default: return drawProTabControl(&c, k, f, enabled: enabled)
        }
        return true
    }

    static func blendTitle(_ b: StepBlend) -> String {
        switch b {
        case .series: "Series"
        case .parallel: "Parallel"
        case .layer(.normal): "Layer"
        case .layer(let m): m.rawValue.prefix(1).uppercased() + m.rawValue.dropFirst()
        }
    }

    // MARK: Pointer

    var stepMenus: ColorGraphMenus? {
        guard let m = model else { return nil }
        var menus = ColorGraphMenus(model: m)
        menus.rename = { [weak m] id in m?.beginRename(id) }
        menus.chooseLUTFile = { [weak self] done in
            guard let pick = self?.chooseLUTFiles else { done(nil); return }
            pick(false) { paths in done(paths.first) }
        }
        if let choose = chooseDecisionFile, let tell = tellUser { menus.importDecision = menus.makeDecisionImport(choose: choose, tell: tell) }
        return menus
    }

    func menu(_ items: [SQMenuItem], at k: Control) {
        guard !items.isEmpty, let f = frame(k) else { return }
        onMenu?(items, f.offsetBy(dx: 0, dy: -scrollY))
    }

    func proSecondary(_ k: Control) {
        switch k {
        case .listRow(let id): model?.selectedStep = id; menu(stepMenus?.stepMenuItems(id) ?? [], at: k)
        case .pathMore: if let id = model?.selectedStep { menu(stepMenus?.stepMenuItems(id) ?? [], at: k) }
        default: break
        }
    }

    func proMouseDown(_ k: Control, at q: CGPoint, modifiers: InputModifiers, clickCount n: Int) {
        guard let m = model else { return }
        switch k {
        case .listRow(let id):
            m.selectedStep = id
            listPress = (id, q.y)
        case .listBlend(let id):
            guard m.graph?.allowsListEdit ?? true else { pressed = nil; return }
            menu(StepBlend.all.map { b in
                SQMenuItem(title: Self.blendTitle(b), isChecked: m.graph?.blend(of: id) == b) { m.setStepBlend(id, b) }
            }, at: k)
            pressed = nil
        case .listMix(let id):
            guard let f = frame(k) else { return }
            _ = f
            var fd = field(.mix(id))
            fd.unit = "%"
            apply(fd.mouseDown(x: Float(q.x), clickCount: n), .mix(id))
            fields[.mix(id)] = fd
            fieldPress = .mix(id)
            focused = .mix(id)
        case .listChip(let slot):
            menu(stepMenus?.lutItems(slot == .input ? .graphInput : .graphOutput) ?? [], at: k)
            pressed = nil
        case .pathMore:
            if let id = m.selectedStep { menu(stepMenus?.stepMenuItems(id) ?? [], at: k) }
            pressed = nil
        case .proTab(let i): proTab = i; pressed = nil
        default: proTabMouseDown(k, at: q, modifiers: modifiers)
        }
    }

    /// A drag in progress that the Pro page owns (a list row, a range bar); false = not ours.
    func proMouseDragged(_ q: CGPoint) -> Bool {
        if let p = listPress, let m = model, let g = m.graph, g.allowsListEdit {
            guard listDrag != nil || abs(q.y - p.y) > 4 else { return true }
            guard let top = rows.first(where: { if case .listItem = $0.style { true } else { false } })?.y else { return true }
            let n = g.steps.count
            listDrag = (p.id, min(max(Int(((q.y - top) / Self.listRowHeight).rounded(.down)), 0), max(n - 1, 0)))
            return true
        }
        return proRangeDragged(q)
    }

    func proMouseUp() -> Bool {
        if let p = listPress {
            defer { listPress = nil; listDrag = nil }
            if let d = listDrag, let g = model?.graph, g.listSteps.firstIndex(where: { $0.id == d.id }) != d.target { model?.moveStep(d.id, toListRow: d.target) }
            return true
        }
        return proRangeUp()
    }

    /// A click that ended on the control it started on.
    func proClicked(_ k: Control) {
        guard let m = model else { return }
        switch k {
        case .listEye(let id): if let s = m.step(id) { m.setStepEnabled(id, !s.enabled) }
        case .pathEye, .turnOn:
            if let id = m.selectedStep, let s = m.step(id) { m.setStepEnabled(id, k == .turnOn ? true : !s.enabled) }
        case .listAdd: m.addLayerOnTop()
        case .startEmpty: m.startEmptyGraph()
        case .startFromSimple: m.startFromSimple()
        default: proTabClicked(k)
        }
    }

    func proHelp(_ k: Control) -> String? {
        switch k {
        case .listAdd: SQL10n.string("Add a layer on top")
        case .listChip(let slot):
            SQL10n.format(slot == .input ? "In LUT: %@" : "Out LUT: %@",
                          SQL10n.string(model?.graphLUTChoice(slot)?.name ?? (slot == .input ? "None (built-in conversion)" : "None")))
        default: nil
        }
    }
}
