import Foundation

// Unified masks: every mask (Magic, Pen, Ellipse, Rectangle) is an item of the clip (`Clip.masks`). It cuts the clip's
// picture (Opacity) while `usedByOpacity`, and limits any picture effect that lists it in `ClipEffect.maskInput`. One mask
// can feed several effects. ProjectFile v54 gate.

extension ClipEffect {
    /// Kinds whose result the renderer can mix back over the picture they read, by the coverage of their input masks: blur
    /// and the picture filters, the keys, Transform (then a picture warp instead of a clip transform) and Color (then a
    /// grade pass in the effect chain). The clip decides for Color (`Clip.takesMaskInput`: not its first one).
    public var acceptsMaskInput: Bool { Self.maskInputKinds.contains(kind) }

    public static let maskInputKinds: Set<String> = [
        gaussianBlurKind, sharpenKind, unsharpMaskKind, directionalBlurKind, mirrorKind, noiseKind, glowKind, mosaicKind,
        vignetteKind, grainKind, rgbSplitKind, radialBlurKind, horizontalFlipKind, verticalFlipKind, invertKind,
        posterizeKind, tintKind, blackAndWhiteKind, brightnessContrastKind, twirlKind, cornerPinKind, waveWarpKind, spherizeKind,
        strobeKind, lensDistortionKind, lightLeakKind, gradientKind, halftoneKind, tileKind, kaleidoscopeKind, edgeFeatherKind, glitchKind,
        outlineKind, longShadowKind,
        ultraKeyKind, lumaKeyKind, transformKind, colorKind,
    ]
}

extension Clip {
    /// Whether `e` can take a mask input on this clip. The first Color effect converts the footage (the base grade every
    /// later effect builds on), so it stays whole; a masked grade is a second Color effect.
    public func takesMaskInput(_ e: ClipEffect) -> Bool {
        guard e.acceptsMaskInput else { return false }
        guard e.isColor else { return true }
        return effects.first(where: \.isColor)?.id != e.id
    }

    /// `e` takes a mask input here and at least one of its input masks exists and is on: the renderer then runs it as a
    /// masked pass (Color: out of the clip's grade; Transform: out of the clip's transform).
    func hasLiveMaskInput(_ e: ClipEffect) -> Bool {
        guard !e.maskInput.isEmpty, takesMaskInput(e) else { return false }
        return masks.contains { $0.enabled && e.maskInput.contains($0.id) }
    }

    /// The shapes of `e`'s input masks at clip-local `t` (enabled ones that still exist, in the clip's list order).
    func inputMaskShapes(_ e: ClipEffect, atLocal t: Time) -> [MaskShape] {
        guard !e.maskInput.isEmpty, takesMaskInput(e) else { return [] }
        let ids = Set(e.maskInput)
        return masks.filter { $0.enabled && ids.contains($0.id) }.map { maskShape($0, atLocal: t) }
            .filter { $0.polygon.count >= 2 || $0.source.usesMatte }
    }

    /// Effects of this clip that take mask `id` as input.
    public func effectsUsing(mask id: ClipMask.ID) -> [ClipEffect.ID] {
        effects.filter { $0.maskInput.contains(id) }.map(\.id)
    }

    /// Adds or removes mask `id` as an input of effect `effectID` (no duplicates; only on kinds that take one).
    public mutating func setMask(_ id: ClipMask.ID, input on: Bool, ofEffect effectID: ClipEffect.ID) {
        guard mask(id) != nil, let i = effects.firstIndex(where: { $0.id == effectID }), takesMaskInput(effects[i]) else { return }
        effects[i].maskInput.removeAll { $0 == id }
        if on { effects[i].maskInput.append(id) }
        pinCovers()                                                 // an effect limited to an Anonymize mask is a cover
    }

    /// Whether mask `id` cuts the clip's picture (Opacity).
    public mutating func setMask(_ id: ClipMask.ID, usedByOpacity on: Bool) {
        updateMask(id) { $0.usedByOpacity = on }
    }

    /// Deletes a mask and drops it from every effect's input.
    public mutating func removeMask(_ id: ClipMask.ID) {
        masks.removeAll { $0.id == id }
        for i in effects.indices { effects[i].maskInput.removeAll { $0 == id } }
    }

    // MARK: Mask tool clicks (Program monitor)

    /// Magic mode click at frame fraction `p` on the source frame at `sourceTime`. Adds the point to mask `id`: on the
    /// pick's own frame it adds / removes objects, on any other frame it corrects the tracked matte from there on
    /// (`MagicFollower`); `id` nil makes a new Magic mask. A subtract (Option) click needs a pick to subtract from.
    /// Returns the mask, nil when nothing changed.
    @discardableResult
    public mutating func magicClick(_ id: ClipMask.ID?, at p: Vec2, subtract: Bool, sourceTime: Time) -> ClipMask.ID? {
        let point = MagicPoint(position: p, subtract: subtract, sourceTime: sourceTime)
        if let id, let m = mask(id), m.source == .magic {
            var sel = m.magic ?? MagicSelection()
            if subtract && sel.points.isEmpty { return nil }
            sel.points.append(point)
            updateMask(id) { $0.magic = sel }
            return id
        }
        guard !subtract else { return nil }
        let m = ClipMask.makeMagic(name: nextMaskName, points: [point])
        masks.append(m)
        return m.id
    }

    /// Pen mode click: appends a corner point to path mask `id` (at clip-local `t`, a key there when animated), or starts a
    /// new path mask with this first point. Returns the mask.
    @discardableResult
    public mutating func penClick(_ id: ClipMask.ID?, at p: Vec2, atLocal t: Time) -> ClipMask.ID {
        if let id, let m = mask(id), m.source == .path {
            var path = m.path.value(atLocal: t)
            path.vertices.append(MaskVertex(p))
            setMaskPath(id, path, atLocal: t)
            return id
        }
        let m = ClipMask(name: nextMaskName, kind: .bezier, path: MaskPath(vertices: [MaskVertex(p)]), feather: ClipMask.defaultFeather)
        masks.append(m)
        return m.id
    }

    /// Ellipse / Rectangle mode click: the default shape centered on `p`.
    @discardableResult
    public mutating func addShapeMask(_ kind: MaskShapeKind, at p: Vec2) -> ClipMask.ID {
        var m = ClipMask.make(kind, name: nextMaskName)
        m.path.value = m.path.value.translated(by: p - Vec2(0.5, 0.5))
        masks.append(m)
        return m.id
    }

    /// Ellipse / Rectangle drawn by dragging: the path as `MaskShapeDrag` made it.
    @discardableResult
    public mutating func addShapeMask(_ kind: MaskShapeKind, path: MaskPath) -> ClipMask.ID {
        let m = ClipMask(name: nextMaskName, kind: kind, path: path, feather: ClipMask.defaultFeather)
        masks.append(m)
        return m.id
    }

    /// True when any mask is a Magic mask.
    public var hasMagicMask: Bool { masks.contains { $0.source == .magic } }

    /// Anything only v54 can hold: a Magic mask, a mask that does not cut Opacity, or an effect with a mask input.
    var holdsMaskInputs: Bool {
        masks.contains { $0.source == .magic || !$0.usedByOpacity } || effects.contains { !$0.maskInput.isEmpty }
    }

    /// Masks as Paste Attributes copies them, with the old -> new id map (for the pasted effects' inputs).
    func pastedMasksWithMap() -> (masks: [ClipMask], map: [UUID: UUID]) {
        var map: [UUID: UUID] = [:]
        let out = masks.map { m -> ClipMask in var c = m; c.id = UUID(); map[m.id] = c.id; return c }
        return (out, map)
    }

    /// Points every effect input through `map`; inputs that are not in it are dropped.
    mutating func remapMaskInputs(_ map: [UUID: UUID]) {
        for i in effects.indices where !effects[i].maskInput.isEmpty {
            effects[i].maskInput = effects[i].maskInput.compactMap { map[$0] }
        }
    }
}

/// A Rectangle / Ellipse being drawn with the Mask tool: a rubber band from the press (`start`, frame fraction) to the
/// pointer. Shift = square / circle (equal sides in frame px), Option = `start` is the center (Premiere / Resolve).
public struct MaskShapeDrag: Sendable, Equatable {
    public var kind: MaskShapeKind
    public var start: Vec2
    public init(kind: MaskShapeKind, start: Vec2) { self.kind = kind; self.start = start }

    /// Pointer travel (view pt) below which a press counts as a click (the default shape there instead).
    public static let clickDistance: Double = 3
    public static func isClick(viewDistance d: Double) -> Bool { d < clickDistance }

    /// The shape for the pointer at `p`. `frame` = the clip's frame size in px (for Shift's equal sides).
    public func path(to p: Vec2, square: Bool, fromCenter: Bool, frame: Vec2) -> MaskPath {
        var d = p - start
        if square, frame.x > 0, frame.y > 0 {
            let side = max(abs(d.x) * frame.x, abs(d.y) * frame.y)
            d = Vec2((d.x < 0 ? -side : side) / frame.x, (d.y < 0 ? -side : side) / frame.y)
        }
        let a = fromCenter ? start - d : start, b = start + d
        switch kind {
        case .ellipse:
            let r = Vec2(abs(b.x - a.x) / 2, abs(b.y - a.y) / 2)
            return MaskPath.ellipse(center: Vec2((a.x + b.x) / 2, (a.y + b.y) / 2), radius: r)
        case .rectangle, .bezier:
            return MaskPath.rectangle(a, b)
        }
    }
}

extension ClipEffects {
    /// Magic masks evaluated anywhere in the clip (Opacity or an effect's input): the renderer needs their mattes
    /// (`RenderLayer.mattes`, keyed by mask id).
    public var magicMatteKeys: [UUID] { magicMattes.map(\.mask) }

    /// Each Magic mask once: its id, the cache key of the matte it draws and its edge (Feather / Expansion, clip frame px).
    /// `baseKey` / `mustCover`: masks made by Anonymize (`MaskShape.matteBaseKey`, `matteMustCover`).
    public var magicMattes: [MagicMatteUse] {
        var out: [MagicMatteUse] = []
        for m in masks + segments.flatMap(\.scope) where m.source == .magic {
            if let k = m.matteKey, !out.contains(where: { $0.mask == k }) {
                out.append(MagicMatteUse(mask: k, cacheKey: m.matteCacheKey ?? "", feather: m.feather, expansion: m.expansion,
                                         baseKey: m.matteBaseKey, mustCover: m.matteMustCover))
            }
        }
        return out
    }
}

/// One Magic mask a layer evaluates (`ClipEffects.magicMattes`).
public struct MagicMatteUse: Sendable, Hashable {
    public var mask: UUID
    public var cacheKey: String
    public var feather: Double
    public var expansion: Double
    public var baseKey: String?
    public var mustCover: Bool
    public init(mask: UUID, cacheKey: String, feather: Double, expansion: Double, baseKey: String? = nil, mustCover: Bool = false) {
        self.mask = mask; self.cacheKey = cacheKey; self.feather = feather; self.expansion = expansion
        self.baseKey = baseKey; self.mustCover = mustCover
    }
}

extension Project {
    /// ProjectFile v54 gate.
    public var containsMaskInputs: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains(where: \.holdsMaskInputs) } }
    }
}
