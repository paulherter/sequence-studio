import Foundation
import Synchronization
import SQAudioFX

/// Monitoring-only Solo/Mute of the output channels. The engine's source render blocks call `process` AFTER the block was
/// handed to the meter (`MeterDrain`), so a muted channel still moves its meter bar and loudness; export never creates one.
/// `set` may come from any thread; `process` runs on one render thread only (its ramp state is not shared).
public final class ChannelMonitorStage: @unchecked Sendable {
    private let mute = Atomic<UInt8>(0)
    private let solo = Atomic<UInt8>(0)
    private var current: (l: Float, r: Float) = (1, 1)   // render thread only

    public init() {}

    public func set(_ m: ChannelMonitor) {
        mute.store(m.muteMask, ordering: .releasing)
        solo.store(m.soloMask, ordering: .releasing)
    }

    public var state: ChannelMonitor {
        ChannelMonitor(muteMask: mute.load(ordering: .acquiring), soloMask: solo.load(ordering: .acquiring))
    }

    /// No allocation: safe on the render thread.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let s = state
        let l: Float = s.isAudible(0) ? 1 : 0, r: Float = s.isAudible(1) ? 1 : 0
        ChannelMonitor.applyRamp(left, count: count, from: current.l, to: l)
        ChannelMonitor.applyRamp(right, count: count, from: current.r, to: r)
        current = (l, r)
    }
}

/// Meter feed off the render thread: the render block pushes the unprocessed (pre-monitoring-gain) block into a lock-free
/// ring; a utility timer measures it in 1024-frame buffers, like the former tap on the source node did. The measurement
/// (Array copies, a mutex, BS.1770 filters) never runs in the render callback.
public final class MeterDrain: @unchecked Sendable {
    static let bufferFrames = 1024
    let ring = RingBuffer(capacity: 1 << 14)
    private let store: AudioMeterStore
    private let timer = Mutex<DispatchSourceTimer?>(nil)
    private let queue = DispatchQueue(label: "sq.audio.meter", qos: .utility)
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: MeterDrain.bufferFrames)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: MeterDrain.bufferFrames)

    public init(store: AudioMeterStore) {
        self.store = store
        left.initialize(repeating: 0, count: Self.bufferFrames)
        right.initialize(repeating: 0, count: Self.bufferFrames)
    }
    deinit { stop(); left.deallocate(); right.deallocate() }

    /// Render thread.
    @inline(__always) public func push(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int) {
        _ = ring.push(left: l, right: r, count: count)
    }

    /// Measures every complete buffer waiting; returns how many were measured. Serial queue only (tests call it directly).
    @discardableResult func drainOnce() -> Int {
        var n = 0
        while ring.availableToRead >= Self.bufferFrames {
            ring.pop(left: left, right: right, count: Self.bufferFrames)
            store.measure(left, right, count: Self.bufferFrames)
            n += 1
        }
        return n
    }

    public func start() {
        timer.withLock { t in
            guard t == nil else { return }
            _ = ring.flush()                    // frames left from before a stop/restart are not measured as a burst
            let s = DispatchSource.makeTimerSource(queue: queue)
            s.schedule(deadline: .now(), repeating: .milliseconds(10))
            s.setEventHandler { [weak self] in self?.drainOnce() }
            s.resume()
            t = s
        }
    }

    public func stop() { timer.withLock { $0?.cancel(); $0 = nil } }
}
