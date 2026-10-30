import AppKit
import SQCore

/// Effect Controls rows for the non-slider parameter kinds: color (NSColorWell), checkbox and choice (pop-up).
/// Point parameters use the normal `PropertyRow` (two scrub fields; the on-canvas handle comes later).
/// All of them keyframe: the animate diamond leads the row like on every parameter row (these kinds have no curve to open).
@MainActor enum EffectParamRows {
    static func make(_ p: EffectProperty, model: EffectControlsModel, owner: EffectControlsView) -> NSView? {
        switch p.paramKind {
        case .color?: EffectColorRow(property: p, model: model, owner: owner)
        case .checkbox?: EffectCheckboxRow(property: p, model: model, owner: owner)
        case .choice(let items)?: EffectChoiceRow(property: p, items: items, model: model, owner: owner)
        default: nil
        }
    }
}

/// Animate diamond, name, previous / next key (`ParameterKeyControls`; reset: right-click, or double-click the
/// value); subclasses add their control, right aligned where number rows show their values.
class EffectParamRowBase: RowBackground, RowUpdating, ControlsRowProbing {
    var rowProbe: ControlsRowProbe {
        ControlsRowProbe(toggle: keyframes.diamond.frame, label: name.frame, controls: control.map { [$0.frame] } ?? [],
                         tail: keyframes.tailFrame)
    }
    let property: EffectProperty
    let model: EffectControlsModel
    weak var owner: EffectControlsView?
    private let keyframes: ParameterKeyControls
    private let name: NSTextField

    init(property p: EffectProperty, model: EffectControlsModel, owner: EffectControlsView) {
        property = p; self.model = model; self.owner = owner
        keyframes = ParameterKeyControls(propertyName: p.title,
                                         onAnimate: { [weak owner] in owner?.animateTapped(p) },
                                         onPrevious: { model.goToPreviousKey(p) },
                                         onToggleKey: { model.toggleKeyAtPlayhead(p) },
                                         onNext: { model.goToNextKey(p) },
                                         onReset: { model.resetAll(p) })
        name = makeLabel(p.title)
        super.init(frame: .zero)
        keyframes.install(in: self)
        addSubview(name)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The value control (laid out by the base class).
    var control: NSView? { nil }
    var controlWidth: CGFloat { 72 }
    /// Room right of the control, before the key navigation (a button a subclass places there).
    var controlTrailing: CGFloat { 0 }

    override func mouseDown(with event: NSEvent) {
        model.focusedProperty = property
        if let o = owner { window?.makeFirstResponder(o) }
        if name.frame.contains(convert(event.locationInWindow, from: nil)) {
            model.setSelection(for: property, ids: Set(model.track(property)?.keyIDs ?? []))
        }
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        // Grid: the control starts at the value column and ends before the key navigation; the name has the label column.
        let h = bounds.height, grid = ControlsGrid(width: bounds.width)
        if let c = control {
            c.frame = grid.fillFrame(height: h, maxX: grid.valueMaxX - controlTrailing, maxWidth: controlWidth)
        }
        grid.place(name, height: h, maxX: control == nil ? grid.valueMaxX : nil)
        keyframes.layout(rowBounds: bounds)
    }

    override func rightMouseDown(with event: NSEvent) { SQContextMenu.show(items: contextItems(), for: event, in: self) }

    func contextItems() -> [SQMenuItem] {
        let animated = model.isAnimated(property)
        var m: [SQMenuItem] = []
        if animated {
            m.append(SQMenuItem(title: "Reset at Playhead", isEnabled: model.playheadInClip) { [model, property] in model.resetAtPlayhead(property) })
        }
        m.append(SQMenuItem(title: animated ? "Reset All (Remove Keyframes)" : "Reset", isEnabled: !model.isDefault(property)) { [model, property] in model.resetAll(property) })
        m.append(.separator)
        m.append(model.graphEditorMenuItem())
        return m
    }

    func update() {
        let p = property
        keyframes.state = model.keyframeControlState(p)
        keyframes.reset?.isEnabled = !model.isDefault(p)
        updateControl()
    }

    func updateControl() {}
}

/// Color parameter: a color well. A drag in the color panel is one undo step (`setColorContinuously`); the model
/// ends it as soon as anything else edits, and the row ends it when the well deactivates, the panel closes, the row
/// goes away, or (fallback) after 2 s without a change. Ending it never touches another gesture.
final class EffectColorRow: EffectParamRowBase {
    private let well = SQColorWell()
    private var idleTimer: Timer?

    override init(property p: EffectProperty, model: EffectControlsModel, owner: EffectControlsView) {
        super.init(property: p, model: model, owner: owner)
        well.target = self; well.action = #selector(changed)
        well.onClose = { [weak self] in self?.finishGesture() }
        well.setAccessibilityLabel(p.title)
        well.sqToolTip = p.title
        addSubview(well)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var control: NSView? { well }
    override var controlWidth: CGFloat { 44 }

    @objc private func changed() {
        guard let color = Theme.ColorBridge.effectColor(well.color, alpha: 1) else { return }
        model.setColorContinuously(property, to: color)
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishGesture() }
        }
    }

    private func finishGesture() {
        idleTimer?.invalidate(); idleTimer = nil
        model.endColorGesture()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishGesture() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateControl() {
        let mixed = model.isMixed(property)      // multi-select, differing colors: empty swatch
        if well.isMixed != mixed { well.isMixed = mixed }
        let c = model.colorValue(property).clamped
        let cur = well.color.usingColorSpace(.sRGB)
        let same = cur.map { abs($0.redComponent - c.red) < 1e-6 && abs($0.greenComponent - c.green) < 1e-6
            && abs($0.blueComponent - c.blue) < 1e-6 } ?? false
        if !same { well.color = Theme.ColorBridge.srgb(c.red, c.green, c.blue) }
    }
}

/// Checkbox parameter (stored 0 / 1; keys are hold).
final class EffectCheckboxRow: EffectParamRowBase {
    private let box = SQCheckbox(title: "", target: nil, action: nil)

    override init(property p: EffectProperty, model: EffectControlsModel, owner: EffectControlsView) {
        super.init(property: p, model: model, owner: owner)
        box.controlSize = .small
        box.target = self; box.action = #selector(toggled)
        box.setAccessibilityLabel(p.title)
        addSubview(box)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var control: NSView? { box }
    override var controlWidth: CGFloat { 22 }

    @objc private func toggled() { model.setValue(property, to: box.state == .off ? 0 : 1) }     // from mixed: on

    override func updateControl() {
        let on = property.paramKind?.isOn(model.scalarValue(property)) ?? false
        box.state = model.isMixed(property) ? .mixed : on ? .on : .off
    }
}

/// Choice parameter: a pop-up of the catalog's items (stored as the item index; keys are hold).
final class EffectChoiceRow: EffectParamRowBase {
    private let popup = SQPopup(frame: .zero, pullsDown: false)

    init(property p: EffectProperty, items: [String], model: EffectControlsModel, owner: EffectControlsView) {
        super.init(property: p, model: model, owner: owner)
        popup.controlSize = .small
        popup.font = Theme.Typography.body
        popup.addItems(withTitles: items.map { SQL10n.string($0) })
        popup.autoenablesItems = false   // a choice can be off for this clip (Stabilizer: Gyroflow without gyro data)
        popup.target = self; popup.action = #selector(changed)
        popup.setAccessibilityLabel(p.title)
        addSubview(popup)
        // FB-T3: a motion effect's Curve gets the curve editor next to its pop-up (edits the effect's Custom curve).
        if case .fx(let id, let kind, let key) = p, key == ClipEffect.motionCurveKey, ClipEffect.motionKinds.contains(kind) {
            let b = IconButton(symbol: .curve, label: "Edit Curve") {}
            b.handler = { [weak self, weak b, weak model] in
                guard let self, let b, let model else { return }
                self.curvePopover?.close()
                let pop = EasingCurvePopover.make(source: MotionCurveEaseSource(model: model, effect: id))
                self.curvePopover = pop
                pop.show(relativeTo: b.bounds, of: b, preferredEdge: .maxX)
            }
            curveButton = b
            addSubview(b)
        }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var curveButton: IconButton?
    private var curvePopover: SQPopover?

    override var control: NSView? { popup }
    override var controlWidth: CGFloat { ControlsMetrics.popupWidth }
    override var controlTrailing: CGFloat { curveButton == nil ? 0 : ControlsGrid.resetWidth + ControlsGrid.gap }

    override func layout() {
        super.layout()
        guard let b = curveButton else { return }
        let grid = ControlsGrid(width: bounds.width)
        b.frame = grid.controlFrame(x: popup.frame.maxX + ControlsGrid.gap, width: ControlsGrid.resetWidth, height: bounds.height)
    }

    @objc private func changed() { model.setValue(property, to: Double(max(popup.indexOfSelectedItem, 0))) }

    override func updateControl() {
        let off = model.disabledChoices(property)
        for (i, item) in popup.itemArray.enumerated() {
            item.isEnabled = off[i] == nil
            item.sqHelp = off[i]
        }
        // Multi-select with differing choices: nothing selected (empty pop-up).
        if model.isMixed(property) { if popup.indexOfSelectedItem != -1 { popup.selectItem(at: -1) }; return }
        guard let i = property.paramKind?.choiceIndex(for: model.scalarValue(property)) else { return }
        if popup.indexOfSelectedItem != i, i < popup.numberOfItems { popup.selectItem(at: i) }
    }
}
