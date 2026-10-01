import AppKit
import Observation
import SQText

/// Text properties inspector: plain AppKit controls bound to `TextInspectorModel`.
/// TODO: replace the numeric NSTextFields with the ScrubField control once it lands.
@MainActor
public final class TextInspectorView: NSView {
    public let model: TextInspectorModel

    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let savePresetButton = NSButton(title: "Save Style…", target: nil, action: nil)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let weightPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = NSTextField()
    private let colorWell = NSColorWell()
    private let alignControl = NSSegmentedControl(labels: ["Left", "Center", "Right"], trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let lineSpacingField = NSTextField()
    private let trackingField = NSTextField()
    private let italicCheck = NSButton(checkboxWithTitle: "Italic", target: nil, action: nil)
    private let capsCheck = NSButton(checkboxWithTitle: "All Caps", target: nil, action: nil)
    private let strokePositionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Premiere's six align buttons (left, centre, right, top, middle, bottom), momentary.
    private let alignFrameControl = NSSegmentedControl(frame: .zero)
    private static let alignSymbols: [(FrameAlignment, String, String)] = [
        (.left, "align.horizontal.left", "Align Left"), (.centerHorizontally, "align.horizontal.center", "Align Center Horizontally"),
        (.right, "align.horizontal.right", "Align Right"), (.top, "align.vertical.top", "Align Top"),
        (.centerVertically, "align.vertical.center", "Align Center Vertically"), (.bottom, "align.vertical.bottom", "Align Bottom"),
    ]
    private let vAlignControl = NSSegmentedControl(labels: ["Top", "Middle", "Bottom"], trackingMode: .selectOne,
                                                   target: nil, action: nil)
    private let boxOpacityField = NSTextField()
    private let shadowAngleField = NSTextField(), shadowDistField = NSTextField(), shadowOpacityField = NSTextField()

    private let strokeCheck = NSButton(checkboxWithTitle: "Stroke", target: nil, action: nil)
    private let strokeWell = NSColorWell()
    private let strokeWidthField = NSTextField()

    private let boxCheck = NSButton(checkboxWithTitle: "Background", target: nil, action: nil)
    private let boxWell = NSColorWell()
    private let padXField = NSTextField(), padYField = NSTextField(), radiusField = NSTextField()

    private let shadowCheck = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    private let shadowWell = NSColorWell()
    private let blurField = NSTextField()

    private let inPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private var colorSessionOpen = false
    private var colorSessionEnd: Task<Void, Never>?

    isolated deinit {
        colorSessionEnd?.cancel()
        if colorSessionOpen { model.endEditing() }       // the timer will never run: close the undo step now
    }
    private static let weights: [(String, FontWeight)] = [
        ("Thin", .thin), ("Light", .light), ("Regular", .regular), ("Medium", .medium),
        ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy), ("Black", .black),
    ]

    public init(model: TextInspectorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 560))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        build()
        refresh()
        track()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        for p in [presetPopup, fontPopup, weightPopup, inPopup, outPopup] {
            p.font = Theme.Fonts.small; p.controlSize = .small
            p.target = self
        }
        presetPopup.action = #selector(presetChanged)
        fontPopup.action = #selector(fontChanged)
        weightPopup.action = #selector(weightChanged)
        inPopup.action = #selector(inChanged)
        outPopup.action = #selector(outChanged)
        weightPopup.addItems(withTitles: Self.weights.map(\.0))
        savePresetButton.target = self; savePresetButton.action = #selector(savePreset)
        savePresetButton.controlSize = .small; savePresetButton.bezelStyle = .rounded
        alignControl.target = self; alignControl.action = #selector(alignChanged)
        alignControl.controlSize = .small
        vAlignControl.target = self; vAlignControl.action = #selector(vAlignChanged)
        vAlignControl.controlSize = .small
        vAlignControl.toolTip = "Vertical alignment inside an area text box"
        italicCheck.target = self; italicCheck.action = #selector(italicToggled)
        italicCheck.font = Theme.Fonts.small; italicCheck.controlSize = .small
        capsCheck.target = self; capsCheck.action = #selector(capsToggled)
        capsCheck.font = Theme.Fonts.small; capsCheck.controlSize = .small
        strokePositionPopup.addItems(withTitles: ["Outside", "Centre"])
        strokePositionPopup.font = Theme.Fonts.small; strokePositionPopup.controlSize = .small
        strokePositionPopup.target = self; strokePositionPopup.action = #selector(strokePositionChanged)
        strokePositionPopup.toolTip = "Outside keeps the letters whole; Centre draws the stroke over the letter edge"
        alignFrameControl.segmentCount = Self.alignSymbols.count
        alignFrameControl.trackingMode = .momentary
        alignFrameControl.controlSize = .small
        for (i, s) in Self.alignSymbols.enumerated() {
            alignFrameControl.setImage(NSImage(systemSymbolName: s.1, accessibilityDescription: s.2), forSegment: i)
            alignFrameControl.setToolTip(s.2, forSegment: i)
            alignFrameControl.setWidth(30, forSegment: i)
        }
        alignFrameControl.target = self; alignFrameControl.action = #selector(alignToFrame)
        alignFrameControl.setAccessibilityLabel("Align to frame")
        for (well, sel) in [(colorWell, #selector(colorChanged)), (strokeWell, #selector(strokeColorChanged)),
                            (boxWell, #selector(boxColorChanged)), (shadowWell, #selector(shadowColorChanged))] {
            well.target = self; well.action = sel
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            well.heightAnchor.constraint(equalToConstant: Theme.Metrics.controlHeight).isActive = true
        }
        for (check, sel) in [(strokeCheck, #selector(strokeToggled)), (boxCheck, #selector(boxToggled)),
                             (shadowCheck, #selector(shadowToggled))] {
            check.target = self; check.action = sel; check.font = Theme.Fonts.small; check.controlSize = .small
        }
        for f in [sizeField, lineSpacingField, trackingField, strokeWidthField, padXField, padYField, radiusField,
                  boxOpacityField, shadowAngleField, shadowDistField, shadowOpacityField, blurField] {
            f.font = Theme.Fonts.small; f.controlSize = .small
            f.alignment = .right
            f.target = self; f.action = #selector(numberChanged(_:))
            f.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }

        let stack = NSStackView(views: [
            section("Caption Style"),
            row("Preset", [presetPopup, savePresetButton]),
            section("Text"),
            row("Font", [fontPopup]),
            row("Weight", [weightPopup, italicCheck]),
            row("Size", [sizeField, colorWell, capsCheck]),
            row("Alignment", [alignControl]),
            row("Vertical", [vAlignControl]),
            row("Tracking", [trackingField, caption("Leading"), lineSpacingField]),
            row("Align", [alignFrameControl]),
            section("Appearance"),
            row(nil, [strokeCheck, strokeWell, caption("Width"), strokeWidthField]),
            row("Stroke", [strokePositionPopup]),
            row(nil, [boxCheck, boxWell]),
            row("Padding", [padXField, padYField]),
            row("Radius", [radiusField, caption("Opacity"), boxOpacityField]),
            row(nil, [shadowCheck, shadowWell]),
            row("Angle", [shadowAngleField, caption("Distance"), shadowDistField]),
            row("Opacity", [shadowOpacityField, caption("Blur"), blurField]),
            section("Animation"),
            row("In", [inPopup]),
            row("Out", [outPopup]),
        ])
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
        ])
    }

    private func caption(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = Theme.Fonts.small; t.textColor = Theme.Colors.label2
        return t
    }

    private func section(_ title: String) -> NSTextField {
        let t = NSTextField(labelWithString: title)
        t.font = Theme.Fonts.bodyTitle; t.textColor = Theme.Colors.label
        return t
    }

    private func row(_ label: String?, _ controls: [NSView]) -> NSStackView {
        let l = caption(label ?? "")
        l.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let r = NSStackView(views: [l] + controls)
        r.orientation = .horizontal; r.spacing = Theme.Spacing.sm; r.alignment = .centerY
        return r
    }

    // MARK: Model -> view

    private func track() {
        withObservationTracking {
            _ = model.style; _ = model.animations; _ = model.library; _ = model.fontFamilies
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh(); self?.track() }
        }
    }

    private func setNumber(_ f: NSTextField, _ v: Double) {
        if f.currentEditor() == nil { f.stringValue = String(format: "%g", (v * 100).rounded() / 100) }
    }

    private func nsColor(_ c: RGBAColor) -> NSColor {
        NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    private func rgba(_ c: NSColor) -> RGBAColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return RGBAColor(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent, alpha: s.alphaComponent)
    }

    private func fill(_ popup: NSPopUpButton, ids: [String], selected: String?) {
        popup.removeAllItems()
        popup.addItems(withTitles: ids.map(Self.title(for:)))
        for (i, id) in ids.enumerated() { popup.item(at: i)?.representedObject = id }
        if let s = selected, let i = ids.firstIndex(of: s) { popup.selectItem(at: i) } else { popup.selectItem(at: -1) }
    }

    static func title(for id: String) -> String {
        id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private func refresh() {
        let s = model.style
        fill(presetPopup, ids: model.presetIDs, selected: model.selectedPresetID)
        if model.selectedPresetID == nil { presetPopup.addItem(withTitle: "Custom"); presetPopup.selectItem(at: presetPopup.numberOfItems - 1) }
        fontPopup.removeAllItems(); fontPopup.addItems(withTitles: model.fontFamilies)
        fontPopup.selectItem(withTitle: s.fontName)
        if let i = Self.weights.firstIndex(where: { $0.1 == s.weight }) { weightPopup.selectItem(at: i) }
        setNumber(sizeField, s.size); setNumber(lineSpacingField, s.lineSpacing); setNumber(trackingField, s.tracking)
        italicCheck.state = s.italic ? .on : .off
        capsCheck.state = s.allCaps ? .on : .off
        vAlignControl.selectedSegment = [TextVerticalAlignment.top, .middle, .bottom].firstIndex(of: s.verticalAlignment) ?? 0
        colorWell.color = nsColor(s.color)
        alignControl.selectedSegment = [TextAlignment.left, .center, .right].firstIndex(of: s.alignment) ?? 1

        strokeCheck.state = s.stroke == nil ? .off : .on
        strokeWell.isEnabled = s.stroke != nil; strokeWidthField.isEnabled = s.stroke != nil
        strokePositionPopup.isEnabled = s.stroke != nil
        if let v = s.stroke {
            strokeWell.color = nsColor(v.color); setNumber(strokeWidthField, v.width)
            strokePositionPopup.selectItem(at: v.position == .outside ? 0 : 1)
        }

        boxCheck.state = s.background == nil ? .off : .on
        for c in [boxWell, padXField, padYField, radiusField, boxOpacityField] as [NSControl] { c.isEnabled = s.background != nil }
        if let v = s.background {
            boxWell.color = nsColor(v.color)
            setNumber(padXField, v.padding.horizontal); setNumber(padYField, v.padding.vertical)
            setNumber(radiusField, v.cornerRadius)
            setNumber(boxOpacityField, (v.color.alpha * 100).rounded())
        }

        shadowCheck.state = s.shadow == nil ? .off : .on
        for c in [shadowWell, shadowAngleField, shadowDistField, shadowOpacityField, blurField] as [NSControl] { c.isEnabled = s.shadow != nil }
        if let v = s.shadow {
            shadowWell.color = nsColor(v.color).withAlphaComponent(1)
            setNumber(shadowAngleField, v.angle.rounded()); setNumber(shadowDistField, v.distance)
            setNumber(shadowOpacityField, (v.color.alpha * 100).rounded()); setNumber(blurField, v.blur)
        }

        fill(inPopup, ids: model.inAnimationIDs, selected: model.selectedInID)
        fill(outPopup, ids: model.outAnimationIDs, selected: model.selectedOutID)
    }

    // MARK: View -> model

    @objc private func presetChanged() {
        if let id = presetPopup.selectedItem?.representedObject as? String { model.applyPreset(id) }
    }
    @objc private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Caption Style"
        alert.informativeText = "Name for the new style preset."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.saveCurrentAsPreset(named: field.stringValue) }
    }
    @objc private func fontChanged() { if let t = fontPopup.selectedItem?.title { model.setFontFamily(t) } }
    @objc private func weightChanged() {
        let i = weightPopup.indexOfSelectedItem
        if Self.weights.indices.contains(i) { model.setWeight(Self.weights[i].1) }
    }
    @objc private func alignChanged() {
        let a: [TextAlignment] = [.left, .center, .right]
        let i = alignControl.selectedSegment
        if a.indices.contains(i) { model.setAlignment(a[i]) }
    }
    @objc private func vAlignChanged() {
        let a: [TextVerticalAlignment] = [.top, .middle, .bottom]
        let i = vAlignControl.selectedSegment
        if a.indices.contains(i) { model.setVerticalAlignment(a[i]) }
    }
    @objc private func italicToggled() { model.setItalic(italicCheck.state == .on) }
    @objc private func capsToggled() { model.setAllCaps(capsCheck.state == .on) }
    @objc private func strokePositionChanged() { model.setStrokePosition(strokePositionPopup.indexOfSelectedItem == 1 ? .centre : .outside) }
    @objc private func alignToFrame() {
        let i = alignFrameControl.selectedSegment
        if Self.alignSymbols.indices.contains(i) { model.alignToFrame(Self.alignSymbols[i].0) }
    }
    @objc private func inChanged() { if let id = inPopup.selectedItem?.representedObject as? String { model.setInAnimation(id) } }
    @objc private func outChanged() { if let id = outPopup.selectedItem?.representedObject as? String { model.setOutAnimation(id) } }

    @objc private func strokeToggled() { model.setStrokeEnabled(strokeCheck.state == .on) }
    @objc private func boxToggled() { model.setBackgroundEnabled(boxCheck.state == .on) }
    @objc private func shadowToggled() { model.setShadowEnabled(shadowCheck.state == .on) }

    /// Color wells stream changes while the panel is dragged; hold one undo step open until idle.
    private func colorEdit(_ apply: () -> Void) {
        if !colorSessionOpen { colorSessionOpen = true; model.beginEditing() }
        apply()
        colorSessionEnd?.cancel()
        colorSessionEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.colorSessionOpen = false
            self.model.endEditing()
        }
    }
    @objc private func colorChanged() { colorEdit { model.setColor(rgba(colorWell.color)) } }
    @objc private func strokeColorChanged() { colorEdit { model.setStrokeColor(rgba(strokeWell.color)) } }
    // The wells carry colour only; opacity has its own field, so a colour pick keeps the current alpha.
    @objc private func boxColorChanged() {
        let a = model.style.background?.color.alpha ?? 1
        colorEdit { model.setBackgroundColor(rgba(boxWell.color.withAlphaComponent(a))) }
    }
    @objc private func shadowColorChanged() {
        let a = model.style.shadow?.color.alpha ?? 1
        colorEdit { model.setShadowColor(rgba(shadowWell.color.withAlphaComponent(a))) }
    }

    @objc private func numberChanged(_ f: NSTextField) {
        let v = f.doubleValue
        switch f {
        case sizeField: model.setSize(v)
        case lineSpacingField: model.setLineSpacing(v)
        case strokeWidthField: model.setStrokeWidth(v)
        case padXField, padYField:
            model.setBackgroundPadding(horizontal: padXField.doubleValue, vertical: padYField.doubleValue)
        case radiusField: model.setBackgroundRadius(v)
        case trackingField: model.setTracking(v)
        case boxOpacityField: model.setBackgroundOpacity(v / 100)
        case shadowAngleField, shadowDistField:
            model.setShadowAngle(shadowAngleField.doubleValue, distance: shadowDistField.doubleValue)
        case shadowOpacityField: model.setShadowOpacity(v / 100)
        case blurField: model.setShadowBlur(v)
        default: break
        }
        refresh()
    }
}
