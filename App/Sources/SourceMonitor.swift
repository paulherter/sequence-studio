import AppKit
import SSCore
import SSEditorUI
import SSRender

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
            case .addMarker: onStatus?("Markers on source clips are not available yet.")
            case .insert: edit(.insert)
            case .overwrite: edit(.overwrite)
            case .exportFrame: exportFrame()
            case .loop: bounds.loop.toggle(); model.isLooping = bounds.loop
            case .lift, .extract, .playInToOut, .toggleSafeMargins: break
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
        refreshMarks()
        return true
    }

    func close() {
        pause()
        mediaID = nil
        duration = .zero
        position = .zero
        model.duration = .zero; model.currentTime = .zero; model.markIn = nil; model.markOut = nil
        engine.setTimeline(Timeline(name: "", frameDuration: frameDuration, tracks: []), sequences: [:])
    }

    func sync(_ change: EditorSession.Change) {
        guard let id = mediaID else { return }
        if session.project.media(id) == nil { close(); return }
        if change.contains(.project) { refreshMarks() }
    }

    private func refreshMarks() {
        guard let id = mediaID else { return }
        let m = session.project.sourceMarks(for: id)
        model.markIn = m.markIn
        model.markOut = m.markOut
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
        let target = min(max(.zero, t.snapped(to: frameDuration)), max(.zero, duration))
        position = target
        engine.seek(to: target)
        model.currentTime = target
    }

    func stepFrames(_ n: Int) { seek(to: position + frameDuration * Int64(n)) }
    func goToStart() { seek(to: .zero) }
    func goToEnd() { seek(to: max(.zero, duration - frameDuration)) }
    func goToIn() { if let i = marks.markIn { seek(to: i) } }
    func goToOut() { if let o = marks.markOut { seek(to: o) } }

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

    func nudge(forward: Bool) { play(rate: engine.rate.nudged(forward: forward)) }

    func press(_ key: ShuttleKey) { apply(shuttle: shuttle.press(key)); _ = shuttle.release(key) }

    func playInToOut() {
        guard mediaID != nil else { return }
        let m = marks
        let range = Timeline.sourceEditRange(marks: m, total: duration)
        seek(to: range?.start ?? .zero)
        play(rate: .forward)
        bounds.range = range
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
            pause(); position = at; model.currentTime = at
            engine.seek(to: at)
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
        case .toggleLoop: bounds.loop.toggle(); model.isLooping = bounds.loop
        case .shuttleReverse: press(.j)
        case .shuttleStop: press(.k)
        case .shuttleSlowReverse: nudge(forward: false)
        case .shuttleSlowForward: nudge(forward: true)
        case .shuttleForward: press(.l)
        case .addMarker: onStatus?("Markers on source clips are not available yet.")
        default: return false
        }
        return true
    }

    // MARK: Export frame and menu

    func exportFrame() {
        guard mediaID != nil else { return }
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
        add("Mark In", has) { [weak self] in self?.markIn() }
        add("Mark Out", has) { [weak self] in self?.markOut() }
        add("Go to In", m.markIn != nil) { [weak self] in self?.goToIn() }
        add("Go to Out", m.markOut != nil) { [weak self] in self?.goToOut() }
        menu.addItem(.separator())
        add("Clear In", m.markIn != nil) { [weak self] in self?.clearIn() }
        add("Clear Out", m.markOut != nil) { [weak self] in self?.clearOut() }
        add("Clear In and Out", !m.isEmpty) { [weak self] in self?.clearMarks() }
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
