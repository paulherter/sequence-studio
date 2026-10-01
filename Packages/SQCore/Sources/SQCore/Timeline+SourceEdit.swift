import Foundation

/// Which streams of a source an edit places (Premiere: the video-only / audio-only drag icons).
public enum SourceStreams: String, Sendable, Hashable { case both, videoOnly, audioOnly }

extension SourceStreams {
    public var includesVideo: Bool { self != .audioOnly }
    public var includesAudio: Bool { self != .videoOnly }
}

/// Source Monitor Insert / Overwrite: which part of the source, where on the sequence, onto which tracks.
extension Timeline {
    /// Source range of an edit: In defaults to the media start, Out to its end. nil when the range is empty.
    public static func sourceEditRange(marks: SourceMarks, total: Time) -> TimeRange? {
        let start = max(marks.markIn ?? .zero, .zero)
        let end = min(marks.markOut ?? total, total)
        return end > start ? TimeRange(start: start, end: end) : nil
    }

    /// Where the edit lands: the sequence In point when one is set, else the playhead (Premiere three-point rule;
    /// the sequence Out does not shorten the source here because our In/Out always carries both ends).
    public func sourceEditPosition(playhead: Time) -> Time { inOut?.start ?? playhead }

    /// Destination tracks. The edit uses the source-patched tracks (first patched video, first patched audio; see
    /// `Timeline+SourcePatch.swift`, track targets play no part); a kind without a patched track is dropped (Premiere).
    /// With no patched track at all the default drop rule applies
    /// (V1 and its mirrored audio track, created when missing). Returns nil when nothing is left to place.
    public mutating func sourceEditTargets(hasVideo: Bool, hasAudio: Bool, streams: SourceStreams = .both) -> [Track.ID]? {
        let wantV = hasVideo && streams.includesVideo, wantA = hasAudio && streams.includesAudio
        guard wantV || wantA else { return nil }
        var out: [Track.ID] = []
        if tracks.contains(where: \.isSourcePatched) {
            if wantV, let v = tracks.first(where: { $0.kind == .video && $0.isSourcePatched }) { out.append(v.id) }
            if wantA, let a = tracks.first(where: { $0.kind == .audio && $0.isSourcePatched }) { out.append(a.id) }
        } else {
            let d = dropTargets(pointer: nil, hasVideo: wantV, hasAudio: wantA)
            if let v = d.video { out.append(v) }
            if let a = d.audio { out.append(a) } else if let n = d.newAudioOrdinal { out.append(ensureAudioTrack(atOrdinal: n)) }
        }
        return out.isEmpty ? nil : out
    }

    /// One-clip sequence that the Source Monitor plays: V1 (+ A1) holding the whole media, in the media's own format.
    public static func sourceTimeline(media: MediaRef, format: SequenceFormat, hasVideo: Bool, hasAudio: Bool,
                                      duration: Time, isStill: Bool) -> Timeline {
        var v = Track(kind: .video), a = Track(kind: .audio)
        let link: UUID? = hasVideo && hasAudio ? UUID() : nil
        func clip(_ k: TrackKind) -> Clip {
            Clip(name: media.name, media: media.id, kind: k, source: TimeRange(start: .zero, duration: duration), start: .zero,
                 link: link, mediaDuration: isStill ? nil : duration, isStill: isStill)
        }
        var tracks: [Track] = []
        if hasVideo { try? v.overwrite(clip(.video)) }
        if hasAudio { try? a.overwrite(clip(.audio)) }
        if hasVideo || !hasAudio { tracks.append(v) }
        if hasAudio { tracks.append(a) }
        return Timeline(name: media.name, format: format, tracks: tracks, formatLocked: true)
    }
}
