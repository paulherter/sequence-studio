import AppKit
import SQCore
import SQExport
import SQUIKit

/// Export dialog, the L modal 860 x 640 (design board "Export"): header with sequence name and preset, left column with the footage
/// preview (the output's aspect), scrub row, one flat list of output files and one summary line; right column one
/// scrolling settings column of InspectorSections (no click-through); footer with file name, folder and the one primary
/// button. A normal export is one Return. Settings that do not apply to the chosen codec are shown disabled with a tip.
@MainActor
public final class ExportDialogView: NSView {
    public static let size = NSSize(width: Theme.Modal.widthL, height: Theme.Modal.heightL)

    private let model: ExportDialogModel
    private let preview = ExportPreviewModel()
    private let onExport: () -> Void
    private let onCancel: () -> Void

    // Layout (board numbers)
    private let headerH: CGFloat = Theme.Modal.headerHeight
    private let footerH: CGFloat = Theme.Modal.footerHeight
    private let leftW: CGFloat = 320
    private let padX: CGFloat = 16
    private let boxH: CGFloat = 204
    private var lineH: CGFloat { ceil(Theme.Typography.body.ascender - Theme.Typography.body.descender + Theme.Typography.body.leading) }
    private var titleH: CGFloat { ceil(Theme.Typography.titleStrong.ascender - Theme.Typography.titleStrong.descender + Theme.Typography.titleStrong.leading) }
    private var fieldH: CGFloat { Theme.Metrics.quietField }
    private var bodyBottom: CGFloat { Self.size.height - footerH }

    // Views
    private let titleLabel = NSTextField(labelWithString: SQL10n.string("Export"))
    private let sequenceLabel = NSTextField(labelWithString: "")
    private let presetLabel = NSTextField(labelWithString: SQL10n.string("Preset"))
    private var presetPopup: ClosurePopup?
    private var addButton: SQButton!
    private let previewBox = NSView()
    private let picture = ExportPictureView()
    private let playButton = SQButton(symbol: .play, label: "Play", target: nil, action: nil, size: 11)
    private let scrubBar = ExportScrubBar()
    private let timeLabel = NSTextField(labelWithString: "")
    private let listTitle = NSTextField(labelWithString: SQL10n.string("Export"))
    private let listBox = NSView()
    private let listScroll = NSScrollView()
    private let listContent = NSView()
    private let variantsBox = NSView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let voiceHintLabel = NSTextField(wrappingLabelWithString: "")
    private let chipsBox = NSView()
    private let settingsScroll = NSScrollView()
    private let fileNameField = ExportCapsuleField()
    private let folderField = ExportCapsuleField()
    private let changeButton = SQButton(title: "Change\u{2026}", target: nil, action: nil, style: .standard)
    private let cancelButton = SQButton(title: "Cancel", target: nil, action: nil, style: .standard)
    private let exportButton = SQButton(title: "Export", target: nil, action: nil, style: .accent)
    private let otherFormatsButton = SQButton(title: "Other Formats\u{2026}", target: nil, action: nil, style: .standard)
    /// Timeline and still targets that are not a render (frame, markers CSV, EDL, FCPXML, Final Cut XML, OpenTimelineIO):
    /// the one place they live now that File has a single Export. Empty hides the footer button.
    public var otherFormats: [(title: String, action: @MainActor () -> Void)] = [] {
        didSet { otherFormatsButton.isHidden = otherFormats.isEmpty }
    }
    /// The Size popup's "Custom" entry was chosen: the width/height fields show.
    private var customSize = false

    public init(model: ExportDialogModel, onExport: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model; self.onExport = onExport; self.onCancel = onCancel
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        build()
        refresh()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// Stops playback and releases the preview source (call when the dialog closes).
    public func close() { preview.close() }

    /// Every option the form shows, in reading order: header, settings sections, footer (a test compares it with the list from before the L rework).
    var optionTitles: [String] {
        func rows(in v: NSView) -> [String] {
            var out: [String] = []
            if let r = v as? ExportSettingRow { out.append(r.title) }
            for s in v.subviews { out += rows(in: s) }
            return out
        }
        return [presetLabel.stringValue, "Add another output"] + rows(in: settingsScroll)
            + [changeButton.title, cancelButton.title, exportButton.title]
    }

    // MARK: Build

    private func styled(_ l: NSTextField, _ font: NSFont = Theme.Typography.body, _ color: NSColor = Theme.Colors.label2) {
        l.font = font; l.textColor = color; l.lineBreakMode = .byTruncatingTail
    }

    private func build() {
        // Header: title, sequence name, preset popup, add output.
        styled(titleLabel, Theme.Typography.titleStrong, Theme.Colors.label)
        titleLabel.frame = NSRect(x: padX, y: ((headerH - titleH) / 2).rounded(), width: 48, height: titleH)
        addSubview(titleLabel)
        styled(sequenceLabel, Theme.Typography.body, Theme.Colors.label3)
        addSubview(sequenceLabel)
        styled(presetLabel)
        presetLabel.frame = NSRect(x: 0, y: ((headerH - lineH) / 2).rounded(), width: 44, height: lineH)
        presetLabel.alignment = .right
        addSubview(presetLabel)
        addButton = SQButton(symbol: .plus, label: SQL10n.string("Add another output"), target: self, action: #selector(addFormatTapped), size: 12)
        addButton.boxHeight = fieldH
        addButton.frame = NSRect(x: Self.size.width - padX - 24, y: ((headerH - fieldH) / 2).rounded(), width: 24, height: fieldH)
        addSubview(addButton)

        // Left column: preview in a viewer-colored box, the frame inside takes the output's aspect.
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = Theme.Colors.viewer.cgColor
        previewBox.layer?.cornerRadius = Theme.Radius.control
        previewBox.frame = NSRect(x: padX, y: headerH + 1 + 14, width: leftW - 2 * padX, height: boxH)
        addSubview(previewBox)
        picture.onClick = { [weak self] in self?.preview.togglePlay() }
        previewBox.addSubview(picture)

        let barY = previewBox.frame.maxY + 10
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.boxHeight = fieldH
        playButton.frame = NSRect(x: padX, y: barY, width: 24, height: fieldH)
        addSubview(playButton)
        let timeW: CGFloat = 78
        let barX = playButton.frame.maxX + Theme.Spacing.sm
        scrubBar.frame = NSRect(x: barX, y: barY, width: leftW - padX - timeW - Theme.Spacing.sm - barX, height: fieldH)
        scrubBar.onScrub = { [weak self] f in self?.preview.scrub(to: f) }
        addSubview(scrubBar)
        styled(timeLabel)
        timeLabel.alignment = .right
        timeLabel.frame = NSRect(x: leftW - padX - timeW, y: barY + ((fieldH - lineH) / 2).rounded(), width: timeW, height: lineH)
        addSubview(timeLabel)

        // Output list.
        styled(listTitle, Theme.Typography.captionStrong, Theme.Colors.label3)
        listTitle.frame = NSRect(x: padX, y: barY + fieldH + 10, width: 200, height: 22)
        listTitle.cell?.alignment = .left
        addSubview(listTitle)
        listBox.wantsLayer = true
        listBox.layer?.backgroundColor = Theme.Colors.field.cgColor
        listBox.layer?.borderColor = Theme.Colors.fieldEdge.cgColor
        listBox.layer?.borderWidth = 0.5
        listBox.layer?.cornerRadius = Theme.Radius.overlay
        listBox.layer?.masksToBounds = true
        addSubview(listBox)
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.borderType = .noBorder
        listScroll.documentView = listContent
        listBox.addSubview(listScroll)
        addSubview(variantsBox)
        styled(summaryLabel)
        styled(warningLabel, Theme.Typography.body, Theme.Colors.warning)
        addSubview(warningLabel)
        styled(voiceHintLabel, Theme.Typography.body, Theme.Colors.warning)
        addSubview(voiceHintLabel)
        addSubview(chipsBox)

        // Right column: one scrolling settings column.
        settingsScroll.frame = NSRect(x: leftW + 1, y: headerH + 1, width: Self.size.width - leftW - 1, height: bodyBottom - headerH - 1)
        settingsScroll.drawsBackground = false
        settingsScroll.hasVerticalScroller = true
        settingsScroll.autohidesScrollers = true
        settingsScroll.scrollerStyle = .overlay
        settingsScroll.borderType = .noBorder
        addSubview(settingsScroll)

        // Footer: file name, folder + buttons.
        styled(summaryLabel)
        summaryLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        fileNameField.target = self
        fileNameField.action = #selector(fileNameCommitted)
        fileNameField.setAccessibilityLabel(SQL10n.string("File name"))
        folderField.isEditable = false
        folderField.setAccessibilityLabel(SQL10n.string("Export folder"))
        changeButton.boxHeight = fieldH
        for b in [otherFormatsButton, cancelButton, exportButton] {      // the shared footer's buttons (same as the other L dialogs)
            b.horizontalPadding = SQDialogMetrics.buttonPadding
            b.boxHeight = SQDialogMetrics.buttonHeight
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        changeButton.target = self; changeButton.action = #selector(changeFolder)
        cancelButton.target = self; cancelButton.action = #selector(cancelTapped)
        exportButton.target = self; exportButton.action = #selector(exportTapped)
        exportButton.keyEquivalent = "\r"
        otherFormatsButton.target = self; otherFormatsButton.action = #selector(otherFormatsTapped)
        otherFormatsButton.isHidden = true
        layoutFooter()

        preview.onChange = { [weak self] in self?.syncPreview() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: headerH, width: bounds.width, height: 1).fill()
        NSRect(x: leftW, y: headerH + 1, width: 1, height: bodyBottom - headerH - 1).fill()
    }

    // MARK: Refresh

    /// Updates everything the model decides. `pane`: rebuild the settings column (not while a scrub gesture runs in it).
    private func refresh(pane rebuildPane: Bool = true, preview reloadPreview: Bool = true) {
        refreshHeader()
        rebuildList()
        if rebuildPane { rebuildSettings() }
        refreshFooter()
        if reloadPreview { configurePreview() }
        syncPreview()
    }

    private func refreshHeader() {
        sequenceLabel.stringValue = model.sequences.first { $0.id == model.selectedID }?.name ?? ""
        sequenceLabel.frame = NSRect(x: titleLabel.frame.maxX + 12, y: ((headerH - lineH) / 2).rounded(), width: 260, height: lineH)
        refreshPreset()
    }

    private func configurePreview() {
        preview.configure(sequenceID: model.selectedID, settings: model.settings, provider: model.previewSource)
    }

    private func syncPreview() {
        let hasSource = model.previewSource != nil
        let note: String? = !hasSource ? SQL10n.string("No preview available") : preview.errorText ?? (preview.isLoading && preview.image == nil ? SQL10n.string("Loading preview\u{2026}") : nil)
        layoutPicture()
        picture.show(image: preview.image, note: preview.image == nil ? note : nil)
        scrubBar.fraction = preview.fraction
        scrubBar.isEnabled = preview.frameCount > 0
        playButton.image = Theme.symbol(preview.isPlaying ? .pause : .play, size: 11, label: SQL10n.string(preview.isPlaying ? "Pause" : "Play"))
        playButton.isEnabled = preview.frameCount > 0
        timeLabel.stringValue = preview.frameCount > 0 ? preview.timecode : ""
    }

    /// The picture takes the aspect of the output (9:16 for a vertical sequence) inside the viewer box.
    private func layoutPicture() {
        let v = model.settings.video
        let box = previewBox.bounds.size
        let aspect = v.height > 0 ? CGFloat(v.width) / CGFloat(v.height) : 16.0 / 9.0
        var w = box.width, h = box.width / aspect
        if h > box.height { h = box.height; w = h * aspect }
        picture.frame = NSRect(x: ((box.width - w) / 2).rounded(), y: ((box.height - h) / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    // MARK: Output list

    private func rebuildList() {
        listContent.subviews.forEach { $0.removeFromSuperview() }
        let rows = model.outputRows
        let w = leftW - 2 * padX
        let inset: CGFloat = 4
        let rowH = Theme.Row.list
        for (i, r) in rows.enumerated() {
            let row = ExportListRow(frame: NSRect(x: 0, y: inset + CGFloat(i) * rowH, width: w, height: rowH))
            row.isSelected = r.isSelected
            let id = r.id
            row.onSelect = { [weak self] in self?.model.selectOutput(id); self?.refresh() }
            let check = ClosureCheckbox(title: "", on: r.isChecked) { [weak self] on in
                self?.model.setOutputChecked(id, on); self?.refresh(pane: false, preview: false)
            }
            check.frame = NSRect(x: 12, y: ((rowH - 14) / 2).rounded(), width: 14, height: 14)
            check.setAccessibilityLabel(r.title)
            row.addSubview(check)
            let size = NSTextField(labelWithString: r.sizeText)
            styled(size)
            size.alignment = .right
            let sizeW: CGFloat = 78
            size.frame = NSRect(x: w - 12 - sizeW, y: ((rowH - lineH) / 2).rounded(), width: sizeW, height: lineH)
            row.addSubview(size)
            let name = NSTextField(labelWithString: r.title)
            styled(name, Theme.Typography.body, Theme.Colors.label)
            name.frame = NSRect(x: 34, y: ((rowH - lineH) / 2).rounded(), width: w - 34 - 12 - sizeW - 4, height: lineH)
            row.addSubview(name)
            listContent.addSubview(row)
        }
        let contentH = inset * 2 + CGFloat(rows.count) * rowH
        // Left column from the bottom: summary, optional warning, optional variants checkbox; the list takes the rest.
        let top = listTitle.frame.maxY + 10
        let summaryY = bodyBottom - 14      // the summary line lives in the footer band now
        let warning = model.validationMessages.first ?? ""
        warningLabel.stringValue = warning
        let warnH: CGFloat = warning.isEmpty ? 0 : lineH * 2
        warningLabel.frame = NSRect(x: padX, y: summaryY - 6 - warnH, width: w, height: warnH)
        variantsBox.subviews.forEach { $0.removeFromSuperview() }
        var bottom = warning.isEmpty ? summaryY : warningLabel.frame.minY
        chipsBox.subviews.forEach { $0.removeFromSuperview() }
        var chipX: CGFloat = 0, chipY: CGFloat = 0
        let chipH = Theme.Metrics.capsule
        for issue in model.deliveryIssues {
            let chip = DeliveryChipView(text: SQL10n.localized(issue.text), warning: issue.severity == .warning)
            if chipX > 0, chipX + chip.frame.width > w { chipX = 0; chipY += chipH + Theme.Spacing.xs }
            chip.frame.origin = CGPoint(x: chipX, y: chipY)
            chipsBox.addSubview(chip)
            chipX += chip.frame.width + Theme.Spacing.xs
        }
        let chipsH: CGFloat = chipsBox.subviews.isEmpty ? 0 : chipY + chipH
        chipsBox.frame = NSRect(x: padX, y: bottom - 6 - chipsH, width: w, height: chipsH)
        if chipsH > 0 { bottom = chipsBox.frame.minY }
        let hint = model.exportNotes
        voiceHintLabel.stringValue = hint
        let hintH: CGFloat = hint.isEmpty ? 0 : ceil(voiceHintLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: .greatestFiniteMagnitude)).height ?? lineH)
        voiceHintLabel.frame = NSRect(x: padX, y: bottom - 6 - hintH, width: w, height: hintH)
        if !hint.isEmpty { bottom = voiceHintLabel.frame.minY }
        if model.hasVariants {
            let c = ClosureCheckbox(title: "Also export every format variant", on: model.exportAllFormats) { [weak self] on in
                self?.model.exportAllFormats = on; self?.refresh(pane: false, preview: false)
            }
            c.sqToolTip = SQL10n.string("Also exports every format variant of the checked sequences; file names carry the format name")
            variantsBox.addSubview(c)
            variantsBox.frame = NSRect(x: padX, y: bottom - 6 - 18, width: w, height: 18)
            c.frame.origin = .zero
            bottom = variantsBox.frame.minY
        } else { variantsBox.frame = .zero }
        let boxHeight = min(contentH, max(bottom - 10 - top, rowH + 2 * inset))
        listBox.frame = NSRect(x: padX, y: top, width: w, height: boxHeight)
        listScroll.frame = listBox.bounds
        listContent.frame = NSRect(x: 0, y: 0, width: w, height: contentH)
        summaryLabel.stringValue = model.outputSummaryText
        summaryLabel.sqToolTip = SQL10n.format("Estimated size of the checked files: %@", model.estimatedSizeText)
    }

    @objc private func addFormatTapped() { model.addFormat(); refresh() }

    // MARK: Preset

    private func refreshPreset() {
        presetPopup?.removeFromSuperview()
        let custom = model.presetID == ExportDialogModel.customPresetID
        var names = model.presets.map(\.name)
        if custom { names.append(SQL10n.string("Custom")) }
        let sel = custom ? names.count - 1 : (model.presets.firstIndex { $0.id == model.presetID } ?? 0)
        let p = ClosurePopup(items: names, selected: sel, width: 230) { [weak self] i in
            guard let self, self.model.presets.indices.contains(i) else { return }
            self.model.presetID = self.model.presets[i].id
            self.refresh()
        }
        p.frame = NSRect(x: addButton.frame.minX - 12 - 230, y: ((headerH - fieldH) / 2).rounded(), width: 230, height: fieldH)
        addSubview(p)
        presetPopup = p
        presetLabel.frame.origin.x = p.frame.minX - 8 - presetLabel.frame.width
    }

    // MARK: Footer

    /// The shared dialog footer (`SQDialog.footerRow`, board `.sh-foot`): summary left, Cancel and Export right. File Name and
    /// Folder are the "Output" section of the settings column (board).
    private func layoutFooter() {
        let footer = SQDialog.footerRow(left: [summaryLabel], right: [otherFormatsButton, cancelButton, exportButton])
        footer.translatesAutoresizingMaskIntoConstraints = true
        footer.frame = NSRect(x: 0, y: bodyBottom, width: Self.size.width, height: footerH)
        addSubview(footer)
        let w = ceil((changeButton.title as NSString).size(withAttributes: [.font: changeButton.font ?? Theme.Typography.body]).width) + 32
        changeButton.frame.size = NSSize(width: w, height: fieldH)
    }

    private func refreshFooter() {
        fileNameField.stringValue = model.fileName
        fileNameField.suffix = model.fileExtension.isEmpty ? "" : "." + model.fileExtension
        folderField.stringValue = (model.outputDirectory?.path as NSString?)?.abbreviatingWithTildeInPath ?? SQL10n.string("Choose a folder\u{2026}")
        exportButton.isEnabled = model.canExport
    }

    @objc private func fileNameCommitted() {
        model.fileName = fileNameField.stringValue
        fileNameField.stringValue = model.fileName
        fileNameField.needsLayout = true
        window?.makeFirstResponder(self)
    }

    @objc private func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = SQL10n.string("Choose")
        panel.message = SQL10n.string("Choose a folder for the exported files")
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.model.outputDirectory = url; self?.refresh(pane: false, preview: false) }
        }
    }

    @objc private func exportTapped() {
        if fileNameField.currentEditor() != nil || fileNameField.stringValue != model.fileName {
            model.fileName = fileNameField.stringValue      // a name typed but not confirmed still counts
        }
        if model.canExport { preview.close(); onExport() }
    }
    @objc private func otherFormatsTapped() {
        let items = otherFormats.map { f in SQMenuItem(title: f.title, action: f.action) }
        SQContextMenu.popUp(items: items, below: otherFormatsButton)
    }
    @objc private func cancelTapped() { preview.close(); onCancel() }
    @objc private func playTapped() { preview.togglePlay() }

    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": preview.togglePlay()
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): preview.step(-1)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): preview.step(1)
        default: super.keyDown(with: event)
        }
    }
}

/// Vertical stack that lays out from the top inside a scroll view.
private final class ExportFlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings column (one scroll, InspectorSections)

extension ExportDialogView {
    private typealias Item = ExportSettingRow.Item

    private func rebuildSettings() {
        let saved = settingsScroll.contentView.bounds.origin
        let stack = ExportFlippedStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        settingsScroll.documentView = stack
        let clip = settingsScroll.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        // An audio-only output has no picture: no Video section, no cover.
        let audioOnly = model.settings.audioOnly != nil
        let sections: [(String, String, Bool, [NSView])] = [
            ("Video", "export.video", true, audioOnly ? [] : videoRows()),
            ("Audio", "export.audio", true, model.settings.frameOutput != nil ? [] : audioRows()),
            ("Captions", "export.captions", true, captionRows()),
            ("Range", "export.range", true, rangeRows()),
            ("Output", "export.output", true, outputRows()),
            ("Advanced", "export.advanced", false, advancedRows()),
        ]
        for (n, (title, key, open, rows)) in sections.filter({ !$0.3.isEmpty }).enumerated() {
            // Board `.sec`: the first has no top line (24 high), the others a 4 pt gap, then the line inside a 25 pt row.
            if n > 0 { Self.addGap(4, to: stack) }
            let sec = InspectorSection(title: title, key: key, defaultOpen: open)
            sec.header.drawsBackground = false
            sec.header.showsTopLine = n > 0
            sec.headerHeightConstraint.constant = n > 0 ? 25 : 24
            for r in rows { sec.addRow(r) }
            stack.addArrangedSubview(sec)
            sec.translatesAutoresizingMaskIntoConstraints = false
            sec.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            sec.onLayoutChange = { [weak stack] in stack?.needsLayout = true }
        }
        settingsScroll.layoutSubtreeIfNeeded()
        settingsScroll.contentView.scroll(to: saved)
        settingsScroll.reflectScrolledClipView(settingsScroll.contentView)
    }

    private static func addGap(_ h: CGFloat, to stack: NSStackView) {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func row(_ title: String, _ items: [Item], dimmed: Bool = false) -> NSView {
        ExportSettingRow(title: title, items: items, dimmed: dimmed)
    }

    private func text(_ s: String, _ color: NSColor = Theme.Colors.label) -> NSTextField {
        let f = NSTextField(labelWithString: SQL10n.string(s))
        f.font = Theme.Typography.body; f.textColor = color; f.lineBreakMode = .byTruncatingTail
        f.sizeToFit()
        return f
    }

    private func popup(_ items: [String], selected: Int, disabled: Set<Int> = [], enabled: Bool = true, tip: String? = nil,
                       onSelect: (@MainActor (Int) -> Void)? = nil) -> Item {
        let p = ClosurePopup(items: items, selected: selected, disabled: disabled, width: 100, onSelect: onSelect)
        p.isEnabled = enabled
        p.sqToolTip = tip.map { SQL10n.string($0) }
        return .fill(p)
    }

    private func check(_ title: String, on: Bool, enabled: Bool = true, then: @escaping @MainActor (Bool) -> Void) -> Item {
        .fixed(ClosureCheckbox(title: title, on: on, enabled: enabled, onToggle: then))
    }

    /// Pins an item to the width of the Bitrate mode popup so the Maximum row lines up with it.
    private static func fixedWidth(_ item: ExportSettingRow.Item, _ w: CGFloat) -> ExportSettingRow.Item { .fixed(item.view, w) }

    private func segmented(_ labels: [String], selected: Int, disabled: Set<Int> = [], width: CGFloat, then: @escaping @MainActor (Int) -> Void) -> Item {
        let s = ClosureSegmented(labels: labels, selected: selected, disabled: disabled, segmentWidth: width, onSelect: then)
        return .fixed(s, s.frame.width)
    }

    private func scrub(value: Double, range: ClosedRange<Double>, step: Double, unit: String = "", decimals: Int = 0, prefix: String = "",
                       defaultValue: Double? = nil, enabled: Bool = true, onChange: @escaping @MainActor (Double) -> Void) -> Item {
        let f = ScrubField(frame: NSRect(x: 0, y: 0, width: 90, height: Theme.Metrics.quietField))
        f.range = range; f.step = step; f.unit = unit; f.decimals = decimals; f.value = value
        f.defaultValue = defaultValue
        f.prefix = prefix
        f.unitOutside = !unit.isEmpty    // dialog rule: the unit sits after the capsule (`units(_:)`)
        f.restFill = Theme.Colors.fill   // same field style as the popups of the dialog
        f.isEnabled = enabled
        f.onChange = { [weak self] v in onChange(v); self?.refresh(pane: false, preview: false) }
        f.onEnd = { [weak self] v in onChange(v); self?.refresh(pane: false, preview: true) }
        return unit.isEmpty ? .fill(f) : .fixed(f, Self.numberFieldWidth)
    }

    /// Board `NUM` width (`.fld.num`).
    static let numberFieldWidth: CGFloat = 84

    /// A number field with a unit: the field, then the unit after the capsule (the row's 8 pt gap, as in every dialog).
    private func units(_ item: Item) -> [Item] {
        guard let f = item.view as? ScrubField, f.unitOutside, !f.unit.isEmpty else { return [item] }
        let label = SQUnitLabel(f.unit)
        return [item, .fixed(label, SQUnitLabel.width(of: f.unit))]
    }

    private func reload() { refresh(pane: true, preview: true) }

    // MARK: Output (board: File Name with the extension after it, Folder with Change…)

    private func outputRows() -> [NSView] {
        [row("File Name", [.fill(fileNameField)]),
         row("Folder", [.fill(folderField), .fixed(changeButton, changeButton.frame.width)])] + chapterRows()
    }

    // MARK: Video

    private static let sizes: [(Int, Int)] = [(1080, 1920), (1920, 1080), (1080, 1080), (1080, 1350), (1280, 720), (3840, 2160), (2160, 3840)]

    private func videoRows() -> [NSView] {
        let s = model.settings
        let d = model.presetSettings
        let mastering = s.video.codec.isMastering
        var rows: [NSView] = []
        if let output = s.frameOutput { return frameOutputRows(output, s: s, d: d) }
        let codecs: [(String, VideoCodec)] = [("H.264", .h264), ("HEVC", .hevc), ("ProRes 422 Proxy", .prores422Proxy), ("ProRes 422 LT", .prores422LT), ("ProRes 422", .prores422), ("ProRes 422 HQ", .prores422HQ), ("ProRes 4444", .prores4444)]
        rows.append(row("Codec", [popup(codecs.map(\.0), selected: codecs.firstIndex { $0.1 == s.video.codec } ?? 0) { [weak self] i in
            self?.model.codec = codecs[i].1
            if codecs[i].1 == .h264, self?.model.settings.video.profile == .main10 { self?.model.edit { $0.video.profile = .automatic } }
            self?.reload()
        }]))
        let profiles: [(String, VideoProfile)]
        switch s.video.codec {
        case .h264: profiles = [("Automatic", .automatic), ("Baseline", .baseline), ("Main", .main), ("High", .high)]
        case .hevc: profiles = [("Automatic", .automatic), ("Main", .main), ("Main 10", .main10)]
        default: profiles = [("Automatic", .automatic)]
        }
        rows.append(row("Profile", [popup(profiles.map(\.0), selected: profiles.firstIndex { $0.1 == s.video.profile } ?? 0, enabled: !s.video.codec.isProRes,
                                          tip: s.video.codec.isProRes ? "Fixed by the ProRes codec" : "\(s.video.bitDepth)-bit") { [weak self] i in
            self?.model.edit { $0.video.profile = profiles[i].1 }; self?.reload()
        }]))
        rows.append(contentsOf: sizeRows(s: s, d: d))
        var rates = ExportDialogModel.frameRates
        if !rates.contains(model.fps) { rates.append(model.fps) }
        rows.append(row("Frame Rate", [popup(rates.map(Self.fpsText), selected: rates.firstIndex(of: model.fps) ?? 0) { [weak self] i in
            self?.model.fps = rates[i]; self?.reload()
        }]))
        // Constant quality: the size follows the picture, so no bitrate rows (not for ProRes, which has no rate control).
        if !mastering {
            let q = s.video.constantQuality
            rows.append(row("Rate Control", [popup(["Target bitrate", "Constant quality"], selected: q == nil ? 0 : 1) { [weak self] i in
                self?.model.edit { $0.video.constantQuality = i == 0 ? nil : 0.6 }; self?.reload()
            }] + (q.map { value in
                units(scrub(value: (value * 100).rounded(), range: 5...100, step: 1, unit: "%", decimals: 0,
                            defaultValue: 60) { [weak self] v in
                    self?.model.edit { $0.video.constantQuality = v / 100 }
                })
            } ?? [])))
        }
        if s.video.constantQuality != nil {
            rows.append(row("", [check("Use hardware encoding", on: s.video.hardwareEncoding) { [weak self] on in
                self?.model.edit { $0.video.hardwareEncoding = on }; self?.refresh(pane: false, preview: false)
            }]))
            rows.append(contentsOf: encoderSpeedRows(mastering: mastering))
            rows.append(contentsOf: colorSpaceRows(s))
            return rows
        }
        // ProRes has no rate control: no mode switch, only the (disabled) target.
        let kinds = BitrateKind.available(for: s.video.codec)
        let target = units(scrub(value: model.bitrateMbps, range: 0.5...400, step: 0.5, unit: "Mbit/s", decimals: 1,
                           defaultValue: Double(d.video.bitrate.averageBitsPerSecond) / 1_000_000, enabled: !mastering) { [weak self] v in
            self?.model.bitrateMbps = v
        })
        if !mastering {
            // Steps set the target bitrate from bits per pixel; a hand-typed bitrate shows "Custom".
            let steps = QualityStep.allCases
            let current = s.video.qualityStep
            var titles = steps.map(\.title)
            if current == nil { titles.append("Custom") }
            rows.append(row("Quality", [popup(titles, selected: current.flatMap { steps.firstIndex(of: $0) } ?? steps.count,
                                              tip: "Sets the target bitrate for the picture size and rate") { [weak self] i in
                guard i < steps.count else { return }
                self?.model.edit { $0.video.applyQuality(steps[i]) }; self?.reload()
            }]))
        }
        if kinds.isEmpty {
            rows.append(row("Bitrate", target))
        } else {
            let modeItem = popup(kinds.map(\.title), selected: kinds.firstIndex(of: model.bitrateKind) ?? 0,
                                 tip: kinds.map(\.help).joined(separator: "\n")) { [weak self] i in
                self?.model.bitrateKind = kinds[i]; self?.reload()
            }
            rows.append(row("Bitrate", [.fixed(modeItem.view, 96)] + target))
        }
        if mastering || model.bitrateKind.showsMaximum { rows.append(row("Max Bitrate", [Self.fixedWidth(check("Limit", on: model.hasMaxBitrate, enabled: !mastering) { [weak self] on in
            self?.model.hasMaxBitrate = on; self?.reload()
        }, 96)] + units(scrub(value: model.maxBitrateMbps, range: 0.5...600, step: 0.5, unit: "Mbit/s", decimals: 1,
                 defaultValue: Double(d.video.bitrate.maxBitsPerSecond ?? d.video.bitrate.averageBitsPerSecond * 3 / 2) / 1_000_000,
                 enabled: !mastering && model.hasMaxBitrate) { [weak self] v in self?.model.maxBitrateMbps = v }))) }
        rows.append(row("", [check("Use hardware encoding", on: s.video.hardwareEncoding) { [weak self] on in
            self?.model.edit { $0.video.hardwareEncoding = on }; self?.refresh(pane: false, preview: false)
        }]))
        rows.append(contentsOf: encoderSpeedRows(mastering: mastering))
        // The engine renders and tags Rec. 709 (1-1-1) only; a popup of unavailable spaces would be dead controls.
        rows.append(contentsOf: colorSpaceRows(s))
        return rows
    }

    /// GIF and image sequence: the picture size and rate, and for a sequence its image format.
    private func frameOutputRows(_ output: FrameOutput, s: ExportSettings, d: ExportSettings) -> [NSView] {
        var rows: [NSView] = []
        if case .sequence(let format) = output {
            let formats = FrameStillFormat.available
            rows.append(row("Image Format", [popup(formats.map(\.displayName), selected: formats.firstIndex(of: format) ?? 0) { [weak self] i in
                self?.model.edit { $0.frameOutput = .sequence(formats[i]) }; self?.reload()
            }]))
        } else {
            rows.append(row("Format", [.fixed(text("Animated GIF, loops, 256 colors per frame"), 300)]))
        }
        rows.append(contentsOf: sizeRows(s: s, d: d))
        var rates = ExportDialogModel.frameRates
        if !rates.contains(model.fps) { rates.append(model.fps) }
        rows.append(row("Frame Rate", [popup(rates.map(Self.fpsText), selected: rates.firstIndex(of: model.fps) ?? 0) { [weak self] i in
            self?.model.fps = rates[i]; self?.reload()
        }]))
        return rows
    }

    /// Encoder Speed popup (H.264 / HEVC; saved per Mac in AppSettings) and, on a small Mac at Quality, a suggestion line.
    private func encoderSpeedRows(mastering: Bool) -> [NSView] {
        let speeds = EncoderSpeed.allCases
        let current = model.encoderSpeed
        var rows: [NSView] = [row("Encoder Speed", [popup(speeds.map(\.displayName), selected: speeds.firstIndex(of: current) ?? 0,
                                                          enabled: !mastering,
                                                          tip: mastering ? "ProRes encodes at one speed" : "Faster encoding, slightly larger or softer file") { [weak self] i in
            self?.model.encoderSpeed = speeds[i]
            var a = AppSettings.load(); a.exportEncoderSpeed = speeds[i]; a.save()
            self?.reload()
        }])]
        if !mastering, let hint = ExportDialogModel.encoderSpeedHint(current) {
            let t = text(hint, Theme.Colors.label3)
            t.font = Theme.Typography.caption; t.sizeToFit()
            rows.append(row("", [.fixed(t, 260)]))
        }
        return rows
    }

    /// Size popup (sequence size and the usual delivery sizes, plus Custom) and, for Custom, the width/height fields.
    private func sizeRows(s: ExportSettings, d: ExportSettings) -> [NSView] {
        var sizes = Self.sizes
        if let f = model.sequences.first(where: { $0.id == model.selectedID })?.format, f.isValid {
            let own = (f.width & ~1, f.height & ~1)
            if !sizes.contains(where: { $0 == own }) { sizes.insert(own, at: 0) }
        }
        let cur = (s.video.width, s.video.height)
        let match = sizes.firstIndex { $0 == cur }
        let isCustom = customSize || match == nil
        var names = sizes.map { "\($0.0) \u{00D7} \($0.1)" }
        names.append("Custom")
        var rows: [NSView] = [row("Size", [popup(names, selected: isCustom ? names.count - 1 : match!) { [weak self] i in
            guard let self else { return }
            if i == sizes.count { self.customSize = true } else {
                self.customSize = false
                self.model.width = sizes[i].0; self.model.height = sizes[i].1
            }
            self.reload()
        }])]
        if isCustom {
            let w = scrub(value: Double(s.video.width), range: 2...8192, step: 2, defaultValue: Double(d.video.width)) { [weak self] v in self?.model.width = Int(v) & ~1 }
            let h = scrub(value: Double(s.video.height), range: 2...8192, step: 2, defaultValue: Double(d.video.height)) { [weak self] v in self?.model.height = Int(v) & ~1 }
            rows.append(row("Custom Size", [w, .fixed(text("\u{00D7}", Theme.Colors.label3)), h]))
        }
        return rows
    }

    // MARK: Audio

    private func audioRows() -> [NSView] {
        let s = model.settings
        let on = s.audio.enabled
        let audioOnly = s.audioOnly != nil
        var rows: [NSView] = []
        // An audio-only file always has audio, and its format (M4A / WAV) decides the codec.
        if !audioOnly {
            rows.append(row("Include Audio", [check("Include audio in the file", on: on) { [weak self] v in
                self?.model.edit { $0.audio.enabled = v }; self?.reload()
            }]))
            rows.append(row("Codec", [popup(["AAC", "PCM"], selected: s.audio.codec == .aac ? 0 : 1, enabled: on) { [weak self] i in
                self?.model.edit { $0.audio.codec = i == 0 ? .aac : .pcm }; self?.reload()
            }]))
        }
        let rates = [44_100, 48_000, 96_000]
        rows.append(row("Sample Rate", [popup(["44.1 kHz", "48 kHz", "96 kHz"], selected: rates.firstIndex(of: s.audio.sampleRate) ?? 1, enabled: on) { [weak self] i in
            self?.model.edit { $0.audio.sampleRate = rates[i] }; self?.refresh(pane: false, preview: false)
        }]))
        if s.effectiveAudio.codec == .aac {
            let rates = [128_000, 192_000, 256_000, 320_000]
            rows.append(row("Bitrate", [popup(["128 kbit/s", "192 kbit/s", "256 kbit/s", "320 kbit/s"], selected: rates.firstIndex(of: s.audio.bitrate) ?? 1, enabled: on) { [weak self] i in
                self?.model.edit { $0.audio.bitrate = rates[i] }; self?.refresh(pane: false, preview: false)
            }]))
        } else {
            let flac = s.audioOnly == .flac
            let depths = flac ? [16, 24] : [16, 24, 32]
            rows.append(row("Bit Depth", [popup(depths.map { "\($0)-bit" }, selected: depths.firstIndex(of: s.audio.pcmBitDepth) ?? 1, enabled: on) { [weak self] i in
                self?.model.edit { $0.audio.pcmBitDepth = depths[i] }; self?.refresh(pane: false, preview: false)
            }]))
        }
        var norm: [Item] = [check("", on: s.audio.loudness != nil, enabled: on) { [weak self] v in
            self?.model.normalizeLoudness = v; self?.reload()
        }]
        if let ln = s.audio.loudness {
            norm.append(contentsOf: units(scrub(value: ln.targetLUFS, range: -40...(-5), step: 1, unit: "LUFS", decimals: 1,
                              defaultValue: model.presetSettings.audio.loudness?.targetLUFS, enabled: on) { [weak self] v in
                self?.model.edit { $0.audio.loudness?.targetLUFS = v.rounded() }
            }))
        }
        if s.audio.loudness != nil {
            let names = AudioDeliveryTarget.allCases.map(\.displayName)
            norm.append(popup(["Custom"] + names, selected: (model.deliveryTargetIndex ?? -1) + 1, enabled: on) { [weak self] i in
                if i > 0 { self?.model.edit { $0.audio.loudness = AudioDeliveryTarget.allCases[i - 1].normalization } }
                self?.reload()
            })
        }
        rows.append(row("Normalize", norm))
        if !model.loudnessRangeAvailable {
            rows.append(row("Loudness Range", [.fill(text(SQL10n.string("Needs a program of 60 s or more"), Theme.Colors.label3))]))
        }
        rows.append(contentsOf: audioCheckRows(enabled: on))
        rows.append(contentsOf: stemRows())
        rows.append(contentsOf: cutDownRows())
        return rows
    }

    /// Planned short versions (60/30/15/6 s) from the cut-down markers; one checkbox per range, one button.
    private func cutDownRows() -> [NSView] {
        let plans = model.cutDownPlans
        guard !plans.isEmpty else { return [] }
        var rows: [NSView] = []
        for plan in plans {
            let items: [Item] = plan.ranges.enumerated().map { i, r in
                let k = ExportDialogModel.CutDownKey(target: plan.targetSeconds, index: i)
                let title = "\(Int(r.start.exportSeconds.rounded()))\u{2013}\(Int(r.end.exportSeconds.rounded())) s"
                return check(title, on: model.isCutDownChecked(k)) { [weak self] v in
                    self?.model.setCutDownChecked(k, v); self?.reload()
                }
            }
            rows.append(row("\(plan.targetSeconds) s", items))
        }
        let button = SQButton(title: SQL10n.string("Export Cut-downs"), target: self, action: #selector(exportCutDownsTapped), style: .standard)
        button.isEnabled = model.checkedCutDownCount > 0 && model.outputDirectory != nil
        let hint = SQL10n.string(model.outputDirectory == nil ? "Choose a folder first" : "One file per checked range")
        rows.append(row("Cut-downs", [.fixed(button), .fill(text(hint, Theme.Colors.label3))]))
        return rows
    }

    @objc private func exportCutDownsTapped() { model.onExportCutDowns?() }

    /// Writes one audio file per role plus the Music and Effects mix next to the output file.
    private func stemRows() -> [NSView] {
        guard model.canExportStems else { return [] }
        let button = SQButton(title: SQL10n.string(model.isExportingStems ? "Exporting\u{2026}" : "Export Stems"),
                              target: self, action: #selector(exportStemsTapped), style: .standard)
        button.isEnabled = !model.isExportingStems && model.outputDirectory != nil && !model.activeStems.isEmpty
        let size = ByteCountFormatter.string(fromByteCount: model.stemEstimatedBytes, countStyle: .file)
        var hint = model.outputDirectory == nil ? SQL10n.string("Choose a folder first")
            : SQL10n.format("About %@ in %@ files", size, String(model.activeStems.count))
        if let s = model.stemStatus { hint = SQL10n.localized(s) }
        let plan = model.stemPlan
        let presets = model.stemPresets
        let checks: [Item] = plan.map { stem in
            check(stem.title, on: model.isStemChecked(stem.id)) { [weak self] on in
                self?.model.setStemChecked(stem.id, on); self?.reload()
            }
        }
        var rows: [NSView] = [row("Stem Roles", checks)]
        var presetItems: [Item] = [popup(["Preset"] + presets.map(\.name), selected: 0, tip: "Pick a saved choice of stems") { [weak self] i in
            guard let self, i > 0 else { return }
            self.model.applyStemPreset(presets[i - 1]); self.reload()
        }]
        if model.stemPresetStore != nil {
            let save = SQButton(title: SQL10n.string("Save Choice"), target: self, action: #selector(saveStemChoiceTapped), style: .standard)
            save.isEnabled = !model.activeStems.isEmpty
            presetItems.append(.fixed(save))
        }
        rows.append(row("Stem Presets", presetItems))
        rows.append(row("Stems", [.fixed(button), .fill(text(hint, Theme.Colors.label3))]))
        return rows
    }

    @objc private func saveStemChoiceTapped() { model.saveStemSelection(); reload() }

    @objc private func exportStemsTapped() {
        guard let dir = model.outputDirectory else { return }
        Task { [weak self] in
            guard let self else { return }
            let work = Task { await self.model.exportStems(to: dir) }
            self.reload()
            await work.value
            self.reload()
        }
    }

    /// The marker chapters as `M:SS Title` lines for a YouTube description, with the reasons YouTube would not show them.
    private func chapterRows() -> [NSView] {
        guard let c = model.chapters else { return [] }
        let button = SQButton(title: SQL10n.string("Copy Chapters"), target: self, action: #selector(copyChaptersTapped), style: .standard)
        let hint = c.warnings.isEmpty ? SQL10n.string("Paste into the video description") : SQL10n.localized(c.warnings[0])
        var rows: [NSView] = [row("Chapters", [.fixed(button),
                                               .fill(text(hint, c.warnings.isEmpty ? Theme.Colors.label3 : Theme.Colors.warning))])]
        for w in c.warnings.dropFirst() { rows.append(row("Warning", [.fill(text(SQL10n.localized(w), Theme.Colors.warning))])) }
        return rows
    }

    @objc private func copyChaptersTapped() {
        guard let c = model.chapters else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.text, forType: .string)
    }

    @objc private func audioCheckTapped() {
        model.runAudioCheck()
        reload()
        // The result arrives later: refresh once the model has it.
        Task { [weak self] in
            while let self, self.model.isCheckingAudio { try? await Task.sleep(nanoseconds: 200_000_000) }
            self?.reload()
        }
    }

    /// Opt-in check of the mix against the delivery target: it reads the whole sequence once, so it runs on request.
    private func audioCheckRows(enabled: Bool) -> [NSView] {
        let button = SQButton(title: SQL10n.string(model.isCheckingAudio ? "Checking\u{2026}" : (model.hasAudioCheck ? "Check Again" : "Check Audio")),
                              target: self, action: #selector(audioCheckTapped), style: .standard)
        button.isEnabled = enabled && !model.isCheckingAudio
        var hint = SQL10n.string("Loudness, true peak, clipping, gaps, dual mono, sync")
        if let e = model.audioCheckError { hint = SQL10n.localized(e) }
        var rows: [NSView] = [row("Audio Check", [.fixed(button), .fill(text(hint, Theme.Colors.label3))])]
        for f in model.audioFindings {
            let color: NSColor
            switch f.severity {
            case .pass: color = Theme.Colors.green
            case .warning: color = Theme.Colors.warning
            case .fail: color = Theme.Colors.red
            }
            let mark = f.severity == .pass ? "Pass" : (f.severity == .warning ? "Warning" : "Fail")
            let message = SQL10n.localized(f.message)
            let t = text(message, color)
            t.toolTip = message
            rows.append(row(mark, [.fill(t)]))
        }
        return rows
    }

    // MARK: Captions and range

    private func captionRows() -> [NSView] {
        let modes: [CaptionMode] = [.none, .burnIn, .sidecarSRT, .sidecarVTT, .sidecarITT]
        let noPicture = model.settings.audioOnly != nil
        return [row("Captions", [segmented(["None", "Burn in", "SRT file", "VTT file", "iTT file"], selected: modes.firstIndex(of: model.captions) ?? 0,
                                           disabled: noPicture ? [1] : [], width: 78) { [weak self] i in
            self?.model.captions = modes[i]; self?.reload()
        }])]
    }

    private func coverRows() -> [NSView] {
        let formats: [CoverImageFormat] = [.png, .jpg]
        var items: [Item] = [check("Also save cover image", on: model.coverImage != nil) { [weak self] on in
            self?.model.coverImage = on ? .png : nil; self?.reload()
        }]
        guard let f = model.coverImage else { return [row("Cover", items)] }
        items.append(segmented(["PNG", "JPG"], selected: formats.firstIndex(of: f) ?? 0, width: 44) { [weak self] i in
            self?.model.coverImage = formats[i]; self?.reload()
        })
        return [row("Cover", items), row("Cover Frame", [.fixed(text(model.coverFrameText, Theme.Colors.label3), 300)])]
    }

    private func rangeRows() -> [NSView] {
        let fd = model.settings.video.frameDuration
        var rows: [NSView] = [row("Range", [segmented(["Entire", "In to Out", "Custom", "Selected"], selected: model.rangeMode,
                                                 disabled: Set((model.canUseInOut ? [] : [1]) + (model.canUseSelection ? [] : [3])), width: 70) { [weak self] i in
            self?.model.rangeMode = i; self?.reload()
        }])]
        if model.rangeMode == 2 {
            let r = model.rangeSeconds
            let total = model.sequences.first(where: { $0.id == model.selectedID })?.duration.exportSeconds ?? 0
            rows.append(row("Start", units(scrub(value: r.start, range: 0...max(total, 0.1), step: 0.5, unit: "s", decimals: 2,
                                                 defaultValue: 0) { [weak self] v in
                self?.model.setCustomRange(startSeconds: v); self?.reload()
            })))
            rows.append(row("End", units(scrub(value: r.end, range: 0...max(total, 0.1), step: 0.5, unit: "s", decimals: 2,
                                               defaultValue: total) { [weak self] v in
                self?.model.setCustomRange(endSeconds: v); self?.reload()
            })))
        }
        if model.rangeMode == 3, model.selectedClipCount > 1 {
            rows.append(row("Files", [check("One file per clip", on: model.oneFilePerClip) { [weak self] on in
                self?.model.oneFilePerClip = on; self?.reload()
            }]))
        }
        rows.append(row("Duration", [.fixed(text(ExportDecodeError.timecode(model.effectiveDuration(of: model.selectedID, settings: model.settings), frameDuration: fd)), 200)]))
        if model.settings.audioOnly == nil, model.settings.frameOutput == nil { rows.append(contentsOf: coverRows()) }
        if let r = model.sequences.first(where: { $0.id == model.selectedID })?.inOut {
            rows.append(row("In / Out", [.fixed(text(ExportDecodeError.timecode(r.start, frameDuration: fd) + " \u{2013} " + ExportDecodeError.timecode(r.end, frameDuration: fd)), 260)]))
        }
        return rows
    }

    // MARK: Advanced (everything the board's four sections do not list; closed by default)

    private func advancedRows() -> [NSView] {
        let s = model.settings
        let d = model.presetSettings
        let mastering = s.video.codec.isMastering
        var rows: [NSView] = []
        if s.frameOutput != nil { return rows }
        if s.audioOnly != nil {
            let ch = s.audio.channels == 1 ? 0 : 1
            rows.append(row("Channels", [popup(["Mono", "Stereo"], selected: ch) { [weak self] i in
                self?.model.edit { $0.audio.channels = i == 0 ? 1 : 2 }; self?.refresh(pane: false, preview: false)
            }]))
            if let ln = s.audio.loudness {
                rows.append(row("True Peak Max", units(scrub(value: ln.truePeakCeilingDB, range: -9...0, step: 0.5, unit: "dBTP", decimals: 1,
                                                        defaultValue: d.audio.loudness?.truePeakCeilingDB) { [weak self] v in
                    self?.model.edit { $0.audio.loudness?.truePeakCeilingDB = v }
                })))
            }
            return rows
        }
        rows.append(row("Keyframe Every", units(scrub(value: Double(s.video.keyframeInterval), range: 1...600, step: 1, unit: "frames",
                                                 defaultValue: Double(d.video.keyframeInterval), enabled: !mastering) { [weak self] v in
            self?.model.edit { $0.video.keyframeInterval = Int(v) }
        })))
        rows.append(row("B-Frames", [check("Allow frame reordering", on: s.video.allowsFrameReordering, enabled: !mastering) { [weak self] on in
            self?.model.edit { $0.video.allowsFrameReordering = on }; self?.refresh(pane: false, preview: false)
        }]))
        rows.append(row("Alpha", [check("Keep transparency (ProRes 4444)", on: s.video.preservesAlpha, enabled: s.video.codec == .prores4444) { [weak self] on in
            self?.model.edit { $0.video.preservesAlpha = on }; self?.reload()
        }]))
        rows.append(row("Bit Depth", [.fixed(text("\(s.video.bitDepth)-bit"), 120)]))
        let ch = s.audio.channels == 1 ? 0 : 1
        rows.append(row("Channels", [popup(["Mono", "Stereo"], selected: ch, enabled: s.audio.enabled) { [weak self] i in
            self?.model.edit { $0.audio.channels = i == 0 ? 1 : 2 }; self?.refresh(pane: false, preview: false)
        }]))
        if let ln = s.audio.loudness {
            rows.append(row("True Peak Max", units(scrub(value: ln.truePeakCeilingDB, range: -9...0, step: 0.5, unit: "dBTP", decimals: 1,
                                                    defaultValue: d.audio.loudness?.truePeakCeilingDB, enabled: s.audio.enabled) { [weak self] v in
                self?.model.edit { $0.audio.loudness?.truePeakCeilingDB = v }
            })))
        }
        rows.append(row("Damaged Frames", [check("Continue on damaged frames", on: model.continueOnDamagedFrames) { [weak self] on in
            self?.model.continueOnDamagedFrames = on; self?.refresh(pane: false, preview: false)
        }]))
        rows.append(row("HDR to SDR", [check("Adjust the conversion of HDR clips", on: s.hdrToSDR != nil) { [weak self] on in
            self?.model.edit { $0.hdrToSDR = on ? HDRToSDR() : nil }; self?.reload()
        }]))
        if let h = s.hdrToSDR {
            rows.append(row("HDR Exposure", units(scrub(value: h.exposureStops, range: -4...4, step: 0.1, unit: "stops", decimals: 1,
                                                   defaultValue: 0) { [weak self] v in
                self?.model.edit { $0.hdrToSDR?.exposureStops = v }
            })))
            rows.append(row("HDR Gamut", [check("Compress colors outside Rec.709", on: h.compressesGamut) { [weak self] on in
                self?.model.edit { $0.hdrToSDR?.compressesGamut = on }; self?.refresh(pane: false, preview: false)
            }]))
        }
        return rows
    }

    /// Color Space: Rec. 709 tagged 1-1-1, or for HEVC an HLG / PQ delivery with the mastering peak (MDCV / CLLI metadata).
    private func colorSpaceRows(_ s: ExportSettings) -> [NSView] {
        guard s.video.codec == .hevc else { return [row("Color Space", [.fixed(text("Rec. 709 (tagged 1-1-1)"), 200)])] }
        let titles = ["Rec. 709 (SDR)"] + HDRDelivery.Transfer.allCases.map { "Rec. 2020 \($0.title)" }
        let sel = s.hdrDelivery.flatMap { h in HDRDelivery.Transfer.allCases.firstIndex(of: h.transfer) }.map { $0 + 1 } ?? 0
        var rows: [NSView] = [row("Color Space", [popup(titles, selected: sel,
                                                        tip: "HDR delivery tags the file Rec. 2020 with HEVC Main 10 and mastering metadata") { [weak self] i in
            let peak = s.hdrDelivery?.peakNits ?? 1000
            self?.model.edit { $0.hdrDelivery = i == 0 ? nil : HDRDelivery(transfer: HDRDelivery.Transfer.allCases[i - 1], peakNits: peak) }
            self?.reload()
        }])]
        if let h = s.hdrDelivery {
            rows.append(row("Peak Brightness", units(scrub(value: h.peakNits, range: 100...10_000, step: 50, unit: "nits", decimals: 0,
                                                      defaultValue: 1000) { [weak self] v in
                self?.model.edit { $0.hdrDelivery = HDRDelivery(transfer: h.transfer, peakNits: v) }
            })))
        }
        return rows
    }

    // MARK: Helpers

    static func durationText(_ t: Time) -> String {
        let total = max(0, Int((Double(t.value) / Double(t.timescale)).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func fpsText(_ fps: Double) -> String {
        (fps == fps.rounded() ? "\(Int(fps))" : String(format: "%g", fps)) + " fps"
    }
}

/// One delivery check chip of the Export sheet: a capsule with a short line, warning tint or neutral.
@MainActor
final class DeliveryChipView: NSView {
    private let warning: Bool
    init(text: String, warning: Bool) {
        self.warning = warning
        let label = NSTextField(labelWithString: text)
        label.font = Theme.Typography.caption
        label.textColor = warning ? Theme.Colors.warning : Theme.Colors.label2
        label.sizeToFit()
        let h = Theme.Metrics.capsule
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(label.frame.width) + Theme.Spacing.md * 2, height: h))
        label.frame.origin = CGPoint(x: Theme.Spacing.md, y: ((h - label.frame.height) / 2).rounded())
        addSubview(label)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.capsule(forHeight: h)
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (warning ? Theme.Colors.warning.withAlphaComponent(0.14) : Theme.State.controlRest).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
