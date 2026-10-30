import Foundation

/// Scale semantics (Premiere): a clip's Scale of 100 % shows the picture at its own pixel size, one source pixel per
/// sequence pixel (upright size: a phone clip rotated 90 degrees counts with width and height swapped). A 4K clip in a
/// 1080 wide sequence therefore fills the width at 50 %. "Fit to Frame" writes the fit value into Scale.
extension SequenceFormat {
    /// Scale at which a `w x h` picture fits the frame entirely (aspect kept, bars on one axis). 1 for a degenerate size.
    public func fitScale(width w: Int, height h: Int) -> Double {
        guard w > 0, h > 0, width > 0, height > 0 else { return 1 }
        return min(Double(displayWidth) / Double(w), Double(height) / Double(h))
    }
}

extension SequenceFormat {
    /// Scale at which a `w x h` picture covers the frame entirely (aspect kept, edges cropped on one axis): Premiere
    /// "Set to Fill Frame". 1 for a degenerate size.
    public func fillScale(width w: Int, height h: Int) -> Double {
        guard w > 0, h > 0, width > 0, height > 0 else { return 1 }
        return max(Double(displayWidth) / Double(w), Double(height) / Double(h))
    }
}

extension Project {
    /// Upright pixel size of what a clip shows: media display size (rotation applied), or the size of the nested
    /// sequence. nil for generators and for media without probe info.
    public func pictureSize(of clip: Clip) -> (width: Int, height: Int)? {
        if clip.isGenerator { return nil }
        if let s = clip.sequence {
            return timelines.first { $0.id == s }.map { ($0.format.displayWidth, $0.format.height) }
        }
        guard let v = media(clip.media)?.info?.video else { return nil }
        return (v.displayWidth, v.displayHeight)
    }

    /// Scale that fits `clip`'s picture into `timeline`'s frame; nil when the picture size is unknown (generator, no info).
    public func frameFitScale(of clip: Clip, in timeline: Timeline) -> Double? {
        guard let size = pictureSize(of: clip) else { return nil }
        return timeline.format.fitScale(width: size.width, height: size.height)
    }

    /// Scale that fills `timeline`'s frame with `clip`'s picture; nil when the picture size is unknown.
    public func frameFillScale(of clip: Clip, in timeline: Timeline) -> Double? {
        guard let size = pictureSize(of: clip) else { return nil }
        return timeline.format.fillScale(width: size.width, height: size.height)
    }

    /// Premiere "Set to Fill Frame": like `setToFrameSize` but the picture covers the whole frame (edges cropped).
    @discardableResult
    public mutating func setToFillFrame(_ ids: Set<Clip.ID>, in timeline: Timeline.ID) throws -> Int {
        try writeFrameScale(ids, in: timeline, fill: true)
    }

    /// Premiere "Fit to Frame": Scale of each picture clip becomes the fit value (keyframes of Scale are removed,
    /// position and rotation stay). Generators and clips of unknown size are skipped. Throws `.trackLocked` when a
    /// clip sits on a locked track, `.timelineNotFound` for an unknown timeline; nothing changes then.
    /// Returns the number of clips changed.
    @discardableResult
    public mutating func setToFrameSize(_ ids: Set<Clip.ID>, in timeline: Timeline.ID) throws -> Int {
        try writeFrameScale(ids, in: timeline, fill: false)
    }

    private mutating func writeFrameScale(_ ids: Set<Clip.ID>, in timeline: Timeline.ID, fill: Bool) throws -> Int {
        guard let ti = timelines.firstIndex(where: { $0.id == timeline }) else { throw EditError.timelineNotFound }
        var work = timelines[ti]
        var changed = 0
        for tr in work.tracks.indices where work.tracks[tr].kind == .video {
            for c in work.tracks[tr].clips where ids.contains(c.id) {
                guard let fit = fill ? frameFillScale(of: c, in: work) : frameFitScale(of: c, in: work) else { continue }
                if work.tracks[tr].isLocked { throw EditError.trackLocked }
                var n = c
                n.animation.scale = AnimatedProperty(Vec2(fit, fit))
                n.pendingSourcePixelScale = false   // an absolute fit value: nothing is owed any more
                if n != c { work.tracks[tr].replace(n); changed += 1 }
            }
        }
        if changed > 0 { timelines[ti] = work }
        return changed
    }

    /// File v10: Scale used to be relative to the aspect-fitted picture (100 % = fit). It is now relative to the
    /// picture's own pixels, so every picture clip's Scale (value and keyframes) is multiplied by its fit scale and
    /// keeps its on-screen size. Generators and stills are left alone. A clip whose picture size is unknown (no probe
    /// info) cannot be converted yet: it is marked `pendingSourcePixelScale` and converted by
    /// `applyPendingScaleMigration` once its media has probe info (Link Media / Replace Footage), H6.
    public mutating func migrateScaleToSourcePixels() {
        convertScaleToSourcePixels({ !$0.isStill && !$0.isGenerator }, markUnknown: true)
    }

    /// Runs the owed v10 Scale step for every `pendingSourcePixelScale` clip whose picture size is now known; the
    /// others stay marked. Called after media gets probe info.
    public mutating func applyPendingScaleMigration() {
        convertScaleToSourcePixels({ $0.pendingSourcePixelScale }, markUnknown: false)
    }

    private mutating func convertScaleToSourcePixels(_ include: (Clip) -> Bool, markUnknown: Bool) {
        for ti in timelines.indices {
            var t = timelines[ti]
            var touched = false
            for tr in t.tracks.indices where t.tracks[tr].kind == .video {
                for c in t.tracks[tr].clips where include(c) {
                    guard let f = frameFitScale(of: c, in: t) else {
                        if markUnknown, !c.pendingSourcePixelScale {
                            var n = c
                            n.pendingSourcePixelScale = true
                            t.tracks[tr].replace(n); touched = true
                        }
                        continue
                    }
                    var n = c.scaledToSourcePixels(fit: f)
                    // Variant overrides come from `Timeline.detach` (base Scale x the conform factor): the conform
                    // applies on top of the base semantics, so they convert with the same base fit.
                    if !c.variantOverrides.isEmpty {
                        n.variantOverrides = c.variantOverrides.mapValues { $0.scaledToSourcePixels(fit: f) }
                    }
                    n.pendingSourcePixelScale = false
                    if n != c { t.tracks[tr].replace(n); touched = true }
                }
            }
            if touched { timelines[ti] = t }
        }
    }
}

extension Clip {
    /// The v10 conversion for one clip: Scale (value and keys) times `f`, Anchor divided by `f`. Identity for f == 1.
    func scaledToSourcePixels(fit f: Double) -> Clip {
        guard abs(f - 1) > 1e-12 else { return self }
        var n = self
        // Layer-local px are now native px (fit factor larger): the anchor shrinks by f to stay on the same point.
        n.animation.anchor = animation.anchor.scaledAnchor(fit: f)
        n.animation.scale = animation.scale.scaledScale(fit: f)
        return n
    }
}

extension VariantOverride {
    /// The v10 conversion of this override's Scale and Anchor (the base fit `f`, like the clip's own values).
    func scaledToSourcePixels(fit f: Double) -> VariantOverride {
        guard abs(f - 1) > 1e-12 else { return self }
        var o = self
        o.scale = scale?.scaledScale(fit: f)
        o.anchor = anchor?.scaledAnchor(fit: f)
        return o
    }
}

extension AnimatedProperty where V == Vec2 {
    fileprivate func scaledScale(fit f: Double) -> AnimatedProperty<Vec2> {
        var n = self
        n.value = Vec2(value.x * f, value.y * f)
        n.track.keys = track.keys.map {
            var k = $0
            k.value = Vec2(k.value.x * f, k.value.y * f)
            k.inTangent = Vec2(k.inTangent.x * f, k.inTangent.y * f)     // as `SequenceConform.scaled`
            k.outTangent = Vec2(k.outTangent.x * f, k.outTangent.y * f)
            return k
        }
        return n
    }

    fileprivate func scaledAnchor(fit f: Double) -> AnimatedProperty<Vec2> {
        var n = self
        n.value = Vec2(value.x / f, value.y / f)
        n.track.keys = track.keys.map {
            var k = $0
            k.value = Vec2(k.value.x / f, k.value.y / f)
            k.inTangent = Vec2(k.inTangent.x / f, k.inTangent.y / f)
            k.outTangent = Vec2(k.outTangent.x / f, k.outTangent.y / f)
            return k
        }
        return n
    }
}
