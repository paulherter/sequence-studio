import Foundation
import SQCore
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

/// One picture ready for the D3D12 shim: packed NV12 (luma, then interleaved chroma, stride = width), or with `rgba` the
/// composited Program picture as RGBA8 display code values (stride = width * 4). A composite stays on the GPU
/// (`texture`, `bytes` empty) until someone needs the bytes (`WinProgramEngine.readablePicture`).
struct NV12Picture: Sendable {
    var bytes: [UInt8]
    var width: Int, height: Int
    var fullRange: Bool
    var rgba = false
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
            let keys = timeline.videoLayers(at: position, sequences: { seqs[$0] }).compactMap { key(for: $0) }
            warming = false
            var seen = Set<Key>()
            warmQueue = keys.filter { seen.insert($0).inserted }
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
    private var cache: [Key: NV12Picture] = [:]
    /// Preferences > Frame Cache: the Program monitor's share of `MemoryBudget.frameCacheBytes` (the cache is trimmed to
    /// the window around the playhead when it holds more).
    var frameCacheBytes = Int.max
    /// `proxy`: the picture comes from the media's proxy file (`proxySources`), same index as the original's.
    /// `divisor`: the picture is box-reduced by it against the original's size (playback quality and, while playing or
    /// scrubbing, `PlaybackLayerDetail`: a 4K clip drawn at half size decodes to a half-size picture).
    private struct Key: Hashable { let media: UUID; let index: Int; var proxy = false; var divisor = 1 }
    /// Media whose file is being opened off the main thread (a frame that needs one waits for it), and opens that failed
    /// (not tried again until the media changes).
    private var opening: Set<UUID> = []
    private var openFailed: [UUID: String] = [:]
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
    private var lastShownFrame: Int64?

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
        if let audio, audioError == nil {
            audio.setRate(r)
            audio.seek(to: position)
            audio.start()   // every rate: |rate| != 1 keeps the pitch (ShuttleStretch in the WASAPI sink)
        }
    }

    func pause() {
        guard !rate.isPaused else { return }
        rate = .zero
        playStart = nil
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
        for id in ids { sources[id] = nil; proxySources[id] = nil; openFailed[id] = nil; proxyLookups[id] = nil; lanes[id] = nil; intraFiles[id] = nil }
        cache = cache.filter { !ids.contains($0.key.media) }
        audio?.mediaChanged(ids)
        refresh()
    }

    // MARK: Clock

    /// Called once per window frame: advances the playhead while playing and keeps decoding.
    func tick() {
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
        } else if rate.isPaused, !scrubbing {
            warmStep()
        }
    }

    private func move(to t: Time) {
        let fd = timeline.frameDuration
        let snapped = max(.zero, t).snapped(to: fd)
        guard snapped != position || picture == nil else { refresh(); return }
        position = snapped
        WinPlayStats.shared.time(.position) { onPositionChange?(snapped) }
        refresh()
    }

    /// Picks the frame for `position`: composites it when every picture it needs is decoded, else asks for them (and a few
    /// frames ahead while playing).
    private func refresh() {
        let planStart = DispatchTime.now().uptimeNanoseconds
        let seqs = sequences
        let requests = WinPlayStats.shared.time(.videoLayers) { timeline.videoLayers(at: position, sequences: { seqs[$0] }) }
        let keys = requests.compactMap { key(for: $0) }
        let want = Wanted(position: position, keys: keys)
        wanted = want
        wantedRequests = requests
        let ahead = rate.isPaused ? 0 : 8
        refreshCount += 1
        var claimed: [UUID: Set<Int>] = [:]
        // Lowest index first: of two layers of one file, the earlier one keeps the lane that is reading toward it.
        for k in Set(keys).sorted(by: { $0.index < $1.index }) { request(k, ahead: ahead, claimed: &claimed) }
        if !rate.isPaused { prefetch(&claimed) } else { prefetchKeys = [] }
        dropIdleLanes()
        // Keep the cache to a window around the pictures of this frame (and the clips coming up).
        if cache.count > 48 || cache.values.reduce(0, { $0 + $1.bytes.count }) > frameCacheBytes {
            let keep = keys + prefetchKeys
            cache = cache.filter { c in
                keep.contains { $0.media == c.key.media && c.key.index >= $0.index - 4 && c.key.index <= $0.index + 24 }
            }
        }
        if !rate.isPaused { WinPlayStats.shared.add(.plan, Double(DispatchTime.now().uptimeNanoseconds - planStart) / 1e6) }
        compose()
    }

    /// Decodes `k` and up to `ahead` frames after it that are neither cached nor on their way, on the lane of its file
    /// that reads toward it (`lane(for:)`).
    private func request(_ k: Key, ahead: Int, claimed: inout [UUID: Set<Int>], prefetching: Bool = false) {
        guard let src = lane(for: k, ahead: ahead, claimed: &claimed, prefetching: prefetching) else { return }
        let last = min(src.frameCount - 1, k.index + ahead)
        let missing = (k.index...max(k.index, last)).map { Key(media: k.media, index: $0, proxy: k.proxy, divisor: k.divisor) }
            .filter { cache[$0] == nil && !inFlight.contains($0) }
        if let first = missing.first { decode(src, k, first.index...missing.last!.index) }
    }

    /// While playing, every 10 refreshes: opens the files of the clips 0.5, 1 and 1.5 s ahead and decodes their first
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
        for seconds in [0.5, 1.0, 1.5] {
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
        guard let want = wanted, shown != want || !shownExact, want.keys.allSatisfy({ picture(for: $0) != nil }),
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
                guard let k = key(for: l), let pic = picture(for: k) else { return nil }
                return WinCompositor.Source(media: k.media, index: k.index, picture: pic, info: sources[k.media]!.info, proxy: k.proxy)
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
    private func picture(for k: Key) -> NV12Picture? {
        if let p = cache[k] { return p }
        return cache.first { $0.key.media == k.media && $0.key.index == k.index && $0.key.proxy == k.proxy }?.value
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

    private func display(_ p: NV12Picture?, _ want: Wanted) {
        shown = want
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

    private func decode(_ src: WinMediaSource, _ key: Key, _ range: ClosedRange<Int>) {
        let media = key.media, proxy = key.proxy, divisor = key.divisor
        let keys = range.map { Key(media: media, index: $0, proxy: proxy, divisor: divisor) }
        inFlight.formUnion(keys)
        let scale = quality
        // A proxy is already 1/2 or 1/4: the divisor reduces only what is left.
        let reduce = max(1, divisor / (proxy ? proxySources[media]?.divisor ?? 1 : 1))
        // Each picture goes to the main actor as soon as it is ready (the first frame does not wait for the batch).
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                try await src.streamPictures(range, divisor: reduce) { i, p in
                    Task { @MainActor in self.decoded(Key(media: media, index: i, proxy: proxy, divisor: divisor), p, scale: scale) }
                }
            } catch {
                failure = "\(error)"
            }
            let err = failure
            // Enqueued after the delivered pictures' tasks, so it sees them cached.
            Task { @MainActor in self.finished(keys, err) }
        }
    }

    private func decoded(_ key: Key, _ p: NV12Picture, scale: DecodeScale) {
        inFlight.remove(key)
        guard scale == quality else { return }   // decoded for the quality before a change (the cache was dropped)
        cache[key] = p
        compose()
    }

    /// A decode ended: keys it did not deliver are free to ask for again.
    private func finished(_ keys: [Key], _ error: String?) {
        let left = keys.filter { inFlight.contains($0) }
        inFlight.subtract(left)
        if let error { lastError = error }
        if !left.isEmpty { refresh() }
    }

    /// The decoded picture a media layer shows, as (media, presentation index); nil for generators and missing files.
    private func key(for l: LayerRequest) -> Key? {
        guard l.generator == nil else { return nil }
        return WinPlayStats.shared.time(.key) { mediaKey(for: l) }
    }

    private func mediaKey(for l: LayerRequest) -> Key? {
        guard l.generator == nil, let src = source(l.media) else { return nil }
        let index = src.frameIndex(at: l.sourceTime)
        var divisor = NV12Reduce.divisor(quality)
        if proxyContext != .paused {
            let d = min(playDivisors[l.media] ?? .max, max(divisor, PlaybackLayerDetail.divisor(for: l)))
            playDivisors[l.media] = d
            divisor = d
        }
        return Key(media: l.media, index: index, proxy: proxySource(l.media, original: src) != nil, divisor: divisor)
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
            lanes[m] = [all[0]] + all.dropFirst().filter { refreshCount - $0.used < 90 }
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
        guard let p = WinPlayStats.shared.time(.proxyOpen, { try? WinMediaSource(path: look.url.path, media: media) }),
              Self.sameFrames(proxy: p.demuxer.index, original: original.demuxer.index) else {
            rejectedProxies.insert(look.url)
            return nil
        }
        proxySources[media] = (look.url, p, look.scaleDivisor)
        return p
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
            await MainActor.run { self.opened(media, path, result) }
        }
        return nil
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
    var isWaitingForFrame: Bool { !rate.isPaused && wanted != nil && shown != wanted }

    /// Blocks until the picture at `position` is decoded (headless checks).
    func waitForPicture(timeout: Double = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let w = wanted, shown == w, shownExact, opening.isEmpty { return true }
            if wanted == nil { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return false
    }
}

/// Media id -> project media info, shared with the color resolver's queue.
final class MediaInfoTable: @unchecked Sendable {
    private let lock = NSLock()
    private var infos: [UUID: MediaInfo?] = [:]
    func set(_ t: [UUID: MediaInfo?]) { lock.lock(); infos = t; lock.unlock() }
    func info(_ id: UUID) -> MediaInfo? { lock.lock(); defer { lock.unlock() }; return infos[id] ?? nil }
}
