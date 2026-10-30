import Foundation

/// A saved look: Motion/Opacity properties and applied effects, with their keyframes and easing.
/// Key times are stored clip-local as they were on the clip the preset was saved from (`referenceDuration` long);
/// `anchor` decides how they land on a clip of another length.
public struct EffectPreset: Sendable, Hashable, Codable {
    /// Version of the JSON payload (`PresetItem.payloadVersion` for `.effect` presets).
    public static let payloadVersion = 1

    public enum Anchor: String, Sendable, Hashable, Codable, CaseIterable {
        /// Keys keep their distance to the clip's first frame.
        case start
        /// Keys keep their distance to the clip's end.
        case end
        /// Key times scale with the clip length.
        case stretch
    }

    public enum MotionProperty: String, Sendable, Hashable, Codable, CaseIterable {
        case position, scale, rotation, opacity, anchorPoint
        /// FB-G: Motion's Shutter Angle (absent in presets saved before it).
        case shutterAngle
    }

    public enum PayloadError: Error, Equatable, Sendable {
        case newerVersion(found: Int, supported: Int)
    }

    public var anchor: Anchor
    /// Length of the clip the preset was saved from (the reference for `.end` and `.stretch`).
    public var referenceDuration: Time
    public var position: AnimatedProperty<Vec2>?
    public var scale: AnimatedProperty<Vec2>?
    public var rotation: AnimatedProperty<Double>?
    public var opacity: AnimatedProperty<Double>?
    public var anchorPoint: AnimatedProperty<Vec2>?
    public var shutterAngle: AnimatedProperty<Double>?
    /// Appended to the target's effects (new ids), in this order.
    public var effects: [ClipEffect]
    /// C7: width x height of the sequence the preset was made on. Applied to a sequence of another size, the spatial values
    /// (Position, Anchor Point, effect points, spatial tangents) scale by the ratio per axis, so a placement keeps its share
    /// of the frame. nil (presets saved before it, built-in stacks) = applied as stored. Optional and only written when set,
    /// so the payload version stays 1 and older builds read it (they ignore the field and apply unscaled).
    public var frameSize: Vec2?

    public init(anchor: Anchor = .start, referenceDuration: Time,
                position: AnimatedProperty<Vec2>? = nil, scale: AnimatedProperty<Vec2>? = nil,
                rotation: AnimatedProperty<Double>? = nil, opacity: AnimatedProperty<Double>? = nil,
                anchorPoint: AnimatedProperty<Vec2>? = nil, shutterAngle: AnimatedProperty<Double>? = nil,
                effects: [ClipEffect] = [], frameSize: Vec2? = nil) {
        self.anchor = anchor; self.referenceDuration = referenceDuration; self.frameSize = frameSize
        self.position = position; self.scale = scale; self.rotation = rotation
        self.opacity = opacity; self.anchorPoint = anchorPoint; self.shutterAngle = shutterAngle
        self.effects = effects
    }

    public var motionProperties: Set<MotionProperty> {
        var out: Set<MotionProperty> = []
        if position != nil { out.insert(.position) }
        if scale != nil { out.insert(.scale) }
        if rotation != nil { out.insert(.rotation) }
        if opacity != nil { out.insert(.opacity) }
        if anchorPoint != nil { out.insert(.anchorPoint) }
        if shutterAngle != nil { out.insert(.shutterAngle) }
        return out
    }

    public var isEmpty: Bool { motionProperties.isEmpty && effects.isEmpty }

    /// Only audio effects (no Motion/Opacity): applies to audio clips instead of video clips (an imported voice chain).
    public var isAudioOnly: Bool { motionProperties.isEmpty && !effects.isEmpty && effects.allSatisfy(\.isAudio) }

    /// The track kind this preset applies to.
    public var trackKind: TrackKind { isAudioOnly ? .audio : .video }

    // MARK: Capture

    /// Preset from `clip`. `motion` nil = every property that is keyframed or differs from its default;
    /// `effects` nil = all applied effects (in list order). `frameSize`: the sequence's width x height (`EffectPreset.frameSize`).
    public static func capture(from clip: Clip, anchor: Anchor = .start,
                               motion: Set<MotionProperty>? = nil, effects: Set<ClipEffect.ID>? = nil,
                               frameSize: Vec2? = nil) -> EffectPreset {
        let a = clip.animation, d = ClipAnimation()
        func take<V>(_ p: MotionProperty, _ v: AnimatedProperty<V>, _ def: AnimatedProperty<V>) -> AnimatedProperty<V>? {
            if let motion { return motion.contains(p) ? v : nil }
            return v.isAnimated || v.value != def.value ? v : nil
        }
        return EffectPreset(anchor: anchor, referenceDuration: clip.duration,
                            position: take(.position, a.position, d.position),
                            scale: take(.scale, a.scale, d.scale),
                            rotation: take(.rotation, a.rotation, d.rotation),
                            opacity: take(.opacity, a.opacity, d.opacity),
                            anchorPoint: take(.anchorPoint, a.anchor, d.anchor),
                            shutterAngle: take(.shutterAngle, a.shutterAngle, d.shutterAngle),
                            effects: clip.effects.filter { effects?.contains($0.id) ?? true }, frameSize: frameSize)
    }

    /// The one uniform factor that maps `frameSize` onto `target`, as Change Format's default conform (fill:
    /// `SequenceConform.frameFactor`); nil when either is unknown, not positive, or they are equal. Uniform, so a circular
    /// motion path stays circular.
    public func spatialScale(to target: Vec2?) -> Double? {
        guard let from = frameSize, let target, from.x > 0, from.y > 0, target.x > 0, target.y > 0, from != target else { return nil }
        return max(target.x / from.x, target.y / from.y)
    }

    // MARK: Time mapping

    /// Where a key saved at clip-local `t` (on a `reference`-long clip) lands on a `target`-long clip.
    /// `.stretch` with a zero reference behaves like `.start`.
    public static func mapTime(_ t: Time, anchor: Anchor, reference: Time, target: Time) -> Time {
        switch anchor {
        case .start: return t
        case .end: return t + (target - reference)
        case .stretch:
            guard reference > .zero else { return t }
            return scaled(t, by: target, over: reference)
        }
    }

    /// `t * num / den` exactly when it fits Int64, else rounded to microseconds. `den` must be positive.
    static func scaled(_ t: Time, by num: Time, over den: Time) -> Time {
        let n = Int128(t.value) * Int128(num.value) * Int128(den.timescale)
        let d = Int128(t.timescale) * Int128(num.timescale) * Int128(den.value)
        var g = gcd128(n.magnitude, d.magnitude)
        if g == 0 { g = 1 }
        let rn = n / Int128(g), rd = d / Int128(g)
        if let v = Int64(exactly: rn), let s = Int64(exactly: rd), s > 0 { return Time(v, s) }
        let micro = (Double(n) / Double(d) * 1_000_000).rounded()
        return Time(Int64(micro), 1_000_000)
    }

    private static func gcd128(_ a: UInt128, _ b: UInt128) -> UInt128 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    // MARK: Payload

    /// Versioned JSON stored in `PresetItem.payload`.
    public func payload() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    /// Decodes a payload; a newer `version` than this build understands throws `PayloadError.newerVersion`.
    public init(payload: Data, version: Int) throws {
        guard version <= Self.payloadVersion else {
            throw PayloadError.newerVersion(found: version, supported: Self.payloadVersion)
        }
        self = try JSONDecoder().decode(EffectPreset.self, from: payload)
        effects = effects.map { $0.upgradingLegacyShadowColor() }   // saved before v24
    }
}

// MARK: - Apply

extension AnimatedProperty {
    /// Key times through `f`, every key with a fresh id (keeps values and easing).
    fileprivate func presetMapped(_ f: (Time) -> Time) -> AnimatedProperty {
        var c = self
        c.track = KeyframeTrack(keys: track.keys.map { var k = $0; k.id = UUID(); k.time = f(k.time); return k })
        return c
    }
}

extension EffectPreset {
    /// How a preset's Motion/Opacity land on a clip that already has its own.
    public enum ApplyMode: String, Sendable, Hashable, Codable, CaseIterable {
        /// The preset's values and keys replace the clip's (Premiere).
        case absolute
        /// The preset adds onto the clip: Position, Rotation and Anchor are added, Scale and Opacity multiply
        /// (the preset is read against its own 100 %). The clip's keys stay, the preset's keys join them.
        case relative
    }
}

extension AnimatedProperty {
    /// `self` (the clip's) combined with `preset` (already time-mapped, fresh key ids) through `op`.
    /// Exact when one side is static (the other side's curve keeps its easing); with keys on both sides the result has a
    /// key at every key time of either, value = op(clip(t), preset(t)), easing from the key that sits there (preset first).
    fileprivate func combined(with preset: AnimatedProperty, _ op: (V, V) -> V) -> AnimatedProperty {
        if !preset.isAnimated {
            var c = self
            c.value = op(value, preset.value)
            c.track = KeyframeTrack(keys: track.keys.map { var k = $0; k.value = op(k.value, preset.value); return k })
            return c
        }
        if !isAnimated {
            var c = preset
            c.value = op(value, preset.value)
            c.track = KeyframeTrack(keys: preset.track.keys.map { var k = $0; k.value = op(value, k.value); return k })
            return c
        }
        // Where both sides have a key the preset's is the one kept, under its own id. A Hold or Hold Ahead of the clip's
        // key there wins over the preset's shape: a step never becomes a ramp.
        let mine = track.keys, theirs = preset.track.keys
        let times = Set(mine.map(\.time)).union(theirs.map(\.time)).sorted()
        let out = KeyframeTrack(keys: times.compactMap { t -> Keyframe<V>? in
            let own = mine.first { $0.time == t }
            guard var k = theirs.first(where: { $0.time == t }) ?? own else { return nil }
            if let own, own.interpolation.isHold { k.interpolation = own.interpolation }
            k.value = op(value(atLocal: t), preset.value(atLocal: t))
            return k
        })
        return AnimatedProperty(op(value, preset.value), track: out)
    }
}

extension Clip {
    /// Applies `preset`. `.absolute`: its Motion/Opacity properties replace the clip's (value and keys); `.relative`:
    /// they add onto the clip's own (see `EffectPreset.ApplyMode`). Its effects are appended with new ids either way.
    /// Keys are placed by the preset's anchor; keys that land outside the clip are kept (as in Premiere),
    /// they only shape the curve at the edge. `frameSize`: the target sequence's width x height; spatial values scale to it
    /// from the preset's own `frameSize` (C7), nil keeps them as stored.
    public mutating func applyPreset(_ preset: EffectPreset, mode: EffectPreset.ApplyMode = .absolute, frameSize: Vec2? = nil) {
        var preset = preset
        if let k = preset.spatialScale(to: frameSize), let from = preset.frameSize, let to = frameSize {
            // Only what Change Format conforms: Motion Position (canvas px) and a Group Transform's Position/Anchor. Anchor
            // Point (layer px), Scale and other effects' points (clip px) stay. A picture uses the uniform fill factor
            // (`conformPicture`), a text clip one factor per axis (`conformText`: a lower third stays a lower third).
            let isText = generator?.kind == GeneratorRef.text
            let sx = isText ? to.x / from.x : k, sy = isText ? to.y / from.y : k
            preset.position = preset.position.map { SequenceConform.scaled($0, sx, sy) }
            preset.effects = preset.effects.map { SequenceConform.conformGroupStage($0, sx, sy) }
        }
        let target = duration
        let f = { (t: Time) in EffectPreset.mapTime(t, anchor: preset.anchor, reference: preset.referenceDuration, target: target) }
        switch mode {
        case .absolute:
            if let p = preset.position { animation.position = p.presetMapped(f) }
            if let p = preset.scale {
                animation.scale = p.presetMapped(f)
                pendingSourcePixelScale = false   // H6: an absolute Scale in source pixels; nothing is owed any more
            }
            if let p = preset.rotation { animation.rotation = p.presetMapped(f) }
            if let p = preset.opacity { animation.opacity = p.presetMapped(f) }
            if let p = preset.anchorPoint { animation.anchor = p.presetMapped(f) }
            if let p = preset.shutterAngle { animation.shutterAngle = p.presetMapped(f) }
        case .relative:
            let add: (Vec2, Vec2) -> Vec2 = { $0 + $1 }
            let mul: (Vec2, Vec2) -> Vec2 = { Vec2($0.x * $1.x, $0.y * $1.y) }
            if let p = preset.position { animation.position = animation.position.combined(with: p.presetMapped(f), add) }
            if let p = preset.scale { animation.scale = animation.scale.combined(with: p.presetMapped(f), mul) }
            if let p = preset.rotation { animation.rotation = animation.rotation.combined(with: p.presetMapped(f), +) }
            if let p = preset.opacity { animation.opacity = animation.opacity.combined(with: p.presetMapped(f), *) }
            if let p = preset.anchorPoint { animation.anchor = animation.anchor.combined(with: p.presetMapped(f), add) }
            // A shutter does not add up: the preset's replaces the clip's.
            if let p = preset.shutterAngle { animation.shutterAngle = p.presetMapped(f) }
        }
        // Fresh ids for the effect and every key, so applying twice never duplicates key ids.
        // Presets saved before v24 may still hold a Drop Shadow color as three channels.
        let added = preset.effects.map { fx in
            var e = fx.upgradingLegacyShadowColor().copy()
            e.parameters = e.parameters.mapValues { $0.presetMapped(f) }
            e.colors = e.colors.mapValues { $0.presetMapped(f) }
            e.points = e.points.mapValues { $0.presetMapped(f) }
            return e
        }
        // Color effects stay first (behind the clip's own), and only on clips that take color.
        let colors = added.filter(\.isColor)
        if !colors.isEmpty, acceptsColor {
            let at = colorEffectIndices.last.map { $0 + 1 } ?? 0
            let adapted = colors.enumerated().map { $1.adaptingLUTs(toMedia: media, primary: at + $0 == 0) }
            effects.insert(contentsOf: adapted, at: at)
        }
        effects += added.filter { !$0.isColor }
    }
}

extension Timeline {
    /// Applies `preset` to the clips among `ids` of its kind (`EffectPreset.trackKind`: video, or audio for an audio-only
    /// preset; the others are skipped). Returns how many changed.
    /// Throws `.wrongTrackKind` when none is of that kind, `.trackLocked` for a clip on a locked track.
    @discardableResult
    public mutating func applyPreset(_ preset: EffectPreset, to ids: Set<Clip.ID>,
                                     mode: EffectPreset.ApplyMode = .absolute) throws -> Int {
        var work = self
        var changed = 0
        let kind = preset.trackKind
        let size = Vec2(Double(format.displayWidth), Double(format.height))
        for tr in work.tracks.indices where work.tracks[tr].kind == kind {
            for c in work.tracks[tr].clips where ids.contains(c.id) {
                if work.tracks[tr].isLocked { throw EditError.trackLocked }
                var n = c
                n.applyPreset(preset, mode: mode, frameSize: size)
                work.tracks[tr].replace(n)
                changed += 1
            }
        }
        guard changed > 0 else { throw EditError.wrongTrackKind }
        self = work
        return changed
    }
}

// MARK: - Transition presets

/// A saved transition: kind, length, alignment, easing and the style a kind uses (direction, softness, motion blur).
/// Stored with effective values, so a preset looks the same even if a kind's defaults change later.
/// Payload of `.transition` library presets.
public struct TransitionPreset: Sendable, Hashable, Codable {
    public static let payloadVersion = 1

    public enum PayloadError: Error, Equatable, Sendable {
        case newerVersion(found: Int, supported: Int)
    }

    public var kind: TransitionKind
    public var duration: Time
    /// Never `.custom` (a custom offset is specific to one cut): that is saved as `.center`.
    public var alignment: TransitionAlignment
    public var easing: EasingCurve
    public var direction: TransitionDirection
    public var softness: Double
    public var motionBlur: Double
    /// FB-G: an element transition's parameters (`Transition.params`); nil for every other kind and in older presets.
    public var params: [String: Double]?
    /// Travels the other way (`Transition.reversed`); nil = not reversed and in older presets.
    public var reversed: Bool?
    /// Border (`Transition.borderWidth` / `borderColor`); nil = none and in older presets.
    public var borderWidth: Double?
    public var borderColor: [UInt8]?

    public init(kind: TransitionKind, duration: Time, alignment: TransitionAlignment = .center,
                easing: EasingCurve? = nil, direction: TransitionDirection = TransitionKind.defaultDirection,
                softness: Double = TransitionKind.defaultSoftness, motionBlur: Double? = nil, params: [String: Double]? = nil, reversed: Bool? = nil,
                borderWidth: Double? = nil, borderColor: [UInt8]? = nil) {
        self.kind = kind; self.duration = duration; self.params = params; self.reversed = reversed == true ? true : nil
        self.borderWidth = (borderWidth ?? 0) > 0 ? borderWidth : nil
        self.borderColor = self.borderWidth == nil ? nil : borderColor
        self.alignment = alignment == .custom ? .center : alignment
        self.easing = easing ?? kind.defaultEasing
        self.direction = direction; self.softness = softness
        self.motionBlur = motionBlur ?? kind.defaultMotionBlur
    }

    /// The preset for `transition` (its requested duration, not the handle-clamped one).
    public static func capture(from t: Transition) -> TransitionPreset {
        TransitionPreset(kind: t.kind, duration: t.duration, alignment: t.alignment, easing: t.effectiveEasing,
                         direction: t.effectiveDirection, softness: t.effectiveSoftness, motionBlur: t.effectiveMotionBlur,
                         params: t.kind.hasParams ? t.params : nil, reversed: t.reversed,
                         borderWidth: t.borderWidth, borderColor: t.borderColor)
    }

    public var trackKind: TrackKind { kind.trackKind }

    public func payload() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public init(payload: Data, version: Int) throws {
        guard version <= Self.payloadVersion else { throw PayloadError.newerVersion(found: version, supported: Self.payloadVersion) }
        self = try JSONDecoder().decode(TransitionPreset.self, from: payload)
        if alignment == .custom { alignment = .center }   // a hand-edited file must not smuggle in a per-cut offset
    }
}

extension Timeline {
    /// Makes the transition `id` what `preset` describes (kind, length as far as the handles allow, alignment, style).
    /// Throws `.wrongTrackKind` for a video preset on an audio transition and the reverse; nothing changes then.
    public mutating func applyTransitionPreset(_ preset: TransitionPreset, to id: Transition.ID) throws {
        try setTransition(id, kind: preset.kind, duration: preset.duration, alignment: preset.alignment,
                          easing: preset.easing, direction: preset.direction, softness: preset.softness, motionBlur: preset.motionBlur,
                          reversed: preset.reversed ?? false)
        try replaceTransitionBorder(id, width: preset.borderWidth, color: preset.borderColor)
        // The saved look as a whole: params the preset does not set go back to their defaults.
        if preset.kind.hasParams {
            try setTransition(id, params: (preset.params ?? [:]).filter { preset.kind.elementParam($0.key) != nil }, replacing: true)
        }
    }

    /// Sets the border as a whole (nil clears): a preset or reset must not keep the target's old border.
    mutating func replaceTransitionBorder(_ id: Transition.ID, width: Double?, color: [UInt8]?) throws {
        guard let ti = tracks.firstIndex(where: { $0.transitions.contains { $0.id == id } }),
              let ni = tracks[ti].transitions.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        let on = (width ?? 0) > 0
        tracks[ti].transitions[ni].borderWidth = on ? min(width!, TransitionKind.maxBorderWidth) : nil
        tracks[ti].transitions[ni].borderColor = on && color?.count == 3 ? color : nil
    }

    /// New transition at `point` built from `preset`.
    @discardableResult
    public mutating func addTransition(preset: TransitionPreset, point: TransitionPoint, track: Track.ID) throws -> Transition.ID {
        let id = try addTransition(point: point, kind: preset.kind, track: track, duration: preset.duration, alignment: preset.alignment)
        try setTransition(id, easing: preset.easing, direction: preset.direction, softness: preset.softness, motionBlur: preset.motionBlur)
        try replaceTransitionBorder(id, width: preset.borderWidth, color: preset.borderColor)
        if preset.kind.hasParams, let p = preset.params { try setTransition(id, params: p.filter { preset.kind.elementParam($0.key) != nil }) }
        return id
    }
}
