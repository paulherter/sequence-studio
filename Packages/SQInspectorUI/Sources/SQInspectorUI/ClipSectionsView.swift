import AppKit
import SQAudioFX
import SQCore
import SQText

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

/// Places a self-sizing inspector at a given width and reports the height it needs.
@MainActor
private final class FitHost: NSView {
    let content: NSView
    private let width: NSLayoutConstraint

    override var isFlipped: Bool { true }

    /// `sizesItself`: the content is a stack view whose own fitting size is its height (no inner stack to pin).
    init(content: NSView, sizesItself: Bool = false) {
        self.content = content
        width = content.widthAnchor.constraint(equalToConstant: 280)
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            width,
        ])
        if !sizesItself, let stack = content.subviews.compactMap({ $0 as? NSStackView }).first {
            content.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func height(forWidth w: CGFloat) -> CGFloat {
        width.constant = max(w, 1)
        content.layoutSubtreeIfNeeded()
        return ceil(content.fittingSize.height)
    }
}

/// The content sections of the Controls column (text concept B, Bild 5). One fixed skeleton for every clip kind:
/// header, Text or Shape (content), Appearance, Transform, Animation, then Speed, Mask, each effect, Audio; for a
/// caption track the read-only caption list in Audio's place. This view is the content slot: it leads the column for a
/// text, shape, template or graphic clip (`mode.leads`) and closes it for an audio clip or a caption track. For a text
/// clip it also hands out the parts the host places inside the skeleton: `transformTailView` (Arrange, the last rows
/// of Transform) and `afterTransformView` (Animation). Every edit goes through `EditorSession` (one undo step per
/// gesture).
///
/// Not undoable and not persisted yet: the track audio preset (`audioPresets`, the engine has no FX hook).
@MainActor
public final class ClipSectionsView: NSView {
    public let session: EditorSession
    /// Track audio preset chosen here, by track. Forwarded to the audio engine via `onAudioPresetChange`.
    /// Only hand-edited presets: a track role lives on `Track.audioRole` and the engine resolves its voiced preset.
    public private(set) var audioPresets: [Track.ID: TrackAudioPreset] = [:]
    /// nil = no explicit preset (the engine falls back to the track's role preset).
    public var onAudioPresetChange: ((Track.ID, TrackAudioPreset?) -> Void)?
    /// One of the six align buttons of the Text section: the host moves the selected text clip against the frame.
    public var onAlignToFrame: ((FrameAlignment) -> Void)?
    /// The height this view wants changed (another section or another track); the host re-lays out.
    public var onHeightChange: (() -> Void)?
    public private(set) var mode: ClipSectionMode = .none

    static let headerHeight = ControlsGrid.headerHeight

    /// The section header (the one disclosure component). A click folds the section; the state is per mode and kept
    /// while the view lasts. Hidden for a text clip: Text and Appearance carry their own headers.
    let header = InspectorSectionHeader(title: "", isExpanded: true)
    private var collapsedModes: Set<String> = []
    private var isCollapsed: Bool { mode != .text && collapsedModes.contains(mode.title) }
    /// Height of this view's own header (0 for a text clip).
    private var headerHeight: CGFloat { mode == .text ? 0 : Self.headerHeight }

    // Text
    private let textModel = TextInspectorModel(styles: TextStyleStore.load())
    /// The window's Library keystones: the saved animations of the Intro / Outro popups, and where a Custom one is
    /// saved. The app sets it; each window has its own.
    public weak var keystones: KeystonesPanelModel? { didSet { textModel.keystones = keystones } }
    /// A short message for the user (a Custom animation that could not be saved); the app shows it in its status line.
    public var onNotice: ((String) -> Void)?
    /// Built on the first text clip (170+ views: building and laying it out at launch cost ~200 ms in Debug).
    private var textHost: FitHost?
    private var arrangeHost: FitHost?
    private var animationHost: FitHost?
    private func makeTextHost() -> FitHost {
        if let h = textHost { return h }
        let block = TextBlockView(model: textModel, context: .clip)
        block.showsTextBox = true
        block.clipText = { [weak self] in self?.textTemplate?.text ?? "" }
        block.onHeightChange = { [weak self] in self?.needsLayout = true; self?.onHeightChange?() }
        block.onNotice = { [weak self] m in if let show = self?.onNotice { show(m) } else { TextBlockView.noticeDialog(m) } }
        block.onTextBegin = { [weak self] in self?.textGestureOpen = false }
        block.onTextChange = { [weak self] str in self?.textTyped(str) }
        block.onTextEnd = { [weak self] in self?.textGestureOpen = false }
        wireLooks(block)
        textBlock = block
        let h = FitHost(content: block)
        h.isHidden = true
        addSubview(h)
        textHost = h
        // The parts the host places inside the skeleton (it adds them to its own content).
        let arrange = FitHost(content: block.arrangeRows, sizesItself: true)
        arrange.isHidden = true
        arrangeHost = arrange
        let anim = FitHost(content: block.animationSection, sizesItself: true)
        anim.isHidden = true
        animationHost = anim
        return h
    }
    private(set) var textBlock: TextBlockView?

    // MARK: Parts placed by the host (text clip)

    /// Every part the host has to own as a subview (it hides the ones the current selection does not show).
    public var partViews: [NSView] { [arrangeHost, animationHost].compactMap { $0 } }
    /// Arrange (text box position, align to the frame): the last rows of Transform.
    public var transformTailView: NSView? { mode == .text ? arrangeHost : nil }
    public func transformTailHeight(for width: CGFloat) -> CGFloat { mode == .text ? arrangeHost?.height(forWidth: width) ?? 0 : 0 }
    /// Animation: its own section right after Transform.
    public var afterTransformView: NSView? { mode == .text ? animationHost : nil }
    public func afterTransformHeight(for width: CGFloat) -> CGFloat { mode == .text ? animationHost?.height(forWidth: width) ?? 0 : 0 }

    // All Captions (a caption is selected, or nothing is and the sequence has a caption track): every caption of the
    // sequence, read only, the one at the playhead marked; a click seeks. It scrolls by itself inside `availableHeight`.
    let captionList = CaptionReadListView()
    /// Name of the caption track in focus and the number of captions listed (the Controls header).
    public private(set) var captionSummary: (name: String, count: Int)?
    /// The caption tracks the list was built from (it is rebuilt only when they change).
    private var listedCaptions: [CaptionTrack] = []
    private var listedFrame: Time?
    /// Height of the column the host shows; the caption list takes what is left of it under its header.
    public var availableHeight: CGFloat = 0 {
        didSet { if oldValue != availableHeight, mode == .captions { needsLayout = true } }
    }
    static let captionRowsWithoutHost = 12, captionRowsAtLeast = 3
    private var captionListHeight: CGFloat {
        let row = Theme.Row.list
        let room = availableHeight > 0 ? availableHeight - headerHeight : CGFloat(Self.captionRowsWithoutHost) * row
        return min(captionList.contentHeight, max(room, CGFloat(Self.captionRowsAtLeast) * row))
    }
    private var textClipID: Clip.ID?
    private var textTemplate: TextTemplate?
    /// Multi-select: several text clips are selected; edits go to all of them (`EditorSession.updateTextClips`).
    private var textMulti = false
    private var textAnimations: AnimationSet?
    private var textGestureOpen = false

    // Shape
    let shapeView = ShapeInspectorView()
    private lazy var shapeHost = FitHost(content: shapeView)
    private var shapeClipID: Clip.ID?

    // Color Matte (one Color row; the picker drag is one undo step)
    let matteView = ColorMatteInspectorView()
    private lazy var matteHost = FitHost(content: matteView)
    private var matteClipID: Clip.ID?
    private var matteGestureOpen = false

    // Template (slots and zones of an applied title template)
    private let templateView = TemplateSlotsView()
    private lazy var templateHost = FitHost(content: templateView)
    private var templateClipID: Clip.ID?

    // Graphic (G7: layer count and the way into the Graphics panel)
    let graphicView = GraphicSectionView()
    private lazy var graphicHost = FitHost(content: graphicView)
    /// "Edit in Graphics": the host brings the Graphics panel to the front.
    public var onShowGraphics: (() -> Void)? {
        get { graphicView.onEdit }
        set { graphicView.onEdit = newValue }
    }
    /// The app's one Graphics editor: Controls > Graphic shows the basics of its selected shape items.
    public var graphicsEditor: GraphicsEditor? {
        get { graphicView.itemRows.editor }
        set { graphicView.itemRows.editor = newValue }
    }
    /// The item selection changed (it is not a session change): the item rows follow.
    public func graphicItemsChanged() {
        guard mode == .graphic else { return }
        graphicView.refreshPicker()
        graphicView.itemRows.refresh()
    }

    // Audio
    private(set) var audioModels: [Track.ID: TrackAudioInspectorModel] = [:]
    private var audioHosts: [Track.ID: FitHost] = [:]
    private var audioTrackID: Track.ID?

    public override var isFlipped: Bool { true }

    public init(session: EditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        header.onToggleExpanded = { [weak self] _ in self?.toggleCollapsed() }
        header.setAccessibilityRole(.button)
        addSubview(header)
        captionList.insets = (ControlsGrid.labelX, ControlsGrid.trailing)
        captionList.isHidden = true
        captionList.onSeek = { [weak self] t in self?.session.seek(to: t) }
        addSubview(captionList)
        clipsToBounds = true           // the section never paints past the panel edge, whatever its content wants
        wireText()
        addSubview(shapeHost)
        shapeView.onKindChange = { [weak self] k in
            guard let self, let id = shapeClipID else { return }
            session.setShapeKind(k, for: id)
        }
        addSubview(matteHost)
        matteView.onGestureStart = { [weak self] in self?.matteGestureOpen = false }
        matteView.onColorChange = { [weak self] c in
            guard let self, let id = matteClipID else { return }
            session.setColorMatte(id, c, continuesGesture: matteGestureOpen)
            matteGestureOpen = true
        }
        addSubview(templateHost)
        addSubview(graphicHost)
        templateView.onSlotChange = { [weak self] slot, value, continues in
            guard let self, let id = templateClipID else { return }
            session.setTemplateSlot(slot, to: value, clip: id, continuesGesture: continues)
        }
        templateView.onZonesToggle = { [weak self] on in
            guard let self, let id = templateClipID else { return }
            session.setZonesEnabled(on, clip: id)
        }
        templateView.onMiddleChange = { [weak self] m in
            guard let self, let id = templateClipID else { return }
            session.setZoneMiddle(m, clip: id)
        }
        templateView.onHeightChange = { [weak self] in self?.needsLayout = true; self?.onHeightChange?() }
        graphicView.itemRows.onHeightChange = { [weak self] in self?.needsLayout = true; self?.onHeightChange?() }
        graphicView.onHeightChange = { [weak self] in self?.needsLayout = true; self?.onHeightChange?() }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Clip section")
        sync([.project, .selection])
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    // MARK: Session to UI

    public func sync(_ change: EditorSession.Change) {
        if change.contains(.playhead), mode == .captions { captionList.setPlayhead(session.playhead) }
        // Item values follow the playhead while it is moved by hand; during playback they wait for the stop.
        if mode == .graphic, !session.isPlaying, change.contains(.playhead) || change.contains(.transport) {
            graphicView.itemRows.refresh()
        }
        guard change.contains(.project) || change.contains(.selection) else { return }
        // Several text clips selected: the Text section shows the first and edits all (empty fields where they differ).
        let texts = session.selectedTextClips
        textMulti = !texts.isEmpty
        let clip = texts.first ?? session.displayedSelectedClip            // the text the Program monitor shows (W5.1 variant)
        pruneAudio()
        syncRoles()
        var new = ClipSectionMode.resolve(clip)
        // A caption is selected, or nothing is and the sequence has a caption track: All Captions closes the column.
        var captions: Timeline?
        if clip == nil, session.selection.isEmpty || !session.captionSelection.isEmpty,
           let tl = session.activeTimeline, !tl.captionTracks.isEmpty { new = .captions; captions = tl }
        var changed = new != mode
        if let tl = captions {
            if tl.captionTracks != listedCaptions || tl.frameDuration != listedFrame {
                listedCaptions = tl.captionTracks; listedFrame = tl.frameDuration
                let before = captionList.model.rows.count
                let drop = tl.frameDuration == Time(1001, 30000) || tl.frameDuration == Time(1001, 60000)
                captionList.setModel(CaptionListModel(timeline: tl, timecode: Timecode(frameDuration: tl.frameDuration, dropFrame: drop)))
                if captionList.model.rows.count != before { changed = true }
            }
            captionList.setPlayhead(session.playhead)
            captionList.setSelected(session.captionSelection)
            captionSummary = (session.currentCaptionTrack?.name ?? new.title, captionList.model.rows.count)
        } else {
            captionSummary = nil
        }
        switch new {
        case .captions: break
        case .text:
            _ = makeTextHost()
            if let clip { loadText(clip) }
        case .shape:
            shapeClipID = clip?.id
            if let k = clip?.generator?.shapeKind { shapeView.show(k) }
        case .matte:
            matteClipID = clip?.id
            if let c = clip?.matteColor { matteView.show(c) }
        case .template:
            templateClipID = clip?.id
            templateView.show(slots: clip?.templateSlots ?? [], zones: clip?.zones)
        case .graphic:
            if let clip { graphicView.show(clip) }
        case .audio:
            if let clip {
                let before = audioTrackID
                loadAudio(clip)
                changed = changed || before != audioTrackID
            }
        case .none: break
        }
        mode = new
        header.title = new.title
        header.isHidden = new == .text
        // The first section of the column carries no line above it.
        header.showsTopLine = !new.leads
        isHidden = new == .none
        applyCollapsed()
        needsLayout = true
        if changed { onHeightChange?() }
    }

    private func toggleCollapsed() {
        guard mode != .none, mode != .text else { return }
        if isCollapsed { collapsedModes.remove(mode.title) } else { collapsedModes.insert(mode.title) }
        applyCollapsed()
        needsLayout = true
        onHeightChange?()
    }

    /// The body shown for the current mode (nil: none, or a track that is gone).
    private var bodyHost: FitHost? {
        switch mode {
        case .none: nil
        case .text: textHost
        case .shape: shapeHost
        case .matte: matteHost
        case .template: templateHost
        case .graphic: graphicHost
        case .captions: nil                 // the caption list is framed directly (it scrolls by itself)
        case .audio: audioTrackID.flatMap { audioHosts[$0] }
        }
    }

    private func applyCollapsed() {
        let c = isCollapsed
        if header.isExpanded == c { header.isExpanded = !c }
        header.setAccessibilityLabel("\(mode.title) section, \(c ? "collapsed" : "expanded")")
        let shown = c ? nil : bodyHost
        for h in [textHost, shapeHost, matteHost, templateHost, graphicHost] + Array(audioHosts.values) {
            h?.isHidden = h !== shown
        }
        captionList.isHidden = c || mode != .captions
    }

    /// Height for `width`; 0 when no section applies.
    public func preferredHeight(for width: CGFloat) -> CGFloat {
        guard mode != .none else { return 0 }
        if isCollapsed { return headerHeight }
        if mode == .captions { return headerHeight + captionListHeight }
        return headerHeight + (bodyHost?.height(forWidth: width) ?? 0)
    }

    public override func layout() {
        super.layout()
        let y = headerHeight
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: y)
        if isCollapsed { return }
        if mode == .captions { captionList.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(bounds.height - y, 0)) }
        bodyHost?.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(bounds.height - y, 0))
    }

    // MARK: Looks (Appearance)

    /// The Look popup, its state ("edited") and Update / Save as New come from the session's Look model
    /// (`EditorSession+Looks`): the text clip's Look, built-in, the user's library or the project's.
    /// Saved title templates the Look popup also offers ("TikTok text": pick it and the selected text takes the template's
    /// style and in/out animation). id + name only; the host decodes the template on `onPickTemplate`.
    public var templateEntries: (() -> [(id: UUID, name: String)])?
    public var onPickTemplate: ((UUID) -> Void)?
    static let templateIDPrefix = "template:"

    private func wireLooks(_ block: TextBlockView) {
        block.lookSource = { [weak self] in
            guard let self else { return .init(titles: [], ids: [], selected: nil, pick: { _ in }, add: nil) }
            let entries = lookEntries
            let templates = templateEntries?() ?? []
            return .init(titles: entries.map(\.look.name) + templates.map { "\($0.name) (Template)" },
                         ids: entries.map(\.id) + templates.map { Self.templateIDPrefix + $0.id.uuidString },
                         selected: session.appliedLook()?.token,
                         pick: { [weak self] token in
                             guard let self else { return }
                             if token.hasPrefix(Self.templateIDPrefix) {
                                 if let id = UUID(uuidString: String(token.dropFirst(Self.templateIDPrefix.count))) { onPickTemplate?(id) }
                                 return
                             }
                             guard let e = lookEntries.first(where: { $0.id == token }) else { return }
                             session.applyLook(e.ref)
                         },
                         add: { [weak self] in self?.saveLookAsNew() })
        }
        block.lookStatus = { [weak self] in
            guard let self else { return nil }
            let token: String, edited: Bool
            switch session.lookState() {
            case .none: return nil
            case .applied(let t): token = t; edited = false
            case .edited(let t): token = t; edited = true
            }
            guard let e = lookEntries.first(where: { $0.id == token }) else { return nil }
            return .init(name: e.look.name, edited: edited, canUpdate: e.ref.scope != .builtIn)
        }
        block.onUpdateLook = { [weak self] in self?.updateLook() }
        block.onSaveLookAsNew = { [weak self] in self?.saveLookAsNew() }
        block.lookContext = { [weak self] in self?.lookMenuItems() ?? [] }
    }

    /// The Look the text carries (applied or edited).
    private var carriedLook: LookEntry? {
        let token: String
        switch session.lookState() {
        case .none: return nil
        case .applied(let t), .edited(let t): token = t
        }
        return lookEntries.first { $0.id == token }
    }

    private func updateLook() {
        guard let e = carriedLook else { return }
        _ = try? session.updateLook(e.ref)
        looksChanged()
    }

    /// Asks for a name; default is a prompt in the SQ design. Tests replace it.
    var askLookName: (_ title: String, _ initial: String) -> String? = { TextBlockView.promptLookName($0, $1) }

    private func saveLookAsNew() {
        let base = carriedLook?.look.name
        guard let name = askLookName("Save as New Look", base.map { "\($0) 2" } ?? "My Look") else { return }
        _ = try? session.saveLookAsNew(name: name)
        looksChanged()
    }

    /// Right-click on the Look popup: the one Look menu (`TextBlockView.lookMenuItems`).
    private func lookMenuItems() -> [SQMenuItem] {
        let saveNew: @MainActor () -> Void = { [weak self] in self?.saveLookAsNew() }
        guard let e = carriedLook, e.ref.scope != .builtIn else { return TextBlockView.lookMenuItems(editable: nil, saveNew: saveNew) }
        return TextBlockView.lookMenuItems(
            editable: e.look.name,
            update: { [weak self] in self?.updateLook() },
            saveNew: saveNew,
            rename: { [weak self] in
                guard let self, let name = askLookName("Rename Look", e.look.name) else { return }
                _ = try? session.renameLook(e.ref, to: name)
                looksChanged()
            },
            delete: { [weak self] in
                guard let self else { return }
                _ = try? session.deleteLook(e.ref)
                looksChanged()
            })
    }

    // The Look list is built once and kept until the Looks change: the user's library (`LookStore.didChange`) or the
    // project's (its Style Kit). The popup and the "edited" state read it on every edit of the text.
    private var lookList: [LookEntry]?
    /// How often the list was built (tests).
    private(set) var lookListBuilds = 0

    private var lookEntries: [LookEntry] {
        if let lookList { return lookList }
        let list = session.looks()
        lookList = list
        lookListBuilds += 1
        return list
    }

    /// A Look was saved, renamed, updated or deleted: the list is read again and the popup shows it.
    func looksChanged() {
        lookList = nil
        textBlock?.refreshLook()
    }

    // MARK: Text

    @objc private nonisolated func looksDidChange() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { textModel.reloadStyles(TextStyleStore.load()); looksChanged() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.textModel.reloadStyles(TextStyleStore.load()); self?.looksChanged() }
        }
    }

    private func wireText() {
        textModel.onBeginEditing = { [weak self] in self?.textGestureOpen = false }
        textModel.onChange = { [weak self] style, anims in
            guard let self, let id = textClipID, let old = textTemplate else { return }
            var t = old
            t.style = style
            textTemplate = t
            sendText(id, from: old, to: t, animations: anims, forcing: textModel.pendingForcedPaths)
        }
        textModel.onEndEditing = { [weak self] in self?.textGestureOpen = false }
        textModel.onAlignToFrame = { [weak self] a in self?.onAlignToFrame?(a) }
        textModel.onStylesChanged = { try? TextStyleStore.save($0) }
        // The panel edits a copy of the Look library: take the store's Looks again whenever it changes (a save from
        // here, a caption Look saved elsewhere), so the copy never goes stale.
        NotificationCenter.default.addObserver(self, selector: #selector(looksDidChange), name: LookStore.didChange, object: LookStore.shared)
    }

    /// Drops the audio inspectors of tracks that no longer exist (their ids could come back with other settings).
    private func pruneAudio() {
        let live = Set(session.activeTimeline?.tracks.map(\.id) ?? [])
        for id in Array(audioHosts.keys) where !live.contains(id) {
            audioHosts[id]?.removeFromSuperview()
            audioHosts[id] = nil; audioModels[id] = nil; audioPresets[id] = nil
        }
        if let id = audioTrackID, !live.contains(id) { audioTrackID = nil }
    }

    private func loadText(_ clip: Clip) {
        guard let ref = clip.generator, let (t, anims) = try? TextGenerator.decode(ref) else {
            textClipID = nil; textTemplate = nil; textModel.target = nil; textBlock?.text = ""      // undecodable: never edit the previous clip
            return
        }
        let changedClip = textClipID != clip.id
        textClipID = clip.id
        textModel.target = clip.id
        // The project's Looks live in its Style Kit: a change of the kit makes the Look list stale.
        if textModel.kit != session.project.styleKit { textModel.kit = session.project.styleKit; lookList = nil }
        textModel.frameSize = AnimationChoices.frameSize(session.displayFormat)
        textModel.clipDuration = clip.duration
        // The animations also change without the template (a Custom side keyed in the rows below, undo).
        let set = anims ?? AnimationSet(in: nil, out: nil)
        if t != textTemplate || changedClip {
            textTemplate = t
            textModel.load(style: t.style, animations: set)
        } else {
            textModel.adopt(animations: set)    // only the animations moved: an open edit session of the block stays open
        }
        textAnimations = anims
        let mixed = textMulti ? session.textMixedPaths : []
        if textModel.mixedPaths != mixed { textModel.mixedPaths = mixed }
        let shown = mixed.contains("text") ? "" : t.text
        if textBlock?.text != shown { textBlock?.text = shown }     // ignored while the user types in the box
    }

    private func textTyped(_ str: String) {
        guard let id = textClipID, let old = textTemplate, old.text != str || textModel.mixedPaths.contains("text") else { return }
        var t = old
        t.text = str
        textTemplate = t
        sendText(id, from: old, to: t, animations: textModel.animations)
    }

    private func sendText(_ id: Clip.ID, from old: TextTemplate, to t: TextTemplate, animations: AnimationSet,
                          forcing: Set<String> = []) {
        if textMulti {
            session.updateTextClips(primary: id, from: old, to: t, animations: animations, oldAnimations: textAnimations,
                                    continuesGesture: textGestureOpen, forcing: forcing)
        } else {
            session.updateTextClip(id, template: t, animations: animations, continuesGesture: textGestureOpen)
        }
        textAnimations = animations
        textGestureOpen = true
    }

    // MARK: Audio

    private func loadAudio(_ clip: Clip) {
        guard let track = session.activeTimeline?.tracks.first(where: { $0.clips.contains { $0.id == clip.id } }) else {
            audioTrackID = nil
            return
        }
        audioTrackID = track.id
        if audioHosts[track.id] == nil {
            let model = TrackAudioInspectorModel(preset: audioPresets[track.id], role: track.audioRole)
            model.onChange = { [weak self] preset in
                self?.audioPresets[track.id] = preset
                self?.onAudioPresetChange?(track.id, preset)
            }
            model.onRoleChange = { [weak self] role in
                guard let self else { return }
                self.clearExplicitPreset(track.id)
                self.session.setTrackAudioRole(track.id, role: role)
            }
            let view = TrackAudioInspectorView(model: model)
            view.note = "The role is saved with the project and applies in playback and export. Preset tweaks apply during playback only."
            audioModels[track.id] = model
            let host = FitHost(content: view)
            audioHosts[track.id] = host
            addSubview(host)
        }
    }

    /// Roles changed outside the popup (undo/redo): every inspector follows, and the role wins over any explicit preset.
    private func syncRoles() {
        guard let tracks = session.activeTimeline?.tracks else { return }
        for tr in tracks {
            guard let model = audioModels[tr.id], model.role != tr.audioRole else { continue }
            clearExplicitPreset(tr.id)
            model.syncRole(tr.audioRole)
        }
    }

    private func clearExplicitPreset(_ id: Track.ID) {
        guard audioPresets[id] != nil else { return }
        audioPresets[id] = nil
        onAudioPresetChange?(id, nil)
    }
}
