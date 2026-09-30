import AppKit
import SSCore
import SSEditorUI
import SSRender

/// Owns the panel views and models and keeps them in step with the `EditorSession`: session changes flow in through
/// `sync(_:)`, user gestures flow out as session calls. Only the Source monitor is still a placeholder.
@MainActor
final class EditorPanels {
    let session: EditorSession

    let timelineView = TimelineView()
    /// Peaks for audio clips; filled for every clip on the timeline, whichever way the media came in.
    let waveforms = TimelineWaveforms()
    let viewer = ViewerView(frame: .zero)
    let monitorModel: MonitorPanelModel
    let monitorView: MonitorPanelView
    let projectModel: ProjectPanelModel
    let projectView: ProjectPanelView
    let effectModel = EffectControlsModel()
    let effectView: EffectControlsView
    let libraryModel = LibraryServices.makeModel()
    let libraryView: LibraryPanelView
    let clipSections: ClipSectionsView
    let textView: TextPanelView
    let colorView: ColorInspectorPanelView
    let scopesView: ScopesPanelView
    let effectsView = EffectsPanelView()

    private var placeholders: [PanelID: NSView] = [:]

    /// A panel was clicked or received a command: move keyboard focus (and shortcut scope) there.
    var onFocus: ((PanelID) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCommand: ((EditorCommand) -> Void)?
    var onNest: (() -> Void)?

    init(session: EditorSession) {
        self.session = session
        let fd = session.activeTimeline?.frameDuration ?? Time(1001, 30000)
        monitorModel = MonitorPanelModel(frameDuration: fd)
        monitorView = MonitorPanelView(model: monitorModel)
        projectModel = ProjectPanelModel(project: session.project, onEdit: { [weak session] p, name in
            session?.perform(name) { $0 = p }
        })
        projectView = ProjectPanelView(model: projectModel)
        effectView = EffectControlsView(model: effectModel)
        libraryView = LibraryPanelView(model: libraryModel)
        clipSections = ClipSectionsView(session: session)
        textView = TextPanelView(session: session)
        colorView = ColorInspectorPanelView(session: session)
        scopesView = ScopesPanelView(session: session)
        Task { [libraryModel] in await LibraryServices.start(libraryModel) }
        effectView.clipSections = clipSections
        wireTimeline()
        wireSidePanels()
        wireMonitor()
        wireEffectControls()
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
        tv.onSelectionChange = { [weak self] clips, captions in self?.session.select(clips: clips, captions: captions) }
        tv.onPointerDown = { [weak self] in self?.session.stopPlayback() }
        tv.onSeek = { [weak self] t in self?.session.seek(to: t) }
        tv.onScrubBegan = { [weak self] in self?.session.beginScrub() }
        tv.onScrub = { [weak self] t in self?.session.scrub(to: t) }
        tv.onScrubEnded = { [weak self] in self?.session.endScrub() }
        tv.onFocusRequest = { [weak self] in self?.onFocus?(.timeline) }
        tv.onRejection = { [weak self] m in self?.onStatus?(m) }
        tv.onTrackToggle = { [weak self] id, toggle in self?.toggleTrack(id, toggle) }
        tv.onDropMedia = { [weak self] ids, time, track, insert in
            self?.session.placeMedia(ids, at: time, videoTrack: track, mode: insert ? .insert : .overwrite)
        }
        tv.onDropTextTemplate = { [weak self] id, time, track in
            guard let entry = TextTemplateCatalog.entry(id: id) else { return }
            self?.session.addTextClip(template: entry.template, at: time, track: track)
        }
        tv.onDropFiles = { [weak self] urls, time, track, insert in self?.dropFiles(urls, at: time, track: track, insert: insert) }
        tv.dropItemsProvider = { [weak self] source in self?.dropItems(for: source) ?? [] }
        tv.onDropEffect = { [weak self] id, clip in
            guard let self, id == EffectsPanelView.roundedCorners else { return }
            if !session.addRoundedCorners(to: [clip]) { onStatus?("Rounded Corners need a video clip that does not have it yet.") }
        }
        tv.contextMenuProvider = { [weak self] p in self?.timelineMenu(at: p) }
    }

    /// Length and streams of what is being dragged, for the ghost. Files not imported yet get the 5 s placeholder.
    private func dropItems(for source: TimelineView.DropSource) -> [DropItem] {
        switch source {
        case .media(let ids):
            let marks = session.project.sourceMarks
            return ids.compactMap { id in
                guard let ref = session.project.media(id) else { return nil }
                let total = ref.info?.duration ?? ref.duration
                guard let d = marks[id]?.range?.duration ?? total else { return nil }
                return DropItem(name: ref.name, duration: d, hasVideo: ref.info?.video != nil || ref.info == nil,
                                hasAudio: ref.info?.audio != nil)
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
        colorView.onChange = { [weak self] in self?.scopesView.scheduleRefresh() }
        libraryView.onApplyTextTemplate = { [weak self] id in
            guard let self, let entry = TextTemplateCatalog.entry(id: id) else { return }
            session.addTextClip(template: entry.template)
        }
        effectsView.onApply = { [weak self] id in
            guard let self, id == EffectsPanelView.roundedCorners else { return }
            if !session.addRoundedCorners() { onStatus?("Select a video clip without Rounded Corners first.") }
        }
    }

    private func toggleTrack(_ id: Track.ID, _ toggle: TrackToggle) {
        let name: String
        switch toggle {
        case .visible: name = "Toggle Track Output"
        case .mute: name = "Toggle Mute"
        case .solo: name = "Toggle Solo"
        case .lock: name = "Toggle Track Lock"
        case .target: name = "Toggle Track Target"
        }
        try? session.performTimeline(name) { t in
            guard let i = t.tracks.firstIndex(where: { $0.id == id }) else { return }
            switch toggle {
            case .visible: t.tracks[i].isVisible.toggle()
            case .mute: t.tracks[i].isMuted.toggle()
            case .solo: t.tracks[i].isSolo.toggle()
            case .lock: t.tracks[i].isLocked.toggle()
            case .target: t.tracks[i].isTargeted.toggle()
            }
        }
    }

    private func timelineMenu(at p: CGPoint) -> NSMenu? {
        let tv = timelineView
        tv.contextSelect(at: p)
        let items = TimelineContextMenu.items(timeline: tv.timeline, selection: tv.selection,
                                              captionSelection: tv.captionSelection, clipboardHasClips: false)
            .map { item -> TimelineMenuItem in
                var i = item
                // Clipboard, link and rename have no session command yet.
                if [.cut, .copy, .paste, .link, .unlink, .rename, .revealInProject].contains(item.action) { i.isEnabled = false }
                return i
            }
        return TimelineContextMenu.makeMenu(items: items) { [weak self] action in
            switch action {
            case .delete: self?.onCommand?(.delete)
            case .rippleDelete: self?.onCommand?(.rippleDelete)
            case .nest: self?.onNest?()
            default: break
            }
        }
    }

    private func wireMonitor() {
        viewer.drivesLayer = false           // the playback engine presents into the layer
        viewer.translatesAutoresizingMaskIntoConstraints = true
        viewer.frame = monitorView.viewerSlot.bounds
        viewer.autoresizingMask = [.width, .height]
        monitorView.viewerSlot.addSubview(viewer)
        session.engine.attach(viewer.metalLayer)

        monitorModel.onSeek = { [weak self] t in self?.session.seek(to: t) }
        monitorModel.onQualityChange = { [weak self] q in self?.session.engine.quality = q.decodeScale }
        monitorModel.onZoomChange = { [weak self] z in
            switch z {
            case .fit: self?.session.engine.viewerZoom = .fit
            case .percent(let p): self?.session.engine.viewerZoom = .percent(p)
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
            }
            self?.onCommand?(c)
        }
    }

    private func wireEffectControls() {
        effectModel.onEdit = { [weak self] clip, name, coalescing in
            self?.session.replaceClip(clip, name: name, continuesGesture: coalescing)
        }
        effectModel.onSeek = { [weak self] t in self?.session.seek(to: t) }
    }

    // MARK: Views

    func view(for p: PanelID) -> NSView {
        switch p {
        case .timeline: return timelineView
        case .programMonitor: return monitorView
        case .project: return projectView
        case .effectControls: return effectView
        case .library: return libraryView
        case .text: return textView
        case .colorInspector: return colorView
        case .scopes: return scopesView
        case .effects: return effectsView
        case .sourceMonitor:
            if let v = placeholders[p] { return v }
            let v = PlaceholderPanelView(title: EditorCommand.panelTitle(p), symbol: Self.symbol(p))
            placeholders[p] = v
            return v
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
        if change.contains(.playhead) || change.contains(.project) {
            timelineView.setPlayhead(session.playhead)
            monitorModel.currentTime = session.playhead
            if session.isPlaying { followPlayhead() }
        }
        // Every change re-reads the transport state, so the Play/Pause button can never lag behind the session.
        if monitorModel.isPlaying != session.isPlaying { monitorModel.isPlaying = session.isPlaying }
        effectModel.sync(with: session, change: change)
        clipSections.sync(change)
        textView.sync(change)
        colorView.sync(change)
        scopesView.sync(change)
    }

    /// Page auto-scroll: when the playhead leaves the visible area during playback, jump a page.
    private func followPlayhead() {
        let tv = timelineView
        let x = tv.geometry.x(for: session.playhead)
        if x > tv.bounds.width - 12 || x < TimelineGeometry.contentOriginX {
            tv.scroll(toX: tv.geometry.scrollX + (x - TimelineGeometry.contentOriginX) - 24)
        }
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
