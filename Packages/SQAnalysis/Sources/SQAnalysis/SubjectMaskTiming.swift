import Foundation
import Synchronization

/// Where the time of a subject mask goes: `SQ_MASK_TIMING=1` logs, per run of `MagicMaskTracker.track` and per model
/// load, the wall time and the stages counted in `spent` (`[SubjectMask] timing ...`). The stages are
/// counted always (a clock read per stage); only the log is switched.
enum SubjectMaskTiming {
    /// Seconds and calls per part since the last `takeTimings()` (the benchmark's per-part ms).
    static let spent = Mutex<[String: (seconds: Double, calls: Int)]>([:])

    /// "name ms/call (calls)" per part, and clears them.
    static func takeTimings() -> String {
        let all = spent.withLock { let v = $0; $0 = [:]; return v }
        return all.sorted { $0.key < $1.key }.map { String(format: "%@ %.1f ms (x%d)", $0.key, $0.value.seconds * 1000 / Double(max($0.value.calls, 1)), $0.value.calls) }.joined(separator: ", ")
    }

    /// Adds the time since `began` (`DispatchTime` nanoseconds) to part `name`.
    static func count(_ name: String, since began: UInt64) {
        let took = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        spent.withLock { $0[name, default: (0, 0)].seconds += took; $0[name, default: (0, 0)].calls += 1 }
    }

    static let enabled = ProcessInfo.processInfo.environment["SQ_MASK_TIMING"] == "1"

    /// `work`, counted under `name`.
    @inline(__always)
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let began = DispatchTime.now().uptimeNanoseconds
        defer { count(name, since: began) }
        return try work()
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Logs `what` with its wall time since `began` and the stages counted since the last log (and clears them).
    static func report(_ what: String, since began: UInt64, frames: Int? = nil) {
        guard enabled else { return }
        let wall = Double(now() - began) / 1e9
        let perFrame = frames.map { String(format: ", %d frames, %.1f ms/frame", $0, wall * 1000 / Double(max($0, 1))) } ?? ""
        NSLog("[SubjectMask] timing %@: %.2f s%@; %@", what, wall, perFrame, takeTimings())
    }
}
