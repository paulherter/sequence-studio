import AppKit
import QuartzCore
import SQCore
import SQEditorSession
import SQPlayback

/// Timeline container (T-02: draw, scroll and zoom only; editing interactions are T-04/T-05).
/// Layer-backed, flipped, draws only the dirty rect. Children: `RulerView` on top, one `TrackHeaderView` per track.
/// Clips, lanes and the playhead line are drawn here.
///
/// Model input: `setTimeline(_:)`, `setSelection(_:)`, `setPlayhead(_:)`, `setOfflineMedia(_:)`.
@MainActor
public final class TimelineView: NSView {
    public private(set) var timeline: Timeline { didSet { rowsBase = nil; trackIndexByID = nil; duckContextCache = nil } }
    /// Track positions by ID for the draw path, valid while `timeline` is unchanged (`Timeline.track` scans and copies
    /// every track it passes: with many tracks that was a tenth of a scroll step).
    private var trackIndexByID: [Track.ID: Int]?

    /// `timeline.track(id)` in O(1).
    func drawTrack(_ id: Track.ID) -> Track? {
        if trackIndexByID == nil {
            trackIndexByID = Dictionary(timeline.tracks.indices.map { (timeline.tracks[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        guard let i = trackIndexByID?[id] else { return nil }
        return timeline.tracks[i]
    }
    public private(set) var selection: Set<Clip.ID> = [] { didSet { if oldValue != selection { positionHeaders(apply: true) } } }
    public private(set) var captionSelection: Set<CaptionItem.ID> = []
    public private(set) var playhead: Time = .zero
    /// The selected word on the caption track (word level); its caption is selected with it.
    public var wordSelection: CaptionWordRef? { interaction.wordSelection }
    /// The word selection the content was last drawn with.
    private var shownWord: CaptionWordRef?
    /// The inline field over a word (double-click) and the find popup of the caption track.
    var wordEditor: CaptionWordEditor?
    var captionSearch: CaptionSearchPopup?
    public private(set) var offlineMedia: Set<UUID> = []
    /// Color page: the clips being graded (target and the clips sharing its grade), outlined in yellow.
    public var gradeOutline: Set<Clip.ID> = [] { didSet { if oldValue != gradeOutline { needsDisplay = true } } }
    /// Clips with a background analysis running (Stabilizer), 0...1: drawn as a progress strip on the clip.
    public var analysisProgress: [Clip.ID: Double] = [:] { didSet { if oldValue != analysisProgress { needsDisplay = true } } }
    public private(set) var geometry: TimelineGeometry {
        didSet {
            if oldValue.viewportHeight != geometry.viewportHeight || oldValue.heightMode != geometry.heightMode
                || oldValue.heightOverrides != geometry.heightOverrides || oldValue.splitFraction != geometry.splitFraction
                || oldValue.fitAllTracks != geometry.fitAllTracks
                || oldValue.reservesGhostSpace != geometry.reservesGhostSpace
                || oldValue.laneSpace != geometry.laneSpace { rowsBase = nil }
        }
    }
    /// Track rows laid out at scrollY 0; valid until the track list, heights or viewport height change.
    private var rowsBase: [TrackRow]?
    /// `SQ_TIMELINE_PERF=1`: timing of the first scroll/zoom steps.
    var perf = TimelinePerf()

    /// `geometry.rows(for: timeline)`, cached per layout generation (scroll and zoom do not invalidate it).
    func layoutRows() -> [TrackRow] {
        if rowsBase == nil {
            let t0 = perf.enabled ? TimelinePerf.now() : 0
            var g = geometry
            g.scrollY = 0
            rowsBase = g.rows(for: timeline)
            if perf.enabled { perf.add(.rows, ns: TimelinePerf.now() &- t0) }
        }
        let sy = geometry.scrollY
        guard sy != 0, let base = rowsBase else { return rowsBase ?? [] }
        return base.map { var r = $0; r.y -= sy; return r }
    }

    /// Label colors of media and sequences (from the Project panel); a clip draws in its effective label color.
    public private(set) var labelResolver = LabelResolver()
    /// Header control clicks (callbacks only in T-02).
    /// A click on an idle "V+" / "A+" ghost strip: add an empty track of that kind (one undo step).
    /// Poster picture of a media item for the thumbnail column of video clips (board `.thh`); nil result = empty well, nil hook = no column.
    public var thumbnails: ((UUID) -> CGImage?)?
    /// The Angles sequence of a nested sequence id (nil = not an Angles sequence): an Angles piece then draws the thumbnails
    /// and waveform of the angle it plays (`Clip.angleProxy`). Called while drawing: the App answers from the project.
    public var anglesSequence: ((Timeline.ID) -> Timeline?)?
    /// Weak stretches (source seconds) of a clip's tracked Magic mask for the confidence strip (MASK-UX 5.4); nil = the clip
    /// has no tracked Magic mask (no strip). Called while drawing: the App answers from a cache.
    public var trackWeakSpans: ((Clip) -> [MagicTrackHealth.Span]?)?
    /// The App calls this when tracking finished or the cache changed.
    public func trackConfidenceChanged() { needsDisplay = true }
    /// The App calls this when a requested thumbnail has arrived.
    public func thumbnailsChanged() { needsDisplay = true }
    /// The frame of a media item at a media time for the thumbnail modes Head and Tail / Continuous (nil = empty well while it
    /// loads; the App asks `ClipThumbnailSource.frame` and calls `thumbnailsChanged` when it arrives). Without it only the head
    /// column (the poster) is shown whatever the mode.
    public var thumbnailFrame: ((UUID, Time) -> CGImage?)?
    /// What the thumbnails of video clips show. Starts from the user preference (`ThumbnailPrefs`); setting it here does not
    /// write the preference (the Timeline menu does, through `ThumbnailPrefs.mode`, and posts `ThumbnailPrefs.didChange`).
    public var thumbnailMode: ThumbnailMode = ThumbnailPrefs.mode {
        didSet { guard thumbnailMode != oldValue else { return }; contentCache.invalidateAll(); needsDisplay = true }
    }
    private var thumbnailModeObserver: NSObjectProtocol?
    /// Follows `ThumbnailPrefs.mode` while the view is in a window.
    func observeThumbnailPrefs() {
        guard thumbnailModeObserver == nil else { return }
        thumbnailModeObserver = NotificationCenter.default.addObserver(forName: ThumbnailPrefs.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thumbnailMode = ThumbnailPrefs.mode }
        }
    }
    public var onAddTrack: ((TrackKind) -> Void)?
    /// Fast Cut: Cmd+Opt+click on an attached clip (Selection tool) moves its attach point to the clicked time.
    public var onSetAttachPoint: ((Clip.ID, Time) -> Void)?
    public var onTrackToggle: ((Track.ID, TrackToggle) -> Void)?
    /// Source patch (MON-30, see TimelineView+SourcePatch): nil while no source is loaded (no patch column).
    public var sourcePatch: SourcePatch? { didSet { if oldValue != sourcePatch { sourcePatchChanged() } } }
    /// Streams the loaded source has: only their chips show.
    public var sourcePatchStreams: Set<TrackKind> = [.video, .audio] { didSet { if oldValue != sourcePatchStreams { sourcePatchChanged() } } }
    /// Track under a dragged patch chip (drop highlight).
    var patchDropTrack: Track.ID? { didSet { if oldValue != patchDropTrack { positionHeaders(apply: true) } } }
    public var onSourcePatchClick: ((TrackKind) -> Void)?
    public var onSourcePatchMove: ((TrackKind, Track.ID) -> Void)?
    /// Option+click on a chip: solo that stream. Shift+drag: both streams move by the same number of tracks.
    public var onSourcePatchSolo: ((TrackKind) -> Void)?
    public var onSourcePatchMoveBoth: ((TrackKind, Track.ID) -> Void)?
    /// Double-click on a caption item: the host opens its text editor.
    public var onEditCaptionText: ((CaptionItem.ID) -> Void)?
    /// Volume rubber band edit of an audio clip: the clip as edited so far; one drag = began, changed..., ended.
    public var onVolumeEdit: ((Clip, VolumeEditPhase) -> Void)?
    var volumeDrag: VolumeDrag?
    /// Item lanes of opened Graphic clips (TimelineView+ItemLanes.swift): which clips are open is view state, not saved.
    var itemLanes = ItemLaneState()
    /// An item's range was moved or trimmed in its lane: the clip as edited so far; one drag = began, changed..., ended.
    public var onItemLaneEdit: ((Clip, VolumeEditPhase) -> Void)?
    /// Lane drag-out: layers (bottom first) of a Graphic dropped on another Graphic or a new one; Option copies.
    public var onItemLaneMoveOut: ((Clip.ID, [UUID], GraphicsLayerDestination, Bool) -> Void)?
    /// A layer dragged to another place inside its Graphic: the layers and the list index they go to (`GraphicsDocument.move`).
    public var onItemLaneReorder: ((Clip.ID, [UUID], Int) -> Void)?
    /// A lane was clicked: the Graphic clip and the items now selected in it.
    public var onItemLaneSelect: ((Clip.ID, Set<UUID>) -> Void)?
    /// The arrow of a text or shape clip was pressed: the host makes it a Graphic (the lanes open once it shows as one).
    public var onItemLanesMakeGraphic: ((Clip.ID) -> Void)?
    /// Lane space per track (the geometry is only written in this file).
    func setLaneSpace(_ s: [Track.ID: CGFloat]) { if geometry.laneSpace != s { geometry.laneSpace = s } }
    /// The snap line of a gesture that does not run through `interaction` (item lanes).
    func showSnapLine(_ t: Time?) { setScrubSnap(t) }
    var fadeDrag: FadeDrag?
    /// Time Remapping speed band edit: the clip and its speed track as edited so far; one drag = began, changed..., ended.
    public var onSpeedEdit: ((SpeedEdit) -> Void)?
    var speedDrag: SpeedDrag?
    /// Fast Cut: the attach thread being dragged (clip, timeline before the drag, last previewed attach time).
    var attachDrag: (clip: Clip.ID, original: Timeline, time: Time)?
    /// Video clips that show the speed band (view state, not saved).
    public internal(set) var speedBandClips: Set<Clip.ID> = []
    /// Set through `setKeyLaneSection` (KeyLanes).
    public var keyLaneSection: EffectSection?
    /// Draws the key lane of one clip (clip, clip rect, visible rect, row height). KeyLanes lives with Effect Controls
    /// above this module and installs it from `setKeyLaneSection`, the only way a lane section gets set
    /// (DECISIONS "SQEditorUI split").
    public static var keyLaneDrawer: (@MainActor (TimelineView, Clip, CGRect, CGRect, CGFloat) -> Void)?
    /// Opacity rubber band on video clips (Cmd-click adds a key); same phases as `onVolumeEdit`.
    public var onOpacityEdit: ((Clip, VolumeEditPhase) -> Void)?
    var opacityDrag: OpacityDrag?
    /// Keys selected on the opacity / volume lines, drawn filled with the keyframe color. The host mirrors
    /// `EditorSession.selectedLineKeys` here.
    public var selectedLineKeys: Set<UUID> = [] {
        didSet { if selectedLineKeys != oldValue { needsDisplay = true } }
    }
    /// A press on a key of the opacity / volume line (Shift extends the selection) or, with nil, a press anywhere else.
    /// The host calls `EditorSession.selectLineKeys`; frame nudges then move the keys.
    public var onLineKeyClick: ((LineKeyRef?, _ extend: Bool) -> Void)?
    var keyLaneClickHandler: ((Clip.ID, Time, Bool) -> Void)?
    /// True after a press on a key-lane glyph until the next press elsewhere: the nudge keys then move the lane keys.
    public internal(set) var keyLaneKeysActive = false
    /// Timeline times of the lane keys selected in Effect Controls (drawn filled). The host mirrors the model here.
    public var selectedKeyLaneTimes: Set<Time> = [] {
        didSet { if selectedKeyLaneTimes != oldValue { needsDisplay = true } }
    }
    /// Frames by which linked clips are out of sync (red badge on the clip); refreshed whenever `timeline` changes.
    var syncBadges: [Clip.ID: Int64] = [:]
    /// Remove Silences preview: the ranges that would be cut, drawn over every lane (nothing is cut yet).
    /// N8b: draws the live duck curve on Music tracks. Set by the host; nil = no curve. Call `refreshDuckCurve()` after a setting change.
    public var duckCurve: DuckCurveSource? { didSet { refreshDuckCurve() } }
    private var shownDuck: LiveDucking?
    /// `duckCurveContext()` result, valid until the timeline, the setting or the dialogue pauses change (it scanned every audio clip per draw).
    var duckContextCache: DuckContext??
    public func refreshDuckCurve() { duckContextCache = nil; shownDuck = duckCurve?.ducking(); contentCache.invalidateAll(); needsDisplay = true }
    /// Redraws only when the setting in force differs from the one last drawn (cheap; call on every project sync).
    public func refreshDuckCurveIfChanged() { if duckCurve?.ducking() != shownDuck { refreshDuckCurve() } }
    public var silencePreview: [TimeRange] = [] { didSet { if silencePreview != oldValue { needsDisplay = true } } }
    /// Builds the right-click menu for a point in view coordinates (see `TimelineContextMenu`). Nil = no menu.
    public var contextMenuProvider: ((CGPoint) -> [SQMenuItem]?)?
    /// Fired after scroll or zoom changed, so a host can sync scrollers and a zoom slider.
    public var onViewportChange: (() -> Void)?

    /// Gesture reducer behind the mouse handlers (tools, selection, snapping). The view feeds it view coordinates.
    public private(set) var interaction: TimelineInteraction
    /// A finished gesture: ONE undo step for the host (`EditorSession.commit`).
    public var onCommit: ((TimelineCommit) -> Void)?
    /// The selection changed by a click or marquee.
    public var onSelectionChange: ((Set<Clip.ID>, Set<CaptionItem.ID>) -> Void)?
    /// Ruler click: show this time. Dragging in the ruler calls begin/scrub/end.
    public var onSeek: ((Time) -> Void)?
    public var onScrubBegan: (() -> Void)?
    public var onScrub: ((Time) -> Void)?
    public var onScrubEnded: (() -> Void)?
    /// Called when a click lands in the view, so the host can move keyboard focus to this panel.
    public var onFocusRequest: (() -> Void)?
    /// A gesture was refused by SQCore (locked track, collision): message for the status bar.
    public var onRejection: ((String) -> Void)?
    /// Media dragged in from the Project panel: ids, drop time, track under the pointer (nil = default track),
    /// insert instead of overwrite (Command held at the drop).
    public var onDropMedia: (([MediaRef.ID], Time, Track.ID?, Bool) -> Void)?
    /// A text template (`TextTemplateCatalog` entry id) dragged in from the Text panel: id, drop time, track under the pointer.
    public var onDropTitleBlock: ((UUID, Time) -> Void)?
    public var onDropTextTemplate: ((String, Time, Track.ID?) -> Void)?
    /// Media dropped on a ghost track: ids, drop time, kind of track to create (in the same undo step as the placement),
    /// insert instead of overwrite.
    public var onDropMediaOnGhost: (([MediaRef.ID], Time, TrackKind, Bool) -> Void)?
    /// Sequences dragged in from the Project panel (nested clips): ids, drop time, track under the pointer, insert.
    public var onDropSequences: (([Timeline.ID], Time, Track.ID?, Bool) -> Void)?
    /// Sequences dropped on a ghost track: ids, drop time, kind of track to create, insert.
    public var onDropSequencesOnGhost: (([Timeline.ID], Time, TrackKind, Bool) -> Void)?
    /// Why a sequence drop is refused (it is the open sequence or contains it); nil = allowed. Asked while dragging.
    public var sequenceDropRefusal: (([Timeline.ID]) -> String?)?
    private var refusalShown = false
    /// Which streams a media drop places (the Source monitor's V/A drag toggles); nil = both.
    public var dropStreamsProvider: (() -> SourceStreams)?
    /// Files dragged in from the Library or Finder: URLs, drop time, track under the pointer, insert instead of overwrite.
    public var onDropFiles: (([URL], Time, Track.ID?, Bool) -> Void)?
    /// Describes a drag in flight (length, video/audio) so the ghost can be drawn. Nil or empty result = 5 s video placeholder.
    /// Peaks drawn inside audio clips; the owner calls `ensure` and the view redraws when peaks arrive.
    public var waveforms: TimelineWaveforms? {
        didSet {
            waveformTiles.removeAll()
            waveforms?.onReady = { [weak self] in self?.duckContextCache = nil; self?.waveformTiles.removeAll(); self?.needsDisplay = true; self?.prewarmWaveforms() }
            waveforms?.cache.onBuilt = { [weak self] in MainActor.assumeIsolated { self?.needsDisplay = true } }
            prewarmWaveforms()
        }
    }

    /// Finished waveform columns per clip (see `WaveformTileCache`).
    let waveformTiles = WaveformTileCache()
    /// Each track row's waveforms as a coverage mask, blended at once; one per row so a frame's rows blend in parallel
    /// (buffers reused across frames).
    private var waveformMasks: [WaveformMask] = []
    /// Rendered content area; horizontal scroll shifts its pixels instead of redrawing every clip.
    let contentCache = TimelineContentCache()
    /// The 2x draw-cost fast paths (clip chrome cut at device pixels, no lane under clip bodies, rows' waveform blends in
    /// parallel, cache frames copied out by rows; all but the last follow `ClipDrawing.usePixelCuts`). Off only for
    /// before/after measurements (EngineBench `timeline-scale --only-2x`) and output comparisons in tests.
    public var fastDraw: Bool {
        get { contentCache.fastOutput && ClipDrawing.usePixelCuts }
        set { contentCache.fastOutput = newValue; ClipDrawing.usePixelCuts = newValue; contentCache.invalidateAll() }
    }
    /// True while scroll/zoom marks the view for display: the cache follows those changes itself (`contentCache.draw`).
    private var keepsContentCache = false

    public override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue, !keepsContentCache { contentCache.invalidateAll() }
            super.needsDisplay = newValue
        }
    }

    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        if !keepsContentCache { contentCache.invalidate(invalidRect) }
        super.setNeedsDisplay(invalidRect)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        contentCache.invalidateAll()
        needsDisplay = true
    }

    /// Display of a strip whose only change is an overlay drawn over the content (playhead, snap line).
    func displayOverlay(_ r: CGRect) {
        keepsContentCache = true
        setNeedsDisplay(r)
        keepsContentCache = false
    }

    /// Display for a pure scroll/zoom change: the content cache is kept (it re-renders what the new viewport needs).
    func displayViewport() {
        keepsContentCache = true
        needsDisplay = true
        keepsContentCache = false
    }

    /// Fills the waveform cache in the background for the current zoom and its neighbors, so the first zoom steps after
    /// opening a project do not resample whole files inside a draw.
    func prewarmWaveforms() {
        guard let wf = waveforms else { return }
        for (id, d) in wf.data { wf.cache.requestBuild(media: id, data: d, pointsPerSecond: geometry.pointsPerSecond, radius: 3) }
    }
    public var dropItemsProvider: ((DropSource) -> [DropItem])?
    /// An effect (`com.sequencestudio.effect-id`) dropped on a clip: effect id, clip id.
    public var onDropEffect: ((String, Clip.ID) -> Void)?
    /// Option-drop of Project media onto a clip (Replace edit, the first item is used): media ids, clip id, Shift = match frame.
    public var onReplaceMedia: (([MediaRef.ID], Clip.ID, Bool) -> Void)?
    /// Option-drop of a sequence onto a clip (Replace edit): sequence id, clip id.
    public var onReplaceSequence: ((Timeline.ID, Clip.ID) -> Void)?
    /// A Library preset dropped on a clip: preset id, clip id (see `TimelineView+PresetDrop.swift`).
    public var onDropPreset: ((UUID, Clip.ID) -> Void)?
    /// G1: a keystone dropped on a video clip at the ghost's span (see `TimelineView+Keystones.swift`).
    public var onDropKeystone: ((Keystone, Clip.ID, KeystoneSpan) -> Void)?
    /// The keystone bar's edge was dragged: clip, old span, new span (the host commits one undo step).
    public var onRestretchKeystone: ((Clip.ID, KeystoneSpan, KeystoneSpan) -> Void)?
    /// The keystone applied last, drawn as a bar on its clip with draggable edges (nil = none).
    public var keystoneBar: KeystoneBar? { didSet { if keystoneBar != oldValue { needsDisplay = true } } }
    /// Where a dragged keystone would land.
    var keystoneGhost: KeystoneBar?
    var keystoneDrag: KeystoneEdgeDrag?
    // Transitions: state lives in `TimelineView+Transitions.swift`; the host wires these callbacks.
    var transitionState = TransitionViewState()
    /// A transition box was clicked (nil = deselected).
    public var onTransitionSelect: ((Transition.ID?, _ keepClips: Bool) -> Void)?
    /// Double-click on a transition box: the host opens "Set Transition Duration".
    public var onTransitionDoubleClick: ((Transition.ID) -> Void)?
    /// A drag of a transition edge or body: new values, and whether this continues the gesture's first change.
    public var onTransitionChange: ((Transition.ID, TransitionLayout.Change, _ continues: Bool) -> Void)?
    /// A transition (`EffectsPanelView.transitionID`) dropped on a cut or clip end.
    public var onDropTransition: ((TransitionKind, Track.ID, TransitionPoint, TransitionAlignment) -> Void)?
    /// Transition layer (DECISIONS 2026-10-05): a layer kind dropped on an empty spot of a video track.
    public var onDropTransitionLayer: ((TransitionKind, TransitionLayerDropTarget) -> Void)?
    /// Length a dropped transition layer of a kind gets (the session's default); nil = the factory length of 20 frames.
    public var transitionLayerDuration: ((TransitionKind) -> Time)?
    /// Center marker drag of a transition layer: the cut's new time, and whether this continues the gesture.
    public var onTransitionLayerCut: ((Clip.ID, Time, _ continues: Bool) -> Void)?
    /// End drag of a transition layer: edge, delta (positive = right), symmetric, continues. Returns how far the edge moved.
    public var onTransitionLayerResize: ((Clip.ID, ClipEdge, Time, _ symmetric: Bool, _ continues: Bool) -> Time)?
    /// FB-G: Move / Zoom / Pop dropped on a clip: its head, its tail, or both (`EditorSession.addElementTransition`).
    public var onDropElementTransition: ((TransitionKind, Track.ID, Clip.ID, [ClipEdge]) -> Void)?
    func clearClipSelectionForTransition() {
        selection = []; captionSelection = []
        interaction.setSelection([]); interaction.setCaptionSelection([])
        onSelectionChange?([], [])
    }
    /// Live drop ghost (read-only for tests and the host).
    public private(set) var dropPreview = DropPreview() { didSet { updateEmptyState() } }
    /// Clip highlighted while an effect is dragged over it.
    public private(set) var effectDropTarget: Clip.ID?
    private var scrubbing: (began: Bool, active: Bool) = (false, false)
    /// Zoom tool gesture: where it started, where the pointer is now, Option held at mouse down (zoom out).
    private var zoomDrag: (start: CGPoint, current: CGPoint, zoomOut: Bool)?
    /// Marker flag drag in the ruler: the marker, where the pointer went down, whether it moved, its original time.
    private var markerDrag: (id: Marker.ID, downX: CGFloat, moved: Bool, original: Time)?
    /// Beat markers that act as snap targets (every beat or bar downbeats only); the host sets it.
    public var beatSnapLevel: BeatSnapLevel = .everyBeat
    /// Range marker end handle drag in the ruler: the marker, its start time and its original duration.
    private var markerDurationDrag: (id: Marker.ID, start: Time, original: Time, moved: Bool)?
    /// Host commit of a range marker's new duration (one undo step).
    public var onMarkerDurationChanged: ((Marker.ID, Time) -> Void)?
    /// A clip marker flag pressed in the bottom strip of a clip: a drag moves it along the clip, a double-click edits it.
    private var clipMarkerDrag: (hit: ClipMarkerFlags.Hit, downX: CGFloat, moved: Bool)?
    /// In/Out band drag in the ruler: the part grabbed, where the pointer went down (x and time), whether it moved, the original range.
    private var inOutDrag: (part: InOutDrag.Part, downX: CGFloat, downTime: Time, moved: Bool, original: TimeRange)?
    /// The In/Out band was trimmed or moved (the host commits one undo step).
    public var onInOutChange: ((TimeRange, MarkedRangeDragPart) -> Void)?
    /// A marker was dragged to a new time (the host commits one undo step).
    public var onMarkerMoved: ((Marker.ID, Time) -> Void)?
    /// A clip marker flag was dragged to a new sequence time (clip, marker, time).
    public var onClipMarkerMoved: ((Clip.ID, Marker.ID, Time) -> Void)?
    /// Double-click on a clip marker flag: the host opens the marker dialog.
    public var onEditClipMarker: ((Clip.ID, Marker.ID) -> Void)?
    /// Last pointer position and modifiers of the drag in flight, for edge autoscroll and the Hold-S snap flip.
    private var lastDrag: (point: CGPoint, modifiers: GestureModifiers)?
    private var autoscrollTimer: Timer?
    private var resignObserver: NSObjectProtocol?
    private var lastHint: String?
    /// What the move gesture in flight does ("Insert", "Rearrange", "Copy", "Insert copy"); nil when it ends.
    public var onGestureHint: ((String?) -> Void)?
    /// Every gesture step and its end: the slip two-up state (nil when no Slip drag runs) and the preview sequence.
    public var onSlipTwoUp: ((SlipTwoUp?, Timeline) -> Void)?
    private var slipTwoUpShown = false
    private var autoscrollLast: TimeInterval = 0
    /// Edit point the playhead is stuck to while Shift-scrubbing (snap indicator), nil otherwise.
    public private(set) var scrubSnapTime: Time?
    /// Fast Cut skimmer (hover playhead): the time it shows and its line's x, nil when hidden. See `Skimmer`.
    public internal(set) var skimmerTime: Time?
    var skimmerX: CGFloat = 0
    /// The skimmer moved to a new frame (the host shows it in the monitor) or went away (nil).
    public var onSkim: ((Time?) -> Void)?
    /// The host's transport state: the skimmer is hidden while playing.
    public var isPlaybackRunning: (() -> Bool)?
    /// Active tool, snapping and linked selection.
    public var toolState: ToolState {
        get { interaction.toolState }
        set {
            let changed = interaction.toolState.tool != newValue.tool
            interaction.toolState = newValue
            onToolStateChange?(newValue)
            if changed {
                if itemLanes.drag != nil || itemLanes.move != nil { cancelItemLaneDrag(); stopAutoscroll(); lastDrag = nil }   // a lane drag belongs to the Select tool
                invalidateCursors(); updateRazorGuideFromPointer()
            }
        }
    }
    /// Any change of `toolState` (keys, header bar buttons): the header bar mirrors it.
    public var onToolStateChange: ((ToolState) -> Void)?
    /// The user picked a tool with a header bar button (keys set `toolState` directly).
    public var onToolChange: ((TimelineTool) -> Void)?
    /// Any click inside the view (ruler, clips, empty space), before it is handled. The host does not stop playback here:
    /// it keeps running while the user clicks, drags clips or cuts.
    public var onPointerDown: (() -> Void)?
    /// The eye in a caption track's header was clicked (board "C1": badge, name, eye). The shell flips `CaptionTrack.isVisible`.
    public var onToggleCaptionTrackVisibility: ((CaptionTrack.ID) -> Void)?
    /// Snap (magnet) and Linked Selection (chain) toggles live in the timeline header bar (`TimelineHeaderBar`).
    /// The user flipped Snap or Linked Selection with its button (the host may show a status message).
    public var onToggleChange: ((_ snapping: Bool, _ linkedSelection: Bool) -> Void)?

    // MARK: Track heights

    /// Track heights changed by the user (drag, command): the host persists them per sequence (`TrackHeightStore`).
    public var onTrackHeightsChange: (([Track.ID: CGFloat]) -> Void)?
    private var resizing: (zone: TrackSizing.Zone, startY: CGFloat, rows: [TrackRow], startFraction: CGFloat)?

    /// The V/A split moved by the user (drag, double-click reset): the host persists it per sequence.
    public var onSplitChange: ((CGFloat) -> Void)?
    public var splitFraction: CGFloat { geometry.splitFraction }

    /// Restores the split (no callback: this is the store speaking).
    public func setSplitFraction(_ f: CGFloat) {
        let v = min(max(f, 0), 1)
        guard v != geometry.splitFraction else { return }
        geometry.splitFraction = v
        clampScroll()
        syncChildren()
        invalidateCursors()
        needsDisplay = true
    }

    /// User track heights (empty = automatic fit).
    public var trackHeights: [Track.ID: CGFloat] { geometry.heightOverrides }

    /// Restores heights (no callback: this is the store speaking).
    public func setTrackHeights(_ h: [Track.ID: CGFloat]) {
        guard h != geometry.heightOverrides else { return }
        applyHeights(h, notify: false, keepFit: true)
    }

    /// Height commands: one step taller (+1) or shorter (-1) for the tracks of `kind` (nil = all).
    public func sizeTracks(_ kind: TrackKind?, direction: Int) {
        applyHeights(TrackSizing.stepped(rows: layoutRows(), kind: kind, direction: direction), notify: true)
    }
    /// Double-click on a track header (Premiere): toggles the track between Large and Medium (Shift: every track of the kind).
    func toggleTrackHeight(_ id: Track.ID, wholeKind: Bool) {
        applyHeights(TrackSizing.toggled(rows: layoutRows(), track: id, wholeKind: wholeKind), notify: true)
    }
    public func minimizeAllTracks() { applyHeights(TrackSizing.minimizedAll(rows: layoutRows()), notify: true) }
    public func expandAllTracks() { applyHeights(TrackSizing.expandedAll, notify: true) }

    /// Track height preset (Small / Medium / Large / Auto): clears per-track overrides and persists the mode.
    public var heightMode: TrackHeightMode { geometry.heightMode }
    public var onHeightModeChange: ((TrackHeightMode) -> Void)?
    public func setHeightMode(_ m: TrackHeightMode, notify: Bool = true) {
        geometry.heightMode = m
        applyHeights([:], notify: notify)
        if notify { onHeightModeChange?(m) }
    }

    /// Fit All Tracks: heights follow the panel height automatically. Any manual height edit turns it off first (the
    /// heights as drawn become the manual ones, so nothing jumps).
    public var fitsTracks: Bool { geometry.fitAllTracks }
    public var onFitTracksChange: ((Bool) -> Void)?
    public func setFitsTracks(_ on: Bool, notify: Bool = true) {
        guard on != geometry.fitAllTracks else { return }
        if on { geometry.fitAllTracks = true; applyHeights(geometry.heightOverrides, notify: false, keepFit: true) }
        else { applyHeights(TrackSizing.frozen(layoutRows()), notify: notify) }      // turns the flag off
        if notify, on { onFitTracksChange?(true) }
    }

    private func applyHeights(_ h: [Track.ID: CGFloat], notify: Bool, keepFit: Bool = false) {
        if !keepFit, geometry.fitAllTracks { geometry.fitAllTracks = false; onFitTracksChange?(false) }
        geometry.heightOverrides = h
        clampScroll()
        syncChildren()
        invalidateCursors()
        needsDisplay = true
        if notify { onTrackHeightsChange?(h) }
    }

    private func resizeZone(at p: CGPoint) -> TrackSizing.Zone? {
        guard resizing != nil || interaction.isIdle else { return nil }
        return TrackSizing.zone(at: p, rows: layoutRows(), viewWidth: bounds.width)
    }

    /// The header column and the V/A boundary belong to the view itself in their grab zones, so the header's buttons
    /// do not swallow the resize drag.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if bounds.contains(p), resizeZone(at: p) != nil { return self }
        return super.hitTest(point)
    }

    public static let minPointsPerSecond: Double = 0.02
    public static let maxPointsPerFrame: Double = 400
    public static let zoomStep: Double = TimelineZoom.keyStep

    private let ruler: RulerView
    private let zoomBar = ZoomScrollBar(accessibilityLabel: "Timeline zoom")
    private let zoomFooter = TimelineFooterFill()
    private let emptyState = EmptyStateView(title: TimelineEmptyState.title, hint: TimelineEmptyState.hint())
    private var zoomBarDrag: (scrollX: Double, viewport: Double, scale: Double, extent: Double)?
    private var headers: [Track.ID: TrackHeaderView] = [:]

    public nonisolated override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public init(timeline: Timeline = Timeline(name: "", frameDuration: Time(1, 24)), frame: NSRect = NSRect(x: 0, y: 0, width: 1000, height: 200)) {
        self.timeline = timeline
        self.syncBadges = timeline.syncOffsets()
        let fd = timeline.frameDuration
        self.geometry = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        self.geometry.viewportHeight = Self.trackAreaHeight(viewHeight: frame.height)
        self.interaction = TimelineInteraction(timeline: timeline, geometry: geometry)
        self.ruler = RulerView(geometry: geometry)
        super.init(frame: frame)
        ClipDrawing.prewarm()
        wantsLayer = true
        // macOS 14+: views do not clip by default, so an opaque `dirtyRect.fill()` would paint over its siblings.
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.sequenceMediaIDs, .sequenceTextTemplate, .sequenceTitleBlock, .sequenceEffectID, .sequencePresetID, .sequenceKeystone, .fileURL])
        addSubview(ruler)
        addSubview(zoomBar)
        zoomBar.backgroundColor = Theme.Colors.timeline
        addSubview(zoomFooter)
        addSubview(emptyState)
        wireZoomBar()
        layoutChildren()
        rebuildHeaders()
        syncChildren()
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Model input

    public func setTimeline(_ t: Timeline) {
        timeline = t
        syncBadges = t.syncOffsets()
        geometry.frameDuration = t.frameDuration
        selection.formIntersection(Set(t.tracks.flatMap { $0.clips.map(\.id) }))
        if let id = transitionState.selected, t.transition(id) == nil { transitionState.selected = nil }
        captionSelection.formIntersection(Set(t.captionTracks.flatMap { $0.items.map(\.id) }))
        interaction.reset(timeline: t)
        interaction.setSelection(selection)
        interaction.setCaptionSelection(captionSelection)
        shownWord = interaction.wordSelection
        syncItemLanes()
        clampScroll()
        rebuildHeaders()
        syncChildren()
        invalidateCursors()
        needsDisplay = true
        if toolState.timelineTool == .razor { updateRazorGuideFromPointer() }
        captionWordToolsFollowTimeline()
    }

    public func setSelection(_ ids: Set<Clip.ID>) {
        guard ids != selection else { return }
        selection = ids
        interaction.setSelection(ids)
        needsDisplay = true
    }

    public func setCaptionSelection(_ ids: Set<CaptionItem.ID>) {
        guard ids != captionSelection else { return }
        captionSelection = ids
        interaction.setCaptionSelection(ids)
        needsDisplay = true
    }

    public func setLabelResolver(_ r: LabelResolver) {
        guard r != labelResolver else { return }
        labelResolver = r
        needsDisplay = true
    }

    public func setOfflineMedia(_ ids: Set<UUID>) {
        guard ids != offlineMedia else { return }
        offlineMedia = ids
        needsDisplay = true
    }

    /// Cache strip of the ruler (spans whose frames are decoded).
    public func setCachedRanges(_ r: [TimeRange]) { ruler.setCachedRanges(r) }

    /// Sequence Settings: timecode of time zero and the frame-count display; the ruler and the header timecode follow.
    public var timecodeStart: Time = .zero {
        didSet { guard timecodeStart != oldValue else { return }; ruler.timecodeStart = timecodeStart; onPlayheadShown?(playhead) }
    }
    public var timecodeFramesOnly = false {
        didSet { guard timecodeFramesOnly != oldValue else { return }; ruler.framesOnly = timecodeFramesOnly; onPlayheadShown?(playhead) }
    }

    /// Told the new playhead time (the header bar's timecode).
    public var onPlayheadShown: ((Time) -> Void)?

    public func setPlayhead(_ t: Time) {
        guard t != playhead else { return }
        defer { onPlayheadShown?(t) }
        let old = geometry.x(for: playhead)
        playhead = t
        let new = geometry.x(for: t)
        ruler.movePlayhead(to: t)
        // The playhead is drawn over the content cache, so its strips need no re-render of the clips under it.
        for x in [old, new] {
            displayOverlay(CGRect(x: x - 2, y: TimelineGeometry.rulerHeight, width: 4, height: bounds.height))
        }
    }

    // MARK: Viewport (scroll + zoom)

    /// Visible time span of the content area.
    public var visibleRange: TimeRange {
        let a = max(geometry.time(atX: TimelineGeometry.contentOriginX), .zero)
        let b = max(geometry.time(atX: bounds.width), a)
        return TimeRange(start: a, end: b)
    }

    /// End of the last clip (zero for an empty timeline).
    public var contentEnd: Time {
        let clips = timeline.tracks.compactMap { $0.clips.last?.timeline.end }
        let captions = timeline.captionTracks.compactMap { $0.items.last?.range.end }
        return (clips + captions).max() ?? .zero
    }

    private var contentViewportWidth: CGFloat { max(bounds.width - TimelineGeometry.contentOriginX, 1) }

    private func maxScrollX() -> CGFloat {
        // Sequence end plus half a viewport of room, so the tail can be scrolled to the left edge. A sequence that fits
        // (with its free space on the right) does not scroll at all: zoomed all the way out the start stays at the left edge.
        TimelineZoom.maxScroll(contentWidth: Double(geometry.width(of: contentEnd)), viewportWidth: Double(contentViewportWidth))
    }

    /// Height the rows may stretch into: the view minus the zoom bar at the bottom (it is not part of the track area).
    static func trackAreaHeight(viewHeight: CGFloat) -> CGFloat { max(viewHeight - ZoomScrollBar.height, 0) }

    /// Vertical overflow. Under one point counts as none: stretched rows sum to the viewport only up to rounding, and a
    /// sliver of overflow would turn every horizontal swipe into a diagonal one (`horizontalOnly` in `scrollWheel`).
    private func maxScrollY() -> CGFloat {
        let content = (layoutRows().last.map { $0.maxY + $0.laneSpace + geometry.scrollY }
                       ?? TimelineGeometry.rulerHeight + geometry.captionHeight(for: timeline))
            + (geometry.reservesGhostSpace ? 2 * TimelineGeometry.ghostRowHeight : 0)
        let over = content + ZoomScrollBar.height - bounds.height
        return over < 1 ? 0 : over
    }

    private func clampScroll() {
        geometry.scrollX = min(max(geometry.scrollX, 0), maxScrollX())
        geometry.scrollY = min(max(geometry.scrollY, 0), maxScrollY())
    }

    /// `systemUptime` of the last scroll that moved the viewport (`PanelSyncThrottle`).
    public private(set) var lastScrollUptime: TimeInterval = 0

    public func scroll(toX x: CGFloat) { setScroll(x: x, y: geometry.scrollY) }
    public func scroll(toY y: CGFloat) { setScroll(x: geometry.scrollX, y: y) }

    public func scroll(byX dx: CGFloat, y dy: CGFloat) {
        perf.beginHandler(.scroll)
        TimelineSignpost.interval("scroll") { setScroll(x: geometry.scrollX + dx, y: geometry.scrollY + dy) }
        perf.endHandler()
    }

    /// `elastic`: the rubber band may leave the view past its ends (`feel.rubberBand`); every other scroll ends a
    /// running spring back and clamps.
    private func setScroll(x: CGFloat, y: CGFloat, elastic: Bool = false) {
        cancelZoomAnimation()
        if !elastic, springBack != nil { endSpringBack(settle: false) }
        let old = (geometry.scrollX, geometry.scrollY)
        geometry.scrollX = x; geometry.scrollY = y
        if !elastic { clampScroll() }
        guard (geometry.scrollX, geometry.scrollY) != old else { return }
        lastScrollUptime = ProcessInfo.processInfo.systemUptime
        // Vertical scroll only moves the header rows (no re-apply, no ruler redraw, cursor rects once the motion pauses).
        if geometry.scrollY != old.1 { positionHeaders() }
        viewportChanged(layout: false, ruler: geometry.scrollX != old.0)
    }

    /// Span `\` fits: In/Out when set, else the whole sequence.
    private var fitSpan: TimeRange {
        timeline.inOut.flatMap { $0.isEmpty ? nil : $0 } ?? TimeRange(start: .zero, duration: contentEnd)
    }

    private var frameSeconds: Double { Double(geometry.frameDuration.value) / Double(geometry.frameDuration.timescale) }

    /// Scale at which the fit span fills the content area (with a margin on both sides).
    public var fitScale: Double {
        let span = fitSpan
        guard !span.isEmpty else { return 1 }
        let seconds = Double(span.duration.value) / Double(span.duration.timescale)
        return max(Double(contentViewportWidth) - 2 * Double(Theme.Spacing.lg), 1) / seconds
    }

    /// Like `fitScale`, but always for the whole sequence (In/Out must not limit how far one can zoom out).
    private var wholeSequenceFitScale: Double {
        let end = contentEnd
        guard end > .zero else { return fitScale }
        let seconds = Double(end.value) / Double(end.timescale)
        return max(Double(contentViewportWidth) - 2 * Double(Theme.Spacing.lg), 1) / seconds
    }

    /// Allowed scales: a little beyond the whole sequence down to a few frames across the width.
    public var zoomLimits: ClosedRange<Double> {
        TimelineZoom.limits(fit: wholeSequenceFitScale, viewportWidth: Double(contentViewportWidth), frameSeconds: frameSeconds)
    }

    /// Sets zoom, keeping the time under `anchorX` (view coordinates) fixed.
    public func setZoom(pointsPerSecond: Double, anchorX: CGFloat? = nil, motion: Bool = true) {
        perf.beginHandler(.zoom)
        let sp = TimelineSignpost.log.beginInterval("zoomStep")
        defer { perf.endHandler(); TimelineSignpost.log.endInterval("zoomStep", sp) }
        cancelZoomAnimation()
        endSpringBack(settle: false)
        let pps = TimelineZoom.clamp(pointsPerSecond, to: zoomLimits)
        guard pps != geometry.pointsPerSecond else { return }
        if motion { noteZoomStep(.continuous) }
        let anchor = anchorX ?? defaultZoomAnchor()
        geometry.scrollX = CGFloat(TimelineZoom.anchoredScroll(oldScale: geometry.pointsPerSecond, newScale: pps,
                                                               scrollX: Double(geometry.scrollX),
                                                               anchorX: Double(anchor - TimelineGeometry.contentOriginX)))
        geometry.pointsPerSecond = pps
        clampScroll()
        viewportChanged(layout: false)
    }

    private func defaultZoomAnchor() -> CGFloat {
        let x = geometry.x(for: playhead)
        return x >= TimelineGeometry.contentOriginX && x <= bounds.width
            ? x : TimelineGeometry.contentOriginX + contentViewportWidth / 2
    }

    /// `=` / `-`: one step, animated over `ZoomAnimation.duration`. A press during a running animation continues from its target.
    public func zoomIn(anchorX: CGFloat? = nil) { animateZoomStep(factor: Self.zoomStep, anchorX: anchorX) }
    public func zoomOut(anchorX: CGFloat? = nil) { animateZoomStep(factor: 1 / Self.zoomStep, anchorX: anchorX) }

    // MARK: Zoom animation (keys, zoom-tool click, fit)

    private var zoomAnimation: (anim: ZoomAnimation, start: TimeInterval)?
    /// Display link while on screen (one step per frame, at the frame's presentation time); a timer otherwise.
    private var zoomAnimationLink: CADisplayLink?
    private var zoomAnimationTimer: Timer?
    /// 1x-while-zooming state and its quiet-period timer (see `ZoomMotion`).
    var zoomMotion = ZoomMotion()
    var zoomMotionTimerPending = false
    var zoomMotionToken = 0
    var sharpenFramePending = false

    /// Scale and scroll the view shows now, or the running animation's target.
    private var zoomTarget: (scale: Double, scrollX: Double) {
        zoomAnimation.map { ($0.anim.toScale, $0.anim.toScroll) } ?? (geometry.pointsPerSecond, Double(geometry.scrollX))
    }

    private func animateZoomStep(factor: Double, anchorX: CGFloat?) {
        noteZoomStep(.discrete)
        let t = zoomTarget
        let new = TimelineZoom.clamp(t.scale * factor, to: zoomLimits)
        let anchor = Double((anchorX ?? defaultZoomAnchor()) - TimelineGeometry.contentOriginX)
        startZoomAnimation(toScale: new, toScroll: TimelineZoom.anchoredScroll(oldScale: t.scale, newScale: new, scrollX: t.scrollX, anchorX: anchor),
                           mode: .anchored(x: anchor))
    }

    /// Animates from the shown state to `toScale`/`toScroll` (scroll clamped to the new scale's range).
    private func startZoomAnimation(toScale: Double, toScroll: Double, mode: ZoomAnimation.Mode) {
        endSpringBack()
        let from = (scale: geometry.pointsPerSecond, scroll: Double(geometry.scrollX))
        cancelZoomAnimation()
        // Anchored end state is derived from the shown state, so a restart mid-animation does not snap in the last frame.
        var toScroll = toScroll
        if case .anchored(let x) = mode {
            toScroll = TimelineZoom.anchoredScroll(oldScale: from.scale, newScale: toScale, scrollX: from.scroll, anchorX: x)
        }
        guard toScale != from.scale || toScroll != from.scroll else { return }
        let a = ZoomAnimation(fromScale: from.scale, fromScroll: from.scroll, toScale: toScale, toScroll: max(toScroll, 0), mode: mode)
        zoomAnimation = (a, CACurrentMediaTime())
        if window != nil {
            // The link retains its target: a weak proxy, so a view that goes away never stays alive through it.
            let proxy = DisplayLinkProxy { [weak self] link in
                guard let self else { link.invalidate(); return }
                self.zoomAnimationFrame(link)
            }
            let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
            link.add(to: .main, forMode: .common)
            zoomAnimationLink = link
        } else {
            let timer = Timer(timeInterval: 1 / ZoomAnimation.frameRate, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated { self.zoomAnimationTick(at: CACurrentMediaTime()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            zoomAnimationTimer = timer
        }
    }

    private func zoomAnimationFrame(_ link: CADisplayLink) {
        // The state for when this frame reaches the screen, not for when the callback happens to run.
        zoomAnimationTick(at: link.targetTimestamp)
    }

    private func zoomAnimationTick(at time: CFTimeInterval) {
        guard let z = zoomAnimation else { cancelZoomAnimation(); return }
        zoomMotion.animationFrame(now: ProcessInfo.processInfo.systemUptime)
        let sp = TimelineSignpost.log.beginInterval("zoomStep")
        defer { TimelineSignpost.log.endInterval("zoomStep", sp) }
        let p = ZoomAnimation.progress(elapsed: time - z.start)
        let s = z.anim.state(progress: p)
        geometry.pointsPerSecond = TimelineZoom.clamp(s.scale, to: zoomLimits)
        geometry.scrollX = CGFloat(s.scrollX)
        clampScroll()
        viewportChanged(layout: false)
        if p >= 1 { cancelZoomAnimation() }
    }

    /// Jumps a running zoom animation to its end state (tests, and anything that needs the final geometry now).
    func settleZoomAnimation() {
        guard let z = zoomAnimation else { return }
        let s = z.anim.state(progress: 1)
        cancelZoomAnimation()
        geometry.pointsPerSecond = TimelineZoom.clamp(s.scale, to: zoomLimits)
        geometry.scrollX = CGFloat(s.scrollX)
        clampScroll()
        viewportChanged(layout: false)
    }

    private func cancelZoomAnimation() {
        zoomAnimationLink?.invalidate()
        zoomAnimationLink = nil
        zoomAnimationTimer?.invalidate()
        zoomAnimationTimer = nil
        zoomAnimation = nil
    }

    private var fitToggle = ZoomFitToggle()

    /// `\`: fit the whole sequence (clips, or In/Out when set); pressed again it returns to the previous zoom (Premiere).
    public func zoomToFit() {
        let now = zoomTarget
        switch fitToggle.press(scale: now.scale, scrollX: now.scrollX, fit: fitScale) {
        case .restore(let scale, let scrollX):
            startZoomAnimation(toScale: TimelineZoom.clamp(scale, to: zoomLimits), toScroll: scrollX, mode: .free)
        case .fit:
            let span = fitSpan
            guard !span.isEmpty else { return }
            let startSeconds = Double(span.start.value) / Double(span.start.timescale)
            let scale = TimelineZoom.clamp(fitScale, to: zoomLimits)     // a one-frame sequence must not pass the zoom cap
            startZoomAnimation(toScale: scale, toScroll: startSeconds * scale - Double(Theme.Spacing.lg), mode: .free)
        }
    }

    /// `layout: false` for pure scrollX/zoom changes: the header rows only move with scrollY or layout changes.
    private func viewportChanged(layout: Bool = true, ruler updateRuler: Bool = true) {
        if layout {
            invalidateCursors()
            syncChildren()
        } else {
            scheduleCursorInvalidation()
            if updateRuler {
                PlayProbe.timed("ruler.update") { ruler.update(geometry: geometry, inOut: timeline.inOut, markers: timeline.markers, playhead: playhead) }
            }
        }
        zoomBar.needsDisplay = true
        if wordEditor != nil { positionWordEditor() }
        if layout { needsDisplay = true } else { PlayProbe.timed("displayViewport") { displayViewport() } }
        if toolState.timelineTool == .razor || !razorGuideRects.isEmpty || timeline.isFastCut || skimmerTime != nil { updateRazorGuideFromPointer() }   // the line follows the content, not stale x
        onViewportChange?()
    }

    // MARK: Events

    public override func scrollWheel(with event: NSEvent) {
        let sp = TimelineSignpost.log.beginInterval("scrollWheel")
        defer { TimelineSignpost.log.endInterval("scrollWheel", sp) }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let held = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
        if scrollZoom.isZoom(phase: Self.scrollPhase(event.phase), momentumPhase: Self.scrollPhase(event.momentumPhase), modifierHeld: held) {
            let anchor = convert(event.locationInWindow, from: nil).x
            let d = abs(dy) >= abs(dx) ? dy : dx
            setZoom(pointsPerSecond: geometry.pointsPerSecond * TimelineZoom.scrollFactor(delta: Double(d), precise: event.hasPreciseScrollingDeltas),
                    anchorX: anchor)
            return
        }
        // A mouse wheel reports ~1 pt per notch; a trackpad reports pixels. Tuning lives in `ScrollTuning`; the
        // Normal / Fast Cut differences in `feel`.
        let precise = event.hasPreciseScrollingDeltas
        let phase = Self.scrollPhase(event.phase), momentum = Self.scrollPhase(event.momentumPhase)
        var d = (dx: Double(dx), dy: Double(dy))
        if precise {
            d = scrollAxisLock.filter(phase: phase, momentumPhase: momentum, dx: d.dx, dy: d.dy)
        }
        if pinchGuard.suppressesVertical(now: ProcessInfo.processInfo.systemUptime) { d.dy = 0 }
        let horizontalOnly = event.modifierFlags.contains(.shift) || maxScrollY() == 0
        let a = ScrollTuning.scrollAmounts(dx: d.dx, dy: d.dy, precise: precise, horizontalOnly: horizontalOnly, feel: feel)
        if feel.rubberBand && precise {
            elasticScroll(dx: -a.x, dy: -a.y, phase: phase, momentumPhase: momentum)
            return
        }
        guard a.x != 0 || a.y != 0 else { return }
        scroll(byX: wholeDevicePixels(CGFloat(-a.x), remainder: &scrollRemainderX),
               y: wholeDevicePixels(CGFloat(-a.y), remainder: &scrollRemainderY))
    }

    /// Sub-pixel parts of scroll deltas not applied yet (carried into the next event).
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0

    /// `d` (plus the carried remainder) rounded to whole device pixels, so the content cache can shift its pixels.
    private func wholeDevicePixels(_ d: CGFloat, remainder: inout CGFloat) -> CGFloat {
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let want = d + remainder
        let applied = (want * scale).rounded() / scale
        remainder = want - applied
        return applied
    }

    /// Scroll / pinch / playback feel: `.normal` (Premiere-like) or `.fastCut` (Final Cut). Set from the sequence's
    /// edit mode with `TimelineFeel.forMagnetic(_:)`.
    public var feel: TimelineFeel = .normal {
        didSet {
            guard feel != oldValue else { return }
            scrollAxisLock = ScrollAxisLock(rule: feel.axisRule)
            if !feel.rubberBand { endSpringBack() }
        }
    }

    // MARK: Rubber band (feel.rubberBand)

    private var elasticX = ElasticAxis()
    private var elasticY = ElasticAxis()
    private var springBack: (fromX: Double, toX: Double, fromY: Double, toY: Double, start: TimeInterval)?
    private var springBackLink: CADisplayLink?
    private var springBackTimer: Timer?

    /// Trackpad scroll with elastic ends: `dx`/`dy` are scroll-offset deltas. Vertical bounces only when the tracks
    /// overflow (a timeline that fits has nothing to pull).
    private func elasticScroll(dx: Double, dy: Double, phase: ScrollZoomState.Phase, momentumPhase: ScrollZoomState.Phase) {
        if momentumPhase == .none, phase == .began || phase == .mayBegin { endSpringBack(settle: false) }
        if springBack != nil { return }                       // the momentum tail of a released overscroll
        let x = elasticX.step(position: Double(geometry.scrollX), delta: dx, range: 0...Double(maxScrollX()),
                              dimension: Double(contentViewportWidth), phase: phase, momentumPhase: momentumPhase)
        var y = (position: Double(geometry.scrollY), springBack: false)
        let maxY = Double(maxScrollY())
        if maxY > 0 {
            y = elasticY.step(position: Double(geometry.scrollY), delta: dy, range: 0...maxY,
                              dimension: Double(Self.trackAreaHeight(viewHeight: bounds.height)), phase: phase, momentumPhase: momentumPhase)
        }
        let nx = geometry.scrollX + wholeDevicePixels(CGFloat(x.position) - geometry.scrollX, remainder: &scrollRemainderX)
        let ny = geometry.scrollY + wholeDevicePixels(CGFloat(y.position) - geometry.scrollY, remainder: &scrollRemainderY)
        if nx != geometry.scrollX || ny != geometry.scrollY {
            perf.beginHandler(.scroll)
            setScroll(x: nx, y: ny, elastic: true)
            perf.endHandler()
        }
        if x.springBack || y.springBack { startSpringBack() }
    }

    /// Eases an overscrolled view back to its ends over `RubberBand.springDuration`.
    private func startSpringBack() {
        let sx = Double(geometry.scrollX), sy = Double(geometry.scrollY)
        let tx = RubberBand.edge(of: sx, range: 0...Double(maxScrollX())) ?? sx
        let ty = RubberBand.edge(of: sy, range: 0...Double(maxScrollY())) ?? sy
        endSpringBack(settle: false)
        guard tx != sx || ty != sy else { return }
        springBack = (sx, tx, sy, ty, CACurrentMediaTime())
        if window != nil {
            let proxy = DisplayLinkProxy { [weak self] link in
                guard let self else { link.invalidate(); return }
                self.springBackTick(at: link.targetTimestamp)
            }
            let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
            link.add(to: .main, forMode: .common)
            springBackLink = link
        } else {
            let timer = Timer(timeInterval: 1 / ZoomAnimation.frameRate, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated { self.springBackTick(at: CACurrentMediaTime()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            springBackTimer = timer
        }
    }

    private func springBackTick(at time: CFTimeInterval) {
        guard let s = springBack else { endSpringBack(settle: false); return }
        let p = (time - s.start) / RubberBand.springDuration
        if p >= 1 { endSpringBack(); return }
        setScroll(x: CGFloat(RubberBand.springBack(from: s.fromX, to: s.toX, progress: p)),
                  y: CGFloat(RubberBand.springBack(from: s.fromY, to: s.toY, progress: p)), elastic: true)
    }

    /// Stops a running spring back; `settle` puts the view inside its range (the spring's end state).
    func endSpringBack(settle: Bool = true) {
        let running = springBack != nil
        springBackLink?.invalidate(); springBackLink = nil
        springBackTimer?.invalidate(); springBackTimer = nil
        springBack = nil
        if settle && running { setScroll(x: geometry.scrollX, y: geometry.scrollY) }
    }

    /// Two-finger double tap: zoom to fit in the Fast Cut feel (Final Cut), the system default otherwise.
    public override func smartMagnify(with event: NSEvent) {
        guard feel.doubleTapFits else { super.smartMagnify(with: event); return }
        zoomToFit()
    }

    private var scrollZoom = ScrollZoomState()
    private var scrollAxisLock = ScrollAxisLock()
    private var pinchGuard = PinchScrollGuard()

    private static func scrollPhase(_ p: NSEvent.Phase) -> ScrollZoomState.Phase {
        if p.contains(.began) { return .began }
        if p.contains(.changed) { return .changed }
        if p.contains(.ended) { return .ended }
        if p.contains(.cancelled) { return .cancelled }
        if p.contains(.mayBegin) { return .mayBegin }
        if p.contains(.stationary) { return .stationary }
        return .none
    }

    public override func magnify(with event: NSEvent) {
        pinchGuard.magnify(phase: Self.scrollPhase(event.phase), now: ProcessInfo.processInfo.systemUptime)
        let anchor = convert(event.locationInWindow, from: nil).x
        setZoom(pointsPerSecond: geometry.pointsPerSecond * TimelineZoom.pinchFactor(magnification: Double(event.magnification)), anchorX: anchor)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { endZoomMotion() }   // sharp as soon as the fingers lift
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        endZoomMotion()
    }

    private func gestureModifiers(_ e: NSEvent) -> GestureModifiers { Self.gestureModifiers(e.modifierFlags) }

    static func gestureModifiers(_ f: NSEvent.ModifierFlags) -> GestureModifiers {
        var m: GestureModifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        return m
    }

    private func feedInteraction() {
        interaction.geometry = geometry
        interaction.playhead = playhead
        interaction.markers = timeline.markerSnapTimes(beatLevel: beatSnapLevel) + timeline.clipMarkerTimes()
    }

    /// Shows the in-flight gesture (`interaction.preview`) and mirrors selection and scroll changes into the view.
    private func refreshFromInteraction() {
        if interaction.moveHint != lastHint {
            lastHint = interaction.moveHint
            onGestureHint?(lastHint)
        }
        if interaction.moveHint?.contains("opy") == true { NSCursor.dragCopy.set() }
        if let two = interaction.slipTwoUp {
            slipTwoUpShown = true
            onSlipTwoUp?(two, interaction.preview)
        } else if slipTwoUpShown {
            slipTwoUpShown = false
            onSlipTwoUp?(nil, interaction.preview)
        }
        if interaction.geometry.scrollX != geometry.scrollX || interaction.geometry.scrollY != geometry.scrollY {
            setScroll(x: interaction.geometry.scrollX, y: interaction.geometry.scrollY)
        }
        let preview = interaction.preview
        var changedRows: [CGRect]? = []                  // nil: the whole content
        if preview != timeline {
            let old = timeline, oldBadges = syncBadges
            timeline = preview
            syncBadges = preview.syncOffsets()
            changedRows = Self.changedRows(old, preview, badges: (oldBadges, syncBadges), geometry: geometry,
                                           ducking: duckCurve?.ducking().map { !$0.isOff } ?? false)
            rebuildHeaders()
            syncChildren()
            invalidateCursors()
        }
        if interaction.selection != selection || interaction.captionSelection != captionSelection {
            selection = interaction.selection
            captionSelection = interaction.captionSelection
            onSelectionChange?(selection, captionSelection)
            changedRows = nil
        }
        if interaction.wordSelection != shownWord {
            shownWord = interaction.wordSelection
            changedRows = nil
        }
        // A drag step moves clips inside their rows: only those rows' content is re-rendered (the overlays redraw anyway).
        if let rows = changedRows {
            for r in rows { contentCache.invalidate(r) }
            displayViewport()
        } else {
            needsDisplay = true
        }
    }

    /// Selects a word of a caption together with its caption (nil: no word; the caption selection stays).
    func selectWord(_ ref: CaptionWordRef?) {
        feedInteraction()
        if let ref {
            interaction.setSelection([])
            interaction.setCaptionSelection([ref.caption])
        }
        interaction.setWordSelection(ref)
        refreshFromInteraction()
    }

    /// Commits a word edit made outside a gesture (typed, inserted, deleted, split, joined, replaced): one undo step.
    func applyCaptionEdit(_ out: Timeline, undoName: String, captions: Set<CaptionItem.ID>, word: CaptionWordRef?) {
        guard out != timeline else { return }
        feedInteraction()
        let commit = interaction.commitCaptionEdit(out, undoName: undoName, captions: captions, word: word)
        refreshFromInteraction()
        onCommit?(commit)
    }

    /// The row strips (view space, full width) whose content differs between `old` and `new`, or nil when anything else
    /// changed (rows, captions, timeline-wide state, live ducking whose curve spans rows).
    static func changedRows(_ old: Timeline, _ new: Timeline, badges: ([Clip.ID: Int64], [Clip.ID: Int64]),
                            geometry: TimelineGeometry, ducking: Bool) -> [CGRect]? {
        guard !ducking, old.tracks.count == new.tracks.count else { return nil }
        var rest = old
        rest.tracks = new.tracks
        guard rest == new else { return nil }
        let rows = geometry.rows(for: new)
        guard rows == geometry.rows(for: old) else { return nil }
        var changed = Set<Track.ID>()
        for (a, b) in zip(old.tracks, new.tracks) where a != b { changed.insert(b.id) }
        let (ba, bb) = badges
        if ba != bb {
            for t in new.tracks where !changed.contains(t.id) {
                if t.clips.contains(where: { ba[$0.id] != bb[$0.id] }) { changed.insert(t.id) }
            }
        }
        return rows.filter { changed.contains($0.track) }
            .map { CGRect(x: -1e6, y: $0.y - 2, width: 2e6, height: $0.height + $0.laneSpace + 4) }
    }

    public override func mouseDown(with event: NSEvent) {
        escapeCancelled = false
        wordEditor?.finish(commit: true)       // a press anywhere takes what was typed into a word
        window?.makeFirstResponder(self)
        onFocusRequest?()
        let p = convert(event.locationInWindow, from: nil)
        if let zone = resizeZone(at: p) {      // a resize does not stop playback
            if zone == .split, event.clickCount == 2 {       // double-click: back to the middle
                setSplitFraction(TrackSizing.defaultSplitFraction)
                onSplitChange?(geometry.splitFraction)
                return
            }
            resizing = (zone, p.y, layoutRows(), geometry.splitFraction)
            return
        }
        if beginKeystoneDrag(at: p) { return }
        if beginItemLaneDrag(at: p, modifiers: event.modifierFlags) { return }
        if beginSpeedDrag(at: p, event: event) { return }
        if beginAttachDrag(at: p, modifiers: event.modifierFlags) { return }
        if beginKeyLaneClick(at: p, event: event) { return }
        keyLaneKeysActive = false
        if beginVolumeDrag(at: p, event: event) || beginOpacityDrag(at: p, event: event) { return }
        if !selectedLineKeys.isEmpty { onLineKeyClick?(nil, false) }
        onPointerDown?()
        if jumpToWeakStretch(at: p) { return }
        if let row = geometry.captionRows(for: timeline).first(where: { captionEyeRect(in: $0).insetBy(dx: -3, dy: -3).contains(p) }),
           let track = timeline.captionTrack(row.track) {
            onToggleCaptionTrackVisibility?(track.id)
            return
        }
        if event.clickCount == 1, !dropPreview.isActive, let kind = idleGhostKind(at: p) { onAddTrack?(kind); return }
        if transitionMouseDown(p, event: event) { return }
        if let id = attachPointClick(at: p, modifiers: event.modifierFlags), let set = onSetAttachPoint {
            set(id, geometry.time(atX: p.x))
            return
        }
        // Two quick Razor or Zoom clicks are two cuts / zooms; every other tool opens the item on double-click.
        let opens = event.clickCount == 2 && toolState.timelineTool != .razor && toolState.timelineTool != .zoom
        if opens, case .caption(let id, _) = geometry.hitTest(p, in: timeline) {
            // Captions are corrected on the track: the word under the pointer becomes a field. A caption without words
            // (or one the zoom cannot open) keeps the Text panel.
            if !beginWordEditing(at: p, caption: id) { onEditCaptionText?(id) }
            return
        }
        if event.clickCount == 2, toolState.timelineTool == .selection, case .clip(let id, let zone) = geometry.hitTest(p, in: timeline),
           zone != .body, let tr = timeline.tracks.first(where: { $0.clips.contains { $0.id == id } }),
           let c = tr.clips.first(where: { $0.id == id }), !tr.isLocked, c.sequence == nil, c.generator == nil,
           // Only a full-width handle counts: on a clip too narrow for a real body the double-click keeps opening it in Source.
           geometry.x(for: c.timeline.end) - geometry.x(for: c.start) >= 3 * TimelineGeometry.maxTrimHandleWidth,
           let point = timeline.trimPoint(at: zone == .head ? c.start : c.timeline.end, on: tr.id) {
            onOpenTrimMode?(point, zone == .tail)       // TL-08: double-click an edit opens Trim mode on the side clicked
            return
        }
        if opens, case .clip(let id, _) = geometry.hitTest(p, in: timeline),
           let clip = timeline.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) {
            // Double-click is the primary action (SH-51): nested sequence opens, text edits, media opens in Source.
            if let seq = clip.sequence { onOpenNestedSequence?(seq); return }
            if clip.tone != nil { onEditToneClip?(id); return }
            if clip.isGraphics, let open = onOpenGraphicLayers { open(id); return }
            if clip.generator != nil { onEditTextClip?(id); return }
            onOpenClipInSource?(clip.media); return
        }
        if geometry.hitTest(p, in: timeline) == .ruler {
            // Above the track headers the ruler shows nothing: markers and In/Out scrolled under there cannot be grabbed.
            let onContent = p.x >= TimelineGeometry.contentOriginX
            if event.clickCount == 2, let m = markerID(at: p) { onEditMarker?(m); return }   // double-click a marker flag
            if let h = markerEndHandleID(at: p), let m = timeline.markers.first(where: { $0.id == h }) {
                markerDurationDrag = (h, m.time, m.duration, false)     // dragging the bar end changes the duration
                return
            }
            if let m = markerID(at: p), let time = timeline.markers.first(where: { $0.id == m })?.time {
                markerDrag = (m, p.x, false, time)         // a drag moves the marker, a click still seeks (mouse up)
                return
            }
            if onContent, let io = timeline.inOut, !io.isEmpty, let part = InOutDrag.part(atX: p.x, range: io, geometry: geometry) {
                inOutDrag = (part, p.x, geometry.time(atX: p.x), false, io)      // a drag trims / moves, a click still seeks (mouse up)
                return
            }
            // The ruler is the playhead's handle: the press itself begins the scrub gesture (stops playback), a click
            // without any drag included. Waiting for the first mouseDragged let a plain click seek while playing on.
            scrubbing = (true, true)
            onScrubBegan?()
            rulerScrub(to: scrubTime(at: p, shift: event.modifierFlags.contains(.shift)))
            return
        }
        if toolState.timelineTool != .zoom, toolState.timelineTool != .hand,
           let h = ClipMarkerFlags.hit(at: p, in: timeline, geometry: geometry) {
            if event.clickCount == 2 { onEditClipMarker?(h.clip, h.marker); return }
            clipMarkerDrag = (h, p.x, false)           // a drag moves the flag; a plain click does nothing
            return
        }
        // The playhead moves only by its handle in the ruler: in the lanes a click at the playhead selects the clip there.
        if toolState.timelineTool == .zoom, p.x >= TimelineGeometry.contentOriginX, p.y >= TimelineGeometry.rulerHeight {
            zoomDrag = (p, p, event.modifierFlags.contains(.option))
            return
        }
        if transitionState.selected != nil, !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            setSelectedTransition(nil)
        }
        if let t = skimmerTime, event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty {
            // Fast Cut: a press over the tracks also puts the playhead where the skimmer is (the seek ends the skim).
            clearSkimmer()
            onSkim?(nil)
            onSeek?(t)
        }
        feedInteraction()
        interaction.mouseDown(p, modifiers: gestureModifiers(event))
        lastDrag = (p, gestureModifiers(event))
        refreshFromInteraction()
    }

    public override func mouseDragged(with event: NSEvent) {
        if escapeCancelled { return }
        let p = convert(event.locationInWindow, from: nil)
        if updateKeystoneDrag(to: p) { return }
        if itemLaneDragged(to: p, modifiers: event.modifierFlags) { return }
        if updateSpeedDrag(to: p) { return }
        if updateAttachDrag(to: p) { return }
        if updateVolumeDrag(to: p) || updateOpacityDrag(to: p) { return }
        if transitionMouseDragged(p, event: event) { return }
        if let r = resizing {
            let dy = p.y - r.startY
            switch r.zone {
            case .split:
                // Only the split moves: the heights as drawn are frozen so stretched rows do not re-fit under the pointer.
                let frozen = TrackSizing.frozen(r.rows)
                if geometry.heightOverrides != frozen { applyHeights(frozen, notify: false) }
                geometry.splitFraction = TrackSizing.splitFraction(startFraction: r.startFraction, dy: dy,
                                                                   available: geometry.splitAvailable(for: timeline))
                clampScroll()
                syncChildren()
                invalidateCursors()
                needsDisplay = true
            case .trackEdge(let id):
                let start = r.rows.first { $0.track == id }?.height ?? 0
                applyHeights(TrackSizing.resized(rows: r.rows, track: id, to: start + dy,
                                                 wholeKind: event.modifierFlags.contains(.shift)), notify: false)
            }
            return
        }
        if var z = zoomDrag {
            z.current = p
            zoomDrag = z
            needsDisplay = true
            return
        }
        if var d = inOutDrag {
            if !d.moved, abs(p.x - d.downX) < TimelineInteraction.dragThreshold { return }
            d.moved = true
            inOutDrag = d
            lastDrag = (p, gestureModifiers(event))
            dragInOut(to: p)
            updateAutoscroll()
            return
        }
        if var d = clipMarkerDrag {
            if !d.moved, abs(p.x - d.downX) < TimelineInteraction.dragThreshold { return }
            d.moved = true
            clipMarkerDrag = d
            lastDrag = (p, gestureModifiers(event))
            dragClipMarker(to: p)
            updateAutoscroll()
            return
        }
        if var d = markerDurationDrag {
            d.moved = true
            markerDurationDrag = d
            let r = MarkerRange.duration(forEndTime: geometry.unsnappedTime(atX: p.x), start: d.start, timeline: timeline,
                                         markerID: d.id, snapping: toolState.snapping != interaction.snapInverted,
                                         geometry: geometry, playhead: playhead, beatLevel: beatSnapLevel)
            _ = timeline.setMarkerDuration(d.id, to: r)
            syncChildren(); needsDisplay = true
            return
        }
        if var d = markerDrag {
            if !d.moved, abs(p.x - d.downX) < TimelineInteraction.dragThreshold { return }
            d.moved = true
            markerDrag = d
            lastDrag = (p, gestureModifiers(event))
            dragMarker(to: p)
            updateAutoscroll()
            return
        }
        if scrubbing.active {
            if !scrubbing.began { scrubbing.began = true; onScrubBegan?() }
            lastDrag = (p, gestureModifiers(event))
            rulerScrub(to: scrubTime(at: p, shift: event.modifierFlags.contains(.shift)))
            updateAutoscroll()
            return
        }
        interaction.geometry = geometry
        interaction.mouseDragged(p, modifiers: gestureModifiers(event))
        lastDrag = (p, gestureModifiers(event))
        refreshFromInteraction()
        updateAutoscroll()
    }

    /// One step of a lane drag. A moving bar scrolls the timeline at its edges like a clip drag (same autoscroll).
    func itemLaneDragged(to p: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard updateItemLaneDrag(to: p, modifiers: modifiers) else { return false }
        if itemLanes.drag?.moved == true { lastDrag = (p, Self.gestureModifiers(modifiers)); updateAutoscroll() }
        return true
    }

    // MARK: Zoom tool, marker drag

    private func applyZoom(scale: Double, scrollX: Double, continuous: Bool = false) {
        cancelZoomAnimation()
        if continuous { noteZoomStep(.continuous) }
        geometry.pointsPerSecond = TimelineZoom.clamp(scale, to: zoomLimits)
        geometry.scrollX = CGFloat(scrollX)
        clampScroll()
        viewportChanged()
    }

    private func finishZoomDrag(_ z: (start: CGPoint, current: CGPoint, zoomOut: Bool)) {
        zoomDrag = nil
        needsDisplay = true
        let dx = abs(z.current.x - z.start.x), dy = abs(z.current.y - z.start.y)
        if max(dx, dy) < TimelineInteraction.dragThreshold {
            let r = TimelineZoom.zoomClick(scale: zoomTarget.scale, scrollX: zoomTarget.scrollX,
                                           anchorX: Double(z.start.x - TimelineGeometry.contentOriginX),
                                           zoomOut: z.zoomOut, range: zoomLimits)
            startZoomAnimation(toScale: r.scale, toScroll: r.scrollX,
                               mode: .anchored(x: Double(z.start.x - TimelineGeometry.contentOriginX)))
        } else {
            func seconds(_ x: CGFloat) -> Double {
                let t = geometry.unsnappedTime(atX: x)
                return Double(t.value) / Double(t.timescale)
            }
            let r = TimelineZoom.zoomMarquee(startSeconds: seconds(z.start.x), endSeconds: seconds(z.current.x),
                                             viewport: Double(contentViewportWidth), range: zoomLimits)
            applyZoom(scale: r.scale, scrollX: r.scrollX)
        }
    }

    /// Previews the In/Out drag in the local copy of the timeline; `mouseUp` commits it.
    private func dragInOut(to p: CGPoint) {
        guard let d = inOutDrag else { return }
        let r = InOutDrag.target(part: d.part, original: d.original, downTime: d.downTime, time: geometry.time(atX: p.x),
                                 frameDuration: geometry.frameDuration)
        timeline.setMarkedRange(r)
        syncChildren()
        needsDisplay = true
    }

    /// Moves the dragged clip marker flag in the local copy of the timeline (preview); `mouseUp` commits it.
    private func dragClipMarker(to p: CGPoint) {
        guard let d = clipMarkerDrag else { return }
        let r = ClipMarkerFlags.target(time: geometry.unsnappedTime(atX: p.x), dragging: d.hit, in: timeline, playhead: playhead,
                                       snapping: toolState.snapping != interaction.snapInverted, geometry: geometry)
        timeline.moveClipMarker(d.hit.marker, on: d.hit.clip, to: r.time)
        setScrubSnap(r.hit?.time)
        syncChildren()
        needsDisplay = true
    }

    /// Moves the dragged marker flag in the local copy of the timeline (preview); `mouseUp` commits it.
    private func dragMarker(to p: CGPoint) {
        guard let d = markerDrag else { return }
        let r = MarkerDrag.target(time: geometry.unsnappedTime(atX: p.x), dragging: d.id, in: timeline, playhead: playhead,
                                  snapping: toolState.snapping != interaction.snapInverted, geometry: geometry,
                                  beatLevel: beatSnapLevel)
        timeline.moveMarker(d.id, to: r.time)
        setScrubSnap(r.hit?.time)
        syncChildren()
        needsDisplay = true
    }

    // MARK: Edge autoscroll

    /// Starts or stops the autoscroll timer for the drag in flight: the pointer near the left or right edge of the
    /// content area scrolls it (`TimelineAutoscroll`), and the gesture is fed the same pointer position again.
    private func updateAutoscroll() {
        guard let l = lastDrag, toolState.timelineTool != .hand, toolState.timelineTool != .zoom else { stopAutoscroll(); return }
        let v = TimelineAutoscroll.velocity(pointerX: l.point.x, viewLeft: TimelineGeometry.contentOriginX, viewRight: bounds.width)
        if v == 0 { stopAutoscroll(); return }
        guard autoscrollTimer == nil else { return }
        autoscrollLast = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let alive = MainActor.assumeIsolated { [weak self] in
                self?.autoscrollTick()
                return self != nil
            }
            if !alive { timer.invalidate() }                           // the view went away
        }
        RunLoop.main.add(timer, forMode: .common)                      // keeps firing during event tracking
        autoscrollTimer = timer
    }

    private func stopAutoscroll() { autoscrollTimer?.invalidate(); autoscrollTimer = nil }

    private func autoscrollTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - autoscrollLast, 0.1)
        autoscrollLast = now
        guard var l = lastDrag, isDragging else { stopAutoscroll(); return }
        l.modifiers = Self.gestureModifiers(NSEvent.modifierFlags)      // keys pressed or released since the last mouse event
        lastDrag = l
        let v = TimelineAutoscroll.velocity(pointerX: l.point.x, viewLeft: TimelineGeometry.contentOriginX, viewRight: bounds.width)
        guard v != 0 else { stopAutoscroll(); return }
        let before = geometry.scrollX
        scroll(byX: v * CGFloat(dt), y: 0)
        guard geometry.scrollX != before else { return }
        replayDrag()
    }

    /// Feeds the last pointer position to the gesture in flight again (after a scroll or a Hold-S flip).
    private func replayDrag() {
        guard var l = lastDrag else { return }
        l.modifiers = Self.gestureModifiers(NSEvent.modifierFlags)
        lastDrag = l
        if clipMarkerDrag?.moved == true { dragClipMarker(to: l.point); return }
        if markerDrag?.moved == true { dragMarker(to: l.point); return }
        if inOutDrag?.moved == true { dragInOut(to: l.point); return }
        if scrubbing.active, scrubbing.began { rulerScrub(to: scrubTime(at: l.point, shift: l.modifiers.contains(.shift))); return }
        if itemLanes.drag?.moved == true { _ = updateItemLaneDrag(to: l.point, modifiers: NSEvent.modifierFlags); return }
        guard !interaction.isIdle else { return }
        interaction.geometry = geometry
        interaction.mouseDragged(l.point, modifiers: l.modifiers)
        refreshFromInteraction()
    }

    /// A clip, edge, marker, playhead, zoom-box or item lane drag is in flight.
    /// The zoom tool's box counts too: its Esc must reach the view (cancel), not switch the tool (AppController).
    public var isDragging: Bool {
        !interaction.isIdle || scrubbing.active || markerDrag != nil || clipMarkerDrag != nil || inOutDrag != nil || zoomDrag != nil || itemLanes.drag?.moved == true
    }

    /// Hold-S while dragging: snapping is flipped until the key comes up (the gesture is recomputed at once).
    /// Re-runs the running drag with the current tool state (a modifier-like key such as the Fast Cut ` hold changed).
    public func refreshGesture() {
        guard isDragging else { return }
        replayDrag()
    }

    public func setSnapInverted(_ on: Bool) {
        guard isDragging || !on else { return }
        guard interaction.snapInverted != on else { return }
        interaction.snapInverted = on
        replayDrag()
    }

    /// Trim mode shows the trimmed edit as the selected edge(s).
    public func selectEdges(_ e: EdgeSelection) {
        interaction.setEdgeSelection(e)
        needsDisplay = true
    }

    /// Ctrl+T: the next trim type of the selected edit (regular, ripple, rolling). False when no edit is selected.
    @discardableResult
    public func cycleTrimType() -> Bool {
        guard let sel = interaction.edgeSelection else { return false }
        interaction.setEdgeSelection(EdgeEdits.cycled(sel, in: timeline))
        needsDisplay = true
        return true
    }

    public override func mouseUp(with event: NSEvent) {
        defer { interaction.snapInverted = false; updateSkimmerFromPointer() }
        if escapeCancelled { escapeCancelled = false; return }
        stopAutoscroll()
        lastDrag = nil
        if endKeystoneDrag(at: convert(event.locationInWindow, from: nil)) { return }
        if endSpeedDrag(at: convert(event.locationInWindow, from: nil)) { return }
        if endAttachDrag(at: convert(event.locationInWindow, from: nil)) { return }
        let up = convert(event.locationInWindow, from: nil)
        if endItemLaneDrag(at: up, modifiers: event.modifierFlags) { return }
        if endVolumeDrag(at: up) || endOpacityDrag(at: up) { return }
        if transitionMouseUp(up, event: event) { return }
        if let z = zoomDrag { finishZoomDrag((z.start, convert(event.locationInWindow, from: nil), z.zoomOut)); return }
        if let d = inOutDrag {
            inOutDrag = nil
            let p = convert(event.locationInWindow, from: nil)
            if d.moved {
                let r = InOutDrag.target(part: d.part, original: d.original, downTime: d.downTime, time: geometry.time(atX: p.x),
                                         frameDuration: geometry.frameDuration)
                if r != d.original { onInOutChange?(r, d.part.markedPart) } else { timeline.setMarkedRange(d.original); syncChildren(); needsDisplay = true }
            } else {
                rulerClick(at: geometry.time(atX: p.x))
            }
            return
        }
        if let d = clipMarkerDrag {
            clipMarkerDrag = nil
            setScrubSnap(nil)
            guard d.moved else { return }
            let p = convert(event.locationInWindow, from: nil)
            let r = ClipMarkerFlags.target(time: geometry.unsnappedTime(atX: p.x), dragging: d.hit, in: timeline, playhead: playhead,
                                           snapping: toolState.snapping != interaction.snapInverted, geometry: geometry)
            timeline.moveClipMarker(d.hit.marker, on: d.hit.clip, to: d.hit.time)    // back to the original, the session commits
            syncChildren(); needsDisplay = true
            if r.time != d.hit.time { onClipMarkerMoved?(d.hit.clip, d.hit.marker, r.time) }
            return
        }
        if let d = markerDurationDrag {
            markerDurationDrag = nil
            let now = timeline.markers.first { $0.id == d.id }?.duration ?? d.original
            _ = timeline.setMarkerDuration(d.id, to: d.original)         // back to the original, the session commits
            syncChildren(); needsDisplay = true
            if d.moved, now != d.original { onMarkerDurationChanged?(d.id, now) }
            return
        }
        if let d = markerDrag {
            markerDrag = nil
            setScrubSnap(nil)
            let p = convert(event.locationInWindow, from: nil)
            if d.moved {
                let r = MarkerDrag.target(time: geometry.unsnappedTime(atX: p.x), dragging: d.id, in: timeline, playhead: playhead,
                                          snapping: toolState.snapping != interaction.snapInverted, geometry: geometry,
                                          beatLevel: beatSnapLevel)
                if r.time != d.original { onMarkerMoved?(d.id, r.time) } else { timeline.moveMarker(d.id, to: d.original); syncChildren(); needsDisplay = true }
            } else {
                rulerClick(at: geometry.time(atX: p.x))
            }
            return
        }
        if resizing != nil {
            let wasSplit = resizing?.zone == .split
            resizing = nil
            onTrackHeightsChange?(geometry.heightOverrides)
            if wasSplit { onSplitChange?(geometry.splitFraction) }
            return
        }
        if scrubbing.active {
            if scrubbing.began { onScrubEnded?() }
            scrubbing = (false, false)
            setScrubSnap(nil)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        interaction.geometry = geometry
        let commit = interaction.mouseUp(p, modifiers: gestureModifiers(event))
        refreshFromInteraction()
        if let m = interaction.releasedRejection { onRejection?(m) }
        if let commit { onCommit?(commit) }
    }

    /// Marker whose flag is under a ruler point (within 6 pt of its pole).
    public func markerID(at p: CGPoint) -> Marker.ID? {
        guard p.x >= TimelineGeometry.contentOriginX,                           // hidden under the track headers
              MarkerRange.grabBand(rulerHeight: TimelineGeometry.rulerHeight).contains(p.y) else { return nil }   // above: playhead handle
        return timeline.markers.map { ($0.id, abs(geometry.x(for: $0.time) - p.x)) }
            .filter { $0.1 <= 6 }.min { $0.1 < $1.1 }?.0                       // the nearest flag, so close ones stay reachable
    }

    /// Range marker whose bar end is under a ruler point (within 5 pt of the end).
    public func markerEndHandleID(at p: CGPoint) -> Marker.ID? {
        guard p.x >= TimelineGeometry.contentOriginX,
              MarkerRange.grabBand(rulerHeight: TimelineGeometry.rulerHeight).contains(p.y) else { return nil }
        return MarkerRange.endHandle(atX: p.x, markers: timeline.markers, geometry: geometry)
    }

    /// Double-click on a marker in the ruler: the host opens the marker dialog.
    public var onEditMarker: ((Marker.ID) -> Void)?
    /// Double-click on a clip that nests another sequence.
    public var onOpenNestedSequence: ((Timeline.ID) -> Void)?
    /// Double-click a text clip: edit its text in the Program monitor.
    public var onEditTextClip: ((Clip.ID) -> Void)?
    /// Double-click a Graphic: its layers open in the Graphics panel (the big layer view).
    public var onOpenGraphicLayers: ((Clip.ID) -> Void)?
    /// Double-click on a tone clip: Tone Settings.
    public var onEditToneClip: ((Clip.ID) -> Void)?
    /// Double-click a media clip: load its media in the Source monitor.
    public var onOpenClipInSource: ((UUID) -> Void)?
    /// Double-click on a clip edge with the Selection tool: the edit point and whether the pointer is before it (Trim mode).
    public var onOpenTrimMode: ((TrimPoint, Bool) -> Void)?

    /// Time under the pointer for a playhead drag. Shift sticks it to clip edges, markers and 0 and shows the snap line.
    private func scrubTime(at p: CGPoint, shift shiftHeld: Bool) -> Time {
        let shift = shiftHeld || interaction.snapInverted      // Hold-S sticks the playhead like Shift does
        guard shift else { setScrubSnap(nil); return geometry.time(atX: p.x) }
        let r = PlayheadSnap.resolve(geometry.unsnappedTime(atX: p.x), timeline: timeline, geometry: geometry,
                                       beatLevel: beatSnapLevel)
        setScrubSnap(r.hit?.time)
        return r.time
    }

    private func setScrubSnap(_ t: Time?) {
        guard t != scrubSnapTime else { return }
        for time in [scrubSnapTime, t].compactMap({ $0 }) {
            displayOverlay(CGRect(x: geometry.x(for: time) - 2, y: TimelineGeometry.rulerHeight, width: 4, height: bounds.height))
        }
        scrubSnapTime = t
    }

    /// Right-click: selects the item under the pointer (see `TimelineInteraction.contextSelect`) before the menu opens.
    public func contextSelect(at p: CGPoint) {
        feedInteraction()
        interaction.contextSelect(at: p)
        refreshFromInteraction()
    }

    /// A drag Escape can undo: clip/edge/caption gestures, marker and zoom drags and a moved item-lane bar (the playhead
    /// scrub keeps its position). Every drag `isDragging` reports that changes the timeline is in here.
    public var cancelsOnEscape: Bool {
        !interaction.isIdle || attachDrag != nil || markerDrag != nil || clipMarkerDrag != nil || inOutDrag != nil || zoomDrag != nil || itemLanes.drag?.moved == true
    }
    /// Set by Escape mid-drag: the rest of that drag (moves and the mouse up) is ignored.
    private var escapeCancelled = false

    /// Escape during a drag.
    /// One step of a ruler scrub gesture (falls back to a plain seek when no scrub handler is wired).
    private func rulerScrub(to t: Time) { if let s = onScrub { s(t) } else { onSeek?(t) } }

    /// A click on a marker flag or the In/Out bar (released without a drag): the playhead jumps there as a one-step scrub
    /// gesture, so playback stops like any other ruler press (DECISIONS "Transport: one owner of playing").
    private func rulerClick(at t: Time) {
        onScrubBegan?()
        onSeek?(t)
        onScrubEnded?()
    }

    public func cancelGesture() {
        stopAutoscroll()
        lastDrag = nil
        interaction.snapInverted = false
        zoomDrag = nil
        cancelItemLaneDrag()
        if let d = attachDrag { attachDrag = nil; setTimeline(d.original); needsDisplay = true }
        if scrubbing.active {                          // Escape swallows the mouse-up: end the scrub gesture here
            if scrubbing.began { onScrubEnded?() }
            scrubbing = (false, false)
            setScrubSnap(nil)
        }
        if let d = markerDrag { timeline.moveMarker(d.id, to: d.original); markerDrag = nil; syncChildren() }
        if let d = markerDurationDrag { _ = timeline.setMarkerDuration(d.id, to: d.original); markerDurationDrag = nil; syncChildren() }
        if let d = clipMarkerDrag {
            timeline.moveClipMarker(d.hit.marker, on: d.hit.clip, to: d.hit.time)
            clipMarkerDrag = nil; syncChildren(); needsDisplay = true
        }
        if let d = inOutDrag { timeline.setMarkedRange(d.original); inOutDrag = nil; syncChildren(); needsDisplay = true }
        interaction.cancel()
        refreshFromInteraction()
    }

    // MARK: Drop from the Project panel

    /// What a drag carries.
    public enum DropSource: Sendable { case media([MediaRef.ID]), sequences([Timeline.ID]), textTemplate(String), files([URL]), effect(String), titleBlock(UUID) }

    private func dropped(_ info: NSDraggingInfo) -> DropSource? {
        let pb = info.draggingPasteboard
        if let id = pb.string(forType: .sequenceEffectID) ?? Self.presetEffectID(from: pb) { return .effect(id) }
        if let s = pb.string(forType: .sequenceMediaIDs) {
            let ids = ProjectPanelModel.decodeItems(s).compactMap { if case .media(let id) = $0 { id } else { nil } }
            if !ids.isEmpty { return .media(ids) }
            let seqs = ProjectPanelModel.decodeItems(s).compactMap { if case .sequence(let id) = $0 { id } else { nil } }
            if !seqs.isEmpty { return .sequences(seqs) }
        }
        if let id = pb.string(forType: .sequenceTextTemplate) { return .textTemplate(id) }
        if let id = pb.string(forType: .sequenceTitleBlock).flatMap(UUID.init(uuidString:)) { return .titleBlock(id) }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.isEmpty ? nil : .files(urls)
    }

    /// The clip an effect drag would land on at `p`: the one under the pointer, unless its track is locked or none of the
    /// dragged effects fits it (`EffectDropRules`): then nothing lights up and the drop is refused.
    func effectDropClip(at p: CGPoint, effectIDs: [String]) -> Clip.ID? {
        guard let id = clipID(at: p) else { return nil }
        for track in timeline.tracks {
            guard let clip = track.clips.first(where: { $0.id == id }) else { continue }
            return EffectDropRules.accepts(effectIDs: effectIDs, clip: clip, trackLocked: track.isLocked) ? id : nil
        }
        return nil
    }

    private func clipID(at p: CGPoint) -> Clip.ID? {
        if case .clip(let id, _) = geometry.hitTest(p, in: timeline) { return id }
        return nil
    }

    /// Option held with Project media or a sequence: a Replace edit (the first item of several is used).
    private func isReplaceDrop(_ payload: DropSource) -> Bool {
        guard NSEvent.modifierFlags.contains(.option) else { return false }
        switch payload {
        case .media(let ids): return !ids.isEmpty
        case .sequences(let ids): return !ids.isEmpty
        default: return false
        }
    }

    private func trackedUpdate(_ info: NSDraggingInfo) -> NSDragOperation {
        if let op = updateKeystoneDrop(info) { return op }
        guard let payload = dropped(info) else { return [] }
        let p = convert(info.draggingLocation, from: nil)
        if case .effect(let id) = payload, let kind = EffectDragPayload.transitionKind(forID: id) {
            return updateTransitionDrop(kind: kind, at: p) ? .copy : []
        }
        if case .effect(let id) = payload {
            let target = effectDropClip(at: p, effectIDs: EffectDragPayload.decodeDrag(id))
            if target != effectDropTarget { effectDropTarget = target; needsDisplay = true }
            return target == nil ? [] : .copy
        }
        if isReplaceDrop(payload), let target = clipID(at: p) {
            if dropPreview.isActive { endDropTracking() }
            if target != effectDropTarget { effectDropTarget = target; needsDisplay = true }      // Replace edit: the clip lights up
            return .copy
        }
        if case .sequences(let ids) = payload, let why = sequenceDropRefusal?(ids) {
            if !refusalShown { refusalShown = true; onRejection?(why) }
            if dropPreview.isActive { endDropTracking() }
            return []
        }
        if effectDropTarget != nil { effectDropTarget = nil; needsDisplay = true }      // Option released / left the clip mid-drag
        if !dropPreview.isActive {
            let items = dropItemsProvider?(payload) ?? []
            var canCreate = false
            if case .media = payload { canCreate = true }       // only Project-panel media and sequences create tracks
            if case .sequences = payload { canCreate = true }
            dropPreview.begin(items: items.isEmpty ? [DropItem(name: "", duration: Time(seconds: 5))] : items,
                              canCreateTracks: canCreate, streams: dropStreamsProvider?() ?? .both)
            geometry.reservesGhostSpace = canCreate             // two ghost rows under the last track, only during the drag
        }
        let insert = NSEvent.modifierFlags.contains(.command)
        dropPreview.update(point: p, insert: insert, timeline: timeline, geometry: geometry,
                           snapping: toolState.snapping, playhead: playhead)
        needsDisplay = true
        return dropPreview.ghosts.isEmpty ? [] : .copy
    }

    private func endDropTracking() {
        refusalShown = false
        guard dropPreview.isActive || effectDropTarget != nil || transitionState.dropTarget != nil || transitionState.layerDrop != nil
              || keystoneGhost != nil else { return }
        keystoneGhost = nil
        dropPreview.cancel()
        geometry.reservesGhostSpace = false
        effectDropTarget = nil
        transitionState.dropTarget = nil
        transitionState.layerDrop = nil
        needsDisplay = true
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { trackedUpdate(sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { trackedUpdate(sender) }
    /// Left the timeline or Esc: the ghost vanishes, nothing was changed.
    public override func draggingExited(_ sender: NSDraggingInfo?) { endDropTracking() }
    public override func draggingEnded(_ sender: NSDraggingInfo) { endDropTracking() }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDropTracking() }
        if let ok = performKeystoneDrop(sender) { return ok }
        guard let payload = dropped(sender) else { return false }
        if case .effect(let id) = payload, let kind = EffectDragPayload.transitionKind(forID: id) {
            return commitTransitionDrop(kind: kind, at: convert(sender.draggingLocation, from: nil))
        }
        if case .effect(let id) = payload {
            guard let target = effectDropClip(at: convert(sender.draggingLocation, from: nil),
                                              effectIDs: EffectDragPayload.decodeDrag(id)) else { return false }
            // A dragged folder carries several effects (newline separated): all go onto the clip.
            for one in EffectDragPayload.decodeDrag(id) {
                if let preset = PresetDrop.presetID(fromEffectID: one) { onDropPreset?(preset, target) } else { onDropEffect?(one, target) }
            }
            return true
        }
        if isReplaceDrop(payload), let clip = clipID(at: convert(sender.draggingLocation, from: nil)) {
            switch payload {
            case .media(let ids): onReplaceMedia?(ids, clip, NSEvent.modifierFlags.contains(.shift))
            case .sequences(let ids): onReplaceSequence?(ids[0], clip)
            default: break
            }
            return true
        }
        _ = trackedUpdate(sender)
        guard let target = dropPreview.commitTarget else { return false }
        if let kind = dropPreview.commitGhostKind {
            if case .sequences(let ids) = payload { onDropSequencesOnGhost?(ids, target.time, kind, target.insert); return true }
            guard case .media(let ids) = payload else { return false }       // only Project-panel media and sequences create tracks
            onDropMediaOnGhost?(ids, target.time, kind, target.insert)
            return true
        }
        switch payload {
        case .media(let ids): onDropMedia?(ids, target.time, target.track, target.insert)
        case .sequences(let ids): onDropSequences?(ids, target.time, target.track, target.insert)
        case .textTemplate(let id): onDropTextTemplate?(id, target.time, target.track)
        case .files(let urls): onDropFiles?(urls, target.time, target.track, target.insert)
        case .titleBlock(let id): onDropTitleBlock?(id, target.time)
        case .effect: return false
        }
        return true
    }

    public override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        wordEditor?.finish(commit: true)
        let rest = contextMenuProvider?(p) ?? []
        let words = captionWordMenuItems(at: p)
        SQContextMenu.show(items: words.isEmpty || rest.isEmpty ? words + rest : words + [.separator] + rest, for: event, in: self)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleItemLaneKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, cancelsOnEscape { cancelGesture(); escapeCancelled = true; return }
        if event.keyCode == 53, interaction.clearGapAndEdgeSelection() { refreshFromInteraction(); return }   // clears the selection only
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           editSelectedWord() { return }   // Return: the selected word becomes a field
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn()
        case "-": zoomOut()
        case "\\": zoomToFit()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Layout

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        geometry.viewportHeight = Self.trackAreaHeight(viewHeight: newSize.height)
        clampScroll()
        layoutChildren()
        syncChildren()
        invalidateCursors()
        needsDisplay = true
    }

    private func zoomBarSnapshot() -> (scrollX: Double, viewport: Double, scale: Double, extent: Double) {
        let scrollX = Double(geometry.scrollX), viewport = Double(contentViewportWidth), scale = geometry.pointsPerSecond
        let seconds = Double(contentEnd.value) / Double(contentEnd.timescale)
        return (scrollX, viewport, scale,
                TimelineZoom.barExtent(contentSeconds: seconds, scrollX: scrollX, viewport: viewport, scale: scale))
    }

    private func wireZoomBar() {
        zoomBar.handles = { [unowned self] in
            let s = zoomBarSnapshot()
            return TimelineZoom.handles(scrollX: s.scrollX, viewport: s.viewport, scale: s.scale, extent: s.extent)
        }
        zoomBar.onBegin = { [unowned self] in zoomBarDrag = zoomBarSnapshot() }
        zoomBar.onHandle = { [unowned self] lower, fraction in
            guard let s = zoomBarDrag else { return }
            cancelZoomAnimation()
            let r = TimelineZoom.dragHandle(lower: lower, fraction: fraction, scrollX: s.scrollX, viewport: s.viewport, scale: s.scale,
                                            extent: s.extent, range: zoomLimits)
            applyZoom(scale: r.scale, scrollX: r.scrollX, continuous: true)
        }
        zoomBar.onPan = { [unowned self] startFraction in
            guard let s = zoomBarDrag else { return }
            cancelZoomAnimation()
            applyZoom(scale: s.scale, scrollX: max(startFraction, 0) * s.extent * s.scale, continuous: true)
        }
        zoomBar.onFit = { [unowned self] in zoomToFit() }
    }

    private func layoutChildren() {
        zoomFooter.frame = CGRect(x: 0, y: max(bounds.height - ZoomScrollBar.height, 0), width: TimelineGeometry.contentOriginX, height: ZoomScrollBar.height)
        zoomBar.frame = CGRect(x: TimelineGeometry.contentOriginX, y: max(bounds.height - ZoomScrollBar.height, 0),
                               width: max(bounds.width - TimelineGeometry.contentOriginX, 0), height: ZoomScrollBar.height)
        ruler.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineGeometry.rulerHeight)
        emptyState.frame = CGRect(x: TimelineGeometry.contentOriginX, y: TimelineGeometry.rulerHeight,
                                  width: max(bounds.width - TimelineGeometry.contentOriginX, 0),
                                  height: max(bounds.height - TimelineGeometry.rulerHeight - ZoomScrollBar.height, 0))
        updateEmptyState()
    }

    private func updateEmptyState() {
        let show = TimelineEmptyState.isVisible(timeline: timeline, dropActive: dropPreview.isActive)
        if show { emptyState.hint = TimelineEmptyState.hint() }
        emptyState.isHidden = !show
    }

    // MARK: Cursors

    private func invalidateCursors() {
        cursorTimer?.invalidate(); cursorTimer = nil
        window?.invalidateCursorRects(for: self)
    }

    private var cursorTimer: Timer?

    /// While scrolling/zooming, cursor rects are rebuilt once the motion pauses, not on every event.
    private func scheduleCursorInvalidation() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateCursors() }
        }
    }

    // MARK: Razor hover guide

    /// Hover line of the razor tool: where a click would cut. nil with any other tool or off the tracks.
    public private(set) var razorGuideRects: [CGRect] = []
    /// Pointer location in view coordinates; the window's by default, replaceable in tests.
    var pointerProvider: (() -> CGPoint?)?
    private var hoverTracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverTracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        updateSkimmer(pointer: convert(event.locationInWindow, from: nil))
        updateRazorGuide(pointer: convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift),
                         option: event.modifierFlags.contains(.option))
        _ = updateKeystoneCursor(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        updateSkimmer(pointer: nil)
        updateRazorGuide(pointer: nil, shift: false, option: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateRazorGuideFromPointer()
        // Cmd (ripple) and Option (copy) change the cursor over clips without the mouse moving.
        let f = event.modifierFlags
        if toolState.timelineTool == .selection, (f.contains(.command), f.contains(.option)) != (cursorKeys.command, cursorKeys.option) {
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Re-evaluates the guide at the current pointer position (tool, modifier, scroll or zoom changed without the mouse moving).
    func updateRazorGuideFromPointer() {
        updateSkimmerFromPointer()
        guard toolState.timelineTool == .razor else { updateRazorGuide(pointer: nil, shift: false, option: false); return }
        let raw: CGPoint?
        if let pointerProvider { raw = pointerProvider() }
        else if let window { raw = convert(window.mouseLocationOutsideOfEventStream, from: nil) }
        else { raw = nil }
        let mods = NSEvent.modifierFlags
        updateRazorGuide(pointer: raw.flatMap { bounds.contains($0) ? $0 : nil }, shift: mods.contains(.shift), option: mods.contains(.option))
    }

    private func updateRazorGuide(pointer p: CGPoint?, shift: Bool, option: Bool) {
        var r: [CGRect] = []
        feedInteraction()   // scroll/zoom change `geometry` without a mouse event; the cut time must use the current one
        if toolState.timelineTool == .razor, let p, p.x >= TimelineGeometry.contentOriginX, p.y >= TimelineGeometry.rulerHeight,
           p.y < bounds.height - ZoomScrollBar.height {
            let tracks = interaction.razorGuideTracks(at: p, shift: shift, option: option)
            if !tracks.isEmpty {
                let x = geometry.x(for: interaction.razorCutTime(atX: p.x))
                r = RazorGuide.rects(x: x, tracks: Set(tracks), rows: layoutRows())
            }
        }
        guard r != razorGuideRects else { return }
        for old in razorGuideRects + r { displayOverlay(old.insetBy(dx: -2, dy: -1)) }
        razorGuideRects = r
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeThumbnailPrefs()
        invalidateCursors()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        // Left its window: no timer, link or lane drag may outlive it (the mouse up of that drag never arrives).
        guard let window else { stopAutoscroll(); settleZoomAnimation(); endZoomMotion(); lastDrag = nil; cancelItemLaneDrag(); return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowResignedKey() }
        }
    }

    /// The window is no longer key: nothing that waits for a key up or a mouse up that may happen elsewhere stays on.
    func windowResignedKey() {
        stopAutoscroll()
        endZoomMotion()
        updateSkimmer(pointer: nil)
        setSnapInverted(false)       // a key up that happened elsewhere must not leave snapping flipped
        if itemLanes.drag != nil { cancelItemLaneDrag(); lastDrag = nil }   // its mouse up may never arrive
    }

    /// Cmd / Option state the cursor rects were last built for (see `flagsChanged`).
    private var cursorKeys: (command: Bool, option: Bool) = (false, false)

    /// Cursor rects per tool (see `TimelineCursorMap`): trim cursors on clip edges, razor over the tracks, ...
    public override func resetCursorRects() {
        discardCursorRects()
        let content = CGRect(x: TimelineGeometry.contentOriginX, y: TimelineGeometry.rulerHeight,
                             width: max(bounds.width - TimelineGeometry.contentOriginX, 0),
                             height: max(bounds.height - TimelineGeometry.rulerHeight, 0))
        let mods = NSEvent.modifierFlags
        cursorKeys = (mods.contains(.command), mods.contains(.option))
        for r in TimelineCursorMap.regions(timeline: timeline, geometry: geometry, tool: toolState.timelineTool, content: content,
                                           command: cursorKeys.command, option: cursorKeys.option) {
            addCursorRect(r.rect, cursor: TimelineCursors.cursor(for: r.kind))
        }
        addTransitionCursorRects()
        addCaptionWordCursorRects(in: content)
        addItemLaneCursorRects(in: content)
        // Resize cursor on the V/A boundary (full width) and on header row edges; added last so it wins.
        let rows = layoutRows()
        let g = TrackSizing.grab
        for (i, r) in rows.enumerated() where r.maxY > TimelineGeometry.rulerHeight && r.maxY < bounds.height {
            let split = i + 1 < rows.count && r.kind == .video && rows[i + 1].kind == .audio
            let x = TimelineGeometry.toolColumnWidth
            let w = split ? bounds.width - x : TimelineGeometry.headerWidth
            addCursorRect(CGRect(x: x, y: r.maxY - g, width: w, height: 2 * g), cursor: .resizeUpDown)
        }
    }

    private func rebuildHeaders() {
        let ids = Set(timeline.tracks.map(\.id))
        for (id, view) in headers where !ids.contains(id) { view.removeFromSuperview(); headers[id] = nil }
        for t in timeline.tracks where headers[t.id] == nil {
            let v = TrackHeaderView(track: t, label: "")
            v.onToggle = { [weak self] id, toggle in self?.onTrackToggle?(id, toggle) }
            v.onPatchClick = { [weak self, weak v] kind in
                if v?.patchGestureFlags.contains(.option) == true, let solo = self?.onSourcePatchSolo { solo(kind) }
                else { self?.onSourcePatchClick?(kind) }
            }
            let trackID = t.id
            v.onDoubleClick = { [weak self] whole in self?.toggleTrackHeight(trackID, wholeKind: whole) }
            v.onPatchDrag = { [weak self, weak v] kind, p, ended in
                self?.patchDragged(kind, window: p, ended: ended, both: v?.patchGestureFlags.contains(.shift) == true)
            }
            headers[t.id] = v
            addSubview(v, positioned: .below, relativeTo: ruler)   // the ruler stays above scrolled-up headers
        }
    }

    /// Pushes model and viewport into the ruler and header rows.
    private func syncChildren() {
        let sp = TimelineSignpost.log.beginInterval("headerSync")
        defer { TimelineSignpost.log.endInterval("headerSync", sp) }
        ruler.update(geometry: geometry, inOut: timeline.inOut, markers: timeline.markers, playhead: playhead)
        positionHeaders(apply: true)
        updateEmptyState()
    }

    func headerView(for id: Track.ID) -> TrackHeaderView? { headers[id] }

    /// Moves the header rows to their laid-out frames; `apply` also pushes the track state (a no-op when it did not change).
    func positionHeaders(apply: Bool = false) {
        let rows = layoutRows()
        var seen = Set<Track.ID>()
        let matte = timeline.pictureMatteTracks(ofClips: selection)
        let splitTrack = Self.splitRow(rows).map { rows[$0].track }
        for row in rows {
            guard let header = headers[row.track] else { continue }
            seen.insert(row.track)
            header.isSplitRow = row.track == splitTrack
            if header.isHidden { header.isHidden = false }
            let f = CGRect(x: TimelineGeometry.toolColumnWidth, y: row.y, width: TimelineGeometry.headerWidth, height: row.height)
            if header.frame != f { header.frame = f }
            if apply, let track = timeline.track(row.track) {
                header.apply(track: track, label: row.label)
                header.apply(patch: patchState(for: row.track))
                header.isMatteSource = matte.contains(row.track)
            }
        }
        for (id, h) in headers where !seen.contains(id) && !h.isHidden { h.isHidden = true }
    }

    // MARK: Drawing

    /// The last video row above the first audio row (V1): design v9 draws a 2 pt strong line under it. Nil without both kinds.
    static func splitRow(_ rows: [TrackRow]) -> Int? {
        guard let a = rows.firstIndex(where: { $0.kind == .audio }), a > 0 else { return nil }
        return a - 1
    }

    /// Design v9 `.lane.alt`: every second lane counted away from the video / audio split (V2, V4, ... and A1, A3, ...)
    /// takes the lighter lane color, so adding a track on either side never recolors the others.
    static func isAltLane(_ index: Int, in rows: [TrackRow]) -> Bool {
        let firstAudio = rows.firstIndex { $0.kind == .audio } ?? rows.count
        return index < firstAudio ? (firstAudio - 1 - index) % 2 == 1 : (index - firstAudio) % 2 == 0
    }

    public override func draw(_ dirtyRect: NSRect) {
        PlayProbe.timed("timeline.draw dirty \(Int(dirtyRect.width))x\(Int(dirtyRect.height))") { drawTimeline(dirtyRect) }
    }

    private func drawTimeline(_ dirtyRect: NSRect) {
        perf.beginDraw()
        let sp = TimelineSignpost.log.beginInterval("draw")
        defer { perf.endDraw(); TimelineSignpost.log.endInterval("draw", sp) }
        let rows = layoutRows()
        let contentClip = CGRect(x: TimelineGeometry.contentOriginX, y: TimelineGeometry.rulerHeight,
                                 width: max(bounds.width - TimelineGeometry.contentOriginX, 0),
                                 height: max(bounds.height - TimelineGeometry.rulerHeight, 0))
        let clip = dirtyRect.intersection(contentClip)
        // Background outside the content area only: the content (cached or drawn) paints every pixel of `clip` itself.
        let dirty = dirtyRect.intersection(bounds)
        Theme.Colors.timeline.setFill()
        let leftOfContent = CGRect(x: dirty.minX, y: dirty.minY, width: min(dirty.maxX, contentClip.minX) - dirty.minX, height: dirty.height)
        let aboveContent = CGRect(x: max(dirty.minX, contentClip.minX), y: dirty.minY,
                                  width: dirty.maxX - max(dirty.minX, contentClip.minX), height: min(dirty.maxY, contentClip.minY) - dirty.minY)
        for r in [leftOfContent, aboveContent] where r.width > 0 && r.height > 0 { r.fill() }
        if !clip.isEmpty {
            let cached = NSGraphicsContext.current.map { ctx in
                contentCache.draw(in: ctx.cgContext, content: contentClip, clip: clip, scrollX: geometry.scrollX, scrollY: geometry.scrollY,
                                  pointsPerSecond: geometry.pointsPerSecond, canShift: canShiftContent, drawnRects: rectsBeingDrawn(),
                                  edgeItems: { self.edgeDependentRects(viewports: $0, rows: rows) },
                                  scaleLimit: contentScaleLimit,
                                  render: { r in self.drawContent(rows: rows, clip: r, visible: contentClip) })
            } ?? false
            NSGraphicsContext.saveGraphicsState()
            clip.clip()
            if !cached { drawContent(rows: rows, clip: clip, visible: contentClip) }
            drawSilencePreview(clip: clip)
            drawInOutTint(clip: clip)
            drawPlayheadLine(clip: clip)
            drawSkimmerLine(clip: clip)
            drawGestureOverlay(clip: clip)
            drawSpeedTip()
            drawDropOverlay(clip: clip)
            drawItemLaneMoveGhost()
            drawKeystoneOverlay(clip: clip)
            NSGraphicsContext.restoreGraphicsState()
        }
        drawCaptionHeaders(dirty: dirtyRect)
        drawItemLaneHeaders(rows: rows, dirty: dirtyRect)
        if contentCache.isSharpening { scheduleSharpenFrame() }
    }

    /// The rects AppKit clips this draw to (empty outside a display pass, e.g. a direct `draw` into a bitmap).
    private func rectsBeingDrawn() -> [CGRect] {
        guard NSView.focusView === self else { return [] }        // only valid inside AppKit's own draw pass
        var list: UnsafePointer<NSRect>?
        var n = 0
        getRectsBeingDrawn(&list, count: &n)
        guard let list, n > 0 else { return [] }
        return (0..<n).map { list[$0] }
    }

    /// Everything the content cache holds: lanes, clips, captions, transitions (playhead and gesture overlays go on top).
    private func drawContent(rows: [TrackRow], clip: CGRect, visible: CGRect) {
        // Background only where no lane is drawn: lanes are opaque and cover their rows across `clip`. A lane edge off
        // the pixel grid only partly covers its device row, so each lane counts only for the device rows it fully covers
        // (the seam rows get the background under them, as before).
        let t = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform ?? .identity
        func fullRows(_ a: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat)? { Self.fullDevice(a, b, scale: t.d, origin: t.ty, t: t) }
        var lanes: [(CGFloat, CGFloat)] = geometry.captionRows(for: timeline).compactMap { r in
            timeline.captionTrack(r.track) != nil ? fullRows(r.y, r.y + r.height) : nil
        }
        lanes += rows.compactMap { r in drawTrack(r.track) != nil ? fullRows(r.y, r.y + r.height) : nil }
        lanes.sort { $0.0 < $1.0 }
        Theme.Colors.timeline.setFill()
        var y = clip.minY
        for (a, b) in lanes where b > y {
            if a > y { CGRect(x: clip.minX, y: y, width: clip.width, height: min(a, clip.maxY) - y).fill() }
            y = max(y, b)
            if y >= clip.maxY { break }
        }
        if y < clip.maxY { CGRect(x: clip.minX, y: y, width: clip.width, height: clip.maxY - y).fill() }
        drawCaptionLanes(clip: clip, visible: visible)
        drawLanes(rows: rows, clip: clip, visible: visible)
        drawItemLanes(rows: rows, clip: clip, visible: visible)
        drawTransitions(rows: rows, clip: clip)
    }

    /// The user-space part `lo'..<hi'` of `a..<b` along one axis (device = `scale * u + origin`) that covers whole device
    /// pixels only; nil when none is whole or `t` rotates or skews.
    static func fullDevice(_ a: CGFloat, _ b: CGFloat, scale: CGFloat, origin: CGFloat, t: CGAffineTransform) -> (CGFloat, CGFloat)? {
        guard t.b == 0, t.c == 0, scale != 0 else { return nil }
        func integral(_ v: CGFloat) -> Bool { abs(v - v.rounded()) < 1e-6 }
        let da = scale * a + origin, db = scale * b + origin
        let lo = min(da, db), hi = max(da, db)
        let inLo = integral(lo) ? lo.rounded() : lo.rounded(.up), inHi = integral(hi) ? hi.rounded() : hi.rounded(.down)
        guard inHi > inLo else { return nil }
        let ua = (inLo - origin) / scale, ub = (inHi - origin) / scale
        return (min(ua, ub), max(ua, ub))
    }

    /// A lane's fill, except where an opaque clip body covers whole device pixels anyway: the body middles (`middles`, x
    /// ranges in user space, sorted, from `ClipDrawing.opaqueMiddle`) over the device rows fully inside `bodyY`. The rounded
    /// ends and the body's partly covered rows keep the lane under them, so every pixel ends up as before.
    private func fillLane(_ lane: CGRect, middles: [(CGFloat, CGFloat)], bodyY: (CGFloat, CGFloat), t: CGAffineTransform) {
        guard !middles.isEmpty, let ys = Self.fullDevice(max(bodyY.0, lane.minY), min(bodyY.1, lane.maxY), scale: t.d, origin: t.ty, t: t)
        else { lane.fill(); return }
        if ys.0 > lane.minY { CGRect(x: lane.minX, y: lane.minY, width: lane.width, height: ys.0 - lane.minY).fill() }
        if lane.maxY > ys.1 { CGRect(x: lane.minX, y: ys.1, width: lane.width, height: lane.maxY - ys.1).fill() }
        var x = lane.minX
        for m in middles {
            guard let xs = Self.fullDevice(max(m.0, lane.minX), min(m.1, lane.maxX), scale: t.a, origin: t.tx, t: t), t.a > 0, xs.1 > x
            else { continue }
            if xs.0 > x { CGRect(x: x, y: ys.0, width: xs.0 - x, height: ys.1 - ys.0).fill() }
            x = max(x, xs.1)
        }
        if lane.maxX > x { CGRect(x: x, y: ys.0, width: lane.maxX - x, height: ys.1 - ys.0).fill() }
    }

    /// Content pixels may be shifted on scroll only while nothing in them is placed in view coordinates.
    private var canShiftContent: Bool { transitionState.dropTarget == nil && transitionState.layerDrop == nil && !isDragging }

    /// Regions whose picture depends on where `viewport`'s edges are (each a content area, view space): names, sync and FX
    /// badges stick to the edges, text and bodies are cut at them. A clip whose volume or opacity line is sampled from the
    /// left edge (animated) or that shows a speed band counts whole. Viewports that differ only vertically (a vertical
    /// scroll) leave every clip's picture as it was; only the idle ghost strips, drawn only when both fit above the zoom
    /// bar, depend on the vertical position.
    func edgeDependentRects(viewports: [CGRect], rows: [TrackRow]) -> [CGRect] {
        var out: [CGRect] = []
        if Set(viewports.map(\.minY)).count > 1 {
            for g in geometry.ghostRows(for: timeline) { out.append(CGRect(x: TimelineGeometry.contentOriginX, y: g.y, width: bounds.width, height: g.height)) }
        }
        guard Set(viewports.map(\.minX)).count > 1 || Set(viewports.map(\.maxX)).count > 1 || viewports.count < 2 else { return out }
        let band: CGFloat = 12
        // A rect never ends on the clip's own edge: off the pixel grid that device column is shared with the neighbor
        // clip's antialiased end, and CoreGraphics covers such a column slightly differently when the clip rect starts in
        // it (measured: 3 levels at 2x with a quarter-pixel scroll offset). 2 pt further out the column is interior.
        let seam: CGFloat = 2
        func item(_ r: CGRect, name: String, viewport v: CGRect, whole: Bool, fx: Bool) {
            if whole { out.append(r.insetBy(dx: -8, dy: 0)); return }
            if r.minX < v.minX, r.maxX > v.minX {
                // Name (and sync badge) start at the left edge.
                let w = max(6 + ClipDrawing.nameWidth(name) + 4, 80)
                out.append(CGRect(x: v.minX - band, y: r.minY, width: min(r.maxX + seam, v.minX + w + band) - (v.minX - band), height: r.height))
            }
            if r.minX < v.maxX, r.maxX > v.maxX {
                // Text is cut at the right edge, and a name with less than ~23 pt left is not drawn at all.
                let x0 = max(r.minX - seam, v.maxX - 70)      // the name also yields to the fx badge (~21 pt)
                out.append(CGRect(x: x0, y: r.minY, width: v.maxX + band - x0, height: r.height))
            }
        }
        for v in viewports {
            for row in rows {
                guard let track = drawTrack(row.track) else { continue }
                for x in [v.minX, v.maxX] {
                    let i = Self.firstClipIndex(endingAfter: geometry.unsnappedTime(atX: x - 1), in: track.clips)
                    for c in track.clips[i...] {
                        let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
                        if x0 > x + 1 { break }
                        guard x0 <= x + 1, x1 >= x - 1 else { continue }
                        let whole = (track.kind == .audio && !c.animation.volume.track.isEmpty)
                            || (track.kind == .video && (!c.animation.opacity.track.isEmpty || speedBandClips.contains(c.id)))
                        item(CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), name: c.name + SpeedLabel.nameSuffix(for: c),
                             viewport: v, whole: whole, fx: track.kind == .video)
                    }
                }
            }
            for row in geometry.captionRows(for: timeline) {
                guard let track = timeline.captionTrack(row.track) else { continue }
                // Only the captions at the two viewport edges can qualify: start at the first one that reaches the left edge.
                let items = track.items
                var i = max(CaptionWordLayout.firstIndex(endingAfter: geometry.time(atX: v.minX - 2), in: items) - 1, 0)
                while i < items.count {
                    let it = items[i]
                    i += 1
                    let x0 = geometry.x(for: it.range.start), x1 = geometry.x(for: it.range.end)
                    if x0 > v.maxX + 1 { break }
                    guard (x0 <= v.minX + 1 && x1 >= v.minX - 1) || (x0 <= v.maxX + 1 && x1 >= v.maxX - 1) else { continue }
                    // Word boxes sit at their times: nothing in them follows the viewport edge.
                    if CaptionWordLayout.showsWords(it, geometry: geometry) { continue }
                    item(CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), name: CaptionDrawing.preview(it), viewport: v, whole: false, fx: false)
                }
            }
        }
        return out
    }

    /// `clip` is the dirty part of the content area, `visible` the whole content area: clip names and waveforms are laid
    /// out against `visible`, so a thin dirty rect (the playhead line) repaints them exactly as a full redraw would.
    /// The attached clip a Cmd+Opt+click at `p` sets the attach point of (Fast Cut, Selection tool, clip body only:
    /// on an edge Cmd+Opt keeps its trim meaning), else nil.
    func attachPointClick(at p: CGPoint, modifiers: NSEvent.ModifierFlags) -> Clip.ID? {
        guard timeline.isFastCut, toolState.timelineTool == .selection,
              modifiers.intersection([.command, .option, .shift, .control]) == [.command, .option],
              case .clip(let id, .body) = geometry.hitTest(p, in: timeline), timeline.isAttachable(id) else { return nil }
        return id
    }

    /// Fast Cut: the main-track clips the selected attached clips are attached to (host highlight).
    private func magneticHintHosts() -> Set<Clip.ID> { ClipDrawing.attachHosts(of: selection, in: timeline) }

    private func drawCaptionLanes(clip: CGRect, visible: CGRect) {
        let visibleX = CGRect(x: visible.minX, y: 0, width: visible.width, height: bounds.height)
        for row in geometry.captionRows(for: timeline) {
            let laneRect = CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)
            guard laneRect.intersects(clip), let track = timeline.captionTrack(row.track) else { continue }
            Theme.Colors.timeline.setFill()                     // design v9: the captions lane is a plain lane
            laneRect.fill()
            Theme.Colors.trackRowLine.setFill()                 // 1 pt lane line
            CGRect(x: clip.minX, y: row.maxY - 1, width: clip.width, height: 1).fill()
            // Cull to the dirty span: a binary search finds the first caption in it, the loop ends at the last one.
            let items = track.items
            var i = max(CaptionWordLayout.firstIndex(endingAfter: geometry.time(atX: clip.minX - 2), in: items) - 1, 0)
            let wordZoom = geometry.pointsPerSecond >= CaptionWordLayout.wordLevelPointsPerSecond
            var lastSliver = -CGFloat.greatestFiniteMagnitude
            while i < items.count {
                let item = items[i]
                i += 1
                let x0 = geometry.x(for: item.range.start), x1 = geometry.x(for: item.range.end)
                if x1 < clip.minX { continue }
                if x0 > clip.maxX { break }
                let selected = captionSelection.contains(item.id)
                let rect = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)
                if x1 - x0 < CaptionWordLayout.sliverWidth {
                    // Zoomed far out a caption is narrower than its own outline: one plain sliver per pixel column.
                    let column = floor(x0)
                    if column == lastSliver, !selected { continue }
                    lastSliver = column
                    (selected ? Theme.Colors.yellow : Theme.Colors.clipCaption).setFill()
                    CGRect(x: x0, y: row.y + 1, width: max(x1 - x0, 1), height: row.height - 2).fill()
                } else if wordZoom, CaptionWordLayout.showsWords(item, geometry: geometry) {
                    CaptionWordDrawing.draw(item, rect: rect, row: row, geometry: geometry, visible: clip, isSelected: selected,
                                            selectedWord: shownWord?.caption == item.id ? shownWord?.index : nil,
                                            hiddenWord: wordEditor?.hiddenWord(in: item.id))
                } else {
                    ClipDrawing.draw(name: CaptionDrawing.preview(item), rect: rect, visible: visibleX, style: .caption,
                                     isSelected: selected, isOffline: false, flat: true)
                }
            }
        }
    }

    /// Same on/off colors as a video track's eye: label3 while visible, warning once hidden.
    static func captionEyeTint(visible: Bool) -> NSColor { visible ? Theme.Colors.label3 : Theme.Colors.warning }

    private func drawCaptionHeaders(dirty: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label2]
        for row in geometry.captionRows(for: timeline) {
            let r = CGRect(x: TimelineGeometry.toolColumnWidth, y: row.y, width: TimelineGeometry.headerWidth, height: row.height)
            guard r.maxY > TimelineGeometry.rulerHeight, r.intersects(dirty) else { continue }
            let track = timeline.captionTrack(row.track)
            drawHeaderRow(r, badge: row.label, name: track?.name ?? "Captions", nameRight: captionEyeRect(in: row).minX - TrackHeaderView.buttonGap)
            let visible = track?.isVisible ?? true
            let e = captionEyeRect(in: row), tint = Self.captionEyeTint(visible: visible)
            (visible ? SQIcon.eye : SQIcon.eyeOff).image(size: 12, color: tint)
                .draw(in: CGRect(x: e.midX - 6, y: e.midY - 6, width: 12, height: 12))
        }
        drawMixHeader(dirty: dirty)
    }

    /// Board `.th` look for the rows the timeline draws itself (captions, Mix): panel fill, badge text, name, 1 pt line.
    /// Board `.th i`: the eye is a 13 pt glyph 8 pt from the header's right edge (same place as a video track's).
    private func captionEyeRect(in row: CaptionRow) -> CGRect {
        // Same place and size as a video track's eye (design v9 `.ibtn.sm`: 24 x 24, 4 pt from the right edge).
        let s = TrackHeaderView.buttonSize(rowHeight: row.height)
        let right = TimelineGeometry.toolColumnWidth + TimelineGeometry.headerWidth - TrackHeaderView.rightPadding
        return CGRect(x: right - s, y: row.y + ((row.height - s) / 2).rounded(), width: s, height: s)
    }

    /// Design v9 `.th` for the rows the timeline draws itself (captions, Mix): panel fill, chip, name, 1 pt line.
    private func drawHeaderRow(_ r: CGRect, badge: String, name: String, nameRight: CGFloat? = nil) {
        Theme.Colors.panel.setFill()
        r.fill()
        Theme.Colors.trackRowLine.setFill()
        CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
        Theme.Colors.separator.setFill()
        CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
        let badgeAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.ns(10, .semibold), .foregroundColor: Theme.Colors.label2]
        let tail = NSMutableParagraphStyle(); tail.lineBreakMode = .byTruncatingTail
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label2, .paragraphStyle: tail]
        let chipH = min(TrackHeaderView.chipHeight, max(r.height - 4, 12))
        let chip = CGRect(x: r.minX + TrackHeaderView.leftPadding + patchColumnOffset, y: r.minY + ((r.height - chipH) / 2).rounded(),
                          width: TrackHeaderView.chipWidth, height: chipH)
        if !badge.isEmpty {
            Theme.Colors.fill.setFill()
            NSBezierPath(roundedRect: chip, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
            let bs = (badge as NSString).size(withAttributes: badgeAttrs)
            (badge as NSString).draw(at: CGPoint(x: chip.midX - bs.width / 2, y: chip.midY - bs.height / 2), withAttributes: badgeAttrs)
        }
        let nameX = chip.maxX + TrackHeaderView.buttonGap
        (name as NSString).draw(in: CGRect(x: nameX, y: r.minY + ((r.height - 14) / 2).rounded(), width: max((nameRight ?? r.maxX - 8) - nameX, 0), height: 14),
                                withAttributes: nameAttrs)
    }

    static let mixRowHeight: CGFloat = 22
    /// Board "Mix 0.0 dB" row, right after the last track (it has no model behind it yet: the master gain is 0.0 dB).
    private func drawMixHeader(dirty: CGRect) {
        let lastBottom = layoutRows().last.map { $0.bottom } ?? (TimelineGeometry.rulerHeight + geometry.captionHeight(for: timeline))
        let r = CGRect(x: TimelineGeometry.toolColumnWidth, y: lastBottom, width: TimelineGeometry.headerWidth, height: Self.mixRowHeight)
        guard r.intersects(dirty), r.minY >= TimelineGeometry.rulerHeight, r.maxY <= bounds.height - ZoomScrollBar.height else { return }
        drawHeaderRow(r, badge: "", name: "Mix")
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]
        let t = "0.0 dB" as NSString
        let sz = t.size(withAttributes: attrs)
        t.draw(at: CGPoint(x: r.maxX - Theme.Spacing.sm - sz.width, y: r.midY - sz.height / 2), withAttributes: attrs)
    }

    private func drawLanes(rows: [TrackRow], clip: CGRect, visible: CGRect) {
        let visibleX = CGRect(x: visible.minX, y: 0, width: visible.width, height: bounds.height)
        var blends: [WaveformMask.Blend] = []
        var deferred: [() -> Void] = []
        let magneticHosts = magneticHintHosts()
        // Fast Cut: attach threads of the attached clips, drawn after every row so lanes in between do not paint over them.
        let mainRow = timeline.editMode == .magnetic ? timeline.mainTrackID.flatMap { id in rows.first { $0.track == id } } : nil
        var threads: [(rect: CGRect, x: CGFloat)] = []
        let duck = duckCurveContext()                          // N8b: the live duck curve on Music tracks (nil = nothing to draw)
        let split = Self.splitRow(rows)
        for (rowIndex, row) in rows.enumerated() {
            let laneRect = CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)
            guard laneRect.intersects(clip), let track = drawTrack(row.track) else { continue }
            let firstVisible = Self.firstClipIndex(endingAfter: geometry.unsnappedTime(atX: clip.minX), in: track.clips)
            let visibleClips = track.clips[firstVisible...].lazy.filter { c in self.geometry.x(for: c.timeline.end) >= clip.minX }
                .prefix { c in self.geometry.x(for: c.timeline.start) <= clip.maxX }     // clips are sorted by start
            let soloActive = Self.audioSoloActive(in: timeline)
            (Self.isAltLane(rowIndex, in: rows) ? Theme.Colors.lane : Theme.Colors.timeline).setFill()
            if ClipDrawing.usePixelCuts, let t = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform {
                // Fast path: no lane fill under the clip bodies (opaque), only in the gaps and under their rounded ends.
                let middles = visibleClips.compactMap { c in
                    ClipDrawing.opaqueMiddle(rect: CGRect(x: self.geometry.x(for: c.timeline.start), y: row.y,
                                                          width: self.geometry.x(for: c.timeline.end) - self.geometry.x(for: c.timeline.start),
                                                          height: row.height), visible: visibleX)?.x
                }
                fillLane(laneRect, middles: Array(middles), bodyY: (row.y + 1, row.maxY - 1), t: t)
            } else {
                laneRect.fill()
            }
            if let mainRow, row.track == mainRow.track {
                // Fast Cut: spacers (holes of the main track) are hatched, so a hole reads as a deliberate spacer.
                // Read from the drawn track (live drag preview), hatched only inside the dirty rect.
                for r in ClipDrawing.spacers(on: track) {
                    let x0 = geometry.x(for: r.start), x1 = geometry.x(for: r.end)
                    guard x1 >= clip.minX, x0 <= clip.maxX else { continue }
                    ClipDrawing.drawSpacer(rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), dirty: clip)
                }
            }
            // Design v9: 1 pt lane line, 2 pt strong line under the last video row (`.lane.vsplit`).
            let lineHeight: CGFloat = rowIndex == split ? 2 : 1
            (rowIndex == split ? Theme.Colors.trackHeaderLine : Theme.Colors.trackRowLine).setFill()
            CGRect(x: clip.minX, y: row.maxY - lineHeight, width: clip.width, height: lineHeight).fill()
            // FB-Q: the row's waveforms go into one coverage mask, blended once after the clip bodies; what lies over a
            // waveform (volume line, key lane, disabled fade) is drawn in a second pass after it.
            let cg = NSGraphicsContext.current?.cgContext
            var mask: WaveformMask?
            if track.kind == .audio, waveforms != nil, let cg {
                let band = ClipDrawing.waveformRect(in: CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)).intersection(clip)
                if waveformMasks.count <= blends.count { waveformMasks.append(WaveformMask()) }
                let m = waveformMasks[blends.count]                 // one per row whose blend is still to run
                if !band.isNull, m.begin(band: band, ctm: cg.ctm, color: WaveformTint.color(for: WaveformTint.role(of: track, clips: track.clips))) { mask = m }
            }
            func overlays(_ c: Clip, _ x0: CGFloat, _ x1: CGFloat) {
                if ClipDrawing.isSimple(width: x1 - x0) { return }
                if track.kind == .audio, waveforms != nil, let cg {
                    waveformTiles.drawClipping(clip: c, rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                               visible: CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height), in: cg)
                }
                if track.kind == .audio, VolumeLine.isAvailable(rowHeight: row.height) {
                    ClipDrawing.drawVolumeLine(clip: c, rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                               visible: CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height),
                                               selected: selection.contains(c.id), hiddenHandles: hiddenFadeHandles(of: c),
                                               selectedKeys: selectedLineKeys)
                }
                if track.kind == .audio, let duck, duck.clips.contains(c.id) {
                    drawDuckCurve(clipRect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), visible: visibleX,
                                  ranges: duck.ranges, ducking: duck.ducking)
                }
                if keyLaneSection != nil {
                    Self.keyLaneDrawer?(self, c, CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), visibleX, row.height)
                }
                if let fade = Self.clipFade(clipEnabled: c.isEnabled, track: track, selected: selection.contains(c.id), audioSoloActive: soloActive) {
                    // Disabled clip or a track that does not contribute (hidden video, muted audio): the clip fades into the lane.
                    Theme.Colors.lane.withAlphaComponent(fade).setFill()
                    CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height).intersection(visibleX).fill()
                }
            }
            for c in visibleClips {
                let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
                // An Angles piece draws like a media clip of the angle it plays (thumbnails, waveform).
                let shown = c.sequence.flatMap { anglesSequence?($0) }.flatMap { c.angleProxy(inner: $0) } ?? c
                if ClipDrawing.isSimple(width: x1 - x0) {
                    ClipDrawing.drawSimple(rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                           style: .label(labelResolver.label(for: c)), isSelected: selection.contains(c.id),
                                           isOffline: offlineMedia.contains(c.media))
                    continue
                }
                // Board: media clips have a name bar (video also a thumbnail column); title, nested, adjustment clips are flat.
                let flat = shown.generator != nil || shown.sequence != nil
                let hasThumb = thumbnails != nil && !flat && track.kind == .video
                perf.time(.names) {
                    let tiles = hasThumb ? thumbnailPictures(for: shown, clipWidth: x1 - x0, x0: x0, rowHeight: row.height, visible: visibleX) : nil
                    ClipDrawing.draw(name: c.name + SpeedLabel.nameSuffix(for: c), rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                     visible: visibleX, style: .label(labelResolver.label(for: c)), isSelected: selection.contains(c.id),
                                     isOffline: offlineMedia.contains(c.media), flat: flat,
                                     thumbnailWidth: hasThumb ? ClipDrawing.thumbnailWidth : 0,
                                     thumbnail: hasThumb ? thumbnails?(shown.media) : nil,
                                     trailingReserve: (track.kind == .video && FXBadge.state(for: c) == .applied
                                         ? ClipDrawing.fxBadgeReserve(clipWidth: x1 - x0) : 0),
                                     leadingReserve: itemLanesOffered(c)
                                         ? ItemLanes.chevronReserve(clipWidth: x1 - x0, thumb: itemLaneThumbWidth(c, kind: track.kind, rowHeight: row.height)) : 0,
                                     thumbnailTiles: tiles)
                }
                if !(c.markers ?? []).isEmpty {
                    ClipMarkerFlags.draw(clip: c, frameDuration: geometry.frameDuration, geometry: geometry,
                                         rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                         visible: CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height))
                }
                if let n = syncBadges[c.id] {
                    ClipDrawing.drawSyncBadge(frames: n, rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), visible: visibleX)
                }
                // A tone clip has no file: its flat band is made from the spec (`ToneWaveform`), without a peak cache.
                let toneData = c.tone.map { ToneWaveform.data(for: $0, sourceEnd: c.source.end) }
                if track.kind == .audio, let d = toneData ?? waveforms?.data[shown.media], let cg {
                    // Cached per clip and tile: columns are computed only for new sizes.
                    perf.time(.waveform) { waveformTiles.draw(clip: shown, data: d, rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                                              visible: CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height),
                                                              cache: toneData == nil ? waveforms?.cache : nil, in: cg, mask: mask) }
                }
                if track.kind == .video, speedBandClips.contains(c.id), SpeedBand.isAvailable(rowHeight: row.height) {
                    drawSpeedBand(clip: c, rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                  visible: CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height), selected: selection.contains(c.id))
                }
                if track.kind == .video {
                    let full = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)
                    let vis = CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height)
                    // The badge sticks to the right edge of the whole content area, never of the dirty strip (a partial redraw
                    // after a scroll would stamp it mid-clip, over the name).
                    let badgeVis = visibleX
                    if OpacityLine.isVisible(clip: c, selected: selection.contains(c.id), rowHeight: row.height), !speedBandClips.contains(c.id) {
                        ClipDrawing.drawOpacityLine(clip: c, rect: full, visible: vis, selected: selection.contains(c.id),
                                                    selectedKeys: selectedLineKeys)
                    }
                    if FXBadge.state(for: c) == .applied { ClipDrawing.drawFXBadge(rect: full, visible: badgeVis) }   // board "Clip badges"
                    if itemLanesOffered(c) {
                        ItemLanes.drawChevron(rect: full, visible: badgeVis, open: itemLanes.open.contains(c.id),
                                              thumb: itemLaneThumbWidth(c, kind: track.kind, rowHeight: row.height),
                                              count: c.graphics?.layers.count ?? 0)
                    }
                    if gradeOutline.contains(c.id) { ClipDrawing.drawGradeOutline(rect: full) }
                    if let p = analysisProgress[c.id] { ClipDrawing.drawAnalysisProgress(rect: full, progress: p) }
                }
                if track.kind == .video, x1 - x0 >= 12, let spans = trackWeakSpans?(c) {
                    let fd = geometry.frameDuration, start = c.timeline.start, len = c.timeline.duration
                    let weak = TrackConfidenceStrip.weakRanges(width: x1 - x0, step: 2, source: { f in
                        let t = start + Time(Int64((Double(len.value) * f).rounded()), len.timescale)
                        let s = c.sourceTime(at: t, frameDuration: fd)
                        return Double(s.value) / Double(s.timescale)
                    }, spans: spans)
                    ClipDrawing.drawTrackConfidence(weak: weak, rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), visible: visibleX)
                }
                // Intro / outro zones: the clip's own zones, or a text clip's in / out animation lengths.
                if track.kind == .video, let z = c.zones ?? c.animationZoneLengths.map({ AnimationZones(introEnd: $0.intro, outroLength: $0.outro) }) {
                    ClipDrawing.drawZoneMarkers(z, duration: c.duration, rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), visible: visibleX)
                }
                if magneticHosts.contains(c.id) { ClipDrawing.drawMagneticHint(rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)) }
                if let mainRow, row.track != mainRow.track, let a = c.attachment {
                    threads.append((CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), geometry.x(for: c.timeline.start + a.point)))
                }
            }
            // Kept inside the row either way: a row edge off the pixel grid shares its device row with the neighbor, and what
            // an overlay (the disabled fade) leaves there must not depend on whether this pass has a waveform mask (a
            // partial re-render of the neighbor row alone has none: its band lies outside the dirty rect).
            let rowOverlays = {
                cg?.saveGState()
                cg?.clip(to: laneRect)
                for c in visibleClips { overlays(c, self.geometry.x(for: c.timeline.start), self.geometry.x(for: c.timeline.end)) }
                cg?.restoreGState()
            }
            if let mask, let cg {
                let blend = perf.time(.waveform) { mask.finish(in: cg) }
                if let blend { blends.append(blend) }
                // Drawn after every row's blend, so the order of rows still decides what is on top.
                deferred.append(rowOverlays)
            } else {
                rowOverlays()
            }
        }
        // The rows' waveform blends write disjoint bands of the bitmap: all at once (fast path) or one after another.
        perf.time(.waveform) {
            if ClipDrawing.usePixelCuts, blends.count > 1 {
                let jobs = blends
                DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0].run() }
            } else {
                for b in blends { b.run() }
            }
        }
        for d in deferred { d() }
        if let mainRow {
            for t in threads where t.x >= clip.minX - 4 && t.x <= clip.maxX + 4 {
                ClipDrawing.drawAttachThread(clipRect: t.rect, x: t.x, hostMinY: mainRow.y, hostMaxY: mainRow.maxY)
            }
        }
    }

    /// Index of the first clip whose end is after `t` (clips on a track are sorted and do not overlap), for skipping
    /// everything left of the dirty rect without touching it.
    static func firstClipIndex(endingAfter t: Time, in clips: [Clip]) -> Int {
        var lo = 0, hi = clips.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if clips[mid].timeline.end > t { hi = mid } else { lo = mid + 1 }
        }
        return max(lo - 1, 0)       // one clip of slack for rounding at the edge
    }

    /// How much of a disabled clip is covered by the lane color (0 = untouched, 1 = invisible).
    static let disabledClipFade: CGFloat = 0.68
    /// Lane-colored veil over clips of a track that does not contribute; lighter on selected clips so the outline stays readable.
    static let inactiveTrackFade: CGFloat = 0.72
    static let inactiveTrackSelectedFade: CGFloat = 0.5

    static func audioSoloActive(in timeline: Timeline) -> Bool {
        timeline.tracks.contains { $0.kind == .audio && $0.isSolo }
    }

    /// The veil alpha for a clip, or nil when it is drawn normally. One rule: a disabled clip, a hidden video track and a muted audio track all dim.
    static func clipFade(clipEnabled: Bool, track: Track, selected: Bool, audioSoloActive: Bool = false) -> CGFloat? {
        // An audio track is also silent while another audio track is soloed.
        let inactive = track.kind == .video ? !track.isVisible : (track.isMuted || (audioSoloActive && !track.isSolo))
        if inactive { return selected ? inactiveTrackSelectedFade : inactiveTrackFade }
        return clipEnabled ? nil : disabledClipFade
    }

    /// Board `.iov`: a neutral tint over every lane between In and Out with a 1 pt line at each edge.
    private func drawInOutTint(clip: CGRect) {
        guard let io = timeline.inOut, !io.isEmpty else { return }
        let x0 = geometry.x(for: io.start), x1 = geometry.x(for: io.end)
        guard x1 > clip.minX, x0 < clip.maxX else { return }
        let band = CGRect(x: x0, y: clip.minY, width: x1 - x0, height: clip.height).intersection(clip)
        Theme.TimelineSkin.inOutBand.setFill()
        band.fill()
        Theme.TimelineSkin.inOutBandEdge.setFill()
        if x0 >= clip.minX { CGRect(x: x0, y: clip.minY, width: 1, height: clip.height).fill() }
        if x1 - 1 <= clip.maxX { CGRect(x: x1 - 1, y: clip.minY, width: 1, height: clip.height).fill() }
    }

    private func drawPlayheadLine(clip: CGRect) {
        let x = geometry.x(for: playhead)
        guard x >= clip.minX - 2, x <= clip.maxX + 2 else { return }
        Theme.Colors.playhead.setFill()                 // design v9 `.playhead`: 2 pt line
        Theme.PlayheadSkin.lineFrame(centerX: x, y: clip.minY, height: clip.height).fill()
    }

    /// Option-drag on a cut: ghost of the old audio edge on the audio rows and the J / L offset label (SplitRoll.swift).
    private func drawSplitRollGhost() {
        guard let ghost = interaction.splitRollGhost else { return }
        let rows = layoutRows().filter { timeline.track($0.track)?.kind == .audio }
        guard !rows.isEmpty else { return }
        let x = geometry.x(for: ghost.cut).rounded()
        Theme.Colors.label2.setFill()
        for row in rows { CGRect(x: x - 1, y: row.y + 1, width: 2, height: row.height - 2).fill() }
        let text = ghost.label(frameDuration: timeline.frameDuration) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.bodyStrong,
                                                    .foregroundColor: Theme.Colors.onClip]
        let size = text.size(withAttributes: attrs)
        let nx = geometry.x(for: ghost.cut + ghost.offset)
        let box = CGRect(x: nx + 6, y: rows[0].y + 4, width: size.width + 10, height: size.height + 4)
        Theme.OnPicture.hudFill.setFill()
        NSBezierPath(roundedRect: box, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        text.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
    }

    /// Fast Cut live reorder preview: the dragged main-track clip floating under the pointer, outlined on V1.
    private func drawReorderGhost() {
        guard let ghost = interaction.reorderGhost, let row = layoutRows().first(where: { $0.track == ghost.track }) else { return }
        let x0 = geometry.x(for: ghost.range.start), x1 = geometry.x(for: ghost.range.end)
        let r = CGRect(x: x0, y: row.y + 1, width: max(x1 - x0, 2), height: row.height - 2)
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        Theme.OnPicture.hudFill.setFill()
        path.fill()
        Theme.Colors.snapLine.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.bodyStrong, .foregroundColor: Theme.Colors.onClip]
        (ghost.name as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + 4), withAttributes: attrs)
    }

    /// Marquee rectangle and the snap line of the gesture in flight.
    private func drawGestureOverlay(clip: CGRect) {
        Theme.OnPicture.stroke.setFill()
        for g in razorGuideRects where g.intersects(clip) { g.fill() }
        if let t = interaction.snapTime ?? scrubSnapTime {
            let x = geometry.x(for: t).rounded()
            Theme.Colors.snapLine.setFill()
            CGRect(x: x - 0.5, y: clip.minY, width: 1, height: clip.height).fill()
        }
        drawSplitRollGhost()
        drawReorderGhost()
        let rows = interaction.gapSelection != nil || interaction.edgeSelection != nil ? layoutRows() : []
        if let g = interaction.gapSelection, let row = rows.first(where: { $0.track == g.track }) {
            let r = CGRect(x: geometry.x(for: g.range.start), y: row.y + 1, width: geometry.x(for: g.range.end) - geometry.x(for: g.range.start),
                           height: row.height - 2)
            // Selected gap: the same outline language as clips and transitions (no accent fill).
            Theme.Selection.outline.setStroke()
            let outline = NSBezierPath(rect: r.insetBy(dx: Theme.Selection.outlineWidth / 2, dy: Theme.Selection.outlineWidth / 2))
            outline.lineWidth = Theme.Selection.outlineWidth
            outline.stroke()
        }
        if let e = interaction.edgeSelection {
            (e.ripple ? Theme.Colors.warning : Theme.Colors.accent).setFill()
            for ref in e.edges {
                guard let t = EdgeEdits.time(of: ref, in: timeline),
                      let row = rows.first(where: { r in timeline.track(r.track)?.clips.contains { $0.id == ref.clip } == true }) else { continue }
                let x = geometry.x(for: t).rounded()
                let bar = ref.edge == .head ? CGRect(x: x, y: row.y + 1, width: 3, height: row.height - 2)
                                            : CGRect(x: x - 3, y: row.y + 1, width: 3, height: row.height - 2)
                bar.fill()
            }
        }
        if let z = zoomDrag, hypot(z.current.x - z.start.x, z.current.y - z.start.y) >= TimelineInteraction.dragThreshold {
            let m = CGRect(x: min(z.start.x, z.current.x), y: min(z.start.y, z.current.y),
                           width: abs(z.current.x - z.start.x), height: abs(z.current.y - z.start.y))
            Theme.Colors.accentTint.setFill()
            m.fill()
            Theme.Colors.accent.setStroke()
            NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        if let m = interaction.marquee {
            Theme.Colors.accentTint.setFill()
            m.fill()
            Theme.Colors.accent.setStroke()
            NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    /// Dashed ghost tracks under the last row while a drop is in flight: "V+" (new video track) and "A+" (new audio track).
    private func drawGhostTracks(_ rows: [TimelineGeometry.GhostRow], clip: CGRect) {
        for gr in rows {
            let hot = dropPreview.ghostKind == gr.kind
            let r = CGRect(x: TimelineGeometry.toolColumnWidth + 2, y: gr.y + 1, width: max(clip.maxX - TimelineGeometry.toolColumnWidth - 4, 0), height: gr.height - 2)
            (hot ? Theme.Colors.accentTint : Theme.Colors.fill2).setFill()
            r.fill()
            (hot ? Theme.Colors.accent : Theme.Colors.label3).setStroke()
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
            let title = (gr.kind == .video ? "Drop here to add a video track" : "Drop here to add an audio track") as NSString
            title.draw(at: CGPoint(x: Self.ghostLabelX, y: r.midY - 6), withAttributes: [
                .font: Theme.Typography.caption, .foregroundColor: hot ? Theme.Colors.accent : Theme.Colors.label3])
        }
    }

    /// Spare room under the last track: two faint strips say where a drop adds a new video / audio track, without making
    /// any track taller. Only drawn when both fit. FB-Q: plain tinted strips with a sentence instead of dashed outlines
    /// (the maintainer read the four dotted lines as unexplained clutter).
    static func idleGhostTitle(_ kind: TrackKind) -> String {
        kind == .video ? "Drop clips here for a new video track" : "Drop clips here for a new audio track"
    }

    /// Ghost strip labels start in the track area: these strips are drawn under the content clip, so a label in the header
    /// column (where it used to start) was cut away and only the dashed outline showed.
    static let ghostLabelX = TimelineGeometry.contentOriginX + 8

    /// The ghost strips drawn while no drop is running: both, and only when they fit above the zoom bar.
    func visibleIdleGhostRows() -> [TimelineGeometry.GhostRow] {
        []          // board: no idle ghost strips; the drop ghost appears only during a drag
    }

    /// Kind of the idle ghost strip under `p` (view coordinates), nil elsewhere. A click there adds a track.
    func idleGhostKind(at p: CGPoint) -> TrackKind? {
        guard p.x >= TimelineGeometry.toolColumnWidth + 2 else { return nil }
        return visibleIdleGhostRows().first { p.y >= $0.y && p.y < $0.maxY }?.kind
    }

    private func drawIdleGhostTracks(clip: CGRect) {
        for gr in visibleIdleGhostRows() {
            let r = CGRect(x: TimelineGeometry.toolColumnWidth + 2, y: gr.y + 2, width: max(clip.maxX - TimelineGeometry.toolColumnWidth - 4, 0), height: gr.height - 4)
            Theme.Colors.fill2.setFill()
            NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
            (Self.idleGhostTitle(gr.kind) as NSString).draw(at: CGPoint(x: Self.ghostLabelX, y: r.midY - 6), withAttributes: [
                .font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3])
        }
    }

    /// Drop ghost (video + linked audio at the snapped position), the insert arrow and the effect target outline.
    private func drawDropOverlay(clip: CGRect) {
        let rows = layoutRows()
        let ghostRows = dropPreview.canCreateTracks ? geometry.ghostRows(for: timeline) : []
        if dropPreview.isActive { drawGhostTracks(ghostRows, clip: clip) } else { drawIdleGhostTracks(clip: clip) }
        if dropPreview.isActive, !dropPreview.ghosts.isEmpty {
            for g in dropPreview.ghosts {
                let rowY: CGFloat, rowH: CGFloat
                if g.onGhostRow, let gr = ghostRows.first(where: { $0.kind == g.kind }) {
                    rowY = gr.y; rowH = gr.height
                } else if let row = rows.first(where: { $0.track == g.track }) {
                    rowY = row.y; rowH = row.height
                } else if let n = g.newTrackOrdinal {
                    // Audio track the drop creates: drawn below the last audio row.
                    let audio = rows.filter { $0.kind == .audio }
                    let last = audio.last ?? rows.last
                    rowH = last?.height ?? 40
                    rowY = (last?.maxY ?? TimelineGeometry.rulerHeight) + CGFloat(max(n - audio.count, 0)) * rowH
                } else { continue }
                let r = CGRect(x: geometry.x(for: g.range.start), y: rowY,
                               width: max(geometry.width(of: g.range.duration), 2), height: rowH - 1)
                (g.kind == .audio ? Theme.Colors.clipAudio : Theme.Colors.clipVideo).withAlphaComponent(Theme.OnPicture.clipGhostAlpha).setFill()
                NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
                Theme.Colors.accent.setStroke()
                let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
                outline.lineWidth = 1
                outline.setLineDash([4, 3], count: 2, phase: 0)
                outline.stroke()
            }
            if let t = dropPreview.snapTime {
                Theme.Colors.snapLine.setFill()
                CGRect(x: geometry.x(for: t).rounded() - 0.5, y: clip.minY, width: 1, height: clip.height).fill()
            }
            if dropPreview.insert, let first = dropPreview.ghosts.first, let row = rows.first(where: { $0.track == first.track }) {
                // Premiere's ripple arrow: a triangle at the insert point pushing later clips right.
                let x = geometry.x(for: dropPreview.start)
                let cy = row.y + row.height / 2
                let arrow = NSBezierPath()
                arrow.move(to: CGPoint(x: x, y: cy - 7))
                arrow.line(to: CGPoint(x: x + 9, y: cy))
                arrow.line(to: CGPoint(x: x, y: cy + 7))
                arrow.close()
                Theme.Colors.accent.setFill()
                arrow.fill()
            }
        }
        if let id = effectDropTarget,
           let (row, c) = rows.compactMap({ r in timeline.track(r.track)?.clips.first { $0.id == id }.map { (r, $0) } }).first {
            let r = CGRect(x: geometry.x(for: c.timeline.start), y: row.y,
                           width: geometry.width(of: c.timeline.duration), height: row.height - 1)
            Theme.Colors.accentTint.setFill()
            r.fill()
            Theme.Colors.accent.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
    }
}

/// Display-link target that forwards to a closure (the closure holds the view weakly).
@MainActor
final class DisplayLinkProxy: NSObject {
    private let action: (CADisplayLink) -> Void
    init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
    @objc func fire(_ link: CADisplayLink) {
        action(link)
    }
}


/// Opaque panel-color block left of the zoom bar so scrolled track headers never show through the bottom strip.
final class TimelineFooterFill: NSView {
    nonisolated override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Theme.Colors.timeline.setFill(); bounds.fill() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
