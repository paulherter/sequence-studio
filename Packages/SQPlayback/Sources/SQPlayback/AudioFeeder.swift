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
/// applied twice. Order: clip volume -> track FX -> track fader gain (`applyPostFader`, ramped per block; pan stays per segment before the FX), as in Premiere. `mix` (scrub, no track FX) applies the fader per segment.
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
/// Master: when the top sequence has a `DeliveryTarget`, the summed mix runs through a zero-latency `MasterLimiter` at its
/// true-peak ceiling (playback ring and export read the same output). The dry `mix(...)` path has no limiter.
/// Sequence Volume (`Timeline.masterGain`) scales the summed mix just before the limiter (ramped per block; `mix` applies it
/// constant); a nested sequence's own level is part of its sum (`faderChain` / `nestFader`).
/// Track roles: a track without an explicit preset (`setTracks` / `setPreset`) gets its `Track.audioRole`'s voiced preset.
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
    struct FXConfig {
        var presets: [UUID: TrackAudioPreset] = [:]
        /// Track roles of the current timeline: a track without an explicit preset gets its role's voiced preset.
        var roles: [UUID: AudioTag] = [:]
        var trackIDs: [UUID] = []
        var fxs: [UUID: (fx: RealtimeAudioFX, denoiser: Bool)] = [:]
        var buses: [UUID: TrackBus] = [:]
        /// Latency the running feeder compensates to. Changes only with `commit` (at a seek), never mid-play.
        var committedLatency = 0

        mutating func rebuild(blockFrames: Int, commit: Bool = false) -> BusSet {
            var newFx: [UUID: (fx: RealtimeAudioFX, denoiser: Bool)] = [:]
            for id in trackIDs {
                guard let preset = effectivePreset(id) else { continue }
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
    let config: Mutex<FXConfig>

    private struct Control {
        var timeline: Timeline
        /// Live ducking decisions of `timeline` (built with it in `setTimeline`, off the audio thread): no per-block walk.
        var duckIndex: LiveDuckingIndex
        var position: Int64 = 0         // timeline frame where the next block starts (forward) or ends (reverse)
        var reverse = false
        var generation = 0              // bumped by seek; blocks mixed under an older generation are dropped
        var running = false
        var buses = BusSet()
        var sequences: [Timeline.ID: Timeline] = [:]   // nested sequences, by id
        var feederEpoch = 0             // bumped by every start and stop: a feeder thread of an older epoch ends
        var staleMedia: Set<UUID> = []  // media whose cached source (and failure) the feeder thread drops at its next block
        var staleAll = false
        /// Master limiter ceiling (the top sequence's `DeliveryTarget.truePeakDB`); nil = no limiter.
        var limiterCeilingDB: Double?
    }
    /// Live feeder threads (for tests: after start/stop settles it is 1 while running, 0 when stopped).
    final class ThreadCount: Sendable { let n = Atomic<Int>(0) }
    let liveThreads = ThreadCount()
    var liveFeederThreads: Int { liveThreads.n.load(ordering: .acquiring) }
    /// Held while the feeder thread produces a block, so a thread of an older epoch that is still inside `fill` finishes
    /// before the next one starts: the ring never has two producers.
    private let feederGate = Mutex<Void>(())
    /// A source that failed to open is not retried before this long has passed (or `mediaChanged`).
    var openRetryInterval: Duration = .seconds(5)
    private var failedOpens: [UUID: ContinuousClock.Instant] = [:]
    private var loggedFailures: Set<UUID> = []
    private let flushState = Mutex<(generation: Int, epoch: Int, latency: Int)>((0, 0, 0))
    /// Lock-free copy of `flushed.generation` for the audio render thread; stored after the ring flush and before any
    /// push of that generation, so once it is >= g the ring holds nothing mixed before generation g.
    public let flushGeneration = FlushGeneration()
    private let control: Mutex<Control>
    private var sources: [UUID: any AudioSource] = [:]
    /// Time maps of remapped clip chains, built once and reused for every block (feeder thread only); a changed clip rebuilds.
    /// Fader gain each bus ended the previous block with: a change is ramped linearly across the next block (no step, no click).
    private var faderState: [FaderKey: (left: Double, right: Double)] = [:]
    /// Post-effects fader gain of each top-level track bus: where the previous block ended (ramped across the next block).
    private var postFaderState: [Track.ID: Float] = [:]
    private var masterLevelState: Float?         // Sequence Volume of the last block (ramp start), feeder thread only
    private var timeMaps: [[Clip.ID]: (chain: [Clip], map: AudioTimeMap)] = [:]
    /// Live duck ranges of the current block and the same expanded by the duck timing (feeder thread only; reused, so a block
    /// does not allocate for them once sized). One expanded buffer per nest level: an effected nest's pass runs while the
    /// outer pass still holds its expanded ranges, so sharing one buffer would copy it (allocate) on every nested block.
    private var duckRanges: [TimeRange] = [], duckExpanded: [[TimeRange]] = []
    private let retimer: AudioRetimer
    private let mixL: UnsafeMutablePointer<Float>, mixR: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>
    /// Role buses (`roleBusGainsDB`): one stereo sum per `AudioTag`, indexed like `AudioTag.allCases`.
    private let roleBuffers: [NestBuffer]
    private let roleGainsDB = Mutex<[AudioTag: Double]>([:])
    /// Gain each role bus ended the previous block with (ramped across the next one), feeder thread only.
    private var roleGainState: [AudioTag: Float] = [:]
    /// Role bus gains in dB (session level, not persisted; missing role = 0 dB). Tracks of a role are summed into that
    /// role's bus, the bus gain applies to the sum, then the buses join the master. A role at 0 dB is not touched: its
    /// tracks sum straight into the master, so a mix with every bus at 0 dB is bit-identical to one without buses.
    /// Read per block, so a change applies live (ramped). Shared by playback and export: both mix through `renderBlock`.
    public var roleBusGainsDB: [AudioTag: Double] {
        get { roleGainsDB.withLock { $0 } }
        set { roleGainsDB.withLock { $0 = newValue } }
    }
    /// Segments whose source failed to open or read (they render as silence; playback continues).
    public let failedReads = Atomic<Int>(0)
    /// Automatic de-click fade at every clip boundary, in frames (0 = off). Default off here so the mixer itself stays
    /// sample-exact; the engine and the export source set it from `AudioDeClick.currentFadeFrames()` (one setting, one path).
    private let declick = Atomic<Int>(0)
    public var declickFrames: Int {
        get { declick.load(ordering: .relaxed) }
        set { declick.store(max(0, newValue), ordering: .relaxed) }
    }
    /// Live music ducking amount in 1/100 dB (0 = off); see `LiveDucking`. Read per block, so a changed setting applies live.
    private let duckCentiDB = Atomic<Int>(0)
    /// Timing of the Preferences duck and of the project's (read with the amount, per block).
    private let prefDuckTiming = Mutex(DuckTiming.classic), projectDuckTiming = Mutex(DuckTiming.classic)
    public var liveDucking: LiveDucking? {
        get {
            let v = duckCentiDB.load(ordering: .relaxed)
            return v > 0 ? LiveDucking(amountDB: Double(v) / 100, timing: prefDuckTiming.withLock { $0 }) : nil
        }
        set {
            prefDuckTiming.withLock { $0 = newValue?.timing ?? .classic }
            duckCentiDB.store(newValue.map { max(0, Int($0.amountDB * 100)) } ?? 0, ordering: .relaxed)
        }
    }
    /// N8b: the project's own setting, which overrides `liveDucking` (Preferences): -1 = none (follow Preferences),
    /// 0 = off, else the amount in 1/100 dB.
    private let projectDuckCentiDB = Atomic<Int>(-1)
    public var projectLiveDucking: ProjectLiveDucking? {
        get {
            let v = projectDuckCentiDB.load(ordering: .relaxed)
            return v < 0 ? nil : ProjectLiveDucking(isOn: v > 0, amountDB: v > 0 ? Double(v) / 100 : Ducking.defaultAmountDB,
                                                    timing: projectDuckTiming.withLock { $0 })
        }
        set {
            projectDuckTiming.withLock { $0 = newValue?.timing ?? .classic }
            let v = newValue.map { p in p.liveDucking.map { max(1, Int($0.amountDB * 100)) } ?? 0 } ?? -1
            projectDuckCentiDB.store(v, ordering: .relaxed)
        }
    }
    /// N8b: pauses inside dialogue clips release the live duck (nil or not known yet = the whole clip ducks).
    /// Must answer without blocking (`WaveformSilences` queues unknown clips in the background).
    private let silenceProvider = Mutex<(any DialogueSilenceProvider)?>(nil)
    public var dialogueSilences: (any DialogueSilenceProvider)? {
        get { silenceProvider.withLock { $0 } }
        set { silenceProvider.withLock { $0 = newValue } }
    }
    /// What the mix applies: the project's setting when it has one, else Preferences.
    public var effectiveLiveDucking: LiveDucking? {
        let p = projectDuckCentiDB.load(ordering: .relaxed)
        if p >= 0 { return p > 0 ? LiveDucking(amountDB: Double(p) / 100, timing: projectDuckTiming.withLock { $0 }) : nil }
        return liveDucking
    }
    private var thread: Thread?
    private var appliedGeneration = 0           // feeder thread only
    /// AUDIO-FX: the effect chain of every clip with audio effects that played in the last block (feeder thread only), keyed by
    /// nest path + clip id. Dropped when the clip no longer plays; all dropped at a seek.
    private final class ClipFX {
        let chain: ClipAudioFXChain
        var nextFrame = Int64.min      // frame a contiguous next block starts at; any other start resets the chain
        var serial = 0
        var steps: [AudioFXStep] = [], endSteps: [AudioFXStep] = []      // reused per block (no allocation once sized)
        init(_ chain: ClipAudioFXChain) {
            self.chain = chain
            steps.reserveCapacity(chain.layout.count); endSteps.reserveCapacity(chain.layout.count)
        }
    }
    /// The clip id plus a hash of its nest path (the same clip seen through two nest instances gets two chains).
    private struct ClipFXKey: Hashable {
        let clip: UUID
        let nests: Int
        init(_ seg: AudioSegment, clip: UUID) { self.init(seg.nests[...], clip: clip) }
        /// `nests`: the enclosing nest clips of `clip`, outermost first (for a nest clip's own chain: the nests above it).
        init(_ path: ArraySlice<AudioNest>, clip: UUID) {
            self.clip = clip
            if path.isEmpty { nests = 0 } else {
                var h = Hasher()
                for n in path { h.combine(n.clip.id) }
                nests = h.finalize()
            }
        }
    }
    /// A nested clip with audio effects: its inner segments are mixed into one buffer, run through its chain, then get the
    /// nest's Volume and the faders above it. `depth` is its index in `AudioSegment.nests`. Every nest level with effects
    /// is a group of its own: the outermost one is found by the outer pass, each further one by the pass of the group
    /// around it, so the chains run inner first (a disguised nest inside an effected nest is never skipped).
    private struct NestGroup { let key: ClipFXKey; let depth: Int }
    /// The first nest clip with audio effects at or below `floor` (the level under the group being rendered, 0 outside).
    private static func nestGroupDepth(_ seg: AudioSegment, from floor: Int = 0) -> Int? {
        var d = floor
        while d < seg.nests.count { if seg.nests[d].clip.hasAudioEffects { return d }; d += 1 }
        return nil
    }
    /// The summing buffers of one nest level (a group inside a group needs its own while the outer one is being filled).
    private struct NestBuffer {
        let l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>
        let ptrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        init(frames: Int) {
            l = .allocate(capacity: frames); l.initialize(repeating: 0, count: frames)
            r = .allocate(capacity: frames); r.initialize(repeating: 0, count: frames)
            ptrs = .allocate(capacity: 2); ptrs[0] = l; ptrs[1] = r
        }
        func free() { l.deallocate(); r.deallocate(); ptrs.deallocate() }
    }
    private var nestBuffers: [NestBuffer] = []      // by nest depth; 4 levels up front, a deeper one is added once
    private var clipFX: [ClipFXKey: ClipFX] = [:]
    private var clipFXSerial = 0
    /// Builds an effect chain. Tests replace it with one that throws to prove the feeder fails closed.
    var makeChain: ([AudioFXSlot], Int) throws -> ClipAudioFXChain = { layout, frames in
        try ClipAudioFXChain(layout: layout, channelCount: 2, maxFrames: frames)
    }
    private let fxL: UnsafeMutablePointer<Float>, fxR: UnsafeMutablePointer<Float>
    private let fxPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private var limiter: MasterLimiter?         // feeder thread only
    var afterMixHook: (() -> Void)?          // test seam: runs between mixing a block and committing it
    var usesDuckIndex = true                 // test seam: false = the per-block timeline walk (the reference the index must match)

    public init(timeline: Timeline, ring: RingBuffer, sampleRate: Int = 48_000, blockFrames: Int = 1024,
                resolver: @escaping Resolver) {
        precondition(sampleRate == RealtimeAudioFX.sampleRate, "AudioFeeder/RealtimeAudioFX run at 48 kHz only")
        self.sampleRate = sampleRate; self.blockFrames = blockFrames; self.ring = ring; self.resolver = resolver
        retimer = AudioRetimer(maxFrames: blockFrames)
        var cfg = FXConfig()
        cfg.trackIDs = timeline.tracks.filter { $0.kind == .audio }.map(\.id)
        cfg.roles = Self.roles(of: timeline)
        var c = Control(timeline: timeline, duckIndex: LiveDuckingIndex(timeline))
        c.limiterCeilingDB = Self.limiterCeiling(of: timeline)
        c.buses = cfg.rebuild(blockFrames: blockFrames, commit: true)
        control = Mutex(c)
        config = Mutex(cfg)
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames); p.initialize(repeating: 0, count: blockFrames); return p
        }
        mixL = alloc(); mixR = alloc(); scratch = alloc(); outL = alloc(); outR = alloc()
        duckRanges.reserveCapacity(64)
        duckExpanded = (0..<4).map { _ in var a: [TimeRange] = []; a.reserveCapacity(64); return a }
        fxL = alloc(); fxR = alloc()
        fxPtrs = .allocate(capacity: 2); fxPtrs[0] = fxL; fxPtrs[1] = fxR
        nestBuffers = (0..<4).map { _ in NestBuffer(frames: blockFrames) }
        roleBuffers = AudioTag.allCases.map { _ in NestBuffer(frames: blockFrames) }
    }
    deinit {
        for b in roleBuffers { b.free() }
        stop()
        for p in [mixL, mixR, scratch, outL, outR, fxL, fxR] { p.deallocate() }
        fxPtrs.deallocate()
        for b in nestBuffers { b.free() }
    }

    // MARK: control

    /// `sequences` resolves nested audio clips (id -> timeline, e.g. `Dictionary(uniqueKeysWithValues: project.timelines.map { ($0.id, $0) })`).
    /// Passing `nil` keeps the current set.
    public func setTimeline(_ t: Timeline, sequences: [Timeline.ID: Timeline]? = nil) {
        let ids = t.tracks.filter { $0.kind == .audio }.map(\.id)
        let roles = Self.roles(of: t), ceiling = Self.limiterCeiling(of: t)
        let duckIndex = LiveDuckingIndex(t)
        // Rebuild and publish under one `config` lock: interleaved callers can never publish an older set last.
        config.withLock { c in
            c.trackIDs = ids
            c.roles = roles
            let set = c.rebuild(blockFrames: blockFrames)
            control.withLock {
                $0.timeline = t; $0.duckIndex = duckIndex; $0.buses = set; $0.limiterCeilingDB = ceiling
                if let sequences { $0.sequences = sequences }
            }
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

    /// Starts the feeder thread. Idempotent: a second `start` while running does nothing. Every start/stop pair moves the
    /// epoch on, so a thread that was stopped but has not noticed yet ends instead of running beside the new one.
    public func start() {
        let epoch = control.withLock { c -> Int? in
            if c.running { return nil }
            c.running = true; c.feederEpoch += 1
            return c.feederEpoch
        }
        guard let epoch else { return }
        let live = liveThreads
        let t = Thread { [weak self] in
            live.n.add(1, ordering: .acquiringAndReleasing)
            defer { live.n.subtract(1, ordering: .acquiringAndReleasing) }
            while let self, self.control.withLock({ $0.running && $0.feederEpoch == epoch }) {
                let pushed = self.feederGate.withLock { _ in self.fill() }
                if pushed == 0 { Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        t.name = "AudioFeeder"; t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Idempotent. The thread ends at its next loop check; a later `start` never runs beside it.
    public func stop() {
        control.withLock { $0.running = false; $0.feederEpoch += 1 }
        thread = nil
    }

    // MARK: producing

    /// Mixes and pushes blocks while the ring has room for a whole block. Returns the number of blocks pushed.
    /// Reverse play mixes each block forward, then writes it time-reversed; blocks run backwards from `position`.
    @discardableResult
    public func fill(maxBlocks: Int = .max) -> Int {
        var pushed = 0
        while pushed < maxBlocks {
            var (timeline, duckIndex, pos, reverse, gen, buses, seqs, ceiling) = control.withLock {
                ($0.timeline, $0.duckIndex, $0.position, $0.reverse, $0.generation, $0.buses, $0.sequences, $0.limiterCeilingDB) }
            if limiter?.ceilingDB != ceiling { limiter = ceiling.map { MasterLimiter(sampleRate: sampleRate, ceilingDB: $0) } }
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
                clipFX.removeAll()                   // clip effect chains too
                limiter?.reset()
                roleGainState.removeAll()           // role bus ramps have no history again, like a fresh feeder
            }
            guard ring.availableToWrite >= blockFrames else { break }
            let start: Int64, count: Int
            if reverse {
                start = max(0, pos - Int64(blockFrames)); count = Int(pos - start)
                if count == 0 { break }                      // reached the timeline start
            } else { start = pos; count = blockFrames }
            renderBlock(timeline: timeline, duckIndex: usesDuckIndex ? duckIndex : nil, sequences: seqs, buses: buses, start: start, count: count, reverse: reverse)
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
    private func renderBlock(timeline: Timeline, duckIndex: LiveDuckingIndex?, sequences: [Timeline.ID: Timeline], buses: BusSet,
                             start: Int64, count: Int, reverse: Bool) {
        for b in buses.list { b.l.update(repeating: 0, count: count); b.r.update(repeating: 0, count: count) }
        outL.update(repeating: 0, count: count); outR.update(repeating: 0, count: count)
        // Clip audio effects also run in reverse play: each block is mixed forward, so the chain sees increasing time inside the
        // block; blocks arrive backwards, so its state is reset and re-primed at every block (an approximation, like scrubbing).
        // The top-level track fader is applied below, after the track's effects (clip volume stays before them).
        accumulateSegments(timeline: timeline, sequences: sequences, startFrame: start, count: count, clipEffects: true,
                           faderAfterEffects: true, duckIndex: duckIndex) { id in
            if let i = buses.index[id] { return (buses.list[i].l, buses.list[i].r) }
            return (outL, outR)                    // track unknown to the bus set (timeline raced setTimeline): no FX
        }
        if reverse { reverseInPlace(outL, count); reverseInPlace(outR, count) }
        var ids = [Track.ID](repeating: UUID(), count: buses.list.count)
        for (id, i) in buses.index { ids[i] = id }
        let roleDB = roleGainsDB.withLock { $0 }
        var busActive = [Bool](repeating: false, count: roleBuffers.count)
        for (bi, b) in buses.list.enumerated() {
            if reverse { reverseInPlace(b.l, count); reverseInPlace(b.r, count) }
            b.process(count: count, reverse: reverse, startSample: start)
            applyPostFader(b, track: ids[bi], timeline: timeline, count: count)
            if let role = timeline.track(ids[bi])?.audioRole, let ri = AudioTag.allCases.firstIndex(of: role),
               Self.roleGain(role, roleDB, &roleGainState) != nil {
                let rb = roleBuffers[ri]
                if !busActive[ri] { busActive[ri] = true; rb.l.update(repeating: 0, count: count); rb.r.update(repeating: 0, count: count) }
                for i in 0..<count { rb.l[i] += b.l[i]; rb.r[i] += b.r[i] }
            } else {
                for i in 0..<count { outL[i] += b.l[i]; outR[i] += b.r[i] }
            }
        }
        for (ri, role) in AudioTag.allCases.enumerated() {
            // Every role's gain is remembered each block (no history = no ramp), active or not, so a later change ramps from the truth.
            let now = Float(TrackPan.linear(volumeDB: roleDB[role] ?? 0)), was = roleGainState[role] ?? now
            roleGainState[role] = now
            guard busActive[ri] else { continue }
            let rb = roleBuffers[ri]
            for i in 0..<count {
                let g = was == now ? now : was + (now - was) * Float(i) / Float(count)
                outL[i] += rb.l[i] * g; outR[i] += rb.r[i] * g
            }
        }
        applyMasterLevel(timeline: timeline, startFrame: start, count: count, reverse: reverse, latency: buses.latency)   // Sequence Volume, before the limiter
        Self.applyChannelLayout(timeline.channelLayout, left: outL, right: outR, count: count)
        limiter?.process(left: outL, right: outR, count: count)   // master bus, shared by playback and export
    }

    /// Channels: Mono = (L + R) / 2 on both sides (dual mono). The one fold, shared by `renderBlock` and the scrub path `mix`.
    /// In place, no allocation; Stereo is untouched.
    static func applyChannelLayout(_ layout: ChannelLayout, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        guard layout == .mono else { return }
        for i in 0..<count { let m = ChannelLayout.fold(left[i], right[i]); left[i] = m; right[i] = m }
    }

    /// Keyed Sequence Volume: the gain at absolute 256-frame grid points (sequence time), linear in between, so any split of a
    /// range into blocks gives the same samples (the clip volume grid). `reverse`: the block is already reversed in place.
    /// `latency`: samples the mix is behind the timeline (FX delay compensation); the level follows the sound it multiplies,
    /// so it is read `latency` earlier going forward and `latency` later in reverse (the delay holds play-earlier frames).
    static func applyKeyedMasterLevel(_ timeline: Timeline, startFrame: Int64, count: Int, reverse: Bool, rate: Int64,
                                      latency: Int = 0, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let grid: Int64 = 256
        var lo = Int64.min, gLo: Float = 1, gHi: Float = 1
        for j in 0..<count {
            let frame = startFrame + Int64(j) + (reverse ? Int64(latency) : -Int64(latency))
            let cell = (frame >= 0 ? frame / grid : -((-frame + grid - 1) / grid)) * grid
            if cell != lo {
                lo = cell
                gLo = Float(timeline.masterGain(at: Time(cell, rate)))
                gHi = Float(timeline.masterGain(at: Time(cell + grid, rate)))
            }
            let g = gLo + (gHi - gLo) * Float(frame - cell) / Float(grid)
            let i = reverse ? count - 1 - j : j
            left[i] *= g; right[i] *= g
        }
    }

    /// The top sequence's Sequence Volume on the summed mix, ramped linearly from the previous block's level like a fader.
    private func applyMasterLevel(timeline: Timeline, startFrame: Int64, count: Int, reverse: Bool, latency: Int) {
        if timeline.isMasterVolumeKeyed {
            masterLevelState = nil
            Self.applyKeyedMasterLevel(timeline, startFrame: startFrame, count: count, reverse: reverse,
                                         rate: Int64(sampleRate), latency: latency, left: outL, right: outR)
            return
        }
        let now = Float(timeline.masterGain)
        let was = masterLevelState ?? now
        masterLevelState = now
        if was == 1 && now == 1 { return }
        for p in [outL, outR] {
            if was == now { for i in 0..<count { p[i] *= now } } else {
                for i in 0..<count { p[i] *= was + (now - was) * Float(i) / Float(count) }
            }
        }
    }

    /// Track fader gain (no pan: pan is applied per segment before the effects) after the bus' effects, ramped linearly from
    /// where the previous block ended (no step, no click). Same path for playback and export.
    /// Non-nil when `role`'s bus must be used: its gain is not 0 dB, or it was not at the start of this block (a ramp back
    /// to unity still has to run through the bus). The previous gain is read here, written after the block's sum.
    private static func roleGain(_ role: AudioTag, _ db: [AudioTag: Double], _ state: inout [AudioTag: Float]) -> Float? {
        let now = Float(TrackPan.linear(volumeDB: db[role] ?? 0))
        let was = state[role] ?? now      // no history (fresh feeder, after a seek): no ramp, like a fresh render
        if now == 1 && was == 1 { return nil }
        return now
    }

    private func applyPostFader(_ b: TrackBus, track id: Track.ID, timeline: Timeline, count: Int) {
        let now = Float(Self.trackFaderGain(timeline: timeline, track: id))
        let was = postFaderState[id] ?? now
        postFaderState[id] = now
        if was == 1 && now == 1 { return }
        for p in [b.l, b.r] {
            if was == now { for i in 0..<count { p[i] *= now } } else {
                for i in 0..<count { p[i] *= was + (now - was) * Float(i) / Float(count) }
            }
        }
    }

    private func reverseInPlace(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        var i = 0, j = n - 1
        while i < j { let t = p[i]; p[i] = p[j]; p[j] = t; i += 1; j -= 1 }
    }

    /// Mixes timeline frames `[startFrame, startFrame + count)` in forward order into `left`/`right` (overwritten).
    /// Clip boundaries are sample-exact: a frame belongs to a clip when `start <= frame/rate < end`.
    /// Clip volume is evaluated on an absolute 256-frame grid and interpolated linearly in between (exact for constant volume).
    /// Mix of all tracks without track FX or latency compensation; the feeder thread itself uses `renderBlock`.
    /// `clipEffects`: run clip and nest audio effects (scrubbing): consecutive calls continue the chains' state, any jump
    /// resets and re-primes them (like reverse play). One caller thread per feeder instance.
    public func mix(timeline: Timeline, sequences: [Timeline.ID: Timeline] = [:], startFrame: Int64, count: Int,
                    left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, clipEffects: Bool) {
        left.update(repeating: 0, count: count); right.update(repeating: 0, count: count)
        var done = 0
        while done < count {                       // longer than one block: contiguous chunks (chains continue across them)
            let n = min(blockFrames, count - done)
            let l = left + done, r = right + done
            accumulateSegments(timeline: timeline, sequences: sequences, startFrame: startFrame + Int64(done), count: n,
                               clipEffects: clipEffects) { _ in (l, r) }
            done += n
        }
        if timeline.isMasterVolumeKeyed {
            Self.applyKeyedMasterLevel(timeline, startFrame: startFrame, count: count, reverse: false,
                                         rate: Int64(sampleRate), left: left, right: right)
        } else {
            let g = Float(timeline.masterGain)             // Sequence Volume (scrub: constant, no limiter on this path)
            if g != 1 { for i in 0..<count { left[i] *= g; right[i] *= g } }
        }
        Self.applyChannelLayout(timeline.channelLayout, left: left, right: right, count: count)   // Mono scrub = Mono playback
    }

    /// Adds every audible segment of `[startFrame, startFrame + count)` (clip volume x nest gain applied) into the destination
    /// of its top-level track.
    /// `clipEffects`: run each clip's audio effects (AUDIO-FX) on its sound first, before volume, envelopes and fader.
    private func accumulateSegments(timeline: Timeline, sequences: [Timeline.ID: Timeline], startFrame: Int64, count: Int,
                                    clipEffects: Bool = false, group: NestGroup? = nil, faderAfterEffects: Bool = false,
                                    duckIndex: LiveDuckingIndex? = nil, destination: (Track.ID) -> (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)) {
        precondition(count <= blockFrames)
        let rate = Int64(sampleRate)
        let range = TimeRange(start: Time(startFrame, rate), duration: Time(Int64(count), rate))
        if group == nil { applyStaleMedia() }
        var endState: [FaderKey: (left: Double, right: Double)] = [:]
        defer { for (k, v) in endState { faderState[k] = v } }
        var groups: [(group: NestGroup, seg: AudioSegment)] = []      // nests with effects, rendered after the plain segments
        let fade = declickFrames                     // one atomic read per block, not per channel
        // N8 live ducking: Music-role clips (clip tag, else track role; audit C18) follow the dialogue as the timeline is right
        // now. Decided per segment from its top-level clip and track (`LiveDucking.ducks`, no per-block set). Applied to the dry
        // segment gain in timeline order, so it is delay-compensated with its bus and the same for forward, reverse, scrub and export.
        // The feeder thread passes the timeline's `duckIndex` (no walk; ranges into reused buffers, expanded once per block);
        // `mix` (scrub grains) walks the timeline as before.
        var duck: (LiveDucking, [TimeRange])?
        if let d = effectiveLiveDucking {
            let pad = d.reach
            let window = TimeRange(start: range.start - pad, duration: range.duration + pad + pad)
            if let duckIndex {
                duckIndex.dialogueRanges(in: timeline, window: window, silences: dialogueSilences, into: &duckRanges)
                if !duckRanges.isEmpty {
                    let level = group.map { $0.depth + 1 } ?? 0          // outer pass 0, a nest pass below it its own
                    while duckExpanded.count <= level { duckExpanded.append([]) }  // deeper than 4 nests: once
                    d.expanded(duckRanges, into: &duckExpanded[level])
                    duck = (d, duckExpanded[level])
                }
            } else {
                let ranges = LiveDucking.dialogueRanges(in: timeline, window: window, silences: dialogueSilences)
                if !ranges.isEmpty { duck = (d, d.expanded(ranges)) }
            }
        }
        let owner = clipEffects && group == nil         // the outer pass owns the chain bookkeeping, a nest pass only reads
        if owner { clipFXSerial &+= 1 }
        defer {                                                  // drop clips that left (allocates only when one did)
            if owner, clipFX.contains(where: { $0.value.serial != clipFXSerial }) {
                clipFX = clipFX.filter { $0.value.serial == clipFXSerial }
            }
        }
        for seg in timeline.audioSegments(in: range, sequences: { sequences[$0] }) {
            let f0 = max(startFrame, Self.ceilFrame(seg.timeline.start, rate))
            let f1 = min(startFrame + Int64(count), Self.ceilFrame(seg.timeline.end, rate))
            // A nest pass takes only what plays inside its nest clip; a further effected nest below it is a group again.
            if let group {
                guard seg.nests.count > group.depth,
                      ClipFXKey(seg.nests[..<group.depth], clip: seg.nests[group.depth].clip.id) == group.key else { continue }
            }
            if clipEffects, let d = Self.nestGroupDepth(seg, from: group.map { $0.depth + 1 } ?? 0) {
                let key = ClipFXKey(seg.nests[..<d], clip: seg.nests[d].clip.id)
                if !groups.contains(where: { $0.group.key == key }) { groups.append((NestGroup(key: key, depth: d), seg)) }
                continue
            }
            guard f1 > f0 else { continue }
            let n = Int(f1 - f0)
            let clip = Self.segmentClip(seg, top: timeline, sequences: sequences)
            // A speed track (or any clip inside a retimed nested clip) goes through the time map; constant clips keep their exact path.
            let ducked = duck != nil && (duckIndex.map { Self.liveDucked(seg, index: $0) } ?? Self.liveDucked(seg, clip: clip, top: timeline))
            let mapped = (clip?.speedKeys != nil) || seg.nests.contains { $0.clip.speedKeys != nil || !$0.clip.speed.isNormal || $0.clip.reversed }
            let timeMap = mapped ? cachedTimeMap(chain: seg.nests.map(\.clip) + (clip.map { [$0] } ?? [])) : nil
            let retimed = mapped || !seg.speed.isNormal || seg.reversed
            let srcStart = retimed ? 0 : Self.roundFrame(seg.sourceStart + (Time(f0, rate) - seg.timeline.start), rate)
            let dstOff = Int(f0 - startFrame)
            let animated = ducked || (clip?.animation.volume.isAnimated ?? false) || seg.nests.contains { $0.clip.animation.volume.isAnimated }
                || !seg.envelopes.isEmpty || seg.nests.contains { !$0.envelopes.isEmpty }
            // AUDIO-FX: a clip running through its effect chain gets its Audio Gain before the chain (Premiere input level),
            // so the volume applied here is the Volume effect alone.
            let fx = clipEffects ? clip.flatMap { clipChain(seg, clip: $0) } : nil
            // A chain that could not be built must not let the clip play dry: Disguise Voice protects a speaker (fail closed).
            if clipEffects, fx == nil, clip?.hasAudioEffects == true { continue }
            let gain = { (frame: Int64) -> Double in
                let g = Self.gain(seg, clip: clip, atFrame: frame, rate: rate, audioGain: fx == nil, nestCut: group?.depth)
                guard ducked, let (d, r) = duck else { return g }
                return g * Double(d.gain(at: Time(frame, rate), expandedRanges: r))
            }
            guard let source = source(for: seg.media) else { failedReads.add(1, ordering: .relaxed); continue }
            let (dl, dr) = destination(seg.nests.first?.track ?? seg.track)
            // Inside an effected nest only the faders below the nest clip apply here (no ramp state); the rest follow its chain.
            let fader = Self.faderChain(seg, top: timeline, sequences: sequences, monoSource: source.isMono, below: group?.depth,
                                         skipTop: faderAfterEffects, at: Time(f0, rate))
            let busKey = FaderKey(track: seg.nests.first?.track ?? seg.track, mono: source.isMono)
            let previous = group == nil ? faderState[busKey] ?? fader : fader
            if group == nil { endState[busKey] = fader }
            // Reads `count` samples of channel `ch` into `into`. `ahead` reads the output that many samples later (the retimer
            // renders are stateless functions of their first output frame); `clamp` zero-fills past the clip's media end. The
            // clip effects' latency is compensated by reading ahead.
            func readChannel(_ ch: Int, into: UnsafeMutablePointer<Float>, ahead: Int = 0, clamp: Bool = false, count: Int) throws {
                if let timeMap {
                    let rateD = Double(rate), grid = Self.ceilFrame(seg.clipStart, rate)
                    try retimer.renderMapped(read: { try source.read(from: $0, count: $1, into: $2, channel: ch) },
                                             position: { timeMap.position(atFrame: Double(grid + $0), rate: rateD) },
                                             keepsPitch: seg.keepsPitch && seg.nests.allSatisfy { $0.clip.keepsPitch },
                                             srcStart: Self.roundFrame(seg.source.start, rate), srcEnd: Self.roundFrame(seg.source.end, rate),
                                             firstOutput: f0 - grid + Int64(ahead),
                                             lead: max(0, grid - Self.ceilFrame(seg.timeline.start, rate)),
                                             count: count, into: into)
                } else if retimed {
                    let a = seg.timeline.start - seg.clipStart
                    let originT = seg.reversed ? seg.sourceStart + seg.speed.scale(a) : seg.sourceStart - seg.speed.scale(a)
                    try retimer.render(read: { try source.read(from: $0, count: $1, into: $2, channel: ch) },
                                       origin: Double(originT.value) / Double(originT.timescale) * Double(rate),
                                       speed: Double(seg.speed.num) / Double(seg.speed.den), reversed: seg.reversed,
                                       keepsPitch: seg.keepsPitch,
                                       srcStart: Self.roundFrame(seg.source.start, rate), srcEnd: Self.roundFrame(seg.source.end, rate),
                                       firstOutput: f0 - Self.ceilFrame(seg.clipStart, rate) + Int64(ahead),
                                       lead: max(0, Self.ceilFrame(seg.clipStart, rate) - Self.ceilFrame(seg.timeline.start, rate)),
                                       count: count, into: into)
                } else {
                    let from = srcStart + Int64(ahead)
                    let avail = ahead == 0 && !clamp ? count : Int(max(0, min(Int64(count), Self.roundFrame(seg.source.end, rate) - from)))
                    let got = avail > 0 ? try source.read(from: from, count: avail, into: into, channel: ch) : 0
                    if got < count { (into + got).update(repeating: 0, count: count - got) }
                }
            }
            // AUDIO-FX: both channels through the clip's effect chain first (Premiere order: effects, then Volume).
            var processed = false
            if let clip, let fx {
                let lat = fx.chain.latencySamples
                Self.fxSteps(seg, clip: clip, f0: f0, count: n, rate: rate, into: fx)
                // Where this piece's samples lie in the stream the chain hears (see `place`).
                let stream = Time(f0, rate) - (seg.nests.first?.clip.start ?? clip.start)
                Self.place(&fx.endSteps, at: stream + Time(Int64(n), rate))
                let input = Float(GainMath.linear(fromDB: clip.audioGainDB))     // Audio Gain: before the effects
                func read(ahead: Int, count k: Int) throws {
                    try readChannel(0, into: fxL, ahead: ahead, clamp: true, count: k)
                    try readChannel(1, into: fxR, ahead: ahead, clamp: true, count: k)
                    if input != 1 { for i in 0..<k { fxL[i] *= input; fxR[i] *= input } }
                }
                do {
                    if fx.nextFrame != f0 {
                        fx.chain.reset()
                        var primed = 0
                        while primed < lat {           // feed the denoiser the `lat` samples whose output lands before f0
                            let k = min(blockFrames, lat - primed)
                            try read(ahead: primed, count: k)
                            Self.place(&fx.steps, at: stream + Time(Int64(primed - lat), rate))
                            fx.chain.process(fxPtrs, frameCount: k, steps: fx.steps)
                            primed += k
                        }
                    }
                    try read(ahead: lat, count: n)
                    Self.place(&fx.steps, at: stream)
                    fx.chain.process(fxPtrs, frameCount: n, steps: fx.steps, endSteps: fx.endSteps)
                    fx.nextFrame = f0 + Int64(n)
                    processed = true
                } catch { failedReads.add(1, ordering: .relaxed); fx.nextFrame = .min; continue }
            }
            for (ch, dst) in [dl, dr].enumerated() {
                let src: UnsafeMutablePointer<Float>
                if processed { src = ch == 0 ? fxL : fxR } else {
                    do { try readChannel(ch, into: scratch, count: n) } catch { failedReads.add(1, ordering: .relaxed); continue }
                    src = scratch
                }
                // Short fade at both edges of the clip's audible extent (not the block piece; after retiming, so every path gets it).
                AudioDeClick.apply(src, count: n, firstFrame: f0, start: Self.ceilFrame(seg.extent.start, rate),
                                   end: Self.ceilFrame(seg.extent.end, rate), fade: fade)
                // Track fader x pan (same path for playback, scrub and export); a change since the last block ramps across this block.
                let side = ch == 0 ? fader.left : fader.right, was = ch == 0 ? previous.left : previous.right
                if was != side {
                    Self.accumulate(src, into: dst + dstOff, count: n, firstFrame: f0, rate: rate, animated: true, gain: gain,
                                    ramp: (Float(was), Float(side), offset: Int(f0 - startFrame), total: count))
                } else {
                    Self.accumulate(src, into: dst + dstOff, count: n, firstFrame: f0, rate: rate, animated: animated,
                                    gain: side == 1 ? gain : { gain($0) * side })
                }
            }
        }
        for g in groups {
            renderNest(g.group, parent: group, seg: g.seg, timeline: timeline, duckIndex: duckIndex, sequences: sequences, startFrame: startFrame, count: count,
                       endState: &endState, faderAfterEffects: faderAfterEffects, destination: destination)
        }
    }

    /// One effected nest over `[startFrame, startFrame + count)`: its inner segments summed (Audio Gain of the nest clip in,
    /// inner volumes and faders applied), through the nest clip's chain (read ahead by its latency, primed after a jump),
    /// then the nest clip's Volume, the enclosing nests' gains and the faders from the nest's track outwards.
    /// `parent`: the effected nest this one plays in. Its output then goes into the parent's sum (the parent's buffers are
    /// `destination`) with the gains and faders between the two only; the rest follows the parent's chain.
    private func renderNest(_ group: NestGroup, parent: NestGroup? = nil, seg: AudioSegment, timeline: Timeline, duckIndex: LiveDuckingIndex?, sequences: [Timeline.ID: Timeline],
                            startFrame: Int64, count: Int, endState: inout [FaderKey: (left: Double, right: Double)],
                            faderAfterEffects: Bool, destination: (Track.ID) -> (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)) {
        let rate = Int64(sampleRate), d = group.depth
        let nest = seg.nests[d].clip
        while nestBuffers.count <= d { nestBuffers.append(NestBuffer(frames: blockFrames)) }      // deeper than 4 nests: once
        let buf = nestBuffers[d]
        let nestL = buf.l, nestR = buf.r, nestPtrs = buf.ptrs
        let fx: ClipFX
        if let old = clipFX[group.key], nest.audioFXLayoutMatches(old.chain.layout) { fx = old } else {
            guard let chain = try? makeChain(nest.audioFXLayout, blockFrames) else { return }
            fx = ClipFX(chain); clipFX[group.key] = fx
        }
        fx.serial = clipFXSerial
        // The nest clip's own time: top time through the nests above it.
        func local(_ frame: Int64) -> Time {
            var t = Time(frame, rate)
            for n in seg.nests[..<d] { t = n.clip.sourceInstant(atLocal: t - n.clip.start) }
            return t - nest.start
        }
        nest.audioFXSteps(atLocal: local(startFrame), into: &fx.steps)
        nest.audioFXSteps(atLocal: local(startFrame + Int64(count)), into: &fx.endSteps)
        let lat = fx.chain.latencySamples
        let stream = Time(startFrame, rate) - seg.nests[0].clip.start
        Self.place(&fx.endSteps, at: stream + Time(Int64(count), rate))
        func read(ahead: Int, count k: Int) {
            nestL.update(repeating: 0, count: k); nestR.update(repeating: 0, count: k)
            accumulateSegments(timeline: timeline, sequences: sequences, startFrame: startFrame + Int64(ahead), count: k,
                               clipEffects: true, group: group, faderAfterEffects: faderAfterEffects, duckIndex: duckIndex) { _ in (nestL, nestR) }
        }
        if fx.nextFrame != startFrame {
            fx.chain.reset()
            var primed = 0
            while primed < lat {
                let k = min(blockFrames, lat - primed)
                read(ahead: primed, count: k)
                Self.place(&fx.steps, at: stream + Time(Int64(primed - lat), rate))
                fx.chain.process(nestPtrs, frameCount: k, steps: fx.steps)
                primed += k
            }
        }
        read(ahead: lat, count: count)
        Self.place(&fx.steps, at: stream)
        fx.chain.process(nestPtrs, frameCount: count, steps: fx.steps, endSteps: fx.endSteps)
        fx.nextFrame = startFrame + Int64(count)
        // After the chain: the nest's Volume and transition curves, the enclosing nests' full gains.
        let above = parent?.depth
        let post = { (frame: Int64) -> Double in
            var t = Time(frame, rate), g = 1.0
            for (j, n) in seg.nests[...d].enumerated() {
                if let above, j <= above {
                    if j == above { g *= GainMath.linear(fromDB: n.clip.audioGainDB) }     // the parent's input level
                } else {
                    for e in n.envelopes { g *= e.gain(at: t) }
                    g *= j == d ? max(n.clip.animation.volume.value(atLocal: t - n.clip.start), 0) : n.clip.volume(at: t)
                }
                t = n.clip.sourceInstant(atLocal: t - n.clip.start)
            }
            return g
        }
        let top = seg.nests[0].track
        let fader = Self.nestFader(seg, depth: d, above: above, top: timeline, sequences: sequences, skipTop: faderAfterEffects,
                                    at: Time(max(startFrame, Self.ceilFrame(seg.timeline.start, rate)), rate))
        let busKey = FaderKey(track: top, mono: false)
        // Fader ramps belong to the top-level bus: inside a parent the faders are the plain product (as for its segments).
        let previous = parent == nil ? faderState[busKey] ?? fader : fader
        if parent == nil { endState[busKey] = fader }
        let (dl, dr) = destination(top)
        for (ch, dst) in [dl, dr].enumerated() {
            let src = ch == 0 ? nestL : nestR
            let side = ch == 0 ? fader.left : fader.right, was = ch == 0 ? previous.left : previous.right
            if was != side {
                Self.accumulate(src, into: dst, count: count, firstFrame: startFrame, rate: rate, animated: true, gain: post,
                                ramp: (Float(was), Float(side), offset: 0, total: count))
            } else {
                Self.accumulate(src, into: dst, count: count, firstFrame: startFrame, rate: rate, animated: true,
                                gain: side == 1 ? post : { post($0) * side })
            }
        }
    }

    /// The effect chain of the segment's clip (built, or rebuilt when its effect list changed), nil without audio effects
    /// or when it cannot be built (the caller then renders silence).
    private func clipChain(_ seg: AudioSegment, clip: Clip) -> ClipFX? {
        guard clip.hasAudioEffects else { return nil }
        let key = ClipFXKey(seg, clip: clip.id)
        let fx: ClipFX
        if let old = clipFX[key], clip.audioFXLayoutMatches(old.chain.layout) { fx = old } else {
            guard let chain = try? makeChain(clip.audioFXLayout, blockFrames) else { return nil }
            fx = ClipFX(chain); clipFX[key] = fx
        }
        fx.serial = clipFXSerial
        return fx
    }

    /// The clip's effect values at the block piece's first frame and one piece later (clip-local time, through enclosing nests),
    /// into the chain's reused arrays.
    private static func fxSteps(_ seg: AudioSegment, clip: Clip, f0: Int64, count: Int, rate: Int64, into fx: ClipFX) {
        func local(_ frame: Int64) -> Time {
            var t = Time(frame, rate)
            for n in seg.nests { t = n.clip.sourceInstant(atLocal: t - n.clip.start) }
            return t - clip.start
        }
        clip.audioFXSteps(atLocal: local(f0), into: &fx.steps)
        clip.audioFXSteps(atLocal: local(f0 + Int64(count)), into: &fx.endSteps)
    }

    /// Effects that count samples (Disguise Voice runs its curves on an absolute sample grid) get the position of the block
    /// in the stream they actually hear: output time since the start of the clip, or of the outermost nest clip around it.
    /// Keyframes are read at the clip's own time, which runs at another speed, or backwards, inside a retimed nest; the
    /// samples arrive one per output frame all the same. Priming chunks lie before the block (`at` minus the latency), so
    /// a chain that starts at a seek continues on the grid a render from the clip's start is on. In place, no allocation.
    private static func place(_ steps: inout [AudioFXStep], at t: Time) {
        for i in steps.indices {
            if case let .disguiseVoice(voice, _) = steps[i].stage { steps[i].stage = .disguiseVoice(voice: voice, at: t) }
        }
    }

    private func cachedTimeMap(chain: [Clip]) -> AudioTimeMap {
        let key = chain.map(\.id)
        if let hit = timeMaps[key], hit.chain == chain { return hit.map }
        if timeMaps.count > 64 { timeMaps.removeAll() }
        let m = AudioTimeMap(chain: chain)
        timeMaps[key] = (chain, m)
        return m
    }

    /// Drops every cached source and remembered open failure (media relinked or proxies switched). Safe from any thread:
    /// it only records the request, the feeder thread applies it at the start of its next block.
    public func invalidateSources() { control.withLock { $0.staleAll = true } }

    /// The files behind these media changed (relink to another path): their sources are reopened at the next block and a
    /// remembered open failure is forgotten, so the new file plays without a restart. Any thread.
    public func mediaChanged(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        control.withLock { $0.staleMedia.formUnion(ids) }
    }

    /// Feeder-side: applies `invalidateSources` / `mediaChanged`.
    private func applyStaleMedia() {
        let (all, ids) = control.withLock { c -> (Bool, Set<UUID>) in
            defer { c.staleAll = false; c.staleMedia = [] }
            return (c.staleAll, c.staleMedia)
        }
        if all {
            sources.removeAll(); timeMaps.removeAll(); failedOpens.removeAll(); loggedFailures.removeAll()
        } else if !ids.isEmpty {
            for id in ids { sources[id] = nil; failedOpens[id] = nil; loggedFailures.remove(id) }
            timeMaps.removeAll()
        }
    }

    /// The cached source of `media`, opening it when needed. A failed open is remembered (retried after `openRetryInterval`
    /// or `mediaChanged`) and logged once, so a missing file does not hit the disk on every block.
    private func source(for media: UUID) -> (any AudioSource)? {
        if let s = sources[media] { return s }
        if let tone = ToneAudioSource.source(for: media, sampleRate: sampleRate) {      // Tone generator: synthesized, no file
            sources[media] = tone
            return tone
        }
        if let t = failedOpens[media], ContinuousClock.now - t < openRetryInterval { return nil }
        do {
            let s = try resolver(media)
            sources[media] = s; failedOpens[media] = nil
            return s
        } catch {
            failedOpens[media] = .now
            if loggedFailures.insert(media).inserted { NSLog("AudioFeeder: cannot open audio of media %@: %@", media.uuidString, "\(error)") }
            return nil
        }
    }

    private static let gainChunk = 256

    /// The segment's own clip: in the top timeline, or (nested) in the sequence of the innermost nest clip.
    /// Whether live ducking acts on this segment: the role rule on its top-level clip (the outermost nest clip, else the clip
    /// itself) and that clip's top-level track. No allocation.
    static func liveDucked(_ seg: AudioSegment, clip: Clip?, top: Timeline) -> Bool {
        let topClip: Clip? = seg.nests.first?.clip ?? clip
        guard let c = topClip, let tr = top.track(seg.nests.first?.track ?? seg.track) else { return false }
        return LiveDucking.ducks(c, on: tr)
    }

    /// Same from the timeline's duck index (a set lookup, no track search). Its top-level clip: the outermost nest clip, else
    /// the segment's own clip (then in the top timeline).
    @inline(__always)
    static func liveDucked(_ seg: AudioSegment, index: LiveDuckingIndex) -> Bool {
        index.ducks(clip: seg.nests.first?.clip.id ?? seg.clip)
    }

    private static func segmentClip(_ seg: AudioSegment, top: Timeline, sequences: [Timeline.ID: Timeline]) -> Clip? {
        let owner = seg.nests.last?.clip.sequence.flatMap { sequences[$0] } ?? top
        return owner.track(seg.track)?.clips.first { $0.id == seg.clip }
    }

    /// Clip volume (evaluated in the clip's own, inner time) x enclosing nest gains, at top-sequence frame `frame`.
    /// `audioGain` false: the Volume effect without the clip's Audio Gain (that one went in before the clip's effects).
    /// `nestCut`: the segment plays inside the effected nest `nests[nestCut]`: the gains of that nest and the ones above it
    /// are applied after its chain, so only the nest clip's Audio Gain (its input level) is applied here.
    private static func gain(_ seg: AudioSegment, clip: Clip?, atFrame frame: Int64, rate: Int64, audioGain: Bool = true,
                             nestCut: Int? = nil) -> Double {
        let outer = Time(frame, rate)
        var g = seg.envelopeGain(at: outer)                              // transition curves, shared by playback and export
        if let cut = nestCut {
            var t = outer
            for (j, n) in seg.nests.enumerated() {
                if j == cut { g *= GainMath.linear(fromDB: n.clip.audioGainDB) } else if j > cut {
                    for e in n.envelopes { g *= e.gain(at: t) }
                    g *= n.clip.volume(at: t)
                }
                t = n.clip.sourceInstant(atLocal: t - n.clip.start)
            }
        } else {
            g *= seg.nestGain(at: outer)
        }
        if let clip {
            var t = outer
            for n in seg.nests { t = n.clip.sourceInstant(atLocal: t - n.clip.start) }
            g *= audioGain ? clip.volume(at: t) : max(clip.animation.volume.value(atLocal: t - clip.start), 0)
        }
        return g
    }

    private static func accumulate(_ src: UnsafePointer<Float>, into dst: UnsafeMutablePointer<Float>, count: Int,
                                   firstFrame: Int64, rate: Int64, animated: Bool, gain: (Int64) -> Double,
                                   ramp: (from: Float, to: Float, offset: Int, total: Int)? = nil) {
        // `ramp`: an extra linear gain from `from` (block start) to `to` (block end), exact per sample.
        @inline(__always) func r(_ i: Int) -> Float {
            guard let ramp else { return 1 }
            return ramp.from + (ramp.to - ramp.from) * Float(ramp.offset + i) / Float(ramp.total)
        }
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
                dst[i + k] += src[i + k] * (g0 + (g1 - g0) * w) * r(i + k)
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
    public static func roundFrame(_ t: Time, _ rate: Int64) -> Int64 {
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
