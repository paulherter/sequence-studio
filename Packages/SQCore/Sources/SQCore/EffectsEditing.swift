import Foundation

// Pure edits of a clip's applied effects and opacity. The session wraps each in one undo step.

extension Clip {
    // MARK: Effect instances

    /// Appends a new instance of `kind` (a second Gaussian Blur is fine) with default values (FB-W: the user default of
    /// the kind in `defaults` when there is one, else factory). Returns its id.
    /// Audio kinds (`ClipEffect.isAudioKind`) only onto audio clips, every other kind only onto video clips.
    /// A Color effect goes behind the existing Color effects, in front of every other effect (color always renders
    /// first), and only onto clips that take color (`acceptsColor`).
    @discardableResult
    public mutating func addEffect(kind: String, defaults: EffectDefaults? = nil) -> ClipEffect.ID? {
        guard !EffectCatalog.isGeneratorOwned(kind),
              var e = defaults?.makeEffect(kind: kind) ?? ClipEffect.make(kind: kind) else { return nil }
        // A user default of the kind wins; without one a neutral effect starts at its visible value.
        if defaults?.hasDefault(effect: kind) != true {
            for (key, v) in ClipEffect.appliedStartValues[kind] ?? [:] { e.parameters[key] = AnimatedProperty(v) }
        }
        // Audio effects run on the sound of audio clips only; picture effects never go onto an audio clip.
        guard e.isAudio == (self.kind == .audio) else { return nil }
        if e.kind == ClipEffect.stabilizeKind { return addStabilizer(e) }
        if e.isColor {
            guard acceptsColor else { return nil }
            let colors = colorEffectIndices
            // A later Color effect works on display-referred video: its Input LUT starts as none, not the camera LUT.
            if !colors.isEmpty { e.grade = ColorGradeData(inputLUT: nil) }
            effects.insert(e, at: colors.last.map { $0 + 1 } ?? 0)
            return e.id
        }
        effects.append(e)
        return e.id
    }

    /// Sets the static value of a parameter (keys stay). NaN and infinity are sanitized on write, the same rule as
    /// `ClipEffect.scalar` (catalog default for NaN, catalog range clamp).
    public mutating func setParameter(_ id: ClipEffect.ID, _ key: String, to value: Double) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        let value = ClipEffect.sanitized(value, kind: effects[i].kind, key: key)
        var p = effects[i].parameters[key] ?? AnimatedProperty(value)
        p.value = value
        effects[i].parameters[key] = p
    }

    /// Sets the static value of a color parameter (keys stay).
    public mutating func setColor(_ id: ClipEffect.ID, _ key: String, to value: EffectColor) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        var p = effects[i].colors[key] ?? AnimatedProperty(value)
        p.value = value
        effects[i].colors[key] = p
    }

    /// Sets the static value of a point parameter (keys stay).
    public mutating func setPoint(_ id: ClipEffect.ID, _ key: String, to value: Vec2) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        var p = effects[i].points[key] ?? AnimatedProperty(value)
        p.value = value
        effects[i].points[key] = p
    }

    /// Moves an effect to `index` in the list (clamped); the list order is the evaluation order. False when nothing moved (re-pinning an unpinned list counts as moved).
    /// Color effects are pinned: they render before every other effect and the first one is the footage conversion, so
    /// they do not move and nothing moves in front of them. Covers (effects limited to an Anonymize mask) come right
    /// behind them: a cover moves among the covers only and no other effect moves in front of one (`pinCovers`).
    @discardableResult
    public mutating func moveEffect(_ id: ClipEffect.ID, to index: Int) -> Bool {
        // An older, unpinned list may be reordered here; the result says so even when the move itself does nothing.
        let pinned0 = pinCovers()
        guard let from = effects.firstIndex(where: { $0.id == id }), !effects[from].isColor else { return pinned0 }
        let pinned = effects.prefix(while: \.isColor).count
        let covers = effects[pinned...].prefix(while: isCover).count
        let cover = isCover(effects[from])
        let low = cover ? pinned : pinned + covers
        let high = cover ? pinned + covers - 1 : effects.count - 1
        let to = min(max(index, low), max(low, high))
        guard to != from else { return pinned0 }
        let e = effects.remove(at: from)
        effects.insert(e, at: to)
        return true
    }

    /// Copies an effect (values and keys, new ids) right behind the original. Returns the copy's id.
    @discardableResult
    public mutating func duplicateEffect(_ id: ClipEffect.ID) -> ClipEffect.ID? {
        guard let i = effects.firstIndex(where: { $0.id == id }), !EffectCatalog.isGeneratorOwned(effects[i].kind)
        else { return nil }
        let copy = effects[i].copy()
        effects.insert(copy, at: i + 1)
        return copy.id
    }

    @discardableResult
    public mutating func removeEffect(_ id: ClipEffect.ID) -> Bool {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return false }
        effects.remove(at: i)
        if !variantOverrides.isEmpty {
            variantOverrides = variantOverrides.mapValues { var o = $0; o.effectParameters[id] = nil; return o }
        }
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
        var track = animation.opacity.track
        switch edge {
        case .head:
            let target = animation.opacity.value(atLocal: d)
            track.keys.removeAll { $0.time <= d }
            track.insert(Keyframe(time: .zero, value: 0))
            track.insert(Keyframe(time: d, value: target))
        case .tail:
            let from = len - d
            let start = animation.opacity.value(atLocal: from)
            track.keys.removeAll { $0.time >= from }
            track.insert(Keyframe(time: from, value: start))
            track.insert(Keyframe(time: len, value: 0))
        }
        animation.opacity.track = track
    }

    // MARK: Paste Attributes

    /// Motion (switch, Position, Scale, Rotation, Anchor) taken from `source`, with its v10 Scale state (H6): Scale and
    /// Anchor arrive in the source's semantics, so a still-pending target is converted no longer (or becomes pending when
    /// the source still is). A target of known picture size that became pending must then get
    /// `Project.applyPendingScaleMigration` (the editor session runs it after every edit).
    public mutating func replaceMotion(with source: Clip) {
        motionEnabled = source.motionEnabled
        animation.position = source.animation.position
        animation.scale = source.animation.scale
        animation.rotation = source.animation.rotation
        animation.anchor = source.animation.anchor
        animation.tiltX = source.animation.tiltX
        animation.tiltY = source.animation.tiltY
        animation.shutterAngle = source.animation.shutterAngle
        animation.antiFlicker = source.animation.antiFlicker
        pendingSourcePixelScale = source.pendingSourcePixelScale
    }

    /// Copy whose clip-local key times (Motion, effects, masks) are stretched so a key at the clip's current length lands at
    /// `newDuration` (Paste Attributes "Scale Attribute Times"). Same length or an empty clip: unchanged.
    public func keyTimesScaled(toDuration newDuration: Time) -> Clip {
        var c = self
        let old = duration
        guard old > .zero, newDuration > .zero, old != newDuration else { return c }
        c.rescaleKeys(from: old, to: newDuration, mirror: false)
        return c
    }

    /// This clip with the attributes of `source` applied (Edit > Paste Attributes). Motion, Opacity (and the blend mode),
    /// Volume and color replace the target's; every other effect is added behind the existing ones with fresh ids.
    /// Key times are clip-local, so they land at the same offset from the target's first frame (keys past its end stay
    /// stored and show when the clip grows). Clips of another kind are left alone.
    public func pastingAttributes(from source: Clip) -> Clip {
        guard source.kind == kind else { return self }
        var out = self
        switch kind {
        case .video:
            out.replaceMotion(with: source)
            out.opacityEnabled = source.opacityEnabled
            out.animation.opacity = source.animation.opacity
            // Subject masks only on clips that take one (no generators, no nests: the matte needs a decoded source frame).
            // Picture masks read another track, so any clip takes them (their track is remapped by the timeline paste).
            let pasted = source.pastedMasksWithMap()
            out.masks = pasted.masks.filter { !$0.source.usesMatte || $0.source == .picture || out.acceptsSubjectMask }
            out.blendMode = source.blendMode
            // Color: the footage interpretation and every Color effect replace the target's (first in the list), on
            // clips that take color.
            if out.acceptsColor {
                out.footageColor = source.footageColor
                out.replaceColorGrade(with: source.colorGradeEffects)
                out.applyCopiedGraph(source.colorGraph)
            }
            let before = Set(out.effects.map(\.id))
            out.pasteEffects(from: source) { !$0.isColor && !$0.isColorGraph && !$0.isAudio }
            // Pasted effects point at the pasted masks; the target's own effects lost theirs with the old masks.
            let kept = Set(out.masks.map(\.id))
            for i in out.effects.indices {
                out.effects[i].maskInput = before.contains(out.effects[i].id)
                    ? out.effects[i].maskInput.filter(kept.contains)
                    : out.effects[i].maskInput.compactMap { pasted.map[$0] }.filter(kept.contains)
            }
            out.pinCovers()                                         // a pasted cover goes in front of the target's effects
        case .audio:
            out.animation.volume = source.animation.volume
            out.audioGainDB = source.audioGainDB
            out.pasteEffects(from: source) { $0.isAudio }          // AUDIO-FX: the audio effect stack
        }
        return out
    }

    /// Effects of `source` passing `include`: a kind the target has as many times as the source replaces those instances
    /// one by one (so pasting twice does not stack copies); otherwise the copies are added behind the existing ones.
    /// A generator-owned effect (a shape's look) only pastes onto a clip of the same generator, and only replaces.
    private mutating func pasteEffects(from source: Clip, include: (ClipEffect) -> Bool) {
        var kinds: [String] = []
        for e in source.effects where include(e) && !kinds.contains(e.kind) { kinds.append(e.kind) }
        for kind in kinds {
            let srcs = source.effects.filter { $0.kind == kind }
            let dsts = effects.indices.filter { effects[$0].kind == kind }
            if let owner = EffectCatalog.owningGenerator(of: kind) {
                guard generator?.kind == owner, source.generator?.kind == owner else { continue }
                if let d = dsts.first, let s = srcs.first { effects[d] = s.copy() }
                else if let s = srcs.first { effects.insert(s.copy(), at: 0) }
            } else if dsts.count == srcs.count {
                for (i, d) in dsts.enumerated() { effects[d] = srcs[i].copy() }
            } else {
                effects += srcs.map { $0.copy() }
            }
        }
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
        let half = clipDuration.halved
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
    /// `sourceLane` / `pictureLanes` (from the clipboard): where the source clip and its Picture masks' tracks sat, so a
    /// mask whose track is not in this sequence keeps its lane offset (`Clip.remapPictureTrack`).
    @discardableResult
    public mutating func pasteAttributes(from source: Clip, to ids: [Clip.ID], sourceLane: Int? = nil,
                                         pictureLanes: [Track.ID: Int] = [:]) throws -> Int {
        var work = self
        var changed = 0
        for id in ids where id != source.id {
            guard let c = work.find(id)?.clip, c.kind == source.kind else { continue }
            let out = work.remappingPictureTracks(of: c.pastingAttributes(from: source), sourceLane: sourceLane,
                                                  pictureLanes: pictureLanes)
            guard out != c else { continue }
            try work.replaceClip(out)
            changed += 1
        }
        guard changed > 0 else { throw EditError.emptyClip }
        self = work
        return changed
    }
}
