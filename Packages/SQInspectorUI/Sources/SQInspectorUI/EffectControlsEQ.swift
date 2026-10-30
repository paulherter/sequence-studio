import AppKit
import SQAudioFX
import SQCore

/// "Curve" disclosure row of a Parametric EQ.
final class EQCurveHeaderRow: RowBackground, RowUpdating {
    let header: InspectorSectionHeader

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        header = InspectorSectionHeader(title: "Curve", hasEnableToggle: false, isExpanded: model.isEQCurveOpen(effect))
        super.init(frame: .zero)
        fill = Theme.Colors.panel
        header.onToggleExpanded = { [weak model] _ in model?.toggleEQCurve(effect) }
        addSubview(header)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let x = ControlsGrid.levelIndent
        header.frame = NSRect(x: x, y: 0, width: max(bounds.width - x, 0), height: bounds.height)
    }

    func update() {}
}

/// The inline curve editor row.
final class EQCurveRow: RowBackground, RowUpdating {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    let curve = EQCurveView(frame: .zero)

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        fill = Theme.Colors.content
        curve.onBegin = { [weak model] in model?.beginGesture() }
        curve.onEnd = { [weak model] in model?.endGesture() }
        curve.onChange = { [weak model] i, hz, gain, q in model?.setEQBand(effect, filter: i, hz: hz, gainDB: gain, q: q) }
        curve.onReset = { [weak model] i in model?.resetEQBand(effect, filter: i) }
        addSubview(curve)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        curve.frame = NSRect(x: ControlsMetrics.labelX, y: Theme.Spacing.xs,
                             width: max(bounds.width - ControlsMetrics.labelX - ControlsGrid.trailing, 40),
                             height: max(bounds.height - 2 * Theme.Spacing.xs, 40))
    }

    func update() { curve.values = model.eqValues(effect) }
}
