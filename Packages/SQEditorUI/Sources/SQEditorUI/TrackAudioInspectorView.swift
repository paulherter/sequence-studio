import AppKit
import Observation
import SQAudioFX

/// Track audio inspector: preset popup, bypass, noise reduction and the 4-band compressor strip.
/// Plain AppKit controls bound to `TrackAudioInspectorModel`; per-band numbers stay in the model for now.
@MainActor
public final class TrackAudioInspectorView: NSView {
    public let model: TrackAudioInspectorModel

    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bypassCheck = NSButton(checkboxWithTitle: "Bypass compressor", target: nil, action: nil)
    private let noiseSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let noiseLabel = NSTextField(labelWithString: "")
    private let bands = CompressorBandsView()
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
        presetPopup.controlSize = .small; presetPopup.font = Theme.Fonts.small
        presetPopup.target = self; presetPopup.action = #selector(presetChanged)
        bypassCheck.controlSize = .small; bypassCheck.font = Theme.Fonts.small
        bypassCheck.target = self; bypassCheck.action = #selector(bypassChanged)
        noiseSlider.controlSize = .small
        noiseSlider.isContinuous = true
        noiseSlider.target = self; noiseSlider.action = #selector(noiseChanged)
        noiseLabel.font = Theme.Fonts.small; noiseLabel.textColor = Theme.Colors.label2
        noteLabel.font = Theme.Fonts.small; noteLabel.textColor = Theme.Colors.label3
        noteLabel.isHidden = true
        bands.beginDrag = { [weak self] in self?.model.beginChange() }
        bands.crossoverChanged = { [weak self] i, hz in self?.model.setCrossover(i, hz: hz) }
        bands.endDrag = { [weak self] in self?.model.endChange() }

        func head(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s.uppercased())
            t.font = Theme.Fonts.mini; t.textColor = Theme.Colors.label3
            return t
        }
        let stack = NSStackView(views: [head("Preset"), presetPopup, head("Noise Reduction"),
                                        NSStackView(views: [noiseSlider, noiseLabel]),
                                        head("Compressor"), bypassCheck, bands, noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.sm
        stack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.md, left: Theme.Spacing.md,
                                        bottom: Theme.Spacing.md, right: Theme.Spacing.md)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            presetPopup.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.md),
            bands.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.md),
            bands.heightAnchor.constraint(equalToConstant: 84),
            noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.md),
        ])
        if let row = stack.views.first(where: { $0 is NSStackView }) as? NSStackView {
            row.orientation = .horizontal; row.spacing = Theme.Spacing.sm
            noiseLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        }
    }

    private func observe() {
        withObservationTracking {
            _ = model.presets; _ = model.selectedPresetID; _ = model.compressor; _ = model.noiseReduction
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.tracking else { return }
                self.refresh(); self.observe()
            }
        }
    }

    /// Refills the controls from the model (no callbacks).
    public func refresh() {
        presetPopup.removeAllItems()
        for p in model.presets { presetPopup.addItem(withTitle: p.name) }
        if let id = model.selectedPresetID, let i = model.presets.firstIndex(where: { $0.id == id }) {
            presetPopup.selectItem(at: i)
        } else {
            presetPopup.addItem(withTitle: "Custom")
            presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
        }
        bypassCheck.state = model.compressor.bypass ? .on : .off
        noiseSlider.doubleValue = model.noiseReductionPercent
        noiseLabel.stringValue = "\(Int(model.noiseReductionPercent)) %"
        bands.crossoversHz = model.compressor.crossoversHz
        bands.isBypassed = model.compressor.bypass
    }

    @objc private func presetChanged() {
        let i = presetPopup.indexOfSelectedItem
        guard model.presets.indices.contains(i) else { return }
        model.selectPreset(id: model.presets[i].id)
    }

    @objc private func bypassChanged() { model.setBypass(bypassCheck.state == .on) }

    @objc private func noiseChanged() {
        let e = NSApp.currentEvent
        if e?.type == .leftMouseDown { model.beginChange() }
        model.setNoiseReductionPercent(noiseSlider.doubleValue)
        if e?.type == .leftMouseUp { model.endChange() }
    }
}
