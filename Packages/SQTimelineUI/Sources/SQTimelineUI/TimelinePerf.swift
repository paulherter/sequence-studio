import Foundation

/// Opt-in timing of the first scroll and zoom steps after a timeline is created (`SQ_TIMELINE_PERF=1`).
/// A step = the handler (`scroll(byX:y:)` / `setZoom`) plus the draw that follows it. Cost buckets are summed over the step.
/// When the variable is unset every entry point is one `Bool` test.
@MainActor
final class TimelinePerf {
    enum Kind: String { case scroll, zoom }
    enum Bucket: Int, CaseIterable { case rows, names, waveform, other }

    static let envEnabled: Bool = ProcessInfo.processInfo.environment["SQ_TIMELINE_PERF"] == "1"
    static let stepLimit = 30
    let enabled: Bool
    init(enabled: Bool = TimelinePerf.envEnabled) { self.enabled = enabled }

    private(set) var counts: [Kind: Int] = [.scroll: 0, .zoom: 0]
    private var pending: (kind: Kind, handlerNs: UInt64)?
    private var handlerStart: UInt64 = 0
    private var drawStart: UInt64 = 0
    private var buckets = [UInt64](repeating: 0, count: Bucket.allCases.count)
    /// Lines of the steps logged so far (read by tests); the log goes to NSLog too.
    private(set) var lines: [String] = []
    var sink: (String) -> Void = { NSLog("%@", $0) }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func beginHandler(_ kind: Kind) {
        guard enabled, (counts[kind] ?? 0) < Self.stepLimit else { return }
        pending = (kind, 0)
        handlerStart = Self.now()
    }

    func endHandler() {
        guard enabled, pending != nil else { return }
        pending?.handlerNs = Self.now() &- handlerStart
    }

    func beginDraw() { if enabled { drawStart = Self.now() } }

    /// Adds `ns` to a cost bucket of the draw in flight.
    func add(_ bucket: Bucket, ns: UInt64) { if enabled { buckets[bucket.rawValue] &+= ns } }

    @inline(__always) func time<T>(_ bucket: Bucket, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let t0 = Self.now()
        let r = body()
        buckets[bucket.rawValue] &+= Self.now() &- t0
        return r
    }

    func endDraw() {
        guard enabled else { return }
        defer { pending = nil; for i in buckets.indices { buckets[i] = 0 } }
        guard let p = pending else { return }
        let drawNs = Self.now() &- drawStart
        let n = (counts[p.kind] ?? 0) + 1
        counts[p.kind] = n
        func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1e6) }
        let b = buckets
        let line = "TimelinePerf \(p.kind.rawValue) #\(n): total \(ms(p.handlerNs + drawNs)) ms | handler \(ms(p.handlerNs)) draw \(ms(drawNs))"
            + " (rows \(ms(b[Bucket.rows.rawValue])) names \(ms(b[Bucket.names.rawValue])) waveform \(ms(b[Bucket.waveform.rawValue])))"
        lines.append(line)
        sink(line)
    }
}
