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

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        left = .allocate(capacity: capacity); right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity); right.initialize(repeating: 0, count: capacity)
    }
    deinit { left.deallocate(); right.deallocate() }

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
        readIndex.store(rd + Int64(n), ordering: .releasing)
        if n > 0 { consumed.add(Int64(n), ordering: .releasing) }
        return n
    }

    /// Producer. Drops everything pushed so far; the consumer discards it on its next `pop`.
    /// Data pushed after this call is kept.
    public func flush() {
        flushTarget.store(writeIndex.load(ordering: .relaxed), ordering: .releasing)
        flushEpoch.add(1, ordering: .releasing)
    }
}
