import Foundation
import Synchronization
import SQCore
import SQMedia
import SQAudioFX

/// Mixes `Timeline.audioSegments` from `AudioSource`s into a `RingBuffer` at the mixer rate (48 kHz), in play direction.
///
/// Per-track buses: every audio track mixes (with its clip volume) into its own bus, optionally runs through its own
/// `RealtimeAudioFX` (compressor/denoiser, preset per track via `setTracks` / `setPreset`), is delay-compensated and only
/// then summed. Clip/track volume lives here in the feeder; the FX instances get a unity `VolumeAutomation` so volume is never
/// applied twice. Consequence: volume is applied before the compressor (offline chain: after), a known difference.
///
/// Nested sequences: segments of a nested audio clip mix into the bus of the top-level track that holds the nested clip
/// (its FX, mute and solo apply); gain = inner clip volume (inner time) x `AudioSegment.nestGain`. Inner tracks' presets are ignored.
///
/// Latency: a denoiser adds 480 samples. Every track is delayed to the maximum FX latency `M` so all tracks stay aligned;
/// the ring output is therefore `M` samples behind the timeline position (`outputLatencySamples`, the clock subtracts it).
/// A denoiser stays allocated while its track has a preset once created (mix 0 = dry), so sliding the amount never changes `M`.
///
/// Reverse: the FX state assumes increasing time, so in reverse each bus is time-reversed first and then runs in play order
/// with the FX bypassed (compressor off, denoiser dry; same latency through the FX's own delay). Volume is evaluated forward
/// on the absolute 256-frame grid before the reversal, i.e. for descending time it is exact. Every generation change (seek)
/// resets all FX state and delay lines.
/// Everything here runs on one thread (the feeder thread, or the test); only `setTimeline`, `seek`, `start`, `stop` are
/// callable from other threads. Sources are expected at the mixer rate already (resampled upstream by `AssetAudioSource`).
public final class AudioFeeder: @unchecked Sendable {
    public typealias Resolver = @Sendable (UUID) throws -> any AudioSource

    public let sampleRate: Int
    public let blockFrames: Int
    public let ring: RingBuffer
    private let resolver: Resolver

    /// One audio track: its mix buffer, optional FX and compensation delay. The FX is thread-safe to re-parameterise;
    /// everything else here is touched by the feeder thread only.
    final class TrackBus: @unchecked Sendable {
        let fx: RealtimeAudioFX?
        let denoiser: Bool
        let extraDelay: Int
        let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>
        let ptrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        private let dl: UnsafeMutablePointer<Float>, dr: UnsafeMutablePointer<Float>
        private var dpos = 0
        private var appliedReverse: Bool?

        init(fx: RealtimeAudioFX?, denoiser: Bool, extraDelay: Int, blockFrames: Int) {
            self.fx = fx; self.denoiser = denoiser; self.extraDelay = extraDelay
            func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, n)); p.initialize(repeating: 0, count: max(1, n)); return p
            }
            l = alloc(blockFrames); r = alloc(blockFrames); dl = alloc(extraDelay); dr = alloc(extraDelay)
            ptrs = .allocate(capacity: 2); ptrs[0] = l; ptrs[1] = r
        }
        deinit { l.deallocate(); r.deallocate(); dl.deallocate(); dr.deallocate(); ptrs.deallocate() }

        func reset() {
            fx?.reset()
            dl.update(repeating: 0, count: max(1, extraDelay)); dr.update(repeating: 0, count: max(1, extraDelay)); dpos = 0
        }

        /// In place, in play order.
        func process(count: Int, reverse: Bool, startSample: Int64) {
            if let fx {
                if appliedReverse != reverse { fx.setBypass(reverse); appliedReverse = reverse }
                fx.process(ptrs, frameCount: count, timelineSample: startSample)
            }
            guard extraDelay > 0 else { return }
            for i in 0..<count {
                let a = dl[dpos], b = dr[dpos]
                dl[dpos] = l[i]; dr[dpos] = r[i]; l[i] = a; r[i] = b
                dpos += 1; if dpos == extraDelay { dpos = 0 }
            }
        }
    }

    struct BusSet: Sendable {
        var list: [TrackBus] = []
        var index: [UUID: Int] = [:]
        var latency = 0
    }

    /// Caller-side bookkeeping (under `config`): presets, and the FX/bus objects kept across rebuilds so unchanged tracks keep state.
    private struct FXConfig {
        var presets: [UUID: TrackAudioPreset] = [:]
        var trackIDs: [UUID] = []
        var fxs: [UUID: (fx: RealtimeAudioFX, denoiser: Bool)] = [:]
        var buses: [UUID: TrackBus] = [:]
        /// Latency the running feeder compensates to. Changes only with `commit` (at a seek), never mid-play.
        var committedLatency = 0

        mutating func rebuild(blockFrames: Int, commit: Bool = false) -> BusSet {
            var newFx: [UUID: (fx: RealtimeAudioFX, denoiser: Bool)] = [:]
            for id in trackIDs {
                guard let preset = presets[id] else { continue }
                let old = fxs[id]
                let dn = preset.noiseReduction > 0 || (old?.denoiser ?? false)
                if let old, old.denoiser == dn { old.fx.setPreset(preset); newFx[id] = old; continue }
                // Unity volume: clip/track volume is applied by the feeder, never twice.
                if let fx = try? RealtimeAudioFX(preset: preset, volume: VolumeAutomation(), channelCount: 2,
                                                 maxFrames: blockFrames, denoiser: dn) {
                    newFx[id] = (fx, dn)
                }
            }
            fxs = newFx
            if commit { committedLatency = trackIDs.map { newFx[$0]?.fx.latencySamples ?? 0 }.max() ?? 0 }
            let m = committedLatency
            var set = BusSet(latency: m), newBuses: [UUID: TrackBus] = [:]
            for id in trackIDs {
                // An FX whose latency exceeds the committed one waits (track plays dry) until the next seek commits it.
                let e = newFx[id].flatMap { $0.fx.latencySamples <= m ? $0 : nil }
                let extra = m - (e?.fx.latencySamples ?? 0)
                let bus: TrackBus
                if let old = buses[id], old.fx === e?.fx, old.extraDelay == extra { bus = old }
                else { bus = TrackBus(fx: e?.fx, denoiser: e?.denoiser ?? false, extraDelay: extra, blockFrames: blockFrames) }
                newBuses[id] = bus
                set.index[id] = set.list.count; set.list.append(bus)
            }
            buses = newBuses
            return set
        }
    }
    private let config: Mutex<FXConfig>

    private struct Control {
        var timeline: Timeline
        var position: Int64 = 0         // timeline frame where the next block starts (forward) or ends (reverse)
        var reverse = false
        var generation = 0              // bumped by seek; blocks mixed under an older generation are dropped
        var running = false
        var buses = BusSet()
        var sequences: [Timeline.ID: Timeline] = [:]   // nested sequences, by id
    }
    private let flushState = Mutex<(generation: Int, epoch: Int, latency: Int)>((0, 0, 0))
    /// Lock-free copy of `flushed.generation` for the audio render thread; stored after the ring flush and before any
    /// push of that generation, so once it is >= g the ring holds nothing mixed before generation g.
    public let flushGeneration = FlushGeneration()
    private let control: Mutex<Control>
    private var sources: [UUID: any AudioSource] = [:]
    private let retimer: AudioRetimer
    private let mixL: UnsafeMutablePointer<Float>, mixR: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>
    /// Segments whose source failed to open or read (they render as silence; playback continues).
    public let failedReads = Atomic<Int>(0)
    private var thread: Thread?
    private var appliedGeneration = 0           // feeder thread only
    var afterMixHook: (() -> Void)?          // test seam: runs between mixing a block and committing it

    public init(timeline: Timeline, ring: RingBuffer, sampleRate: Int = 48_000, blockFrames: Int = 1024,
                resolver: @escaping Resolver) {
        precondition(sampleRate == RealtimeAudioFX.sampleRate, "AudioFeeder/RealtimeAudioFX run at 48 kHz only")
        self.sampleRate = sampleRate; self.blockFrames = blockFrames; self.ring = ring; self.resolver = resolver
        retimer = AudioRetimer(maxFrames: blockFrames)
        var cfg = FXConfig()
        cfg.trackIDs = timeline.tracks.filter { $0.kind == .audio }.map(\.id)
        var c = Control(timeline: timeline)
        c.buses = cfg.rebuild(blockFrames: blockFrames, commit: true)
        control = Mutex(c)
        config = Mutex(cfg)
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames); p.initialize(repeating: 0, count: blockFrames); return p
        }
        mixL = alloc(); mixR = alloc(); scratch = alloc(); outL = alloc(); outR = alloc()
    }
    deinit {
        stop()
        for p in [mixL, mixR, scratch, outL, outR] { p.deallocate() }
    }

    // MARK: control

    /// `sequences` resolves nested audio clips (id -> timeline, e.g. `Dictionary(uniqueKeysWithValues: project.timelines.map { ($0.id, $0) })`).
    /// Passing `nil` keeps the current set.
    public func setTimeline(_ t: Timeline, sequences: [Timeline.ID: Timeline]? = nil) {
        let ids = t.tracks.filter { $0.kind == .audio }.map(\.id)
        // Rebuild and publish under one `config` lock: interleaved callers can never publish an older set last.
        config.withLock { c in
            c.trackIDs = ids
            let set = c.rebuild(blockFrames: blockFrames)
            control.withLock { $0.timeline = t; $0.buses = set; if let sequences { $0.sequences = sequences } }
        }
    }

    /// Replaces all per-track presets (tracks without one have no FX). Builds FX objects on the calling thread; the feeder
    /// thread picks the new set up at its next block. Call off the audio render path (main actor is fine).
    public func setTracks(_ presets: [Track.ID: TrackAudioPreset]) {
        config.withLock { c in
            c.presets = presets
            let set = c.rebuild(blockFrames: blockFrames)
            control.withLock { $0.buses = set }
        }
    }

    /// Sets or clears (`nil`) one track's preset. Same threading as `setTracks`.
    public func setPreset(track: Track.ID, preset: TrackAudioPreset?) {
        config.withLock { c in
            c.presets[track] = preset
            let set = c.rebuild(blockFrames: blockFrames)
            control.withLock { $0.buses = set }
        }
    }

    /// Samples the ring output lags behind the timeline position (the committed max FX latency). It changes only at a seek
    /// (see `flushed.latency`), never mid-play: a new denoiser waits and its track plays dry until then.
    public var outputLatencySamples: Int { control.withLock { $0.buses.latency } }

    /// Feeder-side flush bookkeeping for the clock: `epoch` is the ring flush epoch issued when the feeder applied `generation`
    /// (the value `seek` returned), `latency` the `outputLatencySamples` valid from that flush on. Once `ring.consumedAtEpoch.epoch >= epoch` the clock can re-base exactly.
    public var flushed: (generation: Int, epoch: Int, latency: Int) { flushState.withLock { $0 } }

    /// New anchor: flushes the ring and restarts production at `frame` (timeline frames at the mixer rate).
    /// In reverse, `frame` is the exclusive upper end of the first block, so frame `frame - 1` plays first.
    /// Callable from any thread: only bumps the generation. The feeder thread flushes the ring itself when it sees
    /// the new generation, so the ring keeps a single producer.
    /// Returns the new generation (see `flushed`).
    @discardableResult
    public func seek(to frame: Int64, reverse: Bool) -> Int {
        control.withLock { $0.position = frame; $0.reverse = reverse; $0.generation += 1; return $0.generation }
    }

    /// Timeline frame the next produced block is anchored at (for tests and clock anchoring).
    public var position: Int64 { control.withLock { $0.position } }

    public func start() {
        let already = control.withLock { c -> Bool in let r = c.running; c.running = true; return r }
        if already { return }
        let t = Thread { [weak self] in
            while let self, self.control.withLock({ $0.running }) {
                if self.fill() == 0 { Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        t.name = "AudioFeeder"; t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        control.withLock { $0.running = false }
        thread = nil
    }

    // MARK: producing

    /// Mixes and pushes blocks while the ring has room for a whole block. Returns the number of blocks pushed.
    /// Reverse play mixes each block forward, then writes it time-reversed; blocks run backwards from `position`.
    @discardableResult
    public func fill(maxBlocks: Int = .max) -> Int {
        var pushed = 0
        while pushed < maxBlocks {
            var (timeline, pos, reverse, gen, buses, seqs) = control.withLock {
                ($0.timeline, $0.position, $0.reverse, $0.generation, $0.buses, $0.sequences) }
            if gen != appliedGeneration {           // producer-side flush, before any push of this generation
                // A changed max latency is adopted here only (new FX start, delays re-sized), together with the flush.
                buses = config.withLock { c in
                    let set = c.rebuild(blockFrames: blockFrames, commit: true)
                    control.withLock { $0.buses = set }
                    return set
                }
                let e = ring.flush(); appliedGeneration = gen
                flushState.withLock { $0 = (gen, e, buses.latency) }
                flushGeneration.value.store(gen, ordering: .releasing)
                for b in buses.list { b.reset() }    // FX/denoiser history and delay lines belong to the old position
            }
            guard ring.availableToWrite >= blockFrames else { break }
            let start: Int64, count: Int
            if reverse {
                start = max(0, pos - Int64(blockFrames)); count = Int(pos - start)
                if count == 0 { break }                      // reached the timeline start
            } else { start = pos; count = blockFrames }
            renderBlock(timeline: timeline, sequences: seqs, buses: buses, start: start, count: count, reverse: reverse)
            afterMixHook?()
            // Generation check, push and position update are one step with respect to `seek`.
            let committed = control.withLock { c -> Bool in
                guard c.generation == gen else { return false }
                _ = ring.push(left: outL, right: outR, count: count)
                c.position = reverse ? start : pos + Int64(count)
                return true
            }
            if committed { pushed += 1 }
        }
        return pushed
    }

    /// Per-track mix -> (reverse) -> FX -> delay compensation -> sum into `outL`/`outR`, in play order.
    private func renderBlock(timeline: Timeline, sequences: [Timeline.ID: Timeline], buses: BusSet,
                             start: Int64, count: Int, reverse: Bool) {
        for b in buses.list { b.l.update(repeating: 0, count: count); b.r.update(repeating: 0, count: count) }
        outL.update(repeating: 0, count: count); outR.update(repeating: 0, count: count)
        accumulateSegments(timeline: timeline, sequences: sequences, startFrame: start, count: count) { id in
            if let i = buses.index[id] { return (buses.list[i].l, buses.list[i].r) }
            return (outL, outR)                    // track unknown to the bus set (timeline raced setTimeline): no FX
        }
        if reverse { reverseInPlace(outL, count); reverseInPlace(outR, count) }
        for b in buses.list {
            if reverse { reverseInPlace(b.l, count); reverseInPlace(b.r, count) }
            b.process(count: count, reverse: reverse, startSample: start)
            for i in 0..<count { outL[i] += b.l[i]; outR[i] += b.r[i] }
        }
    }

    private func reverseInPlace(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        var i = 0, j = n - 1
        while i < j { let t = p[i]; p[i] = p[j]; p[j] = t; i += 1; j -= 1 }
    }

    /// Mixes timeline frames `[startFrame, startFrame + count)` in forward order into `left`/`right` (overwritten).
    /// Clip boundaries are sample-exact: a frame belongs to a clip when `start <= frame/rate < end`.
    /// Clip volume is evaluated on an absolute 256-frame grid and interpolated linearly in between (exact for constant volume).
    /// Dry mix of all tracks (no FX, no latency compensation); the feeder thread itself uses `renderBlock`.
    public func mix(timeline: Timeline, sequences: [Timeline.ID: Timeline] = [:], startFrame: Int64, count: Int,
                    left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        left.update(repeating: 0, count: count); right.update(repeating: 0, count: count)
        accumulateSegments(timeline: timeline, sequences: sequences, startFrame: startFrame, count: count) { _ in (left, right) }
    }

    /// Adds every audible segment of `[startFrame, startFrame + count)` (clip volume x nest gain applied) into the destination
    /// of its top-level track.
    private func accumulateSegments(timeline: Timeline, sequences: [Timeline.ID: Timeline], startFrame: Int64, count: Int,
                                    destination: (Track.ID) -> (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)) {
        precondition(count <= blockFrames)
        let rate = Int64(sampleRate)
        let range = TimeRange(start: Time(startFrame, rate), duration: Time(Int64(count), rate))
        for seg in timeline.audioSegments(in: range, sequences: { sequences[$0] }) {
            let f0 = max(startFrame, Self.ceilFrame(seg.timeline.start, rate))
            let f1 = min(startFrame + Int64(count), Self.ceilFrame(seg.timeline.end, rate))
            guard f1 > f0 else { continue }
            let n = Int(f1 - f0)
            let clip = Self.segmentClip(seg, top: timeline, sequences: sequences)
            // A speed track (or any clip inside a retimed nested clip) goes through the time map; constant clips keep their exact path.
            let mapped = (clip?.speedKeys != nil) || seg.nests.contains { $0.clip.speedKeys != nil || !$0.clip.speed.isNormal || $0.clip.reversed }
            let timeMap = mapped ? AudioTimeMap(chain: seg.nests.map(\.clip) + (clip.map { [$0] } ?? [])) : nil
            let retimed = mapped || !seg.speed.isNormal || seg.reversed
            let srcStart = retimed ? 0 : Self.roundFrame(seg.sourceStart + (Time(f0, rate) - seg.timeline.start), rate)
            let dstOff = Int(f0 - startFrame)
            let animated = (clip?.animation.volume.isAnimated ?? false) || seg.nests.contains { $0.clip.animation.volume.isAnimated }
            let gain = { (frame: Int64) -> Double in Self.gain(seg, clip: clip, atFrame: frame, rate: rate) }
            let source: any AudioSource
            do {
                if let s = sources[seg.media] { source = s } else { source = try resolver(seg.media); sources[seg.media] = source }
            } catch { failedReads.add(1, ordering: .relaxed); continue }
            let (dl, dr) = destination(seg.nests.first?.track ?? seg.track)
            for (ch, dst) in [dl, dr].enumerated() {
                do {
                    if let timeMap {
                        let rateD = Double(rate), grid = Self.ceilFrame(seg.clipStart, rate)
                        try retimer.renderMapped(read: { try source.read(from: $0, count: $1, into: $2, channel: ch) },
                                                 position: { timeMap.position(atFrame: Double(grid + $0), rate: rateD) },
                                                 keepsPitch: seg.keepsPitch && seg.nests.allSatisfy { $0.clip.keepsPitch },
                                                 srcStart: Self.roundFrame(seg.source.start, rate), srcEnd: Self.roundFrame(seg.source.end, rate),
                                                 firstOutput: f0 - grid, count: n, into: scratch)
                    } else if retimed {
                        let a = seg.timeline.start - seg.clipStart
                        let originT = seg.reversed ? seg.sourceStart + seg.speed.scale(a) : seg.sourceStart - seg.speed.scale(a)
                        try retimer.render(read: { try source.read(from: $0, count: $1, into: $2, channel: ch) },
                                           origin: Double(originT.value) / Double(originT.timescale) * Double(rate),
                                           speed: Double(seg.speed.num) / Double(seg.speed.den), reversed: seg.reversed,
                                           keepsPitch: seg.keepsPitch,
                                           srcStart: Self.roundFrame(seg.source.start, rate), srcEnd: Self.roundFrame(seg.source.end, rate),
                                           firstOutput: f0 - Self.ceilFrame(seg.clipStart, rate),
                                           count: n, into: scratch)
                    } else {
                        let got = try source.read(from: srcStart, count: n, into: scratch, channel: ch)
                        if got < n { (scratch + got).update(repeating: 0, count: n - got) }
                    }
                } catch { failedReads.add(1, ordering: .relaxed); continue }
                Self.accumulate(scratch, into: dst + dstOff, count: n, firstFrame: f0, rate: rate, animated: animated, gain: gain)
            }
        }
    }

    /// Drops cached sources (media relinked or proxies switched).
    public func invalidateSources() { sources.removeAll() }

    private static let gainChunk = 256

    /// The segment's own clip: in the top timeline, or (nested) in the sequence of the innermost nest clip.
    private static func segmentClip(_ seg: AudioSegment, top: Timeline, sequences: [Timeline.ID: Timeline]) -> Clip? {
        let owner = seg.nests.last?.clip.sequence.flatMap { sequences[$0] } ?? top
        return owner.track(seg.track)?.clips.first { $0.id == seg.clip }
    }

    /// Clip volume (evaluated in the clip's own, inner time) x enclosing nest gains, at top-sequence frame `frame`.
    private static func gain(_ seg: AudioSegment, clip: Clip?, atFrame frame: Int64, rate: Int64) -> Double {
        let outer = Time(frame, rate)
        var g = seg.nestGain(at: outer)
        if let clip {
            var t = outer
            for n in seg.nests { t = n.clip.sourceInstant(atLocal: t - n.clip.start) }
            g *= clip.volume(at: t)
        }
        return g
    }

    private static func accumulate(_ src: UnsafePointer<Float>, into dst: UnsafeMutablePointer<Float>, count: Int,
                                   firstFrame: Int64, rate: Int64, animated: Bool, gain: (Int64) -> Double) {
        if !animated {
            let g = Float(gain(firstFrame))
            for i in 0..<count { dst[i] += src[i] * g }
            return
        }
        // Gain is linear between points on an absolute 256-frame grid, so any split of the timeline gives identical samples.
        var i = 0
        while i < count {
            let f = firstFrame + Int64(i)
            let base = f - (f % Int64(gainChunk) + Int64(gainChunk)) % Int64(gainChunk)
            let n = min(Int(base + Int64(gainChunk) - f), count - i)
            let g0 = Float(gain(base))
            let g1 = Float(gain(base + Int64(gainChunk)))
            for k in 0..<n {
                let w = Float(f + Int64(k) - base) / Float(gainChunk)
                dst[i + k] += src[i + k] * (g0 + (g1 - g0) * w)
            }
            i += n
        }
    }

    // MARK: exact rational -> frame conversion

    /// Smallest frame index `f` with `f / rate >= t`.
    static func ceilFrame(_ t: Time, _ rate: Int64) -> Int64 {
        let num = Int128(t.value) * Int128(rate), den = Int128(t.timescale)
        let q = num / den
        return Int64(num % den > 0 ? q + 1 : q)   // num % den keeps the sign of num, so negatives truncate toward zero = ceil
    }

    /// Nearest frame index (ties round up).
    static func roundFrame(_ t: Time, _ rate: Int64) -> Int64 {
        let num = Int128(t.value) * Int128(rate) * 2 + Int128(t.timescale), den = Int128(t.timescale) * 2
        var q = num / den
        if num % den < 0 { q -= 1 }
        return Int64(q)
    }
}

/// Generation of the latest feeder flush, readable without locks (render thread).
public final class FlushGeneration: Sendable {
    public let value = Atomic<Int>(0)
    public init() {}
}
