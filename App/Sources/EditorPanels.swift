import AppKit
import SQCore
import SQEditorUI
import SQMedia
import SQRender
import SQText

/// Owns the panel views and models and keeps them in step with the `EditorSession`: session changes flow in through
/// `sync(_:)`, user gestures flow out as session calls.
@MainActor
final class EditorPanels {
    let session: EditorSession

    let timelineView = TimelineView()
    /// Peaks for audio clips; filled for every clip on the timeline, whichever way the media came in.
    let waveforms = TimelineWaveforms()
    /// Metal viewer + transform overlay + Hand/Type tools + in-place text editing.
    let surface = ProgramSurfaceView(viewer: ViewerView(frame: .zero))
    var viewer: ViewerView { surface.viewer as! ViewerView }
    /// Overlay state: the clip under manipulation, the gesture in flight, the text being typed.
    private var overlayTarget: OverlayTarget?
    private var overlayGesture: (target: OverlayTarget, start: ClipTransform)?
    private struct TextEditing { var clip: Clip.ID; var template: TextTemplate; var animations: AnimationSet?; var isNew: Bool; var depth = 0; var first = true }
    private var textEditing: TextEditing?
    /// A caption being typed into in the Program monitor (see `EditorPanels+Captions.swift`).
    var captionEditing: CaptionEdit?
    private var failedRasters = Set<GeneratorRef>()
    let monitorModel: MonitorPanelModel
    let source: SourceMonitorController
    let monitorView: MonitorPanelView
    let projectModel: ProjectPanelModel
    let projectView: ProjectPanelView
    let effectModel = EffectControlsModel()
    let effectView: EffectControlsView
    /// Effect Controls with the transition view over it while a transition is selected.
    let transitionView = TransitionControlsView()
    lazy var effectContainer = EffectControlsContainerView(effects: effectView, transition: transitionView)
    let libraryModel = LibraryServices.makeModel()
    let libraryView: LibraryPanelView
    let clipSections: ClipSectionsView
    let textView: TextPanelView
    let colorView: ColorInspectorPanelView
    let scopesView: ScopesPanelView
    let effectsView = EffectsPanelView()
    let meterView = AudioMeterPanelView(frame: .zero)

    private var placeholders: [PanelID: NSView] = [:]
    private var follow = TimelineFollow()
    private let trackHeights = TrackHeightStore()
    private var trackHeightsFor: Timeline.ID?
    private var pagingTimeline = false
    private var wasPlaying = false
    var lastCacheKey: [Int] = []

    /// A panel was clicked or received a command: move keyboard focus (and shortcut scope) there.
    var onFocus: ((PanelID) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCommand: ((EditorCommand) -> Void)?
    var onNest: (() -> Void)?
    /// "Set to Frame Size" of the selected clips.
    var onFrameSize: (() -> Void)?
    /// Match Frame / double-click in the Project panel loaded the Source monitor: bring it forward.
    var onShowSource: (() -> Void)?

    init(session: EditorSession, sourceEngine: (any ProgramEngine)? = nil) {
        self.session = session
        source = SourceMonitorController(session: session, engine: sourceEngine ?? StubProgramEngine())
        let fd = session.activeTimeline?.frameDuration ?? Time(1001, 30000)
        monitorModel = MonitorPanelModel(frameDuration: fd)
        monitorView = MonitorPanelView(model: monitorModel)
        projectModel = ProjectPanelModel(project: session.project, onEdit: { [weak session] p, name in
            session?.perform(name) { $0 = p }
        })
        projectView = ProjectPanelView(model: projectModel)
        effectModel.twirlDefaults = .standard
        effectView = EffectControlsView(model: effectModel)
        libraryView = LibraryPanelView(model: libraryModel)
        clipSections = ClipSectionsView(session: session)
        textView = TextPanelView(session: session)
        colorView = ColorInspectorPanelView(session: session)
        scopesView = ScopesPanelView(session: session)
        Task { [libraryModel] in await LibraryServices.start(libraryModel) }
        effectView.clipSections = clipSections
        meterView.reading = { [weak session] in
            guard let engine = session?.engine, let r = engine.meterReading else { return nil }
            return (ObjectIdentifier(engine), r.sequence, r.peaks)
        }
        wireTimeline()
        wireSidePanels()
        wireMonitor()
        wireSource()
        wireOverlay()
        wireEffectControls()
        wireTransitions()
        sync([.project, .selection, .playhead, .transport])
    }

    // MARK: Wiring

    private func wireTimeline() {
        let tv = timelineView
        tv.waveforms = waveforms
        tv.onCommit = { [weak self] c in
            guard let self else { return }
            session.commit(c)
            syncTimeline()          // a refused commit must snap the view back to the session's timeline
        }
        tv.onToolChange = { [weak self] tool in self?.setMonitorTool(tool == .hand ? .hand : tool == .type ? .type : .select) }
        tv.onSelectionChange = { [weak self] clips, captions in self?.session.select(clips: clips, captions: captions) }
        tv.onPointerDown = { [weak self] in self?.session.stopPlayback() }
        tv.onSeek = { [weak self] t in self?.session.seek(to: t) }
        tv.onScrubBegan = { [weak self] in self?.session.beginScrub() }
        tv.onScrub = { [weak self] t in self?.session.scrub(to: t) }
        tv.onScrubEnded = { [weak self] in self?.session.endScrub() }
        tv.onFocusRequest = { [weak self] in self?.onFocus?(.timeline) }
        tv.onTrackHeightsChange = { [weak self] h in
            guard let self, let id = session.activeTimelineID else { return }
            trackHeights.save(h, for: id)
        }
        // Wheel, drag, zoom: the user owns the view until playback is started again. Our own page jumps do not count.
        tv.onViewportChange = { [weak self] in
            guard let self, !pagingTimeline else { return }
            follow.userScrolled(whilePlaying: session.isPlaying)
        }
        tv.onGestureHint = { [weak self] h in if let h { self?.onStatus?(h) } }
        tv.onRejection = { [weak self] m in self?.onStatus?(m) }
        tv.onTrackToggle = { [weak self] id, toggle in self?.toggleTrack(id, toggle) }
        tv.onDropMedia = { [weak self] ids, time, track, insert in
            self?.session.placeMedia(ids, at: time, videoTrack: track, mode: insert ? .insert : .overwrite,
                                     streams: self?.source.dragStreams ?? .both)
        }
        tv.onDropTextTemplate = { [weak self] id, time, track in
            guard let entry = TextTemplateCatalog.entry(id: id) else { return }
            self?.session.addTextClip(template: entry.template, at: time, track: track)
        }
        tv.onDropFiles = { [weak self] urls, time, track, insert in self?.dropFiles(urls, at: time, track: track, insert: insert) }
        tv.dropItemsProvider = { [weak self] source in self?.dropItems(for: source) ?? [] }
        tv.onDropEffect = { [weak self] id, clip in
            guard let self else { return }
            if !session.addEffect(kind: id, to: [clip]) { onStatus?("\(EffectCatalog.title(for: id)) needs a video clip.") }
        }
        tv.contextMenuProvider = { [weak self] p in self?.timelineMenu(at: p) }
        wireVolumeLine()
        wireSpeedBand()
        wireOpacityLine()
        tv.onEditMarker = { [weak self] id in self?.editMarker(id) }
        tv.onMarkerMoved = { [weak self] id, time in self?.session.moveMarker(id, to: time) }
        tv.onToggleChange = { [weak self] snap, linked in
            self?.onStatus?("Snapping \(snap ? "on" : "off"), Linked Selection \(linked ? "on" : "off")")
        }
    }

    /// Length and streams of what is being dragged, for the ghost. Files not imported yet get the 5 s placeholder.
    private func dropItems(for source: TimelineView.DropSource) -> [DropItem] {
        switch source {
        case .media(let ids):
            let marks = session.project.sourceMarks
            return ids.compactMap { id -> DropItem? in
                guard let ref = session.project.media(id) else { return nil }
                let total = ref.info?.duration ?? ref.duration
                guard let d = marks[id]?.range?.duration ?? total else { return nil }
                let streams = self.source.dragStreams
                return DropItem(name: ref.name, duration: d,
                                hasVideo: (ref.info?.video != nil || ref.info == nil) && streams.includesVideo,
                                hasAudio: ref.info?.audio != nil && streams.includesAudio)
            }
        case .files(let urls):
            // Not probed yet: guess the streams from the extension (video files carry audio, stills do not).
            let still: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp", "webp", "psd"]
            let sound: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "caf", "ogg", "opus"]
            return urls.map { u in
                let e = u.pathExtension.lowercased()
                return DropItem(name: u.lastPathComponent, duration: Time(seconds: 5),
                                hasVideo: !sound.contains(e), hasAudio: !still.contains(e))
            }
        case .textTemplate(let id):
            return [DropItem(name: TextTemplateCatalog.entry(id: id)?.name ?? "", duration: Time(seconds: 5))]
        case .effect: return []
        }
    }

    /// Files from the Library or Finder: imported into the project (one undo step), then placed like Project media.
    private func dropFiles(_ urls: [URL], at time: Time, track: Track.ID?, insert: Bool) {
        Task { [weak self] in
            guard let self else { return }
            await projectModel.importFiles(urls)
            let paths = urls.map(\.path)
            let ids = paths.compactMap { p in session.project.media.first { $0.path == p }?.id }
            guard !ids.isEmpty else { onStatus?("Could not import the dropped files."); return }
            session.placeMedia(ids, at: time, videoTrack: track, mode: insert ? .insert : .overwrite)
        }
    }

    private func wireSidePanels() {
        textView.onStatus = { [weak self] m in self?.onStatus?(m) }
        effectModel.onNotice = { [weak self] m in self?.onStatus?(m) }
        colorView.onChange = { [weak self] in self?.scopesView.scheduleRefresh() }
        libraryView.onApplyTextTemplate = { [weak self] id in
            guard let self, let entry = TextTemplateCatalog.entry(id: id) else { return }
            session.addTextClip(template: entry.template)
        }
        effectsView.onApply = { [weak self] id in
            guard let self else { return }
            // Double-click on a transition: the selected edit, else the edit at the playhead on the targeted tracks.
            if let kind = EffectsPanelView.transitionKind(forID: id) {
                session.applyDefaultTransitions(scope: kind.trackKind == .video ? .video : .audio,
                                                edges: timelineView.interaction.edgeSelection, kind: kind)
                return
            }
            if !session.addEffect(kind: id, to: session.selection) { onStatus?("Select a video clip first, then double-click \(EffectCatalog.title(for: id)).") }
        }
    }

    private func toggleTrack(_ id: Track.ID, _ toggle: TrackToggle) {
        if toggle == .target, let flags = NSApp.currentEvent?.modifierFlags,
           !flags.intersection([.shift, .option]).isEmpty {
            session.toggleTarget(id, shift: flags.contains(.shift), option: flags.contains(.option))   // Shift: all of the kind, Option: only this
            return
        }
        let name: String
        switch toggle {
        case .visible: name = "Toggle Track Output"
        case .mute: name = "Toggle Mute"
        case .solo: name = "Toggle Solo"
        case .lock: name = "Toggle Track Lock"
        case .target: name = "Toggle Track Target"
        case .syncLock: name = "Toggle Sync Lock"
        }
        try? session.performTimeline(name) { t in
            guard let i = t.tracks.firstIndex(where: { $0.id == id }) else { return }
            switch toggle {
            case .visible: t.tracks[i].isVisible.toggle()
            case .mute: t.tracks[i].isMuted.toggle()
            case .solo: t.tracks[i].isSolo.toggle()
            case .lock: t.tracks[i].isLocked.toggle()
            case .target: t.tracks[i].isTargeted.toggle()
            case .syncLock: t.tracks[i].syncLock.toggle()
            }
        }
    }

    private func timelineMenu(at p: CGPoint) -> NSMenu? {
        let tv = timelineView
        if let k = tv.volumeKey(at: p) { return volumeKeyMenu(clip: k.clip, key: k.key) }
        if let k = tv.speedKeyHit(at: p) { return speedKeyMenu(clip: k.clip, hit: k.key) }
        if let m = transitionMenu(at: p) { return m }
        tv.contextSelect(at: p)
        if tv.selection.isEmpty, !tv.captionSelection.isEmpty { return captionMenu() }
        let hasClipboard = session.clipboard != nil
        let items: [TimelineMenuItem]
        switch tv.geometry.hitTest(p, in: tv.timeline) {
        case .clip, .caption:
            items = TimelineContextMenu.items(timeline: tv.timeline, selection: tv.selection,
                                              captionSelection: tv.captionSelection, clipboardHasClips: hasClipboard)
        case .gap where tv.interaction.gapSelection != nil:
            items = TimelineContextMenu.gapItems(clipboardHasClips: hasClipboard)
        case .gap, .captionGap:
            items = TimelineContextMenu.emptyItems(clipboardHasClips: hasClipboard)
        case .header(let id):
            return trackHeaderMenu(for: id)
        case .ruler:
            return rulerMenu(at: p)
        default:
            return nil
        }
        let menu = TimelineContextMenu.makeMenu(items: items, labelHandler: { [weak self] l in self?.session.setLabel(l) }) { [weak self] action in
            switch action {
            case .cut: self?.onCommand?(.cut)
            case .copy: self?.onCommand?(.copy)
            case .paste: self?.onCommand?(.paste)
            case .pasteInsert: self?.onCommand?(.pasteInsert)
            case .pasteAttributes: self?.onCommand?(.pasteAttributes)
            case .audioGain: self?.onCommand?(.audioGain)
            case .delete: self?.onCommand?(.delete)
            case .rippleDelete: self?.onCommand?(.rippleDelete)
            case .enable: self?.onCommand?(.enableClip)
            case .link, .unlink: self?.onCommand?(.link)
            case .nest: self?.onNest?()
            case .speed: self?.onCommand?(.speedDuration)
            case .timeRemapping: self?.onCommand?(.toggleTimeRemapping)
            case .setToFrameSize: self?.onFrameSize?()
            case .rename: self?.renameSelectedClip()
            case .label, .editCaption, .splitCaption, .mergeCaptions: break   // captions have their own menu (`captionMenu`)
            }
        }
        addEditPointItems(to: menu, at: p)
        return menu
    }

    /// Rename sheet for the one selected clip.
    private func renameSelectedClip() {
        guard let window = timelineView.window, let clip = session.singleSelectedClip, session.selection.count == 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Clip"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = clip.name
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { self?.session.renameSelectedClip(to: field.stringValue) } }
        }
    }

    private func wireMonitor() {
        viewer.drivesLayer = false           // the playback engine presents into the layer
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = monitorView.viewerSlot.bounds
        surface.autoresizingMask = [.width, .height]
        monitorView.viewerSlot.addSubview(surface)
        session.engine.attach(viewer.metalLayer)
        viewer.onResize = { [weak self] in self?.session.engine.redraw(); self?.surface.needsLayout = true }   // aspect-fit at every panel size

        monitorModel.onSeek = { [weak self] t in self?.session.seek(to: t) }
        monitorModel.onQualityChange = { [weak self] q in self?.session.engine.quality = q.decodeScale }
        monitorModel.onZoomChange = { [weak self] z in
            let v: ViewerZoom
            switch z {
            case .fit: v = .fit
            case .percent(let p), .custom(let p): v = .percent(p)
            }
            self?.session.engine.viewerZoom = v
            self?.surface.zoom = v
        }
        surface.onZoomGesture = { [weak self] v in
            guard let self else { return }
            session.engine.viewerZoom = v
            surface.zoom = v
            switch v {
            case .fit: monitorModel.displayZoom(.fit)
            case .percent(let p): monitorModel.displayZoom(.percent(p))
            case .view(let s, _, _): monitorModel.displayZoom(.custom(Int((s * 100).rounded())))
            }
        }
        monitorModel.onAction = { [weak self] a in
            let c: EditorCommand
            switch a {
            case .markIn: c = .markIn
            case .markOut: c = .markOut
            case .goToIn: c = .goToIn
            case .goToOut: c = .goToOut
            case .stepBack: c = .stepBackward
            case .stepForward: c = .stepForward
            case .playPause: c = .playPause
            case .addMarker: c = .addMarker
            case .insert: c = .insert
            case .overwrite: c = .overwrite
            case .lift: c = .lift
            case .extract: c = .extract
            case .exportFrame: c = .exportFrame
            case .loop: c = .toggleLoop
            case .playInToOut: c = .playInToOut
            case .toggleSafeMargins: self?.toggleSafeMargins(); return
            }
            self?.onCommand?(c)
        }
    }

    func toggleSafeMargins() {
        monitorModel.safeMargins.toggle()
        monitorView.safeMarginsView.needsDisplay = true
    }

    private func wireSource() {
        source.onStatus = { [weak self] m in self?.onStatus?(m) }
        source.onStartedPlaying = { [weak self] in self?.session.stopPlayback() }
        source.onRevealInProject = { [weak self] id in self?.projectView.reveal(media: id) }
        projectView.onOpenMedia = { [weak self] id in
            guard let self, source.open(id) else { return }
            onShowSource?()
        }
        projectView.onOpenSequence = { [weak self] id in self?.session.setActiveTimeline(id) }
        projectView.onPlace = { [weak self] ids, mode in self?.session.placeMedia(ids, mode: mode) }
        projectView.onNewSequenceFromClip = { [weak self] id in self?.session.newSequence(fromMedia: id) }
        wireSourceFlow()
        projectView.onNewSequence = { [weak self] in self?.onCommand?(.newSequence) }
        projectView.onReplaceFootage = { [weak self] id in self?.replaceFootage(id) }
        monitorView.safeMarginsView.rectProvider = { [weak self] in self?.surface.mapping.canvasRect ?? .zero }
        monitorModel.onScrubBegan = { [weak self] in self?.session.beginScrub() }
        monitorModel.onScrub = { [weak self] t in self?.session.scrub(to: t) }
        monitorModel.onScrubEnded = { [weak self] in self?.session.endScrub() }
        monitorModel.contextMenuBuilder = { [weak self] menu in self?.fillProgramMenu(menu) }
    }

    /// Replace Footage / Link Media: pick a file, probe it, and let it take over the item (clips, marks, label stay).
    private func replaceFootage(_ id: MediaRef.ID) {
        guard let ref = session.project.media(id) else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the file that replaces “\(ref.name)”."
        panel.prompt = ref.status() == .missing ? "Link" : "Replace"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ref.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let probed = try? await MediaImporter.probe(url).0 else { onStatus?("Could not read \(url.lastPathComponent)."); return }
            session.replaceFootage(id, with: probed)
            waveforms.invalidate(id)
            projectView.forgetThumbnail(id)
            projectModel.refreshOffline()
            if source.mediaID == id { source.open(id) }
            onStatus?("Replaced footage with \(url.lastPathComponent).")
        }
    }

    /// Opens the media item under the playhead in the Source monitor, parked on the same frame (F).
    @discardableResult
    func matchFrame() -> Bool {
        guard let t = session.activeTimeline, let m = t.matchFrame(at: session.playhead, selected: session.selection) else {
            onStatus?("No clip with media under the playhead to match."); return false
        }
        guard source.open(m.media, at: m.sourceTime) else { return false }
        onShowSource?()
        return true
    }

    /// Moves the playhead to the frame the Source monitor shows, inside the clip that uses it (Shift+R).
    @discardableResult
    func reverseMatchFrame() -> Bool {
        guard let id = source.mediaID else { onStatus?("Open a clip in the Source monitor first."); return false }
        guard let t = session.activeTimeline,
              let at = t.reverseMatchFrame(media: id, sourceTime: source.currentTime, playhead: session.playhead, selected: session.selection)
        else { onStatus?("That frame is not used in the sequence."); return false }
        session.seek(to: at)
        return true
    }

    private func fillProgramMenu(_ menu: NSMenu) {
        func add(_ title: String, _ enabled: Bool = true, state: Bool? = nil, command: EditorCommand? = nil, _ action: @escaping () -> Void) {
            let it = ClosureMenuItem(title: title, action: action)
            it.isEnabled = enabled
            if let state { it.state = state ? .on : .off }
            if let command { it.showShortcut(of: command) }
            menu.addItem(it)
        }
        func cmd(_ c: EditorCommand, _ enabled: Bool = true, state: Bool? = nil) {
            add(c.title, enabled, state: state, command: c) { [weak self] in self?.onCommand?(c) }
        }
        let io = session.activeTimeline?.inOut
        cmd(.markIn); cmd(.markOut)
        cmd(.goToIn, io != nil); cmd(.goToOut, io != nil); cmd(.clearInOut, io != nil)
        menu.addItem(.separator())
        cmd(.addMarker); cmd(.lift, io != nil); cmd(.extract, io != nil)
        menu.addItem(.separator())
        cmd(.matchFrame); cmd(.reverseMatchFrame, source.mediaID != nil); cmd(.exportFrame)
        menu.addItem(.separator())
        add("Safe Margins", state: monitorModel.safeMargins) { [weak self] in self?.toggleSafeMargins() }
        cmd(.toggleLoop, state: session.bounds.loop)
        menu.addItem(.separator())
        let zoom = NSMenu(title: "Zoom")
        for z in MonitorZoom.presets {
            let it = ClosureMenuItem(title: z.title) { [weak self] in self?.monitorModel.setZoom(z) }
            it.state = monitorModel.zoom == z ? .on : .off
            zoom.addItem(it)
        }
        let zi = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        zi.submenu = zoom
        menu.addItem(zi)
    }

    // MARK: Program monitor overlay, Type tool

    private func wireOverlay() {
        let o = surface.overlay
        o.onTransform = { [weak self] phase, t in self?.overlayTransform(phase, t) }
        o.onPathEdit = { [weak self] phase, edit in
            guard let self, effectModel.clip?.id == overlayTarget?.clip else { return }
            switch phase {
            case .began: session.stopPlayback(); effectModel.beginGesture()
            case .changed: effectModel.editPositionKey(edit.key, position: edit.position, tangents: edit.tangents)
            case .ended: effectModel.editPositionKey(edit.key, position: edit.position, tangents: edit.tangents); effectModel.endGesture()
            }
        }
        o.onBodyDoubleClick = { [weak self] in self?.beginTextEditing(selectAll: false, isNew: false) }
        surface.onTypeClick = { [weak self] pos in self?.typeToolClick(pos) }
        surface.onTypeBox = { [weak self] centre, box in self?.typeToolBox(centre, box) }
        surface.onStyleToggle = { [weak self] t in self?.toggleEditedStyle(t) }
        surface.onTextEdited = { [weak self] text in
            guard let self, !captionEdited(text) else { return }   // a caption edited in the monitor, else the text layer
            textEdited(text)
        }
        surface.onTextEditEnded = { [weak self] text in
            guard let self, !captionEditEnded(text) else { return }
            textEditEnded(text)
        }
        surface.captionHitTest = { [weak self] p in self?.captionHit(p) ?? false }
        surface.onCaptionDoubleClick = { [weak self] p in self?.beginCaptionEditing(at: p) }
        clipSections.onAlignToFrame = { [weak self] a in self?.alignSelectedText(a) }
    }

    /// One gesture = one undo step; the values land in Effect Controls live (same clip, same playhead).
    private func overlayTransform(_ phase: TransformOverlayView.Phase, _ t: ClipTransform) {
        switch phase {
        case .began:
            guard let target = overlayTarget, effectModel.clip?.id == target.clip else { return }
            session.stopPlayback()
            overlayGesture = (target, t)
            effectModel.beginGesture()
        case .changed, .ended:
            guard let g = overlayGesture else { return }
            let wrote = effectModel.setTransform(g.target.baseTransform(fromDisplay: t), from: g.target.baseTransform(fromDisplay: g.start))
            if !wrote {   // animated property and the playhead is outside the clip: nothing to write, hide instead of snapping back
                effectModel.endGesture(); overlayGesture = nil
                overlayTarget = nil; surface.setTarget(nil, snap: nil)
                return
            }
            if phase == .ended { effectModel.endGesture(); overlayGesture = nil }
        }
    }

    /// Type tool: click on existing text edits it; a click elsewhere makes point text (new text clip on the top free
    /// video track at the playhead, 5 s) with the caret in it at once.
    private func typeToolClick(_ position: Vec2) {
        if let hit = textClip(at: position) {
            session.stopPlayback()
            session.select(clips: [hit])
            updateOverlay()
            beginTextEditing(selectAll: false, isNew: false)
            return
        }
        createText(at: position, box: nil)
    }

    /// Type tool drag: area text. The box wraps the text; the caret is in it at once.
    private func typeToolBox(_ centre: Vec2, _ box: TextBox) {
        if let hit = textClip(at: centre), let c = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == hit }),
           let ref = c.generator, let (t, _) = try? TextGenerator.decode(ref), t.box == nil {
            // Dragging over existing point text edits that text, like a click.
            typeToolClick(centre)
            return
        }
        createText(at: centre, box: box)
    }

    private func createText(at position: Vec2, box: TextBox?) {
        session.stopPlayback()
        var template = TextTemplate(name: "Text", text: "Text", style: CaptionPresetLibrary.builtIn.style(for: "title"))
        template.box = box
        if box != nil { template.text = "Text"; template.style.alignment = .left }
        let depth = session.undoDepth
        guard session.addTextClip(template: template, duration: Time(Int64(AppSettings.load().defaultTextSeconds), 1),
                                  position: position) != nil else { return }
        session.seek(to: session.playhead)   // an empty sequence clamped the engine to 0: show the new text now
        updateOverlay()
        beginTextEditing(selectAll: true, isNew: true, depth: depth)
    }

    /// Topmost visible text clip under the playhead whose drawn rectangle contains `p` (sequence px from the centre).
    private func textClip(at p: Vec2) -> Clip.ID? {
        guard let tl = session.activeTimeline else { return nil }
        return TextHitTest.topmostTextClip(at: p, in: tl, project: session.project, time: session.playhead)
    }

    /// Cmd+B / Cmd+I while editing: bold toggles between Bold and Regular, italic on and off, for the whole layer.
    private func toggleEditedStyle(_ t: ProgramSurfaceView.StyleToggle) {
        guard var e = textEditing else { return }
        switch t {
        case .bold: e.template.style.weight = e.template.style.weight >= .bold ? .regular : .bold
        case .italic: e.template.style.italic.toggle()
        }
        session.updateTextClip(e.clip, template: e.template, animations: e.animations, continuesGesture: !e.first)
        e.first = false
        textEditing = e
        surface.updateEditorStyle(e.template.style, box: e.template.box, target: overlayTarget)
    }

    private func beginTextEditing(selectAll: Bool, isNew: Bool, depth: Int = 0) {
        guard let clip = session.singleSelectedClip, let ref = clip.generator, let target = overlayTarget, target.clip == clip.id,
              let (template, animations) = try? TextGenerator.decode(ref) else { return }
        session.stopPlayback()
        textEditing = TextEditing(clip: clip.id, template: template, animations: animations, isNew: isNew, depth: depth)
        surface.beginTextEditing(text: template.text, style: template.style, box: template.box, target: target, selectAll: selectAll)
    }

    private func textEdited(_ text: String) {
        guard var e = textEditing else { return }
        e.template.text = text
        session.updateTextClip(e.clip, template: e.template, animations: e.animations, continuesGesture: !e.first)
        e.first = false
        textEditing = e
    }

    private func textEditEnded(_ text: String) {
        guard let e = textEditing else { return }
        textEditing = nil
        // A text box that was created by the tool and left empty is not kept.
        guard e.isNew else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.discardTextClip(e.clip, rewindingTo: e.depth)   // no undo or redo trace
        } else {
            session.foldUndo(fromDepth: e.depth, name: "Add Text")   // add + typing = one step
        }
    }

    /// Follows selection, playhead and edits: what the overlay draws, and the lines it snaps to.
    func updateOverlay() {
        guard let tl = session.activeTimeline else { surface.setTarget(nil, snap: nil); overlayTarget = nil; return }
        surface.sequenceSize = CGSize(width: tl.format.width, height: tl.format.height)
        // A text raster that is not cached yet is rendered on a background task, never on the main thread (typing
        // is the exception: one short layout per keystroke).
        if !session.isPlaying, !surface.isEditingText, let clip = session.singleSelectedClip, let ref = clip.generator,
           ref.kind == GeneratorRef.text, !TextGenerator.isCached(ref: ref), !failedRasters.contains(ref) {
            overlayTarget = nil
            surface.setTarget(nil, snap: nil)
            Task.detached(priority: .userInitiated) { [weak self] in
                var failed = false
                do { try TextGenerator.prewarm(ref: ref) } catch { NSLog("Text raster failed: \(error)"); failed = true }
                await MainActor.run { if failed { self?.failedRasters.insert(ref) }; self?.updateOverlay() }
            }
            return
        }
        guard !session.isPlaying, let clip = session.singleSelectedClip,
              let target = OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead) else {
            overlayTarget = nil
            if !surface.isEditingText { surface.setTarget(nil, snap: nil) }
            return
        }
        overlayTarget = target
        var others: [CGRect] = []
        for c in tl.tracks.filter({ $0.kind == .video && $0.isVisible }).flatMap(\.clips) where c.id != clip.id {
            if let o = OverlayTarget.make(clip: c, project: session.project, timeline: tl, at: session.playhead) {
                others.append(LayerBounds.rect(size: o.size, transform: o.displayTransform))
            }
        }
        surface.overlay.selectedKey = effectModel.selectedKeyIDs(.position).first
        surface.overlay.uniformScale = effectModel.uniformScale
        surface.setTarget(target, snap: SnapGuides.targets(canvas: surface.sequenceSize, others: others))
    }

    /// Tool column / key: Hand and Type also act in the Program monitor.
    func setMonitorTool(_ t: ProgramSurfaceView.Tool) { surface.tool = t }

    private func wireEffectControls() {
        effectModel.onEdit = { [weak self] clip, name, coalescing in
            self?.session.replaceClip(clip, name: name, continuesGesture: coalescing)
        }
        effectModel.onSeek = { [weak self] t in self?.session.seek(to: t) }
        // Scrubbing the keyframe ruler behaves like the timeline ruler: a press stops playback, a drag scrubs.
        effectModel.onPointerDown = { [weak self] in self?.session.stopPlayback() }
        effectModel.onScrubBegan = { [weak self] in self?.session.beginScrub() }
        effectModel.onScrub = { [weak self] t in self?.session.scrub(to: t) }
        effectModel.onScrubEnded = { [weak self] in self?.session.endScrub() }
    }

    // MARK: Views

    func view(for p: PanelID) -> NSView {
        switch p {
        case .timeline: return timelineView
        case .programMonitor: return monitorView
        case .project: return projectView
        case .effectControls: return effectContainer
        case .library: return libraryView
        case .text: return textView
        case .colorInspector: return colorView
        case .scopes: return scopesView
        case .effects: return effectsView
        case .audioMeter: return meterView
        case .sourceMonitor: return source.view
        }
    }

    private static func symbol(_ p: PanelID) -> String {
        switch p {
        case .sourceMonitor: "play.rectangle"
        default: "square"
        }
    }

    /// Panel whose view contains `view`, for shortcut scope.
    func panel(containing view: NSView?) -> PanelID? {
        var v = view
        while let cur = v {
            if let c = cur as? PanelContainerView { return c.selected }
            v = cur.superview
        }
        return nil
    }

    // MARK: Sync

    private func syncTimeline() {
        timelineView.setTimeline(session.activeTimeline ?? Timeline(name: "", frameDuration: Time(1001, 30000)))
        // Track heights belong to the sequence: load them when another sequence becomes active.
        if session.activeTimelineID != trackHeightsFor {
            trackHeightsFor = session.activeTimelineID
            timelineView.setTrackHeights(session.activeTimelineID.map { trackHeights.load($0) } ?? [:])
        }
        timelineView.setSelection(session.selection)
        timelineView.setCaptionSelection(session.captionSelection)
        ensureWaveforms()
    }

    /// Cmd+I, Project drop, Finder drop, Library and open all end with clips here: build what is missing.
    private func ensureWaveforms() {
        guard let t = session.activeTimeline else { return }
        waveforms.ensure(timeline: t, project: session.project)
    }

    private var lastFrameDuration = Time(1001, 30000)

    func sync(_ change: EditorSession.Change) {
        let t = session.activeTimeline
        if change.contains(.project) || change.contains(.media) {
            if change.contains(.project) {
                if t != timelineView.timeline || timelineView.interaction.preview != timelineView.timeline { syncTimeline() }
                if projectModel.project != session.project { projectModel.setProject(session.project) }
            }
            if let t { waveforms.ensure(timeline: t, project: session.project) }
            timelineView.setOfflineMedia(Set(session.project.media.filter { session.media.isOffline($0.id) }.map(\.id)))
            timelineView.setLabelResolver(session.project.labelResolver)
            projectModel.refreshOffline()
            let fd = t?.frameDuration ?? lastFrameDuration
            lastFrameDuration = fd
            monitorModel.frameDuration = fd
            monitorModel.dropFrame = fd == Time(1001, 30000) || fd == Time(1001, 60000)
            monitorModel.duration = t?.duration ?? .zero
            monitorModel.markIn = t?.inOut?.start
            monitorModel.markOut = t?.inOut?.end
        }
        if change.contains(.selection) || change.contains(.project) {
            timelineView.setSelection(session.selection)
            timelineView.setCaptionSelection(session.captionSelection)
        }
        if session.isPlaying != wasPlaying {
            wasPlaying = session.isPlaying
            if wasPlaying {
                let x = timelineView.geometry.x(for: session.playhead)
                follow.playbackStarted(playheadVisible: x >= TimelineGeometry.contentOriginX && x <= timelineView.bounds.width)
            }
        }
        if change.contains(.playhead) || change.contains(.project) {
            timelineView.setPlayhead(session.playhead)
            monitorModel.currentTime = session.playhead
            if session.isPlaying { followPlayhead() }
        }
        // Every change re-reads the transport state, so the Play/Pause button can never lag behind the session.
        if monitorModel.isPlaying != session.isPlaying { monitorModel.isPlaying = session.isPlaying }
        if session.isPlaying { source.pause() }
        monitorModel.isLooping = session.bounds.loop
        source.sync(change)
        effectModel.sync(with: session, change: change)
        syncTransitions(change)
        updateOverlay()
        clipSections.sync(change)
        textView.sync(change)
        colorView.sync(change)
        scopesView.sync(change)
    }

    /// Page-wise follow during playback (`TimelineFollow`): the view jumps a page when the playhead reaches an edge,
    /// unless the user scrolled since playback started.
    private func followPlayhead() {
        let tv = timelineView
        let x = tv.geometry.x(for: session.playhead)
        guard let target = follow.pageScroll(playheadX: x, scrollX: tv.geometry.scrollX,
                                             viewLeft: TimelineGeometry.contentOriginX, viewRight: tv.bounds.width) else { return }
        pagingTimeline = true
        tv.scroll(toX: target)
        pagingTimeline = false
    }
}

/// Stand-in for panels whose real view is not wired yet.
@MainActor
final class PlaceholderPanelView: NSView {
    init(title: String, symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.contentTintColor = Theme.Colors.label3
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        let label = NSTextField(labelWithString: title)
        label.font = Theme.Fonts.bodyTitle
        label.textColor = Theme.Colors.label2
        let note = NSTextField(labelWithString: "Not connected yet")
        note.font = Theme.Fonts.small
        note.textColor = Theme.Colors.label3
        let stack = NSStackView(views: [icon, label, note])
        stack.orientation = .vertical
        stack.spacing = Theme.Spacing.xs
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(title)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
