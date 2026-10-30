import AppKit
import Observation
import SQAudioFX
import SQCore

/// Track audio inspector: role popup (Dialogue / Music / SFX), preset popup, bypass, noise reduction and the 4-band compressor strip.
/// Plain AppKit controls bound to `TrackAudioInspectorModel`; per-band numbers stay in the model for now.
@MainActor
public final class TrackAudioInspectorView: NSView {
    public let model: TrackAudioInspectorModel

    private let rolePopup = SQPopup(frame: .zero, pullsDown: false)
    private let presetPopup = SQPopup(frame: .zero, pullsDown: false)
    private let bypassCheck = SQCheckbox(title: "Bypass compressor", target: nil, action: nil)
    private let noiseSlider = NumericSlider(value: 0, range: 0...100, defaultValue: 0, step: 1, unit: "%")
    private let bands = CompressorBandsView()
    private let gateCheck = SQCheckbox(title: "Noise gate", target: nil, action: nil)
    private let gateSlider = NumericSlider(value: -45, range: NoiseGateSettings.Limits.thresholdDB, defaultValue: -45, step: 1, unit: "dB")
    private let warmthCheck = SQCheckbox(title: "Warmth", target: nil, action: nil)
    private let warmthSlider = NumericSlider(value: 6, range: SaturationSettings.Limits.driveDB, defaultValue: 6, step: 1, unit: "dB")
    private let attackSlider = NumericSlider(value: 2, range: NoiseGateSettings.Limits.attackMs, defaultValue: 2, step: 0.1, unit: "ms")
    private let holdSlider = NumericSlider(value: 80, range: NoiseGateSettings.Limits.holdMs, defaultValue: 80, step: 1, unit: "ms")
    private let releaseSlider = NumericSlider(value: 150, range: NoiseGateSettings.Limits.releaseMs, defaultValue: 150, step: 1, unit: "ms")
    private let warmthMixSlider = NumericSlider(value: 100, range: 0...100, defaultValue: 100, step: 1, unit: "%")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private var tracking = true

    public init(model: TrackAudioInspectorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 260))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        build()
        refresh()
        observe()
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    isolated deinit { tracking = false }

    /// Text under the controls (e.g. that the preset is not audible yet).
    public var note: String {
        get { noteLabel.stringValue }
        set { noteLabel.stringValue = newValue; noteLabel.isHidden = newValue.isEmpty }
    }

    private func build() {
        rolePopup.font = Theme.Typography.body
        rolePopup.addItems(withTitles: TrackAudioInspectorModel.roleTitles)
        rolePopup.target = self; rolePopup.action = #selector(roleChanged)
        rolePopup.sqToolTip = "Dialogue, Music or SFX: loads a voiced EQ, compressor and level for this track"
        presetPopup.font = Theme.Typography.body
        presetPopup.target = self; presetPopup.action = #selector(presetChanged)
        bypassCheck.controlSize = .small; bypassCheck.font = Theme.Typography.body
        bypassCheck.target = self; bypassCheck.action = #selector(bypassChanged)
        noiseSlider.onBegin = { [weak self] in self?.model.beginChange() }
        noiseSlider.onChange = { [weak self] v in self?.model.setNoiseReductionPercent(v) }
        noiseSlider.onEnd = { [weak self] _ in self?.model.endChange() }
        noiseSlider.heightAnchor.constraint(equalToConstant: ControlsGrid.controlHeight).isActive = true
        gateCheck.controlSize = .small; gateCheck.font = Theme.Typography.body
        gateCheck.target = self; gateCheck.action = #selector(gateToggled)
        warmthCheck.controlSize = .small; warmthCheck.font = Theme.Typography.body
        warmthCheck.target = self; warmthCheck.action = #selector(warmthToggled)
        gateSlider.onBegin = { [weak self] in self?.model.beginChange() }
        gateSlider.onChange = { [weak self] v in self?.model.setGateThresholdDB(v) }
        gateSlider.onEnd = { [weak self] _ in self?.model.endChange() }
        warmthSlider.onBegin = { [weak self] in self?.model.beginChange() }
        warmthSlider.onChange = { [weak self] v in self?.model.setWarmthDriveDB(v) }
        warmthSlider.onEnd = { [weak self] _ in self?.model.endChange() }
        attackSlider.onChange = { [weak self] v in self?.model.setGateAttackMs(v) }
        holdSlider.onChange = { [weak self] v in self?.model.setGateHoldMs(v) }
        releaseSlider.onChange = { [weak self] v in self?.model.setGateReleaseMs(v) }
        warmthMixSlider.onChange = { [weak self] v in self?.model.setWarmthMixPercent(v) }
        for sl in [attackSlider, holdSlider, releaseSlider, warmthMixSlider] {
            sl.onBegin = { [weak self] in self?.model.beginChange() }
            sl.onEnd = { [weak self] _ in self?.model.endChange() }
        }
        attackSlider.sqToolTip = "How fast the gate opens"
        holdSlider.sqToolTip = "How long the gate stays open after the sound drops below the threshold"
        releaseSlider.sqToolTip = "How fast the gate closes"
        warmthMixSlider.sqToolTip = "Warmth mix: 0 % is the dry sound, 100 % the fully warmed sound"
        for sl in [gateSlider, warmthSlider, attackSlider, holdSlider, releaseSlider, warmthMixSlider] { sl.heightAnchor.constraint(equalToConstant: ControlsGrid.controlHeight).isActive = true }
        noteLabel.font = Theme.Typography.body; noteLabel.textColor = Theme.Colors.label3
        noteLabel.isHidden = true
        bands.beginDrag = { [weak self] in self?.model.beginChange() }
        bands.crossoverChanged = { [weak self] i, hz in self?.model.setCrossover(i, hz: hz) }
        bands.endDrag = { [weak self] in self?.model.endChange() }

        // Rows on the Controls grid: name in the label column, the control from the value column to the trailing inset.
        for v in [rolePopup, presetPopup, noiseSlider, gateSlider, warmthSlider, attackSlider, holdSlider, releaseSlider, warmthMixSlider, bands] as [NSView] { ControlsRows.fill(v) }
        for c in [gateCheck, warmthCheck] {
            c.title = ""
            c.setContentHuggingPriority(.required, for: .horizontal)
        }
        gateCheck.setAccessibilityLabel("Noise gate"); warmthCheck.setAccessibilityLabel("Warmth")
        gateCheck.sqToolTip = "Noise gate"; warmthCheck.sqToolTip = "Warmth"
        bypassCheck.title = "Bypass"
        bypassCheck.setAccessibilityLabel("Bypass compressor")
        noiseSlider.sqToolTip = "Noise reduction"
        bands.heightAnchor.constraint(equalToConstant: Self.bandsHeight).isActive = true
        let noteRow = NSView()
        noteRow.addSubview(noteLabel)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noteLabel.leadingAnchor.constraint(equalTo: noteRow.leadingAnchor, constant: ControlsGrid.labelX),
            noteLabel.trailingAnchor.constraint(equalTo: noteRow.trailingAnchor, constant: -ControlsGrid.trailing),
            noteLabel.topAnchor.constraint(equalTo: noteRow.topAnchor, constant: ControlsGrid.gap),
            noteLabel.bottomAnchor.constraint(equalTo: noteRow.bottomAnchor, constant: -ControlsGrid.gap),
        ])
        let stack = ControlsRows.stack([
            TextBlockRow(label: "Role", controls: [rolePopup]),
            TextBlockRow(label: "Preset", controls: [presetPopup]),
            TextBlockRow(label: "Denoise", controls: [slotSpacer(), noiseSlider]),
            TextBlockRow(label: "Compressor", controls: [bypassCheck, ControlsRows.spacer()]),
            TextBlockRow(label: nil, controls: [bands], height: Self.bandsHeight + ControlsGrid.gap),
            TextBlockRow(label: "Noise Gate", controls: [gateCheck, gateSlider]),
            TextBlockRow(label: "Attack", controls: [slotSpacer(), attackSlider]),
            TextBlockRow(label: "Hold", controls: [slotSpacer(), holdSlider]),
            TextBlockRow(label: "Release", controls: [slotSpacer(), releaseSlider]),
            TextBlockRow(label: "Warmth", controls: [warmthCheck, warmthSlider]),
            TextBlockRow(label: "Mix", controls: [slotSpacer(), warmthMixSlider]),
            noteRow,
        ])
        addSubview(stack)
        ControlsRows.pin(stack, in: self)
        // Rows without a checkbox leave its slot empty so all seven sliders share one left edge (the gap comes from the row).
        for slot in checkSlots { slot.widthAnchor.constraint(equalTo: gateCheck.widthAnchor).isActive = true }
    }

    private var checkSlots: [NSView] = []

    /// An empty stand-in for the checkbox slot of a row. A subclass, so the layout probe counts it as a control: the row's
    /// first control starts at the value column and the gap to the slider is the grid's gap.
    private final class CheckSlot: NSView {}

    private func slotSpacer() -> NSView {
        let v = CheckSlot()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.required, for: .horizontal)
        checkSlots.append(v)
        return v
    }

    /// The crossover strip of the compressor.
    static let bandsHeight: CGFloat = Theme.Inspector.bandsHeight

    private func observe() {
        withObservationTracking {
            _ = model.role; _ = model.presets; _ = model.selectedPresetID; _ = model.compressor; _ = model.noiseReduction; _ = model.gate; _ = model.saturation
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.tracking else { return }
                self.refresh(); self.observe()
            }
        }
    }

    /// Refills the controls from the model (no callbacks).
    public func refresh() {
        let roleIndex = model.role.flatMap { AudioTag.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        rolePopup.selectItem(at: roleIndex)
        presetPopup.removeAllItems()
        for p in model.presets { presetPopup.addItem(withTitle: p.name) }
        if let id = model.selectedPresetID, let i = model.presets.firstIndex(where: { $0.id == id }) {
            presetPopup.selectItem(at: i)
        } else {
            presetPopup.addItem(withTitle: "Custom")
            presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
        }
        bypassCheck.state = model.compressor.bypass ? .on : .off
        noiseSlider.value = model.noiseReductionPercent
        gateCheck.state = model.gate.enabled ? .on : .off
        gateSlider.value = model.gate.thresholdDB
        gateSlider.isEnabled = model.gate.enabled
        warmthCheck.state = model.saturation.enabled ? .on : .off
        warmthSlider.value = model.saturation.driveDB
        warmthSlider.isEnabled = model.saturation.enabled
        attackSlider.value = model.gate.attackMs; holdSlider.value = model.gate.holdMs; releaseSlider.value = model.gate.releaseMs
        for sl in [attackSlider, holdSlider, releaseSlider] { sl.isEnabled = model.gate.enabled }
        warmthMixSlider.value = (model.saturation.mix * 100).rounded()
        warmthMixSlider.isEnabled = model.saturation.enabled
        bands.crossoversHz = model.compressor.crossoversHz
        bands.isBypassed = model.compressor.bypass
    }

    @objc private func presetChanged() {
        let i = presetPopup.indexOfSelectedItem
        guard model.presets.indices.contains(i) else { return }
        model.selectPreset(id: model.presets[i].id)
    }

    @objc private func roleChanged() {
        let i = rolePopup.indexOfSelectedItem
        model.setRole(i <= 0 ? nil : AudioTag.allCases[i - 1])
    }

    @objc private func gateToggled() { model.setGateEnabled(gateCheck.state == .on) }
    @objc private func warmthToggled() { model.setWarmthEnabled(warmthCheck.state == .on) }
    @objc private func bypassChanged() { model.setBypass(bypassCheck.state == .on) }
}
