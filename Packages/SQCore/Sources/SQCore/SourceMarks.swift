import Foundation

/// Source-monitor In/Out for one media item. Each side is optional.
public struct SourceMarks: Sendable, Hashable, Codable {
    public var markIn: Time?
    public var markOut: Time?
    /// Split In points (Mark Audio In / Mark Video In): where the sound or the picture starts when it differs from `markIn`.
    /// Nil = follows `markIn`. Used by the source edit (`Timeline.splitSourceEdit`), cleared by a new plain In.
    public var audioIn: Time?
    public var videoIn: Time?

    public init(markIn: Time? = nil, markOut: Time? = nil, audioIn: Time? = nil, videoIn: Time? = nil) {
        self.markIn = markIn; self.markOut = markOut; self.audioIn = audioIn; self.videoIn = videoIn
    }

    public var isEmpty: Bool { markIn == nil && markOut == nil && audioIn == nil && videoIn == nil }

    /// The picture and sound start points of a split edit, nil unless they differ (and both lie before `markOut` when set).
    public func splitIns(total: Time) -> (video: Time, audio: Time, out: Time)? {
        guard audioIn != nil || videoIn != nil else { return nil }
        let base = markIn ?? .zero
        let v = videoIn ?? base, a = audioIn ?? base, o = markOut ?? total
        guard v != a, o > v, o > a else { return nil }
        return (v, a, o)
    }

    /// In/Out as a range when both are set and Out is after In.
    public var range: TimeRange? {
        guard let i = markIn, let o = markOut, o > i else { return nil }
        return TimeRange(start: i, end: o)
    }
}

extension Project {
    public func sourceMarks(for media: MediaRef.ID) -> SourceMarks { sourceMarks[media] ?? SourceMarks() }

    /// Sets In. An existing Out at or before the new In is cleared (Premiere behavior).
    public mutating func setSourceIn(_ t: Time, for media: MediaRef.ID) {
        var m = sourceMarks(for: media)
        m.markIn = t
        m.audioIn = nil; m.videoIn = nil
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

    /// Mark Audio In / Mark Video In: the sound or picture starts at `t` while the other keeps In.
    public mutating func setSourceAudioIn(_ t: Time, for media: MediaRef.ID) { var m = sourceMarks(for: media); m.audioIn = t; sourceMarks[media] = m }
    public mutating func setSourceVideoIn(_ t: Time, for media: MediaRef.ID) { var m = sourceMarks(for: media); m.videoIn = t; sourceMarks[media] = m }

    public mutating func clearSourceIn(for media: MediaRef.ID) { updateMarks(media) { $0.markIn = nil; $0.audioIn = nil; $0.videoIn = nil } }
    public mutating func clearSourceOut(for media: MediaRef.ID) { updateMarks(media) { $0.markOut = nil } }
    public mutating func clearSourceMarks(for media: MediaRef.ID) { sourceMarks[media] = nil }

    private mutating func updateMarks(_ media: MediaRef.ID, _ body: (inout SourceMarks) -> Void) {
        guard var m = sourceMarks[media] else { return }
        body(&m)
        sourceMarks[media] = m.isEmpty ? nil : m
    }
}
