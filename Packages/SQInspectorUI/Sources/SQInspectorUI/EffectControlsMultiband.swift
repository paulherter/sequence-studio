import AppKit
import SQAudioFX
import SQCore

/// The Mac setup window and the Controls rows; the presets and model calls live in EffectControlsMultibandModel.swift.
extension MultibandEditor {
    public static let panelSize = NSSize(width: 560, height: 560)

    /// Band colors low to high (blue, orange, green, purple) from the Theme palette.
    @MainActor static var bandColors: [NSColor] { [Theme.Colors.accent, Theme.Colors.warning, Theme.Colors.green, Theme.Colors.clipTitle] }
}

extension MultibandEditor {
    /// Offscreen render fixture: the floating setup window (title bar and content) for a demo clip with the Broadcast preset.
    @MainActor public static func renderedWindow(clipName: String = "Interview A") -> NSView {
        var clip = Clip(name: clipName, media: UUID(), kind: .audio,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        guard let id = clip.addEffect(kind: ClipEffect.audioMultibandKind) else { return NSView() }
        let model = EffectControlsModel()
        model.setClip(clip)
        model.onEdit = { [weak model] c, _, _ in model?.setClip(c) }
        model.applyMultibandPreset(id, index: 1)
        let panel = MultibandEditorPanel(effect: id, model: model)
        panel.update()
        let floating = SQFloatingPanel(key: "render", title: "Multiband Compressor", subtitle: clipName, content: panel)
        return floating.renderedView
    }
}


/// The open Multiband setup windows, one per effect. A row is rebuilt whenever the list rebuilds, so the window lives here
/// and not in the row: it stays open while the user plays, scrubs or edits keyframes.
@MainActor
enum MultibandEditorWindows {
    private struct Entry { let panel: MultibandEditorPanel; let floating: SQFloatingPanel }
    private static var open: [ClipEffect.ID: Entry] = [:]

    static func isOpen(_ effect: ClipEffect.ID) -> Bool { open[effect]?.floating.isShown == true }
    static func floating(_ effect: ClipEffect.ID) -> SQFloatingPanel? { open[effect]?.floating }

    /// Opens the window (or brings the open one forward). `anchor` is the screen rect of the button, for the first placement.
    static func show(effect: ClipEffect.ID, model: EffectControlsModel, anchor: NSRect?) {
        if let e = open[effect], e.floating.isShown { e.floating.show(near: anchor); return }
        let panel = MultibandEditorPanel(effect: effect, model: model)
        let floating = SQFloatingPanel(key: "multiband.\(effect.uuidString)", title: "Multiband Compressor",
                                       subtitle: model.multibandClipName(effect) ?? "", content: panel)
        panel.onGone = { [weak floating] in floating?.close() }
        floating.onClose = { [weak panel] in panel?.stopMeters(); open[effect] = nil }
        open[effect] = Entry(panel: panel, floating: floating)
        panel.update()
        floating.show(near: anchor)
        panel.startMeters()
    }

    static func close(_ effect: ClipEffect.ID) { open[effect]?.floating.close() }

    static func refresh(_ effect: ClipEffect.ID) {
        guard let e = open[effect], e.floating.isShown else { return }
        e.panel.update()
    }
}

/// The row under the effect header: opens the floating setup window.
final class MultibandEditorRow: RowBackground, RowUpdating {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let button = SQButton(title: "Edit Custom Setup", target: nil, action: nil)

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        fill = Theme.Colors.content
        button.target = self; button.action = #selector(open)
        button.setAccessibilityLabel("Edit Custom Setup")
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let s = button.intrinsicContentSize
        button.frame = NSRect(x: ControlsMetrics.labelX, y: (bounds.height - Theme.Metrics.capsule) / 2, width: max(s.width, 120), height: Theme.Metrics.capsule)
    }

    @objc private func open() {
        let anchor = window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        MultibandEditorWindows.show(effect: effect, model: model, anchor: anchor)
    }

    func update() { MultibandEditorWindows.refresh(effect) }
}

/// "All Parameters" disclosure under the setup button: the individual parameter rows (with their keyframe controls) sit
/// below it and are collapsed by default, the graphic editor is the main way to edit.
final class MultibandParamsRow: RowBackground, RowUpdating {
    let header: InspectorSectionHeader

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        header = InspectorSectionHeader(title: "All Parameters", hasEnableToggle: false,
                                        isExpanded: model.isMultibandParametersOpen(effect))
        super.init(frame: .zero)
        fill = Theme.Colors.panel
        header.onToggleExpanded = { [weak model] _ in model?.toggleMultibandParameters(effect) }
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

/// Window content. Controls are the SQ ScrubField / SQPopup / SQButton / SQCheckbox; a drag is one undo gesture.
final class MultibandEditorPanel: NSView {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let presetPopup = SQPopup(frame: .zero, pullsDown: false)
    private let linkBox = SQCheckbox(title: "Link Band Controls", target: nil, action: nil)
    private let outputLabel = makeLabel("Output Gain (dB)", font: Theme.Typography.caption, color: Theme.Colors.label3)
    private var powerButton: IconButton!
    private var headings: [NSTextField] = []
    var onGone: (() -> Void)?
    private let outputField = ScrubField(frame: .zero)
    private let bands = CompressorBandsView(frame: .zero)
    private let xoverLabel = makeLabel("Crossover (Hz)", font: Theme.Typography.caption, color: Theme.Colors.label3)
    private var xoverFields: [ScrubField] = []
    private var captions: [NSTextField] = []
    private var headers: [NSTextField] = []
    private var rangeLabels: [NSTextField] = []
    private var fields: [[ScrubField]] = []     // [parameter row][band]
    private let switchCaption = makeLabel("Solo / Bypass", font: Theme.Typography.caption, color: Theme.Colors.label3)
    private var soloButtons: [SQButton] = []
    private var bypassButtons: [SQButton] = []
    private let reductionCaption = makeLabel("Reduction dB", font: Theme.Typography.caption, color: Theme.Colors.label3)
    private var reductionLabels: [NSTextField] = []
    private var separators: [NSRect] = []
    private let limiterBox = SQCheckbox(title: "Output Limiter (Brickwall)", target: nil, action: nil)
    private let limiterReduction = makeLabel("", font: Theme.Typography.caption, color: Theme.Colors.label2)
    private var limiterCaptions: [NSTextField] = []
    private var limiterFields: [ScrubField] = []
    private static let rows = MultibandEditor.bandRows
    private static let limiterRows = MultibandEditor.limiterRows
    private static let customTitle = "Custom"

    private var meterTimer: Timer?
    private var meters = MultibandMeterDisplay()
    private let spectrumInputBox = SQCheckbox(title: "Spectrum at Input", target: nil, action: nil)
    private static let spectrumInputDefaultsKey = "sq.multiband.spectrumAtInput"
    private var spectrum = SpectrumDisplay()
    private let analyzer = SpectrumAnalyzer()
    private var snapshot: [Float] = []

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.panel.setFill(); bounds.fill()
        Theme.Colors.divider.setFill(); for r in separators { r.fill() }
    }

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: NSRect(origin: .zero, size: MultibandEditor.panelSize))
        powerButton = IconButton(symbol: .power, label: "Multiband Compressor On / Off", size: 12) { [weak self] in self?.togglePower() }
        addSubview(powerButton)
        for t in ["Bands", "Band Settings"] {
            let h = makeLabel(t, font: Theme.Typography.captionStrong, color: Theme.Colors.label2); headings.append(h); addSubview(h)
        }
        presetPopup.controlSize = .small
        presetPopup.font = Theme.Typography.body
        presetPopup.addItems(withTitles: MultibandEditor.presets.map(\.name) + [Self.customTitle])
        presetPopup.target = self; presetPopup.action = #selector(presetPicked)
        presetPopup.setAccessibilityLabel("Multiband Compressor Preset")
        linkBox.target = self; linkBox.action = #selector(linkToggled)
        linkBox.sqToolTip = "Dragging one band moves all four by the same amount"
        addSubview(presetPopup); addSubview(linkBox); addSubview(outputLabel); addSubview(xoverLabel)
        configure(outputField, key: ClipEffect.mbOutputGainKey); addSubview(outputField)
        for i in 1...3 { let f = ScrubField(frame: .zero); configure(f, key: ClipEffect.mbCrossoverKey(i)); xoverFields.append(f); addSubview(f) }

        bands.beginDrag = { [weak model] in model?.beginGesture() }
        bands.endDrag = { [weak model] in model?.endGesture() }
        bands.crossoverChanged = { [weak self] i, hz in guard let self else { return }; self.model.setCrossover(self.effect, index: i, hz: hz) }
        bands.bandColors = MultibandEditor.bandColors
        addSubview(bands)
        spectrumInputBox.target = self; spectrumInputBox.action = #selector(spectrumInputToggled)
        spectrumInputBox.sqToolTip = "Show the spectrum going into the compressor instead of coming out"
        spectrumInputBox.state = UserDefaults.standard.bool(forKey: Self.spectrumInputDefaultsKey) ? .on : .off
        addSubview(spectrumInputBox)

        for n in 1...MultibandEditor.bandCount {
            let h = makeLabel(SQL10n.format("Band %@", String(n)), font: Theme.Typography.captionStrong, color: MultibandEditor.bandColors[n - 1])
            headers.append(h); addSubview(h)
            let rl = makeLabel("", font: Theme.Typography.caption, color: Theme.Colors.label3)
            rangeLabels.append(rl); addSubview(rl)
            let s = Self.toggle("S", tint: Theme.Colors.warning, label: SQL10n.format("Solo Band %@", String(n)), tag: n - 1, target: self, action: #selector(soloToggled(_:)))
            let b = Self.toggle("B", tint: Theme.Colors.accent, label: SQL10n.format("Bypass Band %@", String(n)), tag: n - 1, target: self, action: #selector(bypassToggled(_:)))
            soloButtons.append(s); bypassButtons.append(b); addSubview(s); addSubview(b)
            let r = makeLabel("", font: Theme.Typography.caption, color: Theme.Colors.label2)
            reductionLabels.append(r); addSubview(r)
        }
        addSubview(switchCaption); addSubview(reductionCaption)
        for (ri, r) in Self.rows.enumerated() {
            let c = makeLabel(r.title, font: Theme.Typography.caption, color: Theme.Colors.label3)
            captions.append(c); addSubview(c)
            var line: [ScrubField] = []
            for n in 1...MultibandEditor.bandCount {
                let f = ScrubField(frame: .zero); configure(f, key: r.key(n), bandRow: ri, band: n - 1); line.append(f); addSubview(f)
            }
            fields.append(line)
        }

        limiterBox.target = self; limiterBox.action = #selector(limiterToggled)
        limiterBox.sqToolTip = "Output limiter: raises by margin minus threshold and holds the peaks at the margin"
        addSubview(limiterBox)
        limiterReduction.alignment = .right; addSubview(limiterReduction)
        for r in Self.limiterRows {
            let c = makeLabel(r.title, font: Theme.Typography.caption, color: Theme.Colors.label3)
            limiterCaptions.append(c); addSubview(c)
            let f = ScrubField(frame: .zero); configure(f, key: r.key); limiterFields.append(f); addSubview(f)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func toggle(_ title: String, tint: NSColor, label: String, tag: Int, target: AnyObject, action: Selector) -> SQButton {
        let b = SQButton(title: title, target: target, action: action)
        b.setButtonType(.pushOnPushOff)
        b.horizontalPadding = 6
        b.tag = tag
        b.sqToolTip = label
        b.setAccessibilityLabel(label)
        b.contentTintColor = Theme.Colors.label2
        return b
    }

    /// `bandRow`/`band`: a band column field, which goes through the link-aware band setter.
    private func configure(_ f: ScrubField, key: String, bandRow: Int? = nil, band: Int = 0) {
        guard let s = MultibandEditor.spec(key) else { return }
        let p = model.multibandProperty(effect, key)
        let isCrossover = key.hasPrefix("x")
        f.range = s.range; f.decimals = s.decimals; f.defaultValue = s.defaultValue
        f.step = max(s.step, (s.range.upperBound - s.range.lowerBound) / 400)
        f.isPlain = true
        let set: (MultibandEditorPanel, EffectControlsModel, Double) -> Void = { panel, model, v in
            if isCrossover, let i = Int(key.dropFirst()) { model.setCrossover(panel.effect, index: i - 1, hz: v) }
            else if let r = bandRow { model.setMultibandBandValue(panel.effect, key: Self.rows[r].key, band: band, to: v) }
            else { model.setValue(p, to: v) }
        }
        f.onBegin = { [weak model] in model?.beginGesture() }
        f.onChange = { [weak self, weak model] v in guard let self, let model else { return }; set(self, model, v) }
        f.onEnd = { [weak self, weak model] v in
            guard let self, let model else { return }
            set(self, model, v)
            model.endGesture()
        }
        f.onCancel = { [weak model] _ in model?.cancelGesture() }
        f.onReset = { [weak model] in model?.resetAll(p) }
        f.setAccessibilityLabel(s.title)
        f.sqToolTip = s.title
    }

    private static let pad: CGFloat = 16
    private static let captionW: CGFloat = 96
    private static let cell: CGFloat = 4     // gap between fields of neighboring columns

    override func layout() {
        super.layout()
        let w = bounds.width, pad = Self.pad, fh = Theme.Metrics.capsule, row = Theme.Row.property + 2, ch: CGFloat = 14
        let dw = max(w - 2 * pad, 40)
        let colX = pad + Self.captionW, colW = max((dw - Self.captionW) / CGFloat(MultibandEditor.bandCount), 30)
        let fieldW = colW - Self.cell
        func midY(_ y: CGFloat, _ h: CGFloat, _ item: CGFloat) -> CGFloat { y + (h - item) / 2 }
        func caption(_ l: NSTextField, _ y: CGFloat) { l.frame = NSRect(x: pad, y: midY(y, row, ch), width: Self.captionW - 4, height: ch) }
        var seps: [NSRect] = []
        func separator(_ y: CGFloat) { seps.append(NSRect(x: 0, y: y, width: w, height: 1)) }

        // Top bar: power, preset, link, output gain.
        var y: CGFloat = 12
        powerButton.frame = NSRect(x: pad, y: y, width: fh, height: fh)
        presetPopup.frame = NSRect(x: pad + fh + Theme.Spacing.sm, y: y, width: 150, height: fh)
        linkBox.sizeToFit()
        linkBox.frame = NSRect(x: presetPopup.frame.maxX + Theme.Spacing.md, y: midY(y, fh, linkBox.frame.height), width: linkBox.frame.width, height: linkBox.frame.height)
        outputField.frame = NSRect(x: w - pad - fieldW, y: y, width: fieldW, height: fh)
        let ox = linkBox.frame.maxX + Theme.Spacing.sm
        outputLabel.frame = NSRect(x: ox, y: midY(y, fh, ch), width: max(outputField.frame.minX - ox - Theme.Spacing.sm, 0), height: ch)
        outputLabel.alignment = .right
        y += fh + 12; separator(y); y += 1

        // Bands: display and crossover fields.
        y += 10
        headings[0].frame = NSRect(x: pad, y: y, width: dw, height: ch)
        spectrumInputBox.sizeToFit()
        spectrumInputBox.frame = NSRect(x: w - pad - spectrumInputBox.frame.width, y: midY(y, ch, spectrumInputBox.frame.height),
                                        width: spectrumInputBox.frame.width, height: spectrumInputBox.frame.height)
        y += ch + 6
        bands.frame = NSRect(x: pad, y: y, width: dw, height: 96); y += 96 + 8
        xoverLabel.frame = NSRect(x: pad, y: midY(y, fh, ch), width: Self.captionW - 4, height: ch)
        for (i, f) in xoverFields.enumerated() { f.frame = NSRect(x: colX + CGFloat(i) * colW, y: y, width: fieldW, height: fh) }
        y += fh + 12; separator(y); y += 1

        // Band settings: colored column headers, S / B, five parameter rows, live reduction.
        y += 10
        headings[1].frame = NSRect(x: pad, y: y, width: dw, height: ch); y += ch + 6
        for (n, h) in headers.enumerated() {
            h.frame = NSRect(x: colX + CGFloat(n) * colW, y: y, width: fieldW, height: ch)
            rangeLabels[n].frame = NSRect(x: colX + CGFloat(n) * colW, y: y + ch, width: fieldW, height: ch)
        }
        y += 2 * ch + 4
        caption(switchCaption, y)
        for n in 0..<MultibandEditor.bandCount {
            let bw = (fieldW - Theme.Spacing.xs) / 2
            soloButtons[n].frame = NSRect(x: colX + CGFloat(n) * colW, y: midY(y, row, fh), width: bw, height: fh)
            bypassButtons[n].frame = NSRect(x: soloButtons[n].frame.maxX + Theme.Spacing.xs, y: midY(y, row, fh), width: bw, height: fh)
        }
        y += row
        for (r, line) in fields.enumerated() {
            caption(captions[r], y)
            for (n, f) in line.enumerated() { f.frame = NSRect(x: colX + CGFloat(n) * colW, y: midY(y, row, fh), width: fieldW, height: fh) }
            y += row
        }
        caption(reductionCaption, y)
        for (n, l) in reductionLabels.enumerated() { l.frame = NSRect(x: colX + CGFloat(n) * colW, y: midY(y, row, ch), width: fieldW, height: ch) }
        y += row + 6; separator(y); y += 1

        // Output limiter: heading with its switch, live reduction at the right, four fields under captions.
        y += 10
        limiterBox.sizeToFit()
        limiterBox.frame = NSRect(x: pad, y: midY(y, fh, limiterBox.frame.height), width: limiterBox.frame.width, height: limiterBox.frame.height)
        let lrx = limiterBox.frame.maxX + Theme.Spacing.sm
        limiterReduction.frame = NSRect(x: lrx, y: midY(y, fh, ch), width: max(w - pad - lrx, 0), height: ch)
        y += fh + 6
        for (i, c) in limiterCaptions.enumerated() { c.frame = NSRect(x: colX + CGFloat(i) * colW, y: y, width: fieldW, height: ch) }
        y += ch + 4
        for (i, f) in limiterFields.enumerated() { f.frame = NSRect(x: colX + CGFloat(i) * colW, y: y, width: fieldW, height: fh) }
        separators = seps
        needsDisplay = true
    }

    private func togglePower() {
        let s = EffectSection.effect(effect, kind: ClipEffect.audioMultibandKind)
        model.toggleEffectEnabled(s)
    }

    @objc private func presetPicked() {
        let i = presetPopup.indexOfSelectedItem
        if i >= 0, i < MultibandEditor.presets.count { model.applyMultibandPreset(effect, index: i) } else { update() }
    }
    @objc private func spectrumInputToggled() {
        let on = spectrumInputBox.state == .on
        UserDefaults.standard.set(on, forKey: Self.spectrumInputDefaultsKey)
        if meterTimer != nil { AudioSpectrumTap.shared.watch(effect, atInput: on) }
        spectrum = SpectrumDisplay()
        bands.spectrumDB = []
    }
    @objc private func linkToggled() { model.setMultibandLink(effect, linkBox.state == .on) }
    @objc private func soloToggled(_ b: SQButton) { model.toggleMultibandSolo(effect, band: b.tag) }
    @objc private func bypassToggled(_ b: SQButton) { model.toggleMultibandBypass(effect, band: b.tag) }
    @objc private func limiterToggled() {
        model.setValue(model.multibandProperty(effect, ClipEffect.mbLimiterOnKey), to: limiterBox.state == .on ? 1 : 0)
    }

    func update() {
        let snap = model.multibandSnapshot(effect)
        func sync(_ f: ScrubField, _ key: String) {
            let p = model.multibandProperty(effect, key)
            if !f.isDragging, !f.isEditing { f.value = snap[key] ?? 0 }
            f.isAnimated = model.isAnimated(p); f.isMixed = model.isMixed(p)
        }
        sync(outputField, ClipEffect.mbOutputGainKey)
        for (i, f) in xoverFields.enumerated() { sync(f, ClipEffect.mbCrossoverKey(i + 1)) }
        for (r, line) in fields.enumerated() { for (n, f) in line.enumerated() { sync(f, Self.rows[r].key(n + 1)) } }
        for (i, f) in limiterFields.enumerated() { sync(f, Self.limiterRows[i].key) }
        let xs = (1...3).map { snap[ClipEffect.mbCrossoverKey($0)] ?? 0 }
        if bands.crossoversHz != xs { bands.crossoversHz = xs }
        let match = MultibandEditor.matchingPreset(snap) ?? MultibandEditor.presets.count
        if presetPopup.indexOfSelectedItem != match { presetPopup.selectItem(at: match) }
        for (n, h) in headers.enumerated() {
            h.stringValue = SQL10n.format("Band %@", String(n + 1))
            rangeLabels[n].stringValue = MultibandEditor.rangeText(band: n, crossovers: xs)
        }
        let enabled = model.isEffectEnabled(.effect(effect, kind: ClipEffect.audioMultibandKind))
        powerButton.contentTintColor = enabled ? Theme.Colors.accent : Theme.Colors.label2
        func on(_ k: String) -> Bool { (snap[k] ?? 0) >= 0.5 }
        linkBox.state = on(ClipEffect.mbLinkKey) ? .on : .off
        let solo = (1...4).map { on(ClipEffect.mbSoloKey($0)) }, byp = (1...4).map { on(ClipEffect.mbBypassKey($0)) }
        let anySolo = solo.contains(true)
        for n in 0..<MultibandEditor.bandCount {
            soloButtons[n].state = solo[n] ? .on : .off
            soloButtons[n].contentTintColor = solo[n] ? Theme.Colors.warning : Theme.Colors.label2
            bypassButtons[n].state = byp[n] ? .on : .off
            bypassButtons[n].contentTintColor = byp[n] ? Theme.Colors.accent : Theme.Colors.label2
        }
        bands.bandDimmed = (0..<4).map { byp[$0] || (anySolo && !solo[$0]) }
        let limOn = on(ClipEffect.mbLimiterOnKey)
        limiterBox.state = limOn ? .on : .off
        for f in limiterFields { f.alphaValue = limOn ? 1 : Theme.State.disabledAlpha }
        showMeters()
    }

    // MARK: Meters (real engine feed, ~30 Hz while the popup is open)

    func startMeters() {
        MultibandMeterTap.shared.watch(effect)
        AudioSpectrumTap.shared.watch(effect, atInput: spectrumInputBox.state == .on)
        meters = MultibandMeterDisplay()
        spectrum = SpectrumDisplay()
        meterTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickMeters() } }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    func stopMeters() {
        meterTimer?.invalidate(); meterTimer = nil
        MultibandMeterTap.shared.watch(nil)
        AudioSpectrumTap.shared.watch(nil)
        meters = MultibandMeterDisplay()
        spectrum = SpectrumDisplay()
        bands.spectrumDB = []
        showMeters()
    }

    private func tickMeters() {
        if model.multibandClipName(effect) == nil { onGone?(); return }
        let before = meters
        meters.update(MultibandMeterTap.shared.reading(for: effect), at: ProcessInfo.processInfo.systemUptime)
        if meters != before { showMeters() }
        let seq = AudioSpectrumTap.shared.snapshot(for: effect, into: &snapshot)
        spectrum.update(sequence: seq, at: ProcessInfo.processInfo.systemUptime) {
            analyzer.magnitudesDB(snapshot, sampleRate: Double(ClipAudioFXChain.sampleRate), points: SpectrumDisplay.points)
        }
        bands.spectrumDB = spectrum.levelsDB
    }

    private func showMeters() {
        let live = meters.isLive
        bands.inputLevel = meters.inputDB.map { Double(MeterBallistics.position(dB: $0)) }
        bands.gainReductionDB = meters.gainReductionDB.map(Double.init)
        for (n, l) in reductionLabels.enumerated() { l.stringValue = live ? String(format: "%.1f", meters.gainReductionDB[n]) : "–" }
        limiterReduction.stringValue = live ? String(format: "Reduction %.1f dB", meters.limiterReductionDB) : "Reduction –"
    }

}
