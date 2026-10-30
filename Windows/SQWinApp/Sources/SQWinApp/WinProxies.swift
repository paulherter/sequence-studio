import Foundation
import SQCore
import SQEditorSession
import SQExport
import SQFrame
import SQMedia
import SQMediaFFmpeg
import SQProxy
import Synchronization

/// Proxies on Windows, the Mac flow on SQProxy's portable parts: the same cache (fingerprint + kind, `<fp>.<kind>.mov`),
/// queue, provider and Auto rule; the files are ProRes 422 (optimized) or ProRes 422 Proxy (half, quarter) written through
/// FFmpeg (`FFmpegProxyTranscoder`). The Program engine reads them while scrubbing, and while playing when the proxy
/// playback setting says so (`WinProgramEngine.proxyContext`); paused frames and export read the original. Media is
/// looked at when the session syncs it (import, open) through the portable `ProxyIntake` (`session.autoProxy`).
/// Preferences: Cache Folder (at once, `moveCache`), Cache Size, Make proxies while you edit (`applySettings`).
@MainActor
final class WinProxies {
    static let shared = WinProxies()

    /// Replaced together when Preferences > Cache Folder moves (`moveCache`).
    private(set) var cache: ProxyCache
    private(set) var provider: ProxyProvider
    private(set) var queue: ProxyQueue
    /// Counts folder moves: only the last one switches once its copy is done.
    private var moveGeneration = 0
    private let store = ProxySettingsStore()
    /// The session's proxy service: probes imported and opened media and queues automatic proxies.
    let intake: ProxyIntake
    /// The Auto rule's answer per file (diagnostics; the headless check prints it).
    var decisions: [String: ProxyDecision] { intake.decisions }
    private var busy = false
    /// Playback is on: a running proxy job waits between frames (`ProxyFrameSource`), so its decode and encode do not
    /// take the cores the playing frames need (the hold only keeps new jobs from starting).
    nonisolated static let playing = Mutex(false)
    private var backgroundAllowed = true
    /// Off: files are fingerprinted but no automatic job is queued (headless checks time their own generation).
    static var automatic = true
    private var listeners: [UUID: @MainActor () -> Void] = [:]

    /// Set before first use: the headless proxy check's own folder.
    static var directoryOverride: URL?
    /// Overrides the proxy playback setting (headless checks; nil: `sq.proxy.playback`).
    var playbackOverride: Bool?

    /// `<Cache Folder>\Proxies` when Preferences picked one, else %LOCALAPPDATA%\SequenceStudio\Proxies
    /// (`StorageLocations.proxyDirectory`, the Mac rule).
    static var directory: URL {
        if let d = directoryOverride { return d }
        return AppSettings.load().locations(from: .standard).proxyDirectory
    }

    /// The PC's profile for the Auto rule. `isAppleSilicon` is true when the GPU decodes (D3D11VA): the flag stands for
    /// "hardware decode with a unified fast path", so only memory and cores make a PC weak, not the missing Apple chip.
    nonisolated static func machine(hardwareDecode: Bool) -> MachineProfile {
        MachineProfile(memoryBytes: ProcessInfo.processInfo.physicalMemory, cores: ProcessInfo.processInfo.activeProcessorCount,
                       isAppleSilicon: hardwareDecode)
    }

    private init() {
        let (c, p, q) = Self.makeCache(Self.directory)
        cache = c; provider = p; queue = q
        intake = ProxyIntake(provider: provider, queue: queue, automatic: Self.automatic,
                             machine: { Self.machine(hardwareDecode: $0) }, probe: Self.probe)
        listen(p)
        intake.onChange = { [weak self] in self?.notifyReady() }
        // Preferences > Cache Folder hands the move here instead of copying in the background for the next launch.
        StorageFolderChoice.movesProxiesAtOnce = { old, new in Task { @MainActor in WinProxies.shared.moveCache(from: old, to: new) } }
    }

    private static func makeCache(_ dir: URL) -> (ProxyCache, ProxyProvider, ProxyQueue) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = ProxyCache(directory: dir)
        // The transcoder refuses interlaced sources, so no woven proxy exists to settle.
        let provider = ProxyProvider(cache: cache, interlaced: { _ in false })
        let queue = ProxyQueue(cache: cache, transcoder: FFmpegProxyTranscoder())
        Task { await queue.start() }
        return (cache, provider, queue)
    }

    private func listen(_ p: ProxyProvider) {
        let events = p.readyEvents()
        Task { [weak self] in
            for await _ in events { self?.notifyReady() }
        }
    }

    /// Preferences > Cache Folder moved: the proxies of `old` are copied into `new` (never moved; the originals stay),
    /// then lookups, the queue and the intake switch to `new` at once (the Mac switches at the next launch). Engines
    /// reopen a proxy whose file moved on their next lookup.
    /// shortcut: a job running in the old folder is canceled and made again in the new one; keep it running and move
    /// its file over if long transcodes get canceled often.
    func moveCache(from old: URL, to new: URL) {
        moveGeneration += 1
        let generation = moveGeneration
        Task {
            _ = await Task.detached(priority: .utility) { StorageLocations.migrate(from: old, to: new) }.value
            defer { self.movesDone = max(self.movesDone, generation) }
            guard generation == self.moveGeneration else { return }
            self.switchCache(to: new)
        }
    }

    /// No folder move is copying (headless checks wait on it).
    var isMoving: Bool { movesDone != moveGeneration }
    private var movesDone = 0

    private func switchCache(to dir: URL) {
        guard dir.standardizedFileURL != cache.directory.standardizedFileURL else { return }
        let (c, p, q) = Self.makeCache(dir)
        cache = c; provider = p; queue = q
        listen(p)
        intake.retarget(provider: p, queue: q)
        applySettings(AppSettings.load())       // the cap and the hold on the new queue
        notifyReady()
    }

    /// Calls `f` on the main actor whenever a proxy becomes ready; returns the token for `removeListener`.
    func addListener(_ f: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        listeners[id] = f
        return id
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }

    private func notifyReady() { for f in listeners.values { f() } }

    /// Proxy playback (`sq.proxy.playback`): Auto uses proxies while playing on a weak PC.
    func usesProxiesForPlayback(hardwareDecode: Bool) -> Bool {
        if let playbackOverride { return playbackOverride }
        return AutoProxyRule.usesProxiesForPlayback(store.playback, machine: Self.machine(hardwareDecode: hardwareDecode))
    }

    /// The proxy to read for `path` now (stat-only; nil until the source was warmed and its proxy is ready).
    func lookup(_ path: String, context: ProxyUseContext, hardwareDecode: Bool) -> ProxyLookup? {
        let url = URL(fileURLWithPath: path)
        let settings = ProxySettings(cacheCapBytes: cache.settings.cacheCapBytes,
                                     useProxiesForPlayback: usesProxiesForPlayback(hardwareDecode: hardwareDecode))
        return provider.file(for: url, context: context, settings: settings)
    }

    /// The intake's probe: the FFmpeg index and track facts, and whether the GPU decodes the file (off the main actor).
    nonisolated static func probe(_ url: URL) async -> ProxySourceProbe? {
        guard let src = try? WinMediaSource(path: url.path, media: UUID()) else { return nil }
        let index = src.demuxer.index
        return ProxySourceProbe(seek: SourceSeekInfo(codecFourCC: SourceSeekInfo.fourCC(ffmpegCodec: src.info.codec),
                                                     syncFlags: index.entries.lazy.map(\.isSync)),
                                video: src.info, hardwareDecode: src.decoder.isHardware,
                                canMatch: ProxyIntake.proxyCanMatch(index))
    }

    /// Preferences > Media > Cache Size (the cap, least recently used proxies evicted at once, never one in use) and
    /// Preferences > Make proxies while you edit (off holds the queue), as the Mac `applyCacheCap` / `setHeld`.
    func applySettings(_ s: AppSettings) {
        let cap = s.cacheCapBytes
        if cache.settings.cacheCapBytes != cap { try? cache.updateSettings { $0.cacheCapBytes = cap } }
        _ = cache.enforceCap()
        backgroundAllowed = s.backgroundWork
        applyHold()
    }

    /// Queues `kind` for `path` now (Generate Proxy; headless checks).
    func generate(_ path: String, kind: ProxyKind) async throws {
        let url = URL(fileURLWithPath: path)
        let id = try await queue.enqueue(url, kind: kind, priority: .userInitiated)
        for await info in await queue.updates(for: id) where info.state.isTerminal {
            if case .failed(let why) = info.state { throw AppError("proxy of \(url.lastPathComponent): \(why)") }
            break
        }
        await provider.warm(url)
        notifyReady()
    }

    /// Holds background jobs while playback needs the decoder and disk (the Mac busy hold).
    func setBusy(_ busy: Bool) {
        self.busy = busy
        Self.playing.withLock { $0 = busy }
        applyHold()
    }

    private func applyHold() {
        let q = queue, held = busy || !backgroundAllowed
        Task { await q.setHeld(held) }
    }
}

/// `ProxyTranscoding` over FFmpeg: decodes the source (D3D11VA when the GPU can), box-reduces the pictures by the kind's
/// divisor (`WinMediaSource.picture`) and writes ProRes through the export encoder (`prores_ks`, 4:2:2 10-bit). Frame i of the proxy
/// is frame i of the source at the source's frame duration, so the engine maps a source index to the same proxy index.
/// shortcut: constant frame rate only (a variable-rate source is refused, the original plays), no deinterlacing (an
/// interlaced source is refused), sizes must divide by 2 x divisor; full-range sources are written as video range
/// pictures. Upgrade with an FFmpeg filter graph (yadif, scale) and per-frame pts when such media needs proxies.
struct FFmpegProxyTranscoder: ProxyTranscoding {
    func transcode(source: URL, kind: ProxyKind, destination: URL, timeRange: TimeRange?,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> TranscodeOutput {
        let src: WinMediaSource
        do { src = try WinMediaSource(path: source.path, media: UUID()) } catch {
            throw ProxyTranscodeError.readerFailed("\(error)")
        }
        let info = src.info
        guard src.frameCount > 0, info.width > 0 else { throw ProxyTranscodeError.noVideoTrack }
        if info.isInterlaced { throw ProxyTranscodeError.deinterlaceFailed }
        if info.isVariableFrameRate { throw ProxyTranscodeError.readerFailed("variable frame rate") }
        let d = kind.scaleDivisor
        guard info.width % (2 * d) == 0, info.height % (2 * d) == 0 else {
            throw ProxyTranscodeError.writerFailed("\(info.width)x\(info.height) does not divide by \(2 * d)")
        }
        let frames = ProxyFrameSource(source: src, divisor: d)
        var s = ExportSettings()
        s.video.codec = kind == .optimized ? .prores422 : .prores422Proxy
        s.video.width = info.width / d; s.video.height = info.height / d
        s.video.frameDuration = frames.frameDuration
        s.video.hardwareEncoding = false
        s.audio.enabled = false
        // The encoder writes ProRes only into a .mov path; the queue hands a `.partial` one.
        let mov = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".mov")
        defer { try? FileManager.default.removeItem(at: mov) }
        do {
            try await FFmpegExportEncoder().export(video: frames, audio: nil, settings: s, to: mov, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProxyTranscodeError.writerFailed("\(error)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: mov, to: destination)
        return TranscodeOutput(dimensions: ProxyDimensions(width: info.width / d, height: info.height / d),
                               sourceDuration: frames.frameDuration * Int64(src.frameCount))
    }
}

/// The source's pictures in order, reduced by `divisor` in the download: NV12, or P010 for 10-bit sources, memory frames
/// for the encoder.
final class ProxyFrameSource: FrameSource, @unchecked Sendable {
    let source: WinMediaSource
    let divisor: Int
    let frameCount: Int
    let frameDuration: Time
    /// Decoded ahead in batches; only the encoder's one task reads (frames come in order).
    private var ahead: [Int: NV12Picture] = [:]

    init(source: WinMediaSource, divisor: Int) {
        self.source = source; self.divisor = divisor
        frameCount = source.frameCount
        frameDuration = source.info.nominalFrameDuration
    }

    func frame(at index: Int) async throws -> ExportFrame {
        while WinProxies.playing.withLock({ $0 }) { try await Task.sleep(nanoseconds: 100_000_000) }
        if ahead[index] == nil {
            let last = min(frameCount - 1, index + 15)
            ahead = [:]
            for (i, p) in try await WinMediaSource.decodePictures(source.decoder, index...last, divisor: divisor) { ahead[i] = p }
        }
        guard let p = ahead.removeValue(forKey: index) else { throw ProxyTranscodeError.readerFailed("frame \(index) did not decode") }
        let deep = p.bitDepth > 8
        return SQFrame(width: p.width, height: p.height, pixelFormat: deep ? .p010 : .nv12, colorSpace: .rec709,
                       presentationTime: frameDuration * Int64(index),
                       storage: MemoryFrame(bytes: p.bytes, bytesPerRow: p.width * (deep ? 2 : 1)))
    }
}
