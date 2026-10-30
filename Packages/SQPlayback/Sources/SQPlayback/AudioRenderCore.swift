#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif
import Foundation
import Synchronization

#if canImport(Darwin)
/// `mach_absolute_time` in nanoseconds (the host time base of `AudioRenderStamp`). Real-time safe.
@inline(__always) public func hostNanosecondsNow() -> Int64 {
    let tb = hostTimebase
    return Int64(Int128(mach_absolute_time()) * Int128(tb.numer) / Int128(tb.denom))
}
private let hostTimebase: (numer: UInt32, denom: UInt32) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (info.numer, info.denom)
}()
#else
/// QueryPerformanceCounter in nanoseconds (the host time base of `AudioRenderStamp` on Windows). Real-time safe.
@inline(__always) public func hostNanosecondsNow() -> Int64 {
    var c = LARGE_INTEGER()
    QueryPerformanceCounter(&c)
    return Int64(Int128(c.QuadPart) * 1_000_000_000 / Int128(qpcFrequency))
}
private let qpcFrequency: Int64 = {
    var f = LARGE_INTEGER()
    QueryPerformanceFrequency(&f)
    return f.QuadPart
}()
#endif

/// Real-time side of `AudioEngine` (and of the Windows WASAPI engine in SQMediaFFmpeg), separated from the hardware so it
/// can be tested headless.
///
/// `render` runs on the Core Audio thread: it only copies from the ring and touches atomics (no locks, no allocation).
/// - Playing: pops from the ring; a short pop is silence (zero-filled by the ring) and counts one underrun.
/// - Priming (after `beginPriming(generation:)`): until the feeder has flushed for THAT generation (lock-free
///   `FlushGeneration`) and the ring holds a whole render call, the old material keeps playing if output was running (so
///   the ring's crossfade has a tail), otherwise silence. Shortage while priming is not an underrun. A newer
///   `beginPriming` during priming is never lost (sequence counter, the render thread only records what it completed).
/// - Stopped: the next `fadeFrames` frames are popped with a raised-cosine fade-out, then silence (ring not consumed).
/// Every consuming call publishes an `AudioRenderStamp` (seqlock) for the clock's interpolation and watchdog.
public final class AudioRenderCore: @unchecked Sendable {
    public let ring: RingBuffer
    public let flushGeneration: FlushGeneration
    public let fadeFrames: Int
    public let playing = Atomic<Bool>(false)
    private let primeSeq = Atomic<Int>(0)
    private let primeTarget = Atomic<Int>(0)
    private let underruns = Atomic<Int>(0)
    private let ramp: UnsafeMutablePointer<Float>       // 0 -> 1
    // Stamp seqlock (odd = render thread writing).
    private let stampSeq = Atomic<Int>(0)
    private let stampFrames = Atomic<Int64>(0)
    private let stampQuantum = Atomic<Int64>(0)
    private let stampNanos = Atomic<Int64>(0)
    // Render thread only.
    private var primedSeq = 0
    private var wasPlaying = false
    private var fadeOutPos: Int

    public init(ring: RingBuffer, flushGeneration: FlushGeneration, fadeFrames: Int = 240) {
        self.ring = ring; self.flushGeneration = flushGeneration; self.fadeFrames = fadeFrames
        let n = max(1, fadeFrames)
        ramp = .allocate(capacity: n)
        for k in 0..<n { ramp[k] = Float(0.5 - 0.5 * cos(Double.pi * (Double(k) + 0.5) / Double(n))) }
        fadeOutPos = fadeFrames
    }
    deinit { ramp.deallocate() }

    public var underrunCount: Int { underruns.load(ordering: .relaxed) }

    /// Call after the feeder seek that returned `generation`: output waits for that generation's flush.
    public func beginPriming(generation: Int) {
        primeTarget.store(generation, ordering: .releasing)
        primeSeq.add(1, ordering: .releasing)
    }

    public var lastRender: AudioRenderStamp {
        while true {
            let s1 = stampSeq.load(ordering: .acquiring)
            if s1 & 1 == 1 { continue }
            let st = AudioRenderStamp(frames: stampFrames.load(ordering: .relaxed), quantum: stampQuantum.load(ordering: .relaxed),
                                      hostNanos: stampNanos.load(ordering: .relaxed))
            atomicMemoryFence(ordering: .acquiring)
            if stampSeq.load(ordering: .relaxed) == s1 { return st }
        }
    }

    /// Fills `count` frames. Returns true when the output is pure silence.
    public func render(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count: Int, hostNanos: Int64) -> Bool {
        guard playing.load(ordering: .acquiring) else {
            if wasPlaying { wasPlaying = false; fadeOutPos = 0 }
            guard fadeOutPos < fadeFrames else { return silence(l, r, count) }
            let n = min(count, fadeFrames - fadeOutPos)
            let got = ring.pop(left: l, right: r, count: n)
            for j in 0..<n { let g = 1 - ramp[fadeOutPos + j]; l[j] *= g; r[j] *= g }
            fadeOutPos += n
            if n < count { (l + n).update(repeating: 0, count: count - n); (r + n).update(repeating: 0, count: count - n) }
            stamp(got, hostNanos)
            return false
        }
        let seq = primeSeq.load(ordering: .acquiring)
        if seq != primedSeq {
            let target = primeTarget.load(ordering: .acquiring)
            if flushGeneration.value.load(ordering: .acquiring) < target {   // feeder has not flushed for the seek yet
                guard wasPlaying else { return silence(l, r, count) }
                stamp(ring.pop(left: l, right: r, count: count), hostNanos)    // old material, shortage not counted
                return false
            }
            guard ring.availableToRead >= count else { return silence(l, r, count) }
            primedSeq = seq
        }
        wasPlaying = true
        fadeOutPos = fadeFrames
        let got = ring.pop(left: l, right: r, count: count)
        if got < count { underruns.add(1, ordering: .relaxed) }
        stamp(got, hostNanos)
        return false
    }

    private func stamp(_ n: Int, _ nanos: Int64) {
        guard n > 0 else { return }
        stampSeq.add(1, ordering: .acquiringAndReleasing)
        stampFrames.store(ring.consumedFrames, ordering: .relaxed)
        stampQuantum.store(Int64(n), ordering: .relaxed)
        stampNanos.store(nanos, ordering: .relaxed)
        stampSeq.add(1, ordering: .releasing)
    }

    private func silence(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ count: Int) -> Bool {
        l.update(repeating: 0, count: count); r.update(repeating: 0, count: count)
        return true
    }
}
