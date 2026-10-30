import Foundation
import SQAppShell
import SQAudioFX
import SQCore
import SQDrawMonitor
import SQDrawTimeline
import SQEditorSession
import SQMediaFFmpeg

/// The Windows backend of the shared hosts' seams (Packages/SQAppShell AppPlatform.swift): comdlg32 choosers, the
/// D3D12 engine's picture and the WASAPI monitoring stages, the Source and two-up engines, the FFmpeg timeline media.
extension WinFilePicker: PanelFileChooser {}

/// The Scopes measure the composite on the D3D12 device (`WinProgramEngine.scopeCounts`).
extension WinProgramEngine: ScopeCountsSource {}

extension WinProgramEngine: AppMonitorEngine {
    var hasPicture: Bool { picture != nil }
    var player: any ProgramEngine { self }

    func scopePicture() -> AppPicture? {
        readablePicture().map { AppPicture(bytes: $0.bytes, width: $0.width, height: $0.height, fullRange: $0.fullRange, rgba: $0.rgba) }
    }

    func setMonitorGain(_ setting: MonitorGain.Setting) { audioOutput?.setMonitorGain(setting) }
    func setChannelMonitor(_ state: ChannelMonitor) { audioOutput?.setChannelMonitor(state) }

    /// shortcut: the shown composite (every layer at sequence size, the layer coverage of WinCompositor), not a
    /// full-size render; upgrade when WinProgramEngine takes a playback quality.
    func exportFrame(suggestedName: String, files: (any PanelFileChooser)?, status: @escaping @MainActor @Sendable (String) -> Void) {
        exportShownFrame(suggestedName: suggestedName, files: files, status: status)
    }
}

/// The Source monitor and the slip / trim two-up on the Program engine's D3D12 device (the one UI renderer samples their
/// pictures without a copy); sound through FFmpeg and WASAPI.
@MainActor
final class WinMonitorBackend: AppMonitorBackend {
    private let program: WinProgramEngine
    private let paths: PathStore

    init(program: WinProgramEngine, paths: PathStore) {
        self.program = program
        self.paths = paths
    }

    func makeSourceEngine() -> any AppMonitorEngine {
        let paths = paths
        return WinProgramEngine(audio: program.audioOutput != nil, device: program.gpu) { id in
            guard let path = paths.path(id) else { throw AppError("no file for media \(id)") }
            return try FFmpegAudioSource(url: URL(fileURLWithPath: path))
        }
    }

    func makeStillEngine() -> any AppMonitorEngine {
        WinProgramEngine(audio: false, device: program.gpu) { _ in throw AppError("the slip view plays no sound") }
    }

    var timelineMedia: (any TimelineMediaSource)? { winTimelineMedia }
}

extension AppController {
    /// The picture the window's video quad shows and a generation unique across both engines.
    var shownPicture: (picture: NV12Picture?, generation: Int) {
        guard source.isShown, let s = source.engine as? WinProgramEngine else { return (engine.picture, engine.pictureGeneration * 2) }
        return (s.picture, s.pictureGeneration * 2 + 1)
    }
}
