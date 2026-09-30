import AppKit
import SSAudioFX
import SSCore
import SSText
import SSTranscribe

/// Scrolls a self-sizing inspector (a view whose content is one top-pinned NSStackView) vertically.
@MainActor
final class InspectorScroll: NSScrollView {
    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    init(content: NSView) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        let doc = Flipped()
        doc.translatesAutoresizingMaskIntoConstraints = false
        documentView = doc
        content.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: doc.topAnchor),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        if let stack = content.subviews.compactMap({ $0 as? NSStackView }).first {
            content.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Properties panel: the inspector of the selection (text clip, audio clip, captions) and the Color inspector with
/// scopes. Every edit goes through `EditorSession` (one undo step per gesture).
///
/// Not undoable and not persisted yet (no model home in SSCore): the track audio preset (`audioPresets`, the engine
/// has no FX hook) and the per-clip colour state (`colorModels`, waits for PHASE3 slice 9 which moves
/// `ColorCorrection` into SSCore).
@MainActor
public final class PropertiesPanelView: NSView, NSTextViewDelegate {
    public enum Tab: Int, CaseIterable { case inspector, captions, color
        var title: String { ["Inspector", "Captions", "Color"][rawValue] }
    }

    public let session: EditorSession
    /// Track audio preset chosen in the inspector, by track. Forwarded to the audio engine via `onAudioPresetChange`.
    public private(set) var audioPresets: [Track.ID: TrackAudioPreset] = [:]
    /// Colour inspector state per clip (side store until ColorCorrection lives in the project model).
    public private(set) var colorModels: [Clip.ID: ColorInspectorModel] = [:]
    public var onStatus: ((String) -> Void)?
    /// Forwards a track preset change to the audio engine (set by the app).
    public var onAudioPresetChange: ((Track.ID, TrackAudioPreset) -> Void)?

    public private(set) var tab: Tab = .inspector
    public private(set) var mode: PropertiesMode = .none

    private let tabs = NSSegmentedControl(labels: Tab.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let scopes = ScopesView()

    // Text page
    private let textModel = TextInspectorModel()
    private lazy var textInspector = TextInspectorView(model: textModel)
    private lazy var textScroll = InspectorScroll(content: textInspector)
    private let textEditor = NSTextView()
    private let textEditorScroll = NSScrollView()
    private var textClipID: Clip.ID?
    private var textTemplate: TextTemplate?
    private var textGestureOpen = false

    // Audio page
    private var audioModels: [Track.ID: TrackAudioInspectorModel] = [:]
    private var audioViews: [Track.ID: InspectorScroll] = [:]
    private var audioTrackID: Track.ID?

    // Captions page
    private var captionModels: [Clip.ID: CaptionsPanelModel] = [:]
    private var captionViews: [Clip.ID: CaptionsPanelView] = [:]
    private var captionClipID: Clip.ID?

    // Colour page
    private var colorViews: [Clip.ID: InspectorScroll] = [:]
    private var colorClipID: Clip.ID?
    private var scopeRefreshScheduled = false

    private var shown: NSView?
    private static let editorHeight: CGFloat = 64

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
        addSubview(tabs)
        addSubview(emptyLabel)
        buildTextEditor()
        wireText()
        sync([.project, .selection, .playhead])
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    // MARK: Session to UI

    public func sync(_ change: EditorSession.Change) {
        if change.contains(.project) || change.contains(.selection) {
            mode = PropertiesMode.resolve(selectedClip: session.singleSelectedClip,
                                          captionSelectionCount: session.captionSelection.count)
            if change.contains(.selection) { autoSelectTab() }
            prune()
            loadSelection()
            showCurrent()
        }
        if change.contains(.playhead) || change.contains(.project) { updateCaptionPlayhead() }
        if tab == .color, change.contains(.playhead) || change.contains(.project) || change.contains(.media) { scheduleScopes() }
    }

    private func autoSelectTab() {
        switch mode {
        case .text, .audio: select(.inspector)
        case .captions: select(.captions)
        case .none, .clip: break
        }
    }

    public func select(_ t: Tab) {
        tab = t
        tabs.selectedSegment = t.rawValue
        showCurrent()
        if t == .color { scheduleScopes() }
    }

    @objc private func tabChanged() { select(Tab(rawValue: tabs.selectedSegment) ?? .inspector) }

    private func prune() {
        let ids = Set(session.activeTimeline?.tracks.flatMap { $0.clips.map(\.id) } ?? [])
        for id in colorModels.keys where !ids.contains(id) { colorModels[id] = nil; colorViews[id] = nil }
        for id in captionModels.keys where !ids.contains(id) { captionModels[id] = nil; captionViews[id] = nil }
    }

    private func loadSelection() {
        let clip = session.singleSelectedClip
        switch mode {
        case .text: if let clip { loadText(clip) }
        case .audio: if let clip { loadAudio(clip) }
        default: break
        }
        if let clip, clip.generator == nil { captionClipID = clip.id; ensureCaptions(for: clip) }
        colorClipID = clip.flatMap { $0.kind == .audio ? nil : $0.id }
        if let id = colorClipID { ensureColor(for: id) }
    }

    // MARK: Pages

    private func showCurrent() {
        let page: NSView?
        var message = ""
        switch tab {
        case .inspector:
            switch mode {
            case .text: page = textPage
            case .audio: page = audioTrackID.flatMap { audioViews[$0] }
            case .none, .captions: page = nil; message = "Select a text layer or an audio clip to edit its properties."
            case .clip: page = nil; message = "Motion, opacity and rounded corners are in Effect Controls. Color is in the Color tab."
            }
        case .captions:
            if let id = captionClipID, let v = captionViews[id] { page = v } else {
                page = nil; message = "Select a clip to transcribe it and create captions."
            }
        case .color:
            if let id = colorClipID, let v = colorViews[id] { page = v } else {
                page = nil; message = "Select a picture clip to adjust its color."
            }
        }
        if shown !== page {
            shown?.removeFromSuperview()
            shown = page
            if let page { addSubview(page, positioned: .below, relativeTo: tabs) }
        }
        let showScopes = tab == .color && scopes != nil
        scopes?.isHidden = !showScopes
        if showScopes, scopes?.superview == nil, let scopes { addSubview(scopes) }
        emptyLabel.stringValue = message
        emptyLabel.isHidden = page != nil
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let h = Theme.Metrics.panelHeader
        tabs.sizeToFit()
        let tw = min(bounds.width - 2 * Theme.Spacing.sm, max(tabs.frame.width, 220))
        tabs.frame = CGRect(x: (bounds.width - tw) / 2, y: bounds.height - h + (h - tabs.frame.height) / 2,
                            width: tw, height: tabs.frame.height)
        var body = CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - h, 0))
        if tab == .color, let scopes, !scopes.isHidden {
            let sh = min(220, body.height * 0.4)
            scopes.frame = CGRect(x: 0, y: body.maxY - sh, width: body.width, height: sh)
            body.size.height -= sh
        }
        shown?.frame = body
        layoutTextPage(in: body)
        emptyLabel.frame = CGRect(x: Theme.Spacing.lg, y: body.midY - 24, width: max(body.width - 2 * Theme.Spacing.lg, 0), height: 48)
    }

    // MARK: Text

    private var textPage: NSView { textContainer }
    private lazy var textContainer: NSView = {
        let v = NSView()
        v.addSubview(textEditorScroll)
        v.addSubview(textScroll)
        return v
    }()

    private func layoutTextPage(in body: CGRect) {
        guard shown === textContainer else { return }
        let b = textContainer.bounds
        let pad = Theme.Spacing.md
        textEditorScroll.frame = CGRect(x: pad, y: b.height - Self.editorHeight - pad, width: max(b.width - 2 * pad, 0), height: Self.editorHeight)
        textScroll.frame = CGRect(x: 0, y: 0, width: b.width, height: max(b.height - Self.editorHeight - 2 * pad, 0))
    }

    private func buildTextEditor() {
        textEditor.font = Theme.Fonts.small
        textEditor.textColor = Theme.Colors.label
        textEditor.drawsBackground = true
        textEditor.backgroundColor = Theme.Colors.field
        textEditor.insertionPointColor = Theme.Colors.label
        textEditor.isRichText = false
        textEditor.allowsUndo = false           // undo belongs to the project history
        textEditor.isAutomaticQuoteSubstitutionEnabled = false
        textEditor.isVerticallyResizable = true
        textEditor.autoresizingMask = [.width]
        textEditor.textContainerInset = NSSize(width: 4, height: 4)
        textEditor.delegate = self
        textEditorScroll.documentView = textEditor
        textEditorScroll.hasVerticalScroller = true
        textEditorScroll.borderType = .lineBorder
        textEditor.setAccessibilityLabel("Text")
    }

    private func wireText() {
        textModel.onBeginEditing = { [weak self] in self?.textGestureOpen = false }
        textModel.onChange = { [weak self] style, anims in
            guard let self, let id = textClipID, var t = textTemplate else { return }
            t.style = style
            textTemplate = t
            session.updateTextClip(id, template: t, animations: anims, continuesGesture: textGestureOpen)
            textGestureOpen = true
        }
        textModel.onEndEditing = { [weak self] in self?.textGestureOpen = false }
    }

    private func loadText(_ clip: Clip) {
        guard let ref = clip.generator, let (t, anims) = try? TextGenerator.decode(ref) else { return }
        let changedClip = textClipID != clip.id
        textClipID = clip.id
        if t != textTemplate || changedClip {
            textTemplate = t
            textModel.load(style: t.style, animations: anims ?? AnimationSet(in: nil, out: nil))
        }
        if textEditor.string != t.text, changedClip || window?.firstResponder !== textEditor {
            textEditor.string = t.text
        }
    }

    public func textDidBeginEditing(_ notification: Notification) { textGestureOpen = false }
    public func textDidEndEditing(_ notification: Notification) { textGestureOpen = false }

    public func textDidChange(_ notification: Notification) {
        guard let id = textClipID, var t = textTemplate, t.text != textEditor.string else { return }
        t.text = textEditor.string
        textTemplate = t
        session.updateTextClip(id, template: t, animations: textModel.animations, continuesGesture: textGestureOpen)
        textGestureOpen = true
    }

    // MARK: Audio

    private func loadAudio(_ clip: Clip) {
        guard let track = session.activeTimeline?.tracks.first(where: { $0.clips.contains { $0.id == clip.id } }) else { return }
        audioTrackID = track.id
        if audioViews[track.id] == nil {
            let model = TrackAudioInspectorModel(preset: audioPresets[track.id] ?? .off)
            model.onChange = { [weak self] preset in
                self?.audioPresets[track.id] = preset
                self?.onAudioPresetChange?(track.id, preset)
            }
            let view = TrackAudioInspectorView(model: model)
            view.note = "Applied to the track during playback. Not saved with the project yet."
            audioModels[track.id] = model
            audioViews[track.id] = InspectorScroll(content: view)
        }
    }

    // MARK: Captions

    private func ensureCaptions(for clip: Clip) {
        guard captionViews[clip.id] == nil else { return }
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
        captionModels[id] = model
        captionViews[id] = CaptionsPanelView(model: model)
    }

    private func clip(_ id: Clip.ID) -> Clip? { session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id } }

    private func updateCaptionPlayhead() {
        guard let id = captionClipID, let c = clip(id), let m = captionModels[id] else { return }
        m.updatePlayhead(session.playhead - c.start + c.source.start)
    }

    // MARK: Color and scopes

    private func ensureColor(for id: Clip.ID) {
        guard colorViews[id] == nil else { return }
        let model = ColorInspectorModel()
        // The model is the store for now: nothing reaches the renderer until ColorCorrection is part of the project.
        model.onChange = { [weak self] _ in self?.scheduleScopes() }
        colorModels[id] = model
        colorViews[id] = InspectorScroll(content: ColorInspectorView(model: model))
    }

    private func scheduleScopes() {
        guard tab == .color, !scopeRefreshScheduled else { return }
        scopeRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scopeRefreshScheduled = false
                if self.tab == .color, let tex = self.session.engine.lastRenderedTexture { self.scopes?.update(frame: tex) }
            }
        }
    }
}
