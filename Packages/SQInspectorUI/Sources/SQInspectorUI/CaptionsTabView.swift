import AppKit
import Observation
import SQCore
import SQUIKit
import SQText
import SQTranscribe

/// Captions tab of the Captions panel (Premiere's Captions tab): the captions of the sequence as an editable list
/// (double-click a caption to type), search and replace, Create Captions with Premiere's options, add a caption at the
/// playhead and SRT export. Split, merge, delete and a per-caption style are in the row context menu; designing the
/// captions is the Style tab. The transcript is the sequence's (Transcribe tab).
@MainActor
public final class CaptionsTabView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    public struct Row: Equatable, Sendable {
        public var id: UUID
        public var start: Time
        public var text: String
    }

    /// Transcript model of the active sequence; nil without a sequence.
    public var model: CaptionsPanelModel? { didSet { observe(); refresh() } }
    public weak var session: EditorSession?
    public var onSeek: ((Time) -> Void)?
    public var onStatus: ((String) -> Void)?
    /// "Export SRT…": the host asks for a file and writes it.
    public var onExportSRT: (() -> Void)?
    /// "Import SRT…": the host asks for a file and imports it.
    public var onImportSRT: (() -> Void)?
    public var timecode = Timecode(frameDuration: Time(1001, 30000), dropFrame: true)

    public private(set) var rows: [Row] = []

    private let table = SQMenuTableView()
    private let scroll = NSScrollView()
    private let findField = SQSearchField()
    private let replaceField = SQTextField(frame: .zero)
    private let matchCase = SQCheckbox(title: "Match Case", target: nil, action: nil)
    private let replaceButton = SQButton(title: "Replace All", target: nil, action: nil)
    private let createButton = SQButton(title: "Create Captions…", target: nil, action: nil)
    /// Footer count ("14 captions", or the match count while searching).
    private let hint = NSTextField(labelWithString: "")
    private let emptyState = EmptyStateView(title: "No captions yet", hint: "Transcribe the sequence first, then create captions from the transcript.")
    private let footerLine = NSView()
    private var observed: CaptionsPanelModel?
    private var generation = 0
    private var syncingSelection = false
    /// A caption text field is being typed into: the typing is one undo step and the list is not reloaded under it.
    private var typing = false
    /// Languages the system can translate into (loaded once, for the row menu).
    private var translationTargets: [(code: String, name: String)] = []
    private var translationTargetsLoaded = false

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        let col = NSTableColumn(identifier: .init("caption"))
        table.addTableColumn(col)
        table.headerView = nil
        QuietList.style(table, rowHeight: Theme.Row.list)
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Captions")
        table.sqItems = { [weak self] _ in self?.contextItems() ?? [] }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        findField.placeholderString = "Find"
        findField.delegate = self
        // Return = next match, Shift+Return = previous (no arrow buttons); the action fires on Return only.
        findField.sendsWholeSearchString = true
        findField.sendsSearchStringImmediately = false
        findField.target = self; findField.action = #selector(findNext)
        replaceField.placeholderString = "Replace With"
        replaceField.controlSize = .small; replaceField.font = Theme.Typography.body
        replaceField.delegate = self
        matchCase.target = self; matchCase.action = #selector(findChanged)
        for b in [replaceButton, createButton] {
            b.target = self
        }
        replaceButton.action = #selector(replaceAll)
        Task { @MainActor in await CaptionLookLibrary.shared.reload() }
        createButton.action = #selector(createClicked)
        createButton.keyEquivalent = "\r"
        hint.font = Theme.Typography.body
        hint.textColor = Theme.Colors.label3
        createButton.style = .accent
        footerLine.wantsLayer = true
        footerLine.layer?.backgroundColor = Theme.Colors.separator.cgColor
        for v in [scroll, emptyState, findField, replaceField, matchCase, replaceButton, footerLine, createButton, hint] { addSubview(v) }
        refresh()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    // MARK: Data

    /// All captions of the timeline's caption tracks in time order.
    public static func rows(of timeline: Timeline?) -> [Row] {
        (timeline?.captionTracks.flatMap(\.items) ?? [])
            .sorted { $0.range.start < $1.range.start }
            .map { Row(id: $0.id, start: $0.range.start, text: $0.lines.joined(separator: " ")) }
    }

    public func setTimeline(_ t: Timeline?) {
        let new = Self.rows(of: t)
        if new != rows {
            let sameShape = new.map(\.id) == rows.map(\.id)
            rows = new
            if !(typing && sameShape) { table.reloadData() }   // typing only changed the text under the caret
        }
        refresh()
    }

    public func setCaptionSelection(_ ids: Set<CaptionItem.ID>) {
        let idx = IndexSet(rows.indices.filter { ids.contains(rows[$0].id) })
        guard idx != table.selectedRowIndexes else { return }
        syncingSelection = true
        table.selectRowIndexes(idx, byExtendingSelection: false)
        if let first = idx.first { table.scrollRowToVisible(first) }
        syncingSelection = false
    }

    /// Starts typing into the caption's row (double-click on the timeline, Return on a selected row).
    public func beginEditing(_ id: CaptionItem.ID) {
        guard let r = rows.firstIndex(where: { $0.id == id }) else { return }
        table.scrollRowToVisible(r)
        table.selectRowIndexes([r], byExtendingSelection: false)
        guard let cell = table.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTableCellView else { return }
        for case let f as NSTextField in (cell.subviews.first as? NSStackView)?.arrangedSubviews ?? [] where f.isEditable {
            window?.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
    }

    // MARK: Observation

    private func observe() {
        generation += 1
        observed = model
        track(generation)
    }

    private func track(_ gen: Int) {
        guard gen == generation, let m = observed else { return }
        withObservationTracking {
            _ = m.state; _ = m.presets; _ = m.selectedPresetIndex; _ = m.transcript
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == generation else { return }
                refresh()
                track(gen)
            }
        }
    }

    private func refresh() {
        loadTranslationTargets()
        replaceButton.isEnabled = !findField.stringValue.isEmpty && !rows.isEmpty
        createButton.isEnabled = model?.canCreateCaptions ?? false
        if !findField.stringValue.isEmpty {
            let n = session?.activeTimeline?.captionMatches(find: findField.stringValue, caseSensitive: matchCase.state == .on).count ?? 0
            hint.stringValue = n == 0 ? SQL10n.string("No match") : SQL10n.format("%@ of %@ match", String(n), String(rows.count))
        } else {
            let tracks = session?.activeTimeline?.captionTracks.count ?? 0
            hint.stringValue = SQL10n.plural(rows.count, one: "%@ caption", other: "%@ captions") + (tracks > 1 ? SQL10n.format(" on %@ tracks", String(tracks)) : "")
        }
        createButton.sqToolTip = model == nil ? "Open a sequence first" : (model?.canCreateCaptions == true ? nil : "Transcribe the sequence first")
        emptyState.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        needsLayout = true
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let pad = Theme.Spacing.sm
        let w = bounds.width
        let inner = max(w - 2 * pad, 0)
        let fieldH = Theme.Metrics.quietField
        let gap: CGFloat = 6
        let footerH: CGFloat = 38
        // Board: Find, then "Replace With" + Replace All, then Match Case; 12 px inset, 6 px between rows, 8 below.
        findField.frame = CGRect(x: pad, y: 0, width: inner, height: fieldH)
        let rowY = findField.frame.maxY + gap
        replaceButton.sizeToFit()
        let rb = replaceButton.frame.width
        replaceField.frame = CGRect(x: pad, y: rowY, width: max(inner - rb - 8, 40), height: fieldH)
        replaceButton.frame = CGRect(x: w - pad - rb, y: rowY + ((fieldH - Theme.Metrics.quietButton) / 2).rounded(),
                                     width: rb, height: Theme.Metrics.quietButton)
        matchCase.sizeToFit()
        matchCase.frame.origin = CGPoint(x: pad, y: replaceField.frame.maxY + gap)
        let top = matchCase.frame.maxY + 8
        let listH = max(bounds.height - footerH - top, 0)
        scroll.frame = CGRect(x: 0, y: top, width: w, height: listH)
        emptyState.frame = scroll.frame
        footerLine.frame = CGRect(x: 0, y: bounds.height - footerH, width: w, height: 1)
        createButton.sizeToFit()
        let cy = bounds.height - footerH + ((footerH - Theme.Metrics.quietButton) / 2).rounded()
        createButton.frame = CGRect(x: w - pad - createButton.frame.width, y: cy, width: createButton.frame.width, height: Theme.Metrics.quietButton)
        hint.sizeToFit()
        hint.frame = CGRect(x: pad, y: bounds.height - footerH + ((footerH - hint.frame.height) / 2).rounded(),
                            width: max(createButton.frame.minX - 2 * pad, 0), height: hint.frame.height)
    }

    // MARK: Actions

    private var selectedIDs: [CaptionItem.ID] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil } }

    @objc private func findChanged() { refresh() }

    /// Return in the Find field (and the down arrow): jump to the next caption that matches; Shift+Return goes back.
    @objc private func findNext() {
        let back = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        stepFind(forward: !back)
    }

    /// From the selected caption (when one is selected) or else the playhead, so Return walks the list.
    private func stepFind(forward: Bool) {
        guard let s = session, let tl = s.activeTimeline else { return }
        let items = s.captionItems
        let sel = selectedIDs
        let anchor = sel.count == 1 ? (items.first { $0.id == sel[0] }?.range.start ?? s.playhead) : s.playhead
        guard let next = tl.captionMatch(find: findField.stringValue, caseSensitive: matchCase.state == .on, from: anchor, forward: forward) else { return }
        s.select(clips: [], captions: [next])
        if let it = items.first(where: { $0.id == next }) { onSeek?(it.range.start) }
    }

    @objc private func replaceAll() {
        guard let s = session, !findField.stringValue.isEmpty else { return }
        if findField.stringValue == replaceField.stringValue { onStatus?(SQL10n.string("Find and Replace are the same: nothing to change.")); return }
        let skipped = s.activeTimeline?.captionTracks.contains(where: \.isLocked) == true ? SQL10n.string(" Locked caption tracks were skipped.") : ""
        if let n = s.replaceCaptionText(find: findField.stringValue, with: replaceField.stringValue, caseSensitive: matchCase.state == .on) {
            onStatus?(n == 0 ? SQL10n.string("No match.") + skipped : SQL10n.plural(n, one: "Replaced %@ time.", other: "Replaced %@ times.") + skipped)
        }
    }

    @objc private func addClicked() {
        if let id = session?.addCaptionAtPlayhead() { DispatchQueue.main.async { [weak self] in self?.beginEditing(id) } }
    }

    @objc private func exportClicked() { onExportSRT?() }
    @objc private func importClicked() { onImportSRT?() }

    @objc private func createClicked() { presentCreateCaptions() }

    /// Also reached from the Transcribe tab's Create Captions button.
    func presentCreateCaptions() {
        guard let m = model, let window = window ?? NSApp.keyWindow else { return }
        // The default look decides style, animation and segmentation of the new captions.
        NamedLookPreset.install(into: m, library: .shared, kit: session?.project.styleKit)
        CreateCaptionsDialog.present(on: window, model: m) { [weak m] ok in if ok { m?.createCaptions() } }
    }

    // MARK: Context menu on rows

    /// Rows of the right-click menu (`SQMenuTableView` has already selected the clicked row).
    func contextItems() -> [SQMenuItem] {
        let n = table.selectedRowIndexes.count
        let atPlayhead = session.flatMap { s in s.activeTimeline?.captions(at: s.playhead).isEmpty == false } ?? false
        // Edit first, then the object's own commands, destructive last (INTERACTION-AUDIT section 5).
        let looks = CaptionPresetLibrary.builtIn.styleIDs.map { id in
            SQMenuItem(title: TextInspectorView.title(for: id), isEnabled: n >= 1) { [weak self] in self?.session?.setSelectedCaptionStyle(id) }
        }
        let translations = translationTargets.map { (code, name) in
            SQMenuItem(title: name) { [weak self] in self?.translate(to: code) }
        }
        return [
            SQMenuItem(title: "Edit in Text", isEnabled: n == 1) { [weak self] in self?.editSelected() },
            SQMenuItem(title: "Split Caption at Playhead", isEnabled: atPlayhead) { [weak self] in self?.splitAtPlayhead() },
            SQMenuItem(title: "Merge Captions", isEnabled: n >= 2) { [weak self] in self?.mergeSelected() },
            .separator,
            SQMenuItem(title: "Look", isEnabled: n >= 1, submenu: looks),
            SQMenuItem(title: "Reset to Track Look", isEnabled: n >= 1 && (session?.selectedCaptionsHaveOverrides ?? false)) { [weak self] in self?.useTrackStyle() },
            .separator,
            SQMenuItem(title: "Tidy for Short Video", isEnabled: !rows.isEmpty) { [weak self] in self?.tidyClicked() },
            SQMenuItem(title: "Translate Captions", isEnabled: !rows.isEmpty && !translationTargets.isEmpty, submenu: translations),
            .separator,
            SQMenuItem(title: "Add Caption at Playhead", isEnabled: session?.activeTimeline != nil) { [weak self] in self?.addClicked() },
            SQMenuItem(title: "New Caption Track", isEnabled: session?.activeTimeline != nil) { [weak self] in self?.newTrackClicked() },
            SQMenuItem(title: "Import Subtitles\u{2026}", isEnabled: session != nil) { [weak self] in self?.importClicked() },
            SQMenuItem(title: "Export SRT\u{2026}", isEnabled: !rows.isEmpty) { [weak self] in self?.exportClicked() },
            .separator,
            // Shows the Delete key; the panel handles the key itself.
            SQMenuItem(title: "Delete", shortcut: "\u{232B}", isEnabled: n >= 1) { [weak self] in self?.deleteSelected() },
        ]
    }

    /// One click: short chunks along the word timings, no overlaps, tidy gaps (the fast-captions pass).
    @objc private func tidyClicked() {
        guard let s = session else { return }
        if let n = s.tidyCaptions() { onStatus?(SQL10n.plural(n, one: "Tidied: %@ caption.", other: "Tidied: %@ captions.")) }
    }

    /// Translates the current caption track on device into a new track with the same timings.
    private func translate(to code: String) {
        guard let s = session else { return }
        onStatus?(SQL10n.string("Translating…"))
        Task { @MainActor [weak self] in
            let made = await s.translateCaptions(to: code)
            if let made, let name = s.activeTimeline?.captionTrack(made)?.name { self?.onStatus?(SQL10n.format("Added %@.", name)) }
            else if let e = s.lastError { self?.onStatus?(e) }
        }
    }

    private func loadTranslationTargets() {
        guard !translationTargetsLoaded else { return }
        translationTargetsLoaded = true
        Task { @MainActor [weak self] in self?.translationTargets = await CaptionTranslator.supportedTargets() }
    }

    @objc private func useTrackStyle() { session?.resetSelectedCaptionsToTrackLook() }
    @objc private func newTrackClicked() {
        if let id = session?.addCaptionTrack(), let name = session?.activeTimeline?.captionTrack(id)?.name { onStatus?(SQL10n.format("Added %@.", name)) }
    }
    @objc private func editSelected() { if let id = selectedIDs.first { beginEditing(id) } }
    @objc private func splitAtPlayhead() { session?.splitCaption() }
    @objc private func mergeSelected() { session?.mergeSelectedCaptions() }
    @objc private func deleteSelected() { session?.deleteSelectedCaptions() }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let s = session else { return }
        let ids = Set(selectedIDs)
        s.select(clips: [], captions: ids)
        if let first = table.selectedRowIndexes.first, rows.indices.contains(first), table.selectedRowIndexes.count == 1 {
            onSeek?(rows[first].start)
        }
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatSelectionRowView() }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
        let time = NSTextField(labelWithString: timecode.format(r.start))
        time.font = Theme.Typography.caption; time.textColor = Theme.Colors.label3
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.widthAnchor.constraint(equalToConstant: 84 - Theme.Spacing.sm).isActive = true   // board: 84 px time column
        let text = NSTextField(string: r.text)
        text.font = Theme.Typography.body; text.textColor = Theme.Colors.label
        text.isBordered = false; text.drawsBackground = false; text.focusRingType = .none
        text.isEditable = true; text.lineBreakMode = .byTruncatingTail
        text.placeholderString = "Empty caption"
        text.tag = row
        text.delegate = self
        text.setAccessibilityLabel("Caption text")
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [time, text])
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = Theme.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.sm),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.Spacing.sm),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Text fields

    public func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === findField || f === replaceField { if f === findField { refresh() }; return }
        guard rows.indices.contains(f.tag), let s = session else { return }
        let continuing = typing
        typing = true
        rows[f.tag].text = f.stringValue                    // keep the model rows equal to what the session will publish
        s.setCaptionText(rows[f.tag].id, f.stringValue, continuesGesture: continuing)
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, f !== findField, f !== replaceField else { return }
        typing = false
    }
}

/// Premiere's Create Captions dialog: style preset, maximum characters per line, single or double line, minimum
/// duration and the gap between captions.
@MainActor
enum CreateCaptionsDialog {
    static func present(on window: NSWindow, model: CaptionsPanelModel, completion: @escaping @MainActor (Bool) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Create Captions"
        alert.informativeText = "Captions are made from the transcript of the whole sequence."

        let preset = SQPopup(frame: .zero, pullsDown: false)
        preset.addItems(withTitles: model.presets.map(\.name))
        preset.selectItem(at: min(model.selectedPresetIndex, max(model.presets.count - 1, 0)))
        let chars = SQDialog.makeNumberField(range: 8...100, step: 1, width: nil)
        let lines = SQSegmented(labels: ["One", "Two"], segmentWidth: 0)
        let minDur = SQDialog.makeNumberField(range: 0...60, step: 0.05, decimals: 2, unit: "s", width: nil)
        let gap = SQDialog.makeNumberField(range: 0...120, step: 1, unit: "frames", width: nil)
        for f in [chars, minDur, gap] { f.leadingText = true }
        func fill() {
            guard model.presets.indices.contains(preset.indexOfSelectedItem) else { return }
            let p = model.presets[preset.indexOfSelectedItem].preset
            chars.value = Double(min(max(p.maxCharsPerLine, 8), 100)); chars.defaultValue = chars.value
            lines.selectedSegment = p.maxLines <= 1 ? 0 : 1
            minDur.value = (Double(p.minDuration.value) / Double(p.minDuration.timescale) * 100).rounded() / 100
            minDur.defaultValue = minDur.value
            let fd = Double(model.frameDuration.value) / Double(model.frameDuration.timescale)
            gap.value = fd > 0 ? Double(Int((Double(p.gap.value) / Double(p.gap.timescale) / fd).rounded())) : 0
            gap.defaultValue = gap.value
        }
        fill()
        final class Target: NSObject { var fill: (() -> Void)?; @objc func go() { fill?() } }
        let target = Target(); target.fill = fill
        preset.target = target; preset.action = #selector(Target.go)

        alert.width = SQModal.Size.s.width
        alert.accessoryView = SQDialogForm(rows: [
            SQDialog.formRow("Style", preset),
            SQDialog.formRow("Characters", chars),
            SQDialog.formRow("Lines", [lines, NSView()]),
            SQDialog.formRow("Min. Duration", minDur),
            SQDialog.formRow("Caption Gap", gap),
        ])
        alert.addButton("Create")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(target) {}
                guard response == .first else { completion(false); return }
                model.selectedPresetIndex = preset.indexOfSelectedItem
                let secs = max(0, minDur.value)
                model.setOptions(maxCharsPerLine: Int(chars.value.rounded()), lines: lines.selectedSegment + 1,
                                 minDuration: CaptionsPanelModel.minDuration(seconds: secs), gapFrames: Int(gap.value.rounded()))
                completion(true)
            }
        }
    }
}
