import AppKit
import CoreGraphics
import Observation
import SQCore
import SQRender
import UniformTypeIdentifiers

/// One section of one Color effect: header with its switch, and a body that folds.
@MainActor
final class ColorSectionView: NSStackView {
    let effect: Int
    let kind: ColorSectionKind
    let header: ColorSectionHeader
    let body = NSStackView()
    var rows: [ColorParam: ColorParamRow] = [:]
    /// Color Range rows and its Invert box.
    var rangeRows: [ColorRangeParam: ColorParamRow] = [:]
    /// The Sharpen row of the primary Basic section.
    var sharpenRow: ColorParamRow?
    var rangeInvert: SQCheckbox?
    /// Color Range mask mode (ranges / color volume).
    var rangeMaskPopup: SQPopup?
    /// Zone Board: one wheel (puck + exposure slider) and one Saturation row per zone.
    var zoneWheels: [BoardZone: ColorWheelControl] = [:]
    var zoneSatRows: [BoardZone: ColorParamRow] = [:]
    var groups: [String: ColorGroupView] = [:]
    var wheels: [ColorWheelSlot: ColorWheelControl] = [:]
    var lutPopups: [ColorLUTSlot: LUTPopup] = [:]
    var curveEditor: CurveEditorView?
    var channelDots: ChannelDots?
    var hueEditor: CurveEditorView?
    var eyedropper: NSButton?
    var huePopup: SQPopup?
    var hueKind = HueCurveKind.hueVsSat
    var selectedChannel = 0

    init(effect: Int, kind: ColorSectionKind) {
        self.effect = effect
        self.kind = kind
        header = ColorSectionHeader(title: kind.title)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        addArrangedSubview(header)
        addArrangedSubview(body)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
}

/// One Color effect: its action line (Reset, more actions), then the fixed sections.
@MainActor
final class ColorEffectView: NSStackView {
    let effect: Int
    var sections: [ColorSectionKind: ColorSectionView] = [:]
    var actions: ColorActionRow?

    init(effect: Int) {
        self.effect = effect
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override var isFlipped: Bool { true }
}

/// The action line above the sections (design source `.chd`): 28 high, hairline above and below, an optional title
/// left, the controls right, 6 px apart, inside the 12 px panel inset.
@MainActor
final class ColorActionRow: NSView {
    let title = NSTextField(labelWithString: "")
    private let controls: [NSView]

    override var isFlipped: Bool { true }
    static let height = ColorGrid.popupRow
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    init(title text: String, controls: [NSView]) {
        self.controls = controls
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.height))
        title.stringValue = text
        title.font = Theme.Typography.bodyStrong
        title.textColor = Theme.Colors.label
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        for c in controls { addSubview(c) }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The hairlines above and below; the Pro page turns them off (sections there are told apart by spacing only).
    var showsRules = true { didSet { if showsRules != oldValue { needsDisplay = true } } }

    /// Version 9 `.note`: a warning tint behind the line and a warning icon before the text.
    var isWarning = false {
        didSet {
            guard isWarning != oldValue else { return }
            warningIcon.isHidden = !isWarning
            title.textColor = isWarning ? Theme.Colors.warning : Theme.Colors.label
            needsLayout = true
            needsDisplay = true
        }
    }
    private lazy var warningIcon: NSImageView = {
        let v = NSImageView()
        v.image = SQIcon.warning.image(size: 12, color: Theme.Colors.warning)
        v.image?.accessibilityDescription = "Warning"
        v.isHidden = true
        addSubview(v)
        return v
    }()

    override func draw(_ dirtyRect: NSRect) {
        if isWarning {
            Theme.Colors.warning.withAlphaComponent(0.10).setFill()
            bounds.fill()
        }
        guard showsRules else { return }
        Theme.Separator.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Separator.width).fill()
        NSRect(x: 0, y: bounds.height - Theme.Separator.width, width: bounds.width, height: Theme.Separator.width).fill()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var right = bounds.width - ColorGrid.inset
        for c in controls.reversed() {
            var s = c.intrinsicContentSize
            if let b = c as? SQButton, b.title.isEmpty { s.width = ColorGrid.iconButton }   // board `.btn.ic`
            right -= s.width
            c.frame = NSRect(x: right, y: ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
            right -= Theme.Spacing.iconToLabel
        }
        let th = ceil(title.intrinsicContentSize.height)
        var tx = ColorGrid.inset - ColorGrid.textInset
        if isWarning {
            let iw: CGFloat = 14
            warningIcon.frame = NSRect(x: tx, y: ((h - iw) / 2).rounded(), width: iw, height: iw)
            tx += iw + Theme.Spacing.iconToLabel
        }
        title.frame = NSRect(x: tx, y: ((h - th) / 2).rounded(), width: max(right - ColorGrid.inset - (tx - ColorGrid.inset + ColorGrid.textInset), 0), height: th)
    }
}

/// Color inspector of the Color page (design board "Color", build.py `colorinsp`): Interpret As and Project Input,
/// the action line (Reset, more actions), then the sections Basic, Look, Curves, Wheels & Match, Color Range and
/// Vignette, each with its chevron left and its enable box right. Everything sits on one grid (`ColorGrid`). "Add
/// Color Effect" in the actions stacks another effect below.
@MainActor
public final class ColorInspectorView: NSView {
    public let model: ColorInspectorModel

    private let stack = NSStackView()
    private lazy var sourcePicker = InputPickerView(label: "Interpret As", automaticTitle: { [weak self] in ColorInputChoices.automaticTitle(detected: self?.model.detectedSource ?? .rec709) })
    /// W9.3: the project's camera input (untagged video that detected as Rec. 709); index 0 = None.
    private lazy var projectPicker = InputPickerView(label: "Project Input", automaticTitle: { ColorInputChoices.noProjectInput })
    private let footageRows = FootageRows()
    private let effectsStack = NSStackView()
    /// Version 9 has no input rows above the sections: Interpret As and Project Input fold into "Input color" below them.
    private let inputHeader = ColorSectionHeader(title: "Input color")
    private let inputBody = NSStackView()
    private var inputOpen = false
    /// The Pro page (Color Graph); shown instead of the Simple effects while the clip's grade is Pro.
    private(set) lazy var proPage = ColorGraphPage(model: model)
    private var effectViews: [Int: ColorEffectView] = [:]
    private var builtSignature: [Int] = []
    private var builtTitles: [String] = []

    private static func name(_ id: ColorSpaceID) -> String { id.displayName }

    public init(model: ColorInspectorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 640))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        rebuildEffects()
        refresh()
        observe()
        NotificationCenter.default.addObserver(self, selector: #selector(thumbnailsReady), name: ColorLookPreview.thumbnailsReady, object: nil)
    }
    @objc private func thumbnailsReady() { refresh() }
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Build

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: ColorGrid.rowWidth(panelWidth: .greatestFiniteMagnitude)),
        ])
        // Fill the panel up to the row cap; a wider panel keeps the rows leading-aligned at the cap.
        let fill = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        fill.priority = .defaultHigh
        fill.isActive = true

        sourcePicker.onChange = { [weak self] space in
            guard let self else { return }
            self.model.gesture { self.model.setSourceOverride(space) }
        }
        sourcePicker.popup.setAccessibilityLabel("Interpret footage as")

        footageRows.onLogMode = { [weak self] in self?.model.setLogMode($0) }
        footageRows.onTarget = { [weak self] in self?.model.setTargetSpace($0) }
        footageRows.onConform = { [weak self] in self?.model.setHDRConform($0) }

        projectPicker.onChange = { [weak self] space in self?.model.setProjectInput(space) }
        projectPicker.popup.setAccessibilityLabel("Project camera input for untagged footage")
        projectPicker.popup.sqToolTip = "Applies to every untagged clip in the project that is set to Automatic."

        effectsStack.orientation = .vertical
        effectsStack.alignment = .leading
        effectsStack.spacing = 0
        pin(effectsStack, in: stack)
        pin(proPage, in: stack)
        inputBody.orientation = .vertical
        inputBody.alignment = .leading
        inputBody.spacing = 0
        inputHeader.onToggleOpen = { [weak self] in
            guard let self else { return }
            inputOpen.toggle()
            refresh()
        }
        // Render harness hook (`sq.color.setInputOpen`, object: Bool): unfolds or folds "Input color" without a click.
        NotificationCenter.default.addObserver(forName: Notification.Name("sq.color.setInputOpen"), object: nil, queue: .main) { [weak self] n in
            guard let on = n.object as? Bool else { return }
            MainActor.assumeIsolated { self?.inputOpen = on; self?.refresh() }
        }
        pin(inputHeader, in: stack)
        pin(inputBody, in: stack)
        pin(sourcePicker.row, in: inputBody)
        pin(footageRows.logRow, in: inputBody)
        pin(footageRows.targetRow, in: inputBody)
        pin(footageRows.conformRow, in: inputBody)
        pin(projectPicker.row, in: inputBody)
        pin(spacer(Theme.Spacing.lg), in: stack)
    }

    private func style(_ popup: NSPopUpButton) {
        popup.font = Theme.Typography.body
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    /// Adds `row` at the full width of `parent`: every row brings its own inset from `ColorGrid`.
    private func pin(_ row: NSView, in parent: NSStackView) {
        parent.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    }

    /// `view` inside the panel inset, `top` above and `bottom` below it.
    private func inset(_ view: NSView, height: CGFloat, top: CGFloat, bottom: CGFloat) -> NSView {
        let box = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: ColorGrid.inset),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -ColorGrid.inset),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -bottom),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
        return box
    }

    // MARK: Effects and sections

    private func rebuildEffects() {
        for v in effectsStack.arrangedSubviews { effectsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        effectViews = [:]
        let multiple = model.effects.count > 1
        for (n, e) in model.effects.enumerated() {
            let v = ColorEffectView(effect: e.id)
            addActions(to: v, effect: e.id, number: n + 1, removable: multiple)
            for kind in Self.sectionOrder {
                let s = makeSection(effect: e.id, kind: kind, isPrimary: n == 0)
                v.sections[kind] = s
                pin(s, in: v)
            }
            effectViews[e.id] = v
            pin(v, in: effectsStack)
        }
        builtSignature = model.effects.map(\.id)
        builtTitles = titles()
    }

    static let sectionOrder = ColorSectionText.order

    private func titles() -> [String] { model.effects.enumerated().map { title($1.id, number: $0 + 1) } }

    /// The action line's title: empty for the one effect of a clip (the panel header names the page), "Color n" when
    /// several are stacked, plus the time range of a range grade.
    private func title(_ effect: Int, number: Int) -> String {
        var parts: [String] = []
        if model.effects.count > 1 { parts.append(number == 1 ? "Color" : "Color \(number)") }
        if let r = model.effectRangeLabels[effect] { parts.append(r) }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    private func addActions(to v: ColorEffectView, effect: Int, number: Int, removable: Bool) {
        let reset = SQButton(title: "Reset", target: self, action: #selector(resetEffectPressed(_:)))
        reset.tag = effect
        reset.sqToolTip = "Reset every section of this effect"
        reset.setAccessibilityLabel(number == 1 ? "Reset Color" : "Reset Color \(number)")
        let more = SQButton(symbol: .ellipsis, label: "More Color actions", target: self, action: #selector(moreActionsPressed(_:)), size: 12)
        more.tag = effect
        more.contentTintColor = Theme.Colors.label2     // board `.btn.ic`: t2
        more.identifier = NSUserInterfaceItemIdentifier(removable ? "removable" : "single")
        let row = ColorActionRow(title: title(effect, number: number), controls: [reset, more])
        row.isHidden = row.title.stringValue.isEmpty      // one effect: its actions are in the panel header's menu
        v.actions = row
        pin(row, in: v)
    }

    private func makeSection(effect: Int, kind: ColorSectionKind, isPrimary: Bool) -> ColorSectionView {
        let v = ColorSectionView(effect: effect, kind: kind)
        let key = ColorPanelKey(effect, kind)
        v.header.onMenu = { [weak self] p in self?.showSectionMenu(effect: effect, kind: kind, at: p) }
        v.header.onToggleOpen = { [weak self] in
            guard let self else { return }
            self.model.setCollapsed(key, !self.model.isCollapsed(key))
        }
        v.header.toggle.target = self
        v.header.toggle.action = #selector(switchToggled(_:))
        v.header.toggle.identifier = NSUserInterfaceItemIdentifier("\(effect)|\(kind.rawValue)")

        switch kind {
        case .basicCorrection: buildBasic(v, isPrimary: isPrimary)
        case .creative: buildCreative(v)
        case .curves: buildCurves(v)
        case .wheels: buildWheels(v)
        case .hslSecondary: buildColorRange(v)
        case .zoneBoard: buildZoneBoard(v)
        case .vignette: addParamGroups(v)
        }
        return v
    }

    /// Board "Basic": Source LUT with its star, Intensity, then the groups COLOR (White Balance with its picker, Temperature,
    /// Tint, Saturation) and LIGHT (Exposure to Blacks). The popup's "None" item clears the LUT.
    private func buildBasic(_ v: ColorSectionView, isPrimary: Bool) {
        let popup = makePopup(v, slot: .input, label: "Source LUT")
        pin(ColorControlRow(title: "Source LUT", controls: [popup, chip(for: popup), star(for: popup)], height: ColorGrid.popupRow), in: v.body)
        let intensity = paramRow(v, .inputLUTIntensity)
        intensity.sqToolTip = isPrimary ? "The conversion LUT of the first effect always runs at full strength." : nil
        pin(intensity, in: v.body)

        let eyedropper = SQButton(symbol: .eyedropper, label: "White balance picker",
                                  target: self, action: #selector(pickWhiteBalance(_:)))
        eyedropper.tag = v.effect
        v.eyedropper = eyedropper
        eyedropper.sqToolTip = "Click a neutral gray or white area in the Program monitor to set the white balance"
        eyedropper.contentTintColor = Theme.Colors.label2
        v.header.accessory = eyedropper      // version 9: the white balance picker sits in the Basic header
        addParamGroups(v)
        if isPrimary {
            let r = ColorParamRow(nil, title: "Sharpen", range: Clip.sharpenRowRange, neutral: 0, decimals: 0)
            r.setActive(true)
            r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
            r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
            r.onCancel = { [weak self] in self?.model.onGestureCancelled?() }
            r.onSet = { [weak self] value in self?.model.setSharpen(value) }
            r.onReset = { [weak self] in self?.model.gesture { self?.model.setSharpen(0) } }
            v.sharpenRow = r
            pin(r, in: v.body)
        }
    }

    /// Board "Look": the Look LUT with its star, Intensity, then the group ADJUSTMENTS (Fade, Vibrance, Saturation, Tint Mix).
    /// The shadow/highlight tint wheels are on no board: hidden (model and engine keep them), see DECISIONS 2026-10-04.
    private func buildCreative(_ v: ColorSectionView) {
        let popup = makePopup(v, slot: .look, label: "Look LUT")
        pin(ColorControlRow(title: "Look LUT", controls: [popup, chip(for: popup), star(for: popup)], height: ColorGrid.popupRow), in: v.body)
        pin(paramRow(v, .lookIntensity), in: v.body)
        addParamGroups(v)
    }

    private func buildCurves(_ v: ColorSectionView) {
        let group = makeGroup(v, title: "RGB Curves")
        group.header.hasRule = false
        let dots = ChannelDots()
        dots.onSelect = { [weak self, weak v] i in
            v?.selectedChannel = i
            self?.refresh()
        }
        v.channelDots = dots
        pin(dots, in: group.content)
        let editor = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 200, height: ColorGrid.rgbCurve))
        editor.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        editor.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        let id = v.effect
        editor.onChange = { [weak self, weak v] pts in
            guard let self, let v else { return }
            var c = self.model.curves(id)
            switch v.selectedChannel { case 1: c.red = pts; case 2: c.green = pts; case 3: c.blue = pts; default: c.master = pts }
            self.model.setCurves(id, c)
        }
        v.curveEditor = editor
        pin(inset(editor, height: ColorGrid.rgbCurve, top: ColorGrid.curveTop, bottom: ColorGrid.curveBottom), in: group.content)
        pin(group, in: v.body)

        // Hue Saturation Curves: one curve at a time, chosen in the popup.
        let hueGroup = makeGroup(v, title: "Hue Saturation Curves")
        let popup = SQPopup(frame: .zero, pullsDown: false)
        style(popup)
        for k in HueCurveKind.allCases { popup.addItem(withTitle: k.title) }
        popup.target = self
        popup.action = #selector(hueCurveKindChanged(_:))
        popup.identifier = NSUserInterfaceItemIdentifier("\(v.effect)")
        popup.setAccessibilityLabel("Hue Saturation Curve")
        v.huePopup = popup
        pin(ColorControlRow(title: "Curve", controls: [popup]), in: hueGroup.content)
        let hue = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 200, height: ColorGrid.hueCurve))
        hue.flatBaseline = true
        hue.points = HueCurves.flat
        hue.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        hue.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        hue.onChange = { [weak self, weak v] pts in
            guard let self, let v else { return }
            self.model.setHueCurve(id, v.hueKind, pts)
        }
        v.hueEditor = hue
        pin(inset(hue, height: ColorGrid.hueCurve, top: ColorGrid.curveTop, bottom: ColorGrid.curveBottom), in: hueGroup.content)
        pin(hueGroup, in: v.body)
    }

    /// Color Range: the qualifier (hue, saturation and luma range, softness, invert) and the correction inside it. The
    /// first edit creates the range; "Reset Color Range" removes it.
    private func buildColorRange(_ v: ColorSectionView) {
        let id = v.effect
        let range = makeGroup(v, title: "Range")
        let mode = SQPopup(frame: .zero, pullsDown: false)
        style(mode)
        for m in HSLSecondary.MaskMode.allCases { mode.addItem(withTitle: m.title) }
        mode.target = self
        mode.action = #selector(rangeMaskModeChanged(_:))
        mode.tag = id
        mode.setAccessibilityLabel("Color Range mask")
        v.rangeMaskPopup = mode
        pin(ColorControlRow(title: "Mask", controls: [mode]), in: range.content)
        for p in ColorRangeParam.allCases where p.isQualifier || p.isVolume { pin(rangeRow(v, p), in: range.content) }
        let invert = SQCheckbox(title: "Correct outside (Inside / Outside)", target: self, action: #selector(rangeInvertToggled(_:)))
        invert.tag = id
        invert.setAccessibilityLabel("Invert Color Range")
        v.rangeInvert = invert
        pin(ColorControlRow(title: "Invert", controls: [invert], stretchFirst: false), in: range.content)
        pin(range, in: v.body)
        let correction = makeGroup(v, title: "Correction")
        for p in ColorRangeParam.allCases where p.isCorrection { pin(rangeRow(v, p), in: correction.content) }
        pin(correction, in: v.body)
    }

    private func rangeRow(_ v: ColorSectionView, _ p: ColorRangeParam) -> ColorParamRow {
        let id = v.effect
        let r = ColorParamRow(nil, title: p.title, range: p.range, neutral: p.neutral, decimals: p.decimals)
        r.slider.track = p.track
        r.setActive(true)
        r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        r.onCancel = { [weak self] in self?.model.onGestureCancelled?() }
        r.onSet = { [weak self] value in self?.model.setRange(id, p, value) }
        r.onReset = { [weak self] in self?.model.resetRangeParameter(id, p) }
        v.rangeRows[p] = r
        return r
    }

    @objc private func rangeMaskModeChanged(_ p: SQPopup) {
        model.setRangeMaskMode(p.tag, HSLSecondary.MaskMode.allCases[max(0, p.indexOfSelectedItem)])
    }

    /// Zone Board: four wheels in a row (puck = tint, side slider = exposure), then one Saturation row per zone.
    private func buildZoneBoard(_ v: ColorSectionView) {
        let id = v.effect
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .equalCentering
        row.spacing = Theme.Spacing.xs
        let size = ColorGrid.wheel - 20
        for zone in BoardZone.allCases {
            let w = ColorWheelControl(frame: NSRect(x: 0, y: 0, width: size, height: size + Theme.Spacing.lg))
            w.title = zone.title
            w.showsMaster = true
            w.translatesAutoresizingMaskIntoConstraints = false
            w.widthAnchor.constraint(equalToConstant: size - 10).isActive = true
            w.heightAnchor.constraint(equalToConstant: size + Theme.Spacing.lg).isActive = true
            w.onBegin = { [weak self] _ in self?.model.onGestureBegan?() }
            w.onEnd = { [weak self] _ in self?.model.onGestureEnded?() }
            w.onChange = { [weak self, weak w] part in
                guard let self, let w else { return }
                switch part {
                case .wheel: self.model.setZonePuck(id, zone, hue: Float(w.hue), amount: Float(w.amount))
                case .master: self.model.setZoneExposure(id, zone, slider: Float(w.master))
                }
            }
            v.zoneWheels[zone] = w
            row.addArrangedSubview(w)
        }
        pin(inset(row, height: size + Theme.Spacing.lg + Theme.Spacing.sm, top: Theme.Spacing.xs, bottom: Theme.Spacing.xs), in: v.body)
        let group = makeGroup(v, title: "Saturation")
        for zone in BoardZone.allCases {
            let r = ColorParamRow(nil, title: zone.title, range: 0...200, neutral: 100, decimals: 0)
            r.setActive(true)
            r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
            r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
            r.onCancel = { [weak self] in self?.model.onGestureCancelled?() }
            r.onSet = { [weak self] value in self?.model.setZoneSaturation(id, zone, percent: value) }
            r.onReset = { [weak self] in self?.model.resetZone(id, zone) }
            v.zoneSatRows[zone] = r
            pin(r, in: group.content)
        }
        pin(group, in: v.body)
    }

    @objc private func rangeInvertToggled(_ b: SQCheckbox) { model.setRangeInvert(b.tag, b.state == .on) }

    private func buildWheels(_ v: ColorSectionView) {
        pin(wheelRow(v, [.shadows, .midtones, .highlights], showsMaster: true), in: v.body)
        addParamGroups(v)
    }

    /// Plain rows of a section (Vignette, Wheels saturation).
    /// Named groups get their label (the first one without a rule above it); `firstRow` leads the first group.
    private func addParamGroups(_ v: ColorSectionView, firstRow: NSView? = nil) {
        var first = true
        for g in ColorParam.layout(for: v.kind) {
            var host: NSStackView = v.body
            if let title = g.group {
                let group = makeGroup(v, title: title)
                group.header.hasRule = !first
                // Version 9: Basic and Creative are plain lists, no group labels.
                group.header.isHidden = v.kind == .basicCorrection || v.kind == .creative
                pin(group, in: v.body)
                host = group.content
            }
            if first, let firstRow { pin(firstRow, in: host) }
            first = false
            for p in g.params { pin(paramRow(v, p), in: host) }
        }
    }

    private func makePopup(_ v: ColorSectionView, slot: ColorLUTSlot, label: String) -> LUTPopup {
        let popup = LUTPopup(frame: .zero, pullsDown: false)
        style(popup)
        popup.effect = v.effect
        popup.slot = slot
        popup.target = self
        popup.action = #selector(lutChosen(_:))
        popup.setAccessibilityLabel(label)
        v.lutPopups[slot] = popup
        return popup
    }

    /// Amber warning chip next to a LUT popup; hidden until the LUT's expected space differs from the clip's.
    private func chip(for popup: LUTPopup) -> NSView {
        let v = NSImageView()
        v.image = SQIcon.warning.image(size: 13, color: Theme.Colors.warning)
        v.isHidden = true
        v.setAccessibilityLabel("LUT color space mismatch")
        popup.mismatchChip = v
        return v
    }

    /// The star next to a LUT popup: favorites the selected library LUT.
    private func star(for popup: LUTPopup) -> NSView {
        let star = SQButton(symbol: .star, label: "Favorite LUT", target: self, action: #selector(starPressed(_:)))
        star.contentTintColor = Theme.Colors.label2
        star.isEnabled = false
        popup.star = star
        return star
    }

    private func makeGroup(_ v: ColorSectionView, title: String) -> ColorGroupView {
        let g = ColorGroupView(title: title)
        v.groups[title] = g
        return g
    }

    private func paramRow(_ v: ColorSectionView, _ p: ColorParam) -> ColorParamRow {
        let id = v.effect
        let r = ColorParamRow(p)
        r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        r.onCancel = { [weak self] in self?.model.onGestureCancelled?() }
        r.onSet = { [weak self] value in self?.model.set(id, p, value) }
        r.onReset = { [weak self] in self?.model.resetParameter(id, p) }
        v.rows[p] = r
        return r
    }

    /// Wheels side by side, evenly spread inside the panel inset.
    private func wheelRow(_ v: ColorSectionView, _ slots: [ColorWheelSlot], showsMaster: Bool) -> NSView {
        let w = NSStackView()
        w.orientation = .horizontal
        w.distribution = .equalCentering
        w.spacing = Theme.Spacing.sm
        for slot in slots { w.addArrangedSubview(wheel(v, slot, showsMaster: showsMaster, size: ColorGrid.wheel)) }
        return inset(w, height: ColorGrid.wheel + Theme.Spacing.lg, top: Theme.Spacing.xs, bottom: Theme.Spacing.xs)
    }

    private func wheel(_ v: ColorSectionView, _ slot: ColorWheelSlot, showsMaster: Bool, size: CGFloat) -> NSView {
        let id = v.effect
        let w = ColorWheelControl(frame: NSRect(x: 0, y: 0, width: size, height: size + Theme.Spacing.lg))
        w.title = slot.title
        w.showsMaster = showsMaster
        w.translatesAutoresizingMaskIntoConstraints = false
        w.widthAnchor.constraint(equalToConstant: showsMaster ? size - 10 : size).isActive = true
        w.heightAnchor.constraint(equalToConstant: size + Theme.Spacing.lg).isActive = true
        w.onBegin = { [weak self] _ in self?.model.onGestureBegan?() }
        w.onEnd = { [weak self] _ in self?.model.onGestureEnded?() }
        w.onChange = { [weak self, weak w] part in
            guard let self, let w else { return }
            switch part {
            case .wheel: self.model.setWheel(id, slot, hue: Float(w.hue), amount: Float(w.amount))
            case .master: self.model.setWheelLuma(id, slot, Float(w.master * 100))
            }
        }
        v.wheels[slot] = w
        return w
    }


    // MARK: Actions

    @objc private func hueCurveKindChanged(_ p: SQPopup) {
        guard let raw = p.identifier?.rawValue, let id = Int(raw), let kind = HueCurveKind(rawValue: p.indexOfSelectedItem),
              let v = effectViews[id]?.sections[.curves] else { return }
        v.hueKind = kind
        refresh()
    }

    /// The section's own menu (version 9 has no enable box in the header): on / off and reset.
    private func showSectionMenu(effect: Int, kind: ColorSectionKind, at p: NSPoint) {
        guard let e = model.effects.first(where: { $0.id == effect }) else { return }
        let on = e.isEnabled(kind)
        let name = kind.title
        var items = [
            SQMenuItem(title: SQL10n.format(on ? "Turn %@ Off" : "Turn %@ On", SQL10n.string(name))) { [weak self] in self?.model.setEnabled(effect, kind, !on) },
            SQMenuItem(title: SQL10n.format("Reset %@", SQL10n.string(name))) { [weak self] in self?.model.resetSection(effect, kind) },
        ]
        if kind == .curves {
            items.append(SQMenuItem(title: "Hold Saturation Legal") { [weak self] in self?.model.holdSaturationLegal(effect) })
        }
        SQMenuController.shared.present(items: items, at: p)
    }

    /// What the panel header's menu adds for the Simple grade of a clip with one effect (its action line is hidden):
    /// Add Color Effect, Auto Tone, the resets, and each section's switch.
    public func simpleActionItems() -> [SQMenuItem] {
        guard let e = model.effects.first else { return [] }
        let id = e.id
        var items = [SQMenuItem(title: "Add Color Effect") { [weak self] in self?.model.addEffect() }]
        if model.effectRangeLabels[id] != nil {
            items.append(SQMenuItem(title: "Set Range to In/Out") { [weak self] in self?.model.onGradeAction?(.setRangeToInOut(id)) })
            items.append(SQMenuItem(title: "Grade Whole Clip") { [weak self] in self?.model.onGradeAction?(.wholeClip(id)) })
        }
        items.append(SQMenuItem(title: "Auto Tone", isEnabled: model.autoToneBlock(id) == nil) { [weak self] in self?.model.onAutoTone?(id) })
        items.append(SQMenuItem(title: "Reset Tone") { [weak self] in self?.model.resetTone(id) })
        var resets: [SQMenuItem] = []
        for r in model.sectionResets(id) {
            resets.append(SQMenuItem(title: r.title, isEnabled: r.enabled) { [weak self] in self?.model.resetSection(id, r.kind) })
        }
        items.append(SQMenuItem(title: "Reset Section", submenu: resets))
        var switches: [SQMenuItem] = []
        for kind in Self.sectionOrder {
            let on = e.isEnabled(kind)
            switches.append(SQMenuItem(title: kind.title, isChecked: on) { [weak self] in
                self?.model.setEnabled(id, kind, !on)
            })
        }
        items.append(SQMenuItem(title: "Sections", submenu: switches))
        return items
    }

    @objc private func moreActionsPressed(_ b: NSButton) {
        let effect = b.tag
        var items: [SQMenuItem] = [
            SQMenuItem(title: "Copy Grade", shortcut: "\u{2318}C") { [weak self] in self?.model.onCopyColor?() },
            SQMenuItem(title: "Paste Grade", shortcut: "\u{2318}V") { [weak self] in self?.model.onPasteColor?() },
            SQMenuItem(title: "Add Color Effect") { [weak self] in self?.model.addEffect() },
            .separator,
        ]
        items.append(SQMenuItem(title: "Link Grade to Selected Clips") { [weak self] in self?.model.onGradeAction?(.linkSelected) })
        items.append(SQMenuItem(title: "Link All Clips of This Source") { [weak self] in self?.model.onGradeAction?(.linkSource) })
        if model.linkedClipCount > 1 {
            items.append(SQMenuItem(title: "Unlink Grade") { [weak self] in self?.model.onGradeAction?(.unlink) })
        }
        items.append(SQMenuItem(title: "Grade Whole Sequence") { [weak self] in self?.model.onGradeWholeSequence?() })
        items.append(SQMenuItem(title: "Add Range Grade") { [weak self] in self?.model.onGradeAction?(.addRange) })
        if model.effectRangeLabels[effect] != nil {
            items.append(SQMenuItem(title: "Set Range to In/Out") { [weak self] in self?.model.onGradeAction?(.setRangeToInOut(effect)) })
            items.append(SQMenuItem(title: "Grade Whole Clip") { [weak self] in self?.model.onGradeAction?(.wholeClip(effect)) })
        }
        items.append(.separator)
        // Pro grade (Color Graph): not on the board, reachable here.
        if model.shownGrade == .pro {
            items.append(SQMenuItem(title: "Use Simple Grade") { [weak self] in self?.model.setActiveGrade(.simple) })
        } else {
            items.append(SQMenuItem(title: "Use Pro Grade (Color Graph)") { [weak self] in self?.model.setActiveGrade(.pro) })
            items.append(SQMenuItem(title: "Send Simple Values to Pro", isEnabled: model.canSendToPro) { [weak self] in
                guard let self else { return }
                self.model.sendToPro()
                SQToast.show("Copied into a new Color Graph. Simple is unchanged.", in: self)
            })
        }
        items.append(.separator)
        items.append(SQMenuItem(title: "Auto Tone", isEnabled: model.autoToneBlock(effect) == nil) { [weak self] in self?.model.onAutoTone?(effect) })
        items.append(SQMenuItem(title: "Reset Tone") { [weak self] in self?.model.resetTone(effect) })
        for r in model.sectionResets(effect) {
            items.append(SQMenuItem(title: r.title, isEnabled: r.enabled) { [weak self] in self?.model.resetSection(effect, r.kind) })
        }
        if b.identifier?.rawValue == "removable" {
            items.append(.separator)
            items.append(SQMenuItem(title: "Remove Effect") { [weak self] in self?.model.removeEffect(effect) })
        }
        guard let window = b.window else { return }
        let inWindow = b.convert(NSPoint(x: b.bounds.minX, y: b.bounds.minY), to: nil)
        SQMenuController.shared.present(items: items, at: window.convertPoint(toScreen: inWindow))
    }

    @objc private func resetEffectPressed(_ b: NSButton) { model.resetEffect(b.tag) }
    @objc private func pickWhiteBalance(_ b: NSButton) { model.onPickWhiteBalance?(b.tag) }

    @objc private func switchToggled(_ s: NSButton) {
        let parts = (s.identifier?.rawValue ?? "").split(separator: "|")
        guard parts.count == 2, let effect = Int(parts[0]), let kind = ColorSectionKind(rawValue: String(parts[1])) else { return }
        model.setEnabled(effect, kind, s.state == .on)
    }

    @objc private func lutChosen(_ popup: LUTPopup) {
        switch popup.picks[safe: popup.indexOfSelectedItem] {
        case .choice(let c)?: model.setLUT(popup.effect, popup.slot, c)
        case .chooseFile?:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
            panel.allowsMultipleSelection = false
            panel.message = "Choose a .cube LUT"
            if panel.runModal() == .OK, let url = panel.url { model.setLUT(popup.effect, popup.slot, .file(url.path)) } else { refresh() }
        case .addToLibrary?:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
            panel.allowsMultipleSelection = true
            panel.message = "Add .cube LUTs to your library (copied, originals stay where they are)"
            guard panel.runModal() == .OK else { refresh(); return }
            let added = model.importLUTs(panel.urls)
            if let first = added.first { model.setLUT(popup.effect, popup.slot, first) } else { refresh() }
        case nil, .inert?: refresh()
        }
    }

    @objc private func starPressed(_ b: NSButton) {
        for ev in effectViews.values {
            for v in ev.sections.values {
                for popup in v.lutPopups.values where popup.star === b {
                    if case .choice(let c?)? = popup.picks[safe: popup.indexOfSelectedItem] { model.toggleFavouriteLUT(c) }
                }
            }
        }
    }

    // MARK: Refresh

    private func observe() {
        withObservationTracking {
            _ = model.color
            _ = model.collapsed
            _ = model.availableLUTs
            _ = model.libraryLUTs
            _ = model.recentLUTs
            _ = model.detectedSource
            _ = model.samplingBlock
            _ = model.embeddedLUTName
            _ = model.projectInput
            _ = model.mediaInfo
            _ = model.effectRangeLabels
            _ = model.linkedClipCount
            _ = model.graph
            _ = model.selectedStep
            _ = model.showsEmptyPro
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    /// Updates all controls from the model; rebuilds the sections first when the set of effects changed.
    public func refresh() {
        if builtSignature != model.effects.map(\.id) { rebuildEffects() }
        let now = titles()
        if builtTitles != now {
            builtTitles = now
            for (n, e) in model.effects.enumerated() {
                effectViews[e.id]?.actions?.title.stringValue = now[n]
                effectViews[e.id]?.actions?.isHidden = now[n].isEmpty
            }
        }

        sourcePicker.reload(override: model.sourceOverride)
        projectPicker.reload(override: model.projectInput)
        footageRows.reload(logMode: model.logMode, target: model.targetSpace, conform: model.hdrConform)
        inputHeader.setOpen(inputOpen)
        inputHeader.setSummary(sourcePicker.popup.titleOfSelectedItem ?? "")
        inputBody.isHidden = !inputOpen
        let pro = model.shownGrade == .pro
        effectsStack.isHidden = pro
        proPage.isHidden = !pro
        if pro { proPage.refresh() }

        for (n, e) in model.effects.enumerated() {
            guard let ev = effectViews[e.id] else { continue }
            for (kind, v) in ev.sections { refreshSection(v, effect: e, kind: kind, isPrimary: n == 0) }
        }
    }

    private func refreshSection(_ v: ColorSectionView, effect e: ColorEffect, kind: ColorSectionKind, isPrimary: Bool) {
        let on = e.isEnabled(kind)
        let open = !model.isCollapsed(ColorPanelKey(e.id, kind))
        v.header.setOn(on)
        v.header.setOpen(open)
        v.header.setSummary(Self.summary(kind, channel: v.selectedChannel, effect: e))
        v.body.isHidden = !open
        v.body.alphaValue = on ? 1 : Theme.State.disabledAlpha
        for (p, r) in v.rows { r.show(model.value(e.id, p)) }
        for (p, r) in v.rangeRows { r.show(model.rangeValue(e.id, p)) }
        v.rangeInvert?.state = e.hslSecondary?.invert == true ? .on : .off
        let maskMode = e.hslSecondary?.maskMode ?? .ranges
        v.rangeMaskPopup?.selectItem(at: HSLSecondary.MaskMode.allCases.firstIndex(of: maskMode) ?? 0)
        for (p, r) in v.rangeRows { r.isHidden = !p.isShown(in: maskMode) }
        for (zone, w) in v.zoneWheels where !w.isDragging {
            let pv = model.zonePuckWheel(e.id, zone)
            w.hue = Double(pv.hue); w.amount = Double(pv.amount); w.master = Double(model.zoneExposureSlider(e.id, zone))
        }
        for (zone, r) in v.zoneSatRows { r.show(model.zoneSaturationPercent(e.id, zone)) }
        for (slot, w) in v.wheels {
            let st = model.wheel(e.id, slot)
            w.hue = Double(st.value.hue); w.amount = Double(st.value.amount); w.master = Double(st.luma / 100)
        }
        for (slot, popup) in v.lutPopups { refreshLUTPopup(popup, slot: slot, effect: e.id, isPrimary: isPrimary) }
        if kind == .basicCorrection {
            v.sharpenRow?.show(model.sharpen)
            let block = model.samplingBlock
            v.eyedropper?.isEnabled = block == nil
            v.eyedropper?.sqToolTip = block ?? "Click a neutral gray or white area in the Program monitor to set the white balance"
            let hasLUT = e.inputLUT != nil && e.inputLUT != .automatic
            // Version 9 has no Intensity row: it shows only where it does something (a LUT on a later effect).
            v.rows[.inputLUTIntensity]?.setActive(!isPrimary && hasLUT)
            v.rows[.inputLUTIntensity]?.isHidden = isPrimary || !hasLUT
        }
        if kind == .creative { v.rows[.lookIntensity]?.isHidden = e.creative.look == nil }
        if let hue = v.hueEditor, let popup = v.huePopup {
            popup.selectItem(at: v.hueKind.rawValue)
            hue.hueStrip = v.hueKind.isHueKeyed
            hue.sqToolTip = v.hueKind.explanation
            popup.sqToolTip = v.hueKind.explanation
            hue.points = model.hueCurve(e.id, v.hueKind)
            hue.lineColor = Theme.Colors.label
        }
        if let editor = v.curveEditor, let dots = v.channelDots {
            dots.selected = v.selectedChannel
            let c = e.curves
            let (pts, color): ([CurvePoint], NSColor) = switch v.selectedChannel {
            case 1: (c.red, Theme.Colors.red)
            case 2: (c.green, Theme.Colors.green)
            case 3: (c.blue, Theme.Palette.graphCurve[8])
            default: (c.master, Theme.Colors.label)
            }
            editor.points = pts
            editor.lineColor = color
        }
    }

    /// What a folded section reads at its right end (portable: `ColorSectionText.summary`).
    static func summary(_ kind: ColorSectionKind, channel: Int, effect e: ColorEffect) -> String {
        ColorSectionText.summary(kind, channel: channel, effect: e)
    }

    private static let thumbnailPlaceholder: NSImage = {
        NSImage(size: Theme.Row.swatch, flipped: false) { r in
            Theme.Colors.field.setFill(); NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill(); return true
        }
    }()

    private func refreshLUTPopup(_ popup: LUTPopup, slot: ColorLUTSlot, effect: Int, isPrimary: Bool) {
        let current = model.lutChoice(effect, slot)
        // Board order: Automatic / None, then Favorites, Library, and the two file actions, each group after a separator.
        var items: [(String, LUTPopup.Pick)] = []
        var headerTitles: [Int: String] = [:]
        func sep() { items.append(("", .inert)) }
        func header(_ t: String) { headerTitles[items.count] = t; items.append((t, .inert)) }
        if slot == .input && isPrimary {
            items.append(("Automatic", .choice(.automatic)))
            if let n = model.embeddedLUTName { items.append(("Embedded: \(n)", .choice(.embedded(name: n)))) }
            else if current?.id == "embedded", let c = current { items.append((c.name, .choice(c))) }
        }
        items.append(("None", .choice(nil)))
        var seen = Set<String>()
        let favourites = model.libraryLUTs.filter(\.isFavourite)
        let others = model.libraryLUTs.filter { !$0.isFavourite }
        if !favourites.isEmpty {
            sep(); header("Favorites")
            for e in favourites { let c = ColorInspectorModel.LUTChoice.file(e.path); items.append((e.name, .choice(c))); seen.insert(c.id) }
        }
        var library: [(String, LUTPopup.Pick)] = []
        for e in others { let c = ColorInspectorModel.LUTChoice.file(e.path); library.append((e.name, .choice(c))); seen.insert(c.id) }
        if let c = current, c.filePath != nil, !seen.contains(c.id) { library.append((c.name, .choice(c))); seen.insert(c.id) }
        var extra = 0
        for c in model.lookChoices where !seen.contains(c.id) && extra < 10 {
            library.append((c.name, .choice(c))); seen.insert(c.id); extra += 1
        }
        if !library.isEmpty { sep(); header("Library"); items.append(contentsOf: library) }
        sep()
        items.append(("Add LUTs to Library…", .addToLibrary))
        items.append(("Choose File…", .chooseFile))
        popup.removeAllItems()
        popup.picks = items.map(\.1)
        for (idx, (title, pick)) in items.enumerated() {
            if case .inert = pick {
                if let h = headerTitles[idx] { popup.menu?.addItem(NSMenuItem.sectionHeader(title: h)) }
                else { popup.menu?.addItem(.separator()) }
                continue
            }
            popup.addItem(withTitle: title)
            // Thumbnail of what the LUT does to the test picture: placeholder until the background render lands.
            if case .choice(let c?) = pick, let path = c.filePath, let item = popup.lastItem {
                if let cached = ColorLookPreview.thumbnail(forLookPath: path) {
                    let img = (cached.copy() as? NSImage) ?? NSImage()
                    img.size = Theme.Row.swatch
                    item.image = img
                } else {
                    item.image = Self.thumbnailPlaceholder
                }
            }
        }
        let i = items.firstIndex { if case .choice(let c) = $0.1 { c == current } else { false } } ?? 0
        popup.selectItem(at: i)
        let starred = current.map(model.isFavouriteLUT) ?? false
        let inLibrary = current.flatMap(\.filePath).map { p in model.libraryLUTs.contains { $0.path == p } } ?? false
        popup.clear?.isEnabled = current != nil
        let mismatch = model.lutMismatch(effect, slot)
        popup.mismatchChip?.isHidden = mismatch == nil
        popup.mismatchChip?.sqToolTip = mismatch ?? ""
        popup.star?.isEnabled = inLibrary
        popup.star?.image = Theme.symbol(starred ? .starFilled : .star, size: 13, label: "Favorite")
        popup.star?.sqToolTip = inLibrary ? (starred ? "Remove from favorites" : "Star: favorites are listed first")
                                        : "Add the LUT to the library to star it"
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
