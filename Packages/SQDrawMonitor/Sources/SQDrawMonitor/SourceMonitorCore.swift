import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQMedia
import SQPlayback
import SQUIKit

/// Fit Clip choice of a four-mark Source edit whose source and sequence ranges differ in length; the last choice is
/// remembered (`sq.fourPointFit`). The Mac sheet and the Windows shell form both list these rows.
public enum FourPointFitChoice: String, CaseIterable, Sendable {
    case changeSpeed, trimSourceEnd, ignoreSourceIn, ignoreSequenceIn, ignoreSequenceOut

    public var title: String {
        switch self {
        case .changeSpeed: "Change Speed (fit the source into the range)"
        case .trimSourceEnd: "Trim Source End (sequence range, source In)"
        case .ignoreSourceIn: "Ignore Source In (source Out ends the clip)"
        case .ignoreSequenceIn: "Ignore Sequence In (clip ends at Out)"
        case .ignoreSequenceOut: "Ignore Sequence Out (source length at In)"
        }
    }

    /// nil for Change Speed (the session's `fitToFill`).
    public var fit: FourPointFit? {
        switch self {
        case .changeSpeed: nil
        case .trimSourceEnd: .trimSourceEnd
        case .ignoreSourceIn: .ignoreSourceIn
        case .ignoreSequenceIn: .ignoreSequenceIn
        case .ignoreSequenceOut: .ignoreSequenceOut
        }
    }

    public static let key = "sq.fourPointFit"
    public static func saved(_ d: UserDefaults = .standard) -> FourPointFitChoice {
        d.string(forKey: key).flatMap(FourPointFitChoice.init(rawValue:)) ?? .trimSourceEnd
    }
    public static func save(_ c: FourPointFitChoice, _ d: UserDefaults = .standard) { d.set(c.rawValue, forKey: key) }
}

/// The Source monitor without its view: plays one project media item on its own engine (a one-clip sequence in the
/// media's own format) and holds the item's In/Out marks (`Project.sourceMarks`). Insert and Overwrite go through
/// `EditorSession.sourceEdit`. Only one monitor plays at a time: starting one pauses the other (`pause()`).
/// Shared by the Mac (`SourceMonitorController` adds the AppKit view, drag and sheet) and Windows (draw-list panel).
@MainActor
open class SourceMonitorCore {
    public let session: EditorSession
    public let engine: any ProgramEngine
    public let model: MonitorPanelModel

    public private(set) var mediaID: MediaRef.ID? { didSet { if oldValue != mediaID { onMediaChange?() } } }
    /// The loaded clip changed (the timeline's source patch column follows it).
    public var onMediaChange: (() -> Void)?
    private var shuttle = Shuttle()
    public private(set) var frameDuration = Time(1, 30)
    public private(set) var duration = Time.zero
    /// Picture shape the loaded source timeline was built with; a pixel aspect change alters it (re-derived in `sync`).
    private var loadedShape: [Int] = []
    public private(set) var isPlaying = false
    private var previewRate = PreviewRate.normal
    private var position = Time.zero
    /// The engine wraps a loop by itself (the Mac PlaybackEngine); otherwise `positionChanged` seeks back.
    public var engineWrapsLoops = false
    public var bounds = PlaybackBounds() {
        // The picture leads the clock while playing (display lead): it must not show frames past the range end, and
        // the engine wraps a loop itself (the frames after the wrap are picked before the clock gets there).
        didSet {
            if bounds.range != oldValue.range { engine.playRange = bounds.range }
            if bounds.loop != oldValue.loop { engine.loops = bounds.loop }
        }
    }
    /// Clips opened earlier (title popup): at most 20, most recent first.
    public private(set) var history = SourceHistory()
    /// Preroll / postroll of Play In to Out with roll and of Play Around (Preferences > Playback).
    public var preroll = PlaybackBounds.defaultPreroll
    public var postroll = PlaybackBounds.defaultPostroll
    /// Streams of the drag in flight (video-only / audio-only icons); read by the timeline's drop handler.
    public var dragStreams: SourceStreams = .both

    public var onCommand: ((EditorCommand) -> Void)?
    public var onStatus: ((String) -> Void)?
    /// Playback started here: the Program monitor must stop.
    public var onStartedPlaying: (() -> Void)?
    public var onRevealInProject: ((MediaRef.ID) -> Void)?
    /// "Show All Angles" row of the context menu (nil = no row); `anglesAvailable`: an Angles clip is under the playhead.
    public var onToggleAngles: (() -> Void)?
    public var anglesAvailable: (() -> Bool)?
    /// Peaks of an audio-only clip for the waveform view (the host asks its peak store; nil until they are built).
    public var waveformProvider: ((MediaRef.ID) -> WaveformData?)?
    /// Asks which Fit Clip rule decides a four-mark edit; the answer (nil = canceled) goes to the completion. nil = no
    /// question, the edit runs with Trim Source End.
    public var chooseFourPointFit: ((@escaping @MainActor (FourPointFitChoice?) -> Void) -> Void)?
    /// Export Frame on the platform (the Mac full-size render, the Windows engine's shown picture).
    public var onExportFrame: (() -> Void)?

    /// `model`: the host's Source model when its view is built before the core (the Mac view takes it at init).
    public init(session: EditorSession, engine: any ProgramEngine, model: MonitorPanelModel? = nil) {
        self.session = session
        self.engine = engine
        self.model = model ?? MonitorPanelModel(frameDuration: Time(1, 30), mode: .source)
        engine.onPositionChange = { [weak self] t in self?.positionChanged(t) }
        wire()
    }

    private func wire() {
        model.onSeek = { [weak self] t in self?.seek(to: t) }
        model.onScrubBegan = { [weak self] in self?.beginScrub() }
        model.onScrub = { [weak self] t in self?.scrub(to: t) }
        model.onScrubEnded = { [weak self] in self?.endScrub() }
        model.onPreviewRateChange = { [weak self] r in
            guard let self else { return }
            previewRate = r
            if isPlaying, engine.rate.isForward { play(rate: r.rate) }
        }
        model.onQualityChange = { [weak self] q in self?.engine.quality = q.decodeScale }
        #if os(macOS)
        model.onZoomChange = { [weak self] z in
            switch z {
            case .fit: self?.engine.viewerZoom = .fit
            case .percent(let p), .custom(let p): self?.engine.viewerZoom = .percent(p)
            }
        }
        #endif
        model.onAction = { [weak self] a in self?.perform(a) }
        model.onDragEnded = { [weak self] in self?.dragStreams = .both }
        model.onMarkEdit = { [weak self] end, t in
            switch end {
            case .markIn: self?.setMarks { $0.setSourceIn(t, for: $1) }
            case .markOut: self?.setMarks { $0.setSourceOut(t, for: $1) }
            case .playhead: break
            }
        }
        model.onPickSource = { [weak self] id in self?.open(id) }
        model.onCloseSource = { [weak self] in self?.closeCurrent() }
        model.onCloseAllSources = { [weak self] in self?.closeAll() }
        model.onDropMedia = { [weak self] ids in self?.open(all: ids) }
        model.contextMenuBuilder = { [weak self] in self?.contextMenuItems() ?? [] }
    }

    /// The monitor's buttons, keys and menus.
    public func perform(_ a: MonitorAction) {
        switch a {
        case .markIn: markIn()
        case .markOut: markOut()
        case .goToIn: goToIn()
        case .goToOut: goToOut()
        case .clearIn: clearIn()
        case .clearOut: clearOut()
        case .clearInOut: clearMarks()
        case .stepBack: stepFrames(-1)
        case .stepForward: stepFrames(1)
        case .playPause: playPause()
        case .addMarker: addMarker()
        case .insert: edit(.insert)
        case .overwrite: edit(.overwrite)
        case .fitToFill: edit(.overwrite, fitToFill: true)
        case .replace: replaceSelectedClip()
        case .exportFrame: exportFrame()
        case .loop: bounds.loop.toggle(); model.isLooping = bounds.loop
        case .playInToOut: playInToOut()
        case .lift, .extract, .toggleSafeMargins: break
        }
    }

    // MARK: Loading

    @discardableResult
    public func open(_ id: MediaRef.ID, at time: Time? = nil) -> Bool {
        guard let ref = session.project.media(id) else { return false }
        guard let built = SourceTimelineBuilder.build(ref) else {
            if id == mediaID { loadedShape = SourceTimelineBuilder.shape(of: ref) }   // even on failure: no repeated status on every project change
            onStatus?(SQL10n.format("“%@” has no readable duration yet.", ref.name)); return false
        }
        let (tl, format, total) = (built.timeline, built.format, built.total)
        let fd = format.frameDuration
        pause()
        mediaID = id
        bounds.range = nil
        engine.setTimeline(tl, sequences: [:])
        applyBuilt(ref, built)
        let start = (time ?? .zero).snapped(to: fd)
        position = min(start, max(.zero, total - fd))
        engine.seek(to: position)
        model.currentTime = position
        history.open(id)
        refreshMarks()
        return true
    }

    /// What the opened timeline says about the clip: shape, frame rate, length, drop frame, viewer mode and waveform.
    private func applyBuilt(_ ref: MediaRef, _ built: SourceTimelineBuilder.Built) {
        let fd = built.format.frameDuration
        let video = ref.info?.video
        loadedShape = [built.format.width, built.format.height]
        frameDuration = fd
        duration = built.total
        model.frameDuration = fd
        model.dropFrame = fd == Time(1001, 30000) || fd == Time(1001, 60000)
        model.duration = built.total
        let mode = SourceViewerMode.resolve(isOpen: true, hasVideo: video != nil || built.still || ref.info == nil,
                                            hasAudio: ref.info?.audio != nil)
        model.viewerMode = mode
        // An audio-only source has nothing to see while dragging: scrubbing always plays grains (tape scrub).
        engine.audioScrubbing = mode == .waveform
        model.sourceWaveform = mode == .waveform ? waveformProvider?(ref.id) : nil
    }

    /// Displayed picture size of the loaded clip [width, height] (the panel's aspect and zoom percentages).
    public var pictureShape: [Int] { loadedShape }

    /// A new displayed shape (pixel aspect, or probe info that arrived late): the source timeline is built again in
    /// place. Playback keeps running; the frame rate, length and mode follow the new info, the playhead and the play
    /// In to Out range are clamped to the new end.
    private func reshape(_ ref: MediaRef) {
        loadedShape = SourceTimelineBuilder.shape(of: ref)
        guard let built = SourceTimelineBuilder.build(ref) else { return }
        engine.setTimeline(built.timeline, sequences: [:])
        applyBuilt(ref, built)
        if let r = bounds.range {
            let c = SourceTimelineBuilder.clampedRange(r, total: built.total)
            if c != r { bounds.range = c }
        }
        let p = SourceTimelineBuilder.clampedPosition(position, total: built.total, frameDuration: built.format.frameDuration)
        if p != position { position = p; model.currentTime = p; if !isPlaying { engine.seek(to: p) } }
        else if !isPlaying { engine.seek(to: position) }
    }

    /// Peaks for the audio-only view arrive after the open (the host's peak store builds them off the main actor).
    public func waveformReady(_ id: UUID) {
        guard id == mediaID, model.viewerMode == .waveform else { return }
        model.sourceWaveform = waveformProvider?(id)
    }

    /// Several clips at once (a drop or a multi-selection): the first one shows, the rest join the history in order.
    @discardableResult
    public func open(all ids: [MediaRef.ID]) -> Bool {
        guard let first = ids.first(where: { session.project.media($0) != nil }) else { return false }
        history.open(all: ids.filter { session.project.media($0) != nil })
        return open(first)
    }

    /// Title popup > Close: the current clip leaves the history; the next one (if any) shows.
    public func closeCurrent() {
        guard let id = mediaID else { return }
        history.close(id)
        if let next = history.ids.first { open(next) } else { close() }
    }

    public func closeAll() {
        history.closeAll()
        close()
    }

    public func close() {
        pause()
        mediaID = nil
        duration = .zero
        position = .zero
        model.viewerMode = .picture; model.sourceWaveform = nil
        model.duration = .zero; model.currentTime = .zero; model.markIn = nil; model.markOut = nil
        refreshMarks()
        engine.setTimeline(Timeline(name: "", frameDuration: frameDuration, tracks: []), sequences: [:])
    }

    public func sync(_ change: EditorSession.Change) {
        guard let id = mediaID else { return }
        if session.project.media(id) == nil { history.close(id); if let next = history.ids.first { open(next) } else { close() }; return }
        if change.contains(.project) {
            refreshMarks()
            // The pixel aspect changes the displayed size: build the source timeline again in the new shape, same place.
            if let ref = session.project.media(id), SourceTimelineBuilder.needsReshape(ref, loaded: loadedShape) {
                reshape(ref)
            }
        }
    }

    private func refreshMarks() {
        history.prune(keeping: Set(session.project.media.map(\.id)))
        model.sourceItems = history.ids.compactMap { id in session.project.media(id).map { .init(id: id, name: $0.name) } }
        model.sourceCurrent = mediaID
        guard let id = mediaID else { model.markerTimes = []; return }
        let m = session.project.sourceMarks(for: id)
        model.markIn = m.markIn
        model.markOut = m.markOut
        model.markerTimes = session.project.sourceMarkers(for: id).map(\.time)
    }

    public var marks: SourceMarks { mediaID.map { session.project.sourceMarks(for: $0) } ?? SourceMarks() }

    // MARK: Transport

    public var currentTime: Time { position }

    public func pause() {
        if isPlaying || !engine.rate.isPaused { engine.pause() }
        isPlaying = false
        shuttle.stopped()
        model.isPlaying = false
    }

    /// Scrub gesture on the ruler or waveform: the engine seeks and, for audio-only sources, plays short grains.
    private func beginScrub() {
        pause()
        if mediaID != nil { engine.beginScrub() }
    }

    private func scrub(to t: Time) {
        guard mediaID != nil else { return }
        let target = min(max(.zero, t.snapped(to: frameDuration)), max(.zero, duration - frameDuration))
        position = target
        engine.scrub(to: target)
        model.currentTime = target
    }

    private func endScrub() {
        if mediaID != nil { engine.endScrub() }
    }

    public func seek(to t: Time) {
        guard mediaID != nil else { return }
        if isPlaying { pause() }
        let target = min(max(.zero, t.snapped(to: frameDuration)), max(.zero, duration - frameDuration))
        position = target
        engine.seek(to: target)
        model.currentTime = target
    }

    public func stepFrames(_ n: Int) { seek(to: position + frameDuration * Int64(n)) }
    public func goToStart() { seek(to: .zero) }
    public func goToEnd() { seek(to: max(.zero, duration - frameDuration)) }
    public func goToIn() { if let i = marks.markIn { seek(to: i) } }
    /// Out is stored exclusive: show the marked (last included) frame.
    public func goToOut() { if let o = marks.markOut { seek(to: o - frameDuration) } }

    public func play(rate: PlaybackRate) {
        guard mediaID != nil else { return }
        if rate.isPaused { pause(); return }
        onStartedPlaying?()
        bounds.range = nil
        if rate.isForward, position + frameDuration >= duration { seek(to: .zero) }
        engine.play(rate)
        isPlaying = true
        model.isPlaying = true
    }

    public func playPause() { if isPlaying { pause() } else { play(rate: previewRate.rate) } }

    public func apply(shuttle action: ShuttleAction) {
        switch action {
        case .setRate(let r): play(rate: r)
        case .step(let n): stepFrames(n)
        case .none: break
        }
    }

    public func nudge(forward: Bool) {
        play(rate: engine.rate.nudged(forward: forward))
        shuttle.adopt(engine.rate)
    }

    public func press(_ key: ShuttleKey) { apply(shuttle: shuttle.press(key)); _ = shuttle.release(key) }

    /// Option+K plays In..Out; Shift+Space (`withRoll`) starts `preroll` before In and ends `postroll` after Out.
    public func playInToOut(withRoll: Bool = false) {
        guard mediaID != nil else { return }
        var range = Timeline.sourceEditRange(marks: marks, total: duration)
        if withRoll, let r = range { range = PlaybackBounds.extended(r, preroll: preroll, postroll: postroll, duration: duration) ?? r }
        seek(to: range?.start ?? .zero)
        play(rate: .forward)
        bounds.range = range
    }

    /// Shift+K: from `preroll` before the playhead to `postroll` after it, then back to where it was.
    public func playAround() {
        guard mediaID != nil else { return }
        let here = position
        guard let range = PlaybackBounds.playAround(at: here, preroll: preroll, postroll: postroll, duration: duration) else { return }
        seek(to: range.start)
        play(rate: .forward)
        bounds.range = range
        bounds.returnTo = here
    }

    private func positionChanged(_ t: Time) {
        guard isPlaying else { return }
        let rate = engine.rate
        switch bounds.action(at: t, rate: rate, frameDuration: frameDuration, duration: duration) {
        case .wrap where engineWrapsLoops && engine.loops: break   // the engine wraps by itself
        case .wrap(let to):
            position = to; model.currentTime = to
            engine.seek(to: to); engine.play(rate)
            return
        case .stop(let at):
            // Park on the last frame (the end itself is one frame past the picture).
            // Reverse playback stops on the range start itself.
            let parked = rate.isReverse ? max(.zero, at) : max(.zero, min(at, duration) - frameDuration)
            pause(); position = parked; model.currentTime = parked
            engine.seek(to: parked)
            return
        case .stopAndReturn(let back):
            pause(); bounds.range = nil
            seek(to: back)
            return
        case .none: break
        }
        // A paused engine reports where its pause parked (the frame on the glass): that is the position.
        position = t
        model.currentTime = t
        if engine.rate.isPaused { pause() }
    }

    // MARK: Marks

    private func setMarks(_ body: (inout Project, MediaRef.ID) -> Void) {
        guard let id = mediaID else { return }
        var p = session.project
        body(&p, id)
        session.setSourceMarks(p.sourceMarks[id], for: id)
        refreshMarks()
    }

    public func markIn() { let t = position; setMarks { $0.setSourceIn(t, for: $1) } }
    public func markOut() { let t = position + frameDuration; setMarks { $0.setSourceOut(t, for: $1) } }
    /// Mark Audio In / Mark Video In: split edit starts (the next Insert / Overwrite lays sound and picture apart).
    public func markAudioIn() { let t = position; setMarks { $0.setSourceAudioIn(t, for: $1) } }
    public func markVideoIn() { let t = position; setMarks { $0.setSourceVideoIn(t, for: $1) } }
    public func clearIn() { setMarks { $0.clearSourceIn(for: $1) } }
    public func clearOut() { setMarks { $0.clearSourceOut(for: $1) } }
    public func clearMarks() { setMarks { $0.clearSourceMarks(for: $1) } }
    /// X: In at the start, Out at the end of the whole clip. The sequence's In/Out stay as they are.
    public func markClip() {
        let d = duration
        setMarks { _ = $0.markSourceClip($1, duration: d) }
    }

    // MARK: Markers (M)

    /// M: a marker on the clip at the playhead. A second M on the same frame says so (no dialog for clip markers yet).
    public func addMarker() {
        guard let id = mediaID else { onStatus?("Open a clip in the Source monitor first."); return }
        var p = session.project
        guard let r = p.addSourceMarker(at: position, frameDuration: frameDuration, to: id) else { return }
        if !r.isNew { onStatus?("There is already a marker on this frame."); return }
        session.setSourceMarkers(p.sourceMarkers(for: id), for: id)
        refreshMarks()
    }

    public func clearMarkerAtPlayhead() {
        guard let id = mediaID, let m = session.project.sourceMarkers(for: id).first(where: { $0.time == position }) else { return }
        var p = session.project
        p.removeSourceMarker(m.id, from: id)
        session.setSourceMarkers(p.sourceMarkers(for: id), for: id)
        refreshMarks()
    }

    public func clearAllMarkers() {
        guard let id = mediaID else { return }
        session.setSourceMarkers(nil, for: id)
        refreshMarks()
    }

    public func goToMarker(forward: Bool) {
        guard let id = mediaID else { return }
        let times = session.project.sourceMarkers(for: id).map(\.time)
        if let t = forward ? times.first(where: { $0 > position }) : times.last(where: { $0 < position }) { seek(to: t) }
    }

    // MARK: Editing

    public func edit(_ mode: ThreePointMode, streams: SourceStreams = .both, placeOnTop: Bool = false, backtimed: Bool = false,
                     fitToFill: Bool = false) {
        guard let id = mediaID else { onStatus?("Open a clip in the Source monitor first (double-click it in the Project panel)."); return }
        pause()
        // Four marks of different lengths: ask what decides the edit (Fit Clip); the last choice is preselected.
        if !fitToFill, !backtimed, session.fourPointNeedsChoice(media: id), let ask = chooseFourPointFit {
            ask { [weak self] choice in
                guard let self, let choice else { return }
                session.sourceEdit(media: id, streams: streams, mode: mode, placeOnTop: placeOnTop,
                                   fitToFill: choice == .changeSpeed, fourPointFit: choice.fit ?? .trimSourceEnd)
            }
            return
        }
        session.sourceEdit(media: id, streams: streams, mode: mode, placeOnTop: placeOnTop, backtimed: backtimed, fitToFill: fitToFill)
    }

    /// Replace Clip from Source: the one selected clip plays this Source clip, the frame shown here lined up with the playhead.
    public func replaceSelectedClip() {
        guard let id = mediaID else { onStatus?("Open a clip in the Source monitor first (double-click it in the Project panel)."); return }
        guard session.selection.count == 1, let clip = session.selection.first else {
            onStatus?("Select one clip in the timeline to replace."); return
        }
        pause()
        session.replaceMedia(of: clip, with: id, matchSourceTime: position)
    }

    // MARK: Commands (keyboard focus on the Source monitor)

    /// Handles a command while the Source monitor has focus. False = not a source command, the caller runs its default.
    public func handle(_ c: EditorCommand) -> Bool {
        switch c {
        case .playPause: playPause()
        case .stepBackward: stepFrames(-1)
        case .stepForward: stepFrames(1)
        case .stepBackward5: stepFrames(-10)
        case .stepForward5: stepFrames(10)
        case .goToStart: goToStart()
        case .goToEnd: goToEnd()
        case .markIn: markIn()
        case .markOut: markOut()
        case .goToIn: goToIn()
        case .goToOut: goToOut()
        case .clearIn: clearIn()
        case .clearOut: clearOut()
        case .clearInOut: clearMarks()
        case .playInToOut: playInToOut()
        case .playInToOutRoll: playInToOut(withRoll: true)
        case .playAround: playAround()
        case .markClip: markClip()
        case .nextMarker: goToMarker(forward: true)
        case .previousMarker: goToMarker(forward: false)
        case .toggleLoop: bounds.loop.toggle(); model.isLooping = bounds.loop
        case .shuttleReverse: press(.j)
        case .shuttleStop: press(.k)
        case .shuttleSlowReverse: nudge(forward: false)
        case .shuttleSlowForward: nudge(forward: true)
        case .shuttleForward: press(.l)
        case .addMarker: addMarker()
        default: return false
        }
        return true
    }

    // MARK: Export frame and menu

    open func exportFrame() {
        guard mediaID != nil else { return }
        pause()
        onExportFrame?()
    }

    /// Make Subclip: the In/Out range becomes a Project item (refusals land in the session's status line).
    public func makeSubclip() {
        guard let id = mediaID else { return }
        session.makeSubclip(of: id)
    }

    /// Key column of a command row: the mapped key, "" when unbound.
    static func shortcut(_ c: EditorCommand) -> String {
        #if canImport(AppKit)
        CommandMenuKeys.shortcut(c)
        #else
        CommandMap.current.binding(for: c).map { KeyBindingText.text($0) } ?? ""
        #endif
    }

    public func contextMenuItems() -> [SQMenuItem] {
        var rows: [SQMenuItem] = []
        func add(_ title: String, _ enabled: Bool = true, checked: Bool = false, command: EditorCommand? = nil,
                 _ action: @escaping @MainActor () -> Void) {
            rows.append(SQMenuItem(title: title, shortcut: command.map { Self.shortcut($0) } ?? "",
                                   isEnabled: enabled, isChecked: checked, action: action))
        }
        let has = mediaID != nil
        let m = marks
        if let toggle = onToggleAngles {
            add("Show All Angles", anglesAvailable?() ?? false, checked: model.angleTiles != nil) { toggle() }
            rows.append(.separator)
        }
        add("Mark Clip", has, command: .markClip) { [weak self] in self?.markClip() }
        add("Mark In", has, command: .markIn) { [weak self] in self?.markIn() }
        add("Mark Out", has, command: .markOut) { [weak self] in self?.markOut() }
        add("Mark Audio In", has && duration > .zero, checked: m.audioIn != nil) { [weak self] in self?.markAudioIn() }
        add("Mark Video In", has && duration > .zero, checked: m.videoIn != nil) { [weak self] in self?.markVideoIn() }
        add("Go to In", m.markIn != nil, command: .goToIn) { [weak self] in self?.goToIn() }
        add("Go to Out", m.markOut != nil, command: .goToOut) { [weak self] in self?.goToOut() }
        rows.append(.separator)
        add("Remove In", m.markIn != nil, command: .clearIn) { [weak self] in self?.clearIn() }
        add("Remove Out", m.markOut != nil, command: .clearOut) { [weak self] in self?.clearOut() }
        add("Remove In and Out", !m.isEmpty, command: .clearInOut) { [weak self] in self?.clearMarks() }
        rows.append(.separator)
        let markers = mediaID.map { session.project.sourceMarkers(for: $0) } ?? []
        add("Add Marker", has, command: .addMarker) { [weak self] in self?.addMarker() }
        if markers.contains(where: { $0.time == position }) { add("Delete Marker") { [weak self] in self?.clearMarkerAtPlayhead() } }
        if !markers.isEmpty { add("Delete All Markers") { [weak self] in self?.clearAllMarkers() } }
        rows.append(.separator)
        add("Insert", has, command: .insert) { [weak self] in self?.edit(.insert) }
        add("Overwrite", has, command: .overwrite) { [weak self] in self?.edit(.overwrite) }
        add("Fit to Fill", has) { [weak self] in self?.edit(.overwrite, fitToFill: true) }
        add("Replace Clip from Source", has) { [weak self] in self?.replaceSelectedClip() }
        rows.append(.separator)
        add("Make Subclip", has && !m.isEmpty, command: .makeSubclip) { [weak self] in self?.makeSubclip() }
        rows.append(.separator)
        add("Export Frame…", has, command: .exportFrame) { [weak self] in self?.exportFrame() }
        add("Loop Playback", checked: bounds.loop, command: .toggleLoop) { [weak self] in
            guard let self else { return }
            bounds.loop.toggle(); model.isLooping = bounds.loop
        }
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Zoom", submenu: MonitorMenus.zoomItems(current: model.zoom) { [weak self] in self?.model.setZoom($0) }))
        if has {
            rows.append(.separator)
            add("Reveal in Project") { [weak self] in
                if let id = self?.mediaID { self?.onRevealInProject?(id) }
            }
        }
        return rows
    }
}
