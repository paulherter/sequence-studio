import AppKit
import Observation
import SSCore
import SSText
import SSTranscribe

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
    /// "Export SRT…" in the Captions tab.
    public var onExportSRT: (() -> Void)?
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
        captionsTab.session = session
        captionsTab.onSeek = { [weak self] t in self?.session.seek(to: t) }
        captionsTab.onStatus = { [weak self] m in self?.onStatus?(m) }
        captionsTab.onExportSRT = { [weak self] in self?.onExportSRT?() }
        addSubview(tabs)
        addSubview(emptyLabel)
        addSubview(captionsTab)
        captionsTab.isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Text")
        sync([.project, .selection, .playhead])
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    /// Transcript model of a clip (dev aids and tests); exists once the clip was selected.
    public func captionsModel(for clip: Clip.ID) -> CaptionsPanelModel? { models[clip] }

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
            let clip = session.singleSelectedClip.flatMap { $0.generator == nil ? $0 : nil }
            clipID = clip?.id
            if let clip { ensure(for: clip) }
            captionsTab.model = clipID.flatMap { models[$0] }
            if let tl = session.activeTimeline {
                captionsTab.timecode = Timecode(frameDuration: tl.frameDuration,
                                                dropFrame: tl.frameDuration == Time(1001, 30000) || tl.frameDuration == Time(1001, 60000))
            }
            captionsTab.model?.frameDuration = session.activeTimeline?.frameDuration ?? Time(1, 30)
            captionsTab.setTimeline(session.activeTimeline)
            captionsTab.setCaptionSelection(session.captionSelection)
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
            self.session.seek(to: c.timelineTime(forSource: t, frameDuration: self.session.activeTimeline?.frameDuration ?? .zero))
        }
        model.onCreateCaptions = { [weak self] captions in
            guard let self, let c = self.clip(id) else { return }
            // Every clip of the sequence that plays this media gets its captions (cut interviews, linked A/V once).
            let same = self.session.activeTimeline?.tracks.flatMap(\.clips).filter { $0.media == c.media && $0.generator == nil } ?? [c]
            let items = CaptionMapping.items(captions, forClips: same.isEmpty ? [c] : same,
                                             frameDuration: self.session.activeTimeline?.frameDuration)
            guard !items.isEmpty else { self.onStatus?("No captions fall inside this clip."); return }
            if self.session.addCaptions(items) { self.onStatus?("Created \(items.count) captions.") }
        }
        if let ref = session.project.media(clip.media) { model.sourceURL = URL(fileURLWithPath: ref.path) }
        models[id] = model
        views[id] = CaptionsPanelView(model: model)
    }

    private func updatePlayhead() {
        guard let id = clipID, let c = clip(id), let m = models[id] else { return }
        m.updatePlayhead(c.sourceTime(at: session.playhead, frameDuration: session.activeTimeline?.frameDuration ?? .zero))
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
