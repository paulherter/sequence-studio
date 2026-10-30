#if canImport(os)
import os
#endif

/// Instruments intervals of the timeline hot paths (subsystem `sq`, category `timeline`; Instruments > os_signpost or
/// Points of Interest). Names: `scrollWheel`, `scroll`, `zoomStep`, `draw`, `headerSync`, `waveformColumns`, `waveformBucketBuild`.
/// Cost while nothing records is a flag test per call.
public enum TimelineSignpost {
    #if canImport(os)
    public static let log = OSSignposter(subsystem: "sq", category: "timeline")
    #else
    /// No signposts off Apple platforms: the same calls, doing nothing.
    public struct NoSignposter: Sendable {
        public func beginInterval(_ name: StaticString) -> Int { 0 }
        public func endInterval(_ name: StaticString, _ state: Int) {}
    }
    public static let log = NoSignposter()
    #endif

    @inline(__always)
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = log.beginInterval(name)
        defer { log.endInterval(name, state) }
        return try body()
    }
}
