import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// The Timeline panel on the shared draw-list toolkit: the Mac `TimelineView` translated, not rebuilt. Models, layout
/// math, hit-testing and every tool gesture are SQTimelineUI's own (`TimelineGeometry`, `TimelineInteraction`,
/// `TrackSizing`, `InOutDrag`, `MarkerDrag`, `MarkerRange`, `PlayheadSnap`, `TransitionLayout`, `TimelineZoom`,
/// `ScrollTuning`, `TimelineAutoscroll`); only the AppKit glue changes: `draw(_:)` bodies paint through `Canvas`, NSEvent
/// handlers read `InputEvent`, callbacks become `TimelineAction`s.
///
/// Coordinates: points inside the panel, origin top-left, y down; the ruler is the top 24 pt and the track header column
/// the left 156 pt, exactly like the Mac view's bounds, so every SQTimelineUI formula applies unchanged.
public struct TimelinePanel {
    public var theme: DrawTheme
    /// What is drawn: the committed timeline, or the gesture's preview while a drag runs.
    public internal(set) var timeline: Timeline
    /// The session's timeline as last synced.
    public internal(set) var committed: Timeline
    public internal(set) var geometry: TimelineGeometry
    public internal(set) var interaction: TimelineInteraction
    public internal(set) var selection: Set<Clip.ID> = []
    public internal(set) var captionSelection: Set<CaptionItem.ID> = []
    public internal(set) var playhead: Time = .zero
    public internal(set) var selectedTransition: Transition.ID?
    public var labels = LabelResolver()
    /// Cached-render spans for the ruler's cache strip (the host fills it when it has a render cache).
    public var cachedRanges: [TimeRange] = []
    /// Beat grid level the snaps use (`TimelineView.beatSnapLevel`).
    public var beatLevel: BeatSnapLevel = .everyBeat
    /// Device-pixel frame in the window and device pixels per point.
    public internal(set) var frame = DrawRect.zero
    public internal(set) var scale: Float = 1
    /// Panel size in points.
    public internal(set) var size = CGSize.zero
    /// Seconds clock for double-click detection and autoscroll (injectable for tests).
    public var clock: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }

    /// Hold-to-temp tool (the Mac `AppController.toolHold`): a tool key held past `ToolHold.threshold` returns to the tool from
    /// before when it comes up.
    var toolHold = ToolHold()

    var fitted = false
    var gesture: Gesture?
    /// Modifiers held at mouse down (the host reports none on drag / up events).
    var downModifiers: InputModifiers = []
    /// The pointer shape at the press: a gesture keeps it until the release (TimelinePanel+Cursor.swift).
    var pressCursor: DrawCursor?
    /// The ` hold (keep attached) took part in an edit: its release does not maximize the panel.
    var keepAttachedUsed = false
    /// The keys held right now (the host's live key state): a drag reads Shift / Alt / Ctrl as they change, as the Mac
    /// drag events do. nil = the keys held at the press.
    public var liveModifiers: (() -> InputModifiers)?
    /// Modifiers for drag and release handling: live when the host reports them, else those of the press.
    var dragModifiers: InputModifiers { liveModifiers?() ?? downModifiers }
    var lastDrag: CGPoint?
    var lastAutoscroll: Double?
    var lastClick: (time: Double, point: CGPoint, count: Int)?
    var scrubSnapTime: Time?
    /// Track row under the pointer (reveals Lock and Sync Lock like the Mac header's hover).
    var hoverTrack: Track.ID?
    var hoverPoint: CGPoint?
    /// Source patching: the streams of the clip in the Source view (nil: none loaded, no patch column), set by the host.
    public var sourcePatchStreams: Set<TrackKind>?
    /// The header row a dragged patch chip is over.
    var patchDropTrack: Track.ID?
    /// A Slip drag's two-up is showing in the Program monitor (the Mac `slipTwoUpShown`).
    var slipTwoUpShown = false
    /// The running media drag over the panel (host driven, `dropHover`).
    public internal(set) var dropPreview = DropPreview()
    /// The gesture hint last reported (`onGestureHint`), so a hint goes to the status line once.
    var lastHint: String?
    /// The zoom scroll bar under the tracks (TimelinePanel+ZoomBar.swift).
    var zoomBar = ZoomScrollBarControl()
    /// Waveforms, thumbnails and the offline state of the media behind the clips (TimelinePanel+Media.swift).
    public weak var media: (any TimelineMediaSource)?
    /// What video clip thumbnails show (the Mac view starts from `ThumbnailPrefs.mode` as well).
    public var thumbnailMode: ThumbnailMode = ThumbnailPrefs.mode
    /// Remove Silences preview: the ranges the open dialog would cut, shaded red (TimelinePanel+SilencePreview.swift).
    public var silencePreview: [TimeRange] = []
    /// Volume / opacity keys selected on the clip bands (the session's `selectedLineKeys`, drawn filled).
    var selectedLineKeys: Set<UUID> = []
    /// A band drag sent a change whose undo step is still open (the Mac host's `TimelineLineGesture.emitted`).
    var lineStepOpen = false
    /// The key lanes of Effect Controls' selected section (TimelinePanel+KeyLanes.swift; nil = no lane).
    public weak var keyLanes: (any TimelineKeyLaneSource)?
    /// Clips that show the speed band instead of the opacity line (`TimelineView.setSpeedBand`).
    public var speedBandClips: Set<Clip.ID> = []
    /// The transport runs (the Mac `isPlaybackRunning`): the skimmer hides. The host keeps it current.
    public var isPlaying = false
    /// Playback follow (TimelinePanel+Follow.swift): whether the user's scroll beats the follow, and the last
    /// transport state `followPlayback` saw.
    var follow = TimelineFollow()
    /// Trackpad and wheel state of `TimelineView.scrollWheel / magnify` (TimelinePanel+Wheel.swift).
    var wheel = TimelineWheelState()
    var followWasPlaying = false
    /// Color page: the clips the Color panel grades get a yellow outline (`gradeOutline`).
    public var gradeOutline: Set<Clip.ID> = []
    /// Background analysis share done per clip (Stabilizer), drawn as a strip along the clip's bottom.
    public var analysisProgress: [Clip.ID: Double] = [:]
    /// Weak tracking stretches of a clip's Magic mask (MASK-UX 5.4); nil = none.
    public var trackWeakSpans: ((Clip) -> [MagicTrackHealth.Span]?)?
    /// The live duck curve on Music tracks (N8b); nil = not drawn.
    public var duckCurve: DuckCurveSource?
    /// Where the user's track heights and split are kept per sequence (nil = not kept, e.g. in tests).
    public var heightStore: TrackHeightStore?
    /// The Fast Cut skimmer's frame (nil: hidden).
    public internal(set) var skimmerTime: Time?
    /// The bar of the keystone applied last (TimelinePanel+Keystones.swift; `setKeystoneBar`), and its clip as the bar
    /// left it: any other change to that clip hides the bar.
    public internal(set) var keystoneBar: KeystoneBar?
    var keystoneBarClip: Clip?
    /// Where a dragged keystone would land (`keystoneHover`).
    public internal(set) var keystoneGhost: KeystoneBar?
    /// Open item lanes, their selection and drags (TimelinePanel+ItemLanes.swift).
    var itemLanes = ItemLaneState()
    /// The inline word field on the caption track (`TimelinePanel+CaptionWords`).
    var wordField: CaptionWordField?
    /// The caption find and replace card (`TimelinePanel+CaptionSearch`; nil = closed).
    public internal(set) var captionSearch: CaptionSearchControl?

    /// One gesture in flight; the Mac view keeps one optional per kind, only ever one of them set.
    enum Gesture {
        case resize(zone: TrackSizing.Zone, startY: CGFloat, rows: [TrackRow], startFraction: CGFloat)
        case zoom(start: CGPoint, current: CGPoint, zoomOut: Bool)
        case inOut(part: InOutDrag.Part, downX: CGFloat, downTime: Time, moved: Bool, original: TimeRange)
        case markerDuration(id: Marker.ID, start: Time, original: Time, moved: Bool)
        case marker(id: Marker.ID, downX: CGFloat, moved: Bool, original: Time)
        case scrub
        case transition(hit: TransitionHit, original: ResolvedTransition, startX: CGFloat, began: Bool, lastFrames: Int64)
        case header(Track.ID, TrackToggle)
        case clips
        case zoomBar(ZoomBarSnapshot)
        case clipMarker(hit: ClipMarkerFlags.Hit, downX: CGFloat, moved: Bool)
        case band(BandDrag)
        case speed(SpeedBandDrag)
        case attach(clip: Clip.ID, original: Timeline, time: Time)
        case keystone(KeystoneEdgeDrag)
        /// A press in the item lanes (bar move or trim, lane name drag; the details are in `itemLanes`).
        /// A transition layer's cut marker or end dragged.
        case transitionLayer(LayerDrag)
        /// A press on a source patch chip; `dragging` once it moved 3 pt.
        case patch(kind: TrackKind, down: CGPoint, dragging: Bool)
        case itemLane
    }

    public init(theme: DrawTheme = DrawTheme()) {
        self.theme = theme
        let empty = Timeline(name: "", frameDuration: Time(1, 25))
        timeline = empty
        committed = empty
        geometry = TimelineGeometry(frameDuration: empty.frameDuration, pointsPerSecond: 40)
        interaction = TimelineInteraction(timeline: empty, geometry: geometry)
    }

    // MARK: Tool state (the Mac view's `toolState`, set by the tool strip and the tool keys)

    public var toolState: ToolState {
        get { interaction.toolState }
        set { interaction.toolState = newValue }
    }

    /// True while a press is held (the host keeps routing drags here even outside the frame).
    public var isDragging: Bool { gesture != nil }

    public func contains(x: Float, y: Float) -> Bool { frame.contains(x, y) }

    /// Host pixels of a time on the content area (scripted input, the edit test).
    public func pixelX(for t: Time) -> Float { frame.x + Float(geometry.x(for: t)) * scale }

    /// Host pixels of the middle of a track's lower half (the clip body, below the name band's trim handles).
    public func pixelY(bodyOf track: Track.ID) -> Float? {
        rows.first { $0.track == track }.map { frame.y + Float($0.y + $0.height * 0.7) * scale }
    }

    // MARK: Session sync

    /// Takes the session's state (the Mac `EditorPanels` pushes the same into the view). Skipped while a gesture runs,
    /// so the drag's preview is not replaced under the pointer; a new sequence starts with a fresh view.
    public mutating func sync(timeline t: Timeline, selection sel: Set<Clip.ID>, captions: Set<CaptionItem.ID> = [],
                              playhead ph: Time, selectedTransition tr: Transition.ID?, labels l: LabelResolver,
                              lineKeys: Set<UUID> = []) {
        labels = l
        playhead = ph
        selectedLineKeys = lineKeys
        guard gesture == nil else { return }
        if t.id != committed.id {
            // The height preset and Fit All Tracks are app-wide (`loadHeightPrefs`), not per sequence: a fresh geometry
            // would fall back to `.auto` and stretch the rows past the Mix row.
            let (mode, fit) = (geometry.heightMode, geometry.fitAllTracks)
            geometry = TimelineGeometry(frameDuration: t.frameDuration, pointsPerSecond: geometry.pointsPerSecond)
            geometry.heightMode = mode
            geometry.fitAllTracks = fit
            geometry.viewportHeight = trackAreaHeight
            interaction = TimelineInteraction(timeline: t, geometry: geometry)
            interaction.toolState = toolState
            fitted = false
            if let store = heightStore {                    // `TrackHeightStore`: the sequence's own heights and split
                geometry.heightOverrides = store.load(t.id)
                geometry.splitFraction = store.loadSplit(t.id)
            }
        }
        geometry.frameDuration = t.frameDuration
        if t != committed || t != timeline {
            committed = t
            timeline = t
            interaction.reset(timeline: t)
        }
        syncKeystoneBar()
        syncItemLanes()
        wordFieldFollowsTimeline()
        captionSearch?.resync(timeline, playhead: playhead)
        if interaction.selection != sel { interaction.setSelection(sel) }
        if interaction.captionSelection != captions { interaction.setCaptionSelection(captions) }
        selection = sel
        captionSelection = captions
        selectedTransition = tr
        if size.width > 0 { fitIfNeeded(); clampScroll() }
    }

    // MARK: Layout

    /// Places the panel at `rect` (device pixels) with `scale` pixels per point.
    public mutating func layout(_ rect: DrawRect, scale s: Float) {
        frame = rect
        scale = max(s, 0.5)
        size = CGSize(width: CGFloat(rect.w / scale), height: CGFloat(rect.h / scale))
        geometry.viewportHeight = trackAreaHeight
        fitIfNeeded()
        clampScroll()
    }

    /// Height over the zoom scroll bar (`TimelineView.trackAreaHeight`).
    var trackAreaHeight: CGFloat { max(size.height - Self.zoomBarHeight, 0) }
    static let zoomBarHeight: CGFloat = ZoomScrollBarControl.height

    var rows: [TrackRow] { geometry.rows(for: timeline) }
    var contentViewportWidth: CGFloat { max(size.width - TimelineGeometry.contentOriginX, 0) }

    /// `TimelineView.contentEnd`.
    var contentEnd: Time {
        let clips = timeline.tracks.compactMap { $0.clips.last?.timeline.end }
        let captions = timeline.captionTracks.compactMap { $0.items.last?.range.end }
        return (clips + captions).max() ?? .zero
    }

    /// `TimelineView.fitScale`: the whole sequence fills the content width with a 16 pt margin on each side.
    var fitScale: Double {
        let end = contentEnd
        guard end > .zero else { return 1 }
        let seconds = Double(end.value) / Double(end.timescale)
        return max(Double(contentViewportWidth) - 2 * Double(DrawTheme.Spacing.lg), 1) / seconds
    }

    var zoomLimits: ClosedRange<Double> {
        let fd = geometry.frameDuration
        return TimelineZoom.limits(fit: fitScale, viewportWidth: Double(contentViewportWidth),
                                   frameSeconds: Double(fd.value) / Double(fd.timescale))
    }

    mutating func fitIfNeeded() {
        guard !fitted, contentViewportWidth > 0 else { return }
        fitted = true
        geometry.pointsPerSecond = fitScale
        geometry.scrollX = 0
    }

    /// `\`: the whole sequence in view.
    public mutating func zoomToFit() {
        geometry.pointsPerSecond = fitScale
        geometry.scrollX = 0
        clampScroll()
    }

    /// `TimelineView.setZoom`: keeps the time under `anchorX` (panel points) fixed; nil = the playhead when visible.
    public mutating func setZoom(pointsPerSecond pps: Double, anchorX: CGFloat? = nil) {
        let new = TimelineZoom.clamp(pps, to: zoomLimits)
        guard new != geometry.pointsPerSecond else { return }
        let anchor = anchorX ?? defaultZoomAnchor
        geometry.scrollX = CGFloat(TimelineZoom.anchoredScroll(oldScale: geometry.pointsPerSecond, newScale: new,
                                                               scrollX: Double(geometry.scrollX),
                                                               anchorX: Double(anchor - TimelineGeometry.contentOriginX)))
        geometry.pointsPerSecond = new
        clampScroll()
    }

    /// `=` / `-` (one key step).
    public mutating func zoomIn() { setZoom(pointsPerSecond: geometry.pointsPerSecond * TimelineZoom.keyStep) }
    public mutating func zoomOut() { setZoom(pointsPerSecond: geometry.pointsPerSecond / TimelineZoom.keyStep) }

    var defaultZoomAnchor: CGFloat {
        let x = geometry.x(for: playhead)
        return x >= TimelineGeometry.contentOriginX && x <= size.width ? x : TimelineGeometry.contentOriginX + contentViewportWidth / 2
    }

    func maxScrollX() -> CGFloat {
        CGFloat(TimelineZoom.maxScroll(contentWidth: Double(geometry.width(of: contentEnd)), viewportWidth: Double(contentViewportWidth)))
    }

    /// `TimelineView.maxScrollY`: vertical overflow, under one point counts as none.
    func maxScrollY() -> CGFloat {
        let content = (rows.last.map { $0.maxY + $0.laneSpace + geometry.scrollY }
                       ?? TimelineGeometry.rulerHeight + geometry.captionHeight(for: timeline))
            + (geometry.reservesGhostSpace ? 2 * TimelineGeometry.ghostRowHeight : 0)
        let over = content + Self.zoomBarHeight - size.height
        return over < 1 ? 0 : over
    }

    mutating func clampScroll() {
        if wheel.allowsOverscroll { interaction.geometry = geometry; return }    // a rubber-band pull or its spring back
        geometry.scrollX = min(max(geometry.scrollX, 0), maxScrollX())
        geometry.scrollY = min(max(geometry.scrollY, 0), maxScrollY())
        interaction.geometry = geometry
    }

    // MARK: Shared row facts (`TimelineView.splitRow` / `isAltLane`, translated as they are)

    static func splitRow(_ rows: [TrackRow]) -> Int? {
        guard let a = rows.firstIndex(where: { $0.kind == .audio }), a > 0 else { return nil }
        return a - 1
    }

    static func isAltLane(_ index: Int, in rows: [TrackRow]) -> Bool {
        let firstAudio = rows.firstIndex { $0.kind == .audio } ?? rows.count
        return index < firstAudio ? (firstAudio - 1 - index) % 2 == 1 : (index - firstAudio) % 2 == 0
    }

    /// `TimelineView.audioSoloActive`: some audio track is soloed.
    static func audioSoloActive(in t: Timeline) -> Bool { t.tracks.contains { $0.kind == .audio && $0.isSolo } }

    /// A track whose clips are veiled: hidden video, muted audio, or audio while another track is soloed.
    static func isInactive(_ track: Track, soloActive: Bool) -> Bool {
        track.kind == .video ? !track.isVisible : (track.isMuted || (soloActive && !track.isSolo))
    }
}
