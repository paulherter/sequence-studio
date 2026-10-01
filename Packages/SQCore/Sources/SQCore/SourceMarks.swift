import Foundation

/// Source-monitor In/Out for one media item. Each side is optional.
public struct SourceMarks: Sendable, Hashable, Codable {
    public var markIn: Time?
    public var markOut: Time?

    public init(markIn: Time? = nil, markOut: Time? = nil) { self.markIn = markIn; self.markOut = markOut }

    public var isEmpty: Bool { markIn == nil && markOut == nil }

    /// In/Out as a range when both are set and Out is after In.
    public var range: TimeRange? {
        guard let i = markIn, let o = markOut, o > i else { return nil }
        return TimeRange(start: i, end: o)
    }
}

extension Project {
    public func sourceMarks(for media: MediaRef.ID) -> SourceMarks { sourceMarks[media] ?? SourceMarks() }

    /// Sets In. An existing Out at or before the new In is cleared (Premiere behaviour).
    public mutating func setSourceIn(_ t: Time, for media: MediaRef.ID) {
        var m = sourceMarks(for: media)
        m.markIn = t
        if let o = m.markOut, o <= t { m.markOut = nil }
        sourceMarks[media] = m
    }

    /// Sets Out. An existing In at or after the new Out is cleared.
    public mutating func setSourceOut(_ t: Time, for media: MediaRef.ID) {
        var m = sourceMarks(for: media)
        m.markOut = t
        if let i = m.markIn, i >= t { m.markIn = nil }
        sourceMarks[media] = m
    }

    public mutating func clearSourceIn(for media: MediaRef.ID) { updateMarks(media) { $0.markIn = nil } }
    public mutating func clearSourceOut(for media: MediaRef.ID) { updateMarks(media) { $0.markOut = nil } }
    public mutating func clearSourceMarks(for media: MediaRef.ID) { sourceMarks[media] = nil }

    private mutating func updateMarks(_ media: MediaRef.ID, _ body: (inout SourceMarks) -> Void) {
        guard var m = sourceMarks[media] else { return }
        body(&m)
        sourceMarks[media] = m.isEmpty ? nil : m
    }
}
