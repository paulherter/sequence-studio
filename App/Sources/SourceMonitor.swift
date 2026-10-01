import AppKit
import SQCore
import SQEditorUI
import SQRender

/// The Source monitor: plays one project media item on its own engine (a one-clip sequence in the media's own format)
/// and holds the item's In/Out marks (`Project.sourceMarks`). Insert and Overwrite go through
/// `EditorSession.sourceEdit`. Only one monitor plays at a time: starting one pauses the other (`pause()`).
@MainActor
final class SourceMonitorController {
    let session: EditorSession
    let engine: any ProgramEngine
    let model: MonitorPanelModel
    let view: MonitorPanelView
    let viewer = ViewerView(frame: .zero)

    private(set) var mediaID: MediaRef.ID?
    private var shuttle = Shuttle()
    private var frameDuration = Time(1, 30)
    private var duration = Time.zero
    private var isPlaying = false
    private var position = Time.zero
    var bounds = PlaybackBounds()
    /// Clips opened earlier (title popup): at most 20, most recent first.
    private(set) var history = SourceHistory()
    /// Preroll / postroll of Play In to Out with roll and of Play Around (Preferences > Playback).
    var preroll = PlaybackBounds.defaultPreroll
    var postroll = PlaybackBounds.defaultPostroll
    /// Streams of the drag in flight (video-only / audio-only icons); read by the timeline's drop handler.
    private(set) var dragStreams: SourceStreams = .both

    var onCommand: ((EditorCommand) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Playback started here: the Program monitor must stop.
    var onStartedPlaying: (() -> Void)?

    init(session: EditorSession, engine: any ProgramEngine) {
        self.session = session
        self.engine = engine
        model = MonitorPanelModel(frameDuration: frameDuration, mode: .source)
        view = MonitorPanelView(model: model)
        viewer.drivesLayer = false
        viewer.translatesAutoresizingMaskIntoConstraints = true
        viewer.frame = view.viewerSlot.bounds
        viewer.autoresizingMask = [.width, .height]
        view.viewerSlot.addSubview(viewer, positioned: .below, relativeTo: nil)
        engine.attach(viewer.metalLayer)
        viewer.onResize = { [weak self] in self?.engine.redraw() }
        engine.onPositionChange = { [weak self] t in self?.positionChanged(t) }
        wire()
    }

    private func wire() {
        model.onSeek = { [weak self] t in self?.seek(to: t) }
        model.onScrubBegan = { [weak self] in self?.pause() }
        model.onScrub = { [weak self] t in self?.seek(to: t) }
        model.onQualityChange = { [weak self] q in self?.engine.quality = q.decodeScale }
        model.onZoomChange = { [weak self] z in
            switch z {
            case .fit: self?.engine.viewerZoom = .fit
            case .percent(let p), .custom(let p): self?.engine.viewerZoom = .percent(p)
            }
        }
        model.onAction = { [weak self] a in
            guard let self else { return }
            switch a {
            case .markIn: markIn()
            case .markOut: markOut()
            case .goToIn: goToIn()
            case .goToOut: goToOut()
            case .stepBack: stepFrames(-1)
            case .stepForward: stepFrames(1)
            case .playPause: playPause()
            case .addMarker: addMarker()
            case .insert: edit(.insert)
            case .overwrite: edit(.overwrite)
            case .exportFrame: exportFrame()
            case .loop: bounds.loop.toggle(); model.isLooping = bounds.loop
            case .playInToOut: playInToOut()
            case .lift, .extract, .toggleSafeMargins: break
            }
        }
        model.dragItem = { [weak self] streams in
            guard let self, let id = mediaID else { return nil }
            dragStreams = streams
            let item = NSPasteboardItem()
            item.setString(ProjectPanelModel.encodeItems([.media(id)]), forType: .sequenceMediaIDs)
            return item
        }
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
        model.contextMenuBuilder = { [weak self] menu in self?.fillContextMenu(menu) }
    }

    // MARK: Loading

    @discardableResult
    func open(_ id: MediaRef.ID, at time: Time? = nil) -> Bool {
        guard let ref = session.project.media(id) else { return false }
        let still = ref.info?.isStill == true
        guard let total = still ? Time(5, 1) : (ref.info?.duration ?? ref.duration) else {
            onStatus?("“\(ref.name)” has no readable duration yet."); return false
        }
        let video = ref.info?.video
        let hasAudio = ref.info?.audio != nil
        let fd = still ? Time(1, 30) : (video?.nominalFrameDuration ?? Time(1, 30))
        let format = SequenceFormat(width: video?.displayWidth ?? 1920, height: video?.displayHeight ?? 1080,
                                    frameDuration: fd, audioSampleRate: ref.info?.audio?.sampleRate ?? 48_000)
        let tl = Timeline.sourceTimeline(media: ref, format: format, hasVideo: video != nil || ref.info == nil,
                                         hasAudio: hasAudio, duration: total, isStill: still)
        pause()
        mediaID = id
        frameDuration = fd
        duration = total
        bounds.range = nil
        engine.setTimeline(tl, sequences: [:])
        let start = (time ?? .zero).snapped(to: fd)
        position = min(start, max(.zero, total - fd))
        engine.seek(to: position)
        model.frameDuration = fd
        model.dropFrame = fd == Time(1001, 30000) || fd == Time(1001, 60000)
        model.duration = total
        model.currentTime = position
        history.open(id)
        refreshMarks()
        return true
    }

    /// Several clips at once (a drop or a multi-selection): the first one shows, the rest join the history in order.
    @discardableResult
    func open(all ids: [MediaRef.ID]) -> Bool {
        guard let first = ids.first(where: { session.project.media($0) != nil }) else { return false }
        history.open(all: ids.filter { session.project.media($0) != nil })
        return open(first)
    }

    /// Title popup > Close: the current clip leaves the history; the next one (if any) shows.
    func closeCurrent() {
        guard let id = mediaID else { return }
        history.close(id)
        if let next = history.ids.first { open(next) } else { close() }
    }

    func closeAll() {
        history.closeAll()
        close()
    }

    func close() {
        pause()
        mediaID = nil
        duration = .zero
        position = .zero
        model.duration = .zero; model.currentTime = .zero; model.markIn = nil; model.markOut = nil
        refreshMarks()
        engine.setTimeline(Timeline(name: "", frameDuration: frameDuration, tracks: []), sequences: [:])
    }

    func sync(_ change: EditorSession.Change) {
        guard let id = mediaID else { return }
        if session.project.media(id) == nil { history.close(id); if let next = history.ids.first { open(next) } else { close() }; return }
        if change.contains(.project) { refreshMarks() }
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

    var marks: SourceMarks { mediaID.map { session.project.sourceMarks(for: $0) } ?? SourceMarks() }

    // MARK: Transport

    var currentTime: Time { position }

    func pause() {
        if isPlaying || !engine.rate.isPaused { engine.pause() }
        isPlaying = false
        shuttle.stopped()
        model.isPlaying = false
    }

    func seek(to t: Time) {
        guard mediaID != nil else { return }
        if isPlaying { pause() }
        let target = min(max(.zero, t.snapped(to: frameDuration)), max(.zero, duration - frameDuration))
        position = target
        engine.seek(to: target)
        model.currentTime = target
    }

    func stepFrames(_ n: Int) { seek(to: position + frameDuration * Int64(n)) }
    func goToStart() { seek(to: .zero) }
    func goToEnd() { seek(to: max(.zero, duration - frameDuration)) }
    func goToIn() { if let i = marks.markIn { seek(to: i) } }
    /// Out is stored exclusive: show the marked (last included) frame.
    func goToOut() { if let o = marks.markOut { seek(to: o - frameDuration) } }

    func play(rate: PlaybackRate) {
        guard mediaID != nil else { return }
        if rate.isPaused { pause(); return }
        onStartedPlaying?()
        bounds.range = nil
        if rate.isForward, position + frameDuration >= duration { seek(to: .zero) }
        engine.play(rate)
        isPlaying = true
        model.isPlaying = true
    }

    func playPause() { if isPlaying { pause() } else { play(rate: .forward) } }

    func apply(shuttle action: ShuttleAction) {
        switch action {
        case .setRate(let r): play(rate: r)
        case .step(let n): stepFrames(n)
        case .none: break
        }
    }

    func nudge(forward: Bool) {
        play(rate: engine.rate.nudged(forward: forward))
        shuttle.adopt(engine.rate)
    }

    func press(_ key: ShuttleKey) { apply(shuttle: shuttle.press(key)); _ = shuttle.release(key) }

    /// Option+K plays In..Out; Shift+Space (`withRoll`) starts `preroll` before In and ends `postroll` after Out.
    func playInToOut(withRoll: Bool = false) {
        guard mediaID != nil else { return }
        var range = Timeline.sourceEditRange(marks: marks, total: duration)
        if withRoll, let r = range { range = PlaybackBounds.extended(r, preroll: preroll, postroll: postroll, duration: duration) ?? r }
        seek(to: range?.start ?? .zero)
        play(rate: .forward)
        bounds.range = range
    }

    /// Shift+K: from `preroll` before the playhead to `postroll` after it, then back to where it was.
    func playAround() {
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
        case .wrap(let to):
            position = to; model.currentTime = to
            engine.seek(to: to); engine.play(rate)
            return
        case .stop(let at):
            // Park on the last frame (the end itself is one frame past the picture).
            let parked = max(.zero, min(at, duration) - frameDuration)
            pause(); position = parked; model.currentTime = parked
            engine.seek(to: parked)
            return
        case .stopAndReturn(let back):
            pause(); bounds.range = nil
            seek(to: back)
            return
        case .none: break
        }
        if engine.rate.isPaused { pause(); return }
        position = t
        model.currentTime = t
    }

    // MARK: Marks

    private func setMarks(_ body: (inout Project, MediaRef.ID) -> Void) {
        guard let id = mediaID else { return }
        var p = session.project
        body(&p, id)
        session.setSourceMarks(p.sourceMarks[id], for: id)
        refreshMarks()
    }

    func markIn() { let t = position; setMarks { $0.setSourceIn(t, for: $1) } }
    func markOut() { let t = position + frameDuration; setMarks { $0.setSourceOut(t, for: $1) } }
    func clearIn() { setMarks { $0.clearSourceIn(for: $1) } }
    func clearOut() { setMarks { $0.clearSourceOut(for: $1) } }
    func clearMarks() { setMarks { $0.clearSourceMarks(for: $1) } }
    /// X: In at the start, Out at the end of the whole clip. The sequence's In/Out stay as they are.
    func markClip() {
        let d = duration
        setMarks { _ = $0.markSourceClip($1, duration: d) }
    }

    // MARK: Markers (M)

    /// M: a marker on the clip at the playhead. A second M on the same frame says so (no dialog for clip markers yet).
    func addMarker() {
        guard let id = mediaID else { onStatus?("Open a clip in the Source monitor first."); return }
        var p = session.project
        guard let r = p.addSourceMarker(at: position, frameDuration: frameDuration, to: id) else { return }
        if !r.isNew { onStatus?("There is already a marker on this frame."); return }
        session.setSourceMarkers(p.sourceMarkers(for: id), for: id)
        refreshMarks()
    }

    func clearMarkerAtPlayhead() {
        guard let id = mediaID, let m = session.project.sourceMarkers(for: id).first(where: { $0.time == position }) else { return }
        var p = session.project
        p.removeSourceMarker(m.id, from: id)
        session.setSourceMarkers(p.sourceMarkers(for: id), for: id)
        refreshMarks()
    }

    func clearAllMarkers() {
        guard let id = mediaID else { return }
        session.setSourceMarkers(nil, for: id)
        refreshMarks()
    }

    func goToMarker(forward: Bool) {
        guard let id = mediaID else { return }
        let times = session.project.sourceMarkers(for: id).map(\.time)
        if let t = forward ? times.first(where: { $0 > position }) : times.last(where: { $0 < position }) { seek(to: t) }
    }

    // MARK: Editing

    func edit(_ mode: ThreePointMode, streams: SourceStreams = .both) {
        guard let id = mediaID else { onStatus?("Open a clip in the Source monitor first (double-click it in the Project panel)."); return }
        pause()
        session.sourceEdit(media: id, streams: streams, mode: mode)
    }

    // MARK: Commands (keyboard focus on the Source monitor)

    /// Handles a command while the Source monitor has focus. False = not a source command, the caller runs its default.
    func handle(_ c: EditorCommand) -> Bool {
        switch c {
        case .playPause: playPause()
        case .stepBackward: stepFrames(-1)
        case .stepForward: stepFrames(1)
        case .stepBackward5: stepFrames(-5)
        case .stepForward5: stepFrames(5)
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

    func exportFrame() {
        guard mediaID != nil else { return }
        pause()
        let name = mediaID.flatMap { session.project.media($0)?.name } ?? "Frame"
        let base = (name as NSString).deletingPathExtension
        FrameExport.run(texture: engine.lastRenderedTexture, suggestedName: base + ".png", on: view.window, status: { [weak self] in self?.onStatus?($0) })
    }

    private func fillContextMenu(_ menu: NSMenu) {
        func add(_ title: String, _ enabled: Bool = true, _ action: @escaping () -> Void) {
            let it = ClosureMenuItem(title: title, action: action)
            it.isEnabled = enabled
            menu.addItem(it)
        }
        let has = mediaID != nil
        let m = marks
        add("Mark Clip", has) { [weak self] in self?.markClip() }
        add("Mark In", has) { [weak self] in self?.markIn() }
        add("Mark Out", has) { [weak self] in self?.markOut() }
        add("Go to In", m.markIn != nil) { [weak self] in self?.goToIn() }
        add("Go to Out", m.markOut != nil) { [weak self] in self?.goToOut() }
        menu.addItem(.separator())
        add("Clear In", m.markIn != nil) { [weak self] in self?.clearIn() }
        add("Clear Out", m.markOut != nil) { [weak self] in self?.clearOut() }
        add("Clear In and Out", !m.isEmpty) { [weak self] in self?.clearMarks() }
        menu.addItem(.separator())
        let markers = mediaID.map { session.project.sourceMarkers(for: $0) } ?? []
        add("Add Marker", has) { [weak self] in self?.addMarker() }
        if markers.contains(where: { $0.time == position }) { add("Clear Marker") { [weak self] in self?.clearMarkerAtPlayhead() } }
        if !markers.isEmpty { add("Clear All Markers") { [weak self] in self?.clearAllMarkers() } }
        menu.addItem(.separator())
        add("Insert", has) { [weak self] in self?.edit(.insert) }
        add("Overwrite", has) { [weak self] in self?.edit(.overwrite) }
        menu.addItem(.separator())
        add("Export Frame…", has) { [weak self] in self?.exportFrame() }
        add("Loop Playback") { [weak self] in
            guard let self else { return }
            bounds.loop.toggle(); model.isLooping = bounds.loop
        }
        if let loop = menu.items.last { loop.state = bounds.loop ? .on : .off }
        if has {
            menu.addItem(.separator())
            add("Reveal in Project") { [weak self] in
                if let id = self?.mediaID { self?.onRevealInProject?(id) }
            }
        }
    }
    var onRevealInProject: ((MediaRef.ID) -> Void)?
}

/// Menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
