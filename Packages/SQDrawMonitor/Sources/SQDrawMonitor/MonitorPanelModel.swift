import Foundation
import Observation
import SQCore
import SQDrawKit
import SQEditorSession
import SQMedia
import SQPlayback
import SQUIKit

@MainActor @Observable
public final class MonitorPanelModel {
    public let mode: MonitorMode
    public var currentTime: Time = .zero
    public var duration: Time = .zero
    public var markIn: Time?
    public var markOut: Time?
    public var isPlaying = false
    /// Program monitor: false shows the "no sequence open" state (Create a sequence or drop a clip here, New Sequence...).
    public var hasSequence = true
    /// Program monitor: the open sequence has no clip and no caption (a fresh project). Shows Pip and a one-line hint.
    public var timelineIsEmpty = false
    /// What the Program monitor's empty layer shows: nothing, the no-sequence state, or the empty-timeline state.
    public var programEmptyState: ProgramEmptyKind { !hasSequence ? .noSequence : (timelineIsEmpty ? .emptyTimeline : .none) }
    @ObservationIgnored public var onNewSequence: (() -> Void)?
    public private(set) var zoom: MonitorZoom = .fit
    public private(set) var quality: MonitorQuality = .full
    public var frameDuration: Time
    public var dropFrame = false
    /// Loop toggle (wrench menu) and Safe Margins overlay (Program monitor).
    public var isLooping = false
    /// The one stored Safe Margins value (monitor menu and View > Safe Margins). Program monitor only; remembered
    /// between launches under `safeMarginsKey`, which snap targets read through `storedSafeMargins`.
    public var safeMargins = false {
        didSet {
            guard mode == .program, safeMargins != oldValue else { return }
            UserDefaults.standard.set(safeMargins, forKey: Self.safeMarginsKey)
        }
    }
    public static let safeMarginsKey = "sq.showSafeAreas"
    public static var storedSafeMargins: Bool { UserDefaults.standard.bool(forKey: safeMarginsKey) }
    /// Debug HUD line (scrub latency); nil = hidden.
    public var latencyText: String?
    /// Program monitor: the dropped-frame dot (quiet, amber for 2 s after a drop while playing). Off by Preferences.
    public var dropIndicatorEnabled = true
    public private(set) var dropAmber = false
    public private(set) var dropTooltip = DropIndicator().tooltip
    /// Pill text next to the dot: drop count of the last run, "Realtime not achieved" once it passed the threshold.
    public private(set) var dropBadgeText: String?
    public private(set) var dropRealtimeNotAchieved = false
    /// Playback quality Auto: the quality the governor currently resolved to (`quality` itself stays `.auto`).
    public private(set) var effectiveQuality: MonitorQuality = .full
    @ObservationIgnored private var governor = AutoQualityGovernor()
    /// Picture size of the shown sequence (resolution badge) and its toggle (off by default, remembered app-wide).
    public var pictureSize: (width: Int, height: Int)?
    public private(set) var showsResolutionBadge: Bool = UserDefaults.standard.bool(forKey: "sq.monitor.resolutionBadge")
    public func setShowsResolutionBadge(_ on: Bool) {
        showsResolutionBadge = on; UserDefaults.standard.set(on, forKey: "sq.monitor.resolutionBadge")
    }
    public var resolutionBadgeText: String? {
        guard showsResolutionBadge, let s = pictureSize else { return nil }
        return "\(s.width) × \(s.height)"
    }
    /// Program monitor transparency checkerboard behind the picture (remembered app-wide).
    public private(set) var showsTransparencyGrid: Bool = UserDefaults.standard.bool(forKey: "sq.monitor.transparencyGrid")
    @ObservationIgnored public var onTransparencyGridChange: ((Bool) -> Void)?
    public func setShowsTransparencyGrid(_ on: Bool) {
        showsTransparencyGrid = on; UserDefaults.standard.set(on, forKey: "sq.monitor.transparencyGrid")
        onTransparencyGridChange?(on)
    }
    /// Program monitor rulers (percent of the picture); remembered between launches (per Mac). The guides pulled from
    /// them are session-only.
    public var showsRulers = false {
        didSet { if mode == .program, showsRulers != oldValue { Self.defaults.set(showsRulers, forKey: Self.rulersKey) } }
    }
    /// Program monitor: hides every guide layer (margins, platform zone, rulers, guides, aspect frame) without changing
    /// their settings; remembered between launches. Entry point for a key: `toggleOverlays()`.
    public var overlaysHidden = false {
        didSet { if mode == .program, overlaysHidden != oldValue { Self.defaults.set(overlaysHidden, forKey: Self.overlaysHiddenKey) } }
    }
    public static let rulersKey = "sq.monitor.rulers"
    public static let overlaysHiddenKey = "sq.monitor.overlaysHidden"
    public static let aspectFrameKey = "sq.monitor.aspectFrame"
    public static let safeMarginActionKey = "sq.monitor.safeMarginAction"
    public static let safeMarginTitleKey = "sq.monitor.safeMarginTitle"
    private static var defaults: UserDefaults { .standard }
    public func toggleOverlays() { overlaysHidden.toggle() }
    /// How the monitors show Rec.709 (Mac 1.96, Web 2.2, Broadcast 2.4): a preview of the display, export is unchanged.
    /// Shared by Source and Program (one presenter state); session-only.
    /// Stored as the raw value: `ViewGamma` lives in SQRender (Mac), which reads and sets it through `viewGamma` /
    /// `setViewGamma` (SQMonitorUI). Nil = the presenter's current value.
    public var viewGammaID: String?
    /// Which display the monitors preview for (SDR, P3, HDR 1000 nit, not tone-mapped); a view only, export is unchanged.
    /// Raw value of SQRender's `DisplayView` (Mac `displayView` / `setDisplayView`); nil = the presenter's current value.
    public var displayViewID: String?
    public var guides = MonitorGuides()
    /// Program monitor: aspect frame (9:16, 4:5, 1:1, 16:9) and the sizes of the safe-margin rectangles; remembered
    /// between launches (per Mac).
    public var aspectFrame: AspectFrame = .off {
        didSet { if mode == .program, aspectFrame != oldValue { Self.defaults.set(aspectFrame.rawValue, forKey: Self.aspectFrameKey) } }
    }
    public var safeMarginSizes = SafeMarginSizes.default {
        didSet {
            guard mode == .program, safeMarginSizes != oldValue else { return }
            Self.defaults.set(safeMarginSizes.action, forKey: Self.safeMarginActionKey)
            Self.defaults.set(safeMarginSizes.title, forKey: Self.safeMarginTitleKey)
        }
    }
    /// Preview speed of Play (0.5x to 10x). Preview only; the host plays the engine at `previewRate.rate`.
    public private(set) var previewRate = PreviewRate.normal
    @ObservationIgnored public var onPreviewRateChange: ((PreviewRate) -> Void)?
    public func setPreviewRate(_ r: PreviewRate) {
        guard r != previewRate else { return }
        previewRate = r
        onPreviewRateChange?(r)
    }
    /// Program monitor: enter the full-screen presentation (App plumbing).
    @ObservationIgnored public var onFullScreen: (() -> Void)?
    /// "Scopes" row of the Program "..." menu: the host shows its Scopes panel (nil hides the row).
    @ObservationIgnored public var onShowScopes: (() -> Void)?
    /// File name of the offline media under the playhead; non-nil shows the "Media offline" card over the picture.
    public var offlineFileName: String?
    public var offlineCardTitle: String { "Media offline" }
    public var offlineCardDetail: String? { offlineFileName.map { "\($0) was moved or renamed" } }
    @ObservationIgnored private var drops = DropIndicator()
    /// Source monitor: picture, or the waveform of audio-only media (MON-36).
    public var viewerMode: SourceViewerMode = .picture
    /// Source monitor: every angle of the Angles clip at the playhead (multi-angle view); nil = the normal viewer.
    public var angleTiles: [AngleTile]?
    /// A click on angle tile `i` (0-based): the host switches the piece under the playhead to that angle.
    @ObservationIgnored public var onPickAngle: ((Int) -> Void)?
    public var sourceWaveform: WaveformData?

    /// Source monitor: the clips opened earlier (title popup, most recent first), the current one, and its markers (M).
    public struct SourceItem: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }
    public var sourceItems: [SourceItem] = []
    public var sourceCurrent: UUID?
    public var markerTimes: [Time] = []
    @ObservationIgnored public var onPickSource: ((UUID) -> Void)?
    /// Program monitor (W5.1): the format switcher. `formatItems` are the active sequence's variants; `formatBaseName`
    /// names its own format (first item); `formatCurrent` = the variant shown (nil = the sequence's own format).
    public struct FormatItem: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }
    public var formatBaseName = ""
    /// Name of the active sequence: the format popup's title while the sequence's own format is shown (board "Main").
    public var sequenceName = ""
    /// The open sequences (title popup of the Program monitor, most recent tab last) and the shown one.
    public struct SequenceItem: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }
    public var sequenceItems: [SequenceItem] = []
    public var sequenceCurrent: UUID?
    @ObservationIgnored public var onPickSequence: ((UUID) -> Void)?
    public var formatItems: [FormatItem] = []
    public var formatCurrent: UUID?
    @ObservationIgnored public var onPickFormat: ((UUID?) -> Void)?
    /// "Add Format" submenu pick: one of `SequenceConform.aspectPresets`.
    @ObservationIgnored public var onAddFormat: ((SequenceConform.AspectPreset) -> Void)?
    @ObservationIgnored public var onRemoveFormat: ((UUID) -> Void)?
    @ObservationIgnored public var onCloseSource: (() -> Void)?
    @ObservationIgnored public var onCloseAllSources: (() -> Void)?
    /// Project items dropped on the Source monitor (the first loads, the rest join the history).
    @ObservationIgnored public var onDropMedia: (([UUID]) -> Void)?
    /// Project items dropped on the Program monitor: the half under the pointer picks Insert or Overwrite.
    /// Without it a Program drop uses `onDropMedia`.
    @ObservationIgnored public var onDropMediaZone: (([UUID], MonitorDropZone) -> Void)?
    /// Finder files dropped on the Source monitor (MON-33): the host imports them, then opens the first.
    @ObservationIgnored public var onDropFiles: (([URL]) -> Void)?

    @ObservationIgnored public var onSeek: ((Time) -> Void)?
    @ObservationIgnored public var onAction: ((MonitorAction) -> Void)?
    @ObservationIgnored public var onZoomChange: ((MonitorZoom) -> Void)?
    @ObservationIgnored public var onQualityChange: ((MonitorQuality) -> Void)?
    /// Dragging the timecode scrubs; hosts that need to stop playback or play scrub audio use these, else `onSeek`.
    @ObservationIgnored public var onScrubBegan: (() -> Void)?
    @ObservationIgnored public var onScrub: ((Time) -> Void)?
    @ObservationIgnored public var onScrubEnded: (() -> Void)?
    /// Source Monitor drag: the pasteboard item for dragging the picture (`.both`) or only its video / audio.
    /// The Mac returns an `NSPasteboardItem`; other platforms their own drag item.
    @ObservationIgnored public var dragItem: ((SourceStreams) -> AnyObject?)?
    @ObservationIgnored public var onDragEnded: (() -> Void)?
    /// A mark grip on the scrub strip was dropped: `.markIn` carries the new In, `.markOut` the new stored Out (one frame
    /// past the Out frame). Called once per drag; while dragging only `markIn` / `markOut` of the model preview it.
    @ObservationIgnored public var onMarkEdit: ((MonitorScrubMath.Hit, Time) -> Void)?
    /// Program monitor on the Color page: showing a clip's whole source file (own time axis). Locks the marks, which are
    /// then the clip's In/Out in the file.
    public var sourceFileView = false
    /// The scrub bar sits under every picture (v9 `.mscr`): Source, Program and the source-file view.
    public var showsScrubStrip: Bool { true }
    public var marksEditable: Bool { onMarkEdit != nil && !sourceFileView }
    /// A moved or newly dragged range was dropped: stored In, stored Out (one frame past the Out frame) and which
    /// gesture it was (a new range sets both marks, a moved band keeps an In-only or Out-only mark).
    @ObservationIgnored public var onRangeEdit: ((Time, Time, MarkedRangeDragPart) -> Void)?
    /// Fills the right-click menu of the picture area.
    @ObservationIgnored public var contextMenuBuilder: (() -> [SQMenuItem])?

    /// Polled by the host (a few times a second) with the engine's running drop total.
    public func updateDrops(dropped: Int, isPlaying: Bool, now: Double) {
        drops.update(dropped: dropped, isPlaying: isPlaying, now: now)
        let amber = drops.isAmber(now: now), tip = drops.tooltip
        if amber != dropAmber { dropAmber = amber }
        if tip != dropTooltip { dropTooltip = tip }
        let text = drops.badgeText, rt = drops.realtimeNotAchieved
        if text != dropBadgeText { dropBadgeText = text }
        if rt != dropRealtimeNotAchieved { dropRealtimeNotAchieved = rt }
        if quality == .auto {
            governor.update(dropped: dropped, isPlaying: isPlaying)
            if governor.current != effectiveQuality {
                effectiveQuality = governor.current
                onQualityChange?(effectiveQuality)
            }
        }
    }

    public init(frameDuration: Time, mode: MonitorMode = .program) {
        self.frameDuration = frameDuration; self.mode = mode
        if mode == .program {
            safeMargins = Self.storedSafeMargins
            let d = Self.defaults
            showsRulers = d.bool(forKey: Self.rulersKey)
            overlaysHidden = d.bool(forKey: Self.overlaysHiddenKey)
            aspectFrame = d.string(forKey: Self.aspectFrameKey).flatMap(AspectFrame.init(rawValue:)) ?? .off
            if d.object(forKey: Self.safeMarginActionKey) != nil {
                safeMarginSizes = SafeMarginSizes(action: d.integer(forKey: Self.safeMarginActionKey),
                                                  title: d.integer(forKey: Self.safeMarginTitleKey))
            }
        }
    }

    /// Sequence Settings: the timecode of time zero and the frame-count display (Program monitor; Source stays at 0).
    public var timecodeOrigin: Time = .zero
    public var timecodeFramesOnly = false
    public var timecode: Timecode {
        var tc = Timecode(frameDuration: frameDuration, dropFrame: dropFrame)
        tc.origin = timecodeOrigin; tc.framesOnly = timecodeFramesOnly
        return tc
    }
    public var timecodeText: String { timecode.position(currentTime) }
    public var durationText: String { timecode.format(duration) }

    /// Length between In and Out (Out defaults to the end, In to the start); nil when neither is set.
    public var inOutDurationText: String? {
        guard markIn != nil || markOut != nil else { return nil }
        let len = (markOut ?? duration) - (markIn ?? .zero)
        return timecode.format(len < .zero ? .zero : len)
    }

    public var availableActions: [MonitorAction] {
        MonitorAction.allCases.filter { a in
            switch a {
            case .insert, .overwrite, .replace, .fitToFill: mode == .source
            case .lift, .extract, .toggleSafeMargins: mode == .program
            default: true
            }
        }
    }

    /// Zoom popup in the monitor header ("Fit", "150 %"). Playback quality has its own popup next to it (changed often).
    public var badgeText: String { zoom.title }
    /// Playback quality popup next to the zoom popup ("Full", "1/2", "1/4").
    public var qualityBadgeText: String {
        guard quality == .auto else { return quality.title }
        return effectiveQuality == .full ? "Auto" : "Auto · \(effectiveQuality.title)"
    }
    /// Edit page picture badge (board `.vbadge`): zoom and quality in one popup, "Fit · ½".
    public var pictureBadgeText: String {
        return "\(zoom.title) · \(quality.badgeSymbol ?? "Full")"
    }
    /// Rows of the picture badge: the zoom presets, then the playback quality choices.
    public func pictureBadgeMenu() -> [SQMenuItem] { zoomMenu() + [.separator] + qualityMenu() }

    /// Rows of the zoom popup (checked = current). Actions run on the model.
    public func zoomMenu() -> [SQMenuItem] {
        MonitorZoom.presets.map { z in SQMenuItem(title: z.title, isChecked: z == zoom, action: { [weak self] in self?.setZoom(z) }) }
    }

    /// Rows of the playback quality popup (checked = current). The choice is the app-wide remembered preference.
    public func qualityMenu() -> [SQMenuItem] {
        [.header("Playback quality")] + MonitorQuality.menuCases.map { q in
            SQMenuItem(title: MonitorMenus.autoTitle(q, level: effectiveQuality), isChecked: q == quality,
                       action: { [weak self] in self?.setQuality(q) })
        }
    }

    /// Time `frames` frames away from `t` (never before zero), for dragging the timecode.
    public func time(offsetFrom t: Time, frames: Int) -> Time {
        max(.zero, (t + frameDuration * Int64(frames)).snapped(to: frameDuration))
    }

    public func perform(_ action: MonitorAction) {
        guard availableActions.contains(action) else { return }
        onAction?(action)
    }

    /// Returns false (and does not seek) when the text is not a valid timecode. `+10` / `-5` move relative to the
    /// current time (frames; `+1:00` is a timecode amount), never before 0 or past the last frame (Premiere).
    @discardableResult
    public func commitTimecodeText(_ text: String) -> Bool {
        if let off = timecode.parseRelative(text) {
            let last = duration > .zero ? max(.zero, duration - frameDuration) : nil
            let target = max(.zero, currentTime + off)
            onSeek?(last.map { min(target, $0) } ?? target)
            return true
        }
        guard let t = timecode.parsePosition(text) else { return false }
        let last = duration > .zero ? max(.zero, duration - frameDuration) : nil
        onSeek?(last.map { min(max(.zero, t), $0) } ?? max(.zero, t))
        return true
    }

    /// SQ hint for text the timecode field rejected (replaces the beep); empty for blank input.
    public static func timecodeHint(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return "“\(t)” is not a timecode. Try 123, +10, -10 or 01:00:00:00."
    }

    // MARK: Mark grips (drag In / Out on the strip)

    /// Drag preview: moves the In or Out to the frame `frame` (`.playhead` is ignored). Out is stored one frame past it.
    public func previewMark(_ end: MonitorScrubMath.Hit, frame: Time) {
        switch end {
        case .markIn:
            markIn = frame
            if let o = markOut, o <= frame { markOut = nil }
        case .markOut:
            let out = frame + frameDuration
            markOut = out
            if let i = markIn, i >= out { markIn = nil }
        case .playhead: break
        }
    }

    /// Drag preview of the whole range (middle drag, or a new range dragged out on the bar): stored In and stored Out.
    public func previewRange(markIn newIn: Time, markOut newOut: Time) {
        markIn = newIn
        markOut = max(newOut, newIn + frameDuration)
    }

    /// Drop of a range gesture (`part`: a new range or the moved band): one call with the stored In and Out
    /// (`onRangeEdit`, one undo step), else the host gets both marks through `onMarkEdit` (In first, then Out).
    public func commitRange(_ part: MarkedRangeDragPart) {
        if let onRangeEdit, let i = markIn, let o = markOut { onRangeEdit(i, o, part); return }
        if let i = markIn { onMarkEdit?(.markIn, i) }
        if let o = markOut { onMarkEdit?(.markOut, o) }
    }

    /// Duration shown at the footer's right: In to Out when a range is set, else the whole length.
    public var footerDurationText: String { inOutDurationText ?? durationText }
    public var hasRange: Bool { markIn != nil || markOut != nil }

    /// Right-click menu of the scrub bar and its In/Out range: the same commands as the main menu's Mark menu.
    public func markMenu() -> [SQMenuItem] {
        let editable = !sourceFileView
        func row(_ title: String, _ a: MonitorAction, _ on: Bool) -> SQMenuItem {
            SQMenuItem(title: title, shortcut: MonitorMenus.shortcut(of: a), isEnabled: on, action: { [weak self] in self?.perform(a) })
        }
        return [row("Remove In", .clearIn, editable && markIn != nil),
                row("Remove Out", .clearOut, editable && markOut != nil),
                row("Remove In and Out", .clearInOut, editable && hasRange),
                .separator,
                row("Go to In", .goToIn, hasRange),
                row("Go to Out", .goToOut, hasRange)]
    }

    /// Drop: hands the final mark to the host.
    public func commitMark(_ end: MonitorScrubMath.Hit) {
        switch end {
        case .markIn: if let i = markIn { onMarkEdit?(.markIn, i) }
        case .markOut: if let o = markOut { onMarkEdit?(.markOut, o) }
        case .playhead: break
        }
    }

    public func setZoom(_ z: MonitorZoom) { zoom = z; onZoomChange?(z) }
    /// Shows a zoom that a gesture produced (Hand tool, pinch) without reporting it back.
    public func displayZoom(_ z: MonitorZoom) { zoom = z }
    public func setQuality(_ q: MonitorQuality) {
        quality = q
        if q == .auto {
            governor.setBase(governor.base)
            effectiveQuality = governor.current
            onQualityChange?(effectiveQuality)
        } else {
            effectiveQuality = q
            onQualityChange?(q)
        }
    }
    /// Auto's starting quality (the Mac's memory-budget pick).
    public func setAutoBase(_ q: MonitorQuality) {
        governor.setBase(q)
        if quality == .auto, governor.current != effectiveQuality { effectiveQuality = governor.current; onQualityChange?(effectiveQuality) }
    }

    /// Program monitor: the platform whose UI zone is overlaid (own popup next to Fit / Full), remembered app-wide.
    public private(set) var safeZone: SafeZoneChoice = .stored
    @ObservationIgnored public var onSafeZoneChange: ((SafeZoneChoice) -> Void)?
    public func setSafeZone(_ c: SafeZoneChoice) { safeZone = c; c.remember(); onSafeZoneChange?(c) }
    /// Light mock of the platform's own UI (action column, name, caption) over the dimmed zone; preview only, never exported.
    public private(set) var showsPlatformMock: Bool = SafeZoneChoice.storedMock
    public func setShowsPlatformMock(_ on: Bool) { showsPlatformMock = on; SafeZoneChoice.rememberMock(on); onSafeZoneChange?(safeZone) }
    public func safeZoneMenu() -> [SQMenuItem] {
        MonitorMenus.safeZoneItems(current: safeZone, set: { [weak self] c in self?.setSafeZone(c) })
            + MonitorMenus.platformMockItems(isOn: showsPlatformMock, available: safeZone.hasUIMock,
                                             set: { [weak self] on in self?.setShowsPlatformMock(on) })
    }
}

public enum ProgramEmptyKind: Equatable, Sendable { case none, noSequence, emptyTimeline }
