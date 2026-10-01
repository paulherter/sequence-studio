import AppKit
import CoreGraphics
import Observation
import SSCore
import SSRender
import UniformTypeIdentifiers

/// One section of one Colour effect: header with its switch, and a body that collapses.
@MainActor
final class ColorSectionView: NSStackView {
    let effect: Int
    let kind: ColorSectionKind
    let header: ColorSectionHeader
    let body = NSStackView()
    var rows: [ColorParam: ColorParamRow] = [:]
    var groups: [String: ColorGroupView] = [:]
    var wheels: [ColorWheelSlot: ColorWheelControl] = [:]
    var lutPopups: [ColorLUTSlot: LUTPopup] = [:]
    var curveEditor: CurveEditorView?
    var channelDots: ChannelDots?
    var hueEditor: CurveEditorView?
    var huePopup: NSPopUpButton?
    var hueKind = HueCurveKind.hueVsSat
    var preview: LookPreviewView?
    var previewPath: String??
    var previewFrame: CGImage?
    var selectedChannel = 0

    init(effect: Int, kind: ColorSectionKind) {
        self.effect = effect
        self.kind = kind
        header = ColorSectionHeader(title: kind.title, isGroup: false)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = Theme.Spacing.xs
        body.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Spacing.lg, bottom: Theme.Spacing.md, right: Theme.Spacing.md)
        addArrangedSubview(header)
        addArrangedSubview(body)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
}

/// One Colour effect: optional title row (only when the clip has several), then the fixed sections.
@MainActor
final class ColorEffectView: NSStackView {
    let effect: Int
    var sections: [ColorSectionKind: ColorSectionView] = [:]

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

/// Color page inspector, laid out like Premiere's Lumetri Color panel: one column of collapsible sections (Basic
/// Correction, Creative, Curves, Color Wheels & Match, HSL Secondary, Vignette), each with its own switch. "Add Colour
/// Effect" stacks another one (Premiere: add another Lumetri Color).
@MainActor
public final class ColorInspectorView: NSView {
    public let model: ColorInspectorModel

    private let stack = NSStackView()
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effectsStack = NSStackView()
    private var effectViews: [Int: ColorEffectView] = [:]
    private var builtSignature: [Int] = []

    /// Index 0 of the source popup is "Automatic (<detected>)", then these.
    private static let sources: [(String, ColorSpaceID)] = [
        ("Rec. 709", .rec709), ("S-Log3 / S-Gamut3.Cine", .sLog3SGamut3Cine), ("HLG / Rec. 2020", .hlgBT2020),
    ]
    private static func name(_ id: ColorSpaceID) -> String { sources.first { $0.1 == id }?.0 ?? "" }

    public init(model: ColorInspectorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 640))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        rebuildEffects()
        refresh()
        observe()
    }
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
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        style(sourcePopup)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        sourcePopup.setAccessibilityLabel("Interpret footage as")
        let interpret = NSTextField(labelWithString: "Interpret as")
        interpret.font = Theme.Fonts.small
        interpret.textColor = Theme.Colors.label2
        interpret.widthAnchor.constraint(equalToConstant: ColorParamRow.titleWidth).isActive = true
        let top = NSStackView(views: [interpret, sourcePopup])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = Theme.Spacing.sm
        top.edgeInsets = NSEdgeInsets(top: Theme.Spacing.md, left: Theme.Spacing.md, bottom: Theme.Spacing.md, right: Theme.Spacing.md)
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        effectsStack.orientation = .vertical
        effectsStack.alignment = .leading
        effectsStack.spacing = 0
        stack.addArrangedSubview(effectsStack)
        effectsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let add = NSButton(title: "Add Colour Effect", target: self, action: #selector(addEffect))
        add.controlSize = .small
        add.bezelStyle = .rounded
        add.font = Theme.Fonts.small
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.toolTip = "Stack another Colour effect on this clip"
        let addRow = NSStackView(views: [add])
        addRow.edgeInsets = NSEdgeInsets(top: Theme.Spacing.md, left: Theme.Spacing.md, bottom: Theme.Spacing.lg, right: Theme.Spacing.md)
        stack.addArrangedSubview(addRow)
    }

    private func style(_ popup: NSPopUpButton) {
        popup.controlSize = .small
        popup.font = Theme.Fonts.small
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.Colors.separator.cgColor
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    // MARK: Effects and sections

    private func rebuildEffects() {
        for v in effectsStack.arrangedSubviews { effectsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        effectViews = [:]
        let multiple = model.effects.count > 1
        for (n, e) in model.effects.enumerated() {
            let v = ColorEffectView(effect: e.id)
            addEffectTitle(to: v, effect: e.id, number: n + 1, removable: multiple)
            for kind in ColorSectionKind.allCases {
                v.addArrangedSubview(separator())
                v.arrangedSubviews.last.map { $0.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
                let s = makeSection(effect: e.id, kind: kind, isPrimary: n == 0)
                v.sections[kind] = s
                v.addArrangedSubview(s)
                s.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
            }
            effectViews[e.id] = v
            effectsStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: effectsStack.widthAnchor).isActive = true
        }
        builtSignature = model.effects.map(\.id)
    }

    private func addEffectTitle(to v: ColorEffectView, effect: Int, number: Int, removable: Bool) {
        let t = NSTextField(labelWithString: number == 1 ? "Colour" : "Colour \(number)")
        t.font = Theme.Fonts.bodyTitle
        t.textColor = Theme.Colors.label
        var views: [NSView] = [t, NSView()]
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetEffectPressed(_:)))
        reset.controlSize = .small
        reset.bezelStyle = .accessoryBarAction
        reset.font = Theme.Fonts.small
        reset.tag = effect
        reset.toolTip = "Reset every section of this effect"
        reset.setAccessibilityLabel("Reset \(t.stringValue)")
        views.append(reset)
        if removable {
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeEffect(_:)))
            remove.controlSize = .small
            remove.bezelStyle = .accessoryBarAction
            remove.font = Theme.Fonts.small
            remove.tag = effect
            remove.setAccessibilityLabel("Remove \(t.stringValue)")
            views.append(remove)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: Theme.Spacing.sm, left: Theme.Spacing.md, bottom: Theme.Spacing.xs, right: Theme.Spacing.md)
        v.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
    }

    private func makeSection(effect: Int, kind: ColorSectionKind, isPrimary: Bool) -> ColorSectionView {
        let v = ColorSectionView(effect: effect, kind: kind)
        let key = ColorPanelKey(effect, kind)
        v.header.onToggleOpen = { [weak self] in
            guard let self else { return }
            self.model.setCollapsed(key, !self.model.isCollapsed(key))
        }
        v.header.toggle.target = self
        v.header.toggle.action = #selector(switchToggled(_:))
        v.header.toggle.identifier = NSUserInterfaceItemIdentifier("\(effect)|\(kind.rawValue)")
        v.header.toggle.isEnabled = kind.isImplemented

        switch kind {
        case .basicCorrection: buildBasic(v, isPrimary: isPrimary)
        case .creative: buildCreative(v)
        case .curves: buildCurves(v)
        case .wheels: buildWheels(v)
        case .hslSecondary:
            let note = NSTextField(labelWithString: "Not available yet.")
            note.font = Theme.Fonts.small
            note.textColor = Theme.Colors.label3
            v.body.addArrangedSubview(note)
        case .vignette: addParamGroups(v)
        }
        return v
    }

    private func pin(_ row: NSView, in parent: NSStackView, inset: CGFloat) {
        parent.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: parent.widthAnchor, constant: -inset).isActive = true
    }

    private func buildBasic(_ v: ColorSectionView, isPrimary: Bool) {
        let popup = makePopup(v, slot: .input, label: "Input LUT")
        pin(labelled("Input LUT", popup), in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
        let intensity = paramRow(v, .inputLUTIntensity)
        intensity.toolTip = isPrimary ? "The conversion LUT of the first effect always runs at full strength." : nil
        pin(intensity, in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)

        let reset = resetButton(v)
        let resetRow = NSStackView(views: [NSView(), reset])
        resetRow.orientation = .horizontal
        pin(resetRow, in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)

        for g in ColorParam.layout(for: .basicCorrection) {
            let group = makeGroup(v, title: g.group ?? "")
            if g.group == "Color" {
                let eyedropper = NSButton(image: NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "White balance picker") ?? NSImage(),
                                          target: self, action: #selector(pickWhiteBalance(_:)))
                eyedropper.isBordered = false
                eyedropper.tag = v.effect
                eyedropper.toolTip = "Click a neutral grey or white area in the Program monitor to set the white balance"
                let l = NSTextField(labelWithString: "White Balance")
                l.font = Theme.Fonts.small
                l.textColor = Theme.Colors.label2
                l.widthAnchor.constraint(equalToConstant: ColorParamRow.titleWidth).isActive = true
                let row = NSStackView(views: [l, eyedropper, NSView()])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = Theme.Spacing.sm
                pin(row, in: group.content, inset: Theme.Spacing.lg)
            }
            if g.group == "Light" {
                let reset = NSButton(title: "Reset", target: self, action: #selector(resetTonePressed(_:)))
                let auto = NSButton(title: "Auto", target: self, action: #selector(autoTonePressed(_:)))
                for b in [reset, auto] {
                    b.controlSize = .small
                    b.bezelStyle = .rounded
                    b.font = Theme.Fonts.small
                    b.tag = v.effect
                }
                reset.toolTip = "Reset Exposure, Contrast, Highlights, Shadows, Whites and Blacks"
                auto.toolTip = "Set Exposure and Blacks from the Program monitor picture"
                let row = NSStackView(views: [NSView(), reset, auto])
                row.orientation = .horizontal
                row.spacing = Theme.Spacing.sm
                pin(row, in: group.content, inset: Theme.Spacing.lg)
            }
            for p in g.params { pin(paramRow(v, p), in: group.content, inset: Theme.Spacing.lg) }
            pin(group, in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
        }
    }

    private func buildCreative(_ v: ColorSectionView) {
        let popup = makePopup(v, slot: .look, label: "Look")
        pin(labelled("Look", popup), in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
        let preview = LookPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 112).isActive = true
        preview.onStep = { [weak self] delta in self?.model.cycleLook(v.effect, by: delta) }
        v.preview = preview
        let previewRow = NSStackView(views: [NSView(), preview, NSView()])
        previewRow.orientation = .horizontal
        previewRow.distribution = .equalCentering
        pin(previewRow, in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
        pin(paramRow(v, .lookIntensity), in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)

        let group = makeGroup(v, title: "Adjustments")
        pin(paramRow(v, .fadedFilm), in: group.content, inset: Theme.Spacing.lg)
        let sharpen = ColorParamRow(nil, title: "Sharpen", range: -100...100)
        sharpen.toolTip = "Not available yet"
        pin(sharpen, in: group.content, inset: Theme.Spacing.lg)
        pin(paramRow(v, .creativeVibrance), in: group.content, inset: Theme.Spacing.lg)
        pin(paramRow(v, .creativeSaturation), in: group.content, inset: Theme.Spacing.lg)
        let tints = NSStackView()
        tints.orientation = .horizontal
        tints.distribution = .equalCentering
        for slot in [ColorWheelSlot.shadowTint, .highlightTint] { tints.addArrangedSubview(wheel(v, slot, showsMaster: false, size: 96)) }
        pin(tints, in: group.content, inset: Theme.Spacing.lg)
        pin(paramRow(v, .tintBalance), in: group.content, inset: Theme.Spacing.lg)
        pin(group, in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
        pin(trailingReset(v), in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
    }

    private func buildCurves(_ v: ColorSectionView) {
        let group = makeGroup(v, title: "RGB Curves")
        let dots = ChannelDots()
        dots.translatesAutoresizingMaskIntoConstraints = false
        dots.onSelect = { [weak self, weak v] i in
            v?.selectedChannel = i
            self?.refresh()
        }
        v.channelDots = dots
        let dotsRow = NSStackView(views: [dots])
        dotsRow.orientation = .horizontal
        dotsRow.distribution = .equalCentering
        pin(dotsRow, in: group.content, inset: Theme.Spacing.lg)
        let editor = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 200, height: 180))
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.heightAnchor.constraint(equalToConstant: 180).isActive = true
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
        pin(editor, in: group.content, inset: Theme.Spacing.lg)
        pin(group, in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)

        // Hue Saturation Curves: one curve at a time, chosen in the popup (Premiere's tabs).
        let hueGroup = makeGroup(v, title: "Hue Saturation Curves")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        style(popup)
        for k in HueCurveKind.allCases { popup.addItem(withTitle: k.title) }
        popup.target = self
        popup.action = #selector(hueCurveKindChanged(_:))
        popup.identifier = NSUserInterfaceItemIdentifier("\(v.effect)")
        popup.setAccessibilityLabel("Hue Saturation Curve")
        v.huePopup = popup
        pin(popup, in: hueGroup.content, inset: Theme.Spacing.lg)
        let hue = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        hue.translatesAutoresizingMaskIntoConstraints = false
        hue.heightAnchor.constraint(equalToConstant: 150).isActive = true
        hue.flatBaseline = true
        hue.points = HueCurves.flat
        hue.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        hue.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        hue.onChange = { [weak self, weak v] pts in
            guard let self, let v else { return }
            self.model.setHueCurve(id, v.hueKind, pts)
        }
        v.hueEditor = hue
        pin(hue, in: hueGroup.content, inset: Theme.Spacing.lg)
        pin(hueGroup, in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
        pin(trailingReset(v), in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
    }

    private func buildWheels(_ v: ColorSectionView) {
        let w = NSStackView()
        w.orientation = .horizontal
        w.spacing = Theme.Spacing.sm
        w.distribution = .equalSpacing
        for slot in [ColorWheelSlot.shadows, .midtones, .highlights] { w.addArrangedSubview(wheel(v, slot, showsMaster: true, size: 92)) }
        pin(w, in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
        addParamGroups(v)
    }

    /// Plain rows of a section (Vignette, Color Wheels saturation) plus its Reset button.
    private func addParamGroups(_ v: ColorSectionView) {
        for g in ColorParam.layout(for: v.kind) {
            for p in g.params { pin(paramRow(v, p), in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md) }
        }
        pin(trailingReset(v), in: v.body, inset: Theme.Spacing.lg + Theme.Spacing.md)
    }

    private func resetButton(_ v: ColorSectionView) -> NSButton {
        let b = NSButton(title: "Reset", target: self, action: #selector(resetPressed(_:)))
        b.controlSize = .small
        b.bezelStyle = .rounded
        b.font = Theme.Fonts.small
        b.tag = v.effect
        b.identifier = NSUserInterfaceItemIdentifier(v.kind.rawValue)
        b.setAccessibilityLabel("Reset \(v.kind.title)")
        return b
    }

    private func trailingReset(_ v: ColorSectionView) -> NSView {
        let row = NSStackView(views: [NSView(), resetButton(v)])
        row.orientation = .horizontal
        return row
    }

    private func labelled(_ name: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: name)
        l.font = Theme.Fonts.small
        l.textColor = Theme.Colors.label2
        l.widthAnchor.constraint(equalToConstant: ColorParamRow.titleWidth).isActive = true
        let r = NSStackView(views: [l, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = Theme.Spacing.sm
        return r
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

    private func makeGroup(_ v: ColorSectionView, title: String) -> ColorGroupView {
        let g = ColorGroupView(title: title)
        let key = ColorPanelKey(v.effect, v.kind, group: title)
        g.header.onToggleOpen = { [weak self] in
            guard let self else { return }
            self.model.setCollapsed(key, !self.model.isCollapsed(key))
        }
        v.groups[title] = g
        return g
    }

    private func paramRow(_ v: ColorSectionView, _ p: ColorParam) -> ColorParamRow {
        let id = v.effect
        let r = ColorParamRow(p)
        r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        r.onSet = { [weak self] value in self?.model.set(id, p, value) }
        r.onReset = { [weak self] in self?.model.resetParameter(id, p) }
        v.rows[p] = r
        return r
    }

    private func wheel(_ v: ColorSectionView, _ slot: ColorWheelSlot, showsMaster: Bool, size: CGFloat) -> ColorWheelControl {
        let id = v.effect
        let w = ColorWheelControl(frame: NSRect(x: 0, y: 0, width: size, height: size + 16))
        w.title = slot.title
        w.showsMaster = showsMaster
        w.translatesAutoresizingMaskIntoConstraints = false
        w.widthAnchor.constraint(equalToConstant: showsMaster ? size - 10 : size).isActive = true
        w.heightAnchor.constraint(equalToConstant: size + 16).isActive = true
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

    @objc private func sourceChanged() {
        let i = sourcePopup.indexOfSelectedItem
        guard i >= 0, i <= Self.sources.count else { return }
        model.gesture { model.setSourceOverride(i == 0 ? nil : Self.sources[i - 1].1) }
    }

    @objc private func hueCurveKindChanged(_ p: NSPopUpButton) {
        guard let raw = p.identifier?.rawValue, let id = Int(raw), let kind = HueCurveKind(rawValue: p.indexOfSelectedItem),
              let v = effectViews[id]?.sections[.curves] else { return }
        v.hueKind = kind
        refresh()
    }

    @objc private func resetTonePressed(_ b: NSButton) { model.resetTone(b.tag) }
    @objc private func autoTonePressed(_ b: NSButton) { model.onAutoTone?(b.tag) }

    @objc private func addEffect() { model.addEffect() }
    @objc private func removeEffect(_ b: NSButton) { model.removeEffect(b.tag) }
    @objc private func resetEffectPressed(_ b: NSButton) { model.resetEffect(b.tag) }
    @objc private func pickWhiteBalance(_ b: NSButton) { model.onPickWhiteBalance?(b.tag) }

    @objc private func switchToggled(_ s: NSSwitch) {
        let parts = (s.identifier?.rawValue ?? "").split(separator: "|")
        guard parts.count == 2, let effect = Int(parts[0]), let kind = ColorSectionKind(rawValue: String(parts[1])) else { return }
        model.setEnabled(effect, kind, s.state == .on)
    }

    @objc private func resetPressed(_ b: NSButton) {
        guard let raw = b.identifier?.rawValue, let kind = ColorSectionKind(rawValue: raw) else { return }
        model.resetSection(b.tag, kind)
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
        case nil: refresh()
        }
    }

    // MARK: Refresh

    private func observe() {
        withObservationTracking {
            _ = model.color
            _ = model.collapsed
            _ = model.availableLUTs
            _ = model.recentLUTs
            _ = model.detectedSource
            _ = model.frameThumbnail
            _ = model.embeddedLUTName
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
        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: "Automatic (\(Self.name(model.detectedSource)))")
        Self.sources.forEach { sourcePopup.addItem(withTitle: $0.0) }
        if let o = model.sourceOverride, let i = Self.sources.firstIndex(where: { $0.1 == o }) { sourcePopup.selectItem(at: i + 1) }
        else { sourcePopup.selectItem(at: 0) }

        for (n, e) in model.effects.enumerated() {
            guard let ev = effectViews[e.id] else { continue }
            for (kind, v) in ev.sections { refreshSection(v, effect: e, kind: kind, isPrimary: n == 0) }
        }
    }

    private func refreshSection(_ v: ColorSectionView, effect e: ColorEffect, kind: ColorSectionKind, isPrimary: Bool) {
        let on = e.isEnabled(kind) && kind.isImplemented
        let open = !model.isCollapsed(ColorPanelKey(e.id, kind))
        v.header.toggle.state = on ? .on : .off
        v.header.setOpen(open)
        v.body.isHidden = !open
        v.body.alphaValue = on || !kind.isImplemented ? 1 : 0.45
        for (p, r) in v.rows { r.show(model.value(e.id, p)) }
        for (title, g) in v.groups { g.setOpen(!model.isCollapsed(ColorPanelKey(e.id, kind, group: title))) }
        for (slot, w) in v.wheels {
            let st = model.wheel(e.id, slot)
            w.hue = Double(st.value.hue); w.amount = Double(st.value.amount); w.master = Double(st.luma / 100)
        }
        for (slot, popup) in v.lutPopups { refreshLUTPopup(popup, slot: slot, effect: e.id, isPrimary: isPrimary) }
        if kind == .basicCorrection {
            let hasLUT = e.inputLUT != nil && e.inputLUT != .automatic
            v.rows[.inputLUTIntensity]?.setActive(!isPrimary && hasLUT)
        }
        if kind == .creative, let preview = v.preview {
            if let frame = model.frameThumbnail {
                if v.previewPath != .some(nil) || preview.image == nil || v.previewFrame !== frame {
                    v.previewFrame = frame
                    v.previewPath = .some(nil)
                    preview.image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
                }
            } else {
                var path: String?
                if case .file(let p)? = e.creative.look { path = p }
                if v.previewPath != .some(path) || v.previewFrame != nil {
                    v.previewFrame = nil
                    v.previewPath = .some(path)
                    preview.image = ColorLookPreview.image(forLookPath: path)
                }
            }
            preview.setStepping(!model.lookChoices.isEmpty || e.creative.look != nil)
        }
        if let hue = v.hueEditor, let popup = v.huePopup {
            popup.selectItem(at: v.hueKind.rawValue)
            hue.hueStrip = v.hueKind.isHueKeyed
            hue.points = model.hueCurve(e.id, v.hueKind)
            hue.lineColor = Theme.Colors.label
        }
        if let editor = v.curveEditor, let dots = v.channelDots {
            dots.selected = v.selectedChannel
            let c = e.curves
            let (pts, color): ([CurvePoint], NSColor) = switch v.selectedChannel {
            case 1: (c.red, Theme.Colors.red)
            case 2: (c.green, Theme.Colors.green)
            case 3: (c.blue, NSColor.systemBlue)
            default: (c.master, Theme.Colors.label)
            }
            editor.points = pts
            editor.lineColor = color
        }
    }

    private func refreshLUTPopup(_ popup: LUTPopup, slot: ColorLUTSlot, effect: Int, isPrimary: Bool) {
        let current = model.lutChoice(effect, slot)
        var items: [(String, LUTPopup.Pick)] = []
        if slot == .input && isPrimary {
            items.append(("Automatic", .choice(.automatic)))
            if let n = model.embeddedLUTName { items.append(("Embedded: \(n)", .choice(.embedded(name: n)))) }
        } else {
            items.append(("None", .choice(nil)))
        }
        var seen = Set<String>()
        if let c = current, c.filePath != nil { items.append((c.name, .choice(c))); seen.insert(c.id) }
        for c in model.lookChoices where !seen.contains(c.id) {
            items.append((c.name, .choice(c))); seen.insert(c.id)
            if seen.count > 10 { break }
        }
        items.append(("Choose File…", .chooseFile))
        if slot == .input && isPrimary { items.append(("None", .choice(nil))) }
        popup.removeAllItems()
        popup.picks = items.map(\.1)
        for (title, _) in items { popup.addItem(withTitle: title) }
        let i = items.firstIndex { if case .choice(let c) = $0.1 { c == current } else { false } } ?? 0
        popup.selectItem(at: i)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
