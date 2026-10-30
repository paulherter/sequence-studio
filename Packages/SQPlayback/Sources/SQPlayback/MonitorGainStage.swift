import Foundation
import Synchronization
import SQAudioFX

/// Listening level (F7.5) applied on the render thread: for an output that has no mixer volume to drive (the Windows
/// WASAPI sink). The Mac AudioEngine ramps its main mixer through `MonitorGainDriver` instead. Runs after the meter push,
/// so meters and loudness never move with it; export never creates one. A change ramps over one block (no click).
/// `set` may come from any thread; `process` runs on one render thread only (its ramp state is not shared).
public final class MonitorGainStage: @unchecked Sendable {
    private let target: Atomic<UInt32>
    private var current: Float   // render thread only

    public init(linear: Float = 1) {
        target = Atomic(linear.bitPattern)
        current = linear
    }

    public func set(_ setting: MonitorGain.Setting) { set(linear: setting.linear) }
    public func set(linear: Float) { target.store(max(0, linear).bitPattern, ordering: .releasing) }
    public var linear: Float { Float(bitPattern: target.load(ordering: .acquiring)) }

    /// No allocation: safe on the render thread.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let to = linear
        ChannelMonitor.applyRamp(left, count: count, from: current, to: to)
        ChannelMonitor.applyRamp(right, count: count, from: current, to: to)
        current = to
    }
}
