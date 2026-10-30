import AppKit
import SQCore
import SQEditorSession
import SQEditorUI
import SQLibrary
import SQMedia
import SQPlayback
import SQRender
import SQText

/// Owns the panel views and models and keeps them in step with the `EditorSession`: session changes flow in through
/// `sync(_:)`, user gestures flow out as session calls.
@MainActor
final class EditorPanels {
    let session: EditorSession
    /// The open Custom curve editor of the selected transition (Effect Controls > Easing > Custom).
    var transitionCurvePopover: SQPopover?

    let timelineView = TimelineView()
    /// Timeline panel content: sequence tab strip above `timelineView`.
    private(set) lazy var timelineHost = TimelineHostView(timeline: timelineView)
    /// Peaks for audio clips; filled for every clip on the timeline, whichever way the media came in.
    let waveforms = TimelineWaveforms()
    /// Poster frames for the thumbnail column of timeline video clips.
    let clipThumbnails = ClipThumbnailSource()
    /// Weak stretches of tracked Magic masks (the clip's confidence strip).
    let magicHealth = MagicTrackHealthCache.mac()
    /// Metal viewer + transform overlay + Hand/Type tools + in-place text editing.
    let surface = ProgramSurfaceView(viewer: ViewerView(frame: .zero))
    var viewer: ViewerView { surface.viewer as! ViewerView }
    /// Overlay state: the clip under manipulation, the gesture in flight, the text being typed.
    private(set) var overlayTarget: OverlayTarget?
    private var overlayGesture: (target: OverlayTarget, start: ClipTransform)?
    /// A text clip's scale-handle drag resizes the font, not Scale: the template and undo depth at the drag's start.
    private var textResizeStart: (template: TextTemplate, animations: AnimationSet?, depth: Int, first: Bool)?
    private struct TextEditing { var clip: Clip.ID; var template: TextTemplate; var animations: AnimationSet?; var isNew: Bool; var depth = 0; var first = true }
    private var textEditing: TextEditing?
    /// A text layer of the selected graphic being typed into (Type tool or double-click with Select).
    private struct GraphicTextEditing { var layer: UUID; var clip: Clip.ID; var isNew: Bool; var depth: Int }
    private var graphicTextEditing: GraphicTextEditing?
    /// A caption being typed into in the Program monitor (see `EditorPanels+Captions.swift`).
    var captionEditing: CaptionEdit?
    var captionDrag: CaptionDragState?
    private var failedRasters = Set<GeneratorRef>()
    let monitorModel: MonitorPanelModel
    /// Trim mode (TL-08/09): state, and the two-up view made on first use over the Program viewer.
    let trimModel: TrimModeModel
    var trimView: TrimMonitorView?
    var makeTrimEngines: (() -> (any ProgramEngine, any ProgramEngine)?)?
    var releaseTrimCache: (() -> Void)?
    /// Slip drag: the first/last-frame view over the Program viewer, made on first use.
    var slipView: SlipTwoUpView?
    var makeSlipEngines: (() -> (any ProgramEngine, any ProgramEngine)?)?
    var releaseSlipCache: (() -> Void)?
    let source: SourceMonitorController
    let monitorView: MonitorPanelView
    let projectModel: ProjectPanelModel
    /// Conform to Constant Frame Rate jobs (listed by the Background Jobs popover).
    let conformRunner = ConformRunner()
    let projectView: ProjectPanelView
    let effectModel = EffectControlsModel()
    /// The Mask tool's Magic mode (hover, pick, click) on this window's monitor and Effect Controls.
    private(set) lazy var magicTool: MagicMaskTool = {
        let t = MagicMaskTool(model: effectModel, overlay: surface.overlay)
        t.targetClip = { [weak self] in self?.overlayTarget?.clip }
        t.mediaURL = { [weak self] id in self?.session.project.media(id).map { URL(fileURLWithPath: $0.path) } }
        t.isPlaying = { [weak self] in self?.session.isPlaying ?? false }
        t.onStatus = { [weak self] s in self?.onStatus?(s) }
        t.onMaskChanged = { [weak self] in self?.updateOverlay() }
        t.onPicked = { [weak self] in self?.session.engine.redraw() }
        t.onCorrect = { [weak self] id, at, subtract in self?.magicCorrect(id, at: at, subtract: subtract) }
        // Hover and a pick see the frame in the file's pixel shape, like Track (`runMagicTrack`).
        t.session.pixelAspect = { [weak self] url in
            self?.session.project.media.first { $0.path == url.path }?.info?.video?.displayPixelAspect ?? .square
        }
        // And deinterlaced as the monitor shows them (the media item's Deinterlace switch).
        t.session.deinterlace = { [weak self] url in
            self?.session.project.media.first { $0.path == url.path }?.info?.video?.deinterlaceFieldOrder
        }
        return t
    }()
    let effectView: EffectControlsView
    /// Effect Controls with the transition view over it while a transition is selected.
    let transitionView = TransitionControlsView()
    /// The transition controls' session calls, shared with the Windows `TransitionControlsDraw`.
    lazy var transitionActions = TransitionControlsActions(session: session)
    lazy var effectContainer = EffectControlsContainerView(effects: effectView, transition: transitionView)
    let libraryModel = LibraryServices.makeModel()
    let libraryView: LibraryPanelView
    let clipSections: ClipSectionsView
    let textView: TextPanelView
    let colorView: ColorInspectorPanelView
    let scopesView: ScopesPanelView
    let effectsView = EffectsPanelView()
    let keystonesModel = KeystonesPanelModel()
    let markerListView = MarkerIndexView(frame: .zero)
    lazy var keystonesView = KeystonesPanelView(model: keystonesModel)
    /// The clip as it was right after the keystone bar's last edit: any other change to it hides the bar.
    var keystoneBarClip: Clip?
    let meterView = AudioMeterPanelView(frame: .zero)
    /// GFX: layer selection and edits of the selected graphics clip, its panel and its monitor handles.
    let graphics: GraphicsEditor
    let graphicsView: GraphicsPanelView
    let graphicsOverlay: GraphicsOverlayView
    /// Window > Graphics: bring the panel forward (New Graphics Clip).
    var onShowGraphics: (() -> Void)?

    private var placeholders: [PanelID: NSView] = [:]
    private var follow = TimelineFollow()
    private let trackHeights = TrackHeightStore()
    private var trackHeightsFor: Timeline.ID?
    private var pagingTimeline = false
    private var wasPlaying = false
    var lastCacheKey: [Int] = []

    /// A panel was clicked or received a command: move keyboard focus (and shortcut scope) there.
    var onFocus: ((PanelID) -> Void)?
    /// Every line the panels write to the status bar goes through here and is noted (`trackStatusLine`).
    var onStatus: ((String) -> Void)? {
        get { statusOut }
        set { statusOut = newValue.map { out in { [weak self] s in self?.trackStatusLine.wrote(); out(s) } } }
    }
    private var statusOut: ((String) -> Void)?
    /// Whether the status bar still shows the going-on line of a Magic track (`endMagicTrackStatus`).
    var trackStatusLine = TrackStatusLine()
    var onLinkedSelectionChange: ((Bool) -> Void)?
    var onCommand: ((EditorCommand) -> Void)?
    /// The quiet text of a panel header changed ("2 uses" after "Color").
    var onHeaderDetailChange: ((PanelID, String?) -> Void)?
    /// The Color page is showing: the timeline sits in its lower panel, the viewer header above the Program monitor.
    var colorPageActive = false
    lazy var projectHeaderButtons = makeProjectHeaderButtons()
    lazy var projectCountLabel = makeProjectCountLabel()
    var onNest: (() -> Void)?
    /// F7.16 Create Angles Clip… from the timeline menu.
    var onCreateAnglesClip: (() -> Void)?
    /// The Source monitor shows every angle of the Angles clip under the playhead (EditorPanels+AnglesGrid).
    var showsAllAngles = false
    var onCreateAnglesClipFromMedia: (([MediaRef.ID]) -> Void)?
    /// "Fit to Frame" of the selected clips.
    var onFrameSize: (() -> Void)?
    var onFillFrame: (() -> Void)?
    /// Match Frame / double-click in the Project panel loaded the Source monitor: bring it forward.
    var onShowSource: (() -> Void)?
    /// The Source monitor started playing (8 GB Macs hand it the larger frame-cache share).
    var onSourceStartedPlaying: (() -> Void)?

    init(session: EditorSession, sourceEngine: (any ProgramEngine)? = nil) {
        self.session = session
        source = SourceMonitorController(session: session, engine: sourceEngine ?? StubProgramEngine())
        let fd = session.activeTimeline?.frameDuration ?? Time(1001, 30000)
        monitorModel = MonitorPanelModel(frameDuration: fd)
        trimModel = TrimModeModel(session: session)
        monitorView = MonitorPanelView(model: monitorModel)
        projectModel = ProjectPanelModel(project: session.project, onEdit: { [weak session] p, name in
            session?.perform(name) { $0 = p }
        })
        // Large imports fill the bin while they probe, as one undo step.
        projectModel.onCoalescingEdit = { [weak session] p, name, key in session?.perform(name, coalescing: key) { $0 = p } }
        projectView = ProjectPanelView(model: projectModel)
        effectModel.graphEditor = EffectControlsGraphEditorPref.load()
        effectView = EffectControlsView(model: effectModel)
        libraryView = LibraryPanelView(model: libraryModel)
        clipSections = ClipSectionsView(session: session)
        textView = TextPanelView(session: session)
        colorView = ColorInspectorPanelView(session: session)
        scopesView = ScopesPanelView(session: session)
        graphics = GraphicsEditor(session: session)
        graphicsView = GraphicsPanelView(editor: graphics)
        graphicsOverlay = GraphicsOverlayView(editor: graphics)
        Task { [libraryModel] in await LibraryServices.start(libraryModel) }
        effectView.clipSections = clipSections
        meterView.reading = { [weak session] in
            guard let engine = session?.engine, let r = engine.meterReading else { return nil }
            return (ObjectIdentifier(engine), r.sequence, r.peaks)
        }
        meterView.loudnessReading = { [weak session] in session?.engine.loudnessLevels.map(LoudnessReading.init) }
        meterView.loudnessTargetProvider = { [weak session] in LoudnessTarget(delivery: session?.activeTimeline?.deliveryTarget) }
        monitorView.loudnessProvider = { [weak session] in session?.engine.loudnessLevels.map(LoudnessReading.init) }
        monitorView.loudnessTargetProvider = meterView.loudnessTargetProvider
        meterView.monoProvider = { [weak session] in session?.activeTimeline?.channelLayout == .mono }
        meterView.onResetLoudness = { [weak session] in session?.engine.resetLoudnessMeter() }
        // Solo/Mute on the meter: speakers only (the meter, loudness and export never see it).
        meterView.onChannelMonitorChange = { [weak session] m in (session?.engine as? PlaybackEngine)?.audio?.setChannelMonitor(m) }
        wireTimeline()
        wireSidePanels()
        wireHeaders()
        wireMonitor()
        wireTrimMode()
        wireSource()
        wireOverlay()
        wireMaskTool()
        wireGraphics()
        wireCreateTool()
        wireEffectControls()
        wireTransitions()
        wireEffectDefaults()
        // Guards the wiring calls above: an unwired timeline edits nothing (the call was lost once in a merge).
        precondition(timelineView.onCommit != nil && timelineView.contextMenuProvider != nil, "EditorPanels: wireTimeline() was not called")
        sync([.project, .selection, .playhead, .transport])
    }

    // MARK: Wiring

    private func wireTimeline() {
        let tv = timelineView
        tv.waveforms = waveforms
        clipThumbnails.onLoad = { [weak self, weak tv] in
            tv?.thumbnailsChanged()
            if self?.showsAllAngles == true { self?.refreshAnglesGrid() }
        }
        wireAnglesGrid()
        magicHealth.onChange = { [weak tv] in tv?.trackConfidenceChanged() }
        // A Magic mask's tracked frames were read or changed: the clip key lane shows them.
        NotificationCenter.default.addObserver(forName: MagicTrackedFrames.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timelineView.trackConfidenceChanged() }
        }
        tv.trackWeakSpans = { [weak self] clip in self?.magicHealth.weakSpans(for: clip) }
        tv.thumbnails = { [weak self] id in
            guard let self, let ref = session.project.media(id) else { return nil }
            return clipThumbnails.image(for: ref)
        }
        tv.anglesSequence = { [weak self] id in self?.session.project.timeline(id).flatMap { $0.angles != nil ? $0 : nil } }
        source.waveforms = waveforms
        waveforms.addObserver { [weak source] id in source?.waveformReady(id) }
        session.engine.setDialogueSilences(waveforms.silences)   // N8b: dialogue pauses release the live duck
        tv.duckCurve = DuckCurveSource(ducking: { [weak session] in LiveDucking.resolved(project: session?.project.liveDucking) },
                                       silences: waveforms.silences)   // N8b: the duck curve on Music tracks
        tv.onCommit = { [weak self] c in
            guard let self else { return }
            session.commit(c)
            syncTimeline()          // a refused commit must snap the view back to the session's timeline
        }
        tv.onOpenTrimMode = { [weak self] point, before in self?.enterTrimMode(point, pointerBefore: before) }
        tv.onOpenNestedSequence = { [weak self] id in self?.session.enterNestedSequence(id) }
        tv.onEditToneClip = { [weak self] id in
            guard let self else { return }
            session.select(clips: [id])
            if let sel = session.selectedTone, let window = timelineView.window {
                ToneDialog.present(on: window, spec: sel.spec) { [weak self] spec in self?.session.setTone(sel.id, spec) }
            }
        }
        tv.onOpenGraphicLayers = { [weak self] id in
            guard let self else { return }
            session.stopPlayback()
            session.select(clips: [id])
            onShowGraphics?()
        }
        tv.onEditTextClip = { [weak self] id in
            guard let self else { return }
            session.stopPlayback()
            session.select(clips: [id])
            updateOverlay()
            beginTextEditing(selectAll: false, isNew: false)
        }
        timelineHost.tabs.onSelect = { [weak self] root in self?.session.selectSequenceTab(root: root) }
        timelineHost.tabs.onClose = { [weak self] root in self?.session.closeSequenceTab(root: root) }
        timelineHost.tabs.onMove = { [weak self] root, index in self?.session.moveSequenceTab(root: root, to: index) }
        tv.onToolChange = { [weak self] tool in
            guard let self else { return }
            setMonitorTool(createMonitorTool(for: tool) ?? monitorTool(for: tool))
            // The track a pick started belongs to the Magic tool: it ends with it; the frames tracked so far are saved.
            if surface.tool.maskModeValue != .magic {
                MaskTrackActivity.shared.stopAutomatic(reason: "the tool was switched")
                stopUnusedSubjectModelLoad()
            } else {
                // The model loads from here, not from the first pick: by the time the user clicked the object it is
                // ready (or close), so that pick does not wait for it. Left unused, the load is stopped above.
                startSubjectModelLoad()
            }
            updateOverlay()
        }
        tv.onSelectionChange = { [weak self] clips, captions in
            self?.session.select(clips: clips, captions: captions)
            self?.syncFastCutStrip()
        }
        tv.onSeek = { [weak self] t in self?.session.seek(to: t) }
        tv.onScrubBegan = { [weak self] in self?.session.beginScrub() }
        tv.onScrub = { [weak self] t in self?.session.scrub(to: t) }
        tv.onScrubEnded = { [weak self] in self?.session.endScrub() }
        tv.onSkim = { [weak self] t in self?.session.skim(to: t) }
        tv.isPlaybackRunning = { [weak self] in self?.session.isPlaying ?? false }
        tv.onFocusRequest = { [weak self] in self?.onFocus?(.timeline) }
        tv.setHeightMode(TrackHeightMode(rawValue: UserDefaults.standard.string(forKey: "sq.trackHeightMode") ?? "") ?? .medium, notify: false)
        tv.setFitsTracks(UserDefaults.standard.bool(forKey: "sq.fitTracksToHeight"), notify: false)
        tv.onFitTracksChange = { UserDefaults.standard.set($0, forKey: "sq.fitTracksToHeight") }
        tv.onHeightModeChange = { UserDefaults.standard.set($0.rawValue, forKey: "sq.trackHeightMode") }
        tv.onTrackHeightsChange = { [weak self] h in
            guard let self, let id = session.activeTimelineID else { return }
            trackHeights.save(h, for: id)
        }
        tv.onSplitChange = { [weak self] f in
            guard let self, let id = session.activeTimelineID else { return }
            trackHeights.saveSplit(f, for: id)
        }
        // Wheel, drag, zoom: the user owns the view until playback is started again. Our own page jumps do not count.
        tv.onViewportChange = { [weak self] in
            guard let self, !pagingTimeline else { return }
            follow.userScrolled(whilePlaying: session.isPlaying)
        }
        tv.onSlipTwoUp = { [weak self] two, preview in self?.syncSlipTwoUp(two, preview: preview) }
        tv.onGestureHint = { [weak self] h in if let h { self?.onStatus?(h) } }
        tv.onRejection = { [weak self] m in self?.onStatus?(m) }
        tv.onAddTrack = { [weak self] kind in self?.session.addTrack(kind) }
        tv.onSetAttachPoint = { [weak self] id, time in
            if self?.session.setAttachPoint(clip: id, at: time) == true { self?.onStatus?("Attach point set.") }
        }
        tv.onTrackToggle = { [weak self] id, toggle in self?.toggleTrack(id, toggle) }
        wireSourcePatch()
        tv.onDropMedia = { [weak self] ids, time, track, insert in
            self?.session.placeMedia(ids, at: time, videoTrack: track, mode: insert ? .insert : .overwrite,
                                     streams: self?.source.dragStreams ?? .both)
        }
        tv.onDropSequences = { [weak self] ids, time, track, insert in
            self?.session.placeSequences(ids, at: time, videoTrack: track, mode: insert ? .insert : .overwrite)
        }
        tv.onDropSequencesOnGhost = { [weak self] ids, time, kind, insert in
            self?.session.placeSequences(ids, at: time, mode: insert ? .insert : .overwrite, newTrack: kind)
        }
        tv.sequenceDropRefusal = { [weak self] ids in self?.session.sequenceNestingRefusal(ids) }
        tv.dropStreamsProvider = { [weak self] in self?.source.dragStreams ?? .both }
        tv.onDropMediaOnGhost = { [weak self] ids, time, kind, insert in
            self?.session.placeMedia(ids, at: time, mode: insert ? .insert : .overwrite,
                                     streams: self?.source.dragStreams ?? .both, newTrack: kind)
        }
        tv.onDropTextTemplate = { [weak self] id, time, track in
            guard let entry = TextTemplateCatalog.entry(id: id) else { return }
            if entry.isCTA { self?.session.addCTAEndCard(at: time, track: track); return }
            if let g = entry.graphicPresetID { self?.session.addGraphicPreset(g, at: time, track: track); return }
            self?.session.addTextClip(template: entry.template, at: time, track: track)
        }
        tv.onDropFiles = { [weak self] urls, time, track, insert in self?.dropFiles(urls, at: time, track: track, insert: insert) }
        tv.dropItemsProvider = { [weak self] source in self?.dropItems(for: source) ?? [] }
        tv.onReplaceMedia = { [weak self] media, clip, match in
            guard let self, let first = media.first else { return }
            _ = session.replaceMedia(of: clip, withFirstOf: media, matchSourceTime: match && source.mediaID == first ? source.currentTime : nil)
            if let e = session.lastError { onStatus?(e) }
        }
        tv.onReplaceSequence = { [weak self] seq, clip in
            guard let self else { return }
            if !session.replaceWithSequence(of: clip, with: seq), let e = session.lastError { onStatus?(e) }
        }
        tv.onDropEffect = { [weak self] id, clip in
            guard let self else { return }
            if !session.addEffect(kind: id, to: session.effectDropTargets(hit: clip)) { onStatus?(SQL10n.format("%@ needs %@.", SQL10n.string(Self.effectTitle(id)), SQL10n.string(Self.effectTargetNoun(id)))) }
        }
        tv.contextMenuProvider = { [weak self] p in self?.timelineMenu(at: p) }
        wireVolumeLine()
        wireItemLanes()
        wireSpeedBand()
        wireOpacityLine()
        wireLineKeys()
        wirePresets()
        wireKeystones()
        wireMarkerList()
        wireMarkerRange()
        tv.onEditMarker = { [weak self] id in self?.editMarker(id) }
        tv.onMarkerMoved = { [weak self] id, time in self?.session.moveMarker(id, to: time) }
        tv.onEditClipMarker = { [weak self] clip, id in self?.editClipMarker(clip, id) }
        tv.onClipMarkerMoved = { [weak self] clip, id, time in self?.session.moveClipMarker(id, on: clip, to: time) }
        tv.onInOutChange = { [weak self] r, part in self?.session.moveInOut(to: r, part: part) }
        let asClips = UserDefaults.standard.bool(forKey: "sq.placeSequencesAsClips")
        tv.toolState.placeSequencesAsClips = asClips
        session.placeSequencesAsClips = asClips
        var stored = tv.toolState
        stored.applyStoredToggles()                  // Snapping and Linked Selection survive a relaunch (per Mac)
        tv.toolState = stored
        session.linkedSelection = stored.linkedSelection
        timelineHost.header.onEditModeRequest = { [weak self] mode in self?.setEditMode(mode) }
        timelineHost.fastCutStrip.onVerb = { [weak self] c in self?.onCommand?(c); self?.syncFastCutStrip() }
        timelineHost.header.onAddMarker = { [weak self] in self?.session.addMarkerAtPlayhead() }
        tv.onToggleChange = { [weak self] snap, linked in
            guard let self else { return }
            self.session.linkedSelection = linked
            // Snapping and Linked Selection belong to the sequence: one undo step each, saved with the project (v91).
            self.session.setSnapping(snap); self.session.setLinkedSelection(linked)
            self.timelineView.toolState.storeToggles()
            let asClips = self.timelineView.toolState.placeSequencesAsClips
            if asClips != self.session.placeSequencesAsClips {
                self.session.placeSequencesAsClips = asClips
                UserDefaults.standard.set(asClips, forKey: "sq.placeSequencesAsClips")
                self.onStatus?(asClips ? "Sequences now land as their own clips" : "Sequences now land as one combined clip")
                return
            }
            self.onStatus?(SQL10n.format("Snapping %@, Linked Selection %@", SQL10n.string(snap ? "on" : "off"), SQL10n.string(linked ? "on" : "off")))
            self.onLinkedSelectionChange?(linked)
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
        case .sequences(let ids):
            let fd = session.activeTimeline?.frameDuration ?? Time(1, 30)
            return ids.compactMap { id -> DropItem? in
                guard let t = session.project.timeline(id), let d = session.project.nestedLength(of: id, hostFrameDuration: fd) else { return nil }
                return DropItem(name: t.name, duration: d, hasVideo: true,
                                hasAudio: t.tracks.contains { $0.kind == .audio && !$0.clips.isEmpty })
            }
        case .files(let urls):
            // Not probed yet: guess the streams from the extension (video files carry audio, stills do not).
            let still = StillImage.extensions
            let sound: Set<String> = ["wav", "aif", "aifc", "aiff", "mp3", "m4a", "aac", "flac", "caf", "ogg", "opus"]
            return urls.map { u in
                let e = u.pathExtension.lowercased()
                return DropItem(name: u.lastPathComponent, duration: Time(seconds: 5),
                                hasVideo: !sound.contains(e), hasAudio: !still.contains(e))
            }
        case .textTemplate(let id):
            return [DropItem(name: TextTemplateCatalog.entry(id: id)?.name ?? "", duration: Time(seconds: 5))]
        case .titleBlock: return []
        case .effect: return []
        }
    }

    /// Sequence > Whoosh at Selected Cuts: the last chosen (else first) sound of the Library's SFX bin. The bin is created on
    /// first use and starts empty: the user adds files (item menu "Add to SFX Folder").
    func whooshFromSFXBin() {
        Task { [weak self] in
            guard let self else { return }
            if let url = libraryModel.whooshSound { whoosh(url); return }
            let existed = libraryModel.sfxFolder != nil
            await libraryModel.ensureSFXBin()
            onStatus?(existed ? "The SFX folder is empty. Add sound files to it (Library item menu: Add to SFX Folder)."
                              : "SFX bin created in the Library. Add whoosh sounds to it, then run this again.")
        }
    }

    /// Library audio item -> a copy centered on each selected cut (selected edges, else the cuts around selected clips).
    func whoosh(_ url: URL) {
        let cuts = session.selectedCuts(edges: timelineView.interaction.edgeSelection?.edges ?? [])
        guard !cuts.isEmpty else { onStatus?("Select a cut first: click an edge, or select clips next to each other."); return }
        Task { [weak self] in
            guard let self else { return }
            await projectModel.importFiles([url])
            guard let id = projectModel.mediaID(forImported: url), session.addWhoosh(media: id, atCuts: cuts) else {
                onStatus?(session.lastError ?? "Could not place the sound on the cuts."); return
            }
        }
    }

    /// Files from the Library or Finder: imported into the project (one undo step), then placed like Project media.
    private func dropFiles(_ urls: [URL], at time: Time, track: Track.ID?, insert: Bool) {
        Task { [weak self] in
            guard let self else { return }
            await projectModel.importFiles(urls)
            let ids = urls.compactMap { projectModel.mediaID(forImported: $0) }
            guard !ids.isEmpty else { onStatus?("Could not import the dropped files."); return }
            session.placeMedia(ids, at: time, videoTrack: track, mode: insert ? .insert : .overwrite)
        }
    }

    private func wireSidePanels() {
        textView.onStatus = { [weak self] m in self?.onStatus?(m) }
        effectModel.onNotice = { [weak self] m in self?.onStatus?(m) }
        clipSections.keystones = keystonesModel     // this window's saved animations (Intro / Outro popups)
        textView.keystones = keystonesModel         // the Captions tab's text sections share them
        clipSections.onNotice = { [weak self] m in self?.onStatus?(m) }
        // Saved title templates in the text clip's Look popup: the text takes the template's style and in/out animation.
        clipSections.templateEntries = { [weak self] in
            (self?.libraryModel.presets ?? []).filter { $0.kind == .titleTemplate }.map { ($0.id, $0.name) }
        }
        clipSections.onPickTemplate = { [weak self] id in
            guard let self, let item = libraryModel.presets.first(where: { $0.id == id }),
                  let preset = try? TitleTemplatePreset(preset: item) else { self?.onStatus?("The template could not be read."); return }
            if !session.applyTemplateStyle(preset.template) {
                onStatus?(session.lastError ?? "The template has no text layer to take the style from.")
            }
        }
        graphicsView.keystones = keystonesModel     // the Graphics panel's text item reads and saves the same ones
        graphicsView.onNotice = { [weak self] m in self?.onStatus?(m) }
        effectModel.timeline = { [weak self] in self?.session.activeTimeline }
        effectModel.onTrackMask = { [weak self] id, forward in self?.trackMask(id, forward: forward) }
        effectModel.onTrackMagic = { [weak self] id, command in self?.trackMagicMask(id, command) }
        colorView.onChange = { [weak self] in self?.scopesView.scheduleRefresh() }
        colorView.onWindowEditChange = { [weak self] _ in self?.refreshStepWindowEdit() }
        // The hint names what the Color page measures: off the page (Edit) the line hides (`setColorPage`).
        colorView.onScreenHintChange = { [weak self] h in
            guard let self, colorPageActive else { return }
            scopesView.hint = h
        }
        libraryView.onApplyTextTemplate = { [weak self] id in
            guard let self, let entry = TextTemplateCatalog.entry(id: id) else { return }
            if entry.isCTA { session.addCTAEndCard(); return }
            if let g = entry.graphicPresetID { session.addGraphicPreset(g); return }
            session.addTextClip(template: entry.template)
        }
        wireTextTemplatesTab()
        libraryView.onWhoosh = {[weak self] url in self?.whoosh(url) }
        // The Library preview has its own player; starting it stops the sequence and the source monitor (and the reverse, see `sync`).
        libraryModel.preview.onWillPlay = { [weak self] in self?.session.stopPlayback(); self?.source.pause() }
        observePresetsForEffectsPanel()
        effectsView.onApply = { [weak self] id in
            guard let self else { return }
            if id.hasPrefix(EditorSession.builtInPresetPrefix) {
                if !session.applyStackPreset(String(id.dropFirst(EditorSession.builtInPresetPrefix.count))) {
                    onStatus?(session.lastError ?? "The preset could not be applied.")
                }
                return
            }
            if id.hasPrefix("preset."), let uuid = UUID(uuidString: String(id.dropFirst("preset.".count))),
               let preset = libraryModel.presets.first(where: { $0.id == uuid }) {
                let ok = preset.kind == .transition
                    ? session.applyTransitionPreset(preset, edges: timelineView.interaction.edgeSelection)
                    : session.applyPreset(preset, mode: PresetApplyModeSetting.load())
                if !ok { onStatus?(session.lastError ?? "The preset could not be applied.") }
                return
            }
            // Double-click on a transition: the selected edit, else the edit at the playhead on the targeted tracks.
            if let kind = EffectsPanelView.transitionKind(forID: id) {
                session.applyDefaultTransitions(scope: kind.trackKind == .video ? .video : .audio,
                                                edges: timelineView.interaction.edgeSelection, kind: kind)
                return
            }
            session.flushFollowSelection()       // while playing the selection is not followed: catch up first
            if !session.addEffect(kind: id, to: session.selection) {
                onStatus?(SQL10n.format("Select %@ first, then double-click %@.", SQL10n.string(Self.effectTargetNoun(id)), SQL10n.string(Self.effectTitle(id))))
            }
        }
    }

    /// "an audio clip" for audio effects (a linked video clip counts through its audio), else "a video clip".
    static func effectTargetNoun(_ kind: String) -> String {
        TextPresetCatalog.isTextPresetID(kind) ? "a text layer" : ClipEffect.isAudioKind(kind) ? "an audio clip" : "a video clip"
    }
    static func effectTitle(_ kind: String) -> String {
        TextPresetCatalog.look(id: kind)?.name ?? TextPresetCatalog.motion(id: kind)?.name ?? EffectCatalog.title(for: kind)
    }

    /// Keeps the Effects panel's "Presets" folder in step with the Library (re-arms itself after every change).
    private func observePresetsForEffectsPanel() {
        effectsView.presetEntries = libraryModel.presets.filter { $0.kind != .keystone }.map {
            EffectsPanelView.Entry(id: "preset.\($0.id.uuidString)", title: $0.name, category: "Presets", symbol: .toolMask)
        }
        withObservationTracking { _ = libraryModel.presets } onChange: { [weak self] in
            Task { @MainActor in self?.observePresetsForEffectsPanel() }
        }
    }

    private func toggleTrack(_ id: Track.ID, _ toggle: TrackToggle) {
        if toggle == .target, let flags = NSApp.currentEvent?.modifierFlags,
           !flags.intersection([.shift, .option]).isEmpty {
            session.toggleTarget(id, shift: flags.contains(.shift), option: flags.contains(.option))   // Shift: all of the kind, Option: only this
            return
        }
        // Shift-click on a mute, solo, lock, visibility or sync lock toggle sets every track of the kind: one undo step.
        let all = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        session.toggleTracks(of: id, toggle, allOfKind: all)
    }

    private func timelineMenu(at p: CGPoint) -> [SQMenuItem]? {
        let tv = timelineView
        if let f = tv.fadeHandleHit(at: p) { return fadeCurveItems(clip: f.clip, handle: f.handle, current: f.curve) }
        if let k = tv.volumeKey(at: p) { return volumeKeyItems(clip: k.clip, key: k.key) }
        if let k = tv.speedKeyHit(at: p) { return speedKeyItems(clip: k.clip, hit: k.key, at: p) }
        if let c = tv.speedSegmentClip(at: p) { return speedPointItems(clip: c, at: p) }
        if let m = transitionItems(at: p) { return m }
        if let h = ClipMarkerFlags.hit(at: p, in: tv.timeline, geometry: tv.geometry) { return clipMarkerItems(h) }
        tv.contextSelect(at: p)
        if tv.selection.isEmpty, !tv.captionSelection.isEmpty { return captionMenu() }
        let hasClipboard = session.clipboard != nil
        let items: [TimelineMenuItem]
        switch tv.geometry.hitTest(p, in: tv.timeline) {
        case .clip, .caption:
            items = TimelineContextMenu.items(timeline: tv.timeline, selection: tv.selection,
                                              captionSelection: tv.captionSelection, clipboardHasClips: hasClipboard,
                                              groups: Set(session.project.timelines.filter(\.isGroup).map(\.id)))
        case .gap where tv.interaction.gapSelection != nil:
            items = TimelineContextMenu.gapItems(clipboardHasClips: hasClipboard)
        case .gap, .captionGap:
            items = TimelineContextMenu.emptyItems(clipboardHasClips: hasClipboard,
                                                   placeSequencesAsClips: tv.toolState.placeSequencesAsClips)
        case .header(let id):
            return trackHeaderItems(for: id)
        case .ruler:
            return rulerItems(at: p)
        default:
            return nil
        }
        let resolver = session.project.labelResolver
        let shared = Set(session.selection.compactMap { id in tv.timeline.tracks.flatMap(\.clips).first { $0.id == id }.map(resolver.label(for:)) })
        var rows = TimelineContextMenu.makeSQItems(items: items, labelHandler: { [weak self] l in self?.session.setLabel(l) },
                                                currentLabel: shared.count == 1 ? shared.first : nil) { [weak self] action in
            switch action {
            case .cut: self?.onCommand?(.cut)
            case .copy: self?.onCommand?(.copy)
            case .paste: self?.onCommand?(.paste)
            case .pasteInsert: self?.onCommand?(.pasteInsert)
            case .pasteAttributes: self?.onCommand?(.pasteAttributes)
            case .delete: self?.onCommand?(.delete)
            case .rippleDelete: self?.onCommand?(.rippleDelete)
            case .enable: self?.onCommand?(.enableClip)
            case .useTake: self?.session.useSelectedTakeForRange()
            case .link, .unlink: self?.onCommand?(.link)
            case .nest: self?.onNest?()
            case .unnest: self?.session.unnestSelection()
            case .group: self?.onCommand?(.group)
            case .ungroup: self?.onCommand?(.ungroup)
            case .bundle: self?.onCommand?(.bundle)
            case .unbundle: self?.onCommand?(.unbundle)
            case .editOriginal: self?.onCommand?(.editOriginal)
            case .revealInProject:
                if let id = self?.session.mediaOfSelection.first { self?.projectView.reveal(media: id) }
            case .extendToSequenceEnd: self?.onCommand?(.extendToSequenceEnd)
            case .speed: self?.onCommand?(.speedDuration)
            case .reverse: self?.onCommand?(.reverseClip)
            case .audioGain: self?.onCommand?(.audioGain)
            case .removeSilences: self?.onCommand?(.removeSilences)
            case .removeFillerWords: self?.onCommand?(.removeFillerWords)
            case .punchInCuts: self?.onCommand?(.punchInCuts)
            case .fitMusicToLength: self?.onCommand?(.fitMusicToLength)
            case .timeRemapping: self?.onCommand?(.toggleTimeRemapping)
            case .setToFrameSize: self?.onFrameSize?()
            case .setToFillFrame: self?.onFillFrame?()
            case .rename: self?.renameSelectedClip()
            case .addClipMarker:
                guard let self, let id = self.timelineView.selection.first else { return }
                let tv = self.timelineView
                let pointer = tv.geometry.time(atX: p.x)
                let clip = tv.timeline.tracks.lazy.flatMap(\.clips).first { $0.id == id }
                let at = clip.map { $0.timeline.contains(pointer) ? pointer : self.session.playhead } ?? pointer
                if let m = self.session.addClipMarker(to: id, at: at) { self.editClipMarker(id, m) }
            case .saveAsPreset: self?.saveSelectedClipAsPreset()
            case .makeGraphic: self?.session.makeGraphic()
            case .newColorMatte: self?.presentNewColorMatte()
            case .togglePlaceSequencesAsClips:
                guard let tv = self?.timelineView else { return }
                var s = tv.toolState
                s.placeSequencesAsClips.toggle()
                tv.toolState = s
                tv.onToggleChange?(s.snapping, s.linkedSelection)
            case .saveTitleBlock: self?.saveSelectionAsTitleBlock()
            case .saveTemplate: self?.saveSelectionAsTemplate()
            case .toggleZones: self?.toggleZonesOfSelection()
            case .speedRamp(let p, let onBeat): self?.onCommand?(.speedRampPreset(p, onBeat: onBeat))
            case .label, .editCaption, .splitCaption, .mergeCaptions: break   // captions have their own menu (`captionMenu`)
            }
        }
        // Sync and edit-point entries go on top of the clip menu.
        rows.insert(contentsOf: syncMenuItems(at: p) + angleMenuItems(at: p) + editPointItems(at: p), at: 0)
        if session.selection.count == 1, session.singleSelectedClip?.acceptsColor == true {
            rows.append(SQMenuItem(title: "Grade From Previous Clip") { [weak self] in self?.session.gradeFromPreviousClip(back: 1) })
            rows.append(SQMenuItem(title: "Grade From Clip Before Previous") { [weak self] in self?.session.gradeFromPreviousClip(back: 2) })
            rows.append(SQMenuItem(title: "Grade All From This Camera") { [weak self] in
                guard let self else { return }
                let n = session.gradeAllFromCamera()
                if n > 0 { onStatus?(SQL10n.format("Graded %d clips from this camera.", n)) }
            })
        }
        return rows
    }

    /// New Color Matte…: dialog (name, color, duration), then the matte goes on the timeline at the playhead.
    func presentNewColorMatte() {
        guard session.activeTimeline != nil else { onStatus?("Open a sequence first."); return }
        guard let window = timelineView.window else { return }
        ColorMatteDialog.present(on: window) { [weak self] r in
            guard let self else { return }
            session.stopPlayback()
            guard session.addColorMatte(r.color, name: r.name, duration: r.duration) != nil else { return }
            session.seek(to: session.playhead)
        }
    }

    /// Rename sheet for the one selected clip.
    func renameSelectedClip() {
        guard let window = timelineView.window, let clip = session.singleSelectedClip, session.selection.count == 1 else { return }
        let alert = SQDialog()
        alert.messageText = "Rename Clip"
        let field = SQDialog.makeField(width: 260)
        field.stringValue = clip.name
        alert.accessoryView = field
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { if response == .first { self?.session.renameSelectedClip(to: field.stringValue) } }
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
        source.model.onDropFiles = { [weak self] urls in   // MON-33: import, then open the first in Source
            Task { [weak self] in
                guard let self else { return }
                await projectModel.importFiles(urls)
                if let id = urls.lazy.compactMap({ self.projectModel.mediaID(forImported: $0) }).first { _ = self.source.open(all: [id]) }
            }
        }
        monitorModel.onDropMedia = { [weak self] ids in self?.session.placeMedia(ids, mode: .overwrite) }   // SH-54
        // Program drop zones: left half Insert, right half Overwrite (both at the playhead).
        monitorModel.onDropMediaZone = { [weak self] ids, zone in
            self?.session.placeMedia(ids, mode: zone == .insert ? .insert : .overwrite)
        }
        monitorModel.onQualityChange = { [weak self] q in self?.session.engine.quality = q.decodeScale }
        session.engine.showsTransparencyGrid = monitorModel.showsTransparencyGrid
        monitorModel.onTransparencyGridChange = { [weak self] on in self?.session.engine.showsTransparencyGrid = on }
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
            case .clearIn: c = .clearIn
            case .clearOut: c = .clearOut
            case .clearInOut: c = .clearInOut
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
            case .replace, .fitToFill: return     // Source monitor only
            }
            self?.onCommand?(c)
        }
    }

    func toggleSafeMargins() {
        monitorModel.safeMargins.toggle()
        monitorView.safeMarginsView.needsDisplay = true
        updateOverlay()    // snap targets follow the same value
    }

    private func wireSource() {
        source.onStatus = { [weak self] m in self?.onStatus?(m) }
        source.onStartedPlaying = { [weak self] in
            self?.session.stopPlayback()
            self?.onSourceStartedPlaying?()
        }
        source.onRevealInProject = { [weak self] id in self?.projectView.reveal(media: id) }
        projectView.onOpenMedia = { [weak self] id in
            guard let self, source.open(id) else { return }
            onShowSource?()
        }
        projectView.onOpenSequence = { [weak self] id in self?.session.setActiveTimeline(id) }
        projectView.onPlace = { [weak self] ids, mode in self?.session.placeMedia(ids, mode: mode) }
        projectView.onPlaceSequences = { [weak self] ids, mode in self?.session.placeSequences(ids, mode: mode) }
        projectView.onNewSequenceFromClip = { [weak self] id in self?.session.newSequence(fromMedia: id) }
        projectView.onNewColorMatte = { [weak self] in self?.presentNewColorMatte() }
        projectView.onCreateAnglesClip = { [weak self] ids in self?.onCreateAnglesClipFromMedia?(ids) }
        projectView.onMakeSubclip = { [weak self] id in
            guard let self, self.session.makeSubclip(of: id) == nil, let e = self.session.lastError else { return }
            self.projectView.onNotice?(e)
        }
        projectView.onEditOriginal = { [weak self] ids in
            guard let self else { return }
            var seen = Set<String>()
            let paths = ids.compactMap { self.session.project.media($0)?.path }.filter { seen.insert($0).inserted }
            for p in paths where FileManager.default.fileExists(atPath: p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        }
        wireSourceFlow()
        projectView.onNewSequence = { [weak self] in self?.onCommand?(.newSequence) }
        projectView.onReplaceFootage = { [weak self] id in self?.replaceFootage(id) }
        projectView.onLocateMedia = { [weak self] id in self?.locateOffline(id) }
        projectView.onExtractAudio = { [weak self] id in
            guard let self else { return }
            Task { @MainActor in
                do {
                    if try await self.projectModel.extractAudio(of: id, resolver: self.session.media) == nil {
                        self.projectView.onNotice?("Extract Audio: the file could not be added.")
                    }
                } catch AudioExtraction.Failure.noAudio {
                    self.projectView.onNotice?("This item has no sound.")
                } catch AudioExtraction.Failure.offline {
                    self.projectView.onNotice?(SQL10n.string("The item is offline. Reconnect it first."))
                } catch {
                    self.projectView.onNotice?(SQL10n.format("Extract Audio failed: %@", SQL10n.errorText(error)))
                }
            }
        }
        projectView.onConformToConstantFrameRate = { [weak self] ids in self?.conformToConstantFrameRate(ids) }
        monitorView.safeMarginsView.rectProvider = { [weak self] in self?.surface.mapping.canvasRect ?? .zero }
        monitorView.safeMarginsView.platformZoneProvider = { [weak self] in
            guard let self, let t = session.displayTimeline else { return nil }
            return monitorModel.safeZone.normRect(frameAspect: Double(t.format.displayWidth) / Double(max(t.format.height, 1)))
        }
        monitorView.safeMarginsView.platformMockProvider = { [weak self] in
            guard let self, monitorModel.showsPlatformMock, let t = session.displayTimeline else { return [] }
            return monitorModel.safeZone.uiMock(frameAspect: Double(t.format.displayWidth) / Double(max(t.format.height, 1)))
        }
        monitorModel.onSafeZoneChange = { [weak self] _ in
            self?.monitorView.safeMarginsView.needsDisplay = true
            self?.updateOverlay()   // the snap lines follow the zone
        }
        monitorModel.onScrubBegan = { [weak self] in self?.session.beginScrub() }
        monitorModel.onScrub = { [weak self] t in self?.session.scrub(to: t) }
        monitorModel.onScrubEnded = { [weak self] in self?.session.endScrub() }
        monitorModel.contextMenuBuilder = { [weak self] in self?.programMenuItems() ?? [] }
        monitorModel.onPickFormat = { [weak self] v in self?.session.setActiveVariant(v) }
        monitorModel.onAddFormat = { [weak self] p in self?.session.addVariant(p) }
        monitorModel.onRemoveFormat = { [weak self] v in self?.session.removeVariant(v) }
    }

    /// Conform to Constant Frame Rate: one background job per item (Background Jobs lists them with progress and Cancel).
    /// The conformed file goes next to the project (else next to the source); the item takes it over, undoable.
    private func conformToConstantFrameRate(_ ids: [MediaRef.ID]) {
        for id in ids {
            guard let ref = session.project.media(id) else { continue }
            let folder = projectModel.projectFolder?() ?? URL(fileURLWithPath: ref.path).deletingLastPathComponent()
            let name = ref.name
            onStatus?(SQL10n.format("Conforming %@ to a constant frame rate…", name))
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await conformRunner.conform(id, in: session, folder: folder)
                    waveforms.invalidate(id)
                    projectView.forgetThumbnail(id)
                    clipThumbnails.forget(id)
                    projectModel.scheduleOfflineRefresh()
                    if source.mediaID == id { source.open(id) }
                    onStatus?(SQL10n.format("Conformed %@ to a constant frame rate.", name))
                } catch is CancellationError {
                    onStatus?(SQL10n.format("Conform of %@ canceled.", name))
                } catch ConstantFrameRateConform.Failure.offline {
                    projectView.onNotice?("The item is offline. Reconnect it first.")
                } catch ConstantFrameRateConform.Failure.alreadyRunning {
                    projectView.onNotice?(SQL10n.format("%@ is already being conformed.", name))
                } catch {
                    projectView.onNotice?(SQL10n.format("Conform failed: %@", SQL10n.errorText(error)))
                }
            }
        }
    }

    /// Replace Footage / Link Media: pick a file, probe it, and let it take over the item (clips, marks, label stay).
    private func replaceFootage(_ id: MediaRef.ID) {
        guard let ref = session.project.media(id) else { return }
        let panel = NSOpenPanel()
        panel.message = SQL10n.format("Choose the file that replaces “%@”.", ref.name)
        panel.prompt = ref.status() == .missing ? "Link" : "Replace"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ref.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let probed = try? await MediaImporter.probe(url).0 else { onStatus?(SQL10n.format("Could not read %@.", url.lastPathComponent)); return }
            session.replaceFootage(id, with: probed)
            waveforms.invalidate(id)
            projectView.forgetThumbnail(id)
            clipThumbnails.forget(id)
            projectModel.scheduleOfflineRefresh()
            if source.mediaID == id { source.open(id) }
            onStatus?(SQL10n.format("Replaced footage with %@.", url.lastPathComponent))
        }
    }

    /// Locate… on one offline item: choose its file (the panel opens at the folder it was in), relink that item only,
    /// then offer the other offline items whose files sit in the same folder.
    private func locateOffline(_ id: MediaRef.ID) {
        guard let ref = session.project.media(id), ref.status() == .missing else { return }
        let panel = NSOpenPanel()
        panel.message = SQL10n.format("Locate “%@”.", ref.name)
        panel.prompt = "Locate"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let old = URL(fileURLWithPath: ref.path).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: old.path) { panel.directoryURL = old }
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.finishLocate(id, url)
            }
        }
    }

    /// Media files changed on disk (re-exported, gone, back): thumbnails, waveforms and offline marks are rebuilt, and an
    /// open Source monitor item is opened again.
    func mediaFilesChanged(_ ids: Set<MediaRef.ID>) {
        for id in ids { waveforms.invalidate(id); projectView.forgetThumbnail(id); clipThumbnails.forget(id) }
        projectModel.scheduleOfflineRefresh()
        if let open = source.mediaID, ids.contains(open) { source.open(open) }
    }

    private func finishLocate(_ id: MediaRef.ID, _ url: URL) {
        guard session.locateMedia(id, at: url) else { return }
        waveforms.invalidate(id)
        projectView.forgetThumbnail(id)
        clipThumbnails.forget(id)
        projectModel.scheduleOfflineRefresh()
        if source.mediaID == id { source.open(id) }
        onStatus?(SQL10n.format("Located %@.", url.lastPathComponent))
        Task { [weak self] in
            guard let self else { return }
            let siblings = await session.missingSiblings(in: url.deletingLastPathComponent(), excluding: id)
            guard !siblings.isEmpty else { return }
            let n = siblings.count
            SQDialog.confirm(SQL10n.plural(n, one: "Reconnect %@ more file in this folder?", other: "Reconnect %@ more files in this folder?"),
                             message: SQL10n.format(n == 1 ? "%@ other offline file is in “%@”." : "%@ other offline files are in “%@”.", String(n), url.deletingLastPathComponent().lastPathComponent),
                             confirm: "Reconnect", cancel: "Not Now", in: projectView.window) { [weak self] yes in
                guard yes, let self else { return }
                session.relinkSiblings(siblings)
                for sid in siblings.keys { waveforms.invalidate(sid); projectView.forgetThumbnail(sid); clipThumbnails.forget(sid) }
                projectModel.scheduleOfflineRefresh()
                onStatus?(SQL10n.plural(n, one: "Reconnected %@ more file.", other: "Reconnected %@ more files."))
            }
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

    private func programMenuItems() -> [SQMenuItem] {
        var rows: [SQMenuItem] = []
        func add(_ title: String, _ enabled: Bool = true, state: Bool? = nil, command: EditorCommand? = nil,
                 _ action: @escaping @MainActor () -> Void) {
            rows.append(SQMenuItem(title: title, shortcut: command.map { ProjectPanelMenus.shortcut($0) } ?? "",
                                   isEnabled: enabled, isChecked: state ?? false, action: action))
        }
        func cmd(_ c: EditorCommand, _ enabled: Bool = true, state: Bool? = nil) {
            add(c.title, enabled, state: state, command: c) { [weak self] in self?.onCommand?(c) }
        }
        let io = session.activeTimeline?.inOut
        cmd(.markIn); cmd(.markOut)
        cmd(.goToIn, io != nil); cmd(.goToOut, io != nil); cmd(.clearInOut, io != nil)
        rows.append(.separator)
        cmd(.addMarker); cmd(.lift, io != nil); cmd(.extract, io != nil)
        rows.append(.separator)
        cmd(.matchFrame); cmd(.reverseMatchFrame, source.mediaID != nil); cmd(.exportFrame)
        rows.append(.separator)
        // W6.7 masks on the selected clip (minimal hooks; Effect Controls rows follow).
        let maskClip = effectModel.clip != nil && effectModel.clip?.kind == .video
        add("Add Rectangle Mask", maskClip) { [weak self] in self?.effectModel.addMask(.rectangle); self?.updateOverlay() }
        add("Add Ellipse Mask", maskClip) { [weak self] in self?.effectModel.addMask(.ellipse); self?.updateOverlay() }
        // C6: the other video tracks of the clip's sequence, nearest above first; the default (nearest above with a clip at the
        // playhead) is checked and is what a click on the title adds.
        let pictureChoices = maskClip ? effectModel.pictureTrackChoices().filter { $0.track != nil } : []
        let pictureDefault = effectModel.defaultPictureTrack
        rows.append(SQMenuItem(title: "Add Picture Mask", isEnabled: !pictureChoices.isEmpty, submenu: pictureChoices.map { c in
            SQMenuItem(title: c.title, isChecked: c.track == pictureDefault) { [weak self] in
                self?.effectModel.addPictureMask(track: c.track); self?.updateOverlay()
            }
        }))
        add("Add Color Range Mask", maskClip) { [weak self] in self?.effectModel.addColorRangeMask(); self?.updateOverlay() }
        cmd(.addSubjectMask, session.addSubjectMaskEnabled)
        add("Delete Masks", maskClip && !(effectModel.clip?.masks.isEmpty ?? true)) { [weak self] in
            self?.effectModel.removeAllMasks(); self?.updateOverlay()
        }
        rows.append(.separator)
        add("Safe Margins", state: monitorModel.safeMargins) { [weak self] in self?.toggleSafeMargins() }
        add("Mask Tint", state: Self.showsMaskTint) { [weak self] in self?.toggleMaskTint() }
        rows.append(SubjectMaskQualityMenu.item { [weak self] q in
            self?.onStatus?(SQL10n.format("Subject mask edges: %@. Track the mask again to change frames that are already tracked.", SQL10n.string(q.title)))
        })
        cmd(.toggleLoop, state: session.bounds.loop)
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Zoom", submenu: MonitorMenus.zoomItems(current: monitorModel.zoom) { [weak self] in self?.monitorModel.setZoom($0) }))
        return rows
    }

    // MARK: Program monitor overlay, Type tool

    private func wireGraphics() {
        graphicsOverlay.frame = surface.bounds
        graphicsOverlay.autoresizingMask = [.width, .height]
        surface.addSubview(graphicsOverlay, positioned: .above, relativeTo: surface.overlay)
        graphicsOverlay.viewMapping = { [weak self] in
            self?.surface.mapping ?? MonitorViewMapping(viewSize: .zero, backingScale: 2, sequenceSize: .zero, zoom: .fit)
        }
        graphics.onSelectionChange = { [weak self] in
            guard let self else { return }
            graphicsView.selectionChanged()
            clipSections.graphicItemsChanged()
            effectModel.sync(with: session, change: .selection)     // Controls follows the picked item
            updateGraphicsOverlay()
            syncItemLaneSelection()
        }
        clipSections.graphicsEditor = graphics
        graphicsView.onMakeGraphic = { [weak self] in self?.session.makeGraphic() }
        graphicsView.onNewGraphic = { [weak self] in self?.newGraphicsClip() }
        graphicsView.onSaveTemplate = { [weak self] in self?.saveSelectionAsTemplate() }
        graphicsView.effectPresets = { [weak self] in self?.layerEffectPresets() ?? [] }
        graphicsView.onSaveEffectPreset = { [weak self] preset in self?.saveLayerEffectPreset(preset) }
        clipSections.onShowGraphics = { [weak self] in self?.onShowGraphics?() }
        graphicsOverlay.onEditText = { [weak self] id in self?.beginGraphicTextEditing(id, isNew: false, depth: 0, selectAll: false, caretAt: nil) }
    }

    /// Sequence > New Graphics Clip: an empty graphic at the playhead, the Graphics panel in front.
    @discardableResult
    func newGraphicsClip() -> Bool {
        guard graphics.newGraphicsClip() != nil else { return false }
        onShowGraphics?()
        return true
    }

    private func updateGraphicsOverlay() {
        // A text edit ends the moment its layer, clip or selection goes away.
        if let e = graphicTextEditing, !graphics.isEditingValid(layer: e.layer, clip: e.clip) { surface.endTextEditing() }
        // Select: handles and drags. Type, or a text field open: the frame is drawn only (MonitorTextInteraction table).
        // A Create shape mode: the frames of the Graphic the new item goes into, drawn only.
        let creating = if case .create = surface.tool { true } else { false }
        let show = !session.isPlaying && (surface.tool == .select || surface.tool == .type || creating) && graphicsActive
        if !show, graphicsOverlay.isHidden { return }      // playback ticks: nothing to redraw or re-register while it stays hidden
        graphicsOverlay.isInteractive = surface.tool == .select && !surface.isEditingText
        graphicsOverlay.isHidden = !show
        graphicsOverlay.needsDisplay = true
        graphicsOverlay.window?.invalidateCursorRects(for: graphicsOverlay)
    }

    /// A graphics clip is selected and the playhead is inside it: the monitor works on its layers.
    private var graphicsActive: Bool {
        graphics.clip.map { $0.timeline.contains(session.playhead) } == true
    }

    /// The clip a mask overlay gesture started on (nil: none open, or it was refused). A drag belongs to that clip: if Effect
    /// Controls shows another one mid-drag the edits stop, and the gesture still ends on `.ended`.
    private static var maskGestureClip: Clip.ID?

    /// One mask handle gesture: refused up front (with a notice) for an animated path while the playhead is outside the clip,
    /// where the edit would snap back; otherwise opens an undo gesture on `.began` and always closes it on `.ended`.
    private func maskGesture(_ phase: TransformOverlayView.Phase, _ id: ClipMask.ID, needsPlayhead: Bool = true,
                             _ edit: (EditorPanels) -> Void) {
        switch phase {
        case .began:
            Self.maskGestureClip = nil
            guard let clip = effectModel.clip, clip.id == overlayTarget?.clip else { return }
            if needsPlayhead, effectModel.maskEditNeedsPlayhead(id) {
                onStatus?("Put the playhead on the clip to edit an animated mask path there.")
                return
            }
            Self.maskGestureClip = clip.id
            session.stopPlayback(); effectModel.beginGesture()
        case .changed:
            guard Self.maskGestureClip != nil, Self.maskGestureClip == effectModel.clip?.id else { return }
            edit(self)
        case .ended:
            guard let started = Self.maskGestureClip else { return }
            Self.maskGestureClip = nil
            if started == effectModel.clip?.id { edit(self) }
            effectModel.endGesture()
        }
    }

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
        o.onMaskVertex = { [weak self] phase, id, index, point in
            self?.maskGesture(phase, id) { $0.effectModel.moveMaskVertex(id, index: index, to: point) }
        }
        o.onMaskEdit = { [weak self] phase, edit in
            self?.maskGesture(phase, edit.maskID, needsPlayhead: edit.editsAtPlayhead) { $0.applyMaskEdit(edit) }
        }
        o.onDragCancelled = { [weak self] in
            guard let self else { return }
            effectModel.cancelGesture()
            Self.maskGestureClip = nil
            overlayGesture = nil
            textResizeStart = nil
        }
        o.onBodyDoubleClick = { [weak self] in self?.beginTextEditing(selectAll: false, isNew: false) }
        surface.onTypeClick = { [weak self] pos in self?.typeToolClick(pos) }
        surface.onTextDoubleClick = { [weak self] pos in self?.editGraphicText(at: pos) }
        surface.onTypeBox = { [weak self] centre, box in self?.typeToolBox(centre, box) }
        surface.onStyleToggle = { [weak self] t in self?.toggleEditedStyle(t) }
        surface.onTextEdited = { [weak self] text in
            guard let self, !captionEdited(text) else { return }   // a caption edited in the monitor, else the text layer
            if graphicTextEditing != nil { graphicTextEdited(text) } else { textEdited(text) }
        }
        surface.onTextEditEnded = { [weak self] text in
            guard let self, !captionEditEnded(text) else { return }
            if graphicTextEditing != nil { graphicTextEditEnded(text) } else { textEditEnded(text) }
        }
        surface.captionHitTest = { [weak self] p in self?.captionHit(p) ?? false }
        surface.onPickClip = { [weak self] p in self?.pickClip(at: p) }
        surface.onMagicNeedsClip = { [weak self] _ in self?.previewMagic() }
        surface.onCaptionDragBegan = { [weak self] p in self?.beginCaptionDrag(at: p) ?? false }
        surface.onCaptionDragMoved = { [weak self] d, t in self?.moveCaptionDrag(by: d, snap: t) ?? .none }
        surface.onCaptionDragEnded = { [weak self] in self?.captionDrag = nil }
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
            textResizeStart = nil
            if target.isText, !target.isGraphics, let ref = session.displayedSelectedClip?.generator, ref.kind == GeneratorRef.text,
               let (template, animations) = try? TextGenerator.decode(ref) {
                textResizeStart = (template, animations, session.undoDepth, true)
            }
            effectModel.beginGesture()
        case .changed, .ended:
            guard let g = overlayGesture else { return }
            var t = t
            if var r = textResizeStart, t.scale != g.start.scale {
                // Font size follows the handle (sequence px); Scale stays as it was. Position keeps the opposite edge fixed.
                let ratio = Self.textResizeFactor(from: g.start.scale, to: t.scale)
                session.updateTextClip(g.target.clip, template: r.template.resized(by: ratio), animations: r.animations, continuesGesture: !r.first)
                r.first = false
                textResizeStart = r
                t.scale = g.start.scale
            }
            let wrote = effectModel.setTransform(g.target.baseTransform(fromDisplay: t), from: g.target.baseTransform(fromDisplay: g.start))
            if !wrote {   // animated property and the playhead is outside the clip: nothing to write, hide instead of snapping back
                effectModel.endGesture(); overlayGesture = nil
                overlayTarget = nil; surface.setTarget(nil, snap: nil)
                return
            }
            if phase == .ended {
                effectModel.endGesture(); overlayGesture = nil
                if let r = textResizeStart, !r.first, session.undoDepth > r.depth + 1 { session.foldUndo(fromDepth: r.depth, name: "Resize Text") }
                textResizeStart = nil
            }
        }
    }

    /// Font size factor for a scale-handle drag: the geometric mean of the two axis ratios (edge handles stretch one axis).
    static func textResizeFactor(from start: Vec2, to now: Vec2) -> Double { TextTemplate.resizeFactor(from: start, to: now) }

    /// Type tool: click on existing text edits it; a click elsewhere makes point text (new text clip on the top free
    /// video track at the playhead, 5 s) with the caret in it at once.
    private func typeToolClick(_ position: Vec2) {
        typeToolAct(at: position, box: nil)
    }

    /// Runs `GraphicsEditor.typeToolOutcome` for a click (`box` nil) or drag at `position` (sequence px).
    private func typeToolAct(at position: Vec2, box: TextBox?) {
        // Existing text of a Graphic that is not selected: select that Graphic, the click then edits the layer.
        selectGraphicOfTextLayer(at: position)
        // No Graphic selected, no text under the pointer: the Graphic under the playhead on the targeted track takes the text.
        if !graphicsActive, textClip(at: position) == nil { adoptCreateTarget() }
        let hit = textClip(at: position)
        var pointText = false
        if let hit, let c = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == hit }),
           let ref = c.generator, let (t, _) = try? TextGenerator.decode(ref) { pointText = t.box == nil }
        switch graphics.typeToolOutcome(at: position, box: box, textClipHit: hit, hitIsPointText: pointText) {
        case .editLayer:
            guard let map = graphics.mapping else { return }
            graphicTypeToolClick(map.canvasPoint(fromSequence: position))
        case .addLayer(let at, let areaBox): graphicTypeToolClick(at, box: areaBox)
        case .editTextClip: typeToolEditTextClip(hit, at: position)
        case .newGraphic(_, let b):
            if let b { createText(at: position, box: b) } else { typeToolEditTextClip(nil, at: position) }   // a click ends an open edit first
        }
    }

    /// A text layer of a graphics clip lies under `position` and that clip is not the selected one: selects the clip.
    /// Returns the layer hit (nil: none, selection unchanged).
    @discardableResult
    private func selectGraphicOfTextLayer(at position: Vec2) -> GraphicsEditor.TextLayerHit? {
        guard let hit = graphics.textLayerHit(atSequence: position) else { return nil }
        if graphics.clip?.id != hit.clip {
            session.select(clips: [hit.clip])
            graphics.sync()
            updateOverlay()
        }
        return hit
    }

    /// Select tool double-click: edits the text layer under the pointer (selecting its graphic first).
    private func editGraphicText(at position: Vec2) {
        guard let hit = selectGraphicOfTextLayer(at: position), graphics.clip?.id == hit.clip else { return }
        session.stopPlayback()
        beginGraphicTextEditing(hit.layer, isNew: false, depth: 0, selectAll: false, caretAt: nil)
    }

    private func typeToolEditTextClip(_ hit: Clip.ID?, at position: Vec2) {
        for action in MonitorTextInteraction.actions(tool: .type, hit: hit == nil ? .empty : .textLayer, editing: surface.isEditingText, event: .click) {
            switch action {
            case .endEditing: surface.endTextEditing()
            case .editText(let caretAtClick):
                guard let hit else { break }
                session.stopPlayback()
                session.select(clips: [hit])
                updateOverlay()
                beginTextEditing(selectAll: false, isNew: false, caretAt: caretAtClick ? position : nil)
            case .createText: createText(at: position, box: nil)
            case .createLayerText, .editLayerText: break   // only for a selected graphic
            }
        }
    }

    /// Type tool with a graphic selected: click on one of its text layers edits it, a click elsewhere adds a text layer
    /// there (typed at once). A drag (`box`) makes area text.
    private func graphicTypeToolClick(_ canvasPoint: Vec2, box: TextBox? = nil) {
        let hit = graphics.textLayer(at: canvasPoint)
        for action in MonitorTextInteraction.actions(tool: .type, hit: hit == nil ? .empty : .textLayer, editing: surface.isEditingText,
                                                     event: .click, inGraphic: true) {
            switch action {
            case .endEditing: surface.endTextEditing()
            case .editLayerText:
                guard let hit else { break }
                graphics.select([hit])
                beginGraphicTextEditing(hit, isNew: false, depth: 0, selectAll: false, caretAt: nil)
            case .createLayerText:
                session.stopPlayback()
                let depth = session.undoDepth
                guard let id = graphics.addText(at: canvasPoint, box: box) else { break }
                beginGraphicTextEditing(id, isNew: true, depth: depth, selectAll: true, caretAt: nil)
                surface.protectTextFocus(seconds: 1)
                reassertTextEditing(id)
            case .createText, .editText: break
            }
        }
    }

    /// Opens the monitor's text field on layer `id` of the selected graphic. One undo step: typing merges into the
    /// layer's step (a new layer: add + typing fold into one "Add Text").
    private func beginGraphicTextEditing(_ id: UUID, isNew: Bool, depth: Int, selectAll: Bool, caretAt: Vec2?) {
        graphics.select([id])
        guard let clip = graphics.clip, let target = graphics.textEditTarget(for: id), let template = graphics.textTemplate else { return }
        session.stopPlayback()
        graphics.beginGesture()
        graphicTextEditing = GraphicTextEditing(layer: id, clip: clip.id, isNew: isNew, depth: depth)
        surface.targetIsText = false   // the graphics overlay draws the layer's frame
        updateGraphicsOverlay()
        surface.beginTextEditing(text: template.text, style: template.style, box: template.box, target: target, selectAll: selectAll, caretAt: caretAt)
    }

    private func graphicTextEdited(_ text: String) {
        guard let e = graphicTextEditing else { return }
        guard graphics.isEditingValid(layer: e.layer, clip: e.clip) else { surface.endTextEditing(); return }
        graphics.updateText("Edit Text") { $0.text = text }
    }

    private func graphicTextEditEnded(_ text: String) {
        guard let e = graphicTextEditing else { return }
        graphicTextEditing = nil
        if e.isNew, graphics.isEditingValid(layer: e.layer, clip: e.clip) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                graphics.discardNewLayer(rewindingTo: e.depth)   // an empty new layer leaves no trace
            } else {
                session.foldUndo(fromDepth: e.depth, name: "Add Text")
            }
        }
        updateGraphicsOverlay()
        updateOverlay()
    }

    /// Type tool drag: area text. The box wraps the text; the caret is in it at once.
    private func typeToolBox(_ centre: Vec2, _ box: TextBox) {
        typeToolAct(at: centre, box: box)
    }

    /// Type tool on empty canvas: a new Graphic clip with one text layer (typed at once). One undo step (clip + layer + typing
    /// fold into "Add Text"). An area-text drag gives the layer a box.
    private func createText(at position: Vec2, box: TextBox?) {
        session.stopPlayback()
        let depth = session.undoDepth
        // Never over footage: with no free video track above the picture a new track goes on top (same undo step).
        guard session.addGraphicsClip(duration: Time(Int64(AppSettings.load().defaultTextSeconds), 1), neverOverwrite: true) != nil else { return }
        graphics.sync()
        guard let map = graphics.mapping, let id = graphics.addText(at: map.canvasPoint(fromSequence: position), box: box.map {
            let d = map.canvasDelta(fromSequence: Vec2($0.width, $0.height)); return TextBox(width: abs(d.x), height: abs(d.y))
        }) else {
            session.rewindUndo(toDepth: depth); graphics.sync(); return
        }
        session.seek(to: session.playhead)   // an empty sequence clamped the engine to 0: show the new text now
        updateOverlay()
        beginGraphicTextEditing(id, isNew: true, depth: depth, selectAll: true, caretAt: nil)
        surface.protectTextFocus(seconds: 1)
        reassertTextEditing(id)
    }

    /// A new text must be selected and typing at once. Session changes that land after the click (engine frame, track
    /// sync) must not leave it unselected and closed: one short check, and the editor is reopened on that layer.
    /// shortcut: a timed re-check instead of finding the late change that drops it; upgrade when that cause is known.
    private func reassertTextEditing(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, graphicTextEditing == nil, !surface.isEditingText, surface.tool == .type,
                  graphics.document?.layer(id) != nil else { return }
            beginGraphicTextEditing(id, isNew: false, depth: 0, selectAll: true, caretAt: nil)
        }
    }

    /// Selection tool click on the picture: select the topmost clip under the pointer (Premiere); empty canvas keeps the selection.
    private func pickClip(at p: Vec2) {
        // Magic works on video from a file: a title or graphic above the picture does not catch its click.
        let magic = surface.tool == .mask(.magic)
        guard let tl = session.displayTimeline else { return }
        let picked = TextHitTest.topmostVisualClip(at: p, in: tl, project: session.project, time: session.playhead,
                                                   variant: session.activeVariantID,
                                                   accepting: { !magic || MagicMaskTool.canUse($0) })
        if !magic, pickGraphicText(at: p, above: picked.flatMap { id in tl.tracks.firstIndex { $0.clips.contains { $0.id == id } } }) { return }
        guard let id = picked else { return }
        session.select(clips: [id])
        updateOverlay()
        if magic { updateMagicOverlay() }
    }

    /// Select tool click on a graphic's text that lies above the clip picked by `pickClip` (or where nothing else is):
    /// selects that graphic and the text layer. True when it did.
    private func pickGraphicText(at p: Vec2, above trackIndex: Int?) -> Bool {
        // shortcut: the layer hit is the topmost over all tracks, not the topmost on a targeted track; upgrade if overlapping graphics on a targeted and a higher track matter.
        guard let hit = graphics.textLayerHit(atSequence: p), let tl = session.displayTimeline,
              TextHitTest.hitWins(hit.trackIndex, over: trackIndex, tracks: tl.tracks) else { return false }
        session.select(clips: [hit.clip])
        graphics.sync()
        graphics.select([hit.layer])
        updateOverlay()
        return true
    }

    /// Magic mode and the selection gives it nothing to work on under the playhead (nothing selected, the selected clip
    /// lies elsewhere or is a title, still or nested sequence): the topmost video clip under the pointer is previewed,
    /// its object under the pointer highlighted. Hover never changes the selection; the click selects that clip and
    /// picks (`pickClip`, then the overlay's forwarded press).
    func previewMagic() {
        guard surface.tool == .mask(.magic), !session.isPlaying, magicTool.source == nil,
              let p = surface.magicPointerPosition, let tl = session.displayTimeline,
              let id = TextHitTest.topmostVisualClip(at: p, in: tl, project: session.project, time: session.playhead,
                                                     variant: session.activeVariantID, accepting: MagicMaskTool.canUse),
              let clip = tl.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
              let target = OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead,
                                              variant: session.activeVariantID) else {
            magicTool.preview(nil)
            return
        }
        let layer = TransformOverlayView.MagicPreviewLayer(transform: target.displayTransform, mediaPixelSize: target.size)
        magicTool.preview(clip, localPlayhead: session.playhead - clip.start, layer: layer,
                          at: surface.overlay.magicPreviewPoint(layer))
    }

    /// Topmost visible text clip under the playhead whose drawn rectangle contains `p` (sequence px from the center).
    private func textClip(at p: Vec2) -> Clip.ID? {
        guard let tl = session.displayTimeline else { return nil }       // as the Program monitor shows it (W5.1)
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

    private func beginTextEditing(selectAll: Bool, isNew: Bool, depth: Int = 0, caretAt: Vec2? = nil) {
        // As the Program monitor shows it: in a variant whose override has its own text, that text (W5.1).
        guard let clip = session.displayedSelectedClip, let ref = clip.generator, let target = overlayTarget, target.clip == clip.id,
              let (template, animations) = try? TextGenerator.decode(ref) else { return }
        session.stopPlayback()
        textEditing = TextEditing(clip: clip.id, template: template, animations: animations, isNew: isNew, depth: depth)
        surface.beginTextEditing(text: template.text, style: template.style, box: template.box, target: target, selectAll: selectAll, caretAt: caretAt)
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
        // Without a target the Magic state is cleared too (no stale highlight or pick for the next clip).
        defer { refreshDynamicZoomEdit(); refreshStepWindowEdit(); updateGraphicsOverlay(); if overlayTarget == nil { updateMagicOverlay() } }
        // The monitor shows the active format variant (W5.1): its canvas, its clips as resolved there.
        // The Color page's solo (source file view or a still in place) shows the raw picture, not the clip's framing:
        // no transform handles over it.
        guard let tl = session.displayTimeline, session.colorSourceView == nil, session.colorSoloClip == nil else {
            // No sequence picture here (no timeline, source or solo view): square, never the previous sequence's shape.
            ((surface.viewer as? ViewerView)?.metalLayer as? ShapedMetalLayer)?.pixelAspect = .square
            surface.setTarget(nil, snap: nil); overlayTarget = nil; return
        }
        // The picture and every overlay live in display space; the stored texture is shown at that aspect.
        surface.sequenceSize = CGSize(width: tl.format.displayWidth, height: tl.format.height)
        ((surface.viewer as? ViewerView)?.metalLayer as? ShapedMetalLayer)?.pixelAspect = tl.format.pixelAspect
        // A text raster that is not cached yet is rendered on a background task, never on the main thread (typing
        // is the exception: one short layout per keystroke).
        if !session.isPlaying, !surface.isEditingText, let clip = session.displayedSelectedClip, let ref = clip.generator,
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
        guard !session.isPlaying, let clip = session.displayedSelectedClip,
              let target = OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead,
                                              variant: session.activeVariantID) else {
            overlayTarget = nil
            if !surface.isEditingText { surface.setTarget(nil, snap: nil) }
            return
        }
        overlayTarget = target       // kept on the Color page: the Step window handles use its geometry
        // The Color page picture is the graded frame, no transform box or handles over it (design board "Color").
        if colorPageActive { surface.setTarget(nil, snap: nil); return }
        // Typing into a graphic's text layer: the field follows that layer's box, not the clip's canvas-sized group.
        let layerTarget = graphicTextEditing.flatMap { graphics.textEditTarget(for: $0.layer) }
        surface.targetIsText = layerTarget == nil && clip.generator?.kind == GeneratorRef.text
        var others: [OverlayTarget] = []
        for c in tl.tracks.filter({ $0.kind == .video && $0.isVisible }).flatMap(\.clips) where c.id != clip.id {
            if let o = OverlayTarget.make(clip: c, project: session.project, timeline: tl, at: session.playhead,
                                          variant: session.activeVariantID) {
                others.append(o)
            }
        }
        surface.overlay.selectedKey = effectModel.selectedKeyIDs(.position).first
        surface.overlay.uniformScale = effectModel.uniformScale
        surface.overlay.masks = effectModel.clip?.id == clip.id ? effectModel.maskOverlays : []
        let areas = Self.safeAreasInUse
        surface.setSafeAreas(areas)
        surface.setNeighborBounds(SnapGuides.otherBounds(others))
        surface.setTarget(layerTarget ?? target, snap: SnapGuides.targets(canvas: surface.sequenceSize, others: SnapGuides.otherBounds(others), safeAreas: areas,
                                                           zone: platformZoneOffsetRect))
        updatePointHandles(clip: clip, target: target)
        updateCropHandles()
        updateMagicOverlay()
        updateMaskTint()
    }

    /// The picked platform's clear rectangle in offset space (sequence px from the canvas center); titles and captions snap to it.
    var platformZoneOffsetRect: CGRect? {
        guard let tl = session.displayTimeline else { return nil }
        return monitorModel.safeZone.offsetRect(canvasWidth: Double(tl.format.displayWidth), canvasHeight: Double(tl.format.height))
    }

    static let safeAreasKey = MonitorPanelModel.safeMarginsKey
    static var showsSafeAreas: Bool { MonitorPanelModel.storedSafeMargins }
    static var safeAreasInUse: [SafeArea] { showsSafeAreas ? [.action, .title] : [] }

    /// Handle id = effect id + "|" + parameter key.
    private func pointProperty(_ id: String, in clip: Clip) -> EffectProperty? {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let eid = UUID(uuidString: parts[0]), let e = clip.effects.first(where: { $0.id == eid }) else { return nil }
        return .fx(eid, kind: e.kind, key: parts[1])
    }

    /// Point parameters of the selected clip's enabled effects as on-canvas handles (px from the layer center, through the
    /// clip's transform). Dragging writes the value at the playhead, one undo step per gesture.
    private func updatePointHandles(clip: Clip, target: OverlayTarget) {
        var handles: [PointHandle] = []
        if effectModel.clip?.id == clip.id {
            for e in clip.effects where e.enabled {
                for p in EffectCatalog.spec(for: e.kind)?.params ?? [] {
                    guard case .point = p.kind, PointHandleMapping.hasHandle(kind: e.kind, key: p.key) else { continue }
                    var v = effectModel.vectorValue(.fx(e.id, kind: e.kind, key: p.key))
                    if PointHandleMapping.isCornerOffset(kind: e.kind) {
                        // Corner Warp: handles only while its section is selected, drawn at the warped corners.
                        guard case .effect(let sid, _)? = effectModel.selectedSection, sid == e.id else { continue }
                        v = PointHandleMapping.cornerLocal(key: p.key, value: v, frame: target.size)
                    }
                    handles.append(PointHandle(id: "\(e.id.uuidString)|\(p.key)",
                                               offset: PointHandleMapping.offset(kind: e.kind, local: v, transform: target.displayTransform)))
                }
            }
        }
        surface.setPointHandles(handles) { [weak self] phase, id, offset in
            guard let self, let target = overlayTarget, effectModel.clip?.id == target.clip,
                  let clip = effectModel.clip, let prop = pointProperty(id, in: clip) else { return }
            if phase == .began { session.stopPlayback(); effectModel.beginGesture(); return }
            let kind = clip.effects.first { id.hasPrefix($0.id.uuidString) }?.kind ?? ""
            var local = PointHandleMapping.local(kind: kind, offset: offset, transform: target.displayTransform)
            if PointHandleMapping.isCornerOffset(kind: kind), case .fx(_, _, let key) = prop {
                local = PointHandleMapping.cornerValue(key: key, local: local, frame: target.size)
            }
            effectModel.setVector(prop, to: local)
            if phase == .ended { effectModel.endGesture() }
        }
    }

    /// Edge handles for the Crop effect while its section is selected in Effect Controls (not while playing or on the Color page).
    /// One drag = one undo step; the value is a percent of the clip's own frame at the playhead.
    func updateCropHandles() {
        // Corner Warp handles follow the selected section too (called on every section change).
        if let c = effectModel.clip, let t = overlayTarget, c.id == t.clip { updatePointHandles(clip: c, target: t) }
        guard let target = overlayTarget, !colorPageActive, !session.isPlaying, effectModel.clip?.id == target.clip,
              case .effect(let id, kind: let kind)? = effectModel.selectedSection, kind == ClipEffect.cropKind,
              let clip = effectModel.clip, clip.effects.first(where: { $0.id == id })?.enabled == true else {
            surface.setCrop(nil, onChange: nil)
            return
        }
        func p(_ key: String) -> EffectProperty { .fx(id, kind: kind, key: key) }
        let insets = CropInsets(left: effectModel.scalarValue(p(ClipEffect.cropLeftKey)) / 100,
                                top: effectModel.scalarValue(p(ClipEffect.cropTopKey)) / 100,
                                right: effectModel.scalarValue(p(ClipEffect.cropRightKey)) / 100,
                                bottom: effectModel.scalarValue(p(ClipEffect.cropBottomKey)) / 100)
        surface.setCrop(insets) { [weak self] phase, edge, fraction in
            guard let self, effectModel.clip?.id == target.clip else { return }
            if phase == .began { session.stopPlayback(); effectModel.beginGesture(); return }
            _ = effectModel.setValue(p(edge.effectKey), to: fraction * 100)
            if phase == .ended { effectModel.endGesture() }
        }
    }

    /// Tool column / key: Hand and Type also act in the Program monitor.
    func setMonitorTool(_ t: ProgramSurfaceView.Tool) { surface.tool = t }

    private func wireEffectControls() {
        effectModel.onEffectCopied = { [weak self] e in self?.session.effectClipboard = e }
        effectModel.onBuiltInCopied = { [weak self] s, c in self?.session.copyBuiltIn(s, of: c) }
        effectModel.canPasteBuiltIn = { [weak self] in self?.session.canPasteAttributes ?? false }
        effectModel.onPasteBuiltIn = { [weak self] in self?.session.pasteAttributes() ?? false }
        effectModel.onEdit = { [weak self] clip, name, coalescing in
            // Effect Controls and the overlay edit the clip as the active format variant shows it (W5.1).
            guard let self else { return }
            let before = session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == clip.id }?.effect(ofKind: ClipEffect.stabilizeKind)
            session.replaceDisplayedClip(clip, name: name, continuesGesture: coalescing)
            // Result / Smoothness / Crop Limit of a Stabilizer: re-plan from the cached analysis (no new Stabilize run).
            // Rolling Shutter Strength scales the stored shear when the frame is drawn: no new plan.
            if let before, let now = clip.effect(ofKind: ClipEffect.stabilizeKind),
               !StabilizerOptions(effect: before).samePlan(as: StabilizerOptions(effect: now)) {
                session.scheduleStabilizerReplan(clip: clip.id, lookup: AppController.stabilizationLookup)
            }
        }
        effectModel.onEditMany = { [weak self] clips, name, coalescing in
            guard let self else { return }
            let before = Dictionary(uniqueKeysWithValues: clips.compactMap { c in
                session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == c.id }?.effect(ofKind: ClipEffect.stabilizeKind).map { (c.id, $0) }
            })
            session.replaceDisplayedClips(clips, name: name, continuesGesture: coalescing)
            // Stabilizer settings edited on several clips re-plan each one, as the single-clip path does.
            let changed = clips.filter { c in
                guard let was = before[c.id], let now = c.effect(ofKind: ClipEffect.stabilizeKind) else { return false }
                return !StabilizerOptions(effect: was).samePlan(as: StabilizerOptions(effect: now))
            }.map(\.id)
            if !changed.isEmpty { session.scheduleStabilizerReplan(clips: changed, lookup: AppController.stabilizationLookup) }
        }
        effectModel.onAudioEdit = { [weak self] clip, name, coalescing in
            self?.session.replaceClip(clip, name: name, continuesGesture: coalescing)
        }
        effectModel.onGestureEnded = { [weak self] in self?.session.endGesture() }
        effectModel.canConvert = { [weak self] clip, effect in self?.session.canConvertToKeyframes(effect: effect, in: clip) ?? false }
        effectModel.onConvertToKeyframes = { [weak self] clip, effect in
            guard let self else { return }
            if !session.convertToKeyframes(effect: effect, in: clip) { onStatus?(session.lastError ?? "The effect could not be converted.") }
        }
        effectModel.onReopenAsEffect = { [weak self] clip in
            guard let self else { return }
            if !session.reopenAsEffect(in: clip) { onStatus?(session.lastError ?? "The effect could not be re-opened.") }
        }
        effectModel.onSeek = { [weak self] t in self?.session.seek(to: t) }
        // Scrubbing the keyframe ruler behaves like the timeline ruler: a press stops playback, a drag scrubs.
        effectModel.onPointerDown = { [weak self] in self?.session.stopPlayback() }
        effectModel.onScrubBegan = { [weak self] in self?.session.beginScrub() }
        effectModel.onScrub = { [weak self] t in self?.session.scrub(to: t) }
        effectModel.onScrubEnded = { [weak self] in self?.session.endScrub() }
        wireColorMatch()
    }

    // MARK: Views

    func view(for p: PanelID) -> NSView {
        switch p {
        case .timeline: return timelineHost
        case .steps: return colorView.stepsGraph
        case .programMonitor: return monitorView
        case .project: return projectView
        case .effectControls: return effectContainer
        case .library: return libraryView
        case .text: return textView
        case .colorInspector: return colorView
        case .colorClips: return colorView.clipsPanel
        case .graphics: return graphicsView
        case .scopes: return scopesView
        case .effects: return effectsView
        case .keystones: return keystonesView
        case .markerList: return markerListView
        case .audioMeter: return meterView
        case .sourceMonitor: return source.view
        }
    }

    private static func symbol(_ p: PanelID) -> SQIcon {
        switch p {
        case .sourceMonitor: .playRectangle
        default: .roundedSquare
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

    private func syncSequenceTabs() {
        let tabs = session.sequenceTabs
        let items = tabs.tabs.enumerated().map { i, tab in
            SequenceTabsView.Item(root: tab.root,
                                  title: tab.path.map { session.project.timeline($0)?.name ?? "?" }.joined(separator: " > "),
                                  active: i == tabs.activeIndex)
        }
        timelineHost.tabs.setItems(items)
        let hidden = items.isEmpty     // always visible, so the open sequence is named even with one tab
        if timelineHost.tabs.isHidden != hidden { timelineHost.tabs.isHidden = hidden; timelineHost.needsLayout = true }
    }

    /// Normal | Fast Cut: the header switch, the gesture preview flag and the scroll / zoom feel follow the active
    /// sequence. Called after every project change, so undo, redo, a project load and a tab switch re-apply them.
    func syncEditMode() {
        let mode = session.activeTimeline?.editMode ?? .normal
        let fast = mode == .magnetic
        timelineView.feel = TimelineFeel.forMagnetic(fast)
        if timelineHost.header.editMode != mode { timelineHost.header.editMode = mode }
        syncFastCutStrip()
        syncSequenceSettingsDisplay()
    }

    /// The Fast Cut verb strip: shown only in a Fast Cut sequence, each verb greyed unless the selection allows it.
    func syncFastCutStrip() {
        let fast = session.activeTimeline?.editMode == .magnetic
        timelineHost.showsFastCutStrip = fast
        if fast { timelineHost.fastCutStrip.setEnabled { [session] in session.fastCutCommandEnabled($0) } }
    }

    /// Sequence Settings that show up in the UI: timecode start / display (ruler, header, Program monitor timecode) and the
    /// sequence's own preview quality (applied when the sequence or its setting changes, never on every edit).
    private func syncSequenceSettingsDisplay() {
        let t = session.activeTimeline
        let start = t?.timecodeStart ?? .zero, frames = t?.timecodeDisplay == .frames
        timelineView.timecodeStart = start
        timelineView.timecodeFramesOnly = frames
        if monitorModel.timecodeOrigin != start || monitorModel.timecodeFramesOnly != frames {
            monitorModel.timecodeOrigin = start
            monitorModel.timecodeFramesOnly = frames
        }
        let key = t.map { SequenceQualityKey(id: $0.id, quality: $0.previewQuality) }
        guard key != appliedSequenceQuality else { return }
        let hadOwn = appliedSequenceQuality?.quality != nil
        appliedSequenceQuality = key
        if let q = t?.previewQuality.flatMap({ MonitorQuality(rawValue: $0.rawValue) }) { applySequenceQuality?(q) }
        else if hadOwn { applySequenceQuality?(nil) }
    }
    private struct SequenceQualityKey: Equatable { var id: UUID; var quality: SequencePreviewQuality? }
    private var appliedSequenceQuality: SequenceQualityKey?
    /// Set by the app: shows a sequence's own quality without remembering it; nil goes back to the app setting.
    var applySequenceQuality: ((MonitorQuality?) -> Void)?

    /// The header switch or Shift+G: one undo step, no clip moves.
    func setEditMode(_ mode: TimelineEditMode) {
        guard session.setTimelineEditMode(mode) else { return }
        syncEditMode()
        onStatus?(mode == .magnetic ? "Fast Cut: the main track closes gaps, clips above and below stay attached" : "Normal: classic tracks")
    }

    func toggleEditMode() { setEditMode(session.activeTimeline?.editMode == .magnetic ? .normal : .magnetic) }

    func syncTimeline() {
        syncSequenceTabs()
        timelineView.setTimeline(session.activeTimeline ?? Timeline(name: "", frameDuration: Time(1001, 30000)))
        syncEditMode()
        // Track heights belong to the sequence: load them when another sequence becomes active.
        if session.activeTimelineID != trackHeightsFor {
            trackHeightsFor = session.activeTimelineID
            timelineView.setTrackHeights(session.activeTimelineID.map { trackHeights.load($0) } ?? [:])
            timelineView.setSplitFraction(session.activeTimelineID.map { trackHeights.loadSplit($0) } ?? TrackSizing.defaultSplitFraction)
        }
        timelineView.setSelection(session.selection)
        timelineView.setCaptionSelection(session.captionSelection)
        mirrorLineKeys()
        timelineView.refreshDuckCurveIfChanged()
        ensureWaveforms()
    }

    /// Cmd+I, Project drop, Finder drop, Library and open all end with clips here: build what is missing.
    private func ensureWaveforms() {
        guard let t = session.activeTimeline else { return }
        waveforms.ensure(timeline: t, project: session.project)
    }

    private var lastFrameDuration = Time(1001, 30000)
    /// Which Magic picks the project had one change ago (`followReturnedPick`).
    var magicPickWatch = MagicPickWatch()
    private var panelSyncThrottle = PanelSyncThrottle()

    func sync(_ change: EditorSession.Change) {
        PlayProbe.timed("EditorPanels.sync \(change)", over: 4) { syncBody(change) }
    }

    private func syncBody(_ change: EditorSession.Change) {
        let t = session.activeTimeline
        syncMarkerList(change)
        if showsAllAngles, !change.isDisjoint(with: [.project, .playhead, .selection]) { refreshAnglesGrid() }
        if change.contains(.project) || change.contains(.media) {
            if change.contains(.project) {
                stopTrackOfRemovedMask()
                stopTrackOfChangedPick()
                saveFramesOfReturnedMasks()
                syncSequenceTabs()
                syncEditMode()
                if t != timelineView.timeline || timelineView.interaction.preview != timelineView.timeline { syncTimeline() }
                if projectModel.project != session.project { projectModel.setProject(session.project) }
                syncKeystoneBar()
            }
            if let t { waveforms.ensure(timeline: t, project: session.project) }
            timelineView.setOfflineMedia(Set(session.project.media.filter { session.media.isOffline($0.id) }.map(\.id)))
            timelineView.setLabelResolver(session.project.labelResolver)
            projectModel.scheduleOfflineRefresh()
            let fd = t?.frameDuration ?? lastFrameDuration
            lastFrameDuration = fd
            monitorModel.frameDuration = fd
            monitorModel.dropFrame = fd == Time(1001, 30000) || fd == Time(1001, 60000)
            monitorModel.duration = t?.duration ?? .zero
            monitorModel.hasSequence = t != nil
            monitorModel.timelineIsEmpty = t.map { $0.tracks.allSatisfy { $0.clips.isEmpty } && $0.captionTracks.allSatisfy { $0.items.isEmpty } } ?? false  // same rule as TimelineEmptyState.isEmpty
            monitorModel.markIn = t?.inOut?.start
            monitorModel.markOut = t?.inOut?.end
            monitorModel.syncFormats(from: session)
            syncMonitorAxis()   // the Color source file view keeps the file's own frame grid and axis
        }
        if change.contains(.project), let t = session.activeTimeline,
           timelineView.toolState.snapping != t.snappingOn || timelineView.toolState.linkedSelection != t.linkedSelectionOn {
            // Open, sequence switch, Undo / Redo: the sequence's saved toggles drive the timeline (mirror back via onToggleChange is a no-op).
            var s = timelineView.toolState
            s.snapping = t.snappingOn; s.linkedSelection = t.linkedSelectionOn
            timelineView.toolState = s
            session.linkedSelection = t.linkedSelectionOn
        }
        if change.contains(.project), trimModel.isActive { trimModel.refresh() }
        if change.contains(.selection) || change.contains(.project) {
            timelineView.setSelection(session.selection)
            timelineView.setCaptionSelection(session.captionSelection)
            mirrorLineKeys()
        }
        if session.isPlaying != wasPlaying {
            wasPlaying = session.isPlaying
            timelineView.updateSkimmerFromPointer()      // hidden while playing, back at the pointer when stopped
            if wasPlaying {
                let x = timelineView.geometry.x(for: session.playhead)
                follow.playbackStarted(playheadVisible: x >= TimelineGeometry.contentOriginX && x <= timelineView.bounds.width)
            }
        }
        if change.contains(.playhead) || change.contains(.project) {
            timelineView.setPlayhead(session.playhead)
            syncMonitorAxis()
            if session.isPlaying { followPlayhead() }
        }
        if change.contains(.reveal), let r = session.revealRange { revealInTimeline(r) }
        // Every change re-reads the transport state, so the Play/Pause button can never lag behind the session.
        if monitorModel.isPlaying != session.isPlaying { monitorModel.isPlaying = session.isPlaying }
        if session.isPlaying { source.pause(); libraryModel.preview.pause() }
        monitorModel.isLooping = session.bounds.loop
        // Playing while the timeline scrolls: side panels follow the playhead a few times a second, not on every tick.
        if !panelSyncThrottle.shouldSyncPanels(now: ProcessInfo.processInfo.systemUptime,
                                               playheadOnly: change == .playhead && session.isPlaying,
                                               lastScroll: timelineView.lastScrollUptime) { return }
        source.sync(change)
        if change.contains(.sourcePatch) || change.contains(.project) { syncSourcePatch() }
        effectModel.sync(with: session, change: change)
        syncTransitions(change)
        updateOverlay()
        clipSections.sync(change)
        textView.sync(change)
        colorView.sync(change)
        scopesView.sync(change)
        graphicsView.sync(change)
        updateGraphicsOverlay()
    }

    /// Undo/redo: scrolls the timeline only when the touched range is out of view (zoom is left alone).
    private func revealInTimeline(_ r: TimeRange) {
        let tv = timelineView
        let left = TimelineGeometry.contentOriginX, right = tv.bounds.width
        let x0 = tv.geometry.x(for: r.start), x1 = tv.geometry.x(for: r.end)
        guard x1 < left || x0 > right else { return }
        pagingTimeline = true
        tv.scroll(toX: tv.geometry.scrollX + x0 - left - (right - left) * 0.1)
        pagingTimeline = false
    }

    /// The Program monitor's time axis: the sequence, or (Color page, Clips mode) the picked clip's whole source file,
    /// with the clip's In and Out in the file as its marks.
    private func syncMonitorAxis() {
        monitorModel.currentTime = session.monitorTime
        monitorModel.sourceFileView = session.colorSourceView != nil
        // The source file view runs on the file's own frame grid (timecode, steps); the sequence's otherwise.
        let fd = session.monitorFrameDuration
        if monitorModel.frameDuration != fd {
            monitorModel.frameDuration = fd
            monitorModel.dropFrame = fd == Time(1001, 30000) || fd == Time(1001, 60000)
        }
        if let r = session.sourceViewClipRange {
            monitorModel.duration = session.monitorDuration
            monitorModel.markIn = r.start
            monitorModel.markOut = r.end
        } else if let t = session.activeTimeline {
            monitorModel.duration = t.duration
            monitorModel.markIn = t.inOut?.start
            monitorModel.markOut = t.inOut?.end
        }
    }

    /// Follow during playback (`TimelineFollow`, mode from `timelineView.feel`): page-wise, or continuous with the
    /// playhead held at the center; either stops once the user scrolled since playback started.
    private func followPlayhead() {
        let tv = timelineView
        let x = tv.geometry.x(for: session.playhead)
        guard let target = follow.scroll(mode: tv.feel.playbackFollow, playheadX: x, scrollX: tv.geometry.scrollX,
                                         viewLeft: TimelineGeometry.contentOriginX, viewRight: tv.bounds.width) else { return }
        if PlayProbe.enabled { NSLog("PLAYPROBE page scroll %.0f -> %.0f", tv.geometry.scrollX, target) }
        pagingTimeline = true
        PlayProbe.timed("followPlayhead.scroll") { tv.scroll(toX: target) }
        pagingTimeline = false
    }
}
