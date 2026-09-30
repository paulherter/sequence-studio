import AppKit
import Observation
import SSCore
import SSRender
import UniformTypeIdentifiers

/// Properties/Color page: Source, Correction (with wheels), Conversion LUT, Creative LUT in processing order.
/// TODO: swap the NSSlider + NSTextField pairs for `ScrubField` once that control lands.
@MainActor
public final class ColorInspectorView: NSView {
    public let model: ColorInspectorModel

    private let stack = NSStackView()
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sliders: [ColorInspectorModel.Parameter: NSSlider] = [:]
    private var fields: [ColorInspectorModel.Parameter: NSTextField] = [:]
    private var wheelControls: [ColorInspectorModel.WheelID: ColorWheelControl] = [:]
    private var bypassButtons: [ColorInspectorModel.Section: NSButton] = [:]
    private let conversionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let creativePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let intensitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let intensityField = NSTextField(string: "")
    private var sliderGestureOpen = false

    /// Index 0 of the source popup is "Automatic (<detected>)", then these.
    private static let sources: [(String, ColorSpaceID)] = [
        ("Rec. 709", .rec709), ("S-Log3 / S-Gamut3.Cine", .sLog3SGamut3Cine), ("HLG / Rec. 2020", .hlgBT2020),
    ]
    private static func name(_ id: ColorSpaceID) -> String { sources.first { $0.1 == id }?.0 ?? "" }

    /// What a conversion / creative popup item does, by index (rebuilt on every refresh).
    private enum Pick { case choice(ColorInspectorModel.LUTChoice?), chooseFile }
    private var conversionPicks: [Pick] = []
    private var creativePicks: [Pick] = []

    public init(model: ColorInspectorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 640))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        refresh()
        observe()
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Build

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.sm
        stack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.md, left: Theme.Spacing.md, bottom: Theme.Spacing.md, right: Theme.Spacing.md)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        add(header(.source))
        style(sourcePopup)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        add(row("Interpret as", sourcePopup))

        add(header(.correction))
        let wheels = NSStackView()
        wheels.orientation = .horizontal
        wheels.spacing = Theme.Spacing.sm
        for id in ColorInspectorModel.WheelID.allCases {
            let w = ColorWheelControl(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            w.title = ["Shadows", "Midtones", "Highlights"][id.rawValue]
            w.translatesAutoresizingMaskIntoConstraints = false
            w.widthAnchor.constraint(equalToConstant: 82).isActive = true
            w.heightAnchor.constraint(equalToConstant: 92).isActive = true
            w.onBegin = { [weak self] _ in self?.model.onGestureBegan?() }
            w.onEnd = { [weak self] _ in self?.model.onGestureEnded?() }
            w.onChange = { [weak self, weak w] part in
                guard let self, let w else { return }
                switch part {
                case .wheel: self.model.setWheel(id, hue: w.hue, amount: w.amount)
                case .master: self.model.setWheelMaster(id, w.master)
                }
            }
            wheelControls[id] = w
            wheels.addArrangedSubview(w)
        }
        add(wheels)
        for p in ColorInspectorModel.Parameter.allCases { add(parameterRow(p)) }

        add(header(.conversionLUT))
        add(row("LUT", conversionPopup))
        conversionPopup.target = self
        conversionPopup.action = #selector(conversionChanged)
        style(conversionPopup)

        add(header(.creativeLUT))
        add(row("LUT", creativePopup))
        creativePopup.target = self
        creativePopup.action = #selector(creativeChanged)
        style(creativePopup)
        intensitySlider.target = self
        intensitySlider.action = #selector(intensityChanged)
        intensityField.target = self
        intensityField.action = #selector(intensityFieldChanged)
        styleField(intensityField)
        add(sliderRow("Intensity", intensitySlider, intensityField))
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.md).isActive = true
    }

    private func label(_ s: String, font: NSFont = Theme.Fonts.small, color: NSColor = Theme.Colors.label2) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        return l
    }

    private func header(_ s: ColorInspectorModel.Section) -> NSView {
        let title = label(s.title, font: Theme.Fonts.bodyTitle, color: Theme.Colors.label)
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSection(_:)))
        reset.tag = s.rawValue
        reset.controlSize = .small
        reset.bezelStyle = .accessoryBarAction
        reset.font = Theme.Fonts.small
        let h = NSStackView(views: [title, NSView(), reset])
        if s.canBypass {
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(bypassToggled(_:)))
            b.tag = s.rawValue
            b.controlSize = .small
            b.toolTip = "Enable / bypass \(s.title)"
            bypassButtons[s] = b
            h.insertArrangedSubview(b, at: 1)
        }
        h.orientation = .horizontal
        h.alignment = .centerY
        return h
    }

    private func row(_ name: String, _ control: NSView) -> NSView {
        let l = label(name)
        l.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let r = NSStackView(views: [l, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = Theme.Spacing.sm
        return r
    }

    private func sliderRow(_ name: String, _ slider: NSSlider, _ field: NSTextField) -> NSView {
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let l = label(name)
        l.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let r = NSStackView(views: [l, slider, field])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = Theme.Spacing.sm
        return r
    }

    private func parameterRow(_ p: ColorInspectorModel.Parameter) -> NSView {
        let s = NSSlider(value: Double(p.neutral), minValue: Double(p.range.lowerBound), maxValue: Double(p.range.upperBound),
                         target: self, action: #selector(sliderChanged(_:)))
        s.tag = p.rawValue
        let f = NSTextField(string: "")
        f.tag = p.rawValue
        f.target = self
        f.action = #selector(fieldChanged(_:))
        styleField(f)
        sliders[p] = s
        fields[p] = f
        return sliderRow(p.title, s, f)
    }

    private func style(_ popup: NSPopUpButton) {
        popup.controlSize = .small
        popup.font = Theme.Fonts.small
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func styleField(_ f: NSTextField) {
        f.controlSize = .small
        f.font = Theme.Fonts.small
        f.alignment = .right
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
    }

    // MARK: Actions

    @objc private func sourceChanged() {
        let i = sourcePopup.indexOfSelectedItem
        guard i >= 0, i <= Self.sources.count else { return }
        model.gesture { model.setSourceOverride(i == 0 ? nil : Self.sources[i - 1].1) }
    }

    @objc private func conversionChanged() {
        apply(conversionPicks[safe: conversionPopup.indexOfSelectedItem]) { model.conversionLUT = $0 }
    }

    @objc private func creativeChanged() {
        apply(creativePicks[safe: creativePopup.indexOfSelectedItem]) { model.creativeLUT = $0 }
    }

    private func apply(_ pick: Pick?, set: (ColorInspectorModel.LUTChoice?) -> Void) {
        switch pick {
        case .choice(let c)?: model.gesture { set(c) }
        case .chooseFile?:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
            panel.allowsMultipleSelection = false
            panel.message = "Choose a .cube LUT"
            if panel.runModal() == .OK, let url = panel.url { model.gesture { set(.file(url.path)) } }
            else { refresh() }
        case nil: refresh()
        }
    }

    /// Slider drags are one undo step: begin on the first change, end on mouse-up.
    private func trackGesture(_ body: () -> Void) {
        if !sliderGestureOpen { sliderGestureOpen = true; model.onGestureBegan?() }
        body()
        let t = NSApp.currentEvent?.type
        if t == .leftMouseUp || t == nil || t == .keyDown { sliderGestureOpen = false; model.onGestureEnded?() }
    }

    @objc private func sliderChanged(_ s: NSSlider) {
        guard let p = ColorInspectorModel.Parameter(rawValue: s.tag) else { return }
        trackGesture { model.set(p, Float(s.doubleValue)) }
        refresh()
    }

    @objc private func fieldChanged(_ f: NSTextField) {
        guard let p = ColorInspectorModel.Parameter(rawValue: f.tag) else { return }
        model.gesture { model.set(p, f.floatValue) }
        refresh()
    }

    @objc private func intensityChanged() {
        trackGesture { model.creativeIntensity = Float(intensitySlider.doubleValue) }
        refresh()
    }

    @objc private func intensityFieldChanged() {
        model.gesture { model.creativeIntensity = intensityField.floatValue / 100 }
        refresh()
    }

    @objc private func bypassToggled(_ b: NSButton) {
        guard let s = ColorInspectorModel.Section(rawValue: b.tag) else { return }
        model.gesture { model.setBypassed(s, b.state == .off) }   // checkbox = enabled
    }

    @objc private func resetSection(_ b: NSButton) {
        guard let s = ColorInspectorModel.Section(rawValue: b.tag) else { return }
        model.reset(s)
    }

    // MARK: Refresh

    private func observe() {
        withObservationTracking {
            _ = model.state
            _ = model.wheels
            _ = model.availableLUTs
            _ = model.bypassed
            _ = model.detectedSource
            _ = model.embeddedLUTName
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    public func refresh() {
        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: "Automatic (\(Self.name(model.detectedSource)))")
        Self.sources.forEach { sourcePopup.addItem(withTitle: $0.0) }
        if let o = model.sourceOverride, let i = Self.sources.firstIndex(where: { $0.1 == o }) { sourcePopup.selectItem(at: i + 1) }
        else { sourcePopup.selectItem(at: 0) }
        for p in ColorInspectorModel.Parameter.allCases {
            let v = model.value(p)
            if sliders[p]?.doubleValue != Double(v) { sliders[p]?.doubleValue = Double(v) }
            let text = p == .exposure ? String(format: "%.2f", v) : String(format: "%.0f", v)
            if fields[p]?.currentEditor() == nil { fields[p]?.stringValue = text }
        }
        for id in ColorInspectorModel.WheelID.allCases {
            let w = model.wheel(id)
            wheelControls[id]?.hue = w.hue
            wheelControls[id]?.amount = w.amount
            wheelControls[id]?.master = w.master
        }
        for (s, b) in bypassButtons { b.state = model.isBypassed(s) ? .off : .on }
        var conv: [(String, Pick)] = [("Automatic", .choice(.automatic))]
        if let n = model.embeddedLUTName { conv.append(("Embedded: \(n)", .choice(.embedded(name: n)))) }
        if let f = model.conversionLUT, f.filePath != nil { conv.append((f.name, .choice(f))) }
        conv.append(("Choose File…", .chooseFile)); conv.append(("None", .choice(nil)))
        fill(conversionPopup, conv, selected: model.conversionLUT, picks: &conversionPicks)
        var cre: [(String, Pick)] = [("None", .choice(nil))]
        if let f = model.creativeLUT { cre.append((f.name, .choice(f))) }
        cre.append(("Choose File…", .chooseFile))
        fill(creativePopup, cre, selected: model.creativeLUT, picks: &creativePicks)
        intensitySlider.doubleValue = Double(model.creativeIntensity)
        if intensityField.currentEditor() == nil { intensityField.stringValue = String(format: "%.0f", model.creativeIntensity * 100) }
    }

    private func fill(_ popup: NSPopUpButton, _ items: [(String, Pick)], selected: ColorInspectorModel.LUTChoice?,
                      picks: inout [Pick]) {
        popup.removeAllItems()
        picks = items.map(\.1)
        items.forEach { popup.addItem(withTitle: $0.0) }
        let i = items.firstIndex { if case .choice(let c) = $0.1 { c == selected } else { false } } ?? 0
        popup.selectItem(at: i)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
