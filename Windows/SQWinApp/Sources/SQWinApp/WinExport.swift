import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQExport
import SQFrame
import SQMedia
import SQMediaFFmpeg
import SQPlayback
import SQProxy
import SQUIKit

/// File > Export on Windows: the shell's Export form (SQDrawShell `ShellExport` over the Mac `ExportDialogModel`) gets its
/// sources here (the Mac `ExportCoordinator.makeModel` provider): the picture from `WinTimelineFrameSource` (FFmpeg
/// decode, D3D12 compositor), the mix from the portable `TimelineAudioSource` over FFmpeg audio, written by
/// `FFmpegExportEncoder` (H.264 / HEVC in MP4 or MOV, every ProRes in MOV, AAC or PCM; audio-only M4A / WAV / FLAC,
/// animated GIF, image sequences) through the shared `ExportQueue`. Stems: one mix per audio role through the same
/// encoder (the Mac `ExportCoordinator` stem provider).
/// Burn-in captions draw through `CaptionLayerPlan` (as the Program monitor).
/// The mix and the stems use the tracks' audio presets (`InspectorHost.audioPresets`) and the project's live ducking, as
/// the Mac `ExportCoordinator` does.
/// shortcut: no dialogue-silence release for live ducking (the Mac waits for the dialogue waveforms), no proxies or
/// render cache; add them once the Windows session builds those.
extension AppController {
    func wireExport() {
        shell.exportQueue = ExportQueue(encoder: FFmpegExportEncoder())
        // The popover's background section: proxy and optimized-media jobs (the Mac `ProxyJobSource`).
        shell.backgroundJobs = {
            let q = WinProxies.shared.queue
            return await q.allJobs().compactMap { info in
                switch info.state { case .queued, .running: break; default: return nil }
                let what = info.kind == .optimized ? "Optimized media" : "Proxy"
                return ExportQueuePopover.Background(
                    id: "\(info.id)", title: SQL10n.format("%@: %@", SQL10n.string(what), info.source.lastPathComponent),
                    progress: info.state == .running ? info.progress : 0)
            }
        }
        shell.cancelBackgroundJob = { id in
            let q = WinProxies.shared.queue
            Task { for info in await q.allJobs() where "\(info.id)" == id { await q.cancel(info.id) } }
        }
        shell.exportCodecs = [.h264, .hevc, .prores422HQ, .prores422, .prores422LT, .prores422Proxy, .prores4444]
        shell.exportFileOutputs = true
        if let videos = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            shell.exportDirectory = videos
        }
        let session = self.session, engine = self.engine, inspector = self.inspector
        shell.configureExport = { model in
            let project = session.project
            let presets = inspector.audioPresets, ducking = project.liveDucking
            let timelines = Dictionary(project.timelines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let resolver = WinExportAudioResolver(project.media)
            model.stemPlans = timelines.mapValues { StemPlan.stems(for: $0) }.filter { !$0.value.isEmpty }
            model.stemEncoder = FFmpegExportEncoder()
            model.stemAudio = { _, stem, range in
                TimelineAudioSource(timeline: stem.timeline, sequences: timelines, range: range, presets: presets,
                                    liveDucking: ducking, resolver: resolver)
            }
            // The sheet's picture (the Mac `ExportCoordinator.makeModel` preview): the export's own compositor at the
            // preview's small size, silent. Only the session read runs on the main actor; the source is made and renders
            // on `WinRenderActor`, while the sheet shows "Loading preview…".
            model.previewSource = { id, settings in
                let input = try await MainActor.run { try AppController.frameInput(id, settings, session: session, engine: engine) }
                let t0 = Date()
                let source = try await WinTimelineFrameSource.make(input)
                if AppController.printTiming {
                    print(String(format: "timing: export preview source %.0f ms (render actor)", Date().timeIntervalSince(t0) * 1000))
                }
                return source
            }
        }
        shell.exportFrameImage = { frame in AppController.rgbaImage(frame) }
        shell.exportSources = { id, settings in
            let (input, audio) = try await MainActor.run {
                let project = session.project
                let input = try AppController.frameInput(id, settings, session: session, engine: engine)
                guard settings.audio.enabled || settings.audioOnly != nil else { return (input, nil as TimelineAudioSource?) }
                let tl = input.timeline
                let audio = TimelineAudioSource(timeline: tl, sequences: input.sequences,
                                                range: input.range ?? TimeRange(start: .zero, duration: tl.duration),
                                                presets: inspector.audioPresets, liveDucking: project.liveDucking,
                                                resolver: WinExportAudioResolver(project.media))
                return (input, audio)
            }
            let video = try await WinTimelineFrameSource.make(input)
            return ExportSources(video: video, audio: audio)
        }
    }
}

extension AppController {
    /// `--shell-test` prints how long the steps behind a dialog take (set once before the window opens).
    nonisolated(unsafe) static var printTiming = false

    /// What the frame source of sequence `id` needs (the export and the sheet's preview), read from the session.
    static func frameInput(_ id: UUID, _ settings: ExportSettings, session: EditorSession, engine: WinProgramEngine)
        throws -> WinTimelineFrameSource.Input {
        guard engine.gpu != nil else { throw AppError("Export needs a Direct3D 12 graphics card") }
        let project = session.project
        guard let view = project.variantView(of: id, variant: settings.variant) else {
            throw AppError("The sequence is no longer in the project")
        }
        var all = Dictionary(project.timelines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (k, v) in view.sequences { all[k] = v }
        let range: TimeRange? = if case .inOut(let r) = settings.range { r } else { nil }
        return WinTimelineFrameSource.Input(timeline: view.timeline, sequences: all, range: range, media: project.media,
                                            width: settings.video.width, height: settings.video.height,
                                            captions: settings.captions == .burnIn,
                                            linear: { if case .sequence? = settings.frameOutput { true } else { false } }())
    }

    /// A preview frame (8-bit RGBA or BGRA in memory) as the RGBA pixels of an image slot; nil for other layouts.
    nonisolated static func rgbaImage(_ frame: SQFrame) -> RGBAImage? {
        guard let m = frame.storage as? MemoryFrame, frame.width > 0, frame.height > 0,
              frame.pixelFormat == .rgba8 || frame.pixelFormat == .bgra8,
              m.bytesPerRow >= frame.width * 4, m.bytes.count >= m.bytesPerRow * frame.height else { return nil }
        let w = frame.width, h = frame.height, bgra = frame.pixelFormat == .bgra8
        if !bgra, m.bytesPerRow == w * 4 { return RGBAImage(width: w, height: h, pixels: Array(m.bytes.prefix(w * h * 4))) }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        m.bytes.withUnsafeBufferPointer { src in
            for y in 0..<h {
                let row = y * m.bytesPerRow
                for x in 0..<w {
                    let i = row + x * 4, o = (y * w + x) * 4
                    px[o] = src[i + (bgra ? 2 : 0)]; px[o + 1] = src[i + 1]; px[o + 2] = src[i + (bgra ? 0 : 2)]; px[o + 3] = src[i + 3]
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: px)
    }
}

/// The media audio the export mix reads: FFmpeg audio sources by media id (offline media throw and play silent).
struct WinExportAudioResolver: MediaResolver {
    private let paths: [UUID: String]
    init(_ media: [MediaRef]) { paths = Dictionary(media.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a }) }
    func demuxer(for media: UUID) throws -> any Demuxing { throw MediaResolverError.unknownMedia(media) }
    func audio(for media: UUID) throws -> any SQMedia.AudioSource {
        guard let p = paths[media] else { throw MediaResolverError.unknownMedia(media) }
        return try FFmpegAudioSource(url: URL(fileURLWithPath: p))
    }
    func fileURL(for media: UUID) -> URL? { paths[media].map { URL(fileURLWithPath: $0) } }
}
