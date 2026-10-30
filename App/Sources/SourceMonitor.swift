import AppKit
import SQCore
import SQEditorUI
import SQPlayback
import SQRender

/// The Source monitor on the Mac: the shared `SourceMonitorCore` (SQDrawMonitor: loading, transport, marks, edits,
/// menu) plus the AppKit view, the Metal viewer, the picture drag, the Fit Clip sheet and the full-size Export Frame.
@MainActor
final class SourceMonitorController: SourceMonitorCore {
    let view: MonitorPanelView
    let viewer = ViewerView(frame: .zero)

    /// Shared peak store (the timeline's); set by the panels. Feeds the audio-only view.
    var waveforms: TimelineWaveforms?

    init(session: EditorSession, engine: any ProgramEngine) {
        let model = MonitorPanelModel(frameDuration: Time(1, 30), mode: .source)
        view = MonitorPanelView(model: model)
        super.init(session: session, engine: engine, model: model)
        attachView()
    }

    private func attachView() {
        engineWrapsLoops = engine is PlaybackEngine
        viewer.drivesLayer = false
        viewer.translatesAutoresizingMaskIntoConstraints = true
        viewer.frame = view.viewerSlot.bounds
        viewer.autoresizingMask = [.width, .height]
        view.viewerSlot.addSubview(viewer, positioned: .below, relativeTo: nil)
        engine.attach(viewer.metalLayer)
        viewer.onResize = { [weak self] in self?.engine.redraw() }
        // Audio-only media: the waveform view shows the source player's own level meter (the stub engine has none).
        if let pe = engine as? PlaybackEngine {
            view.waveformView.meterReading = { [weak pe] in
                guard let pe, let r = pe.meterReading else { return nil }
                return (ObjectIdentifier(pe), r.sequence, r.peaks)
            }
            view.waveformView.meter.onChannelMonitorChange = { [weak pe] m in pe?.audio?.setChannelMonitor(m) }
        }
        waveformProvider = { [weak self] id in
            guard let self, let waveforms, let ref = session.project.media(id) else { return nil }
            waveforms.request(ref.id, project: session.project, urgent: true)   // jumps the import's waveform queue
            return waveforms.data[id]
        }
        model.dragItem = { [weak self] streams in
            guard let self, let id = mediaID else { return nil }
            dragStreams = streams
            let item = NSPasteboardItem()
            item.setString(ProjectPanelModel.encodeItems([.media(id)]), forType: .sequenceMediaIDs)
            return item
        }
        chooseFourPointFit = { [weak self] done in
            guard let window = self?.view.window else { done(FourPointFitChoice.saved()); return }
            FourPointFitSheet.present(over: window) { done($0) }
        }
    }

    /// A full-size render (not the viewer quality or a weak Mac's half-size preview decode).
    override func exportFrame() {
        guard mediaID != nil else { return }
        pause()
        let name = mediaID.flatMap { session.project.media($0)?.name } ?? "Frame"
        let base = (name as NSString).deletingPathExtension
        // The task holds the engine (bounded by its timeout), never this controller.
        let engine = self.engine
        Task { @MainActor in
            await engine.withFullSizeFrame { [weak self] result in
                guard let self else { return }
                FrameExport.run(result, suggestedName: base + ".png", on: self.view.window, status: { [weak self] in self?.onStatus?($0) })
            }
        }
    }
}
