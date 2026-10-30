import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQEditorSession
import SQAudioFX
import SQText
import SQUIKit
import SQDrawKit
import SQLibrary

/// The clip's content section of Controls on the shared toolkit: `ClipSectionsView` translated. The mode rules
/// (`ClipSectionMode.resolve`, the caption fallback), the per-track audio models, role sync and the collapse per mode
/// are the Mac code; the bodies are drawn here: Text (`TextBlockDraw`, its Arrange and Animation slots placed by the
/// panel around Transform), Audio (`TrackAudioDraw`), Shape (kind buttons and the hint) and Color Matte (swatch and hex). The Effect Controls panel places it before Transform (`mode.leads`) or after every effect.
/// Coordinates: points, y down, (0, 0) = the section's top-left.
@MainActor public final class ClipSectionsDraw {
    public let session: EditorSession
    public var theme = DrawTheme() {
        didSet { for a in audio.values { a.theme = theme }; textBlock.theme = theme; template.theme = theme; itemRows.theme = theme }
    }
    public var width: CGFloat = 320 {
        didSet { for a in audio.values { a.width = width }; textBlock.width = width; template.width = width; itemRows.width = width }
    }
    public private(set) var mode: ClipSectionMode = .none
    /// Track audio preset chosen here, by track (forwarded to the engine through `onAudioPresetChange`).
    public private(set) var audioPresets: [Track.ID: TrackAudioPreset] = [:]
    public var onAudioPresetChange: ((Track.ID, TrackAudioPreset?) -> Void)?
    /// The section's height changed: the panel re-lays out.
    public var onHeightChange: (() -> Void)?
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)? {
        didSet {
            for a in audio.values { a.onMenu = onMenu }
            template.onMenu = { [weak self] items, anchor in self?.onMenu?(items, anchor.offsetBy(dx: 0, dy: self?.headerHeight ?? 0)) }
            itemRows.onMenu = { [weak self] items, anchor in self?.onMenu?(items, anchor.offsetBy(dx: 0, dy: self?.itemsTop ?? 0)) }
        }
    }
    /// The swatch was clicked: the host opens its color picker (same hook as the panel's color wells).
    public var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                         _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// Arrange buttons of the text clip: the host moves the clip in the frame (`TextFrameAlign`).
    public var onAlignToFrame: ((FrameAlignment) -> Void)?
    /// The window's Library keystones: the saved animations of the Intro / Outro popups.
    public weak var keystones: (any AnimationKeystoneSource)? { didSet { textModel.keystones = keystones } }
    /// Where the text block's Arrange and Animation parts sit relative to the section's top (set by the panel), so
    /// their menus and color picker anchor in section coordinates like the body's.
    public var slotOffset: ((TextBlockDraw.Part) -> CGFloat)?
    /// Asks for a name (Save as New Look, Rename, Save Animation) and answers through `done` (nil = canceled); nil =
    /// the suggested name is taken.
    public var askName: (@MainActor (_ title: String, _ initial: String, _ done: @escaping @MainActor (String?) -> Void) -> Void)? {
        didSet { textBlock.askName = askName }
    }
    /// Saved title templates the Look popup also offers as "<name> (Template)" (ClipSectionsView.templateEntries);
    /// picking one calls `onPickTemplate`, the host applies its style and animation.
    public var templateEntries: (() -> [(id: UUID, name: String)])?
    public var onPickTemplate: ((UUID) -> Void)?
    /// A status line (an animation that could not be saved).
    public var onNotice: ((String) -> Void)? { didSet { textBlock.onNotice = onNotice } }

    static let headerHeight = ControlsGrid.headerHeight
    private var collapsedModes: Set<String> = []
    var isCollapsed: Bool { mode != .text && collapsedModes.contains(mode.title) }
    private var headerHeight: CGFloat { mode == .text ? 0 : Self.headerHeight }

    private(set) var audio: [Track.ID: TrackAudioDraw] = [:]
    private(set) var audioTrackID: Track.ID?
    private var shapeClipID: Clip.ID?
    private(set) var shapeKind: ShapeKind = .rectangle
    private var matteClipID: Clip.ID?
    private(set) var matteColor = ColorMatteColor.default
    private var matteGestureOpen = false

    /// The text clip's block: one model for the column (ClipSectionsView.textModel).
    public let textModel = TextInspectorModel(styles: TextStyleStore.load())
    public private(set) lazy var textBlock = makeTextBlock()
    private var textClipID: Clip.ID?
    private var textTemplate: TextTemplate?
    private var textAnimations: AnimationSet?
    private var textGestureOpen = false
    private var textMulti = false
    private var lookList: [LookEntry]?
    nonisolated(unsafe) private var lookObserver: NSObjectProtocol?

    public init(session: EditorSession) {
        self.session = session
        wireText()
        wireTemplate()
        wireItemRows()
        sync([.project, .selection])
    }

    deinit { if let lookObserver { NotificationCenter.default.removeObserver(lookObserver) } }

    // MARK: Session to UI (ClipSectionsView.sync)

    public func sync(_ change: EditorSession.Change) {
        if change.contains(.playhead), mode == .captions { captionList.setPlayhead(session.playhead) }
        guard change.contains(.project) || change.contains(.selection) else { return }
        let texts = session.selectedTextClips
        let clip = texts.first ?? session.displayedSelectedClip
        textMulti = !texts.isEmpty
        pruneAudio()
        syncRoles()
        let new = ClipSectionMode.resolve(clip)
        let captions: Timeline? = nil
        // Captions live only in the Captions tab; Controls never lists them (the maintainer, 2026-10-30).
        // The Mac ClipSectionsView still does; this shared column does not.
        var changed = new != mode
        if let tl = captions {
            if tl.captionTracks != listedCaptions || tl.frameDuration != listedFrame {
                listedCaptions = tl.captionTracks; listedFrame = tl.frameDuration
                let before = captionList.model.rows.count
                let drop = tl.frameDuration == Time(1001, 30000) || tl.frameDuration == Time(1001, 60000)
                _ = captionList.setModel(CaptionListModel(timeline: tl, timecode: Timecode(frameDuration: tl.frameDuration, dropFrame: drop)))
                if captionList.model.rows.count != before { changed = true }
            }
            captionList.setPlayhead(session.playhead)
            captionList.setSelected(session.captionSelection)
            captionSummary = (session.currentCaptionTrack?.name ?? new.title, captionList.model.rows.count)
        } else {
            captionSummary = nil
        }
        switch new {
        case .shape:
            shapeClipID = clip?.id
            if let k = clip?.generator?.shapeKind { shapeKind = k }
        case .matte:
            matteClipID = clip?.id
            if let c = clip?.matteColor { matteColor = c }
        case .audio:
            if let clip {
                let before = audioTrackID
                loadAudio(clip)
                changed = changed || before != audioTrackID
            }
        case .text:
            if let clip {
                let before = textBlock.height(.text)
                loadText(clip)
                changed = changed || before != textBlock.height(.text)
            }
        case .template:
            templateClipID = clip?.id
            changed = template.show(slots: clip?.templateSlots ?? [], zones: clip?.zones) || changed
        case .graphic:
            let before = graphicPicker.isEmpty
            graphicClip = clip
            graphicPicker = clip?.graphics?.itemPickerEntries ?? []
            changed = changed || before != graphicPicker.isEmpty
            itemRows.editor?.sync()       // gone items leave the selection even while the Graphics panel is hidden
            changed = itemRows.sync() || changed
        case .none, .captions: break
        }
        if mode == .graphic, new != .graphic { itemRows.resignFocus() }
        mode = new
        if changed { onHeightChange?() }
    }

    private func pruneAudio() {
        let live = Set(session.activeTimeline?.tracks.map(\.id) ?? [])
        for id in Array(audio.keys) where !live.contains(id) { audio[id] = nil; audioPresets[id] = nil }
        if let id = audioTrackID, !live.contains(id) { audioTrackID = nil }
    }

    private func loadAudio(_ clip: Clip) {
        guard let track = session.activeTimeline?.tracks.first(where: { $0.clips.contains { $0.id == clip.id } }) else {
            audioTrackID = nil
            return
        }
        audioTrackID = track.id
        guard audio[track.id] == nil else { return }
        let model = TrackAudioInspectorModel(preset: audioPresets[track.id], role: track.audioRole)
        model.onChange = { [weak self] preset in
            self?.audioPresets[track.id] = preset
            self?.onAudioPresetChange?(track.id, preset)
        }
        model.onRoleChange = { [weak self] role in
            guard let self else { return }
            clearExplicitPreset(track.id)
            session.setTrackAudioRole(track.id, role: role)
        }
        let block = TrackAudioDraw(model: model)
        block.note = "The role is saved with the project and applies in playback and export. Preset tweaks apply during playback only."
        block.theme = theme; block.width = width; block.onMenu = onMenu
        audio[track.id] = block
    }

    private func syncRoles() {
        guard let tracks = session.activeTimeline?.tracks else { return }
        for tr in tracks {
            guard let model = audio[tr.id]?.model, model.role != tr.audioRole else { continue }
            clearExplicitPreset(tr.id)
            model.syncRole(tr.audioRole)
        }
    }

    private func clearExplicitPreset(_ id: Track.ID) {
        guard audioPresets[id] != nil else { return }
        audioPresets[id] = nil
        onAudioPresetChange?(id, nil)
    }

    var audioBlock: TrackAudioDraw? { audioTrackID.flatMap { audio[$0] } }

    // MARK: Template (ClipSectionsView templateView)

    /// Slots and zones of an applied title template.
    let template = TemplateSlotsDraw()
    private var templateClipID: Clip.ID?

    private func wireTemplate() {
        template.fontFamilies = { [weak self] in self?.textModel.fontFamilies ?? [] }
        template.onSlotChange = { [weak self] slot, value, continues in
            guard let self, let id = templateClipID else { return }
            session.setTemplateSlot(slot, to: value, clip: id, continuesGesture: continues)
        }
        template.onZonesToggle = { [weak self] on in
            guard let self, let id = templateClipID else { return }
            session.setZonesEnabled(on, clip: id)
        }
        template.onMiddleChange = { [weak self] m in
            guard let self, let id = templateClipID else { return }
            session.setZoneMiddle(m, clip: id)
        }
        template.onPickColor = { [weak self] color, anchor, change in
            guard let self else { return }
            onPickColor?(color, anchor.offsetBy(dx: 0, dy: headerHeight), change)
        }
    }
    private func inBody(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - headerHeight) }

    // MARK: Graphic (GraphicSectionView)

    /// "Edit in Graphics": the host brings its Graphics panel to the front; nil = no such panel (the button is dimmed).
    public var onEditGraphics: (() -> Void)?
    /// The item picker changed the shared item selection (`session.graphicLayerSelection`, which posts no change): the
    /// host syncs Controls so it shows the picked item (or the whole graphic) again.
    public var onGraphicItemChange: (() -> Void)?
    private(set) var graphicClip: Clip?
    /// The item picker: "Whole graphic" and the items front first; hidden when the graphic has no items to pick.
    private(set) var graphicPicker: [(id: UUID, name: String)] = []
    private var graphicRows: Int { graphicPicker.isEmpty ? 1 : 2 }
    /// The selected items' basics under the picker (`GraphicItemRows`): text box, Corners, Fill, Outline.
    let itemRows = GraphicItemRowsDraw()
    /// The app's one Graphics editor (shared with the Graphics panel): the item rows edit its selected items.
    public var graphicsEditor: GraphicsEditor? {
        get { itemRows.editor }
        set { itemRows.editor = newValue; graphicItemsChanged() }
    }
    var itemsTop: CGFloat { headerHeight + CGFloat(graphicRows) * ControlsGrid.rowHeight }

    /// The item selection changed (it is not a session change): the item rows follow (ClipSectionsView.graphicItemsChanged).
    public func graphicItemsChanged() {
        guard mode == .graphic, itemRows.sync() else { return }
        onHeightChange?()
    }

    private func wireItemRows() {
        itemRows.onPickColor = { [weak self] color, anchor, change in
            guard let self else { return }
            onPickColor?(color, anchor.offsetBy(dx: 0, dy: itemsTop), change)
        }
    }
    private func inItems(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - itemsTop) }
    static let pickerWidth: CGFloat = 160, editButtonWidth: CGFloat = 120

    func graphicFrame(_ h: Hit) -> CGRect? {
        let ch = ControlsGrid.controlHeight, inset = ((ControlsGrid.rowHeight - ch) / 2).rounded()
        switch h {
        case .layerPicker where !graphicPicker.isEmpty:
            return CGRect(x: ControlsGrid.valueX, y: headerHeight + inset, width: Self.pickerWidth, height: ch)
        case .editGraphics:
            let y = headerHeight + CGFloat(graphicRows - 1) * ControlsGrid.rowHeight + inset
            return CGRect(x: ControlsGrid.valueX, y: y, width: Self.editButtonWidth, height: ch)
        default: return nil
        }
    }

    /// The item Controls shows (one picked item) or nil for the whole graphic: follows the shared item selection.
    var pickedItem: UUID? {
        guard let c = graphicClip, let sel = session.graphicLayerSelection, sel.clip == c.id else { return nil }
        return c.graphics?.shownItem(selection: sel.layers)
    }

    private func layerMenu() -> [SQMenuItem] {
        guard let c = graphicClip else { return [] }
        let picked = pickedItem
        let whole = SQMenuItem(title: "Whole graphic", isChecked: picked == nil) { [weak self] in
            self?.session.graphicLayerSelection = nil
            self?.onGraphicItemChange?()
        }
        return [whole] + graphicPicker.map { e in
            SQMenuItem(title: e.name, isChecked: e.id == picked) { [weak self] in
                self?.session.graphicLayerSelection = GraphicLayerSelection(clip: c.id, layers: [e.id])
                self?.onGraphicItemChange?()
            }
        }
    }

    // MARK: All Captions (ClipSectionsView captionList)

    /// A caption is selected, or nothing is and the sequence has a caption track: every caption of the sequence, read
    /// only, the one at the playhead marked; a click seeks. It scrolls by itself inside `availableHeight`.
    private(set) var captionList = CaptionListDraw()
    /// Name of the caption track in focus and the number of captions listed (the Controls header).
    public private(set) var captionSummary: (name: String, count: Int)?
    private var listedCaptions: [CaptionTrack] = []
    private var listedFrame: Time?
    /// Height of the column the host shows; the caption list takes what is left of it under its header.
    public var availableHeight: CGFloat = 0 {
        didSet { if oldValue != availableHeight, mode == .captions { captionList.clampScroll(height: captionListHeight) } }
    }
    static let captionRowsWithoutHost = 12, captionRowsAtLeast = 3
    var captionListHeight: CGFloat {
        let row = CaptionListDraw.rowHeight
        let room = availableHeight > 0 ? availableHeight - headerHeight : CGFloat(Self.captionRowsWithoutHost) * row
        return min(captionList.contentHeight, max(room, CGFloat(Self.captionRowsAtLeast) * row))
    }
    private func inCaptions(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - headerHeight) }

    /// The wheel over the section at `p` (section coordinates): the caption list scrolls first; false = not used.
    public func scroll(at p: CGPoint, dy: CGFloat) -> Bool {
        if hit(p) == .items { return itemRows.scroll(at: inItems(p), dy: dy, precise: true, modifiers: []) }
        guard case .caption = hit(p) else { return false }
        let used = captionList.scroll(dy: dy, height: captionListHeight)
        if used { captionList.hovered = captionList.row(at: inCaptions(p), height: captionListHeight) }
        return used
    }

    // MARK: Text (ClipSectionsView wireText / loadText / sendText / wireLooks)

    private func makeTextBlock() -> TextBlockDraw {
        let b = TextBlockDraw(model: textModel)
        b.theme = theme; b.width = width
        b.showsLookGallery = true      // the clip context's Look gallery (TextBlockView .clip)
        b.onHeightChange = { [weak self] in self?.onHeightChange?() }
        b.onMenu = { [weak self] items, anchor, part in
            guard let self else { return }
            onMenu?(items, anchor.offsetBy(dx: 0, dy: offset(part)))
        }
        b.onPickColor = { [weak self] color, anchor, part, change in
            guard let self else { return }
            onPickColor?(color, anchor.offsetBy(dx: 0, dy: offset(part)), change)
        }
        b.onTextChange = { [weak self] s in self?.textTyped(s) }
        b.onTextEnd = { [weak self] in self?.textGestureOpen = false }
        b.onTextBegin = { [weak self] in self?.textGestureOpen = false }
        wireLooks(b)
        return b
    }

    private func offset(_ part: TextBlockDraw.Part) -> CGFloat { part == .text ? 0 : slotOffset?(part) ?? 0 }

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
        // The block edits a copy of the Look library: take the store's Looks again whenever it changes.
        lookObserver = NotificationCenter.default.addObserver(forName: LookStore.didChange, object: LookStore.shared,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.textModel.reloadStyles(TextStyleStore.load())
                self.lookList = nil
            }
        }
    }

    private func loadText(_ clip: Clip) {
        guard let ref = clip.generator, let (t, anims) = try? TextGenerator.decode(ref) else {
            textClipID = nil; textTemplate = nil; textModel.target = nil; textBlock.text = ""   // undecodable: never edit the previous clip
            return
        }
        let changedClip = textClipID != clip.id
        textClipID = clip.id
        textModel.target = clip.id
        // The project's Looks live in its Style Kit: a change of the kit makes the Look list stale.
        if textModel.kit != session.project.styleKit { textModel.kit = session.project.styleKit; lookList = nil }
        textModel.frameSize = AnimationChoices.frameSize(session.displayFormat)
        textModel.clipDuration = clip.duration
        let set = anims ?? AnimationSet(in: nil, out: nil)
        if t != textTemplate || changedClip {
            textTemplate = t
            textModel.load(style: t.style, animations: set)
        } else {
            textModel.adopt(animations: set)    // only the animations moved: an open edit session stays open
        }
        textAnimations = anims
        let mixed = textMulti ? session.textMixedPaths : []
        if textModel.mixedPaths != mixed { textModel.mixedPaths = mixed }
        let shown = mixed.contains("text") ? "" : t.text
        if textBlock.text != shown { textBlock.text = shown }     // ignored while the user types in the box
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

    // The Look list is built once and kept until the Looks change (LookStore.didChange, the project's Style Kit).
    private var lookEntries: [LookEntry] {
        if let lookList { return lookList }
        let list = session.looks()
        lookList = list
        return list
    }

    private var carriedLook: LookEntry? {
        switch session.lookState() {
        case .none: return nil
        case .applied(let t), .edited(let t): return lookEntries.first { $0.id == t }
        }
    }

    private func wireLooks(_ b: TextBlockDraw) {
        b.lookSource = { [weak self] in
            guard let self else { return .init(titles: [], ids: [], selected: nil, pick: { _ in }, add: nil) }
            let entries = lookEntries
            let templates = templateEntries?() ?? []
            return .init(titles: entries.map(\.look.name) + templates.map { TextAnimatorChoices.templateTitle($0.name) },
                         ids: entries.map(\.id) + templates.map { TextAnimatorChoices.templateIDPrefix + $0.id.uuidString },
                         selected: session.appliedLook()?.token,
                         pick: { [weak self] token in
                             guard let self else { return }
                             if let id = TextAnimatorChoices.templateID(token) { onPickTemplate?(id); return }
                             guard let e = lookEntries.first(where: { $0.id == token }) else { return }
                             session.applyLook(e.ref)
                         },
                         add: { [weak self] in self?.saveLookAsNew() })
        }
        b.lookContext = { [weak self] in self?.lookMenuItems() ?? [] }
        b.lookStatus = { [weak self] in
            guard let self else { return nil }
            let edited: Bool
            switch session.lookState() {
            case .none: return nil
            case .applied: edited = false
            case .edited: edited = true
            }
            guard let e = carriedLook else { return nil }
            return .init(name: e.look.name, edited: edited, canUpdate: e.ref.scope != .builtIn)
        }
        b.onUpdateLook = { [weak self] in
            guard let self, let e = carriedLook else { return }
            _ = try? session.updateLook(e.ref)
            lookList = nil
        }
        b.onSaveLookAsNew = { [weak self] in self?.saveLookAsNew() }
    }

    // MARK: Title templates in the Look popup

    private var templates: [PresetItem] = []
    private var loadingTemplates = false

    /// Lists the saved title templates of `store` in the Look popup and applies a picked one's style and animation to
    /// the selected text (EditorPanels.wireSidePanels on the Mac). The list is read in the background each time the
    /// popup opens; it shows the last list read.
    public func useTemplates(from store: PresetStore) {
        let reload: @MainActor () -> Void = { [weak self] in
            guard let self, !loadingTemplates else { return }
            loadingTemplates = true
            Task { @MainActor [weak self] in
                let list = await store.presets(kind: .titleTemplate)
                self?.templates = list
                self?.loadingTemplates = false
            }
        }
        templateEntries = { [weak self] in
            reload()
            return self?.templates.map { ($0.id, $0.name) } ?? []
        }
        onPickTemplate = { [weak self] id in
            guard let self else { return }
            guard let item = templates.first(where: { $0.id == id }), let preset = try? TitleTemplatePreset(preset: item) else {
                onNotice?("The template could not be read."); return
            }
            if !session.applyTemplateStyle(preset.template) {
                onNotice?(session.lastError ?? "The template has no text layer to take the style from.")
            }
        }
        reload()
    }

    private func saveLookAsNew() {
        let base = carriedLook?.look.name
        textBlock.name("Save as New Look", base.map { "\($0) 2" } ?? "My Look") { [weak self] name in
            guard let self else { return }
            _ = try? session.saveLookAsNew(name: name)
            looksChanged()
        }
    }

    /// A Look was saved, renamed, updated or deleted: the list is read again.
    private func looksChanged() {
        lookList = nil
        onHeightChange?()
    }

    /// Right-click on the Look popup: the one Look menu (ClipSectionsView.lookMenuItems).
    func lookMenuItems() -> [SQMenuItem] {
        let saveNew: @MainActor () -> Void = { [weak self] in self?.saveLookAsNew() }
        guard let e = carriedLook, e.ref.scope != .builtIn else { return TextAnimatorChoices.lookMenuItems(editable: nil, saveNew: saveNew) }
        return TextAnimatorChoices.lookMenuItems(
            editable: e.look.name,
            update: { [weak self] in
                guard let self else { return }
                _ = try? session.updateLook(e.ref)
                looksChanged()
            },
            saveNew: saveNew,
            rename: { [weak self] in
                guard let self else { return }
                textBlock.name("Rename Look", e.look.name) { [weak self] name in
                    guard let self else { return }
                    _ = try? session.renameLook(e.ref, to: name)
                    looksChanged()
                }
            },
            delete: { [weak self] in
                guard let self else { return }
                _ = try? session.deleteLook(e.ref)
                looksChanged()
            })
    }

    // MARK: Layout

    private var bodyHeight: CGFloat {
        switch mode {
        case .none: 0
        case .audio: audioBlock?.height ?? 0
        case .text: textBlock.height(.text)
        case .shape: 2 * ControlsGrid.rowHeight
        case .matte: ControlsGrid.rowHeight
        case .captions: captionListHeight
        case .template: template.height
        case .graphic: CGFloat(graphicRows) * ControlsGrid.rowHeight + itemRows.height
        }
    }

    /// The text clip's Arrange part (closes Transform) and Animation section (after Transform); 0 for other clips.
    public var transformTailHeight: CGFloat { mode == .text ? textBlock.height(.arrange) : 0 }
    public var afterTransformHeight: CGFloat { mode == .text ? textBlock.height(.animation) : 0 }

    /// Height for the current width; 0 when no section applies.
    public var height: CGFloat {
        guard mode != .none else { return 0 }
        return isCollapsed ? headerHeight : headerHeight + bodyHeight
    }

    static let kindButton: CGFloat = 32
    func kindFrame(_ i: Int) -> CGRect {
        CGRect(x: ControlsGrid.valueX + CGFloat(i) * Self.kindButton, y: headerHeight + ((ControlsGrid.rowHeight - 22) / 2).rounded(),
               width: Self.kindButton, height: 22)
    }
    var wellFrame: CGRect {
        CGRect(x: ControlsGrid.valueX, y: headerHeight + ((ControlsGrid.rowHeight - 18) / 2).rounded(), width: 44, height: 18)
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        guard mode != .none else { return }
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height), t.panel)
        if headerHeight > 0 {
            let h = headerHeight
            // The first section of the column carries no line above it (a leading section).
            if !mode.leads { c.fill(CGRect(x: 0, y: 0, width: width, height: 1), t.separator) }
            InspectorDraw.chevron(&c, in: CGRect(x: ControlsGrid.headerToggleX, y: 0, width: 12, height: h),
                                  direction: isCollapsed ? .right : .down, t.label3, size: 8)
            c.draw(SQL10n.string(mode.title), in: CGRect(x: ControlsGrid.headerLabelX, y: 0, width: max(width - ControlsGrid.headerLabelX, 0), height: h),
                   fontSize: fs, t.label)
            c.fill(CGRect(x: 0, y: h - 1, width: width, height: 1), t.trackRowLine)
        }
        if !isCollapsed { drawBody(&c) }
        c.restoreGState()
    }

    private func label(_ c: inout Canvas, _ s: String, y: CGFloat) {
        c.draw(SQL10n.string(s), in: CGRect(x: ControlsGrid.labelX, y: y, width: ControlsGrid.valueX - ControlsGrid.labelX - ControlsGrid.gap,
                                            height: ControlsGrid.rowHeight), fontSize: CGFloat(DrawTheme.TypeSize.body), theme.label2)
    }

    private func drawBody(_ c: inout Canvas) {
        let t = theme, y = headerHeight, fs = CGFloat(DrawTheme.TypeSize.body)
        switch mode {
        case .audio:
            guard let b = audioBlock else { return }
            c.saveGState(); c.translateBy(x: 0, y: y); b.draw(&c); c.restoreGState()
        case .shape:
            label(&c, "Shape", y: y)
            for (i, k) in ShapeKind.allCases.enumerated() {
                let f = kindFrame(i), on = k == shapeKind
                if on || hover == .kind(i) { c.fill(roundedRect: f.insetBy(dx: 1, dy: 0), radius: CGFloat(DrawTheme.Radius.small), on ? t.fillPressed : t.fillHover) }
                c.draw(icon: Self.symbol(k), at: CGPoint(x: f.midX - 6, y: f.midY - 6), size: 12, on ? t.label : t.label2)
            }
            c.draw(SQL10n.string("Size and colors: Shape effect below"),
                   in: CGRect(x: ControlsGrid.valueX, y: y + ControlsGrid.rowHeight, width: max(width - ControlsGrid.valueX - ControlsGrid.trailing, 0),
                              height: ControlsGrid.rowHeight), fontSize: fs, t.label3)
        case .matte:
            label(&c, "Color", y: y)
            let m = matteColor
            InspectorDraw.colorWell(&c, DrawColor(Float(m.r) / 255, Float(m.g) / 255, Float(m.b) / 255), in: wellFrame,
                                    hovering: hover == .well, t)
            c.draw(Self.hexString(m), in: CGRect(x: wellFrame.maxX + ControlsGrid.gap, y: y, width: 80, height: ControlsGrid.rowHeight),
                   fontSize: fs, t.label2)
        case .text:
            c.saveGState(); c.translateBy(x: 0, y: y); textBlock.draw(&c, part: .text); c.restoreGState()
        case .captions:
            c.saveGState(); c.translateBy(x: 0, y: y)
            captionList.draw(&c, width: width, height: captionListHeight, theme: t)
            c.restoreGState()
        case .template:
            c.saveGState(); c.translateBy(x: 0, y: y); template.draw(&c); c.restoreGState()
        case .graphic:
            if let f = graphicFrame(.layerPicker) {
                label(&c, "Layer", y: y)
                let title = pickedItem.flatMap { id in graphicPicker.first { $0.id == id }?.name } ?? SQL10n.string("Whole graphic")
                InspectorDraw.popup(&c, title: title, in: f, hovering: hover == .layerPicker, open: false, enabled: true, t)
            }
            if let f = graphicFrame(.editGraphics) {
                label(&c, graphicClip.map(ClipSectionMode.layerSummary) ?? "", y: f.minY - ((ControlsGrid.rowHeight - f.height) / 2).rounded())
                InspectorDraw.button(&c, title: SQL10n.string("Edit in Graphics"), in: f, hovering: hover == .editGraphics,
                                     pressed: pressed == .editGraphics, enabled: onEditGraphics != nil, t)
            }
            c.saveGState(); c.translateBy(x: 0, y: itemsTop); itemRows.draw(&c); c.restoreGState()
        case .none: break
        }
    }

    static func symbol(_ k: ShapeKind) -> SQIcon {
        switch k {
        case .rectangle: .shapeRectangle
        case .ellipse: .shapeEllipse
        case .line: .shapeLine
        case .arrow: .arrowRight
        }
    }

    static func hexString(_ c: ColorMatteColor) -> String { String(format: "#%02X%02X%02X", c.r, c.g, c.b) }

    // MARK: Pointer and keys

    enum Hit: Equatable { case header, kind(Int), well, audio, text, template, layerPicker, editGraphics, items, caption(Int?), none }
    private(set) var hover: Hit = .none
    private var pressed: Hit = .none

    func hit(_ p: CGPoint) -> Hit {
        guard mode != .none, p.y >= 0, p.y < height else { return .none }
        if p.y < headerHeight { return .header }
        if isCollapsed { return .none }
        switch mode {
        case .audio: return .audio
        case .text: return .text
        case .shape: return ShapeKind.allCases.indices.first { kindFrame($0).contains(p) }.map { .kind($0) } ?? .none
        case .matte: return wellFrame.contains(p) ? .well : .none
        case .template: return .template
        case .graphic:
            if p.y >= itemsTop { return .items }
            return [Hit.layerPicker, .editGraphics].first { graphicFrame($0)?.contains(p) == true } ?? .none
        case .captions: return .caption(captionList.row(at: inCaptions(p), height: captionListHeight))
        default: return .none
        }
    }

    private func inAudio(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - headerHeight) }

    public func mouseMoved(to p: CGPoint?) {
        hover = p.map(hit) ?? .none
        if case .caption(let i) = hover { captionList.hovered = i } else { captionList.hovered = nil }
        audioBlock?.mouseMoved(to: hover == .audio ? p.map(inAudio) : nil)
        if mode == .text { textBlock.mouseMoved(to: hover == .text ? p : nil, part: .text) }
        if mode == .template { template.mouseMoved(to: hover == .template ? p.map(inBody) : nil) }
        if mode == .graphic { itemRows.mouseMoved(to: hover == .items ? p.map(inItems) : nil) }
    }

    public func mouseDown(at p: CGPoint, clickCount: Int) {
        pressed = hit(p)
        if pressed == .layerPicker, let f = graphicFrame(.layerPicker) {
            pressed = .none
            onMenu?(layerMenu(), f)
            return
        }
        if pressed == .audio { audioBlock?.mouseDown(at: inAudio(p), clickCount: clickCount) } else { audioBlock?.resignFocus() }
        if pressed == .text { textBlock.mouseDown(at: p, part: .text, clickCount: clickCount) } else if mode == .text { textBlock.resignFocus() }
        if pressed == .template { template.mouseDown(at: inBody(p), clickCount: clickCount) } else if mode == .template { template.resignFocus() }
        if pressed == .items { itemRows.mouseDown(at: inItems(p), clickCount: clickCount) } else if mode == .graphic { itemRows.resignFocus() }
    }

    /// A right click at `p`: true when a part here showed its own menu (the text clip's Look popup).
    public func contextMenu(at p: CGPoint) -> Bool {
        hit(p) == .text && textBlock.contextMenu(at: p, part: .text)
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        if pressed == .audio { audioBlock?.mouseDragged(to: inAudio(p), modifiers: modifiers) }
        if pressed == .text { textBlock.mouseDragged(to: p, part: .text, modifiers: modifiers) }
        if pressed == .template { template.mouseDragged(to: inBody(p), modifiers: modifiers) }
        if pressed == .items { itemRows.mouseDragged(to: inItems(p), modifiers: modifiers) }
    }

    public func mouseUp(at p: CGPoint) {
        let was = pressed
        pressed = .none
        if was == .audio { audioBlock?.mouseUp(at: inAudio(p)); return }
        if was == .text { textBlock.mouseUp(at: p, part: .text); return }
        if was == .template { template.mouseUp(at: inBody(p)); return }
        if was == .items { itemRows.mouseUp(at: inItems(p)); return }
        guard was != .none, hit(p) == was else { return }
        switch was {
        case .header: toggleCollapsed()
        case .kind(let i):
            let k = ShapeKind.allCases[i]
            guard let id = shapeClipID, k != shapeKind else { return }
            shapeKind = k
            session.setShapeKind(k, for: id)
        case .well: pickMatte()
        case .editGraphics: onEditGraphics?()
        case .caption(let i?): if let t = captionList.model.seekTime(row: i) { session.seek(to: t) }
        default: break
        }
    }

    private func toggleCollapsed() {
        guard mode != .none, mode != .text else { return }
        if isCollapsed { collapsedModes.remove(mode.title) } else { collapsedModes.insert(mode.title) }
        onHeightChange?()
    }

    /// The SQ color picker through the host; one picker session is one undo step (ColorMatteInspectorView).
    private func pickMatte() {
        guard let pick = onPickColor else { return }
        let m = matteColor
        matteGestureOpen = false
        pick(EffectColor(red: Double(m.r) / 255, green: Double(m.g) / 255, blue: Double(m.b) / 255), wellFrame) { [weak self] color in
            guard let self, let id = matteClipID else { return }
            guard let color else { matteGestureOpen = false; return }
            func b(_ x: Double) -> UInt8 { UInt8((min(max(x, 0), 1) * 255).rounded()) }
            let c = ColorMatteColor(r: b(color.red), g: b(color.green), b: b(color.blue))
            matteColor = c
            session.setColorMatte(id, c, continuesGesture: matteGestureOpen)
            matteGestureOpen = true
        }
    }

    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        switch mode {
        case .audio: audioBlock?.key(k, modifiers: modifiers) ?? false
        case .text: textBlock.key(k, modifiers: modifiers)
        case .template: template.key(k, modifiers: modifiers)
        case .graphic: itemRows.key(k, modifiers: modifiers)
        default: false
        }
    }

    public func tick() {
        if mode == .audio { audioBlock?.tick() }
        if mode == .text { textBlock.tick() }
        if mode == .template { template.tick() }
        if mode == .graphic { itemRows.tick() }
    }

    public func help(at p: CGPoint) -> String? {
        switch hit(p) {
        case .header: SQL10n.format(isCollapsed ? "Expand %@" : "Collapse %@", SQL10n.string(mode.title))
        case .kind(let i): SQL10n.string(ShapeKind.allCases[i].title)
        case .well: SQL10n.string("Color Matte color")
        case .layerPicker: SQL10n.string("Pick a layer of this graphic to edit its Motion, Opacity and effects with keyframes")
        case .editGraphics: SQL10n.string("Edit in Graphics")
        case .audio: audioBlock?.help(at: inAudio(p))
        case .text: textBlock.help(at: p, part: .text)
        case .template: template.help(at: inBody(p))
        default: nil
        }
    }
}
