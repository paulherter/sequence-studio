import Foundation

/// What is visible at one instant for one track.
public struct LayerRequest: Sendable, Hashable {
    public var clip: Clip.ID, media: UUID, track: Track.ID
    /// `clip.source.start + (t - clip.start)`
    public var sourceTime: Time
    /// Evaluated (clamped) transform of the clip at this instant.
    public var transform: ClipTransform

    public init(clip: Clip.ID, media: UUID, track: Track.ID, sourceTime: Time, transform: ClipTransform = .identity) {
        self.clip = clip; self.media = media; self.track = track; self.sourceTime = sourceTime
        self.transform = transform
    }
}

/// One clip's contribution to a timeline range.
public struct AudioSegment: Sendable, Hashable {
    public var clip: Clip.ID, media: UUID, track: Track.ID
    public var timeline: TimeRange, sourceStart: Time

    public init(clip: Clip.ID, media: UUID, track: Track.ID, timeline: TimeRange, sourceStart: Time) {
        self.clip = clip; self.media = media; self.track = track
        self.timeline = timeline; self.sourceStart = sourceStart
    }
}

extension Timeline {
    /// Visible layers at `t`, bottom to top (first video track first). Hidden tracks and gaps are omitted.
    public func videoLayers(at t: Time) -> [LayerRequest] {
        tracks.compactMap { track -> LayerRequest? in
            guard track.kind == .video, track.isVisible,
                  let c = track.clips.first(where: { $0.timeline.contains(t) }) else { return nil }
            return LayerRequest(clip: c.id, media: c.media, track: track.id,
                                sourceTime: c.source.start + (t - c.start),
                                transform: c.transform(at: t))
        }
    }

    /// Audible clip pieces inside `range`. If any audio track is solo only solo tracks sound; muted tracks never.
    public func audioSegments(in range: TimeRange) -> [AudioSegment] {
        let audio = tracks.filter { $0.kind == .audio }
        let anySolo = audio.contains { $0.isSolo }
        var out: [AudioSegment] = []
        for track in audio where !track.isMuted && (!anySolo || track.isSolo) {
            for c in track.clips {
                guard let r = c.timeline.intersection(range), !r.isEmpty else { continue }
                out.append(AudioSegment(clip: c.id, media: c.media, track: track.id,
                                        timeline: r, sourceStart: c.source.start + (r.start - c.start)))
            }
        }
        return out
    }

    /// Sorted, unique clip starts and ends over all tracks.
    public func editPoints() -> [Time] {
        var set = Set<Time>()
        for track in tracks {
            for c in track.clips { set.insert(c.start); set.insert(c.timeline.end) }
        }
        return set.sorted()
    }

    /// End of the last clip; `.zero` when empty.
    public var duration: Time { tracks.map(\.end).max() ?? .zero }
}
