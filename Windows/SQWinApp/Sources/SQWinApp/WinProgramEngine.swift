import Foundation
import SQCore
import SQDrawKit
import SQAppShell
import SQEditorSession
import SQFrame
import SQGPUD3D12
import SQMedia
import SQMediaFFmpeg
import SQPlayback
import SQProxy
import SQRender
import SQText
import Synchronization

/// The pictures the monitor wants right now, readable from the decoding threads: a paused or scrubbing playhead moves on
/// faster than a long-GOP decode runs, so a queued decode asks (once the decoder is free) whether anything in its range is
/// still wanted and is dropped when not. Playback never drops: its ranges run ahead of the playhead on purpose.
final class WinWantGate: Sendable {
    private struct State { var indices: [UUID: Set<Int>] = [:]; var playing = false }
    private let state = Mutex(State())
    func set(_ keys: [(media: UUID, index: Int)], playing: Bool) {
        state.withLock { s in
            s.playing = playing
            s.indices = [:]
            for k in keys { s.indices[k.media, default: []].insert(k.index) }
        }
    }
    func isStale(media: UUID, range: ClosedRange<Int>) -> Bool {
        state.withLock { s in
            guard !s.playing else { return false }
            guard let wanted = s.indices[media] else { return true }
            return !wanted.contains { range.contains($0) }
        }
    }
}

/// One picture ready for the D3D12 shim: packed NV12 (luma, then interleaved chroma, stride = width), or with `rgba` the
/// composited Program picture as RGBA8 display code values (stride = width * 4). A composite stays on the GPU
/// (`texture`, `bytes` empty) until someone needs the bytes (`WinProgramEngine.readablePicture`).
struct NV12Picture: Sendable {
    var bytes: [UInt8]
    var width: Int, height: Int
    var fullRange: Bool
    var rgba = false
    /// `bytes` are 8-bit RGBA with straight alpha (footage with an alpha channel: QuickTime Animation, ProRes 4444), stride = width * 4.
    var straightRGBA = false
    var texture: GPUPicture?
    /// 8, or 10 for P010 bytes (16-bit little-endian samples, 10 bits MSB-aligned, stride = 2 x width).
    var bitDepth = 8

    /// The picture as 8-bit NV12 (the high byte of each P010 sample) for paths that only take 8-bit planes.
    var eightBit: NV12Picture {
        guard bitDepth > 8, !rgba, texture == nil else { return self }
        var out = [UInt8](repeating: 0, count: bytes.count / 2)
        bytes.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in for i in 0..<d.count { d[i] = s[i * 2 + 1] } }
        }
        return NV12Picture(bytes: out, width: width, height: height, fullRange: fullRange)
    }
}

/// A composited picture on the shared D3D12 device: the texture and its ID3D12Resource (already in a shader resource
/// state) for the UI renderer. Only touched on the main actor.
final class GPUPicture: @unchecked Sendable {
    let texture: D3D12GPUTexture
    let resource: UnsafeMutableRawPointer
    init(texture: D3D12GPUTexture, resource: UnsafeMutableRawPointer) { self.texture = texture; self.resource = resource }
}

/// The Windows Program engine: a host clock (or the audio device) drives the position, every video layer at that
/// position is decoded through the FFmpeg media layer and `WinCompositor` (SQRender's GPUCompositor on D3D12) draws the
/// frame like the Mac, on the device the window's UI renderer shares (the picture stays on the GPU). Without a D3D12
/// device the topmost video layer is shown as NV12.
@MainActor
final class WinProgramEngine: ProgramEngine {
    private(set) var timeline = Timeline(name: "", frameDuration: Time(1, 25))
    private var sequences: [Timeline.ID: Timeline] = [:]
    private(set) var position: Time = .zero
    private(set) var rate: PlaybackRate = .zero
    /// The monitor's playback quality (the Auto governor's step included): decoded pictures are box-reduced by it
    /// (`NV12Reduce`) before they are cached and uploaded. A change drops the cache and redraws.
    var quality: DecodeScale = .full {
        didSet {
            guard quality != oldValue else { return }
            cache = [:]
            playDivisors = [:]
            compositor?.dropPlanes()
            shown = nil
            refresh()
        }
    }
    /// Captions over the picture (monitor only), as the Mac RenderLoop draws them, in the caption library the session
    /// keeps current (`CaptionLookRegistry.setStyleKit`: one project per Windows process).
    var showsCaptions = true { didSet { if showsCaptions != oldValue { shown = nil; refresh() } } }
    var onPositionChange: (@MainActor (Time) -> Void)?
    /// Media id -> file path (the host refreshes it from the project with `setMedia`).
    var mediaPaths: [UUID: String] = [:]
    /// The project's media facts for the clip grades (source color space, LUTs), read on the resolver's queue.
    private let mediaInfos = MediaInfoTable()
    private(set) var mediaRefs: [MediaRef] = []
    private lazy var colorResolver: LayerColorResolver = WinMediaSource.colorResolver(mediaInfos)
    /// The D3D12 device of the compositor; the window's UI renderer is created on it (nil: no D3D12 hardware).
    let gpu: D3D12GPUDevice?

    /// The project's media: paths for decoding, infos for the grades.
    func setMedia(_ refs: [MediaRef]) {
        mediaRefs = refs
        let paths = Dictionary(refs.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        // A relinked item (Reconnect Media, the open relink of a copied project) reads from its new file; the open error
        // of its old path goes away with it.
        let moved = Set(paths.compactMap { id, p in mediaPaths[id].map { $0 == p ? nil : id } ?? nil })
        mediaPaths = paths
        mediaInfos.set(Dictionary(refs.map { ($0.id, $0.info) }, uniquingKeysWith: { a, _ in a }))
        mediaInfos.setPaths(Dictionary(refs.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a }))
        colorResolver.invalidate()
        if !moved.isEmpty {
            if lastError?.hasPrefix("open ") == true { lastError = nil }
            mediaChanged(moved)
        }
    }

    /// Redraws when a proxy becomes ready while one would be read. The session's proxy service (`WinProxies.intake`)
    /// looks at the media at import and open, so a file the engine opens is already warmed.
    private func considerProxy(_ path: String, _ src: WinMediaSource) {
        guard usesProxies, proxyListener == nil else { return }
        proxyListener = WinProxies.shared.addListener { [weak self] in
            guard let self else { return }
            self.proxyLookups = [:]
            guard self.proxyContext != .paused else { return }
            self.shown = nil
            self.refresh()
        }
    }

    /// The Mac `ProxyUse` contexts: scrubbing, playing, or paused (exact frames from the original).
    private var proxyContext: ProxyUseContext { warming ? .playback : scrubbing ? .scrubbing : rate.isPaused ? .paused : .playback }

    /// Decoder warm-up while paused: after the playhead rests 0.1 s, the layers at it decode their first playback
    /// frames (playback proxy and divisor), one layer per 80 ms once the last decode is done, so a play right after an
    /// open finds the decoders open, positioned and ahead instead of six 4K decoders starting at once.
    private var warming = false
    private var warmPosition: Time?
    private var warmSince: UInt64 = 0
    private var warmQueue: [Key] = []
    private var warmLast: UInt64 = 0

    private func warmStep() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let shown, shown == wanted, inFlight.isEmpty, opening.isEmpty, laneOpening.isEmpty else { return }
        if warmPosition != position {
            warmPosition = position
            warmSince = now
            warmQueue = []
            return
        }
        if warmSince != 0, now - warmSince >= 100_000_000 {
            warmSince = 0
            let seqs = sequences
            warming = true
            let layers = timeline.videoLayers(at: position, sequences: { seqs[$0] })
            let keys = layers.compactMap { key(for: $0) }
            warming = false
            // The grades of these layers are assembled (LUT files read, first-use setup) off the main thread now, so the
            // first play frame finds them served instead of stalling the window for 0.2 s.
            // The clips of the next 12 s too: a cut during play must not stall on its first-use grade either.
            var ahead = layers
            let fd = timeline.frameDuration
            var seenClips = Set(layers.map(\.clip))
            for half in 1...24 {
                let t = (position + fd * Int64((Double(half) * 0.5 * Double(fd.timescale) / Double(fd.value)).rounded())).snapped(to: fd)
                for l in timeline.videoLayers(at: t, sequences: { seqs[$0] }) where l.generator == nil && seenClips.insert(l.clip).inserted {
                    ahead.append(l)
                }
            }
            let resolver = colorResolver, warmLayers = ahead
            DispatchQueue.global(qos: .userInitiated).async {
                for l in warmLayers where l.generator == nil { _ = resolver.pipelineBlocking(for: l.color, media: l.media, owner: l.clip) }
            }
            var seen = Set<Key>()
            warmQueue = keys.filter { seen.insert($0).inserted }
            preopenProxies(seconds: 8)
        }
        if warmQueue.isEmpty, warmSince == 0, now - warmLast >= 300_000_000 {
            warmLast = now
            preopenProxies(seconds: 8)   // later clips: their files open (and proxies) a few times a second until all are open
        }
        guard !warmQueue.isEmpty, now - warmLast >= 80_000_000 else { return }
        warmLast = now
        let k = warmQueue.removeFirst()
        var claimed: [UUID: Set<Int>] = [:]
        warming = true
        request(k, ahead: 8, claimed: &claimed)
        warming = false
    }

    /// The picture to show now and a counter that changes with it.
    private(set) var picture: NV12Picture?
    private(set) var pictureGeneration = 0
    /// Playback statistics since the last `play`: frame positions shown and frame positions skipped.
    private(set) var shownFrames = 0
    private(set) var skippedFrames = 0
    /// The sequence frames the play statistics span: the one on screen at play, the last one shown.
    private(set) var playedSpan: (from: Int64, to: Int64)?
    private(set) var lastError: String?

    private let audio: WASAPIAudioEngine?
    private(set) var audioError: String?
    var audioUnavailable: Bool { audio == nil || audioError != nil }
    var audioDevice: String? { audio?.deviceName }
    var audioUnderruns: Int { audio?.underrunCount ?? 0 }
    /// Meter feed of the WASAPI output (the Mac PlaybackEngine's `meterReading` / `loudnessLevels`).
    var meterReading: (sequence: Int, peaks: [Float])? {
        guard let s = audio?.meterSnapshot() else { return nil }
        return (s.sequence, [s.left.peak, s.right.peak])
    }
    var loudnessLevels: LoudnessLevels? { audio?.meterSnapshot().loudness }
    func resetLoudnessMeter() { audio?.resetLoudnessMeter() }
    /// The speaker output, for the meter strip's listening volume, Dim and Solo/Mute stages.
    var audioOutput: WASAPIAudioEngine? { audio }

    private var sources: [UUID: WinMediaSource] = [:]
    /// Decoded pictures by (media, presentation index); a small window around the playhead.
    private var cache: [Key: NV12Picture] = [:] { didSet { cacheGeneration &+= 1 } }
    /// Changes with the frame cache (the ruler's cache strip polls `cachedSpans` only when it moved).
    private(set) var cacheGeneration = 0
    /// Preferences > Frame Cache: the Program monitor's share of `MemoryBudget.frameCacheBytes` (the cache is trimmed to
    /// the window around the playhead when it holds more).
    var frameCacheBytes = 1 << 30
    /// `proxy`: the picture comes from the media's proxy file (`proxySources`), same index as the original's.
    /// `divisor`: the picture is box-reduced by it against the original's size (playback quality and, while playing or
    /// scrubbing, `PlaybackLayerDetail`: a 4K clip drawn at half size decodes to a half-size picture).
    private struct Key: Hashable { let media: UUID; let index: Int; var proxy = false; var divisor = 1 }
    /// Media whose file is being opened off the main thread (a frame that needs one waits for it), and opens that failed
    /// (not tried again until the media changes).
    private var opening: Set<UUID> = []
    private var openFailed: [UUID: String] = [:]
    /// PNG stills by media, decoded with their transparency at open (the video decoder path is NV12: no alpha).
    private var stillImages: [UUID: RGBAImage] = [:]
    /// Window frames since the last look ahead at the clips coming up (`prefetch`).
    private var prefetchCountdown = 0
    private var prefetchKeys: [Key] = []
    /// The divisor each media plays at since play / scrub start: only ever lowered (more detail), so a scale keyframe
    /// that crosses a `PlaybackLayerDetail` step does not re-decode the same frames at the other size (and seek the
    /// decoder back) every time it crosses.
    private var playDivisors: [UUID: Int] = [:]
    /// Open proxy files by media: the file, its reader and its size divisor; `rejectedProxies` did not match the
    /// original's frames and are not opened again.
    private var proxySources: [UUID: (url: URL, source: WinMediaSource, divisor: Int)] = [:]
    private var rejectedProxies: Set<URL> = []
    /// `WinProxies.lookup` by media for one context: the lookup stats the file and locks the proxy cache (5 ms mean,
    /// up to 400 ms while the intake writes), too slow for every layer of every frame. Cleared when a proxy becomes
    /// ready, the media change, and at play (the proxy playback setting may have changed).
    private var proxyLookups: [UUID: (context: ProxyUseContext, look: ProxyLookup?)] = [:]
    private var scrubbing = false
    /// The shown frame reads at least one proxy picture.
    var showsProxy: Bool { shown?.keys.contains(where: \.proxy) == true }
    private var proxyListener: UUID?
    /// Proxies read while scrubbing and (per the proxy playback setting) while playing; off for headless checks that
    /// compare full-resolution pictures.
    var usesProxies = true {
        didSet { if usesProxies != oldValue { shown = nil; refresh() } }
    }
    private var inFlight: Set<Key> = []
    /// Pictures whose decode failed, with the time of the failure: the frame draws without that layer (a stuck picture
    /// froze the whole monitor while the clock ran) and the decode is not asked again for `failedRetry`.
    private var failedKeys: [Key: UInt64] = [:]
    private static let failedRetry: UInt64 = 3_000_000_000
    private func hasFailed(_ k: Key) -> Bool {
        guard let t = failedKeys[k] else { return false }
        if DispatchTime.now().uptimeNanoseconds - t > Self.failedRetry { failedKeys[k] = nil; return false }
        return true
    }
    /// The frame to show: its position and the decoded pictures it needs (bottom to top); `shown` is the one on screen.
    private struct Wanted: Equatable { let position: Time; let keys: [Key] }
    private var wanted: Wanted?
    private var shown: Wanted?
    /// The shown frame drew every picture at its own size (false: a stand-in of another size, `picture(for:)`).
    private var shownExact = true
    private var wantedRequests: [LayerRequest] = []
    private var compositor: WinCompositor?
    private var compositorFailed = false
    /// The shown picture's bytes, read back once per picture (scopes, Export Frame).
    private var readable: (generation: Int, picture: NV12Picture)?
    /// Milliseconds the compositor took for the shown frame.
    var composeMilliseconds: Double { compositor?.lastMilliseconds ?? 0 }
    /// Mean CPU milliseconds per composited frame since the last `play` (the play test's number).
    var meanComposeMilliseconds: Double { composeCount > 0 ? composeSum / Double(composeCount) : 0 }
    private var composeSum = 0.0, composeCount = 0
    /// The most frames the D3D12 device had in flight.
    var framesInFlightMax: Int { gpu?.inFlightMax ?? 0 }

    private var playStart: (host: UInt64, position: Time)?
    private(set) var lastShownFrame: Int64?

    /// View > Transparency Grid: the composite starts transparent and WinCompositor's Present pass lays it over the
    /// checkerboard (monitor only; `makeFrameSource` exports never see it).
    var showsTransparencyGrid = false {
        didSet { if showsTransparencyGrid != oldValue { shown = nil; refresh() } }
    }

    /// `device`: share another engine's D3D12 device (the Source monitor's engine uses the Program's, so the window's one
    /// UI renderer samples both pictures without a copy).
    init(audio enabled: Bool, device: D3D12GPUDevice? = nil, audioResolver: @escaping AudioFeeder.Resolver) {
        var gpuError: String?
        if let device { gpu = device } else {
            do { gpu = try D3D12GPUDevice() } catch { gpu = nil; gpuError = "D3D12: \(error)" }
        }
        lastError = gpuError
        if enabled {
            let a = WASAPIAudioEngine(resolver: audioResolver)
            do { try a.prepare() } catch { audioError = "\(error)" }
            audio = a
        } else {
            audio = nil
        }
    }

    // MARK: ProgramEngine

    func setDialogueSilences(_ provider: (any DialogueSilenceProvider)?) { audio?.setDialogueSilences(provider) }

    func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        self.timeline = timeline
        self.sequences = sequences
        audio?.setTimeline(timeline, sequences: sequences)
        warmPosition = nil
        wanted = nil
        shown = nil
        refresh()
    }

    func attach(_ layer: PreviewSurface?) {}

    func play(_ r: PlaybackRate) {
        guard !r.isPaused else { pause(); return }
        rate = r
        if usesProxies { WinProxies.shared.setBusy(true) }
        playStart = (DispatchTime.now().uptimeNanoseconds, position)
        // From the frame on screen: frames that never showed before the first new one count as dropped.
        shownFrames = 0; skippedFrames = 0; lastShownFrame = position.frameIndex(frameDuration: timeline.frameDuration)
        playedSpan = lastShownFrame.map { ($0, $0) }
        WinPlayStats.shared.reset()
        proxyLookups = [:]
        playDivisors = [:]
        composeSum = 0; composeCount = 0
        // The clock and the sound start when the picture at the playhead is on screen (`releaseClock`): a cold 4K file
        // needs 0.2 to 1 s for its first frame, and a clock that ran meanwhile left the decoder chasing a playhead it
        // never caught (black monitor with sound, until a click moved the playhead to a warm spot).
        clockHeldSince = DispatchTime.now().uptimeNanoseconds
        audio?.setRate(r)
    }

    /// Nanoseconds when a started play began waiting for its first picture; nil once the clock runs.
    private var clockHeldSince: UInt64?
    private static let clockHoldLimit: UInt64 = 2_000_000_000

    private func releaseClock() {
        clockHeldSince = nil
        playStart = (DispatchTime.now().uptimeNanoseconds, position)
        if let audio, audioError == nil {
            audio.seek(to: position)
            audio.start()   // every rate: |rate| != 1 keeps the pitch (ShuttleStretch in the WASAPI sink)
        }
    }

    func pause() {
        guard !rate.isPaused else { return }
        rate = .zero
        playStart = nil
        clockHeldSince = nil
        audio?.stop()
        if usesProxies { WinProxies.shared.setBusy(false) }
        onPositionChange?(position)
        refresh()   // the paused frame from the original at full detail (a no-op when the keys did not change)
    }

    func seek(to t: Time) { move(to: t) }
    func step(_ frames: Int) { pause(); move(to: position + timeline.frameDuration * Int64(frames)) }
    func beginScrub() { pause(); scrubbing = true; playDivisors = [:] }
    func scrub(to t: Time) { move(to: t) }
    func endScrub() {
        scrubbing = false
        // Preview pictures (software decoders without the loop filter) leave the cache; the exact ones decode again.
        for src in sources.values { src.setPreview(false) }
        for all in lanes.values { for l in all { l.source.setPreview(false) } }
        if !previewKeys.isEmpty { cache = cache.filter { !previewKeys.contains($0.key) }; previewKeys = []; shown = nil }
        refresh()
    }

    /// Color page Before / Split (the Mac RenderLoop): these clips drawn with their ungraded color (monitor only).
    private(set) var colorBypass: ColorBypass?
    func setColorBypass(_ bypass: ColorBypass?) {
        let value = bypass?.isEmpty == true ? nil : bypass
        guard value != colorBypass else { return }
        colorBypass = value
        shown = nil
        refresh()
    }

    func mediaChanged(_ ids: Set<UUID>) {
        for id in ids { sources[id] = nil; stillImages[id] = nil; proxySources[id] = nil; openFailed[id] = nil; proxyLookups[id] = nil; lanes[id] = nil; intraFiles[id] = nil }
        cache = cache.filter { !ids.contains($0.key.media) }
        audio?.mediaChanged(ids)
        refresh()
    }

    // MARK: Clock

    /// Called once per window frame: advances the playhead while playing and keeps decoding.
    func tick() {
        if let held = clockHeldSince {
            let waited = DispatchTime.now().uptimeNanoseconds - held
            if let w = wanted, shown == w || waited > Self.clockHoldLimit { releaseClock() }
            else if wanted == nil, waited > Self.clockHoldLimit { releaseClock() }
            else { refresh(); return }     // nothing moves while the first picture decodes
        }
        if let start = playStart {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.host) / 1e9
            let fd = timeline.frameDuration
            let speed = Double(rate.num) / Double(rate.den)
            let frames = Int64((elapsed * speed * Double(fd.timescale) / Double(fd.value)).rounded(.down))
            var t = start.position + fd * frames
            let end = timeline.tracks.map(\.end).max() ?? .zero
            if t >= end && speed > 0 { t = end > fd ? end - fd : .zero; move(to: t); pause(); return }
            if t <= .zero && speed < 0 { move(to: .zero); pause(); return }
            move(to: t)
        } else if scrubbing {
            if composePending, !movedSinceTick { compose() }
            movedSinceTick = false
        } else if rate.isPaused {
            warmStep()
        }
    }

    private func move(to t: Time) {
        let fd = timeline.frameDuration
        let snapped = max(.zero, t).snapped(to: fd)
        guard snapped != position || picture == nil else { refresh(); return }
        position = snapped
        movedSinceTick = true
        WinPlayStats.shared.time(.position) { onPositionChange?(snapped) }
        refresh()
    }

    /// Picks the frame for `position`: composites it when every picture it needs is decoded, else asks for them (and a few
    /// frames ahead while playing).
    private func refresh() {
        let planStart = DispatchTime.now().uptimeNanoseconds
        func ms(_ t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
        let seqs = sequences
        let requests = WinPlayStats.shared.time(.videoLayers) { timeline.videoLayers(at: position, sequences: { seqs[$0] }) }
        let keys = requests.compactMap { key(for: $0) }
        let want = Wanted(position: position, keys: keys)
        wanted = want
        wantedRequests = requests
        wantGate.set(keys.map { ($0.media, $0.index) }, playing: !rate.isPaused)
        let ahead = rate.isPaused ? 0 : 8
        refreshCount += 1
        if !rate.isPaused, refreshCount % 20 == 0 { preopenProxies(seconds: 4) }
        var claimed: [UUID: Set<Int>] = [:]
        // Lowest index first: of two layers of one file, the earlier one keeps the lane that is reading toward it.
        let t1 = DispatchTime.now().uptimeNanoseconds
        for k in Set(keys).sorted(by: { $0.index < $1.index }) { request(k, ahead: ahead, claimed: &claimed) }
        let dReq = ms(t1), t2 = DispatchTime.now().uptimeNanoseconds
        if !rate.isPaused { prefetch(&claimed) } else { prefetchKeys = [] }
        let dPre = ms(t2), t3 = DispatchTime.now().uptimeNanoseconds
        dropIdleLanes()
        let dIdle = ms(t3), t4 = DispatchTime.now().uptimeNanoseconds
        // The cache keeps what it holds up to the Preferences budget (the frames behind the playhead stay: the ruler's cache strip
        // and a step back use them); over it, the pictures farthest from this frame (and the clips coming up) go first, down to
        // three quarters of the budget so the trim does not run again at once.
        var total = 0
        for p in cache.values { total += p.bytes.count }
        if total > frameCacheBytes {
            let keep = keys + prefetchKeys
            func distance(_ k: Key) -> Int {
                var d = Int.max / 2
                for w in keep where w.media == k.media { d = min(d, abs(w.index - k.index)) }
                return d
            }
            // Each picture's distance once (not inside the sort's comparator: 60-75 ms with a full cache).
            let ranked = cache.keys.map { (key: $0, distance: distance($0)) }.sorted { $0.distance > $1.distance }
            var kept = cache
            var doomed: [NV12Picture] = []
            for r in ranked {
                guard total > frameCacheBytes / 4 * 3, let p = kept.removeValue(forKey: r.key) else { break }
                total -= p.bytes.count
                doomed.append(p)
            }
            cache = kept
            nonisolated(unsafe) let graveyard = doomed   // freeing a few hundred MB of pictures is not for the window's thread either
            DispatchQueue.global(qos: .utility).async { _ = graveyard.count }
        }
        if !rate.isPaused {
            let all = ms(planStart)
            WinPlayStats.shared.add(.plan, all)
            if all > 15 { NSLog("slow plan %.0f ms: request %.0f, prefetch %.0f, idle %.0f, trim %.0f", all, dReq, dPre, dIdle, ms(t4)) }
        }
        compose()
    }

    /// Decodes `k` and up to `ahead` frames after it that are neither cached nor on their way, on the lane of its file
    /// that reads toward it (`lane(for:)`).
    private func request(_ k: Key, ahead: Int, claimed: inout [UUID: Set<Int>], prefetching: Bool = false) {
        guard let src = lane(for: k, ahead: ahead, claimed: &claimed, prefetching: prefetching) else { return }
        let last = min(src.frameCount - 1, k.index + ahead)
        let missing = (k.index...max(k.index, last)).map { Key(media: k.media, index: $0, proxy: k.proxy, divisor: k.divisor) }
            .filter { cache[$0] == nil && !inFlight.contains($0) && !hasFailed($0) }
        if let first = missing.first { decode(src, k, first.index...missing.last!.index) }
    }

    /// While playing, every 10 refreshes: opens the files of the clips 0.5 to 3.5 s ahead and decodes their first
    /// frames there, so a cut does not wait for an open and a cold decoder. A picture a playing lane reads toward is
    /// left to it; a later cut in a file on screen warms a lane of its own.
    private func prefetch(_ claimed: inout [UUID: Set<Int>]) {
        prefetchCountdown -= 1
        guard prefetchCountdown <= 0 else { return }
        prefetchCountdown = 10
        let fd = timeline.frameDuration
        let speed = Double(rate.num) / Double(rate.den)
        let seqs = sequences
        var keys: [Key] = []
        for seconds in [0.5, 1.0, 1.5, 2.5, 3.5] {
            let frames = Int64((seconds * speed * Double(fd.timescale) / Double(fd.value)).rounded())
            let t = position + fd * frames
            guard t >= .zero else { continue }
            for l in timeline.videoLayers(at: t, sequences: { seqs[$0] }) where l.generator == nil {
                // A clip that starts before `t`: warm its first frame, where the cut lands.
                var first = l
                let start = t - l.localTime
                if start > position, start < t,
                   let s = timeline.videoLayers(at: start.snapped(to: fd), sequences: { seqs[$0] }).first(where: { $0.clip == l.clip }) {
                    first = s
                }
                if let k = key(for: first), !keys.contains(k) { keys.append(k) }
            }
        }
        prefetchKeys = keys
        for k in keys { request(k, ahead: 3, claimed: &claimed, prefetching: true) }
    }

    /// Draws the wanted frame once all its pictures are decoded (and no file it needs is still opening).
    private func compose() {
        composePending = false
        guard let want = wanted, shown != want || !shownExact, want.keys.allSatisfy({ picture(for: $0, standIn: true) != nil || hasFailed($0) }),
              opening.isEmpty || !wantedRequests.contains(where: { opening.contains($0.media) }) else { return }
        let captions = captionLayers()
        if want.keys.isEmpty && !showsTransparencyGrid && captions.isEmpty && !wantedRequests.contains(where: { $0.generator != nil }) {
            display(nil, want)
            return
        }
        if compositor == nil && !compositorFailed, let gpu {
            do { compositor = try WinCompositor(device: gpu) } catch { compositorFailed = true; lastError = "compositor: \(error)" }
        }
        guard let c = compositor else {
            display(want.keys.last.flatMap { picture(for: $0)?.eightBit }, want)
            return
        }
        c.clipDurations = WinCompositor.clipDurations(of: timeline, sequences: sequences)
        c.asyncCaptions = !rate.isPaused || scrubbing   // a scrub jumps: the last raster stands in, the exact one draws when the drag ends
        c.frameStep = timeline.frameDuration
        if c.asyncCaptions, refreshCount % 4 == 0 { prepareCaptions(c) }
        do {
            let resolver = colorResolver, bypass = colorBypass
            let graded: (LayerRequest) -> ColorPipeline? = { l in
                resolver.pipelineBlocking(for: l.color, media: l.media, owner: l.clip)
            }
            // Before: the bypassed clips ungraded; Split: graded, the ungraded composite over the left half.
            let ungraded: (LayerRequest) -> ColorPipeline? = { l in
                guard let u = bypass?.ungraded(l) else { return graded(l) }
                return resolver.pipelineBlocking(for: u.color, media: l.media, owner: u.owner)
            }
            let split = bypass?.isSplit == true
            let p = try c.render(wantedRequests, format: timeline.format, transparent: showsTransparencyGrid, captions: captions,
                                 grade: bypass == nil || split ? graded : ungraded,
                                 splitGrade: split ? ungraded : nil) { [self] l in
                guard let k = key(for: l), let pic = picture(for: k, standIn: true) else { return nil }
                return WinCompositor.Source(media: k.media, index: k.index, picture: pic, info: sources[k.media]!.info, proxy: k.proxy, still: stillImages[k.media])
            }
            if !rate.isPaused {
                composeSum += c.lastMilliseconds; composeCount += 1
                WinPlayStats.shared.add(.compose, c.lastMilliseconds)
                WinPlayStats.shared.frame(layers: want.keys.count, culled: 0)
            }
            display(p, want)
        } catch {
            lastError = "compose: \(error)"
        }
    }

    /// The decoded picture for `k`, or the same frame of the same file at another size (play start after a paused
    /// full-detail frame, a divisor change): the frame is right, only its detail differs until the exact one arrives.
    /// While playing (`standIn`), a frame still decoding shows the nearest decoded one of the same file (at most
    /// `standInReach` frames away) instead of nothing: the monitor keeps moving when the decoder is behind the clock, and
    /// the exact picture replaces it on arrival (`shownExact`).
    static let standInReach = 90
    private func picture(for k: Key, standIn: Bool = false) -> NV12Picture? {
        if let p = cache[k] { return p }
        if let p = cache.first(where: { $0.key.media == k.media && $0.key.index == k.index && $0.key.proxy == k.proxy })?.value { return p }
        guard standIn, !rate.isPaused || scrubbing else { return nil }
        let near = cache.filter { $0.key.media == k.media && $0.key.proxy == k.proxy && abs($0.key.index - k.index) <= Self.standInReach }
        // Playing: a frame the playhead has already passed, never one ahead of it (old frames from before a click would show
        // the picture jumping forward and back); scrubbing takes the nearest either way.
        if !scrubbing {
            let forward = rate.num >= 0
            let passed = near.filter { forward ? $0.key.index <= k.index : $0.key.index >= k.index }
            if let p = passed.min(by: { abs($0.key.index - k.index) < abs($1.key.index - k.index) })?.value { return p }
        }
        return near.min { abs($0.key.index - k.index) < abs($1.key.index - k.index) }?.value
    }

    /// While playing: draws the captions 0.5 s ahead of the playhead on the compositor's lane, so a cut to the next
    /// caption finds its first rasters ready.
    private func prepareCaptions(_ c: WinCompositor) {
        let fd = timeline.frameDuration
        prepareTitles(c, step: fd)
        guard showsCaptions, !timeline.captionTracks.isEmpty else { return }
        let ahead = position + fd * Int64(max(1, Int((0.5 * Double(fd.timescale) / Double(fd.value)).rounded())))
        let slots = timeline.captionSlots(at: ahead)
        guard !slots.isEmpty else { return }
        for l in CaptionLayerPlan.layers(timeline, slots: slots, at: ahead, library: CaptionLookRegistry.shared.library,
                                         forward: rate.num >= 0, units: { TextGenerator.portableUnits(ref: $0) }) {
            c.captionLane.prepare(ref: l.ref, localTime: l.localTime, duration: l.duration, step: fd, count: 4,
                                  canvas: timeline.format.layoutFormat)
        }
    }

    /// The text clips (titles, date stamps) 0.5 s and 1 s ahead render on the caption lane's worker, so a title that enters
    /// finds its raster done instead of drawing it (up to ~100 ms) inside the frame.
    private func prepareTitles(_ c: WinCompositor, step fd: Time) {
        let seqs = sequences
        let per = Int64(max(1, Int((0.5 * Double(fd.timescale) / Double(fd.value)).rounded())))
        for n in Int64(1)...2 {
            let t = position + fd * (per * n)
            for l in timeline.videoLayers(at: t, sequences: { seqs[$0] }) {
                guard let g = l.generator else { continue }
                guard let ref = g.kind == GeneratorRef.dateStamp ? DateStampText.textRef(for: g) : g else { continue }
                let dur = l.clipDuration ?? c.clipDurations[l.clip] ?? l.localTime
                c.captionLane.prepare(ref: ref, localTime: l.localTime, duration: dur, step: fd, count: 4,
                                      canvas: timeline.format.layoutFormat)
            }
        }
    }

    /// The caption layers at the playhead (`CaptionLayerPlan`, the Mac `RenderLoop.captionNodes`).
    private func captionLayers() -> [CaptionLayerRequest] {
        guard showsCaptions, !timeline.captionTracks.isEmpty else { return [] }
        let slots = timeline.captionSlots(at: position)
        guard !slots.isEmpty else { return [] }
        return CaptionLayerPlan.layers(timeline, slots: slots, at: position, library: CaptionLookRegistry.shared.library,
                                       forward: rate.num >= 0) { TextGenerator.portableUnits(ref: $0) }
    }

    /// The shown picture with its bytes (a GPU composite is read back once per picture): scopes and Export Frame.
    func readablePicture() -> NV12Picture? {
        guard let p = picture else { return nil }
        guard p.texture != nil, let compositor else { return p }
        if let r = readable, r.generation == pictureGeneration { return r.picture }
        let bytes = compositor.download(p)
        readable = (pictureGeneration, bytes)
        return bytes
    }

    /// The Scopes of the shown composite measured on the GPU (`ScopesPanel` takes these before the readback); nil while
    /// the monitor shows no GPU composite.
    func scopeCounts(pixelStride: Int) -> ScopeCounts? {
        guard picture?.texture != nil, let compositor else { return nil }
        return compositor.measureScopes(pixelStride: pixelStride)
    }

    /// True when the shown picture is the exact one for the playhead (no stand-in, nothing still opening): a frame capture
    /// taken now is the frame the user would see (Match Color to Clip waits for this after it solos a clip).
    var isPictureSettled: Bool {
        guard let w = wanted else { return picture?.texture != nil }
        return shown == w && shownExact && opening.isEmpty && picture?.texture != nil
    }

    /// The shown composite in working-linear Rec.709 (the Color page's eyedropper and Auto), `width` pixels wide by the
    /// picture's aspect (nil = sequence size); nil while the monitor shows no GPU composite.
    /// shortcut: Split reads the graded canvas, the Mac reads the split picture; match it if Auto on Split matters.
    func linearFrame(width: Int?) -> ProgramLinearFrame? {
        guard picture?.texture != nil, let compositor else { return nil }
        let f = timeline.format
        let size = width.flatMap { ProgramLinearFrame.scaledSize(width: $0, sourceWidth: f.width, sourceHeight: f.height) }
        guard let d = compositor.downloadLinear(size: size) else { return nil }
        return ProgramLinearFrame(halfRGBA: d.bytes, width: d.width, height: d.height)
    }

    /// An export frame source over the current sequence on the render actor's device (nil without D3D12).
    func makeFrameSource(range: TimeRange? = nil) async throws -> WinTimelineFrameSource? {
        guard gpu != nil else { return nil }
        let input = WinTimelineFrameSource.Input(timeline: timeline, sequences: sequences, range: range, media: mediaRefs)
        return try await WinTimelineFrameSource.make(input)
    }

    /// How many frames the shown picture is off the wanted one (largest over the layers); the scrub test's measure of a stand-in.
    private(set) var shownLag = 0

    private func display(_ p: NV12Picture?, _ want: Wanted) {
        shown = want
        shownLag = want.keys.map { k in
            cache[k] != nil ? 0 : (cache.keys.filter { $0.media == k.media && $0.proxy == k.proxy }.map { abs($0.index - k.index) }.min() ?? 0)
        }.max() ?? 0
        shownExact = want.keys.allSatisfy { cache[$0] != nil }
        picture = p
        readable = nil
        pictureGeneration += 1
        if !rate.isPaused {
            let frame = position.frameIndex(frameDuration: timeline.frameDuration)
            if let last = lastShownFrame, abs(frame - last) > 1 { skippedFrames += Int(abs(frame - last) - 1) }
            if frame != lastShownFrame { shownFrames += 1 }   // not again when the exact picture replaces a stand-in
            lastShownFrame = frame
            if let s = playedSpan { playedSpan = (s.from, frame) }
        }
    }

    private let wantGate = WinWantGate()

    private func decode(_ src: WinMediaSource, _ key: Key, _ range: ClosedRange<Int>) {
        let media = key.media, proxy = key.proxy, divisor = key.divisor
        let keys = range.map { Key(media: media, index: $0, proxy: proxy, divisor: divisor) }
        inFlight.formUnion(keys)
        let scale = quality
        let name = mediaPaths[media].map { URL(fileURLWithPath: $0).lastPathComponent } ?? "\(media)"
        // A proxy is already 1/2 or 1/4: the divisor reduces only what is left.
        let reduce = max(1, divisor / (proxy ? proxySources[media]?.divisor ?? 1 : 1))
        let gate = wantGate
        // Scrubbing a clip only software can decode: the decoder skips its loop filter (`FFmpegVideoDecoder.setPreview`).
        let preview = scrubbing && src.canPreview
        if scrubbing { src.setPreview(preview) }
        // Each picture goes to the main actor as soon as it is ready (the first frame does not wait for the batch).
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                try await src.streamPictures(range, divisor: reduce, isStale: { gate.isStale(media: media, range: range) }) { i, p in
                    Task { @MainActor in WinPlayStats.shared.time(.arrive) { self.decoded(Key(media: media, index: i, proxy: proxy, divisor: divisor), p, scale: scale, preview: preview) } }
                }
            } catch {
                failure = "decode \(name) \(range): \(error)"
            }
            let err = failure
            // Enqueued after the delivered pictures' tasks, so it sees them cached.
            Task { @MainActor in WinPlayStats.shared.time(.finish) { self.finished(keys, err) } }
        }
    }

    /// Keys whose cached picture came from a decoder in preview mode (scrubbing a heavy clip); dropped when the scrub ends.
    private var previewKeys: Set<Key> = []
    /// A scrub step has a picture it did not compose yet / the playhead moved since the last `tick`.
    private var composePending = false, movedSinceTick = false

    /// Sources larger than this (1080p plus a margin) scrub in preview mode (`mediaKey`, `setPreview`).
    static let previewPixels = 2_400_000
    private func decoded(_ key: Key, _ p: NV12Picture, scale: DecodeScale, preview: Bool = false) {
        inFlight.remove(key)
        if preview { guard scrubbing else { return }; previewKeys.insert(key) }
        guard scale == quality else { return }   // decoded for the quality before a change (the cache was dropped)
        // A long-GOP decode delivers every picture from the keyframe on; composing (and uploading a 4K stand-in) for each
        // one stalled the main thread many times per window frame. Compose only when this picture is wanted or is nearer
        // to a wanted one than anything cached.
        let useful = wanted?.keys.contains { w in
            guard w.media == key.media, w.proxy == key.proxy else { return false }
            if w == key { return true }
            let d = abs(key.index - w.index)
            return !cache.keys.contains { $0.media == w.media && $0.proxy == w.proxy && abs($0.index - w.index) <= d }
        } ?? true
        cache[key] = p
        guard useful else { return }
        // Scrubbing: the playhead moves every window frame and composes then; an arrival only marks the picture (tick draws it
        // when the playhead stood still), so one window frame never uploads and composes a 4K picture twice.
        if scrubbing { composePending = true } else { compose() }
    }

    private func dropProxy(_ media: UUID) {
        guard let path = mediaPaths[media], let p = proxySources[media] else { return }
        rejectedProxies.insert(p.url)
        proxySources[media] = nil
        if let look = proxyLookups[media]?.look { WinProxies.shared.discardCorrupt(look, source: path) }
        proxyLookups[media] = nil
        cache = cache.filter { !($0.key.media == media && $0.key.proxy) }
        shown = nil
    }

    /// A decode ended: keys it did not deliver are free to ask for again.
    private func finished(_ keys: [Key], _ error: String?) {
        let left = keys.filter { inFlight.contains($0) }
        inFlight.subtract(left)
        if let error {
            lastError = error
            let now = DispatchTime.now().uptimeNanoseconds
            // A proxy that cannot decode is dropped for the original; any other picture is skipped for a while.
            for media in Set(left.filter(\.proxy).map(\.media)) { dropProxy(media) }
            for k in left where cache[k] == nil && !k.proxy { failedKeys[k] = now }
            compose()
        }
        // A scrub drops most of its queued decodes as stale (nothing delivered): refreshing for each one planned and composed
        // the frame again, a 4K upload per dropped request. Refresh only when a picture the monitor still wants is missing.
        if !left.isEmpty, error != nil || !rate.isPaused || wanted?.keys.contains(where: { left.contains($0) }) != false { refresh() }
    }

    /// The decoded picture a media layer shows, as (media, presentation index); nil for generators and missing files.
    /// Timeline spans whose pictures are all decoded (the ruler's cache strip): the frames around the playhead the cache
    /// window covers, a gap or a clip with a missing picture ends a span. Generated layers (titles, mattes) need no picture.
    var cachedSpans: [TimeRange] {
        let fd = timeline.frameDuration
        let here = position.frameIndex(frameDuration: fd)
        let seqs = sequences
        // One lookup set for the whole scan, and a coarser scan while playing (the frames are on the main thread's budget).
        struct ID: Hashable { let media: UUID; let index: Int }   // a proxy's picture counts: it plays through the same gap
        var ids = Set<ID>()
        for k in cache.keys { ids.insert(ID(media: k.media, index: k.index)) }
        let playing = !rate.isPaused
        let stride: Int64 = playing ? 4 : 4
        let first = max(0, here - (playing ? 240 : 450)), last = here + (playing ? 120 : 450)
        var spans: [TimeRange] = []
        var open: Int64?
        func close(at f: Int64) { if let a = open { spans.append(TimeRange(start: fd * a, end: fd * f)); open = nil } }
        var f = first
        while f <= last {
            let layers = timeline.videoLayers(at: fd * f, sequences: { seqs[$0] })
            let ready = !layers.isEmpty && layers.allSatisfy { l in
                guard l.generator == nil else { return true }
                guard let k = mediaKey(for: l, remember: false) else { return false }
                return stillImages[l.media] != nil || ids.contains(ID(media: k.media, index: k.index))
            }
            if ready { if open == nil { open = f } } else { close(at: f) }
            f += stride
        }
        close(at: last + 1)
        return spans
    }

    private func key(for l: LayerRequest) -> Key? {
        guard l.generator == nil else { return nil }
        return WinPlayStats.shared.time(.key) { mediaKey(for: l) }
    }

    private func mediaKey(for l: LayerRequest, remember: Bool = true) -> Key? {
        guard l.generator == nil, let src = source(l.media) else { return nil }
        let index = src.frameIndex(at: l.sourceTime)
        var divisor = NV12Reduce.divisor(quality)
        if proxyContext != .paused {
            let d = min(playDivisors[l.media] ?? .max, max(divisor, PlaybackLayerDetail.divisor(for: l)))
            if remember { playDivisors[l.media] = d }
            divisor = d
        }
        // Scrub preview: a picture beyond 1080p is read at a quarter of each side (smaller download and upload per window
        // frame); the paused frame after the scrub is the normal, exact one.
        if scrubbing, src.info.width * src.info.height > Self.previewPixels { divisor = max(divisor, 4) }
        let proxy = proxySource(l.media, original: src) != nil
        // A ready proxy that is still opening: wait for it (refresh runs when it is open) instead of decoding the 4K original.
        if !proxy, proxyOpening.contains(l.media), proxyContext != .paused { return nil }
        return Key(media: l.media, index: index, proxy: proxy, divisor: divisor)
    }

    // MARK: Decoder lanes

    /// One decoder over a file and where it reads: `at` the last picture asked of it, `to` the last one it decodes.
    /// Two clips of one long-GOP file on screen at once (a cut back into the same take, a group that repeats it) each
    /// read on their own lane; on one decoder every frame would seek back to the other clip's GOP (1.5 s stalls measured
    /// on the Oppo project).
    private struct Lane { var source: WinMediaSource; var at: Int?; var to = -1; var used = 0 }
    /// Lanes by media, beyond the first one (`sources`), and their state; lane 0 is the open original, a proxy read has
    /// one lane (ProRes frames decode alone, a jump costs one frame).
    private var lanes: [UUID: [Lane]] = [:]
    private var laneOpening: Set<UUID> = []
    private var intraFiles: [UUID: Bool] = [:]
    private var refreshCount = 0
    /// A lane reads toward a picture that is at most this far past what it decodes.
    private static let laneReach = 45
    private static let maxLanes = 3

    /// The decoder for `k`: a lane not yet claimed in this frame that reads toward it, else a free lane (which seeks),
    /// else a new lane opened off the main thread (nil until it is open; at most `maxLanes` per file). A prefetch
    /// picture that any lane already reads toward is left to it (nil). Proxies and intra-only files read on one decoder.
    private func lane(for k: Key, ahead: Int, claimed: inout [UUID: Set<Int>], prefetching: Bool) -> WinMediaSource? {
        if k.proxy { return proxySources[k.media]?.source }
        guard let base = sources[k.media] else { return nil }
        if lanes[k.media] == nil { lanes[k.media] = [Lane(source: base)] }
        guard var all = lanes[k.media] else { return nil }
        if intraOnly(k.media, base) {
            // One decoder serves every clip of the file; a prefetch of a file on screen would only decode twice.
            if prefetching, claimed[k.media] != nil { return nil }
            claimed[k.media, default: []].insert(0)
            return base
        }
        let taken = claimed[k.media] ?? []
        func reaches(_ l: Lane) -> Bool { l.at.map { k.index >= $0 && k.index <= max($0, l.to) + Self.laneReach } ?? false }
        if prefetching, all.contains(where: reaches) { return nil }
        let free = all.indices.filter { !taken.contains($0) }
        let pick = free.first { reaches(all[$0]) } ?? free.first { all[$0].at == nil } ?? free.first
        guard let i = pick else {
            // Every lane serves another picture of this frame: open one more; past the limit (or for a prefetch while
            // one opens) a current picture shares lane 0, which seeks but keeps the frame coming.
            if all.count < Self.maxLanes { openLane(k.media); return nil }
            return prefetching ? nil : base
        }
        claimed[k.media, default: []].insert(i)
        if !reaches(all[i]) { all[i].to = k.index - 1 }   // this lane seeks
        all[i].at = k.index
        all[i].to = max(all[i].to, min(all[i].source.frameCount - 1, k.index + ahead))
        all[i].used = refreshCount
        lanes[k.media] = all
        return all[i].source
    }

    /// Starts opening one more lane of `media` (the picture waits for it; `refresh` when it is open).
    private func openLane(_ media: UUID) {
        guard let path = mediaPaths[media], !laneOpening.contains(media) else { return }
        laneOpening.insert(media)
        Task.detached(priority: .userInitiated) {
            let s = try? WinMediaSource(path: path, media: media)
            await MainActor.run {
                self.laneOpening.remove(media)
                guard let s, self.mediaPaths[media] == path, self.lanes[media] != nil else { return }
                self.lanes[media]?.append(Lane(source: s, used: self.refreshCount))
                self.prefetchCountdown = 0   // the prefetch that asked for it runs again now
                self.refresh()
            }
        }
    }

    /// Every frame of the file decodes alone (ProRes, MJPEG): a jump costs one frame, one decoder serves all clips.
    private func intraOnly(_ media: UUID, _ s: WinMediaSource) -> Bool {
        if let v = intraFiles[media] { return v }
        let v = s.demuxer.index.entries.allSatisfy(\.isSync)
        intraFiles[media] = v
        return v
    }

    /// Closes extra lanes no frame used for about 3 s (each holds a decoder with its frame threads and buffers).
    private func dropIdleLanes() {
        guard refreshCount % 30 == 0 else { return }
        for (m, all) in lanes where all.count > 1 {
            let stale = all.dropFirst().filter { refreshCount - $0.used >= 90 }
            guard !stale.isEmpty else { continue }
            lanes[m] = [all[0]] + all.dropFirst().filter { refreshCount - $0.used < 90 }
            // Closing a decoder (FFmpeg context, D3D11 frames) takes 15-30 ms: not on the window's thread.
            nonisolated(unsafe) let graveyard = stale
            DispatchQueue.global(qos: .utility).async { _ = graveyard.count }
        }
    }

    /// The media's ready proxy when the context reads proxies (`WinProxies.lookup`), opened once. A proxy is used only
    /// with the original's frames (same count and span), so index i of both is the same picture.
    private func proxySource(_ media: UUID, original: WinMediaSource) -> WinMediaSource? {
        guard usesProxies, let path = mediaPaths[media] else { return nil }
        let context = proxyContext
        let look: ProxyLookup?
        if let m = proxyLookups[media], m.context == context { look = m.look } else {
            look = WinProxies.shared.lookup(path, context: context, hardwareDecode: original.decoder.isHardware)
            proxyLookups[media] = (context, look)
        }
        guard let look, !rejectedProxies.contains(look.url) else { return nil }
        if let p = proxySources[media], p.url == look.url { return p.source }
        openProxy(media, look: look, path: path, original: original)
        return nil
    }

    private var proxyOpening: Set<UUID> = []

    /// Opens the proxy off the main thread (the open reads the index and starts a decoder: ~0.3 s, which stalled the
    /// first frames of a play); until it is open the picture reads the original, `refresh` runs when it is done.
    private func openProxy(_ media: UUID, look: ProxyLookup, path: String, original: WinMediaSource) {
        guard !proxyOpening.contains(media) else { return }
        proxyOpening.insert(media)
        let originalIndex = original.demuxer.index
        let playing = !rate.isPaused
        Task.detached(priority: .userInitiated) {
            let openedAt = DispatchTime.now().uptimeNanoseconds
            let p = try? WinMediaSource(path: look.url.path, media: media)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - openedAt) / 1e6
            WinPlayStats.shared.add(.proxyOpen, ms)
            StartupLog.note("proxy open \(look.url.lastPathComponent) \(Int(ms)) ms, playing \(playing)")
            let ok = p.map { Self.sameFrames(proxy: $0.demuxer.index, original: originalIndex) } ?? false
            let intact = ok && p.map(Self.proxyIsIntact) == true
            await MainActor.run {
                self.proxyOpening.remove(media)
                guard self.mediaPaths[media] == path else { return }
                guard let p, intact else {
                    self.rejectedProxies.insert(look.url)
                    if ok { WinProxies.shared.discardCorrupt(look, source: path) }
                    self.refresh()
                    return
                }
                self.proxySources[media] = (look.url, p, look.scaleDivisor)
                self.shown = nil
                self.refresh()
            }
        }
    }

    /// Opens the proxies of the media the playhead reaches in the next `seconds`, so a play or a cut finds them open.
    private func preopenProxies(seconds: Int) {
        guard usesProxies else { return }
        let seqs = sequences
        let wasWarming = warming
        warming = true
        defer { warming = wasWarming }
        var seen = Set<UUID>()
        for s in 0...seconds {
            let t = position + Time(Int64(s), 1)
            for l in timeline.videoLayers(at: t, sequences: { seqs[$0] }) where l.generator == nil && seen.insert(l.media).inserted {
                if let src = source(l.media) { _ = proxySource(l.media, original: src) }
            }
        }
    }

    /// Every sampled frame of the proxy starts like a ProRes frame (size, then "icpf"): a proxy written by two processes at
    /// once or cut short holds stretches of other bytes, which the decoder rejects frame after frame.
    nonisolated static func proxyIsIntact(_ p: WinMediaSource) -> Bool {
        guard let heads = p.demuxer.sampleHeads(count: 24, prefix: 8) else { return false }
        return heads.allSatisfy { $0.count == 8 && $0[4] == 0x69 && $0[5] == 0x63 && $0[6] == 0x70 && $0[7] == 0x66 }
    }

    /// The proxy holds the original's frames: the same count over the same span (the proxy starts at zero, an original
    /// may start later: `ProxyPicture.hasOriginalFrameTimes` compares absolute times, the index mapping needs only this).
    nonisolated static func sameFrames(proxy: SampleIndex, original: SampleIndex) -> Bool {
        let a = proxy.entries, b = original.entries
        guard let a0 = a.first, let a1 = a.last, let b0 = b.first, let b1 = b.last, a.count == b.count else { return false }
        return a1.pts - a0.pts == b1.pts - b0.pts
    }

    /// The media's open file; nil while it opens (on a detached task: an open reads the index and starts a decoder,
    /// up to 400 ms for a 4K file, which stalled playback on the main thread) or when it failed to open.
    private func source(_ media: UUID) -> WinMediaSource? {
        if let s = sources[media] { return s }
        guard let path = mediaPaths[media], openFailed[media] == nil, !opening.contains(media) else { return nil }
        opening.insert(media)
        Task.detached(priority: .userInitiated) {
            let result = Result { try WinMediaSource(path: path, media: media) }
            let still = Self.stillImage(path)
            await MainActor.run { if let still { self.stillImages[media] = still }; self.opened(media, path, result) }
        }
        return nil
    }

    /// A PNG file's straight RGBA (nil for other files and PNGs `PortablePNG` cannot read: those stay on the decoder path).
    nonisolated private static func stillImage(_ path: String) -> RGBAImage? {
        guard path.lowercased().hasSuffix(".png"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let png = PortablePNG.decode(data) else { return nil }
        return RGBAImage(width: png.width, height: png.height, pixels: png.rgba)
    }

    private func opened(_ media: UUID, _ path: String, _ result: Result<WinMediaSource, any Error>) {
        opening.remove(media)
        guard mediaPaths[media] == path else { refresh(); return }   // relinked while opening: open the new file
        switch result {
        case .success(let s):
            sources[media] = s
            considerProxy(path, s)
        case .failure(let error):
            openFailed[media] = "\(error)"
            lastError = "open \(path): \(error)"
        }
        refresh()
    }

    /// Playing and the frame at the playhead is not on screen yet (its pictures are still decoding).
    /// The monitor shows the exact pictures of the wanted frame (not a nearby stand-in); for the scrub test.
    var isShowingExactFrame: Bool { shown == wanted && shownExact }
    var isWaitingForFrame: Bool { !rate.isPaused && wanted != nil && shown != wanted }

    /// Blocks until the picture at `position` is decoded (headless checks).
    func waitForPicture(timeout: Double = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let w = wanted, shown == w, shownExact, opening.isEmpty { return true }
            if wanted == nil { return false }
            if scrubbing { tick() }   // a scrub composes in the window frame; headless there is none
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return false
    }
}

/// Media id -> project media info, shared with the color resolver's queue.
final class MediaInfoTable: @unchecked Sendable {
    private let lock = NSLock()
    private var infos: [UUID: MediaInfo?] = [:]
    private var paths: [UUID: String] = [:]
    func set(_ t: [UUID: MediaInfo?]) { lock.lock(); infos = t; lock.unlock() }
    /// Media id -> file path (the camera LUT embedded in a clip is read from the file).
    func setPaths(_ t: [UUID: String]) { lock.lock(); paths = t; lock.unlock() }
    func path(_ id: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return paths[id] }
    func info(_ id: UUID) -> MediaInfo? { lock.lock(); defer { lock.unlock() }; return infos[id] ?? nil }
}
