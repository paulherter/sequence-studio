import AppKit
import Observation
import SQCore
import SQUIKit
import SQText
import SQTranscribe

/// Captions panel (Premiere's Text panel, named for what it holds): a Transcribe tab (transcribe the whole active
/// sequence and edit the transcript), a Captions tab (caption list, Create Captions into the caption track) and a Style
/// tab (design all or the selected captions, the word highlight, the project's brand tokens). Transcript words are in
/// sequence time. A Templates tab lists the text and graphic templates (also in the Library) for one-click placing.
@MainActor
public final class TextPanelView: NSView {
    public enum Tab: Int, CaseIterable { case transcript, captions, style, templates
        var title: String { ["Transcribe", "List", "Look", "Templates"][rawValue] }
    }

    public let session: EditorSession
    public var onStatus: ((String) -> Void)?
    /// "Export SRT…" in the Captions tab.
    public var onExportSRT: (() -> Void)?
    /// "Import SRT…" in the Captions tab.
    public var onImportSRT: (() -> Void)?
    public private(set) var tab: Tab = .transcript
    /// This window's Library keystones: the Captions tab's text sections offer the same saved animations as the clip's.
    public weak var keystones: KeystonesPanelModel? { didSet { styleTab.inspectorModel.keystones = keystones } }

    private let tabs = SQSegmented(labels: Tab.allCases.map(\.title), segmentWidth: 0)
    private let emptyLabel = EmptyStateView(title: "No sequence open", hint: "Open a sequence to transcribe it and create captions")
    private let captionsTab = CaptionsTabView()
    private let styleTab = CaptionStyleTabView()
    /// Text and graphic templates, one click to place (the host fills `allTiles` and handles `onPick`).
    public let templatesTab = TextTemplatesTabView()
    private var models: [Timeline.ID: CaptionsPanelModel] = [:]
    private var views: [Timeline.ID: CaptionsPanelView] = [:]
    private var timelineID: Timeline.ID?
    private var shown: NSView?

    public override var isFlipped: Bool { true }

    public init(session: EditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        clipsToBounds = true      // the page never paints past the panel edge into the neighboring Timeline
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        captionsTab.session = session
        captionsTab.onSeek = { [weak self] t in self?.session.seek(to: t) }
        captionsTab.onStatus = { [weak self] m in self?.onStatus?(m) }
        captionsTab.onExportSRT = { [weak self] in self?.onExportSRT?() }
        captionsTab.onImportSRT = { [weak self] in self?.onImportSRT?() }
        addSubview(tabs)
        addSubview(emptyLabel)
        addSubview(captionsTab)
        captionsTab.isHidden = true
        styleTab.session = session
        styleTab.onStatus = { [weak self] m in self?.onStatus?(m) }
        addSubview(styleTab)
        styleTab.isHidden = true
        addSubview(templatesTab)
        templatesTab.isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Captions")
        sync([.project, .selection, .playhead])
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    /// Transcript model of the active sequence (dev aids and tests); exists once the sequence was shown.
    /// Delete key in the panel: deletes the selected captions when the Captions tab is showing.
    @discardableResult
    public func deleteSelectedCaptions() -> Bool {
        guard tab == .captions else { return false }
        return session.deleteSelectedCaptions()
    }

    public var captionsModel: CaptionsPanelModel? { timelineID.flatMap { models[$0] } }

    public func select(_ t: Tab) {
        tab = t
        tabs.selectedSegment = t.rawValue
        showCurrent()
    }

    /// Shows the Captions tab and starts typing into that caption (double-click on a caption in the timeline).
    public func editCaption(_ id: CaptionItem.ID) {
        select(.captions)
        layoutSubtreeIfNeeded()
        captionsTab.setTimeline(session.activeTimeline)
        captionsTab.beginEditing(id)
    }

    @objc private func tabChanged() { select(Tab(rawValue: tabs.selectedSegment) ?? .transcript) }

    // MARK: Session to UI

    public func sync(_ change: EditorSession.Change) {
        if change.contains(.project) || change.contains(.selection) {
            prune()
            timelineID = session.activeTimeline?.id
            if let tl = session.activeTimeline { ensure(for: tl) }
            captionsTab.model = timelineID.flatMap { models[$0] }
            if let tl = session.activeTimeline {
                captionsTab.timecode = Timecode(frameDuration: tl.frameDuration,
                                                dropFrame: tl.frameDuration == Time(1001, 30000) || tl.frameDuration == Time(1001, 60000))
            }
            captionsTab.model?.frameDuration = session.activeTimeline?.frameDuration ?? Time(1, 30)
            captionsTab.setTimeline(session.activeTimeline)
            captionsTab.setCaptionSelection(session.captionSelection)
            styleTab.model = captionsTab.model
            if tab == .style { styleTab.refresh() }
            showCurrent()
        }
        if change.contains(.playhead) || change.contains(.project) { updatePlayhead() }
    }

    private func prune() {
        let ids = Set(session.project.timelines.map(\.id))
        for id in models.keys where !ids.contains(id) { models[id] = nil; views[id] = nil }
    }

    /// Media files of the audible clips (a relinked file keeps its media id: the path is read fresh on every sync).
    private func sequenceSource(_ tl: Timeline) -> CaptionsPanelModel.SequenceSource {
        var urls: [UUID: URL] = [:]
        var maps: [UUID: AudioChannelMap] = [:]
        var counts: [UUID: Int] = [:]
        for c in TimelineTranscription.audibleClips(in: tl) {
            guard let ref = session.project.media(c.media) else { continue }
            urls[c.media] = URL(fileURLWithPath: ref.path)
            if let map = ref.info?.audio?.channelMap { maps[c.media] = map; counts[c.media] = ref.info?.audio?.channels }
        }
        return .init(timeline: tl, urls: urls, channelMaps: maps, expectedChannels: counts)
    }

    private func ensure(for tl: Timeline) {
        if let model = models[tl.id] {
            model.setSequenceSource(sequenceSource(tl))
            return
        }
        let model = CaptionsPanelModel(service: SpeechAnalyzerTranscriber())
        let projectID = session.project.id
        let language = AppSettings.captionLanguage(forProject: projectID)
        if !model.languages.contains(language) { model.languages.insert(language, at: 0) }
        model.language = language
        model.autoDetectLanguage = AppSettings.load().captionAutoLanguage
        // Picking another language in the panel is the per-project override.
        model.onLanguageChanged = { l in AppSettings.setCaptionLanguage(l, forProject: projectID) }
        // Words are in sequence time already.
        model.onSeek = { [weak self] t in self?.session.seek(to: t) }
        model.onCreateCaptions = { [weak self] captions in
            guard let self else { return }
            let fd = self.session.activeTimeline?.frameDuration
            let items = captions.map { c in
                CaptionItem(lines: c.lines, range: c.range, styleRef: c.styleRef, animationRef: c.animationRef,
                            words: c.words.map { CaptionWord(text: $0.text, range: TimeRange(start: $0.range.start - c.range.start,
                                                                                            end: $0.range.end - c.range.start),
                                                                                            confidence: $0.confidence) })
            }
            let snapped = fd.map { CaptionMapping.snapped(items, to: $0) } ?? items
            guard !snapped.isEmpty else { self.onStatus?(SQL10n.string("There are no captions to create.")); return }
            if self.session.addCaptions(snapped) { self.onStatus?(SQL10n.format("Created %@ captions.", String(snapped.count))) }
        }
        model.setSequenceSource(sequenceSource(tl))
        models[tl.id] = model
        Task { await model.loadSupportedLanguages() }
        let transcriptView = CaptionsPanelView(model: model)
        transcriptView.onCreateCaptions = { [weak self] in self?.captionsTab.presentCreateCaptions() }
        transcriptView.onMarkHits = { [weak self] times, name in
            guard let self else { return }
            var added = 0
            self.session.attempt("Mark Search Hits") { added = $0.addSearchHitMarkers(at: times, name: name) }
            self.onStatus?(added == 0 ? SQL10n.string("Every match already has a marker.") : SQL10n.plural(added, one: "Marked %@ match.", other: "Marked %@ matches."))
        }
        views[tl.id] = transcriptView
    }

    private func updatePlayhead() {
        timelineID.flatMap { models[$0] }?.updatePlayhead(session.playhead)
    }

    // MARK: Layout

    private func showCurrent() {
        let page: NSView?
        switch tab {
        case .transcript: page = timelineID.flatMap { views[$0] }
        case .captions: page = captionsTab
        case .style: page = styleTab; styleTab.refresh()
        case .templates: page = templatesTab
        }
        if shown !== page {
            shown?.isHidden = true
            if shown !== captionsTab && shown !== styleTab && shown !== templatesTab { shown?.removeFromSuperview() }
            shown = page
            if let page, page !== captionsTab, page !== styleTab, page !== templatesTab { addSubview(page) }
        }
        page?.isHidden = false
        emptyLabel.isHidden = page != nil
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let h: CGFloat = 38     // v9 `.capbar`: 38 pt bar, the switch at the leading inset
        tabs.sizeToFit()
        let tw = min(max(bounds.width - 2 * Theme.Spacing.sm, 0), tabs.frame.width)
        tabs.frame = CGRect(x: Theme.Spacing.sm, y: ((h - tabs.frame.height) / 2).rounded(), width: tw, height: tabs.frame.height)
        let body = CGRect(x: 0, y: h, width: bounds.width, height: max(bounds.height - h, 0))
        shown?.frame = body
        emptyLabel.frame = body
    }
}
