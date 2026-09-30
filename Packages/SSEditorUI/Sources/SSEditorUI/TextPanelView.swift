import AppKit
import Observation
import SSCore
import SSText
import SSTranscribe

/// Captions tab of the Text panel: the captions of the sequence, the style preset and Create Captions.
/// The transcript comes from the model of the selected clip (Transcript tab).
@MainActor
public final class CaptionsTabView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public struct Row: Equatable, Sendable {
        public var id: UUID
        public var start: Time
        public var text: String
    }

    /// Model of the selected clip; nil when no clip is selected.
    public var model: CaptionsPanelModel? { didSet { observe(); refresh() } }
    public var onSeek: ((Time) -> Void)?
    public var timecode = Timecode(frameDuration: Time(1001, 30000), dropFrame: true)

    public private(set) var rows: [Row] = []

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let presetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let createButton = NSButton(title: "Create Captions", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var observed: CaptionsPanelModel?
    private var generation = 0

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        let col = NSTableColumn(identifier: .init("caption"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("Captions")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        presetPopUp.controlSize = .small
        presetPopUp.font = Theme.Fonts.small
        presetPopUp.target = self; presetPopUp.action = #selector(presetChanged)
        createButton.bezelStyle = .rounded
        createButton.controlSize = .small
        createButton.font = Theme.Fonts.small
        createButton.keyEquivalent = "\r"
        createButton.target = self; createButton.action = #selector(createClicked)
        hint.font = Theme.Fonts.small
        hint.textColor = Theme.Colors.label3
        addSubview(scroll); addSubview(presetPopUp); addSubview(createButton); addSubview(hint)
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
        if new != rows { rows = new; table.reloadData() }
        refresh()
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
        presetPopUp.removeAllItems()
        if let m = model {
            presetPopUp.addItems(withTitles: m.presets.map(\.name))
            if m.presets.indices.contains(m.selectedPresetIndex) { presetPopUp.selectItem(at: m.selectedPresetIndex) }
        }
        presetPopUp.isEnabled = model != nil
        createButton.isEnabled = model?.canCreateCaptions ?? false
        if model?.canCreateCaptions == true {
            hint.stringValue = rows.isEmpty ? "No captions yet." : "\(rows.count) captions. Creating replaces them."
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
        let footer: CGFloat = 78
        scroll.frame = CGRect(x: 0, y: 0, width: w, height: max(bounds.height - footer, 0))
        let y = scroll.frame.maxY + pad
        let inner = max(w - 2 * pad, 0)
        presetPopUp.frame = CGRect(x: pad, y: y, width: inner, height: 20)
        createButton.sizeToFit()
        createButton.frame = CGRect(x: max(w - pad - createButton.frame.width, pad), y: y + 26,
                                    width: createButton.frame.width, height: createButton.frame.height)
        let hw = max(createButton.frame.minX - 2 * pad, 0)
        hint.frame = CGRect(x: pad, y: y + 26, width: hw, height: max(footer - 26 - pad, 0))
    }

    // MARK: Actions

    @objc private func presetChanged() { model?.selectedPresetIndex = presetPopUp.indexOfSelectedItem }
    @objc private func createClicked() { model?.createCaptions() }
    @objc private func rowClicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        onSeek?(rows[table.clickedRow].start)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
        let time = NSTextField(labelWithString: timecode.format(r.start))
        time.font = Theme.Fonts.mini; time.textColor = Theme.Colors.label3
        let text = NSTextField(labelWithString: r.text)
        text.font = Theme.Fonts.smallName; text.textColor = Theme.Colors.label
        text.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [time, text])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.xs),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Theme.Spacing.xs),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel(r.text)
        return cell
    }
}

/// Text panel = Premiere's Text panel: a Transcript tab (transcribe and edit the transcript of the selected clip)
/// and a Captions tab (caption list, style preset, Create Captions into the caption track).
/// Text templates live in the Library (Text Templates), not here.
@MainActor
public final class TextPanelView: NSView {
    public enum Tab: Int, CaseIterable { case transcript, captions
        var title: String { ["Transcript", "Captions"][rawValue] }
    }

    public let session: EditorSession
    public var onStatus: ((String) -> Void)?
    public private(set) var tab: Tab = .transcript

    private let tabs = NSSegmentedControl(labels: Tab.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Select a clip to transcribe it and create captions.")
    private let captionsTab = CaptionsTabView()
    private var models: [Clip.ID: CaptionsPanelModel] = [:]
    private var views: [Clip.ID: CaptionsPanelView] = [:]
    private var clipID: Clip.ID?
    private var shown: NSView?

    public override var isFlipped: Bool { true }

    public init(session: EditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        tabs.segmentStyle = .texturedRounded
        tabs.controlSize = .small
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        emptyLabel.font = Theme.Fonts.small
        emptyLabel.textColor = Theme.Colors.label3
        emptyLabel.alignment = .center
        captionsTab.onSeek = { [weak self] t in self?.session.seek(to: t) }
        addSubview(tabs)
        addSubview(emptyLabel)
        addSubview(captionsTab)
        captionsTab.isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Text")
        sync([.project, .selection, .playhead])
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public func select(_ t: Tab) {
        tab = t
        tabs.selectedSegment = t.rawValue
        showCurrent()
    }

    @objc private func tabChanged() { select(Tab(rawValue: tabs.selectedSegment) ?? .transcript) }

    // MARK: Session to UI

    public func sync(_ change: EditorSession.Change) {
        if change.contains(.project) || change.contains(.selection) {
            prune()
            let clip = session.singleSelectedClip.flatMap { $0.generator == nil ? $0 : nil }
            clipID = clip?.id
            if let clip { ensure(for: clip) }
            captionsTab.model = clipID.flatMap { models[$0] }
            if let tl = session.activeTimeline {
                captionsTab.timecode = Timecode(frameDuration: tl.frameDuration,
                                                dropFrame: tl.frameDuration == Time(1001, 30000) || tl.frameDuration == Time(1001, 60000))
            }
            captionsTab.setTimeline(session.activeTimeline)
            showCurrent()
        }
        if change.contains(.playhead) || change.contains(.project) { updatePlayhead() }
    }

    private func prune() {
        let ids = Set(session.activeTimeline?.tracks.flatMap { $0.clips.map(\.id) } ?? [])
        for id in models.keys where !ids.contains(id) { models[id] = nil; views[id] = nil }
    }

    private func clip(_ id: Clip.ID) -> Clip? { session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id } }

    private func ensure(for clip: Clip) {
        guard views[clip.id] == nil else { return }
        let model = CaptionsPanelModel(service: SpeechAnalyzerTranscriber())
        let id = clip.id
        model.onSeek = { [weak self] t in
            guard let self, let c = self.clip(id) else { return }
            self.session.seek(to: c.start + (t - c.source.start))
        }
        model.onCreateCaptions = { [weak self] captions in
            guard let self, let c = self.clip(id) else { return }
            let items = CaptionMapping.items(captions, for: c)
            guard !items.isEmpty else { self.onStatus?("No captions fall inside this clip."); return }
            if self.session.replaceCaptions(items) { self.onStatus?("Created \(items.count) captions.") }
        }
        if let ref = session.project.media(clip.media) { model.sourceURL = URL(fileURLWithPath: ref.path) }
        models[id] = model
        views[id] = CaptionsPanelView(model: model)
    }

    private func updatePlayhead() {
        guard let id = clipID, let c = clip(id), let m = models[id] else { return }
        m.updatePlayhead(session.playhead - c.start + c.source.start)
    }

    // MARK: Layout

    private func showCurrent() {
        let page: NSView?
        switch tab {
        case .transcript: page = clipID.flatMap { views[$0] }
        case .captions: page = captionsTab
        }
        if shown !== page {
            shown?.isHidden = true
            if shown !== captionsTab { shown?.removeFromSuperview() }
            shown = page
            if let page, page !== captionsTab { addSubview(page) }
        }
        page?.isHidden = false
        emptyLabel.isHidden = page != nil
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let h: CGFloat = 28
        tabs.sizeToFit()
        let tw = min(max(bounds.width - 2 * Theme.Spacing.sm, 0), max(tabs.frame.width, 180))
        tabs.frame = CGRect(x: (bounds.width - tw) / 2, y: (h - tabs.frame.height) / 2 + 2, width: tw, height: tabs.frame.height)
        let body = CGRect(x: 0, y: h + 4, width: bounds.width, height: max(bounds.height - h - 4, 0))
        shown?.frame = body
        emptyLabel.frame = CGRect(x: Theme.Spacing.lg, y: body.midY - 24, width: max(body.width - 2 * Theme.Spacing.lg, 0), height: 48)
    }
}
