import Foundation
import Synchronization
import SSCore
import SSMedia

/// Mixes `Timeline.audioSegments` from `AudioSource`s into a `RingBuffer` at the mixer rate (48 kHz), in play direction.
/// Everything here runs on one thread (the feeder thread, or the test); only `setTimeline`, `seek`, `start`, `stop` are
/// callable from other threads. Sources are expected at the mixer rate already (resampled upstream by `AssetAudioSource`).
public final class AudioFeeder: @unchecked Sendable {
    public typealias Resolver = @Sendable (UUID) throws -> any AudioSource

    public let sampleRate: Int
    public let blockFrames: Int
    public let ring: RingBuffer
    private let resolver: Resolver

    private struct Control {
        var timeline: Timeline
        var position: Int64 = 0         // timeline frame where the next block starts (forward) or ends (reverse)
        var reverse = false
        var generation = 0              // bumped by seek; blocks mixed under an older generation are dropped
        var running = false
    }
    private let control: Mutex<Control>
    private var sources: [UUID: any AudioSource] = [:]
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
        self.sampleRate = sampleRate; self.blockFrames = blockFrames; self.ring = ring; self.resolver = resolver
        control = Mutex(Control(timeline: timeline))
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

    public func setTimeline(_ t: Timeline) { control.withLock { $0.timeline = t } }

    /// New anchor: flushes the ring and restarts production at `frame` (timeline frames at the mixer rate).
    /// In reverse, `frame` is the exclusive upper end of the first block, so frame `frame - 1` plays first.
    /// Callable from any thread: only bumps the generation. The feeder thread flushes the ring itself when it sees
    /// the new generation, so the ring keeps a single producer.
    public func seek(to frame: Int64, reverse: Bool) {
        control.withLock { $0.position = frame; $0.reverse = reverse; $0.generation += 1 }
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
            let (timeline, pos, reverse, gen) = control.withLock { ($0.timeline, $0.position, $0.reverse, $0.generation) }
            if gen != appliedGeneration { ring.flush(); appliedGeneration = gen }   // producer-side flush, before any push of this generation
            guard ring.availableToWrite >= blockFrames else { break }
            let start: Int64, count: Int
            if reverse {
                start = max(0, pos - Int64(blockFrames)); count = Int(pos - start)
                if count == 0 { break }                      // reached the timeline start
            } else { start = pos; count = blockFrames }
            mix(timeline: timeline, startFrame: start, count: count, left: outL, right: outR)
            if reverse { reverseInPlace(outL, count); reverseInPlace(outR, count) }
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

    private func reverseInPlace(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        var i = 0, j = n - 1
        while i < j { let t = p[i]; p[i] = p[j]; p[j] = t; i += 1; j -= 1 }
    }

    /// Mixes timeline frames `[startFrame, startFrame + count)` in forward order into `left`/`right` (overwritten).
    /// Clip boundaries are sample-exact: a frame belongs to a clip when `start <= frame/rate < end`.
    /// Clip volume is evaluated on an absolute 256-frame grid and interpolated linearly in between (exact for constant volume).
    public func mix(timeline: Timeline, startFrame: Int64, count: Int,
                    left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        precondition(count <= blockFrames)
        left.update(repeating: 0, count: count); right.update(repeating: 0, count: count)
        let rate = Int64(sampleRate)
        let range = TimeRange(start: Time(startFrame, rate), duration: Time(Int64(count), rate))
        for seg in timeline.audioSegments(in: range) {
            let f0 = max(startFrame, Self.ceilFrame(seg.timeline.start, rate))
            let f1 = min(startFrame + Int64(count), Self.ceilFrame(seg.timeline.end, rate))
            guard f1 > f0 else { continue }
            let n = Int(f1 - f0)
            let srcStart = Self.roundFrame(seg.sourceStart + (Time(f0, rate) - seg.timeline.start), rate)
            let clip = timeline.track(seg.track)?.clips.first { $0.id == seg.clip }
            let dstOff = Int(f0 - startFrame)
            let source: any AudioSource
            do {
                if let s = sources[seg.media] { source = s } else { source = try resolver(seg.media); sources[seg.media] = source }
            } catch { failedReads.add(1, ordering: .relaxed); continue }
            for (ch, dst) in [left, right].enumerated() {
                do {
                    let got = try source.read(from: srcStart, count: n, into: scratch, channel: ch)
                    if got < n { (scratch + got).update(repeating: 0, count: n - got) }
                } catch { failedReads.add(1, ordering: .relaxed); continue }
                Self.accumulate(scratch, into: dst + dstOff, count: n, firstFrame: f0, clip: clip, rate: rate)
            }
        }
    }

    /// Drops cached sources (media relinked or proxies switched).
    public func invalidateSources() { sources.removeAll() }

    private static let gainChunk = 256

    private static func accumulate(_ src: UnsafePointer<Float>, into dst: UnsafeMutablePointer<Float>, count: Int,
                                   firstFrame: Int64, clip: Clip?, rate: Int64) {
        guard let clip else { for i in 0..<count { dst[i] += src[i] }; return }
        if !clip.animation.volume.isAnimated {
            let g = Float(clip.volume(at: Time(firstFrame, rate)))
            for i in 0..<count { dst[i] += src[i] * g }
            return
        }
        // Gain is linear between points on an absolute 256-frame grid, so any split of the timeline gives identical samples.
        var i = 0
        while i < count {
            let f = firstFrame + Int64(i)
            let base = f - (f % Int64(gainChunk) + Int64(gainChunk)) % Int64(gainChunk)
            let n = min(Int(base + Int64(gainChunk) - f), count - i)
            let g0 = Float(clip.volume(at: Time(base, rate)))
            let g1 = Float(clip.volume(at: Time(base + Int64(gainChunk), rate)))
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
