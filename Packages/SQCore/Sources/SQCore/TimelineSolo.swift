import Foundation

extension Clip {
    /// The Color page's solo picture of this clip (DECISIONS: "Color solo = raw source + grade"): the same id, media,
    /// footage interpretation and Color effects (base and range grades), and nothing else. Transform, opacity, keys of
    /// Motion, blend mode, crop, masks, stabilization, every other effect, baked effects and variant overrides are left
    /// out, so the picture is the file as it is with only the grade on it. `scale` is the (static) Scale that fits the
    /// picture into the viewer. Timing (start, source, speed) is the caller's.
    func colorSoloPicture(scale: Double = 1) -> Clip {
        var c = Clip(id: id, name: name, media: media, kind: .video, source: source, start: start, link: nil,
                     mediaDuration: mediaDuration)
        c.isStill = isStill
        c.footageColor = footageColor
        c.gradeLink = gradeLink
        c.gradeIndependent = gradeIndependent
        c.effects = effects.filter(\.isColor)
        c.animation.scale = AnimatedProperty(Vec2(scale, scale))
        return c
    }
}

extension Timeline {
    /// The sequence as the Color page's Clips mode shows one source clip that has no file axis to scrub (a still):
    /// every video track that does not hold the clip is hidden, the clip's own track keeps no transitions and the clip
    /// itself is reduced to its raw picture plus its grade (`Clip.colorSoloPicture`), fitted into the frame when its
    /// upright pixel size `picture` is known. Generators and nested clips stay as they are (their picture is what they
    /// render). Audio tracks are untouched. An unknown id returns the timeline unchanged.
    public func soloingVideoClip(_ id: Clip.ID, picture: (width: Int, height: Int)? = nil) -> Timeline {
        guard tracks.contains(where: { $0.kind == .video && $0.clips.contains { $0.id == id } }) else { return self }
        var t = self
        for i in t.tracks.indices where t.tracks[i].kind == .video {
            if let c = t.tracks[i].clips.first(where: { $0.id == id }) {
                t.tracks[i].transitions = []
                if !c.isGenerator, !c.isNested {
                    let fit = picture.map { format.fitScale(width: $0.width, height: $0.height) } ?? 1
                    var raw = c.colorSoloPicture(scale: fit)
                    raw.speed = c.speed; raw.reversed = c.reversed; raw.speedKeys = c.speedKeys; raw.holdFrame = c.holdFrame
                    raw.isEnabled = true
                    t.tracks[i].replace(raw)
                }
            } else {
                t.tracks[i].isVisible = false
            }
        }
        return t
    }
}

/// What the Program monitor plays on the Color page while a source clip is picked in the Clips strip: the clip's whole
/// media file at normal speed, on its own time axis (file time) and in its own frame size and rate, with only the clip's
/// grade on it (`Clip.colorSoloPicture`). `position` is the file frame to open on.
public struct ColorSourceFileView: Sendable, Hashable {
    public var clipID: Clip.ID
    public var timeline: Timeline
    public var position: Time
}

extension Timeline {
    /// The source-file view of video clip `id` (`ColorSourceFileView`), opened on the source frame shown at sequence time
    /// `playhead` (the clip's first frame when the playhead is outside it). One video track holds the clip's raw picture
    /// with its grade (same id, so compare / bypass by clip id applies) over the whole file from 0, at 100 % and identity
    /// geometry. Grade keys move from clip-local time to the start of the source frame the clip shows there
    /// (`ClipEffect.soloMapped`), so every file frame the clip uses gets the values the timeline shows on it; outside the
    /// used part the first / last values hold. A frame hold has no source axis: its grade is frozen at the playhead.
    /// `position` is the file frame containing the shown source time (floor, as the decoder picks it).
    /// `picture`: the file's probe info; the view then has the file's upright size and nominal frame rate (Scale 100 % =
    /// the file's own pixels = the whole frame), else the sequence's format. A linked audio clip of the same media adds
    /// the file's audio. nil for generators, nested sequences, stills and clips without a known media length: nothing to
    /// scrub (the caller solos the clip in place with `soloingVideoClip`).
    public func colorSourceFileView(of id: Clip.ID, at playhead: Time, picture: VideoTrackInfo? = nil) -> ColorSourceFileView? {
        guard let clip = tracks.lazy.filter({ $0.kind == .video }).compactMap({ $0.clips.first { $0.id == id } }).first,
              !clip.isGenerator, clip.sequence == nil, !clip.isStill, let length = clip.mediaDuration, length > .zero else { return nil }
        let inside = clip.timeline.contains(playhead)
        let at = inside ? clip.sourceTime(at: playhead, frameDuration: frameDuration)
            : (clip.reversed ? clip.source.end - frameDuration : clip.source.start)
        var viewFormat = format
        if let p = picture, p.displayWidth > 0, p.displayHeight > 0 {
            viewFormat.width = p.displayWidth
            viewFormat.height = p.displayHeight
            if p.nominalFrameDuration > .zero { viewFormat.frameDuration = p.nominalFrameDuration }
        }
        var c = clip.colorSoloPicture()
        c.start = .zero
        c.source = TimeRange(start: .zero, duration: length)
        c.isEnabled = true
        if clip.holdFrame != nil {
            // No source axis: the grade frozen at the playhead; a range grade shows over the whole view exactly when it
            // graded the held frame there (as `Clip.freezeFrame`), else not at all.
            let local = inside ? playhead - clip.start : .zero
            c.effects = c.effects.compactMap { e in
                var f = e.frozen(atLocal: local)
                guard let r = e.colorRange else { return f }
                guard r.contains(local) else { return nil }
                f.colorRange = TimeRange(start: .zero, duration: length)
                f.colorFadeIn = nil; f.colorFadeOut = nil
                return f
            }
        } else {
            c.effects = c.effects.map { $0.soloMapped(from: clip, frameDuration: frameDuration) }
        }
        var v = Track(kind: .video)
        try? v.overwrite(c)
        var out = [v]
        if let link = clip.link,
           let a = tracks.lazy.filter({ $0.kind == .audio }).compactMap({ $0.clips.first { $0.link == link && $0.media == clip.media } }).first {
            var t = Track(kind: .audio)
            try? t.overwrite(Clip(id: a.id, name: a.name, media: a.media, kind: .audio, source: TimeRange(start: .zero, duration: length),
                            start: .zero, mediaDuration: length))
            out.append(t)
        }
        let fd = viewFormat.frameDuration
        let last = max(.zero, length - fd)
        return ColorSourceFileView(clipID: id, timeline: Timeline(name: clip.name, format: viewFormat, tracks: out),
                                   position: min(max(.zero, at), last).flooredToFrame(fd))
    }
}

extension Time {
    /// Start of the frame of `frameDuration` that contains this time (floor).
    public func flooredToFrame(_ frameDuration: Time) -> Time {
        guard frameDuration > .zero else { return self }
        return frameDuration * frameIndex(frameDuration: frameDuration)
    }
}

extension ClipEffect {
    /// This effect of `clip` on the solo view's file axis. Keys: clip-local time L -> start of the source frame the
    /// timeline shows at L (`Clip.sourceTime` convention, so a reversed frame is the one ending at the mapped instant).
    /// A map that runs backwards (reverse) mirrors each track: handles and spatial tangents swap sides, each segment
    /// keeps its own interpolation (the left key's), and a hold segment, which must hold its timeline-left key's value
    /// on the right, gets a hold key just after its file-left key. A map that is neither (time remapping that changes
    /// direction) is only sorted. Range grades map through the instants (the frames they cover); a reversed range swaps
    /// its fades.
    func soloMapped(from clip: Clip, frameDuration fd: Time) -> ClipEffect {
        func key(_ l: Time) -> Time {
            if let k = clip.speedKeys { return k.sourceTime(at: l, frameDuration: fd) }
            return clip.reversed ? clip.sourceInstant(atLocal: l) - clip.speed.scale(fd) : clip.sourceInstant(atLocal: l)
        }
        var e = self
        e.parameters = parameters.mapValues { $0.soloMapped(key) }
        e.colors = colors.mapValues { $0.soloMapped(key) }
        e.points = points.mapValues { $0.soloMapped(key) }
        if let r = colorRange {
            let a = clip.sourceInstant(atLocal: r.start), b = clip.sourceInstant(atLocal: r.end)
            e.colorRange = TimeRange(start: min(a, b), end: max(a, b))
            func dist(_ x: Time, _ y: Time) -> Time { x < y ? y - x : x - y }
            let fin = colorFadeIn.map { dist(clip.sourceInstant(atLocal: r.start + $0), a) }
            let fout = colorFadeOut.map { dist(clip.sourceInstant(atLocal: r.end - $0), b) }
            if b < a { e.colorFadeIn = fout; e.colorFadeOut = fin } else { e.colorFadeIn = fin; e.colorFadeOut = fout }
        }
        return e
    }
}

extension AnimatedProperty {
    /// The key track through the time map `f` (see `ClipEffect.soloMapped`): the one remap every retime and reverse
    /// uses (`remapped`), so the keys are the user's.
    fileprivate func soloMapped(_ f: (Time) -> Time) -> AnimatedProperty { remapped(f) }
}
