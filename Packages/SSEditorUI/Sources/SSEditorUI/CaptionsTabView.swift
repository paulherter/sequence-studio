import AppKit
import Observation
import SSCore
import SSText
import SSTranscribe

/// Captions tab of the Text panel (Premiere's Captions tab): the captions of the sequence as an editable list
/// (double-click a caption to type), search and replace, one style for all captions, Create Captions with Premiere's
/// options, add a caption at the playhead and SRT export. Split, merge and delete are in the row context menu.
/// The transcript comes from the model of the selected clip (Transcript tab).
@MainActor
public final class CaptionsTabView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    public struct Row: Equatable, Sendable {
        public var id: UUID
        public var start: Time
        public var text: String
    }

    /// Model of the selected clip; nil when no clip is selected.
    public var model: CaptionsPanelModel? { didSet { observe(); refresh() } }
    public weak var session: EditorSession?
    public var onSeek: ((Time) -> Void)?
    public var onStatus: ((String) -> Void)?
    /// "Export SRT…": the host asks for a file and writes it.
    public var onExportSRT: (() -> Void)?
    public var timecode = Timecode(frameDuration: Time(1001, 30000), dropFrame: true)

    public private(set) var rows: [Row] = []

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let matchCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let styleLabel = NSTextField(labelWithString: "Style")
    private let stylePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export SRT…", target: nil, action: nil)
    private let createButton = NSButton(title: "Create Captions…", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var observed: CaptionsPanelModel?
    private var generation = 0
    private var syncingSelection = false
    /// A caption text field is being typed into: the typing is one undo step and the list is not reloaded under it.
    private var typing = false
    private var styleIDs: [String] = []

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        let col = NSTableColumn(identifier: .init("caption"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 36
        table.style = .sourceList
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Captions")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        findField.placeholderString = "Find"
        findField.controlSize = .small; findField.font = Theme.Fonts.small
        findField.delegate = self
        findField.target = self; findField.action = #selector(findNext)
        replaceField.placeholderString = "Replace with"
        replaceField.controlSize = .small; replaceField.font = Theme.Fonts.small
        replaceField.delegate = self
        matchCase.controlSize = .small; matchCase.font = Theme.Fonts.small
        matchCase.target = self; matchCase.action = #selector(findChanged)
        for b in [replaceButton, exportButton, createButton] {
            b.bezelStyle = .rounded; b.controlSize = .small; b.font = Theme.Fonts.small; b.target = self
        }
        replaceButton.action = #selector(replaceAll)
        exportButton.action = #selector(exportClicked)
        createButton.action = #selector(createClicked)
        createButton.keyEquivalent = "\r"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Caption")
        addButton.bezelStyle = .rounded; addButton.controlSize = .small
        addButton.toolTip = "Add a caption at the playhead"
        addButton.target = self; addButton.action = #selector(addClicked)
        styleLabel.font = Theme.Fonts.small; styleLabel.textColor = Theme.Colors.label2
        stylePopUp.controlSize = .small; stylePopUp.font = Theme.Fonts.small
        stylePopUp.target = self; stylePopUp.action = #selector(styleChanged)
        stylePopUp.toolTip = "Applies to all captions"
        hint.font = Theme.Fonts.small
        hint.textColor = Theme.Colors.label3
        for v in [scroll, findField, replaceField, matchCase, replaceButton, styleLabel, stylePopUp, addButton, exportButton,
                  createButton, hint] { addSubview(v) }
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
        styleIDs = CaptionPresetLibrary.builtIn.styleIDs
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
        stylePopUp.removeAllItems()
        let ids = styleIDs.isEmpty ? CaptionPresetLibrary.builtIn.styleIDs : styleIDs
        stylePopUp.addItems(withTitles: ids.map(TextInspectorView.title(for:)))
        for (i, id) in ids.enumerated() { stylePopUp.item(at: i)?.representedObject = id }
        let used = Set(session?.captionItems.map(\.styleRef) ?? [])
        if used.count == 1, let one = used.first, let i = ids.firstIndex(of: one) { stylePopUp.selectItem(at: i) }
        else { stylePopUp.addItem(withTitle: used.isEmpty ? "None" : "Mixed"); stylePopUp.selectItem(at: stylePopUp.numberOfItems - 1) }
        stylePopUp.isEnabled = !rows.isEmpty
        replaceButton.isEnabled = !findField.stringValue.isEmpty && !rows.isEmpty
        exportButton.isEnabled = !rows.isEmpty
        addButton.isEnabled = session != nil
        createButton.isEnabled = model?.canCreateCaptions ?? false
        if !findField.stringValue.isEmpty {
            let n = session?.activeTimeline?.captionMatches(find: findField.stringValue, caseSensitive: matchCase.state == .on).count ?? 0
            hint.stringValue = n == 0 ? "No match." : "\(n) caption\(n == 1 ? "" : "s") match."
        } else if model?.canCreateCaptions == true {
            hint.stringValue = rows.isEmpty ? "No captions yet." : "\(rows.count) captions. Creating adds captions for this clip."
        } else {
            hint.stringValue = model == nil ? "Select a clip, then transcribe it in the Transcript tab."
                                            : "Transcribe the clip in the Transcript tab first."
        }
        needsLayout = true
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let pad = Theme.Spacing.sm
        let w = bounds.width
        let inner = max(w - 2 * pad, 0)
        let fieldH: CGFloat = 22
        findField.frame = CGRect(x: pad, y: pad, width: inner, height: fieldH)
        replaceButton.sizeToFit()
        let rb = replaceButton.frame.width
        replaceField.frame = CGRect(x: pad, y: pad + fieldH + 4, width: max(inner - rb - pad, 40), height: fieldH)
        replaceButton.frame = CGRect(x: w - pad - rb, y: pad + fieldH + 4, width: rb, height: fieldH)
        matchCase.sizeToFit()
        matchCase.frame.origin = CGPoint(x: pad, y: pad + 2 * (fieldH + 4))
        let top = matchCase.frame.maxY + 4
        let footer: CGFloat = 96
        scroll.frame = CGRect(x: 0, y: top, width: w, height: max(bounds.height - footer - top, 0))
        let y = scroll.frame.maxY + pad
        hint.frame = CGRect(x: pad, y: y, width: inner, height: 28)
        styleLabel.sizeToFit()
        let ly = y + 32
        styleLabel.frame.origin = CGPoint(x: pad, y: ly + 3)
        stylePopUp.frame = CGRect(x: styleLabel.frame.maxX + pad, y: ly, width: max(inner - styleLabel.frame.width - pad, 40), height: 20)
        createButton.sizeToFit(); exportButton.sizeToFit()
        let by = ly + 26
        createButton.frame = CGRect(x: w - pad - createButton.frame.width, y: by, width: createButton.frame.width, height: 22)
        exportButton.frame = CGRect(x: createButton.frame.minX - pad - exportButton.frame.width, y: by,
                                    width: exportButton.frame.width, height: 22)
        addButton.frame = CGRect(x: pad, y: by, width: 30, height: 22)
    }

    // MARK: Actions

    private var selectedIDs: [CaptionItem.ID] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil } }

    @objc private func styleChanged() {
        guard let id = stylePopUp.selectedItem?.representedObject as? String else { return }
        if session?.setCaptionStyle(styleRef: id) == true { onStatus?("Caption style applied to all captions.") }
    }

    @objc private func findChanged() { refresh() }

    /// Return in the Find field: jump to the next caption that matches.
    @objc private func findNext() {
        guard let s = session, let tl = s.activeTimeline else { return }
        let hits = tl.captionMatches(find: findField.stringValue, caseSensitive: matchCase.state == .on)
        guard !hits.isEmpty else { return }
        let items = s.captionItems
        let here = s.playhead
        let next = hits.first { id in items.first { $0.id == id }.map { $0.range.start > here } ?? false } ?? hits[0]
        s.select(clips: [], captions: [next])
        if let it = items.first(where: { $0.id == next }) { onSeek?(it.range.start) }
    }

    @objc private func replaceAll() {
        guard let s = session, !findField.stringValue.isEmpty else { return }
        if findField.stringValue == replaceField.stringValue { onStatus?("Find and Replace are the same: nothing to change."); return }
        let skipped = s.activeTimeline?.captionTracks.contains(where: \.isLocked) == true ? " Locked caption tracks were skipped." : ""
        if let n = s.replaceCaptionText(find: findField.stringValue, with: replaceField.stringValue, caseSensitive: matchCase.state == .on) {
            onStatus?(n == 0 ? "No match." + skipped : "Replaced \(n) time\(n == 1 ? "" : "s")." + skipped)
        }
    }

    @objc private func addClicked() {
        if let id = session?.addCaptionAtPlayhead() { DispatchQueue.main.async { [weak self] in self?.beginEditing(id) } }
    }

    @objc private func exportClicked() { onExportSRT?() }

    @objc private func createClicked() {
        guard let m = model, let window else { return }
        CreateCaptionsDialog.present(on: window, model: m) { [weak m] ok in if ok { m?.createCaptions() } }
    }

    // MARK: Context menu on rows

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { table.selectRowIndexes([clicked], byExtendingSelection: false) }
        let n = table.selectedRowIndexes.count
        func add(_ title: String, _ sel: Selector, enabled: Bool) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.isEnabled = enabled
            menu.addItem(i)
        }
        let atPlayhead = session.flatMap { s in s.activeTimeline?.captions(at: s.playhead).isEmpty == false } ?? false
        add("Edit Text", #selector(editSelected), enabled: n == 1)
        add("Split Caption at Playhead", #selector(splitAtPlayhead), enabled: atPlayhead)
        add("Merge Captions", #selector(mergeSelected), enabled: n >= 2)
        menu.addItem(.separator())
        add("Delete", #selector(deleteSelected), enabled: n >= 1)
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

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
        let time = NSTextField(labelWithString: timecode.format(r.start))
        time.font = Theme.Fonts.mini; time.textColor = Theme.Colors.label3
        let text = NSTextField(string: r.text)
        text.font = Theme.Fonts.smallName; text.textColor = Theme.Colors.label
        text.isBordered = false; text.drawsBackground = false; text.focusRingType = .none
        text.isEditable = true; text.lineBreakMode = .byTruncatingTail
        text.placeholderString = "Empty caption"
        text.tag = row
        text.delegate = self
        text.setAccessibilityLabel("Caption text")
        let stack = NSStackView(views: [time, text])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.xs),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.Spacing.xs),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        let alert = NSAlert()
        alert.messageText = "Create Captions"
        alert.informativeText = "Captions are made from the transcript of the selected clip."

        let preset = NSPopUpButton(frame: .zero, pullsDown: false)
        preset.addItems(withTitles: model.presets.map(\.name))
        preset.selectItem(at: min(model.selectedPresetIndex, max(model.presets.count - 1, 0)))
        let chars = NSTextField(string: "")
        let lines = NSPopUpButton(frame: .zero, pullsDown: false)
        lines.addItems(withTitles: ["Single", "Double"])
        let minDur = NSTextField(string: "")
        let gap = NSTextField(string: "")
        for f in [chars, minDur, gap] { f.alignment = .right; f.widthAnchor.constraint(equalToConstant: 60).isActive = true }

        func fill() {
            guard model.presets.indices.contains(preset.indexOfSelectedItem) else { return }
            let p = model.presets[preset.indexOfSelectedItem].preset
            chars.integerValue = p.maxCharsPerLine
            lines.selectItem(at: p.maxLines <= 1 ? 0 : 1)
            minDur.stringValue = String(format: "%g", (Double(p.minDuration.value) / Double(p.minDuration.timescale) * 100).rounded() / 100)
            let fd = Double(model.frameDuration.value) / Double(model.frameDuration.timescale)
            gap.integerValue = fd > 0 ? Int((Double(p.gap.value) / Double(p.gap.timescale) / fd).rounded()) : 0
        }
        fill()
        final class Target: NSObject { var fill: (() -> Void)?; @objc func go() { fill?() } }
        let target = Target(); target.fill = fill
        preset.target = target; preset.action = #selector(Target.go)

        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let grid = NSGridView(views: [
            [label("Style"), preset], [label("Maximum length (characters)"), chars], [label("Lines"), lines],
            [label("Minimum duration (seconds)"), minDur], [label("Gap between captions (frames)"), gap],
        ])
        grid.rowSpacing = 6; grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 130)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(target) {}
                guard response == .alertFirstButtonReturn else { completion(false); return }
                model.selectedPresetIndex = preset.indexOfSelectedItem
                let secs = max(0, minDur.doubleValue)
                model.setOptions(maxCharsPerLine: chars.integerValue, lines: lines.indexOfSelectedItem + 1,
                                 minDuration: Time(Int64((secs * 1000).rounded()), 1000), gapFrames: gap.integerValue)
                completion(true)
            }
        }
    }
}
