import Foundation

/// A stretch of the sequence that playback reads from a rendered cache file (`RenderCacheStore`) instead of compositing.
/// The file holds the segment at sequence size, starting at file time 0.
public struct RenderCacheSpan: Sendable, Hashable {
    public var range: TimeRange
    /// Media ID the file is registered under in the media resolver (`RenderCacheMedia.id(forKey:)`).
    public var media: UUID
    public init(range: TimeRange, media: UUID) { self.range = range; self.media = media }
}

public enum RenderCacheMedia {
    /// The media ID of a segment file: the 128 key bits as a UUID, so the same content always has the same ID (the decoded
    /// frames in the frame cache stay valid across edits that keep the key).
    public static func id(forKey key: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let chars = Array(key.utf8)
        func v(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : c - 48 }
        for i in 0..<16 where i * 2 + 1 < chars.count { bytes[i] = v(chars[i * 2]) << 4 | v(chars[i * 2 + 1]) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                           bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension Timeline {
    /// The sequence as playback shows it with the cache: every heavy segment whose key has a file becomes a span. The
    /// timeline itself is unchanged (edit, save and undo never see the spans). Spans are recomputed from the keys on every
    /// push, so an edit that changes a segment drops its span in the same step.
    public func withRenderCache(segments: [RenderCacheSegment], index: RenderCacheIndex) -> Timeline {
        var t = self
        t.renderCacheSpans = segments.filter { $0.isHeavy && index.contains($0.key) }
            .map { RenderCacheSpan(range: $0.range, media: RenderCacheMedia.id(forKey: $0.key)) }
        return t
    }
}
