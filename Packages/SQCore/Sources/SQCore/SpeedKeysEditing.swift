import Foundation

/// Pure edits of a speed track (the rubber-band gestures), all on whole frames of `frameDuration`.
///
/// Premiere's rules these follow (see docs/audit/speed-time-2.md): a key splits into two halves with a ramp between them;
/// dragging a segment of the rubber band changes its speed and so the clip's length (the source range stays); dragging a key
/// moves where the speed changes; deleting a key removes the change. Ramps are linear in timeline time (no Bezier easing).
extension SpeedKeys {
    /// The track a constant clip is equal to: one segment (what the first edit starts from).
    public static func of(_ c: Clip) -> SpeedKeys {
        c.speedKeys ?? SpeedKeys(constant: c.speed, reversed: c.reversed, duration: c.duration,
                                 origin: c.reversed ? c.source.end : c.source.start)
    }

    private func snappedFrames(_ t: Time, _ fd: Time) -> Time { t.snapped(to: fd) }

    /// Adds a key (a boundary) at clip-local `local` (snapped to a frame). A ramp is cut in two sub-ramps; the speed does not
    /// change. nil when `local` is on an existing boundary or outside the clip. Returns the new boundary index too.
    public func addingKey(at local: Time, frameDuration fd: Time) -> (keys: SpeedKeys, boundary: Int)? {
        let x = snappedFrames(local, fd)
        let bs = boundaries
        guard x > .zero, x < duration, !bs.contains(x) else { return nil }
        let i = bs.lastIndex(where: { $0 < x })!
        let s = segments[i]
        let off = x - bs[i]
        var left = s, right = s
        left.duration = off; right.duration = s.duration - off
        if s.isRamp {
            let mid = ClipSpeed(rational: s.speed(at: off))
            left.to = mid; right.from = mid
        }
        var k = self
        k.segments.replaceSubrange(i...i, with: [left, right])
        return (k, i + 1)
    }

    /// Sets the speed of constant segment `i` (a ramp becomes constant). The segment keeps the source it covers, so its timeline
    /// length changes to `span / speed`, rounded to whole frames (at least one): the clip gets shorter or longer.
    public func settingSpeed(ofSegment i: Int, to v: ClipSpeed, frameDuration fd: Time) -> SpeedKeys {
        guard segments.indices.contains(i) else { return self }
        var k = self
        let s = segments[i]
        let n = max(snappedFrames(v.unscale(s.span), fd), fd)
        k.segments[i] = SpeedSegment(duration: n, from: v, reversed: s.reversed)
        return k.normalized()
    }

    /// Splits the key at `boundary` into two halves with a ramp between them (Premiere's "split key"): `half` frames come off
    /// each neighbour (ramp of `2 * half`, centred). See `splittingKey(atBoundary:takeLeft:takeRight:)`.
    public func splittingKey(atBoundary b: Int, half: Time, frameDuration fd: Time) -> SpeedKeys? {
        splittingKey(atBoundary: b, takeLeft: half, takeRight: half, frameDuration: fd)
    }

    /// Splits the key at `boundary` into two halves: the ramp takes `takeLeft` from the segment before and `takeRight` from the
    /// one after (dragging only the right half to the right gives `takeRight` only, like Premiere). Both neighbours must be
    /// constant segments that keep at least one frame and play in the same direction (a ramp cannot pass through a stop);
    /// the ramp is at least one frame. nil otherwise.
    public func splittingKey(atBoundary b: Int, takeLeft: Time, takeRight: Time, frameDuration fd: Time) -> SpeedKeys? {
        guard b >= 1, b < segments.count else { return nil }
        let l = segments[b - 1], r = segments[b]
        let tl = takeLeft.snapped(to: fd), tr = takeRight.snapped(to: fd)
        guard tl >= .zero, tr >= .zero, tl + tr >= fd, !l.isRamp, !r.isRamp, l.reversed == r.reversed, l.from != r.from,
              l.duration - tl >= fd, r.duration - tr >= fd else { return nil }
        var k = self
        k.segments[b - 1].duration = l.duration - tl
        k.segments[b].duration = r.duration - tr
        k.segments.insert(SpeedSegment(duration: tl + tr, from: l.from, to: r.from, reversed: l.reversed), at: b)
        return k
    }

    /// Removes the speed transition `i`: the change of speed becomes instant in the middle of where the ramp was (Premiere:
    /// deleting a half of a split key reverts the transition).
    public func removingRamp(atSegment i: Int, frameDuration fd: Time) -> SpeedKeys? {
        guard segments.indices.contains(i), segments[i].isRamp else { return nil }
        var k = self
        let ramp = segments[i]
        let half = Time(ramp.duration.value, ramp.duration.timescale * 2).snapped(to: fd)
        let leftGets = min(half, ramp.duration)
        let rightGets = ramp.duration - leftGets
        var parts: [SpeedSegment] = []
        parts.append(SpeedSegment(duration: leftGets, from: ramp.from, reversed: ramp.reversed))
        if rightGets > .zero { parts.append(SpeedSegment(duration: rightGets, from: ramp.to, reversed: ramp.reversed)) }
        k.segments.replaceSubrange(i...i, with: parts)
        return k.normalized()
    }

    /// Changes the width of ramp `i` to `width` (whole frames), taking the difference from the neighbours evenly (all from one
    /// side at a clip end). Clamped to what the neighbours can give (each keeps one frame) and to at least 2 frames.
    public func settingRampWidth(ofSegment i: Int, to width: Time, frameDuration fd: Time) -> SpeedKeys? {
        guard segments.indices.contains(i), segments[i].isRamp else { return nil }
        let hasL = i > 0, hasR = i + 1 < segments.count
        guard hasL || hasR else { return nil }
        let cur = segments[i].duration.frameIndex(frameDuration: fd)
        let want = max(snappedFrames(width, fd).frameIndex(frameDuration: fd), 2)
        var n = want - cur                                   // frames to add (negative = give back)
        let roomL = hasL ? max(segments[i - 1].duration.frameIndex(frameDuration: fd) - 1, 0) : 0
        let roomR = hasR ? max(segments[i + 1].duration.frameIndex(frameDuration: fd) - 1, 0) : 0
        if n > 0 { n = min(n, roomL + roomR) }
        guard n != 0 else { return n == want - cur ? self : nil }
        var l = 0 as Int64, r = 0 as Int64
        if hasL && hasR {
            l = n / 2
            if n > 0 { l = min(l, roomL) }
            r = n - l
            if n > 0, r > roomR { r = roomR; l = n - r }
        } else if hasL { l = n } else { r = n }
        var k = self
        if hasL { k.segments[i - 1].duration -= fd * l }
        if hasR { k.segments[i + 1].duration -= fd * r }
        k.segments[i].duration = fd * (cur + n)
        return k
    }

    /// Moves the key at `boundary` by `delta` (snapped to frames; each neighbour keeps at least one frame). The clip length stays.
    public func movingKey(atBoundary b: Int, by delta: Time, frameDuration fd: Time) -> SpeedKeys? {
        guard b >= 1, b < segments.count else { return nil }
        var d = snappedFrames(delta, fd)
        let l = segments[b - 1].duration, r = segments[b].duration
        d = min(d, r - fd); d = max(d, fd - l)
        guard d != .zero else { return nil }
        var k = self
        k.segments[b - 1].duration = l + d
        k.segments[b].duration = r - d
        return k
    }

    /// Moves a whole speed transition by `delta` (snapped to frames): the segment before grows by it, the one after shrinks;
    /// the ramp keeps its width. Each neighbour keeps at least one frame.
    public func movingRamp(atSegment i: Int, by delta: Time, frameDuration fd: Time) -> SpeedKeys? {
        guard segments.indices.contains(i), segments[i].isRamp, i >= 1, i + 1 < segments.count else { return nil }
        var d = snappedFrames(delta, fd)
        d = min(d, segments[i + 1].duration - fd); d = max(d, fd - segments[i - 1].duration)
        guard d != .zero else { return nil }
        var k = self
        k.segments[i - 1].duration += d
        k.segments[i + 1].duration -= d
        return k
    }

    /// Deletes the key at `boundary`: the two segments join into one constant segment over the same timeline length that
    /// covers the same source (their average speed). Segments that play in different directions are left alone.
    public func removingKey(atBoundary b: Int) -> SpeedKeys? {
        guard b >= 1, b < segments.count else { return nil }
        let l = segments[b - 1], r = segments[b]
        guard l.reversed == r.reversed else { return nil }
        let dur = l.duration + r.duration
        let avg = (l.span(at: l.duration) + r.span(at: r.duration)) / Rational(dur)
        var k = self
        k.segments.replaceSubrange((b - 1)...b, with: [SpeedSegment(duration: dur, from: ClipSpeed(rational: avg), reversed: l.reversed)])
        return k
    }

    /// Scales every segment's length so the track is `target` long (whole frames; the last segment takes the rounding), and
    /// every speed by `old/new` so each segment still covers the same source (used by the Speed/Duration dialog and Rate Stretch
    /// on a remapped clip: the whole shape gets faster or slower).
    public func scaled(toDuration requested: Time, frameDuration fd: Time) -> SpeedKeys {
        let old = duration
        let target = clampedDuration(requested, frameDuration: fd)
        guard old > .zero, target > .zero, old != target else { return self }
        let ratio = Rational(target) / Rational(old)
        var k = self
        var used = Time.zero
        for i in k.segments.indices {
            let s = k.segments[i]
            let remaining = target - used
            var d = i == k.segments.count - 1 ? remaining : max((Rational(s.duration) * ratio).time.snapped(to: fd), fd)
            d = min(d, remaining - fd * Int64(k.segments.count - 1 - i))
            d = max(d, fd)
            // Same source span in the new length: speeds scale by old/new.
            let f = Rational(s.duration) / Rational(d)
            k.segments[i] = SpeedSegment(duration: d, from: ClipSpeed(rational: Rational(s.from) * f),
                                         to: ClipSpeed(rational: Rational(s.to) * f), reversed: s.reversed)
            used += d
        }
        return k
    }

    /// The shortest and longest length this track can be scaled to whole frames without any segment speed leaving
    /// 1 % ... 10000 % (the source each segment covers is preserved).
    public func durationLimits(frameDuration fd: Time) -> (min: Time, max: Time) {
        var lo = Rational(1_000_000), hi = Rational(0)
        for s in segments {
            for v in [Rational(s.from), Rational(s.to)] {
                if v.double < lo.double { lo = v }
                if v.double > hi.double { hi = v }
            }
        }
        let old = Rational(duration)
        let minT = (old * hi / Rational(100)).time, maxT = (old * lo * Rational(100)).time
        let n = Int64(segments.count)
        let minF = max((minT.frameIndex(frameDuration: fd) + (minT > fd * minT.frameIndex(frameDuration: fd) ? 1 : 0)), n)
        let maxF = max(maxT.frameIndex(frameDuration: fd), minF)
        return (fd * minF, fd * maxF)
    }

    /// `t` clamped into `durationLimits`.
    public func clampedDuration(_ t: Time, frameDuration fd: Time) -> Time {
        let l = durationLimits(frameDuration: fd)
        return min(max(t, l.min), l.max)
    }
}
