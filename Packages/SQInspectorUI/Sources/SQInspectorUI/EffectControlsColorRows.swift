import AppKit
import SQCore
import SQUIKit

/// Group header of a Color effect (Basics, Creative, Curves ...): the shared `InspectorSectionHeader`, so every group
/// opens and closes the same way (REDESIGN-ROUND-2 decision 5: Color > Basics collapses like the others). Chevron and
/// title toggle the group, the header's own switch turns the group on or off.
final class ColorGroupHeaderRow: RowBackground, RowUpdating {
    let property: EffectProperty
    let model: EffectControlsModel
    let header: InspectorSectionHeader

    init(effect: ClipEffect.ID, key: String, model: EffectControlsModel) {
        let p = EffectProperty.fx(effect, kind: ClipEffect.colorKind, key: key)
        property = p; self.model = model
        let name = EffectCatalog.param(ClipEffect.colorKind, key)?.title ?? key
        let open = model.openColorGroups.contains(EffectControlsModel.colorGroupID(effect, key))
        header = InspectorSectionHeader(title: name, hasEnableToggle: true, isExpanded: open)
        super.init(frame: .zero)
        fill = Theme.Colors.panel
        header.onToggleExpanded = { [weak model] _ in model?.toggleColorGroup(effect, key) }
        header.onToggleEnabled = { [weak model] on in model?.setValue(p, to: on ? 1 : 0) }
        addSubview(header)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Indented under its Color section like the parameter rows.
        let x = ControlsGrid.levelIndent
        header.frame = NSRect(x: x, y: 0, width: max(bounds.width - x, 0), height: bounds.height)
    }

    func update() {
        let on = model.scalarValue(property) >= 0.5
        if header.isEnabledToggleOn != on { header.isEnabledToggleOn = on }
    }
}

/// The RGB curves of a Color effect, same editor as the Color page: channel dots above the plot.
final class ColorCurvesRow: RowBackground, RowUpdating {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let dots = ChannelDots()
    private let editor = CurveEditorView(frame: .zero)
    private var channel = 0

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        fill = Theme.Colors.content
        dots.onSelect = { [weak self] i in self?.channel = i; self?.update() }
        editor.onBegin = { [weak model] in model?.beginGesture() }
        editor.onEnd = { [weak model] in model?.endGesture() }
        editor.onChange = { [weak self] pts in
            guard let self else { return }
            var c = self.model.colorCurves(self.effect)
            switch self.channel { case 1: c.red = pts; case 2: c.green = pts; case 3: c.blue = pts; default: c.master = pts }
            self.model.setColorCurves(self.effect, c)
        }
        addSubview(dots); addSubview(editor)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        let dw = dots.intrinsicContentSize.width
        // Grid: the plot spans label column to the trailing inset; the channel dots sit in one row above it.
        let top = ControlsGrid.rowHeight
        dots.frame = NSRect(x: max((w - dw) / 2, ControlsGrid.toggleX), y: 0, width: dw, height: top)
        editor.frame = NSRect(x: ControlsGrid.labelX, y: top, width: max(w - ControlsGrid.labelX - ControlsGrid.trailing, 40),
                              height: max(bounds.height - top - ControlsGrid.gap, 40))
    }

    func update() {
        let c = model.colorCurves(effect)
        dots.selected = channel
        let (pts, color): ([CurvePoint], NSColor) = switch channel {
        case 1: (c.red, Theme.Colors.red)
        case 2: (c.green, Theme.Colors.green)
        case 3: (c.blue, Theme.Palette.channelBlue)
        default: (c.master, Theme.Colors.label)
        }
        editor.points = pts
        editor.lineColor = color
    }
}

/// FB-B3: Color Match under the Color Wheels group (Premiere Lumetri "Match"): Set Reference stores the Program frame's
/// statistics, Match sets the wheels so this clip's frame matches them. The label names the reference or why Match is off.
final class ColorMatchRow: RowBackground, RowUpdating {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let setButton = SQButton(title: "Set Reference", target: nil, action: nil)
    private let matchButton = SQButton(title: "Match", target: nil, action: nil)
    private let status = makeLabel("", font: Theme.Typography.caption, color: Theme.Colors.label3)

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        fill = Theme.Colors.content
        for b in [setButton, matchButton] {
            b.target = self
            addSubview(b)
        }
        setButton.action = #selector(setReference)
        matchButton.action = #selector(match)
        setButton.sqToolTip = Tooltip.text("Set Reference", shortcut: nil)
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func setReference() { model.requestColorMatch(effect, .setReference) }
    @objc private func match() { model.requestColorMatch(effect, .match) }

    override func layout() {
        super.layout()
        let h = bounds.height, bw1 = setButton.intrinsicContentSize.width, bw2 = matchButton.intrinsicContentSize.width
        let grid = ControlsGrid(width: bounds.width)
        setButton.frame = grid.controlFrame(x: ControlsGrid.valueX, width: bw1, height: h)
        matchButton.frame = grid.controlFrame(x: setButton.frame.maxX + ControlsGrid.gap, width: bw2, height: h)
        let x = matchButton.frame.maxX + ControlsGrid.gap
        status.frame = NSRect(x: x, y: (h - ControlsGrid.labelHeight) / 2, width: max(grid.tailMaxX - x, 0), height: ControlsGrid.labelHeight)
    }

    func update() {
        let block = model.colorMatchBlock(effect)
        let ref = model.colorMatchReference(effect)
        matchButton.isEnabled = block == nil
        matchButton.sqToolTip = block ?? Tooltip.text("Match", shortcut: nil)
        status.stringValue = ref.map { SQL10n.format("Ref: %@", $0.label) } ?? SQL10n.string("No reference")
        status.sqToolTip = block ?? ref?.label
    }
}

/// COLOR-GRADE-LINKS: start and end (clip-local timecode) of a range grade under its section header, and Whole Clip.
final class GradeRangeRow: RowBackground, RowUpdating {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let caption = makeLabel("Range", font: Theme.Typography.bodyStrong, color: Theme.Colors.label2)
    private let startField = SQTextField(string: "")
    private let endField = SQTextField(string: "")
    private let wholeButton = SQButton(title: "Whole Clip", target: nil, action: nil)

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        fill = Theme.Colors.content
        for f in [startField, endField] {
            f.alignment = .center
            f.font = Theme.Typography.caption
            f.target = self
            f.action = #selector(fieldChanged(_:))
            addSubview(f)
        }
        startField.sqToolTip = Tooltip.text("Range Start", shortcut: nil)
        endField.sqToolTip = Tooltip.text("Range End", shortcut: nil)
        wholeButton.target = self
        wholeButton.action = #selector(whole)
        wholeButton.sqToolTip = Tooltip.text("Whole Clip", shortcut: nil)
        addSubview(caption); addSubview(wholeButton)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fieldChanged(_ f: NSTextField) {
        let t = MarkersPanelModel.parseTimecode(f.stringValue, frameDuration: model.frameDuration)
        if let t { model.setGradeRange(effect, start: f === startField ? t : nil, end: f === endField ? t : nil) }
        update()
    }
    @objc private func whole() { model.setGradeWholeClip(effect) }

    override func layout() {
        super.layout()
        // Grid: name in the label column, the two timecode fields from the value column, the button after them.
        let h = bounds.height, fw = Theme.Inspector.timecodeWidth, grid = ControlsGrid(width: bounds.width)
        grid.place(caption, height: h)
        startField.frame = grid.controlFrame(x: ControlsGrid.valueX, width: fw, height: h)
        endField.frame = grid.controlFrame(x: startField.frame.maxX + ControlsGrid.gap, width: fw, height: h)
        let bx = endField.frame.maxX + ControlsGrid.gap
        let bw = min(wholeButton.intrinsicContentSize.width, max(grid.tailMaxX - bx, 0))
        wholeButton.frame = grid.controlFrame(x: bx, width: bw, height: h)
    }

    func update() {
        guard let r = model.gradeRange(effect) else { return }
        let fd = model.frameDuration
        if startField.currentEditor() == nil { startField.stringValue = MarkersPanelModel.timecode(r.start, frameDuration: fd) }
        if endField.currentEditor() == nil { endField.stringValue = MarkersPanelModel.timecode(r.end, frameDuration: fd) }
    }
}


/// Soft edges of a range grade: fade-in and fade-out length (clip-local timecode), 0 = hard edge.
final class GradeFadeRow: RowBackground, RowUpdating {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let caption = makeLabel("Fade", font: Theme.Typography.bodyStrong, color: Theme.Colors.label2)
    private let inField = SQTextField(string: "")
    private let outField = SQTextField(string: "")

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        fill = Theme.Colors.content
        for f in [inField, outField] {
            f.alignment = .center
            f.font = Theme.Typography.caption
            f.target = self
            f.action = #selector(fieldChanged(_:))
            addSubview(f)
        }
        inField.sqToolTip = Tooltip.text("Fade In Length", shortcut: nil)
        outField.sqToolTip = Tooltip.text("Fade Out Length", shortcut: nil)
        addSubview(caption)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fieldChanged(_ f: NSTextField) {
        let t = MarkersPanelModel.parseTimecode(f.stringValue, frameDuration: model.frameDuration)
        if let t { model.setGradeFades(effect, fadeIn: f === inField ? t : nil, fadeOut: f === outField ? t : nil) }
        update()
    }

    override func layout() {
        super.layout()
        let h = bounds.height, fw = Theme.Inspector.timecodeWidth, grid = ControlsGrid(width: bounds.width)
        grid.place(caption, height: h)
        inField.frame = grid.controlFrame(x: ControlsGrid.valueX, width: fw, height: h)
        outField.frame = grid.controlFrame(x: inField.frame.maxX + ControlsGrid.gap, width: fw, height: h)
    }

    func update() {
        let fd = model.frameDuration, v = model.gradeFades(effect)
        if inField.currentEditor() == nil { inField.stringValue = MarkersPanelModel.timecode(v.fadeIn, frameDuration: fd) }
        if outField.currentEditor() == nil { outField.stringValue = MarkersPanelModel.timecode(v.fadeOut, frameDuration: fd) }
    }
}

/// The Pro grade under its section header: how many Steps it has, and Adjust, which opens the Color page where the
/// graph is edited. Shown only while Pro is the clip's grade (`EffectControlsModel.visibleSections`).
final class ColorGraphSummaryRow: RowBackground, RowUpdating {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let caption = makeLabel("", font: Theme.Typography.bodyStrong, color: Theme.Colors.label2)
    private let adjustButton = SQButton(title: "Adjust", target: nil, action: nil)

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        fill = Theme.Colors.content
        adjustButton.target = self
        adjustButton.action = #selector(adjust)
        adjustButton.sqToolTip = Tooltip.text("Adjust in the Color page", shortcut: nil)
        addSubview(caption); addSubview(adjustButton)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func adjust() { model.onOpenColorPro?() }

    override func layout() {
        super.layout()
        let h = bounds.height, grid = ControlsGrid(width: bounds.width)
        grid.place(caption, height: h)
        let bw = min(adjustButton.intrinsicContentSize.width, max(grid.tailMaxX - ControlsGrid.valueX, 0))
        adjustButton.frame = grid.controlFrame(x: ControlsGrid.valueX, width: bw, height: h)
    }

    func update() {
        let n = model.colorGraphStepCount(effect)
        let text = SQL10n.plural(n, one: "%@ Step", other: "%@ Steps")
        if caption.stringValue != text { caption.stringValue = text }
    }
}
