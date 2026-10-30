import AppKit
import SQCore
import SQUIKit

/// The Step inspector below the primaries: RGB Curves, Hue Saturation Curves, Qualifier and Window of the selected Step.
/// The editors are the Simple page's own (`CurveEditorView`, `ChannelDots`, `ColorParamRow` with `ColorRangeParam`);
/// only the model calls differ (`ColorInspectorModel+GraphDetail`). Every drag is one "Color Graph" undo step.
@MainActor
final class ColorStepDetailView: NSStackView {
    let model: ColorInspectorModel
    private var channel = 0
    private var hueKind = HueCurveKind.hueVsSat

    private var primaryWheels: [PrimaryWheel: ColorWheelControl] = [:]
    private var primaryRows: [StepPrimaryRow: ColorParamRow] = [:]
    private let chips = ColorChips(titles: ["Luma", "Red", "Green", "Blue"], label: "Curve channel")
    private let resetCurve = SQButton(title: "Reset", target: nil, action: nil, style: .standard)
    private let curveEditor = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 200, height: ColorGrid.rgbCurve))
    private let huePopup = SQPopup(frame: .zero, pullsDown: false)
    private let hueEditor = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 200, height: ColorGrid.hueCurve))
    private let qualifierOn = SQCheckbox(title: "Limit to a color range", target: nil, action: nil)
    private let pickColor = SQButton(title: "Pick color", target: nil, action: nil, style: .standard)
    private let matteOn = SQCheckbox(title: "Show matte", target: nil, action: nil)
    private let qualifierInvert = SQCheckbox(title: "Invert", target: nil, action: nil)
    private var rangeRows: [ColorRangeRow.Kind: ColorRangeRow] = [:]
    private var softnessRow: ColorParamRow?
    private let shapeChips = ColorChips(titles: StepWindow.Shape.allCases.map(\.chipTitle), label: "Window shape")
    private let windowTitle = NSTextField(labelWithString: "")
    private let removeWindow = SQButton(symbol: .trash, label: "Remove window", target: nil, action: nil)
    private var windowRows: [StepWindowParam: ColorParamRow] = [:]
    private let windowInvert = SQCheckbox(title: "Invert", target: nil, action: nil)

    override var isFlipped: Bool { true }

    init(model: ColorInspectorModel) {
        self.model = model
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        buildPrimaries()
        buildCurves()
        buildQualifier()
        buildWindow()
        buildEffects()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var stepID: UUID? { model.selectedStep }

    /// The groups by the Pro page's tab (1 Curves, 2 Qualifier with the matte preview, 3 Window, 5 Effects).
    private var tabGroups: [(tab: Int, view: NSView)] = []
    func show(tab: Int) { for g in tabGroups { g.view.isHidden = g.tab != tab } }

    private func pin(_ row: NSView, in parent: NSStackView? = nil) {
        let p = parent ?? self
        p.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: p.widthAnchor).isActive = true
    }

    private func inset(_ view: NSView, height: CGFloat) -> NSView {
        let box = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: ColorGrid.inset),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -ColorGrid.inset),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: ColorGrid.curveTop),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -ColorGrid.curveBottom),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
        return box
    }

    private func gestureHooks(_ r: ColorParamRow) {
        r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        r.onCancel = { [weak self] in self?.model.onGestureCancelled?() }
    }

    // MARK: Build

    /// Version 9 `.wheels.four`: Lift, Gamma, Gain and Offset as a 2 x 2 grid of 96 pt wheels, each with its master
    /// slider under it, then Saturation, Contrast and Pivot.
    private func buildPrimaries() {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 0
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = Theme.Spacing.md
        let all = PrimaryWheel.allCases
        for pair in [Array(all[0..<2]), Array(all[2..<4])] {
            let line = NSStackView()
            line.orientation = .horizontal
            line.distribution = .fillEqually
            line.spacing = Theme.Spacing.sm
            for w in pair { line.addArrangedSubview(wheelCell(w)) }
            grid.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        let box = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: ColorGrid.inset),
            grid.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -ColorGrid.inset),
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: Theme.Spacing.md),
            grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Theme.Spacing.md),
        ])
        pin(box, in: group)
        for p in StepPrimaryRow.allCases {
            let r = ColorParamRow(nil, title: p.title, range: p.range, neutral: p.neutral, decimals: p.decimals)
            gestureHooks(r)
            r.onSet = { [weak self] v in guard let self, let id = self.stepID else { return }; self.model.setStep(id, p.param, v / p.scale) }
            r.onReset = { [weak self] in guard let self, let id = self.stepID else { return }; self.model.resetStepValue(id, p.param) }
            primaryRows[p] = r
            pin(r, in: group)
        }
        pin(group)
        tabGroups.append((0, group))
    }

    private func wheelCell(_ w: PrimaryWheel) -> NSView {
        let size = ColorGrid.wheel
        let c = ColorWheelControl(frame: NSRect(x: 0, y: 0, width: size, height: size))
        c.title = w.title
        c.masterBelow = true
        c.translatesAutoresizingMaskIntoConstraints = false
        let h = size + 20 + Theme.Spacing.xs + ColorWheelControl.belowHeight
        c.widthAnchor.constraint(equalToConstant: size).isActive = true
        c.heightAnchor.constraint(equalToConstant: h).isActive = true
        c.setAccessibilityLabel("\(w.title) wheel")
        c.onBegin = { [weak self] _ in self?.model.onGestureBegan?() }
        c.onEnd = { [weak self] _ in self?.model.onGestureEnded?() }
        c.onChange = { [weak self, weak c] _ in
            guard let self, let c, let id = self.stepID else { return }
            self.model.setStepWheel(id, w, puck: .init(hue: c.hue, amount: c.amount), master: c.master)
        }
        primaryWheels[w] = c
        let cell = NSView()
        cell.addSubview(c)
        NSLayoutConstraint.activate([
            c.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            c.topAnchor.constraint(equalTo: cell.topAnchor),
            c.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }

    private func buildCurves() {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 0
        curveEditor.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        curveEditor.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        curveEditor.onChange = { [weak self] pts in
            guard let self, let id = self.stepID else { return }
            var c = self.model.stepCurves(id)
            switch self.channel { case 1: c.red = pts; case 2: c.green = pts; case 3: c.blue = pts; default: c.master = pts }
            self.model.setStepCurves(id, c)
        }
        pin(inset(curveEditor, height: ColorGrid.rgbCurve), in: group)
        chips.onSelect = { [weak self] i in self?.channel = i; self?.refresh() }
        resetCurve.target = self; resetCurve.action = #selector(resetCurveTapped)
        resetCurve.setAccessibilityLabel("Reset curve")
        pin(ColorFormRow(controls: [chips, resetCurve], stretchFirst: true), in: group)
        pin(hueCurveGroup(), in: group)
        pin(group)
        tabGroups.append((1, group))
    }

    private func hueCurveGroup() -> NSView {
        let group = ColorGroupView(title: "Hue Saturation Curves")
        group.header.hasRule = false
        huePopup.font = Theme.Typography.body
        huePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for k in HueCurveKind.allCases { huePopup.addItem(withTitle: k.title) }
        huePopup.target = self
        huePopup.action = #selector(hueKindChanged(_:))
        huePopup.setAccessibilityLabel("Step Hue Saturation Curve")
        pin(ColorControlRow(title: "Curve", controls: [huePopup]), in: group.content)
        hueEditor.flatBaseline = true
        hueEditor.points = HueCurves.flat
        hueEditor.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        hueEditor.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        hueEditor.onChange = { [weak self] pts in
            guard let self, let id = self.stepID else { return }
            self.model.setStepHueCurve(id, self.hueKind, pts)
        }
        pin(inset(hueEditor, height: ColorGrid.hueCurve), in: group.content)
        return group
    }

    private func buildQualifier() {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 0
        qualifierOn.target = self; qualifierOn.action = #selector(qualifierToggled(_:))
        qualifierOn.setAccessibilityLabel("Step Qualifier")
        pin(ColorFormRow(controls: [qualifierOn]), in: group)
        pickColor.isEnabled = false
        pickColor.setAccessibilityLabel("Pick color")
        matteOn.target = self; matteOn.action = #selector(matteToggled(_:))
        matteOn.setAccessibilityLabel("Show Step matte")
        qualifierInvert.target = self; qualifierInvert.action = #selector(qualifierInvertToggled(_:))
        qualifierInvert.setAccessibilityLabel("Invert Step Qualifier")
        pin(ColorFormRow(controls: [pickColor, matteOn, qualifierInvert]), in: group)
        let defs: [(ColorRangeRow.Kind, String, Double)] = [
            (.hue, "Hue", 360), (.saturation, "Saturation", 100), (.luma, "Luma", 100),
        ]
        for (kind, title, top) in defs {
            let r = ColorRangeRow(kind: kind, title: title, maximum: top)
            r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
            r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
            r.onChange = { [weak self] lo, hi in
                guard let self, let id = self.stepID else { return }
                for (param, v) in ColorRangeRow.params(kind, low: lo, high: hi) { self.model.setStepQualifier(id, param, v) }
            }
            rangeRows[kind] = r
            pin(r, in: group)
        }
        let p = ColorRangeParam.softness
        let soft = ColorParamRow(nil, title: p.title, range: p.range, neutral: p.neutral, decimals: 0)
        gestureHooks(soft)
        soft.onSet = { [weak self] v in guard let self, let id = self.stepID else { return }; self.model.setStepQualifier(id, p, v) }
        soft.onReset = { [weak self] in guard let self, let id = self.stepID else { return }; self.model.resetStepQualifierParameter(id, p) }
        softnessRow = soft
        pin(soft, in: group)
        pin(group)
        tabGroups.append((2, group))
    }

    private func buildWindow() {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 0
        shapeChips.onSelect = { [weak self] i in
            guard let self, let id = self.stepID, StepWindow.Shape.allCases.indices.contains(i) else { return }
            if self.model.step(id)?.window == nil { self.model.setStepWindowEnabled(id, true) }
            self.model.setStepWindowShape(id, StepWindow.Shape.allCases[i])
        }
        pin(ColorFormRow(controls: [shapeChips]), in: group)
        windowTitle.font = Theme.Typography.body
        windowTitle.textColor = Theme.Colors.label
        windowTitle.lineBreakMode = .byTruncatingTail
        windowTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeWindow.target = self; removeWindow.action = #selector(removeWindowTapped)
        pin(ColorFormRow(controls: [windowTitle, removeWindow], stretchFirst: true), in: group)
        for p in StepWindowParam.allCases {
            let r = ColorParamRow(nil, title: p == .softness ? "Feather" : p.title, range: p.range, neutral: p.neutral, decimals: 0)
            gestureHooks(r)
            r.onSet = { [weak self] v in guard let self, let id = self.stepID else { return }; self.model.setStepWindow(id, p, v) }
            r.onReset = { [weak self] in guard let self, let id = self.stepID else { return }; self.model.resetStepWindowParameter(id, p) }
            windowRows[p] = r
            pin(r, in: group)
        }
        windowInvert.target = self; windowInvert.action = #selector(windowInvertToggled(_:))
        windowInvert.setAccessibilityLabel("Invert Step Window")
        pin(ColorFormRow(controls: [windowInvert]), in: group)
        pin(ColorFootnote("Windows use the same shapes as masks on the timeline."), in: group)
        pin(group)
        tabGroups.append((3, group))
    }

    /// Version 9 Effects tab: a wide "Add effect" popup and the empty-state caption. A Step carries no effects yet, so
    /// the popup stays off rather than offering names that do nothing.
    private func buildEffects() {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 0
        let add = SQPopup(frame: .zero, pullsDown: true)
        add.font = Theme.Typography.body
        add.addItem(withTitle: "Add effect")
        add.isEnabled = false
        add.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add.setAccessibilityLabel("Add effect")
        pin(ColorFormRow(controls: [add], stretchFirst: true), in: group)
        pin(ColorFootnote("No effects on this Step. Effects run after the Step’s color work, in the order listed."), in: group)
        pin(group)
        tabGroups.append((5, group))
    }

    // MARK: Refresh

    func refresh() {
        let step = stepID.flatMap(model.step)
        let id = step?.id
        // Primaries.
        for (w, c) in primaryWheels where !c.isDragging {
            let v: (puck: ColorWheelMath.Value, master: Double) = id.map { model.stepWheel($0, w) } ?? (ColorWheelMath.reset, 0)
            c.hue = v.puck.hue; c.amount = v.puck.amount; c.master = v.master
            c.alphaValue = step == nil ? Theme.State.disabledAlpha : 1
        }
        for (p, r) in primaryRows { r.show((step.map(p.param.read) ?? p.param.neutral) * p.scale); r.setActive(step != nil) }
        // RGB curves.
        let c = step?.curves ?? RGBCurves()
        chips.selected = channel
        chips.isEnabled = step != nil
        resetCurve.isEnabled = step != nil
        let (pts, color): ([CurvePoint], NSColor) = switch channel {
        case 1: (c.red, Theme.Colors.red)
        case 2: (c.green, Theme.Colors.green)
        case 3: (c.blue, Theme.Palette.graphCurve[8])
        default: (c.master, Theme.Colors.label)
        }
        curveEditor.points = pts
        curveEditor.lineColor = color
        curveEditor.alphaValue = step == nil ? Theme.State.disabledAlpha : 1
        // Hue curves.
        huePopup.selectItem(at: hueKind.rawValue)
        hueEditor.hueStrip = hueKind.isHueKeyed
        hueEditor.points = id.map { model.stepHueCurve($0, hueKind) } ?? HueCurves.flat
        hueEditor.alphaValue = step == nil ? Theme.State.disabledAlpha : 1
        // Qualifier (the matte preview works for a qualifier or a window).
        let hasQ = step?.qualifier != nil
        let hasW = step?.window != nil
        matteOn.state = model.showsMatte ? .on : .off
        matteOn.isEnabled = hasQ || hasW
        qualifierOn.state = hasQ ? .on : .off
        qualifierOn.isEnabled = step != nil
        for (kind, r) in rangeRows {
            let (a, b) = ColorRangeRow.pair(kind)
            let va = id.map { model.stepQualifierValue($0, a) } ?? a.neutral
            let vb = id.map { model.stepQualifierValue($0, b) } ?? b.neutral
            let (lo, hi) = ColorRangeRow.bounds(kind, first: Double(va), second: Double(vb))
            r.show(low: lo, high: hi)
            r.setActive(hasQ)
        }
        if let r = softnessRow {
            r.show(id.map { model.stepQualifierValue($0, .softness) } ?? ColorRangeParam.softness.neutral)
            r.setActive(hasQ)
        }
        qualifierInvert.state = step?.qualifier?.invert == true ? .on : .off
        qualifierInvert.isEnabled = hasQ
        pickColor.isEnabled = false
        // Window.
        let shapes = StepWindow.Shape.allCases
        shapeChips.isEnabled = step != nil
        shapeChips.selected = step?.window.flatMap { shapes.firstIndex(of: $0.shape) } ?? -1
        windowTitle.stringValue = step?.window.map { "Window \u{00B7} \($0.shape.chipTitle)" } ?? "No window"
        windowTitle.textColor = hasW ? Theme.Colors.label : Theme.Colors.label3
        removeWindow.isEnabled = hasW
        for (p, r) in windowRows {
            r.show(id.map { model.stepWindowValue($0, p) } ?? p.neutral)
            r.setActive(hasW)
        }
        windowInvert.state = step?.window?.invert == true ? .on : .off
        windowInvert.isEnabled = hasW
    }

    // MARK: Actions

    @objc private func hueKindChanged(_ p: SQPopup) {
        guard let k = HueCurveKind(rawValue: p.indexOfSelectedItem) else { return }
        hueKind = k
        refresh()
    }

    @objc private func matteToggled(_ b: SQCheckbox) {
        model.showsMatte = b.state == .on
    }
    @objc private func qualifierToggled(_ b: SQCheckbox) {
        if let id = stepID { model.setStepQualifierEnabled(id, b.state == .on) }
    }
    @objc private func qualifierInvertToggled(_ b: SQCheckbox) {
        if let id = stepID { model.setStepQualifierInvert(id, b.state == .on) }
    }
    @objc private func windowInvertToggled(_ b: SQCheckbox) {
        if let id = stepID { model.setStepWindowInvert(id, b.state == .on) }
    }
    @objc private func removeWindowTapped() {
        if let id = stepID { model.setStepWindowEnabled(id, false) }
    }
    @objc private func resetCurveTapped() {
        guard let id = stepID else { return }
        var c = model.stepCurves(id)
        let flat = RGBCurves()
        switch channel { case 1: c.red = flat.red; case 2: c.green = flat.green; case 3: c.blue = flat.blue; default: c.master = flat.master }
        model.setStepCurves(id, c)
    }
}
