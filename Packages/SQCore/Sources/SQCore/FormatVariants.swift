import Foundation

/// Multi-format phase 2 (design note (a) option 3 in docs/ROADMAP.md): one sequence, one shared edit, several frame sizes.
/// A variant only changes the canvas size (frame rate and sample rate stay the sequence's). Each clip can hold a sparse
/// override per variant; whatever it does not override is the base value conformed automatically (`SequenceConform`
/// rules: pictures scale uniformly by the fit/fill factor, text keeps its scale and moves per axis, solids stay).
public struct FormatVariant: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var width: Int
    public var height: Int
    /// How clips without their own choice are conformed into this size.
    public var conform: ConformMode

    public init(id: UUID = UUID(), name: String, width: Int, height: Int, conform: ConformMode = .fill) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.conform = conform
    }

    /// The canvas of this variant for a sequence of format `base`.
    public func format(base: SequenceFormat) -> SequenceFormat {
        var f = SequenceFormat(width: width, height: height, frameDuration: base.frameDuration, audioSampleRate: base.audioSampleRate)
        f.pixelAspectStore = base.pixelAspectStore
        return f
    }

    static func validSize(_ w: Int, _ h: Int) -> Bool {
        (1...SequenceFormatPresets.maxDimension).contains(w) && (1...SequenceFormatPresets.maxDimension).contains(h)
    }

    private enum CodingKeys: String, CodingKey { case id, name, width, height, conform }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let w = try c.decode(Int.self, forKey: .width), h = try c.decode(Int.self, forKey: .height)
        guard Self.validSize(w, h) else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: c, debugDescription: "variant size \(w)x\(h) is not valid")
        }
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name), width: w, height: h,
                  conform: try c.decodeIfPresent(ConformMode.self, forKey: .conform) ?? .fill)
    }
}

public enum VariantError: Error, Equatable { case variantNotFound }

/// The transform properties a variant can override (Effect Controls > Motion, without Opacity: opacity is shared).
public enum VariantProperty: String, Sendable, Hashable, CaseIterable { case position, scale, rotation, anchor, tilt }

/// One clip's own values in one variant. Every field is optional: nil = the automatic conform of the base value.
/// Keyframe times are clip-local like `ClipAnimation` and move with the clip in every edit (split, trims, retime).
public struct VariantOverride: Sendable, Hashable, Codable {
    public var position: AnimatedProperty<Vec2>?
    public var scale: AnimatedProperty<Vec2>?
    public var rotation: AnimatedProperty<Double>?
    public var anchor: AnimatedProperty<Vec2>?
    /// Perspective tilt about the horizontal / vertical axis (`PerspectiveTilt`), degrees. One property `.tilt`: both axes
    /// are overridden together. v84 content (written only when set; marks `TiltSeen`).
    public var tiltX: AnimatedProperty<Double>?
    public var tiltY: AnimatedProperty<Double>?
    /// Fit / fill for this clip's automatic conform; nil = the variant's.
    public var conform: ConformMode?
    /// Replaces the generator content in this variant (e.g. a text clip's box, size or line breaks). Used only when its
    /// kind matches the clip's generator.
    public var generator: GeneratorRef?
    /// Scalar effect parameters by effect instance id, then parameter key (e.g. a Crop per variant). Overrides for an
    /// effect the clip no longer has are ignored (and dropped by `pruneVariantOverrides`).
    public var effectParameters: [UUID: [String: AnimatedProperty<Double>]]

    public init(position: AnimatedProperty<Vec2>? = nil, scale: AnimatedProperty<Vec2>? = nil,
                rotation: AnimatedProperty<Double>? = nil, anchor: AnimatedProperty<Vec2>? = nil,
                conform: ConformMode? = nil, generator: GeneratorRef? = nil,
                effectParameters: [UUID: [String: AnimatedProperty<Double>]] = [:],
                tiltX: AnimatedProperty<Double>? = nil, tiltY: AnimatedProperty<Double>? = nil) {
        self.tiltX = tiltX; self.tiltY = tiltY
        self.position = position; self.scale = scale; self.rotation = rotation; self.anchor = anchor
        self.conform = conform; self.generator = generator; self.effectParameters = effectParameters
    }

    public var isEmpty: Bool {
        position == nil && scale == nil && rotation == nil && anchor == nil && tiltX == nil && tiltY == nil && conform == nil && generator == nil
            && effectParameters.values.allSatisfy(\.isEmpty)
    }

    public func has(_ p: VariantProperty) -> Bool {
        switch p {
        case .position: position != nil
        case .scale: scale != nil
        case .rotation: rotation != nil
        case .anchor: anchor != nil
        case .tilt: tiltX != nil || tiltY != nil
        }
    }

    public mutating func reset(_ p: VariantProperty) {
        switch p {
        case .position: position = nil
        case .scale: scale = nil
        case .rotation: rotation = nil
        case .anchor: anchor = nil
        case .tilt: tiltX = nil; tiltY = nil
        }
    }

    /// Every key time through `f` (keeps ids and easing).
    func remapped(_ f: (Time) -> Time) -> VariantOverride {
        var o = self
        o.position = position?.remapped(f); o.scale = scale?.remapped(f)
        o.rotation = rotation?.remapped(f); o.anchor = anchor?.remapped(f)
        o.tiltX = tiltX?.remapped(f); o.tiltY = tiltY?.remapped(f)
        o.effectParameters = effectParameters.mapValues { $0.mapValues { $0.remapped(f) } }
        return o
    }

    /// Animated properties replaced by their value at clip-local `t` (an inserted frame hold is a pause in time).
    func frozen(atLocal t: Time) -> VariantOverride {
        func fz<V>(_ p: AnimatedProperty<V>?) -> AnimatedProperty<V>? { p.map { AnimatedProperty($0.value(atLocal: t)) } }
        var o = self
        o.position = fz(position); o.scale = fz(scale); o.rotation = fz(rotation); o.anchor = fz(anchor)
        o.tiltX = fz(tiltX); o.tiltY = fz(tiltY)
        o.effectParameters = effectParameters.mapValues { $0.mapValues { AnimatedProperty($0.value(atLocal: t)) } }
        return o
    }

    private enum CodingKeys: String, CodingKey { case position, scale, rotation, anchor, conform, generator, effectParameters, tiltX, tiltY }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(position, forKey: .position); try c.encodeIfPresent(scale, forKey: .scale)
        try c.encodeIfPresent(rotation, forKey: .rotation); try c.encodeIfPresent(anchor, forKey: .anchor)
        if tiltX != nil || tiltY != nil {
            try c.encodeIfPresent(tiltX, forKey: .tiltX); try c.encodeIfPresent(tiltY, forKey: .tiltY)
            (e.userInfo[TiltSeen.key] as? TiltSeen)?.mark()   // v84 gate (`ProjectFile.encode`)
        }
        try c.encodeIfPresent(conform, forKey: .conform); try c.encodeIfPresent(generator, forKey: .generator)
        let fx = effectParameters.filter { !$0.value.isEmpty }
        if !fx.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: fx.map { ($0.key.uuidString, $0.value) }), forKey: .effectParameters)
        }
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: [String: AnimatedProperty<Double>]].self, forKey: .effectParameters) ?? [:]
        var fx: [UUID: [String: AnimatedProperty<Double>]] = [:]
        for (k, v) in raw { if let id = UUID(uuidString: k) { fx[id] = v } }
        self.init(position: try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .position),
                  scale: try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .scale),
                  rotation: try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .rotation),
                  anchor: try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .anchor),
                  conform: try c.decodeIfPresent(ConformMode.self, forKey: .conform),
                  generator: try c.decodeIfPresent(GeneratorRef.self, forKey: .generator),
                  effectParameters: fx,
                  tiltX: try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .tiltX),
                  tiltY: try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .tiltY))
    }
}

/// A clip's overrides, stored as an object keyed by variant id string (a `[UUID: _]` would encode as a flat array).
/// Never stored empty: `Clip.variantOverrides` keeps it nil instead, so clips without overrides write nothing.
struct VariantOverrides: Sendable, Hashable, Codable {
    var items: [FormatVariant.ID: VariantOverride]

    init(_ items: [FormatVariant.ID: VariantOverride]) { self.items = items }

    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: items.map { ($0.key.uuidString, $0.value) }))
    }
    init(from d: Decoder) throws {
        let raw = try d.singleValueContainer().decode([String: VariantOverride].self)
        var out: [FormatVariant.ID: VariantOverride] = [:]
        for (k, v) in raw { if let id = UUID(uuidString: k), !v.isEmpty { out[id] = v } }
        items = out
    }
}

extension Clip {
    /// Sparse per-variant overrides. Setting drops empty overrides; an empty map stores nothing.
    public var variantOverrides: [FormatVariant.ID: VariantOverride] {
        get { variantStore?.items ?? [:] }
        set {
            let kept = newValue.filter { !$0.value.isEmpty }
            variantStore = kept.isEmpty ? nil : VariantOverrides(kept)
        }
    }

    /// Moves every override key time through `f` (the clip's own keys moved the same way).
    mutating func remapVariantKeys(_ f: (Time) -> Time) {
        remapBakedKeys(f)   // W7.5: baked-effect records follow the clip's keys on every path that moves them
        remapMaskKeys(f)    // W6.7: mask keys too
        graphicsStore?.remapItemKeys(f)   // the keys of a Graphic's items are clip-local too
        guard let s = variantStore else { return }
        variantStore = VariantOverrides(s.items.mapValues { $0.remapped(f) })
    }

    mutating func shiftVariantKeys(by delta: Time) {
        guard delta != .zero else { return }
        remapVariantKeys { $0 + delta }
    }

    /// This clip as it renders in `variant` of a sequence of format `base`: the base values conformed into the variant's
    /// size, then the clip's own override for that variant on top. Audio clips are returned unchanged.
    /// `conformsPicture: false` skips the automatic picture conform (a nested clip whose inner sequence is itself rendered
    /// in the same variant already has the variant's size).
    public func resolved(for variant: FormatVariant, base: SequenceFormat, conformsPicture: Bool = true) -> Clip {
        guard kind == .video else { return self }
        let target = variant.format(base: base)
        let o = variantStore?.items[variant.id]
        var n = self
        if let g = generator {
            if g.kind == GeneratorRef.text { n = SequenceConform.conformText(self, from: base, to: target, blockSize: nil) }
        } else if conformsPicture {
            n = SequenceConform.conformPicture(self, factor: SequenceConform.frameFactor(from: base, to: target,
                                                                                         mode: o?.conform ?? variant.conform))
        }
        guard let o else { return n }
        if let p = o.position { n.animation.position = p }
        if let p = o.scale { n.animation.scale = p }
        if let p = o.rotation { n.animation.rotation = p }
        if let p = o.anchor { n.animation.anchor = p }
        if let p = o.tiltX { n.animation.tiltX = p }
        if let p = o.tiltY { n.animation.tiltY = p }
        if let g = o.generator, g.kind == generator?.kind { n.generator = g }
        if !o.effectParameters.isEmpty {
            for i in n.effects.indices {
                guard let ps = o.effectParameters[n.effects[i].id] else { continue }
                for (k, v) in ps { n.effects[i].parameters[k] = v }
            }
        }
        return n
    }
}

extension Timeline {
    public func variant(_ id: FormatVariant.ID?) -> FormatVariant? {
        guard let id else { return nil }
        return variants.first { $0.id == id }
    }

    /// The canvas for `variant`; the sequence's own format for nil or an unknown id.
    public func format(for variant: FormatVariant.ID?) -> SequenceFormat {
        self.variant(variant)?.format(base: format) ?? format
    }

    /// `clip` as it renders in `variant`; unchanged for nil or an unknown id. Does not know nested sequences: for display
    /// and edits use `Project.displayedClip(_:in:variant:)`, which skips the conform where render does.
    public func resolvedClip(_ clip: Clip, variant: FormatVariant.ID?) -> Clip {
        guard let v = self.variant(variant) else { return clip }
        return clip.resolved(for: v, base: format)
    }

    public func override(of clip: Clip.ID, in variant: FormatVariant.ID) -> VariantOverride? {
        find(clip)?.clip.variantOverrides[variant]
    }

    // MARK: Variant list

    @discardableResult
    public mutating func addVariant(name: String, width: Int, height: Int, conform: ConformMode = .fill) throws -> FormatVariant.ID {
        guard FormatVariant.validSize(width, height) else { throw EditError.invalidFormat }
        let v = FormatVariant(name: name, width: width, height: height, conform: conform)
        variants.append(v)
        return v.id
    }

    /// Removes the variant and every clip's override for it.
    public mutating func removeVariant(_ id: FormatVariant.ID) throws {
        guard variants.contains(where: { $0.id == id }) else { throw VariantError.variantNotFound }
        variants.removeAll { $0.id == id }
        forEachClip { c in
            guard c.variantOverrides[id] != nil else { return false }
            c.variantOverrides[id] = nil
            return true
        }
    }

    public mutating func renameVariant(_ id: FormatVariant.ID, to name: String) throws {
        try withVariant(id) { $0.name = name }
    }

    /// Overrides keep their values (they are in sequence pixels of the variant); the automatic part follows the new size.
    public mutating func setVariantSize(_ id: FormatVariant.ID, width: Int, height: Int) throws {
        guard variants.contains(where: { $0.id == id }) else { throw VariantError.variantNotFound }
        guard FormatVariant.validSize(width, height) else { throw EditError.invalidFormat }
        try withVariant(id) { $0.width = width; $0.height = height }
    }

    public mutating func setVariantConform(_ id: FormatVariant.ID, _ mode: ConformMode) throws {
        try withVariant(id) { $0.conform = mode }
    }

    private mutating func withVariant(_ id: FormatVariant.ID, _ body: (inout FormatVariant) -> Void) throws {
        guard let i = variants.firstIndex(where: { $0.id == id }) else { throw VariantError.variantNotFound }
        body(&variants[i])
    }

    // MARK: Overrides

    /// Replaces a clip's override for `variant` (nil or empty = remove it).
    public mutating func setOverride(_ o: VariantOverride?, clip: Clip.ID, variant: FormatVariant.ID) throws {
        try editOverride(clip: clip, variant: variant) { $0 = o ?? VariantOverride() }
    }

    /// Edits a clip's override for `variant` in place, starting from an empty one when there is none. An override left
    /// empty is removed (sparse storage). One call = one value change of the timeline (one undo step in a commit).
    public mutating func editOverride(clip: Clip.ID, variant: FormatVariant.ID, _ body: (inout VariantOverride) throws -> Void) throws {
        guard variants.contains(where: { $0.id == variant }) else { throw VariantError.variantNotFound }
        guard let m = find(clip) else { throw EditError.clipNotFound }
        var c = m.clip
        var o = c.variantOverrides[variant] ?? VariantOverride()
        try body(&o)
        c.variantOverrides[variant] = o
        tracks[m.track].replace(c)
    }

    /// Copies the current automatic values of `properties` into the clip's override (keys included), so the variant can
    /// be edited without anything moving. Properties already overridden keep their values.
    public mutating func detach(_ properties: Set<VariantProperty>, clip: Clip.ID, variant: FormatVariant.ID) throws {
        guard let v = self.variant(variant) else { throw VariantError.variantNotFound }
        guard let m = find(clip) else { throw EditError.clipNotFound }
        let r = m.clip.resolved(for: v, base: format)
        try editOverride(clip: clip, variant: variant) { o in
            for p in properties where !o.has(p) {
                switch p {
                case .position: o.position = r.animation.position
                case .scale: o.scale = r.animation.scale
                case .rotation: o.rotation = r.animation.rotation
                case .anchor: o.anchor = r.animation.anchor
                case .tilt: o.tiltX = r.animation.tiltX; o.tiltY = r.animation.tiltY
                }
            }
        }
    }

    /// Back to automatic: one property, or the whole override (nil).
    public mutating func resetOverride(_ property: VariantProperty?, clip: Clip.ID, variant: FormatVariant.ID) throws {
        try editOverride(clip: clip, variant: variant) { o in
            if let property { o.reset(property) } else { o = VariantOverride() }
        }
    }

    /// Drops overrides for variants this sequence does not have and effect overrides for effects a clip no longer has
    /// (e.g. after pasting from another sequence). True when anything changed.
    @discardableResult
    public mutating func pruneVariantOverrides() -> Bool {
        let known = Set(variants.map(\.id))
        var changed = false
        forEachClip { c in
            guard !c.variantOverrides.isEmpty else { return false }
            let fx = Set(c.effects.map(\.id))
            var out: [FormatVariant.ID: VariantOverride] = [:]
            for (k, var o) in c.variantOverrides where known.contains(k) {
                o.effectParameters = o.effectParameters.filter { fx.contains($0.key) && !$0.value.isEmpty }
                out[k] = o
            }
            let before = c.variantOverrides
            c.variantOverrides = out
            if c.variantOverrides != before { changed = true; return true }
            return false
        }
        return changed
    }

    /// Runs `body` on every clip; replaces the clip when it returns true.
    private mutating func forEachClip(_ body: (inout Clip) -> Bool) {
        for i in tracks.indices {
            for c in tracks[i].clips {
                var n = c
                if body(&n) { tracks[i].replace(n) }
            }
        }
    }
}

extension Project {
    /// Runs `body` on one timeline in place (for value edits such as variants inside one `History.commit`).
    @discardableResult
    public mutating func withTimeline<R>(_ id: Timeline.ID, _ body: (inout Timeline) throws -> R) throws -> R {
        guard let i = timelines.firstIndex(where: { $0.id == id }) else { throw EditError.timelineNotFound }
        return try body(&timelines[i])
    }

    /// `Timeline.pruneVariantOverrides` on every timeline. True when anything changed.
    @discardableResult
    public mutating func pruneVariantOverrides() -> Bool {
        var changed = false
        for i in timelines.indices where timelines[i].pruneVariantOverrides() { changed = true }
        return changed
    }
}
