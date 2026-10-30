import Foundation

extension Timeline {
    /// Split source edit (Mark Audio In / Mark Video In): picture and sound of one source start at different source
    /// points and end together at `out`. The picture lands at `at`, the sound `videoIn - audioIn` earlier (a J cut; later
    /// for a negative lead, an L start), and the clips share one link. Insert ripples with the picture; the sound is
    /// laid over its tracks. A sound start before sequence time 0 moves its source start up by the overshoot. One
    /// atomic edit: any failure throws before `self` changes. Not for Fast Cut sequences (`.collision`, callers use the
    /// plain source edit there).
    public mutating func splitSourceEdit(media: UUID, name: String = "", videoIn: Time, audioIn: Time, out: Time,
                                         mediaDuration: Time? = nil, initialScale: Double = 1,
                                         videoTracks: [Track.ID], audioTracks: [Track.ID], at: Time,
                                         mode: ThreePointMode) throws {
        guard !isFastCut else { throw EditError.collision }
        guard out > videoIn, out > audioIn, videoIn >= .zero, audioIn >= .zero else { throw EditError.emptyClip }
        if let md = mediaDuration, out > md { throw EditError.emptyClip }
        guard !videoTracks.isEmpty, !audioTracks.isEmpty else { throw EditError.clipNotFound }
        var work = self
        let link = UUID()
        var audioStart = at - (videoIn - audioIn)
        var audioSource = audioIn
        if audioStart < .zero {
            audioSource = audioIn - audioStart
            audioStart = .zero
            guard out > audioSource else { throw EditError.emptyClip }
        }
        func placements(_ ids: [Track.ID], source: TimeRange) throws -> [(clip: Clip, track: Track.ID)] {
            try ids.map { id in
                guard let tr = work.track(id) else { throw EditError.clipNotFound }
                var c = Clip(name: name, media: media, kind: tr.kind, source: source, start: .zero, link: link, mediaDuration: mediaDuration)
                if tr.kind == .video, abs(initialScale - 1) > 1e-12 { c.animation.scale = AnimatedProperty(Vec2(initialScale, initialScale)) }
                return (c, id)
            }
        }
        let v = try placements(videoTracks, source: TimeRange(start: videoIn, end: out))
        let a = try placements(audioTracks, source: TimeRange(start: audioSource, end: out))
        switch mode {
        case .insert: try work.insert(v, at: at)
        case .overwrite: try work.overwrite(v, at: at)
        }
        try work.overwrite(a, at: audioStart)
        self = work
    }
}
