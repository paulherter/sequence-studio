import Foundation

/// Layers nobody can see: everything composited under an opaque picture that fills the canvas. Export leaves such layers
/// out (no decode, no grade); the output is the same picture, so the rule is deliberately narrow and only says "hidden"
/// when that is certain (DECISIONS 2026-10-06, PLAYBACK-PERF "Export: hidden layers").
public enum LayerOcclusion {
    /// Upright size in pixels of a source known to carry no transparency (the size its layer is drawn at for Scale 1).
    public struct Picture: Sendable, Hashable {
        public var width: Int, height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    public struct Result: Sendable, Hashable {
        /// Indices into the evaluated layers that cannot show.
        public var hidden: Set<Int> = []
        /// Index of the layer that hides them; nil = nothing is hidden. The caller checks that this layer really is drawn
        /// as assumed (frame decoded, size as given) and draws everything otherwise.
        public var cover: Int?
        public init(hidden: Set<Int> = [], cover: Int? = nil) { self.hidden = hidden; self.cover = cover }
    }

    /// `layers`: `Timeline.videoLayers(at:)`, bottom first. `picture`: the upright size of a media layer's source when the
    /// source is opaque video, nil when unknown or when it may be transparent.
    ///
    /// A cover is a media layer drawn plainly: Opacity 1, Normal blend, no rotation, no effect of its own (crop, corners,
    /// masks, keys, blur, shadow, stabilizer, motion blur), outside every transition, whose rectangle reaches all four
    /// canvas edges. Inside nested sequences it must fill the nest's canvas and every enclosing nest must be drawn just as
    /// plainly and fill its parent; a nest that does not still hides what lies below the cover inside it.
    /// Hidden are the media layers below the topmost cover that are plain enough to drop: not part of a transition (a
    /// transition composites its sides apart) and without state carried from frame to frame (denoise, subject mask,
    /// tracked masks). Generators stay: they cost no decode.
    public static func evaluate(_ layers: [LayerRequest], canvas: SequenceFormat,
                                picture: (LayerRequest) -> Picture?) -> Result {
        guard layers.count > 1 else { return Result() }
        for i in layers.indices.reversed() where i > 0 {
            let l = layers[i]
            guard l.generator == nil, isPlain(l), let p = picture(l) else { continue }
            let own = l.groups.last?.format ?? canvas
            guard fills(l.transform, width: p.width, height: p.height, canvas: own) else { continue }
            // `level`: how many of the enclosing nests (outermost first) do NOT pass the cover on: every nest from there
            // inwards fills its parent, so the cover hides everything below it in the sequence at that level.
            var level = l.groups.count
            while level > 0 {
                let g = l.groups[level - 1]
                let parent = level > 1 ? l.groups[level - 2].format : canvas
                guard isPlain(g), fills(g.transform, width: g.format.displayWidth, height: g.format.height, canvas: parent) else { break }
                level -= 1
            }
            let scope = l.groups.prefix(level).map(\.clip)
            var hidden = Set<Int>()
            for j in 0..<i where canDrop(layers[j]) && layers[j].groups.prefix(level).map(\.clip) == scope {
                hidden.insert(j)
            }
            if !hidden.isEmpty { return Result(hidden: hidden, cover: i) }
            if level == 0 { return Result() }      // a full cover with nothing to drop: no cover below it hides more
        }
        return Result()
    }

    private static let plainEffects = ClipEffects(cornerRadius: 0)

    private static func isPlain(_ t: ClipTransform) -> Bool {
        t.opacity >= 1 && t.rotation == 0 && !t.isTilted && t.scale.x > 0 && t.scale.y > 0
    }

    private static func isPlain(_ l: LayerRequest) -> Bool {
        isPlain(l.transform) && l.blendMode == .normal && l.cornerRadius == 0 && l.effects == plainEffects
            && l.pair == nil && !l.inTransition && l.stackTransitions.isEmpty && l.motionBlur == nil && l.gyro == nil
            && l.shape == nil
            // C6: a matte layer is not drawn into the picture, so it covers nothing.
            && l.matteFor == nil
            // Frame Blending / Optical Flow need a second frame; without it the layer is a placeholder that covers nothing.
            && l.interpolation == .frameSampling
    }

    private static func isPlain(_ g: LayerGroup) -> Bool {
        isPlain(g.transform) && g.blendMode == .normal && g.cornerRadius == 0 && g.effects == plainEffects
    }

    /// The layer may be left out when covered.
    private static func canDrop(_ l: LayerRequest) -> Bool {
        l.generator == nil && l.pair == nil && !l.inTransition && l.stackTransitions.isEmpty && l.matteFor == nil
            && l.effects.temporal == nil && !l.effects.needsSubjectMatte && l.effects.magicMattes.isEmpty
    }

    /// The rectangle of a `width` x `height` picture under `t` (no rotation) reaches all four edges of `canvas`. Same
    /// geometry as the compositor: center = canvas center + position, corners = (+-size / 2 - anchor) * scale.
    private static func fills(_ t: ClipTransform, width: Int, height: Int, canvas: SequenceFormat) -> Bool {
        let cw = Double(canvas.displayWidth), ch = Double(canvas.height), w = Double(width), h = Double(height)
        guard w > 0, h > 0, cw > 0, ch > 0 else { return false }
        let x0 = cw / 2 + t.position.x + (-w / 2 - t.anchor.x) * t.scale.x
        let x1 = cw / 2 + t.position.x + (w / 2 - t.anchor.x) * t.scale.x
        let y0 = ch / 2 + t.position.y + (-h / 2 - t.anchor.y) * t.scale.y
        let y1 = ch / 2 + t.position.y + (h / 2 - t.anchor.y) * t.scale.y
        // Pixel centers lie half a pixel inside the canvas; the tolerance only absorbs rounding of an exact fit.
        let e = 0.01
        return x0 <= e && y0 <= e && x1 >= cw - e && y1 >= ch - e
    }
}
