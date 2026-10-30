import SQCore

/// Poll gate for the timeline's render-cache strip, shared by the AppKit ruler and the shared timeline: asks the
/// engine for its cached spans at most every `interval` seconds, and only when the frame cache, the sequence length or
/// the undo step changed since the last look. Returns the new spans, or nil when nothing needs updating.
public struct CacheStripGate: Sendable {
    public var interval: Double
    private var lastKey: [Int] = []
    private var lastCheck: Double = -.infinity

    public init(interval: Double = 0.5) { self.interval = interval }

    public mutating func spans(now: Double, generation: Int, duration: Time?, undoName: String?,
                               fetch: () -> [TimeRange]) -> [TimeRange]? {
        guard now - lastCheck >= interval else { return nil }
        lastCheck = now
        let key = [generation, duration?.hashValue ?? 0, undoName?.hashValue ?? 0]
        guard key != lastKey else { return nil }
        lastKey = key
        return fetch()
    }
}
