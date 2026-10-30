import AppKit
import SQCore

/// Effect Controls content while a transition is selected: its name, Duration (timecode), Alignment, and the style a kind
/// uses (Easing, Direction, Softness, Motion Blur).
@MainActor
public final class TransitionControlsView: NSView {
    public var onDuration: ((Time) -> Void)?
    /// Transition layer only: the Type menu picked another kind.
    public var onKind: ((TransitionKind) -> Void)?
    public var onAlignment: ((TransitionAlignment) -> Void)?
    public var onEasing: ((EasingCurve) -> Void)?
    /// "Custom": open the curve editor for the shown transition, anchored to this view.
    public var onEditCurve: ((NSView) -> Void)?
    public var onDirection: ((TransitionDirection) -> Void)?
    /// Reverse box: the move or wipe travels the other way.
    public var onReversed: ((Bool) -> Void)?
    let reverseBox = SQCheckbox(title: "Reverse", target: nil, action: nil)
    /// Soft Wipe edge, 0...0.5 of the frame.
    public var onSoftness: ((Double, _ continuesGesture: Bool) -> Void)?
    /// Border along the moving edge of Push / Slide / Soft Wipe: width as a fraction of the frame (0 = off).
    public var onBorderWidth: ((Double, _ continuesGesture: Bool) -> Void)?
    /// Border color (display-encoded RGB bytes); `continuesGesture` while the picker stays open.
    public var onBorderColor: (([UInt8], _ continuesGesture: Bool) -> Void)?
    /// Shutter in frames (0.5 = 180 degrees).
    public var onMotionBlur: ((Double, _ continuesGesture: Bool) -> Void)?
    /// N6b Stinger: the picked clip (nil = None).
    public var onStingerMedia: ((UUID?) -> Void)?
    /// N6b Stinger: where in the clip the picture switches, 0...1.
    public var onStingerCut: ((Double, _ continuesGesture: Bool) -> Void)?

    /// Through Color: the color picked (display-encoded RGB bytes); `continuesGesture` while the picker stays open.
    public var onColor: (([UInt8], _ continuesGesture: Bool) -> Void)?

    /// FB-G: a parameter of an element transition (Move / Zoom / Pop) was edited: key and new value.
    public var onElementParam: ((String, Double) -> Void)?
    /// A kind parameter (Zoom Amount ...) dragged: every change as it moves, so the monitor shows it at once;
    /// `continuesGesture` is false for the first change (starts the undo step) and true after. The release sends
    /// nothing more; a typed value arrives through `onElementParam` only.
    public var onElementParamLive: ((String, Double, _ continuesGesture: Bool) -> Void)?

    /// "Save as Preset…": the shown transition goes to the Library as a transition preset.
    public var onSavePreset: (() -> Void)?
    /// FB-W (right-click menu): the shown transition becomes the default of its kind / is reset to the default (the
    /// user's, else built-in) / the user default of its kind is deleted.
    public var onUseAsDefault: (() -> Void)?
    public var onReset: (() -> Void)?
    public var onResetDefaultToFactory: (() -> Void)?

    private let savePresetButton = SQButton(title: "Save as Preset…", target: nil, action: nil)
    private let resetButton = SQButton(title: "Reset", target: nil, action: nil)
    private var shownKind: TransitionKind?
    private var shownHasUserDefault = false
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    /// Duration in frames, shown as timecode (drag scrubs frames, a click types a timecode).
    let durationField = ScrubField()
    private let alignmentPopUp = SQPopup(frame: .zero, pullsDown: false)
    /// Transition layer only: the kind (layers change kind in place; a clip-edge transition is replaced by a drop).
    private let kindPopUp = SQPopup(frame: .zero, pullsDown: false)
    private var kindRow = NSStackView()
    private var buttonRow = NSStackView()
    private let easingPopUp = SQPopup(frame: .zero, pullsDown: false)
    private let directionPopUp = SQPopup(frame: .zero, pullsDown: false)
    let softnessSlider = NumericSlider(value: 10, range: 0...50, defaultValue: 10, unit: "%")
    let blurSlider = NumericSlider(value: 50, range: 0...200, defaultValue: 50, unit: "%")
    let colorWell = SQColorWell()
    private var colorRow = NSStackView()
    let borderSlider = NumericSlider(value: 0, range: 0...10, defaultValue: 0, unit: "%")
    let borderColorWell = SQColorWell()
    private var borderRow = NSStackView(), borderColorRow = NSStackView()
    private var borderColorGesture = false
    private var colorGesture = false
    private var easingRow = NSStackView(), directionRow = NSStackView(), softnessRow = NSStackView(), blurRow = NSStackView()
    let stingerPopUp = SQPopup(frame: .zero, pullsDown: false)
    let stingerCut = NumericSlider(value: 50, range: 0...100, defaultValue: 50, unit: "%")
    var stingerCutSlider: SQSlider { stingerCut.slider }
    private var stingerRow = NSStackView(), stingerCutRow = NSStackView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private let emptyState = EmptyStateView(title: "No transition selected", hint: "Click a transition in the timeline to edit it")
    /// Rows of the element transition's parameters, rebuilt when the kind changes.
    private let elementStack = NSStackView()
    private var elementKind: TransitionKind?
    private var elementControls: [String: NSControl] = [:]
    private var frameDuration = Time(1, 30)
    private var shownDuration = Time.zero

    /// The rules are the shared `TransitionControlsLogic` (the Windows `TransitionControlsDraw` reads the same).
    static let easings: [EasingCurve] = TransitionControlsLogic.easings
    static let customEasingTitle = TransitionControlsLogic.customEasingTitle
    static let customEasingKey = "custom"
    var easingTitlesForTests: [String] { easingPopUp.itemTitles }
    var easingTitleForTests: String? { easingPopUp.titleOfSelectedItem }
    static var customEasingIndex: Int { TransitionControlsLogic.customEasingIndex }
    private var shownEasing: EasingCurve = .linear

    static func blurPercent(_ shutter: Double) -> Double { TransitionControlsLogic.blurPercent(shutter) }
    static func shutter(percent: Double) -> Double { TransitionControlsLogic.shutter(percent: percent) }
    static func softnessPercent(_ s: Double) -> Double { TransitionControlsLogic.softnessPercent(s) }
    static func durationFrames(_ t: Time, frameDuration fd: Time) -> Double { TransitionControlsLogic.durationFrames(t, frameDuration: fd) }
    static func duration(frames: Double, frameDuration fd: Time) -> Time { TransitionControlsLogic.duration(frames: frames, frameDuration: fd) }

    /// Turns one slider's begin / change / end triple into the host's `(value, continuesGesture)` callback: the first change
    /// of a gesture starts the undo step, the rest join it; a typed value (no change event) reports once at the end.
    private static func wire(_ n: NumericSlider, _ report: @escaping @MainActor (Double, Bool) -> Void) {
        let started = Flag()
        n.onBegin = { started.on = false }
        n.onChange = { v in report(v.rounded(), started.on); started.on = true }
        n.onEnd = { v in if !started.on { report(v.rounded(), false) } }
    }
    private final class Flag { var on = false }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        title.font = Theme.Typography.titleStrong; title.textColor = Theme.Colors.label
        subtitle.font = Theme.Typography.body; subtitle.textColor = Theme.Colors.label3
        note.font = Theme.Typography.body; note.textColor = Theme.Colors.label3
        note.isHidden = true
        durationField.range = 1...1_000_000
        durationField.valueFormatter = { [weak self] v in
            guard let self else { return "" }
            return timecode.format(Self.duration(frames: v, frameDuration: frameDuration))
        }
        durationField.valueParser = { [weak self] text in
            guard let self, let t = timecode.parse(text), t > .zero else { return nil }
            return Self.durationFrames(t, frameDuration: frameDuration)
        }
        durationField.onEnd = { [weak self] v in
            guard let self else { return }
            let t = Self.duration(frames: v, frameDuration: frameDuration)
            if t != shownDuration { onDuration?(t) }
        }
        durationField.setAccessibilityLabel("Transition duration")
        alignmentPopUp.target = self; alignmentPopUp.action = #selector(alignmentPicked)
        alignmentPopUp.setAccessibilityLabel("Transition alignment")
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = Theme.Typography.body; l.textColor = Theme.Colors.label2
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return l
        }
        for k in TransitionKind.layerKinds { kindPopUp.addItem(withTitle: k.name); kindPopUp.lastItem?.representedObject = k.rawValue }
        kindPopUp.target = self; kindPopUp.action = #selector(kindPicked)
        kindPopUp.setAccessibilityLabel("Transition type")
        kindRow = NSStackView(views: [label("Type"), kindPopUp]); kindRow.spacing = Theme.Spacing.sm
        kindRow.isHidden = true
        let dRow = NSStackView(views: [label("Duration"), durationField]); dRow.spacing = Theme.Spacing.sm
        let aRow = NSStackView(views: [label("Alignment"), alignmentPopUp]); aRow.spacing = Theme.Spacing.sm
        durationField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        for c in Self.easings { easingPopUp.addItem(withTitle: c.displayName); easingPopUp.lastItem?.representedObject = c.id.uuidString }
        easingPopUp.addItem(withTitle: Self.customEasingTitle); easingPopUp.lastItem?.representedObject = Self.customEasingKey
        for d in TransitionDirection.allCases { directionPopUp.addItem(withTitle: d.name); directionPopUp.lastItem?.representedObject = d.rawValue }
        easingPopUp.target = self; easingPopUp.action = #selector(easingPicked)
        easingPopUp.setAccessibilityLabel("Transition easing")
        directionPopUp.target = self; directionPopUp.action = #selector(directionPicked)
        directionPopUp.setAccessibilityLabel("Transition direction")
        for (s, name) in [(softnessSlider, "Edge softness"), (blurSlider, "Motion blur"), (stingerCut, "Stinger cut point")] {
            s.slider.setAccessibilityLabel(name); s.field.setAccessibilityLabel(name)
            s.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        borderSlider.slider.setAccessibilityLabel("Border width"); borderSlider.field.setAccessibilityLabel("Border width")
        borderSlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        Self.wire(borderSlider) { [weak self] v, cont in self?.onBorderWidth?(v / 100, cont) }
        borderColorWell.target = self; borderColorWell.action = #selector(borderColorPicked)
        borderColorWell.onClose = { [weak self] in self?.borderColorGesture = false }
        borderColorWell.setAccessibilityLabel("Border color"); borderColorWell.sqToolTip = "Border Color"
        borderRow = NSStackView(views: [label("Border"), borderSlider]); borderRow.spacing = Theme.Spacing.sm
        borderColorRow = NSStackView(views: [label("Border Color"), borderColorWell]); borderColorRow.spacing = Theme.Spacing.sm
        Self.wire(softnessSlider) { [weak self] v, cont in self?.onSoftness?(v / 100, cont) }
        Self.wire(blurSlider) { [weak self] v, cont in self?.onMotionBlur?(Self.shutter(percent: v), cont) }
        Self.wire(stingerCut) { [weak self] v, cont in self?.onStingerCut?(v / 100, cont) }
        easingRow = NSStackView(views: [label("Easing"), easingPopUp]); easingRow.spacing = Theme.Spacing.sm
        reverseBox.target = self; reverseBox.action = #selector(reversePicked)
        reverseBox.setAccessibilityLabel("Reverse transition")
        directionRow = NSStackView(views: [label("Direction"), directionPopUp, reverseBox]); directionRow.spacing = Theme.Spacing.sm
        softnessRow = NSStackView(views: [label("Softness"), softnessSlider]); softnessRow.spacing = Theme.Spacing.sm
        blurRow = NSStackView(views: [label("Motion Blur"), blurSlider]); blurRow.spacing = Theme.Spacing.sm
        colorWell.target = self; colorWell.action = #selector(colorPicked)
        colorWell.onClose = { [weak self] in self?.colorGesture = false }
        colorWell.setAccessibilityLabel("Transition color"); colorWell.sqToolTip = "Color"
        colorRow = NSStackView(views: [label("Color"), colorWell]); colorRow.spacing = Theme.Spacing.sm
        stingerPopUp.target = self; stingerPopUp.action = #selector(stingerPicked)
        stingerPopUp.setAccessibilityLabel("Stinger clip")
        stingerPopUp.sqToolTip = "Stinger Clip"
        stingerPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        stingerCut.sqToolTip = "Stinger Cut Point"
        stingerRow = NSStackView(views: [label("Clip"), stingerPopUp]); stingerRow.spacing = Theme.Spacing.sm
        stingerCutRow = NSStackView(views: [label("Cut Point"), stingerCut]); stingerCutRow.spacing = Theme.Spacing.sm
        savePresetButton.target = self; savePresetButton.action = #selector(savePresetClicked)
        savePresetButton.sqToolTip = "Save as Preset"
        savePresetButton.setAccessibilityLabel("Save transition as preset")
        resetButton.target = self; resetButton.action = #selector(resetClicked)
        resetButton.setAccessibilityLabel("Reset transition")
        let buttons = NSStackView(views: [resetButton, savePresetButton]); buttons.spacing = Theme.Spacing.sm
        buttonRow = buttons
        elementStack.orientation = .vertical; elementStack.alignment = .leading; elementStack.spacing = Theme.Spacing.sm
        stack.setViews([title, subtitle, kindRow, dRow, aRow, elementStack, stingerRow, stingerCutRow, colorRow, easingRow, directionRow, softnessRow, borderRow, borderColorRow, blurRow,
                                        note, buttons], in: .leading)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = Theme.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.lg),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.lg),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.lg),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        emptyState.frame = bounds
        emptyState.autoresizingMask = [.width, .height]
        emptyState.isHidden = true
        addSubview(emptyState)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Transition controls")
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    private var timecode: Timecode { Timecode(frameDuration: frameDuration, dropFrame: false) }

    /// Shows a transition (nil = nothing). `resolved` nil means its cut is gone.
    /// `stingerMedia`: the clips a Stinger can play (id, name), offered in its Clip menu.
    /// `hasUserDefault`: the kind has a user default (FB-W): shown under the name, and Reset goes back to it.
    /// `isLayer`: a transition layer clip (DECISIONS 2026-10-05): a Type menu instead of the preset and default buttons.
    public func update(transition: Transition?, resolved: ResolvedTransition?, frameDuration fd: Time,
                       stingerMedia: [(id: UUID, name: String)] = [], hasUserDefault: Bool = false, isLayer: Bool = false) {
        emptyState.isHidden = transition != nil
        stack.isHidden = transition == nil
        guard let tr = transition else { shownKind = nil; return }
        frameDuration = fd
        shownKind = tr.kind
        shownHasUserDefault = hasUserDefault
        let shown = TransitionControlsShown(transition: tr, resolved: resolved, frameDuration: fd,
                                            stingerMedia: stingerMedia.map { .init(id: $0.id, name: $0.name) },
                                            hasUserDefault: hasUserDefault, isLayer: isLayer)
        title.stringValue = tr.kind.name
        subtitle.stringValue = TransitionControlsLogic.subtitle(shown)
        subtitle.sqToolTip = nil
        resetButton.sqToolTip = TransitionControlsLogic.resetTip(hasUserDefault: hasUserDefault)
        resetButton.isHidden = tr.kind.isStinger
        kindRow.isHidden = !isLayer
        buttonRow.isHidden = isLayer
        if isLayer { kindPopUp.selectItem(at: kindPopUp.indexOfItem(withRepresentedObject: tr.kind.rawValue)) }
        shownDuration = TransitionControlsLogic.shownDuration(shown)
        durationField.value = Self.durationFrames(shownDuration, frameDuration: fd)
        alignmentPopUp.removeAllItems()
        let options = TransitionControlsLogic.alignmentOptions(shown)
        for o in options { alignmentPopUp.addItem(withTitle: o.name); alignmentPopUp.lastItem?.representedObject = o.rawValue }
        if let i = options.firstIndex(of: tr.alignment) { alignmentPopUp.selectItem(at: i) }
        alignmentPopUp.isEnabled = TransitionControlsLogic.isTwoSided(shown)
        let k = tr.kind
        easingRow.isHidden = !k.usesEasing
        directionRow.isHidden = !k.usesDirection
        softnessRow.isHidden = !k.usesSoftness
        blurRow.isHidden = !k.usesMotionBlur
        // Edge transitions only: a transition layer has no stored border.
        borderRow.isHidden = isLayer || !k.usesBorder
        borderColorRow.isHidden = borderRow.isHidden
        borderSlider.value = ((tr.borderWidth ?? 0) * 100).rounded()
        if !borderColorWell.isActive {
            let c = TransitionControlsLogic.borderColor(shown)
            borderColorWell.color = SQColorValue(r: Double(c[0]) / 255, g: Double(c[1]) / 255, b: Double(c[2]) / 255).nsColor
        }
        // An element transition blurs through its clip's shutter, which stops at one frame (360 degrees).
        blurSlider.range = TransitionControlsLogic.blurRange(k)
        blurSlider.defaultValue = Self.blurPercent(k.defaultMotionBlur)
        softnessSlider.defaultValue = Self.softnessPercent(TransitionKind.defaultSoftness)
        stingerRow.isHidden = !k.isStinger
        colorRow.isHidden = !k.usesColor
        if k.usesColor, !colorWell.isActive {
            let c = TransitionControlsLogic.color(shown)
            colorWell.color = SQColorValue(r: Double(c[0]) / 255, g: Double(c[1]) / 255, b: Double(c[2]) / 255).nsColor
        }
        updateElementRows(tr)
        stingerCutRow.isHidden = !k.isStinger || tr.stinger == nil
        if k.isStinger {
            stingerPopUp.removeAllItems()
            stingerPopUp.addItem(withTitle: "None")
            for m in stingerMedia { stingerPopUp.addItem(withTitle: m.name); stingerPopUp.lastItem?.representedObject = m.id.uuidString }
            if let id = tr.stinger?.media {
                if !stingerMedia.contains(where: { $0.id == id }) {
                    stingerPopUp.addItem(withTitle: "Missing Clip"); stingerPopUp.lastItem?.representedObject = id.uuidString
                }
                stingerPopUp.selectItem(at: stingerPopUp.indexOfItem(withRepresentedObject: id.uuidString))
            } else {
                stingerPopUp.selectItem(at: 0)
            }
            stingerCut.value = ((tr.stinger?.cutFraction ?? 0.5) * 100).rounded()
        }
        let easing = tr.effectiveEasing
        shownEasing = easing
        easingPopUp.selectItem(at: Self.easingIndex(of: easing))
        if let i = TransitionDirection.allCases.firstIndex(of: tr.effectiveDirection) { directionPopUp.selectItem(at: i) }
        reverseBox.state = tr.isReversed ? .on : .off
        softnessSlider.value = Self.softnessPercent(tr.effectiveSoftness)
        blurSlider.value = Self.blurPercent(tr.effectiveMotionBlur)
        let noteText = TransitionControlsLogic.note(shown)
        note.stringValue = noteText ?? ""
        note.isHidden = noteText == nil
    }

    // MARK: Element transition parameters (FB-G)

    private func updateElementRows(_ tr: Transition) {
        let specs = tr.kind.elementParams
        elementStack.isHidden = specs.isEmpty
        if elementKind != tr.kind {
            elementKind = tr.kind
            elementStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            elementControls = [:]
            for spec in specs { elementStack.addArrangedSubview(elementRow(spec)) }
        }
        for spec in specs {
            let v = tr.param(spec.key)
            switch (elementControls[spec.key], spec.kind) {
            case (let pop as SQPopup, .choice): pop.selectItem(at: spec.kind.choiceIndex(for: v))
            case (let box as SQCheckbox, .checkbox): box.state = spec.kind.isOn(v) ? .on : .off
            case (let field as ScrubField, _) where !field.isEditing && !field.isDragging: field.value = v
            default: break
            }
        }
    }

    private func elementRow(_ spec: EffectParamSpec) -> NSView {
        let l = NSTextField(labelWithString: spec.title); l.font = Theme.Typography.body; l.textColor = Theme.Colors.label2
        l.alignment = .right; l.lineBreakMode = .byTruncatingTail
        l.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let control: NSControl
        var views: [NSView] = [l]
        switch spec.kind {
        case .choice(let titles):
            let pop = SQPopup(frame: .zero, pullsDown: false)
            pop.addItems(withTitles: titles)
            pop.target = self; pop.action = #selector(elementChoicePicked(_:))
            control = pop
        case .checkbox:
            control = SQCheckbox(title: "", target: self, action: #selector(elementCheckboxClicked(_:)))
        default:
            let f = ScrubField()
            f.range = spec.range; f.step = spec.step; f.decimals = spec.decimals; f.unit = spec.unit
            f.defaultValue = spec.defaultValue
            let key = spec.key
            let started = Flag()
            f.onBegin = { started.on = false }
            f.onChange = { [weak self] v in
                guard let self, onElementParamLive != nil else { return }
                onElementParamLive?(key, v, started.on); started.on = true
            }
            f.onEnd = { [weak self] v in
                if started.on { started.on = false; return }
                self?.onElementParam?(key, v)
            }
            f.widthAnchor.constraint(equalToConstant: 72).isActive = true
            control = f
        }
        control.identifier = NSUserInterfaceItemIdentifier(spec.key)
        control.setAccessibilityLabel(spec.title)
        elementControls[spec.key] = control
        views.append(control)
        let row = NSStackView(views: views); row.spacing = Theme.Spacing.sm
        return row
    }

    @objc private func elementChoicePicked(_ sender: SQPopup) {
        guard let key = sender.identifier?.rawValue else { return }
        onElementParam?(key, Double(sender.indexOfSelectedItem))
    }

    @objc private func elementCheckboxClicked(_ sender: SQCheckbox) {
        guard let key = sender.identifier?.rawValue else { return }
        onElementParam?(key, sender.state == .on ? 1 : 0)
    }

    @objc private func colorPicked() {
        guard let c = colorWell.color.usingColorSpace(.sRGB) else { return }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
        onColor?([byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent)], colorGesture)
        colorGesture = true
    }

    @objc private func borderColorPicked() {
        guard let c = borderColorWell.color.usingColorSpace(.sRGB) else { return }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
        onBorderColor?([byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent)], borderColorGesture)
        borderColorGesture = true
    }

    @objc private func savePresetClicked() { onSavePreset?() }
    @objc private func resetClicked() { onReset?() }
    @objc private func useAsDefaultClicked() { onUseAsDefault?() }
    @objc private func factoryDefaultClicked() { onResetDefaultToFactory?() }

    /// FB-W: right-click anywhere in the inspector.
    public override func rightMouseDown(with event: NSEvent) {
        let items = contextItems()
        if items.isEmpty { super.rightMouseDown(with: event) } else { SQContextMenu.show(items: items, for: event, in: self) }
    }

    /// Rows of the right-click menu; empty for stingers and while nothing is shown.
    public func contextItems() -> [SQMenuItem] {
        guard let kind = shownKind else { return [] }
        return TransitionControlsLogic.contextItems(
            kind: kind, hasUserDefault: shownHasUserDefault,
            reset: { [weak self] in self?.onReset?() },
            useAsDefault: { [weak self] in self?.onUseAsDefault?() },
            resetDefaultToFactory: { [weak self] in self?.onResetDefaultToFactory?() })
    }

    @objc private func kindPicked() {
        guard let raw = kindPopUp.selectedItem?.representedObject as? String, let k = TransitionKind(rawValue: raw) else { return }
        onKind?(k)
    }

    @objc private func alignmentPicked() {
        guard let raw = alignmentPopUp.selectedItem?.representedObject as? String, let a = TransitionAlignment(rawValue: raw) else { return }
        onAlignment?(a)
    }

    /// Pop-up index of a curve: its preset, else Custom.
    static func easingIndex(of c: EasingCurve) -> Int { TransitionControlsLogic.easingIndex(of: c) }

    @objc private func easingPicked() {
        if easingPopUp.selectedItem?.representedObject as? String == Self.customEasingKey {
            // Starts from the curve that is shown (a preset's handles), so Custom never jumps; then the editor opens.
            if shownEasing.matchingTransitionPreset != nil, let c = EasingCurve.transitionCustom(shownEasing.shape) { onEasing?(c); shownEasing = c }
            onEditCurve?(easingPopUp)
            return
        }
        guard let raw = easingPopUp.selectedItem?.representedObject as? String,
              let c = Self.easings.first(where: { $0.id.uuidString == raw }) else { return }
        onEasing?(c)
    }

    @objc private func directionPicked() {
        guard let raw = directionPopUp.selectedItem?.representedObject as? String, let d = TransitionDirection(rawValue: raw) else { return }
        onDirection?(d)
    }

    @objc private func reversePicked() { onReversed?(reverseBox.state == .on) }

    @objc private func stingerPicked() {
        let raw = stingerPopUp.selectedItem?.representedObject as? String
        onStingerMedia?(raw.flatMap(UUID.init(uuidString:)))
    }
}

/// Effect Controls with the transition view laid over it while a transition is selected.
@MainActor
public final class EffectControlsContainerView: NSView {
    public let effects: EffectControlsView
    public let transition: TransitionControlsView

    public init(effects: EffectControlsView, transition: TransitionControlsView) {
        self.effects = effects; self.transition = transition
        super.init(frame: effects.frame)
        for v in [effects, transition] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
                                         v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor)])
        }
        transition.isHidden = true
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    public var showsTransition: Bool {
        get { !transition.isHidden }
        set { transition.isHidden = !newValue; effects.isHidden = newValue }
    }
}

/// "Set Transition Duration" (double-click on a transition): a small sheet with the duration as timecode.
@MainActor
public enum TransitionDurationSheet {
    public static func present(on window: NSWindow?, name: String, duration: Time, frameDuration fd: Time,
                               completion: @escaping @MainActor (Time) -> Void) {
        let tc = Timecode(frameDuration: fd, dropFrame: false)
        let alert = SQDialog()
        alert.messageText = "Set Transition Duration"
        alert.informativeText = name + ". Type a timecode, or digits for frames and seconds (101 is 1 second, 1 frame)."
        let field = SQTextField(string: tc.format(duration))
        field.textColor = Theme.Colors.accent
        field.heightAnchor.constraint(equalToConstant: Theme.Row.control).isActive = true
        field.setAccessibilityLabel("Duration")
        alert.accessoryView = field
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        let finish: @MainActor (SQDialog.Response) -> Void = { r in
            guard r == .first, let t = tc.parse(field.stringValue), t > .zero else { return }
            completion(t)
        }
        if let window { alert.beginSheetModal(for: window, completion: finish) } else { finish(alert.runModal()) }
    }
}
