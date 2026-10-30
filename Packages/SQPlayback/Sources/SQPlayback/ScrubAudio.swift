import Foundation
import Synchronization
import SQCore
import SQMedia
import SQAudioFX

// Scrub audio (E-12, ARCHITECTURE §7): short grains of timeline audio at the scrub/step position, in the direction of
// motion, overlap-added with raised-cosine crossfades.
//
// Pieces:
// - `ScrubGrainPlanner` (pure): scrub/step events -> grain requests (start, direction, length, speed).
// - `ScrubAudio`: owns the planner and a worker that mixes a requested grain (dry timeline mix: clip volume, mute/solo,
//   gaps; no track FX) into a free `ScrubVoice` slot, windowed, and hands it over. Requests are latest-wins: a newer one
//   replaces an older one that was not mixed yet (idea from palmier-pro's `ScrubAudioPendingState`, GPL-3.0; own code).
// - `ScrubVoice`: the real-time side. Fixed slots, lock-free handoff (one pending slot, atomic exchange), no allocation.
//
// Output path (why not the play ring): the play ring belongs to `AudioClock` (every flush must be one it requested, its
// consumed counter is the master clock) and sits behind TimePitch (~85 ms latency when engaged). Scrub audio therefore
// has its own voice, rendered by a second `AVAudioSourceNode` straight into the same engine's main mixer: nothing on the
// play path or the clock changes, and grains start within one render call. While scrubbing the engine is paused, so the
// play node renders silence; `PlaybackEngine.play()` stops the voice first.
//
// Speed / pitch: grains are read at 1x (pitch preserved) and placed at the current scrub position, so the audible speed
// follows the drag velocity (granular time-stretch). This replaces "speed through TimePitch" from the plan (TimePitch's
// latency would lag the mouse). `ScrubSettings.maxVarispeed` > 1 optionally raises the grain's playback speed (and pitch)
// with the drag velocity, up to that factor.

/// Tuning for scrub grains. Defaults per ARCHITECTURE §7.
public struct ScrubSettings: Sendable, Equatable {
    /// Shortest grain (hop between grain starts). Grains are one sequence frame long, but never shorter than this.
    public var minGrain = Time(1, 25)
    /// Raised-cosine crossfade at each grain join (and fade in/out at the ends), in frames at the mixer rate. 5 ms.
    public var fadeFrames = 240
    /// |drag velocity| (timeline s per s) at or above which grains use `minGrain` (quicker position updates).
    public var fastSpeed = 2.0
    /// Upper bound of the grain playback speed. 1 = always 1x, pitch preserved.
    public var maxVarispeed = 1.0
    /// A pause between scrub events longer than this restarts the velocity estimate.
    public var holdNanos: Int64 = 250_000_000
    public init() {}
}

/// One grain request. Frames are timeline frames at the mixer rate.
public struct ScrubGrain: Sendable, Equatable {
    /// Forward: first frame played. Reverse: exclusive upper end; frame `start - 1` plays first, then backwards.
    public var start: Int64
    public var reverse: Bool
    /// Output frames before the next grain may start (the grain length).
    public var hop: Int
    /// Crossfade frames; the grain renders `hop + fade` frames (fade-in over the first, fade-out over the last `fade`).
    public var fade: Int
    /// Source frames per output frame (1 = pitch preserved).
    public var speed: Double
    public var frames: Int { hop + fade }
    /// Source frames the grain reads (plus one for interpolation).
    public var sourceSpan: Int { Int((Double(frames - 1) * speed).rounded(.up)) + 2 }
}

/// Pure: turns scrub and step events into grain requests.
///
/// - Direction = sign of the last movement; no movement = no grain (holding the mouse still goes silent once the playing
///   grain ends).
/// - Length (hop) = one sequence frame, at least `minGrain`; `minGrain` when |velocity| >= `fastSpeed`.
/// - Velocity = timeline time moved / host time elapsed, smoothed (EMA 0.5) and restarted after a hold > `holdNanos`.
/// - Speed = clamp(|velocity|, 1, `maxVarispeed`).
public struct ScrubGrainPlanner: Sendable {
    public let settings: ScrubSettings
    public let sampleRate: Int
    /// Smoothed drag velocity (timeline seconds per second, signed). 0 before the first movement.
    public private(set) var velocity = 0.0
    private var last: (frame: Int64, nanos: Int64)?
    private var hasVelocity = false

    public init(settings: ScrubSettings = ScrubSettings(), sampleRate: Int = 48_000) {
        self.settings = settings; self.sampleRate = sampleRate
    }

    public mutating func begin(at position: Time, hostNanos: Int64) {
        last = (frame(position), hostNanos); velocity = 0; hasVelocity = false
    }

    /// Next grain for a drag to `position` at host time `hostNanos`, or nil when the position did not move.
    public mutating func scrub(to position: Time, hostNanos: Int64, frameDuration: Time) -> ScrubGrain? {
        let f = frame(position)
        defer { last = (f, hostNanos) }
        guard let prev = last else { return nil }          // first event without begin: anchor only
        let moved = f - prev.frame
        guard moved != 0 else { return nil }
        let dt = hostNanos - prev.nanos
        if dt > settings.holdNanos { hasVelocity = false }
        if dt > 0 {
            let raw = Double(moved) / (Double(dt) * Double(sampleRate) / 1e9)
            velocity = hasVelocity ? 0.5 * velocity + 0.5 * raw : raw
            hasVelocity = true
        }
        let speed = min(max(abs(velocity), 1), max(1, settings.maxVarispeed))
        return grain(at: f, reverse: moved < 0, hop: grainLength(speed: abs(velocity), frameDuration: frameDuration), speed: speed)
    }

    /// Grain for a step from `from` to `to` (grid times): forward plays the new frame from its start, backward plays it
    /// reversed from its end. Nil when the step did not move.
    public func step(from: Time, to: Time, frameDuration: Time) -> ScrubGrain? {
        guard to != from else { return nil }
        let reverse = to < from
        return grain(at: frame(reverse ? to + frameDuration : to), reverse: reverse,
                     hop: grainLength(speed: 1, frameDuration: frameDuration), speed: 1)
    }

    /// Hop in frames at |velocity| `speed`: one frame (rounded up), at least `minGrain`; `minGrain` when fast.
    public func grainLength(speed: Double, frameDuration: Time) -> Int {
        let minimum = Int(AudioFeeder.ceilFrame(settings.minGrain, Int64(sampleRate)))
        let frameLen = Int(AudioFeeder.ceilFrame(frameDuration, Int64(sampleRate)))
        let hop = speed >= settings.fastSpeed ? minimum : max(minimum, frameLen)
        return max(hop, settings.fadeFrames)               // a join never overlaps more than two grains
    }

    private func grain(at start: Int64, reverse: Bool, hop: Int, speed: Double) -> ScrubGrain {
        ScrubGrain(start: start, reverse: reverse, hop: hop, fade: settings.fadeFrames, speed: speed)
    }

    private func frame(_ t: Time) -> Int64 { AudioFeeder.roundFrame(t, Int64(sampleRate)) }
}

/// Real-time grain player. Producer (one thread at a time): `claim` a free slot, write the windowed grain into
/// `buffers(slot)`, `publish` it. Consumer (audio render thread): `render`. Handoff is lock-free and allocation-free:
/// slot ownership is a free bitmask plus one `pending` slot (atomic exchange), so a newer grain replaces an unplayed one
/// and nothing queues up. The voice takes the pending grain when the playing one reaches its hop (join crossfade:
/// outgoing fade-out + incoming fade-in sum to 1), or right away when idle. `cancel` fades out within `fadeFrames`
/// and drops the pending grain and every grain published for an older generation.
public final class ScrubVoice: @unchecked Sendable {
    /// At most: 2 rendering (playing + fading tail), 1 pending, 1 being written.
    public static let slotCount = 4
    public let capacity: Int
    public let fadeFrames: Int

    struct SlotInfo { var frames = 0, hop = 0, generation = 0; var tag: Int64 = 0 }

    private let storageL: UnsafeMutablePointer<Float>, storageR: UnsafeMutablePointer<Float>
    private let info: UnsafeMutablePointer<SlotInfo>
    private let ramp: UnsafeMutablePointer<Float>
    private let free = Atomic<Int>((1 << ScrubVoice.slotCount) - 1)
    private let pending = Atomic<Int>(-1)
    private let cancelGeneration = Atomic<Int>(0)
    private let started = Atomic<Int>(0)
    private let startedTag = Atomic<Int64>(-1)
    // Render thread only.
    private var cur = -1, curOff = 0, old = -1, oldOff = 0, seenGeneration = 0, stopFade = -1

    public init(capacity: Int, fadeFrames: Int = 240) {
        precondition(capacity > 0 && fadeFrames > 0)
        self.capacity = capacity; self.fadeFrames = fadeFrames
        let n = capacity * Self.slotCount
        storageL = .allocate(capacity: n); storageR = .allocate(capacity: n)
        storageL.initialize(repeating: 0, count: n); storageR.initialize(repeating: 0, count: n)
        info = .allocate(capacity: Self.slotCount); info.initialize(repeating: SlotInfo(), count: Self.slotCount)
        ramp = .allocate(capacity: fadeFrames)
        for k in 0..<fadeFrames { ramp[k] = Self.rampValue(k, fadeFrames) }
    }
    deinit { storageL.deallocate(); storageR.deallocate(); info.deallocate(); ramp.deallocate() }

    /// Raised cosine 0 -> 1 over `n` frames; `rampValue(k) + rampValue(n - 1 - k) == 1`.
    static func rampValue(_ k: Int, _ n: Int) -> Float { Float(0.5 - 0.5 * cos(Double.pi * (Double(k) + 0.5) / Double(n))) }

    // MARK: producer

    /// Current cancel generation: stamp grains with the value read when their request was made.
    public var generation: Int { cancelGeneration.load(ordering: .acquiring) }

    /// Takes a free slot for writing, nil if none (cannot happen with one producer).
    public func claim() -> Int? {
        var f = free.load(ordering: .acquiring)
        while f != 0 {
            let bit = f & -f
            let (done, orig) = free.compareExchange(expected: f, desired: f & ~bit, ordering: .acquiringAndReleasing)
            if done { return bit.trailingZeroBitCount }
            f = orig
        }
        return nil
    }

    public func buffers(_ slot: Int) -> (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        (storageL + slot * capacity, storageR + slot * capacity)
    }

    /// Hands a written slot to the voice; an older pending grain goes back to the free set.
    public func publish(slot: Int, frames: Int, hop: Int, generation: Int, tag: Int64) {
        precondition(frames <= capacity && hop >= fadeFrames && hop <= frames)
        info[slot] = SlotInfo(frames: frames, hop: hop, generation: generation, tag: tag)
        let replaced = pending.exchange(slot, ordering: .acquiringAndReleasing)
        if replaced >= 0 { release(replaced) }
    }

    /// Returns a claimed slot without publishing it.
    public func abandon(_ slot: Int) { release(slot) }

    /// Any thread: fade out what plays (within `fadeFrames`), drop pending and older-generation grains.
    public func cancel() { cancelGeneration.add(1, ordering: .acquiringAndReleasing) }

    // MARK: stats (any thread)

    public var grainsStarted: Int { started.load(ordering: .acquiring) }
    public var lastStartedTag: Int64 { startedTag.load(ordering: .acquiring) }
    public var freeSlots: Int { free.load(ordering: .acquiring).nonzeroBitCount }

    // MARK: render thread

    /// Overwrites `count` frames. Returns true when the output is pure silence (nothing playing).
    public func render(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        let gen = cancelGeneration.load(ordering: .acquiring)
        if gen != seenGeneration {
            seenGeneration = gen
            if cur >= 0 || old >= 0 { stopFade = 0 }
            // Only a grain of an older generation is dropped: one published for the new generation (the next scrub started
            // within this render quantum) stays, unless a newer one has replaced it meanwhile.
            let p = pending.exchange(-1, ordering: .acquiringAndReleasing)
            if p >= 0 {
                let keep = info[p].generation == gen
                    && pending.compareExchange(expected: -1, desired: p, ordering: .acquiringAndReleasing).exchanged
                if !keep { release(p) }
            }
        }
        if cur < 0 && old < 0 && pending.load(ordering: .relaxed) < 0 {
            l.update(repeating: 0, count: count); r.update(repeating: 0, count: count)
            return true
        }
        var tried = false, sounded = false
        for i in 0..<count {
            if stopFade < 0 {
                let atHop = cur >= 0 && curOff == info[cur].hop
                if atHop || (!tried && (cur < 0 || curOff > info[cur].hop)) {
                    tried = true
                    if let n = take(gen) {
                        if old >= 0 { release(old) }           // finished already (hop >= fade), defensive
                        old = cur; oldOff = curOff
                        cur = n; curOff = 0
                        started.add(1, ordering: .relaxed)
                        startedTag.store(info[n].tag, ordering: .releasing)
                    }
                }
            }
            var sl: Float = 0, sr: Float = 0
            if cur >= 0 {
                sounded = true
                let (bl, br) = buffers(cur)
                sl += bl[curOff]; sr += br[curOff]
                curOff += 1
                if curOff >= info[cur].frames { release(cur); cur = -1 }
            }
            if old >= 0 {
                sounded = true
                let (bl, br) = buffers(old)
                sl += bl[oldOff]; sr += br[oldOff]
                oldOff += 1
                if oldOff >= info[old].frames { release(old); old = -1 }
            }
            if stopFade >= 0 {
                let g = 1 - ramp[stopFade]
                sl *= g; sr *= g
                stopFade += 1
                if stopFade >= fadeFrames {
                    if cur >= 0 { release(cur); cur = -1 }
                    if old >= 0 { release(old); old = -1 }
                    stopFade = -1
                }
            }
            l[i] = sl; r[i] = sr
        }
        if cur < 0 && old < 0 { stopFade = -1 }
        return !sounded
    }

    private func take(_ gen: Int) -> Int? {
        let p = pending.exchange(-1, ordering: .acquiringAndReleasing)
        guard p >= 0 else { return nil }
        guard info[p].generation == gen else { release(p); return nil }
        return p
    }

    private func release(_ slot: Int) { free.bitwiseOr(1 << slot, ordering: .releasing) }
}

/// Scrub/step audio: planner + grain mixing worker + `ScrubVoice`. Control calls are cheap and never block on mixing
/// (except with `inline: true`, used by tests, which mixes on the calling thread).
public final class ScrubAudio: @unchecked Sendable {
    public let voice: ScrubVoice
    public let settings: ScrubSettings
    public let sampleRate: Int
    private let inline: Bool

    private struct Control {
        var planner: ScrubGrainPlanner
        var timeline: Timeline?
        var sequences: [Timeline.ID: Timeline] = [:]
        var request: (grain: ScrubGrain, generation: Int, tag: Int64)?
        var draining = false
        var nextTag: Int64 = 0
        var lastGrain: ScrubGrain?
    }
    private let control: Mutex<Control>
    private let queue = DispatchQueue(label: "ScrubAudio", qos: .userInteractive)
    private let submitted = Atomic<Int>(0), produced = Atomic<Int>(0), dropped = Atomic<Int>(0), failed = Atomic<Int>(0)

    // Worker only (the queue, or the caller when inline).
    private let mixer: AudioFeeder
    private let declickObserver: AudioDeClickObserver
    private let duckObserver: LiveDuckingObserver
    private let srcL: UnsafeMutablePointer<Float>, srcR: UnsafeMutablePointer<Float>
    private let spanCapacity: Int
    private let ramp: UnsafeMutablePointer<Float>

    /// `resolver` provides the sources (48 kHz), like `AudioFeeder`'s.
    public init(resolver: @escaping AudioFeeder.Resolver, settings: ScrubSettings = ScrubSettings(), sampleRate: Int = 48_000,
                inline: Bool = false) {
        self.settings = settings; self.sampleRate = sampleRate; self.inline = inline
        // Longest grain: a 1/10 s frame (10 fps) is the longest hop the app uses; longer frames are clamped to it.
        let capacity = sampleRate / 10 + settings.fadeFrames
        voice = ScrubVoice(capacity: capacity, fadeFrames: settings.fadeFrames)
        spanCapacity = Int((Double(capacity) * max(1, settings.maxVarispeed)).rounded(.up)) + 2
        srcL = .allocate(capacity: spanCapacity); srcR = .allocate(capacity: spanCapacity)
        ramp = .allocate(capacity: settings.fadeFrames)
        for k in 0..<settings.fadeFrames { ramp[k] = ScrubVoice.rampValue(k, settings.fadeFrames) }
        mixer = AudioFeeder(timeline: Timeline(name: "", frameDuration: Time(1, 30)), ring: RingBuffer(capacity: 1),
                            sampleRate: sampleRate, blockFrames: 4096, resolver: resolver)
        mixer.declickFrames = AudioDeClick.currentFadeFrames(sampleRate: sampleRate)   // same de-click fades as playback
        let liveMixer = mixer
        declickObserver = AudioDeClickObserver(sampleRate: sampleRate) { liveMixer.declickFrames = $0 }
        mixer.liveDucking = LiveDucking.current()
        duckObserver = LiveDuckingObserver { liveMixer.liveDucking = $0 }
        control = Mutex(Control(planner: ScrubGrainPlanner(settings: settings, sampleRate: sampleRate)))
    }
    deinit { srcL.deallocate(); srcR.deallocate(); ramp.deallocate() }

    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        control.withLock { $0.timeline = timeline; $0.sequences = sequences }
        mixer.declickFrames = AudioDeClick.currentFadeFrames(sampleRate: sampleRate)   // a changed setting applies at the next edit
    }

    /// De-click fade length the scrub mixer applies (frames; 0 = off).
    var declickFrames: Int { mixer.declickFrames }

    /// The files behind these media changed (relink): the scrub mixer reopens their sources at its next grain. Any thread.
    public func mediaChanged(_ ids: Set<UUID>) { mixer.mediaChanged(ids) }
    /// N8b: the project's own live ducking (an atomic on the mixer, safe from any thread).
    public func setProjectLiveDucking(_ setting: ProjectLiveDucking?) { mixer.projectLiveDucking = setting }
    /// N8b: dialogue pauses for the live duck (safe from any thread).
    public func setDialogueSilences(_ provider: (any DialogueSilenceProvider)?) { mixer.dialogueSilences = provider }

    /// Start of a drag at `position` (no sound yet).
    public func begin(at position: Time, hostNanos: Int64) {
        control.withLock { $0.planner.begin(at: position, hostNanos: hostNanos) }
    }

    /// Drag moved to `position` at host time `hostNanos` (same base as `AudioPlaying.hostNanoseconds()`).
    public func scrub(to position: Time, hostNanos: Int64) {
        let g = control.withLock { c -> ScrubGrain? in
            guard let fd = c.timeline?.format.frameDuration else { return nil }
            return c.planner.scrub(to: position, hostNanos: hostNanos, frameDuration: fd)
        }
        if let g { submit(g) }
    }

    /// Step from `from` to `to` (grid times): one grain of the new frame in step direction.
    public func step(from: Time, to: Time) {
        let g = control.withLock { c -> ScrubGrain? in
            guard let fd = c.timeline?.format.frameDuration else { return nil }
            return c.planner.step(from: from, to: to, frameDuration: fd)
        }
        if let g { submit(g) }
    }

    /// Stops scrub audio: the voice fades out (5 ms), queued and in-flight grains are dropped.
    public func stop() {
        voice.cancel()
        control.withLock { $0.request = nil }
    }

    /// Blocks until the worker has mixed every submitted request (tests).
    public func waitUntilIdle() { queue.sync {} }

    public var submittedGrains: Int { submitted.load(ordering: .acquiring) }
    public var producedGrains: Int { produced.load(ordering: .acquiring) }
    /// Requests that found no free voice slot (should stay 0).
    public var droppedRequests: Int { dropped.load(ordering: .acquiring) }
    /// Source reads that failed while mixing grains (rendered as silence).
    public var failedReads: Int { mixer.failedReads.load(ordering: .relaxed) + failed.load(ordering: .relaxed) }
    /// Tag of the most recent request (compare with `voice.lastStartedTag`).
    public var lastTag: Int64 { control.withLock { $0.nextTag - 1 } }
    public var lastGrain: ScrubGrain? { control.withLock { $0.lastGrain } }

    // MARK: worker

    private func submit(_ g0: ScrubGrain) {
        var g = g0
        g.hop = min(g.hop, voice.capacity - g.fade)
        let generation = voice.generation
        submitted.add(1, ordering: .relaxed)
        if inline {
            let tag = control.withLock { c -> Int64 in c.lastGrain = g; defer { c.nextTag += 1 }; return c.nextTag }
            produce(g, generation: generation, tag: tag)
            return
        }
        let startDrain = control.withLock { c -> Bool in
            c.request = (g, generation, c.nextTag); c.nextTag += 1; c.lastGrain = g
            if c.draining { return false }
            c.draining = true
            return true
        }
        if startDrain { queue.async { [self] in drain() } }
    }

    private func drain() {
        while let r = control.withLock({ c -> (grain: ScrubGrain, generation: Int, tag: Int64)? in
            if let r = c.request { c.request = nil; return r }
            c.draining = false
            return nil
        }) {
            produce(r.grain, generation: r.generation, tag: r.tag)
        }
    }

    private func produce(_ g: ScrubGrain, generation: Int, tag: Int64) {
        guard let snap = control.withLock({ c in c.timeline.map { ($0, c.sequences) } }) else { return }
        guard let slot = voice.claim() else { dropped.add(1, ordering: .relaxed); return }
        let (l, r) = voice.buffers(slot)
        render(g, timeline: snap.0, sequences: snap.1, left: l, right: r)
        produced.add(1, ordering: .relaxed)
        voice.publish(slot: slot, frames: g.frames, hop: g.hop, generation: generation, tag: tag)
    }

    /// Mixes the grain's source span (timeline mix with clip effects), reads it at `speed` in grain direction and applies the window.
    private func render(_ g: ScrubGrain, timeline: Timeline, sequences: [Timeline.ID: Timeline],
                       left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let span = min(g.sourceSpan, spanCapacity)
        let first = g.reverse ? g.start - Int64(span) : g.start      // srcL[k] = timeline frame first + k
        var k = 0
        while k < span {
            let f = first + Int64(k)
            let n = min(span - k, mixer.blockFrames)
            if f < 0 {                                                // before the timeline start: silence
                let z = min(n, Int(-f))
                (srcL + k).update(repeating: 0, count: z); (srcR + k).update(repeating: 0, count: z)
                k += z; continue
            }
            // Clip and nest audio effects too, so a scrubbed clip sounds like it plays (chains re-prime at every grain jump).
            mixer.mix(timeline: timeline, sequences: sequences, startFrame: f, count: n, left: srcL + k, right: srcR + k,
                      clipEffects: true)
            k += n
        }
        let n = g.frames, fade = g.fade
        for j in 0..<n {
            let x = Double(j) * g.speed
            let pos = g.reverse ? Double(span - 1) - x : x
            let i0 = min(max(Int(pos.rounded(.down)), 0), span - 1)
            let i1 = min(i0 + 1, span - 1), w = Float(pos - Double(i0))
            var a = srcL[i0] + (srcL[i1] - srcL[i0]) * w
            var b = srcR[i0] + (srcR[i1] - srcR[i0]) * w
            let win: Float = j < fade ? ramp[j] : (j >= n - fade ? ramp[n - 1 - j] : 1)
            a *= win; b *= win
            left[j] = a; right[j] = b
        }
    }
}
