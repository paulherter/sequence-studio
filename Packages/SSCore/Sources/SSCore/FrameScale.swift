import Foundation

/// Scale semantics (Premiere): a clip's Scale of 100 % shows the picture at its own pixel size, one source pixel per
/// sequence pixel (upright size: a phone clip rotated 90 degrees counts with width and height swapped). A 4K clip in a
/// 1080 wide sequence therefore fills the width at 50 %. "Set to Frame Size" writes the fit value into Scale.
extension SequenceFormat {
    /// Scale at which a `w x h` picture fits the frame entirely (aspect kept, bars on one axis). 1 for a degenerate size.
    public func fitScale(width w: Int, height h: Int) -> Double {
        guard w > 0, h > 0, width > 0, height > 0 else { return 1 }
        return min(Double(width) / Double(w), Double(height) / Double(h))
    }
}

extension Project {
    /// Upright pixel size of what a clip shows: media display size (rotation applied), or the size of the nested
    /// sequence. nil for generators and for media without probe info.
    public func pictureSize(of clip: Clip) -> (width: Int, height: Int)? {
        if clip.isGenerator { return nil }
        if let s = clip.sequence {
            return timelines.first { $0.id == s }.map { ($0.format.width, $0.format.height) }
        }
        guard let v = media(clip.media)?.info?.video else { return nil }
        return (v.displayWidth, v.displayHeight)
    }

    /// Scale that fits `clip`'s picture into `timeline`'s frame; nil when the picture size is unknown (generator, no info).
    public func frameFitScale(of clip: Clip, in timeline: Timeline) -> Double? {
        guard let size = pictureSize(of: clip) else { return nil }
        return timeline.format.fitScale(width: size.width, height: size.height)
    }

    /// Premiere "Set to Frame Size": Scale of each picture clip becomes the fit value (keyframes of Scale are removed,
    /// position and rotation stay). Generators and clips of unknown size are skipped. Throws `.trackLocked` when a
    /// clip sits on a locked track, `.timelineNotFound` for an unknown timeline; nothing changes then.
    /// Returns the number of clips changed.
    @discardableResult
    public mutating func setToFrameSize(_ ids: Set<Clip.ID>, in timeline: Timeline.ID) throws -> Int {
        guard let ti = timelines.firstIndex(where: { $0.id == timeline }) else { throw EditError.timelineNotFound }
        var work = timelines[ti]
        var changed = 0
        for tr in work.tracks.indices where work.tracks[tr].kind == .video {
            for c in work.tracks[tr].clips where ids.contains(c.id) {
                guard let fit = frameFitScale(of: c, in: work) else { continue }
                if work.tracks[tr].isLocked { throw EditError.trackLocked }
                var n = c
                n.animation.scale = AnimatedProperty(Vec2(fit, fit))
                if n != c { work.tracks[tr].replace(n); changed += 1 }
            }
        }
        if changed > 0 { timelines[ti] = work }
        return changed
    }

    /// File v10: Scale used to be relative to the aspect-fitted picture (100 % = fit). It is now relative to the
    /// picture's own pixels, so every picture clip's Scale (value and keyframes) is multiplied by its fit scale and
    /// keeps its on-screen size. Generators, clips without probe info and stills are left alone.
    public mutating func migrateScaleToSourcePixels() {
        for ti in timelines.indices {
            var t = timelines[ti]
            for tr in t.tracks.indices where t.tracks[tr].kind == .video {
                for c in t.tracks[tr].clips where !c.isStill {
                    guard let f = frameFitScale(of: c, in: t), abs(f - 1) > 1e-12 else { continue }
                    var n = c
                    // Layer-local px are now native px (fit factor larger): the anchor shrinks by f to stay on the same point.
                    n.animation.anchor.value = Vec2(c.animation.anchor.value.x / f, c.animation.anchor.value.y / f)
                    n.animation.anchor.track.keys = c.animation.anchor.track.keys.map {
                        var k = $0
                        k.value = Vec2(k.value.x / f, k.value.y / f)
                        k.inTangent = Vec2(k.inTangent.x / f, k.inTangent.y / f)
                        k.outTangent = Vec2(k.outTangent.x / f, k.outTangent.y / f)
                        return k
                    }
                    n.animation.scale.value = Vec2(c.animation.scale.value.x * f, c.animation.scale.value.y * f)
                    n.animation.scale.track.keys = c.animation.scale.track.keys.map {
                        var k = $0
                        k.value = Vec2(k.value.x * f, k.value.y * f)
                        return k
                    }
                    t.tracks[tr].replace(n)
                }
            }
            timelines[ti] = t
        }
    }
}
