import Foundation
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQEditorSession
import SQUIKit

/// The Source monitor of the shared shell: the shared `SourceMonitorCore` (the Mac SourceMonitorController's logic) on
/// its own platform engine (`AppMonitorBackend.makeSourceEngine`: Windows on the Program engine's D3D12 device, the Mac a
/// second PlaybackEngine with its own layer) and a `MonitorPanel` in source mode. Program and Source are tabs of the monitor card, as in the Mac layout; the
/// card shows one at a time. A click on the card gives its tab keyboard focus (`PanelID.sourceMonitor` routes the
/// transport and mark keys here, as `CommandRouting.sourceMonitorOffered` does on the Mac).
@MainActor
public final class SourceHost {
    public let engine: any AppMonitorEngine
    public let core: SourceMonitorCore
    public let panel: MonitorPanel
    private let session: EditorSession
    private unowned let shell: ShellHost
    /// The card shows the Source tab (else the Program tab).
    public var isShown = false
    /// "Show All Angles": the tiles of the Angles clip under the playhead instead of the picture (MonitorCardHost).
    public var showsAllAngles = false
    private var isDragging = false

    public init(session: EditorSession, shell: ShellHost, backend: AppMonitorBackend) {
        self.session = session
        self.shell = shell
        let engine = backend.makeSourceEngine()
        self.engine = engine
        engine.setMedia(session.project.media)
        core = SourceMonitorCore(session: session, engine: engine.player)
        // The shared panel zooms by placing the picture quad (`MonitorPanel.viewerZoom`): the engine renders at Fit.
        core.model.onZoomChange = nil
        panel = MonitorPanel(model: core.model, title: "Source")
        panel.tabs = ["Program", "Source"]
        panel.selectedTab = 1
        core.onStatus = { [weak shell] in shell?.onStatus?($0) }
        core.onCommand = { [weak shell] c in shell?.execute(c) }
        // Peaks come from the timeline's store; `layout` asks again until they are built.
        core.waveformProvider = { [weak backend] id in backend?.timelineMedia?.waveform(media: id) }
        core.chooseFourPointFit = { [weak self] done in
            guard let self else { done(nil); return }
            shell.spawn { done(await self.askFit()) }
        }
        core.onExportFrame = { [weak self] in self?.exportFrame() }
        // Audio-only media: the waveform view's level meter is this player's own output (App/Sources/SourceMonitor.swift).
        let player = engine.player
        panel.waveMeterReading = { [weak player] in
            guard let player, let r = player.meterReading else { return nil }
            return (ObjectIdentifier(player), r.sequence, r.peaks)
        }
        panel.onWaveChannelMonitorChange = { [weak engine] m in engine?.setChannelMonitor(m) }
        // The session's change hook is shared: keep whoever set it before.
        let previous = session.onChange
        session.onChange = { [weak self] change in
            previous?(change)
            guard let self else { return }
            if change.contains(.project) { engine.setMedia(session.project.media) }
            core.sync(change)
        }
    }

    /// Fit Clip (App/Sources/FourPointFitSheet.swift as a shell form): the rule a four-mark edit follows, remembered.
    private func askFit() async -> FourPointFitChoice? {
        let all = FourPointFitChoice.allCases
        let d = ShellDialog("Fit Clip", informative: "The Source and the sequence marks differ in length. Choose what decides the edit.")
        d.form = ShellForm([.radio(id: "fit", options: all.map(\.title),
                                   selected: all.firstIndex(of: FourPointFitChoice.saved()) ?? 0)])
        d.addButton("Edit")
        d.addButton("Cancel", role: .cancel)
        guard await shell.ask(d) == .first, let i = d.form?.index("fit"), all.indices.contains(i) else { return nil }
        FourPointFitChoice.save(all[i])
        return all[i]
    }

    /// Export Frame of the Source clip: the platform engine's frame as a PNG (the Program monitor's `exportFrame`).
    private func exportFrame() {
        let name = core.mediaID.flatMap { session.project.media($0)?.name } ?? "Frame"
        let base = (name as NSString).deletingPathExtension
        engine.exportFrame(suggestedName: base + ".png", files: shell.files as? PanelFileChooser) { [weak shell] in shell?.onStatus?($0) }
    }

    /// Opens a Project item in the Source tab (double-click in the Project panel).
    public func open(_ id: MediaRef.ID, at time: Time? = nil) {
        guard core.open(id, at: time) else { return }
        isShown = true
        shell.focus = .sourceMonitor
    }

    /// Show in Source (F): the media under the playhead opens here, parked on the same frame (EditorPanels.matchFrame).
    private func matchFrame() {
        guard let t = session.activeTimeline, let m = t.matchFrame(at: session.playhead, selected: session.selection) else {
            shell.onStatus?("No clip with media under the playhead to match."); return
        }
        open(m.media, at: m.sourceTime)
    }

    /// Show in Timeline (Shift+R): the playhead goes to the frame shown here, inside the clip that uses it.
    private func reverseMatchFrame() {
        guard let id = core.mediaID else { shell.onStatus?("Open a clip in the Source monitor first."); return }
        guard let t = session.activeTimeline,
              let at = t.reverseMatchFrame(media: id, sourceTime: core.model.currentTime, playhead: session.playhead,
                                           selected: session.selection)
        else { shell.onStatus?("That frame is not used in the sequence."); return }
        session.seek(to: at)
        isShown = false
        shell.focus = .timeline
    }

    public var isFocused: Bool { shell.focus == .sourceMonitor }

    /// Per frame: the engine clock, the facts the shell's command states read, the picture size and the card.
    public func layout(_ card: DrawRect, scale: Float) {
        engine.tick()
        if core.model.viewerMode == .waveform, core.model.sourceWaveform == nil, let id = core.mediaID { core.waveformReady(id) }
        let loaded = core.mediaID != nil
        shell.panels.panelsLoaded = true
        shell.panels.sourceMediaLoaded = loaded
        shell.panels.canPlaceSource = PlaceSource.resolve(sourceLoaded: loaded, focus: shell.focus, selectedMedia: 0,
                                                          selectedSequences: 0) == .sourceMonitor
        let shape = core.pictureShape
        if shape.count == 2 { panel.sequenceSize = CGSize(width: shape[0], height: shape[1]) }
        panel.hasPicture = engine.hasPicture
        panel.layout(card, scale: scale)
        panel.pollWaveMeter(now: ProcessInfo.processInfo.systemUptime)
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        panel.theme = theme
        panel.draw(&c)
    }

    /// Routes one event in pixels while the Source tab is shown; true when the panel took it.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        func inside(_ x: Float, _ y: Float) -> Bool { panel.frame.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) }
        switch e {
        case .mouseDown(let x, let y, _):
            guard inside(x, y) else { return false }
            isDragging = true
            shell.focus = .sourceMonitor
        case .mouseDragged: guard isDragging else { return false }
        case .mouseUp: guard isDragging else { return false }; isDragging = false
        case .mouseMoved: _ = panel.handle(e); return false
        case .scroll(let x, let y, _, _, _): guard inside(x, y) else { return false }
        case .keyDown(let k, _):
            return k == .escape && panel.activeSourceDrag != nil && panel.handle(e)
        }
        _ = panel.handle(e)
        return true
    }

    /// The shell's commands while the Source tab has focus (transport, marks, Insert / Overwrite / Replace / Fit to Fill);
    /// Insert / Overwrite and the Source edits also run from the timeline while a clip is loaded (PlaceSource).
    public func command(_ c: EditorCommand) -> Bool {
        let loaded = core.mediaID != nil
        let edit: MonitorAction? = switch c {
        case .insert: .insert
        case .overwrite: .overwrite
        case .fitToFill: .fitToFill
        case .replaceClipFromSource: .replace
        default: nil
        }
        if case .replaceMode(let mode) = c { return replaceWithMode(mode) }
        if c == .matchFrame { matchFrame(); return true }
        if c == .reverseMatchFrame { reverseMatchFrame(); return true }
        if c == .placeOnTop, loaded { core.edit(.overwrite, placeOnTop: true); return true }
        if let edit {
            guard loaded else { return false }
            core.perform(edit)
            return true
        }
        return isFocused && isShown && core.handle(c)
    }

    /// Clip > Replace and Fit > Replace Modes (the Mac AppController+ReplaceModes): the one selected clip plays the Source clip.
    func replaceWithMode(_ mode: ReplaceMode) -> Bool {
        guard let media = core.mediaID else {
            shell.onStatus?("Open a clip in the Source monitor first (double-click it in the Project panel).")
            return true
        }
        guard session.selection.count == 1, let clip = session.selection.first else {
            shell.onStatus?("Select one clip in the timeline to replace.")
            return true
        }
        core.pause()
        session.replaceOnMainTrack(clip, withMedia: media, mode: mode, sourceAnchor: core.currentTime)
        if let e = session.lastError { shell.onStatus?(e) }
        return true
    }
}
