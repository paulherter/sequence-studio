import AppKit
import AVFoundation
import Metal
import SQAppShell
import SQAudioFX
import SQCore
import SQDrawKit
import SQDrawTimeline
import SQEditorSession
import SQMedia
import SQMonitorUI
import SQPlayback
import Synchronization

/// The Mac backend of the shared monitor card (SQAppShell `AppMonitorBackend`): the Source monitor's own PlaybackEngine
/// (with an AudioEngine, presenting into `sourceViewer`) and the layerless engines of the slip / trim two-up, all on the
/// session's ProjectMediaResolver; thumbnails and waveforms from `MacTimelineMedia`.
@MainActor
final class MacMonitorBackend: AppMonitorBackend {
    private let device: MTLDevice?
    private let media: ProjectMediaResolver
    let mediaStore: MacTimelineMedia
    /// The Source picture: its engine's CAMetalLayer, placed like the Program viewer when the Source tab shows.
    let sourceViewer = ViewerView(frame: .zero)
    var window: () -> NSWindow? = { nil }
    /// The audio engines made here (the Source monitor's): Settings > Audio Output points them at the chosen device.
    private(set) var audioEngines: [AudioEngine] = []

    init(device: MTLDevice?, media: ProjectMediaResolver, mediaStore: MacTimelineMedia) {
        self.device = device
        self.media = media
        self.mediaStore = mediaStore
    }

    /// Every engine made here is told to the session: relinks and proxy swaps reach it like the Program engine.
    var registerEngine: ((any ProgramEngine) -> Void)?

    func makeSourceEngine() -> any AppMonitorEngine {
        let tap = MacPictureTap(engine: engine(audio: true))
        tap.window = { [weak self] in self?.window() }
        tap.player.attach(sourceViewer.metalLayer)
        return tap
    }

    func makeStillEngine() -> any AppMonitorEngine { MacPictureTap(engine: engine(audio: false), layerless: true) }

    var timelineMedia: (any TimelineMediaSource)? { mediaStore }

    private func engine(audio: Bool) -> any ProgramEngine {
        guard let device else { return StubProgramEngine() }
        do {
            let out = audio ? AudioEngine(media: media) : nil
            if let out {
                out.setOutputDevice(uid: AppSettings.load().audioOutputUID)
                audioEngines.append(out)
            }
            let e = try PlaybackEngine(device: device, media: media, audio: out)
            registerEngine?(e)
            return e
        } catch {
            SQLog.error("shared UI: monitor engine unavailable: \(error)")
            return StubProgramEngine()
        }
    }
}

/// The Timeline panel's media on the Mac shared UI: peaks from `WaveformBuilder.build` (vDSP, the disk cache), thumbnails from
/// the AVFoundation `Thumbnailer` packed into the shared `ThumbnailAtlas` (image slot `thumbnailSlot`, the renderer turns
/// it into a CGImage when its generation moves). Also the Project panel's posters and the start screen's card pictures
/// (files outside the project get a loose id per path). The Windows twin is WinTimelineMedia.
final class MacTimelineMedia: TimelineMediaSource, Sendable {
    static let thumbnailSlot = 0
    /// Thumbnail decodes in flight; more requests wait for the next frame's ask.
    static let maxInFlight = 16

    private struct State {
        var paths: [UUID: String] = [:]
        var loose: [String: UUID] = [:]
        var waveforms: [UUID: WaveformData] = [:]
        var started: Set<UUID> = []
        var atlas = ThumbnailAtlas(slot: MacTimelineMedia.thumbnailSlot)
        var queued: Set<ThumbnailAtlas.Key> = []
        var failed: Set<UUID> = []
        /// Bumped when a path value changes (Reconnect Media keeps the count) or the offline set changes.
        var pathsRevision = 0
        var offline: Set<UUID> = []
        var offlineChecked = Date.distantPast
    }
    private let state = Mutex(State())
    private let thumbnailer = Thumbnailer()

    /// The project's media changed: the path table the decodes read.
    func set(_ project: Project) {
        let map = Dictionary(project.media.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        state.withLock { s in
            if s.paths != map { s.pathsRevision += 1 }
            s.paths = map
        }
    }

    /// A stable id for a file outside the project (start screen posters).
    func id(forPath path: String) -> UUID {
        state.withLock { s in
            if let id = s.loose[path] { return id }
            let id = UUID()
            s.loose[path] = id
            return id
        }
    }

    private func path(_ id: UUID) -> String? {
        state.withLock { s in s.paths[id] ?? s.loose.first { $0.value == id }?.key }
    }

    func waveform(media: UUID) -> WaveformData? {
        let (ready, start) = state.withLock { s -> (WaveformData?, Bool) in
            if let w = s.waveforms[media] { return (w, false) }
            return (nil, s.started.insert(media).inserted)
        }
        if start, let p = path(media) {
            Task.detached { [self] in
                guard let wf = try? await WaveformBuilder.build(url: URL(fileURLWithPath: p)) else { return }
                state.withLock { $0.waveforms[media] = wf }
            }
        }
        return ready
    }

    func isOffline(media: UUID) -> Bool {
        guard let p = state.withLock({ $0.paths[media] }) else { return false }
        return !FileManager.default.fileExists(atPath: p)
    }

    func picture(media: UUID, at: Time?) -> TimelinePicture? {
        // The poster is the first frame (key 0), like a frame request at media time zero.
        let ms = at.map { Int(max($0.value, 0) * 1000 / max($0.timescale, 1)) } ?? 0
        let key = ThumbnailAtlas.Key(media: media, frame: ms)
        let (picture, start) = state.withLock { s -> (TimelinePicture?, Bool) in
            if let p = s.atlas.picture(for: key) { return (p, false) }
            guard !s.failed.contains(media), !s.queued.contains(key), s.queued.count < Self.maxInFlight else { return (nil, false) }
            s.queued.insert(key)
            return (nil, true)
        }
        if start {
            guard let p = path(media) else {
                state.withLock { $0.queued.remove(key); $0.failed.insert(media) }
                return nil
            }
            let thumbnailer = thumbnailer
            Task.detached { [self] in
                let cg = try? await thumbnailer.thumbnail(media: media, url: URL(fileURLWithPath: p),
                                                          at: CMTime(value: CMTimeValue(ms), timescale: 1000), height: 90,
                                                          exact: false)
                let frame = cg.flatMap(Self.rgba)
                state.withLock { s in
                    s.queued.remove(key)
                    if let frame { s.atlas.insert(key, frame: frame) } else { s.failed.insert(media) }
                }
            }
        }
        return picture
    }

    /// Changes whenever a path, waveform, thumbnail or failure arrives: the timeline replays its cached clip layer until then.
    var drawRevision: Int? {
        state.withLock { s in
            // Files appear and vanish while the app runs: look again at most once a second, and only a change bumps the revision.
            if Date().timeIntervalSince(s.offlineChecked) >= 1 {
                s.offlineChecked = Date()
                let now = Set(s.paths.filter { !FileManager.default.fileExists(atPath: $0.value) }.keys)
                if now != s.offline { s.offline = now; s.pathsRevision += 1 }
            }
            var h = Hasher()
            h.combine(s.pathsRevision)
            h.combine(s.paths.count); h.combine(s.waveforms.count); h.combine(s.failed.count); h.combine(s.atlas.generation)
            return h.finalize()
        }
    }

    /// The atlas for the renderer: (slot, image, generation).
    var thumbnailImage: (Int, RGBAImage, Int) {
        state.withLock { (Self.thumbnailSlot, $0.atlas.image, $0.atlas.generation) }
    }

    /// A thumbnail as 8-bit RGBA rows (premultiplied, opaque video).
    static func rgba(_ image: CGImage) -> RGBAImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RGBAImage(width: w, height: h, pixels: px) : nil
    }
}
