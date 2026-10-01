import Foundation

// Pure edits of a clip's applied effects and opacity. The session wraps each in one undo step.

extension Clip {
    // MARK: Effect instances

    /// Appends a new instance of `kind` (a second Gaussian Blur is fine) with default values. Returns its id.
    @discardableResult
    public mutating func addEffect(kind: String) -> ClipEffect.ID? {
        guard let e = ClipEffect.make(kind: kind) else { return nil }
        effects.append(e)
        return e.id
    }

    /// Sets the static value of a parameter (keys stay).
    public mutating func setParameter(_ id: ClipEffect.ID, _ key: String, to value: Double) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        var p = effects[i].parameters[key] ?? AnimatedProperty(value)
        p.value = value
        effects[i].parameters[key] = p
    }

    /// Moves an effect to `index` in the list (clamped); the list order is the evaluation order. False when nothing moved.
    @discardableResult
    public mutating func moveEffect(_ id: ClipEffect.ID, to index: Int) -> Bool {
        guard let from = effects.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(index, 0), effects.count - 1)
        guard to != from else { return false }
        let e = effects.remove(at: from)
        effects.insert(e, at: to)
        return true
    }

    /// Copies an effect (values and keys, new ids) right behind the original. Returns the copy's id.
    @discardableResult
    public mutating func duplicateEffect(_ id: ClipEffect.ID) -> ClipEffect.ID? {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = effects[i].copy()
        effects.insert(copy, at: i + 1)
        return copy.id
    }

    @discardableResult
    public mutating func removeEffect(_ id: ClipEffect.ID) -> Bool {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return false }
        effects.remove(at: i)
        return true
    }

    // MARK: Opacity

    /// Cmd-click on the Opacity rubber band: a key at clip-local `t` holding the value shown there. Nil outside the clip.
    @discardableResult
    public mutating func addOpacityKey(atLocal t: Time) -> UUID? {
        guard t >= .zero, t <= duration else { return nil }
        let v = animation.opacity.value(atLocal: t)
        let k = Keyframe(time: t, value: v)
        animation.opacity.track.insert(k)
        return k.id
    }

    /// Moves an opacity key to clip-local `time` (kept inside the clip) and `value` (0...1).
    public mutating func moveOpacityKey(_ id: UUID, toLocal time: Time, value: Double, frameDuration: Time? = nil) {
        var t = min(max(time, .zero), duration)
        if let fd = frameDuration { t = min(max(t.snapped(to: fd), .zero), duration) }
        animation.opacity.track.move(id, to: t)
        animation.opacity.track.set(id, value: min(max(value, 0), 1))
    }

    public mutating func removeOpacityKey(_ id: UUID) { animation.opacity.track.remove(id) }

    /// Raises or lowers the opacity line at clip-local `t` by `delta` (0...1 scale), like dragging the rubber band there:
    /// without keys the whole clip's opacity; with keys the segment under `t` (both of its keys), or the first / last
    /// key when `t` is before / after all of them.
    public mutating func shiftOpacityLine(atLocal t: Time, by delta: Double) {
        guard abs(delta) > 1e-9 else { return }
        func shifted(_ v: Double) -> Double { min(max(v + delta, 0), 1) }
        let keys = animation.opacity.track.keys
        guard !keys.isEmpty else {
            animation.opacity.value = shifted(animation.opacity.value)
            return
        }
        let ids: [UUID]
        switch keys.lastIndex(where: { $0.time <= t }) {
        case nil: ids = [keys[0].id]
        case let n? where n == keys.count - 1: ids = [keys[n].id]
        case let n?: ids = [keys[n].id, keys[n + 1].id]
        }
        for id in ids { if let k = animation.opacity.track.key(id: id) { animation.opacity.track.set(id, value: shifted(k.value)) } }
    }

    /// Fade preset on the picture (Opacity keys): `.head` fades in from 0, `.tail` fades out to 0, over `duration`
    /// (clamped to half the clip). The opacity the clip has at the other end of the fade is kept as its target, and keys
    /// inside the fade span are replaced, so applying a fade again changes it.
    public mutating func applyVideoFade(_ edge: ClipEdge, duration requested: Time, frameDuration: Time? = nil) {
        let len = duration
        var d = OpacityFade.clamped(requested, clipDuration: len)
        if let fd = frameDuration { d = min(d.snapped(to: fd), len) }       // keys sit on frames
        guard d > .zero else { return }
        switch edge {
        case .head:
            let target = animation.opacity.value(atLocal: d)
            animation.opacity.track.keys.removeAll { $0.time <= d }
            animation.opacity.track.insert(Keyframe(time: .zero, value: 0))
            animation.opacity.track.insert(Keyframe(time: d, value: target))
        case .tail:
            let from = len - d
            let start = animation.opacity.value(atLocal: from)
            animation.opacity.track.keys.removeAll { $0.time >= from }
            animation.opacity.track.insert(Keyframe(time: from, value: start))
            animation.opacity.track.insert(Keyframe(time: len, value: 0))
        }
    }

    // MARK: Paste Attributes

    /// This clip with the attributes of `source` applied (Edit > Paste Attributes). Motion, Opacity (and the blend mode),
    /// Volume and colour replace the target's; every other effect is added behind the existing ones with fresh ids.
    /// Key times are clip-local, so they land at the same offset from the target's first frame (keys past its end stay
    /// stored and show when the clip grows). Clips of another kind are left alone.
    public func pastingAttributes(from source: Clip) -> Clip {
        guard source.kind == kind else { return self }
        var out = self
        switch kind {
        case .video:
            out.motionEnabled = source.motionEnabled
            out.opacityEnabled = source.opacityEnabled
            out.animation.position = source.animation.position
            out.animation.scale = source.animation.scale
            out.animation.rotation = source.animation.rotation
            out.animation.anchor = source.animation.anchor
            out.animation.opacity = source.animation.opacity
            out.blendMode = source.blendMode
            out.color = source.color
            // Other effects: a kind the target has as many times as the source replaces those instances one by one (so
            // pasting twice does not stack copies); otherwise the copies are added behind the existing ones.
            var kinds: [String] = []
            for e in source.effects where !kinds.contains(e.kind) { kinds.append(e.kind) }
            for kind in kinds {
                let srcs = source.effects.filter { $0.kind == kind }
                let dsts = out.effects.indices.filter { out.effects[$0].kind == kind }
                if dsts.count == srcs.count {
                    for (i, d) in dsts.enumerated() { out.effects[d] = srcs[i].copy() }
                } else {
                    out.effects += srcs.map { $0.copy() }
                }
            }
        case .audio:
            out.animation.volume = source.animation.volume
            out.audioGainDB = source.audioGainDB
        }
        return out
    }
}

extension ClipEffect {
    /// A copy with a new id (for the effect and nothing else that is shared).
    func copy() -> ClipEffect {
        var c = self
        c.id = UUID()
        return c
    }
}

/// Pure maths of the video fade preset.
public enum OpacityFade {
    /// A fade never takes more than half the clip, so a fade in and a fade out cannot cross.
    public static func clamped(_ requested: Time, clipDuration: Time) -> Time {
        let half = Time(clipDuration.value, clipDuration.timescale * 2)
        return min(requested, half)
    }
}

extension Timeline {
    /// Fade In / Fade Out preset on the given video clips: one call, one undo step. Audio clips are skipped; refuses when
    /// none of the clips is a video clip.
    public mutating func fadeVideo(_ ids: [Clip.ID], edge: ClipEdge, duration: Time) throws {
        let fd = frameDuration
        var work = self
        var changed = 0
        for id in ids {
            guard var c = work.find(id)?.clip, c.kind == .video else { continue }
            c.applyVideoFade(edge, duration: duration, frameDuration: fd)
            try work.replaceClip(c)
            changed += 1
        }
        guard changed > 0 else { throw EditError.wrongTrackKind }
        self = work
    }

    /// Paste Attributes onto `ids` (the source clip itself is skipped). Returns how many clips changed.
    @discardableResult
    public mutating func pasteAttributes(from source: Clip, to ids: [Clip.ID]) throws -> Int {
        var work = self
        var changed = 0
        for id in ids where id != source.id {
            guard let c = work.find(id)?.clip, c.kind == source.kind else { continue }
            let out = c.pastingAttributes(from: source)
            guard out != c else { continue }
            try work.replaceClip(out)
            changed += 1
        }
        guard changed > 0 else { throw EditError.emptyClip }
        self = work
        return changed
    }
}
