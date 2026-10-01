import Darwin
import Synchronization

/// Lock-free single-producer / single-consumer stereo float ring (non-interleaved).
/// Producer = AudioFeeder thread (`push`, `flush`), consumer = audio render thread (`pop`). `push`/`pop` neither lock
/// nor allocate. Indices are monotonic frame counters, so `consumedFrames` doubles as the audio master clock counter.
public final class RingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int64>(0)
    private let readIndex = Atomic<Int64>(0)
    private let flushEpoch = Atomic<Int>(0)
    private let flushTarget = Atomic<Int64>(0)
    private let underruns = Atomic<Int>(0)
    private let consumed = Atomic<Int64>(0)
    private let consumerEpoch = Atomic<Int>(0)   // written by the consumer only

    // Flush acknowledgement (seqlock: odd sequence = consumer is writing). Written by the consumer only.
    private let ackSeq = Atomic<Int>(0)
    private let ackEpoch = Atomic<Int>(0)
    private let ackFrames = Atomic<Int64>(0)

    // Consumer-only fade state. `fadeFrames == 0` disables fades (plain flush).
    public let fadeFrames: Int
    private let staleNs: UInt64
    private let ramp: UnsafeMutablePointer<Float>          // raised cosine 0 -> 1, `fadeFrames` long
    private let tailL: UnsafeMutablePointer<Float>         // old audio following the last pop, for the fade-out
    private let tailR: UnsafeMutablePointer<Float>
    private var tailCount = 0
    private var lastPopEnd: UInt64 = 0
    private var tailUsable = 0, fadeOutPos = 0, fadeInPos = 0

    /// - Parameters:
    ///   - fadeFrames: length of the fade around a flush (5 ms = 240 frames at 48 kHz). 0 = no fades.
    ///   - staleAfter: if the consumer has not popped for this long (paused), the old tail is not played on a flush.
    public init(capacity: Int, fadeFrames: Int = 0, staleAfter: Double = 0.1) {
        precondition(capacity > 0 && fadeFrames >= 0)
        self.capacity = capacity
        self.fadeFrames = fadeFrames
        staleNs = UInt64(staleAfter * 1e9)
        let fl = max(1, fadeFrames)
        ramp = .allocate(capacity: fl); tailL = .allocate(capacity: fl); tailR = .allocate(capacity: fl)
        tailL.initialize(repeating: 0, count: fl); tailR.initialize(repeating: 0, count: fl)
        for k in 0..<fl { ramp[k] = Float(0.5 - 0.5 * cos(Double.pi * (Double(k) + 0.5) / Double(fl))) }
        left = .allocate(capacity: capacity); right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity); right.initialize(repeating: 0, count: capacity)
    }
    deinit { left.deallocate(); right.deallocate(); ramp.deallocate(); tailL.deallocate(); tailR.deallocate() }

    /// Frames the consumer can pop right now (flushed frames excluded).
    public var availableToRead: Int { Int(max(0, writeIndex.load(ordering: .acquiring) - effectiveRead())) }
    /// Frames the producer can push right now.
    public var availableToWrite: Int { capacity - availableToRead }
    /// Frames delivered to the consumer since creation (excludes flushed and underrun frames).
    public var consumedFrames: Int64 { consumed.load(ordering: .acquiring) }
    /// Number of `pop` calls that could not be served completely.
    public var underrunCount: Int { underruns.load(ordering: .relaxed) }

    /// Read position as seen by the producer: frames dropped by `flush` count as consumed even before the consumer
    /// has run again (so a flush while the consumer is paused frees the whole ring).
    private func effectiveRead() -> Int64 { max(readIndex.load(ordering: .acquiring), flushTarget.load(ordering: .acquiring)) }

    /// Producer. Copies as many of `count` frames as fit; returns the number accepted.
    public func push(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let rd = effectiveRead()
        let n = min(count, capacity - Int(w - rd))
        guard n > 0 else { return 0 }
        let pos = Int(w % Int64(capacity))
        let first = min(n, capacity - pos)
        left.advanced(by: pos).update(from: l, count: first)
        right.advanced(by: pos).update(from: r, count: first)
        if n > first {
            left.update(from: l + first, count: n - first)
            right.update(from: r + first, count: n - first)
        }
        writeIndex.store(w + Int64(n), ordering: .releasing)
        return n
    }

    /// Consumer. Fills `count` frames; any shortfall is zero-filled and counted as one underrun. Returns frames of real data.
    @discardableResult
    public func pop(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count: Int) -> Int {
        var rd = readIndex.load(ordering: .relaxed)
        let epoch = flushEpoch.load(ordering: .acquiring)
        if epoch != consumerEpoch.load(ordering: .relaxed) {
            rd = max(rd, flushTarget.load(ordering: .acquiring))
            consumerEpoch.store(epoch, ordering: .relaxed)
            publishAck(epoch: epoch, frames: consumed.load(ordering: .relaxed))
            beginFade()
        }
        let w = writeIndex.load(ordering: .acquiring)
        let n = max(0, min(count, Int(w - rd)))
        if n > 0 {
            let pos = Int(rd % Int64(capacity))
            let first = min(n, capacity - pos)
            l.update(from: left.advanced(by: pos), count: first)
            r.update(from: right.advanced(by: pos), count: first)
            if n > first {
                (l + first).update(from: left, count: n - first)
                (r + first).update(from: right, count: n - first)
            }
        }
        if n < count {
            (l + n).update(repeating: 0, count: count - n)
            (r + n).update(repeating: 0, count: count - n)
            underruns.add(1, ordering: .relaxed)
        }
        if fadeFrames > 0 {
            if fadeInPos < fadeFrames || fadeOutPos < fadeFrames { applyFade(l, r, count: count, real: n) }
            snapshotTail(at: rd + Int64(n))
        }
        readIndex.store(rd + Int64(n), ordering: .releasing)
        if n > 0 { consumed.add(Int64(n), ordering: .releasing) }
        return n
    }

    /// Latest flush the consumer has applied, with `consumedFrames` at that moment (frames popped before the cut).
    /// A clock that called `flush()` (epoch `e`) and wants to re-base exactly waits until `epoch >= e`, then counts
    /// `consumedFrames - frames` as time elapsed in the new anchor. `epoch == 0` = no flush applied yet.
    public var consumedAtEpoch: (epoch: Int, frames: Int64) {
        while true {
            let s1 = ackSeq.load(ordering: .acquiring)
            if s1 & 1 == 1 { continue }
            let e = ackEpoch.load(ordering: .relaxed), f = ackFrames.load(ordering: .relaxed)
            atomicMemoryFence(ordering: .acquiring)      // keep the data loads before the recheck (arm64)
            if ackSeq.load(ordering: .relaxed) == s1 { return (e, f) }
        }
    }

    private func publishAck(epoch: Int, frames: Int64) {
        ackSeq.add(1, ordering: .acquiringAndReleasing)
        ackEpoch.store(epoch, ordering: .relaxed); ackFrames.store(frames, ordering: .relaxed)
        ackSeq.add(1, ordering: .releasing)
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Consumer: a flush was just applied. Fade-in starts on the first real new frame; the old tail (if the consumer
    /// was actively playing) fades out over the first `fadeFrames` output frames, cross-faded with the new material.
    private func beginFade() {
        guard fadeFrames > 0 else { return }
        fadeInPos = 0; fadeOutPos = 0
        let active = lastPopEnd != 0 && Self.now() &- lastPopEnd <= staleNs
        tailUsable = active ? tailCount : 0
    }

    private func applyFade(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, count: Int, real n: Int) {
        for j in 0..<count {
            // With an old tail the two ramps advance together (crossfade stays at unity even on a partial pop);
            // without one, fade-in waits for real data.
            if fadeInPos < fadeFrames && (j < n || tailUsable > 0) {
                if j < n { let g = ramp[fadeInPos]; l[j] *= g; r[j] *= g }
                fadeInPos += 1
            }
            if fadeOutPos < fadeFrames {
                if fadeOutPos < tailUsable {
                    let g = 1 - ramp[fadeOutPos]
                    l[j] += tailL[fadeOutPos] * g; r[j] += tailR[fadeOutPos] * g
                }
                fadeOutPos += 1
            }
        }
    }

    /// Copies up to `fadeFrames` frames that follow the read position (what would have played next).
    private func snapshotTail(at pos: Int64) {
        let w = writeIndex.load(ordering: .acquiring)
        let n = max(0, min(fadeFrames, Int(w - pos)))
        let epoch = consumerEpoch.load(ordering: .relaxed)
        if n > 0 {
            let p = Int(pos % Int64(capacity)), first = min(n, capacity - p)
            tailL.update(from: left.advanced(by: p), count: first); tailR.update(from: right.advanced(by: p), count: first)
            if n > first {
                (tailL + first).update(from: left, count: n - first); (tailR + first).update(from: right, count: n - first)
            }
        }
        atomicMemoryFence(ordering: .acquiringAndReleasing)   // order the copy before the epoch recheck
        // A flush that raced the copy makes the snapshot (possibly overwritten by the producer) unusable.
        tailCount = flushEpoch.load(ordering: .acquiring) == epoch ? n : 0
        lastPopEnd = Self.now()
    }

    /// Producer. Drops everything pushed so far; the consumer discards it on its next `pop`.
    /// Data pushed after this call is kept. Returns the flush epoch; `consumedAtEpoch.epoch >= epoch` once the
    /// consumer has applied it (several flushes before one `pop` are applied together, as the latest).
    @discardableResult
    public func flush() -> Int {
        flushTarget.store(writeIndex.load(ordering: .relaxed), ordering: .releasing)
        return flushEpoch.add(1, ordering: .releasing).newValue
    }
}
