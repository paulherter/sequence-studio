import Foundation
import SQCore
import SQFrame

// The render model the compositor draws (layers, nodes, adjustment groups): portable, no GPU types.
public enum PlaceholderKind: Sendable { case offline, damaged, loading }

/// How a text clip's glyphs use the picture below them (`RenderLayer.footageFill`).
public enum FootageFill: Sendable, Hashable {
    /// The glyphs are a window onto what is below: it shows only inside them.
    case stencil
    /// The glyphs invert what is below them.
    case inverted
}

/// One layer of one display frame, built by the caller from `LayerRequest` + frame cache.
/// `transform` is the already evaluated `LayerRequest.transform`: position = offset from the canvas center in
/// sequence px (y down), scale linear x/y, rotation in degrees (positive = clockwise on screen), anchor = offset from
/// the layer's center in sequence px, opacity 0...1. The layer is drawn at its own (upright) pixel size, one source pixel
/// per sequence pixel at scale 1 (Premiere: 100 % = source pixels; "Set to Frame Size" writes the fit value into the
/// scale), scaled/rotated about the anchor; the anchor lands on `canvas center + position`.
public struct RenderLayer: @unchecked Sendable {
    public enum Content: @unchecked Sendable {
        case frame(SQFrame, colorHint: VideoTrackInfo)
        case placeholder(PlaceholderKind)
        /// Linear-light premultiplied `kCVPixelFormatType_64RGBAHalf` raster (text), drawn at exactly `width` x `height`
        /// sequence px (no aspect fit); `transform` positions its center like any other layer.
        case linearPremultiplied(SQFrame, width: Double, height: Double)
        /// Flat color over the whole canvas (transition dips). Display-encoded (BT.709 OETF) 0...1; the compositor linearises it.
        case solid(red: Float, green: Float, blue: Float)
    }
    public var content: Content
    public var transform: ClipTransform
    /// Per-layer color stage slot. nil = Rec.709 source: the compositor applies only the inverse BT.709 OETF
    /// (source-encoded -> working-linear). Non-nil = YCbCr->RGB into an intermediate, `ColorPipelineGPU.encode`
    /// (source-encoded -> working-linear, includes the output of the chain), then composite with no further transfer.
    public var colorPipeline: ColorPipeline?
    /// Rounded-corner radius in px of the layer as if it were aspect-fitted into the canvas, applied BEFORE the transform
    /// scale, so it scales with the clip (Premiere-like). Clamped to half the shorter side. 0 = square corners.
    public var cornerRadius: Double
    /// Pixel size of the picture before rotation (the track's native size). A decode at reduced quality hands over a
    /// smaller buffer that must still be drawn at the native size: scale 1 = one native pixel per sequence pixel.
    /// nil = the buffer's own size.
    public var nativeSize: (width: Int, height: Int)?
    /// Crop, Rounded Corners and Gaussian Blur of the clip. Identity = the plain path (no effect maths runs); then
    /// `cornerRadius` above is used as before.
    public var effects: ClipEffects
    /// Opacity > Blend Mode. Normal = plain alpha-over.
    public var blendMode: BlendMode
    /// Frame Blending: the second source frame and its weight (see `FrameBlend`). Only used with `.frame` content.
    public var blend: FrameBlend?
    /// Video Denoise / Deflicker: the filter and the neighboring source frames it reads (see `TemporalFrames`). Only used
    /// with `.frame` content; takes precedence over `blend`.
    public var temporal: TemporalFrames?
    /// W9.8: the (smoothed) person matte of this frame, covering the clip's own upright frame; read by subject masks in
    /// `effects.masks`. nil = subject masks are left out (nothing cut).
    public var subjectMatte: SubjectMatte?
    /// Magic masks' tracked mattes of this frame (with their edge applied), by mask id (`MaskShape.matteKey`), each covering
    /// the clip's upright frame. A Magic mask without an entry covers nothing (not tracked there).
    public var mattes: [UUID: SubjectMatte] = [:]
    /// Only with `.linearPremultiplied` content: the buffer holds a part of the layer's picture, the rest is transparent
    /// (an animated text raster cut to what is painted). `width`/`height`, `transform`, corner radius, effects, masks
    /// and blend mode all work on the whole rectangle: the compositor reads the part at the whole picture's texel
    /// coordinates, transparent outside it (`Compositor.drawsContentPartsDirectly`; switched off it copies the part
    /// texel for texel into a cleared picture of the whole size first). Either way the picture is the one of a whole
    /// buffer (`PartialContentTests`: bit for bit).
    public var contentPart: ContentPart?
    /// Footage fill (a text clip's glyphs as a stencil): the layer is not drawn over what is below it but is a matte of it. The
    /// picture below shows only where the layer covers it (times the layer's opacity), every other pixel of the canvas is
    /// cleared; the blend mode is ignored. `.inverted`: the layer (a white glyph) is drawn with Difference, so what is
    /// below it shows inverted under the glyph. Kept by `applying(_:)`; inside a transition side or pair the layer is plain (a stencil's raster keeps the title's color, an inverted one is white).
    public var footageFill: FootageFill?
    /// Footage fill as a stencil (see `footageFill`).
    var stencil: Bool { footageFill == .stencil }

    /// Where a partial buffer lies in the whole picture: its top-left texel and the whole picture's size in texels.
    public struct ContentPart: Sendable, Hashable {
        public var x: Int, y: Int
        public var wholeWidth: Int, wholeHeight: Int
        public init(x: Int, y: Int, wholeWidth: Int, wholeHeight: Int) {
            self.x = x; self.y = y; self.wholeWidth = wholeWidth; self.wholeHeight = wholeHeight
        }
        /// A buffer of this size at `x`, `y` lies inside the whole picture.
        func holds(width: Int, height: Int) -> Bool {
            x >= 0 && y >= 0 && x + width <= wholeWidth && y + height <= wholeHeight
        }
    }

    /// The stand-in layer of an Adjustment Layer request: draws nothing itself (`RenderNode.tree` turns the request into an
    /// `.adjustment` node over the layers below). `colorPipeline`: the clip's Lumetri grade, run on the picture below.
    public static func adjustment(transform: ClipTransform = .identity, colorPipeline: ColorPipeline? = nil) -> RenderLayer {
        RenderLayer(content: .placeholder(.loading), transform: transform, colorPipeline: colorPipeline)
    }

    /// A solid layer from a `GeneratorRef.solid` payload (RGB bytes).
    /// `colorPipeline` (the clip's grade) and `cornerRadius` are honored by the compositor like on a picture.
    public static func solid(payload: Data, transform: ClipTransform = .identity, colorPipeline: ColorPipeline? = nil,
                             cornerRadius: Double = 0) -> RenderLayer {
        let b = [UInt8](payload) + [0, 0, 0]
        return RenderLayer(content: .solid(red: Float(b[0]) / 255, green: Float(b[1]) / 255, blue: Float(b[2]) / 255),
                           transform: transform, colorPipeline: colorPipeline, cornerRadius: cornerRadius)
    }

    public init(content: Content, transform: ClipTransform = .identity, colorPipeline: ColorPipeline? = nil,
                cornerRadius: Double = 0, nativeSize: (width: Int, height: Int)? = nil,
                effects: ClipEffects = .none, blendMode: BlendMode = .normal, blend: FrameBlend? = nil) {
        self.blend = blend
        self.content = content; self.transform = transform; self.colorPipeline = colorPipeline
        self.cornerRadius = cornerRadius; self.nativeSize = nativeSize
        self.effects = effects; self.blendMode = blendMode
    }

    /// The same layer with the effects and blend mode of the request it was built from.
    public func applying(_ request: LayerRequest) -> RenderLayer {
        var l = self
        l.effects = request.effects
        l.blendMode = footageFill == .inverted ? .difference : request.blendMode
        return l
    }
}

/// Tree form of a display frame: a leaf layer, or a nested-sequence group whose children are composited offscreen
/// (transparent background, `format` size, rgba16Float premultiplied) and then drawn like a layer at its own size
/// (scale 1 = one inner px per parent px), with the group's `transform` (anchor/scale/rotation/position in the parent's px),
/// `opacity` (applied once to the whole image) and `cornerRadius` (in the group image's own px, before the scale).
public indirect enum RenderNode: @unchecked Sendable {
    case layer(RenderLayer)
    case group(format: SequenceFormat, transform: ClipTransform, opacity: Double, cornerRadius: Double, children: [RenderNode])
    /// A group whose nested clip has Crop, Blur, Ultra Key or a blend mode (the plain `.group` is the common case).
    case styledGroup(format: SequenceFormat, transform: ClipTransform, opacity: Double, cornerRadius: Double,
                     children: [RenderNode], effects: ClipEffects, blendMode: BlendMode)
    /// Cross dissolve of two pictures: `first` and `second` (opacities already folded in: 1-w and w) are summed as premultiplied
    /// color, `first + second`, into one transparent canvas-sized image that is then composited over what is below. Correct for
    /// letterboxed, transparent and nested pictures, on any track (a plain "over" of B on A would not fade A out where B is empty).
    case pair(format: SequenceFormat, first: [RenderNode], second: [RenderNode])
    /// Motion transition (push, slide, zoom, whip, wipe): `first` (outgoing) and `second` (incoming) are each composited into
    /// their own transparent canvas-sized image, then `render` moves, scales, smears and combines them (bilinear sampling, so
    /// edges land between pixels) into one image composited over what is below. Either side may be empty.
    case transition(format: SequenceFormat, render: TransitionRender, first: [RenderNode], second: [RenderNode])
    /// Wraps one node (a pair or group result) that is composited with a blend mode against what is below it.
    case blended(RenderNode, BlendMode)
    /// Footage fill: `children` (a matte layer drawn with opacity 1) are composited into a transparent canvas-sized image,
    /// which then keeps what is below it (the target so far) only where it covers it, `opacity` mixing the two. Everything
    /// outside the matte is cleared, canvas-wide.
    case stencil(opacity: Double, children: [RenderNode])
    /// W9.6 Adjustment Layer: `below` (everything under it in the same sequence) is composited into one transparent
    /// canvas-sized image, drawn plainly (`drawsBase`), and drawn again on top graded (`colorPipeline`) and with `effects`,
    /// Motion, `opacity` and `blendMode`: the adjusted picture over the unadjusted one, so opacity mixes the two and a crop
    /// or mask limits where the adjustment shows.
    case adjustment(AdjustmentNode, below: [RenderNode])
    /// C6 Picture masks: the picture of `track` (its matte layers, `LayerRequest.matteFor`) for the Picture masks of this
    /// level. Rendered once into a transparent image of the level's canvas, never drawn into the picture; every Picture mask
    /// of the level (and of the pair / transition sides inside it) reading `track` samples it, fixed to the screen.
    case pictureMatte(track: Track.ID, children: [RenderNode])
    /// C6: heads the node list of a held transition side (`StackTransition.held`). Its Picture masks read only the
    /// `.pictureMatte`s of that list (evaluated at the held time, possibly none), never the level's live ones. Draws nothing.
    case pictureScope

    /// Builds the tree from flat `LayerRequest`s (bottom -> top) and their prepared layers (`layers[i]` belongs to
    /// `requests[i]`). Consecutive layers sharing the same `groups` prefix (same nested clip) form one group,
    /// recursively. The group node's `opacity` is the nested clip's `transform.opacity`; its `transform.opacity` is 1.
    public static func tree(requests: [LayerRequest], layers: [RenderLayer]) -> [RenderNode] {
        // Unequal arrays (an inconsistent snapshot) pair up to the shorter one instead of trapping.
        return build(Array(zip(requests, layers)), depth: 0, forceNormal: false, under: [])
    }

    /// `forceNormal`: inside a transition pair every picture is plain "over" in the pair's own transparent image; the blend mode
    /// belongs to the pair as a whole (see `.blended`). `under`: inside a pair, what is below the pair (an adjustment layer
    /// that is one side of the transition adjusts it).
    private static func build(_ items: [(LayerRequest, RenderLayer)], depth: Int, forceNormal: Bool,
                              under: [RenderNode]) -> [RenderNode] {
        // C6: this level's matte layers come out first (a held transition side's and a pair side's own are built inside
        // that side); a matte no drawn layer of the level reads is left out (no pass).
        let (mattes, items) = pictureMattes(items, depth: depth)
        var out: [RenderNode] = []
        var i = 0
        while i < items.count {
            let (req, layer) = items[i]
            // Transition layer: everything below it at this level forms its two sides, each composited whole (its own pairs,
            // groups, adjustment layers and blend modes inside), then combined like a motion transition. Outermost first.
            if let st = req.stackTransitions.first, st.depth == depth {
                var j = i + 1
                while j < items.count, items[j].0.stackTransitions.first?.id == st.id { j += 1 }
                func side(_ role: LayerRequest.PairRole) -> [RenderNode] {
                    let mine = items[i..<j].filter { $0.0.stackTransitions.first?.role == role }
                    let nodes = build(mine.map { item in
                        var r = item.0; r.stackTransitions.removeFirst()
                        return (r, item.1)
                    }, depth: depth, forceNormal: false, under: [])
                    // A held side never inherits the level's live-time mattes; the live side does.
                    let held = mine.first?.0.stackTransitions.first?.held ?? false
                    return held && !nodes.isEmpty ? [.pictureScope] + nodes : nodes
                }
                out.append(.transition(format: st.format, render: st.render, first: side(.first), second: side(.second)))
                i = j
                continue
            }
            if let p = req.pair, p.depth == depth {
                var j = i + 1
                while j < items.count, items[j].0.pair?.id == p.id { j += 1 }
                func side(_ role: LayerRequest.PairRole) -> [RenderNode] {
                    build(items[i..<j].filter { $0.0.pair?.role == role }.map { item in
                        var r = item.0; r.pair = nil
                        return (r, item.1)
                    }, depth: depth, forceNormal: true, under: out)
                }
                // The pair's blend mode is the incoming clip's (second side); when that is Normal the outgoing clip's counts.
                // A nested clip contributes its group's mode.
                func mode(_ role: LayerRequest.PairRole) -> BlendMode {
                    guard let item = items[i..<j].first(where: { $0.0.pair?.role == role }) else { return .normal }
                    return item.0.groups.count > depth ? item.0.groups[depth].blendMode : item.0.blendMode
                }
                let incoming = mode(.second)
                let blend = incoming != .normal ? incoming : mode(.first)
                let node: RenderNode = p.render.map { .transition(format: p.format, render: $0, first: side(.first), second: side(.second)) }
                    ?? .pair(format: p.format, first: side(.first), second: side(.second))
                out.append(blend == .normal ? node : .blended(node, blend))
                i = j
                continue
            }
            guard req.groups.count > depth else {
                if req.isAdjustment {
                    // One side of a transition: the side is the adjusted picture alone (opacity = the transition weight), over
                    // what is under the pair. A dissolve then gives (1 - w) * adjusted + w * other, so the adjustment fades.
                    if let node = adjustment(req, layer: layer, below: forceNormal ? under + out : out, transitionSide: forceNormal) {
                        out = [node]
                    }
                    i += 1; continue
                }
                // Safety: a matte layer that reached here (no level reads it) is never drawn.
                if req.matteFor != nil { i += 1; continue }
                var l = layer
                if forceNormal { l.blendMode = .normal; l.footageFill = nil }
                // shortcut: a stencil layer has no motion blur (one sample; the blur copies are transparent intermediates the
                // stencil cannot read); upgrade by stenciling the summed copies when asked for.
                if let mb = req.motionBlur, mb.transforms.count > 1, !l.stencil {
                    out.append(motionBlurred(l, request: req, samples: mb)); i += 1; continue
                }
                out.append(.layer(l)); i += 1; continue
            }
            let g = req.groups[depth]
            var j = i + 1
            while j < items.count, items[j].0.groups.count > depth, items[j].0.groups[depth].clip == g.clip { j += 1 }
            var t = g.transform
            let opacity = t.opacity
            t.opacity = 1
            let kids = build(Array(items[i..<j]), depth: depth + 1, forceNormal: false, under: [])
            let groupBlend = forceNormal ? BlendMode.normal : g.blendMode
            let plain = groupBlend == .normal && g.effects.segments.count <= 1 && g.effects.pre.crop.isIdentity
                && g.effects.pre.feather == 0
                && g.effects.keys.isEmpty && !g.effects.pre.roundFirst && g.effects.masks.isEmpty
            if plain {
                out.append(.group(format: g.format, transform: t, opacity: opacity, cornerRadius: g.cornerRadius, children: kids))
            } else {
                out.append(.styledGroup(format: g.format, transform: t, opacity: opacity, cornerRadius: g.cornerRadius,
                                        children: kids, effects: g.effects, blendMode: groupBlend))
            }
            i = j
        }
        return mattes + out
    }

    /// Splits off the matte layers of level `depth` (not inside a transition side or pair of this level): one
    /// `.pictureMatte` per track that a drawn layer of this level reads, in first-seen order. Returns the remaining items.
    private static func pictureMattes(_ items: [(LayerRequest, RenderLayer)], depth: Int)
        -> ([RenderNode], [(LayerRequest, RenderLayer)]) {
        func isMatte(_ r: LayerRequest) -> Bool {
            r.matteFor != nil && r.matteDepth == depth && r.stackTransitions.first?.depth != depth && r.pair?.depth != depth
        }
        guard items.contains(where: { isMatte($0.0) }) else { return ([], items) }
        var rest: [(LayerRequest, RenderLayer)] = []
        var order: [Track.ID] = []
        var byTrack: [Track.ID: [(LayerRequest, RenderLayer)]] = [:]
        for item in items {
            guard isMatte(item.0), let t = item.0.matteFor else { rest.append(item); continue }
            var r = item.0
            r.matteFor = nil
            if byTrack[t] == nil { order.append(t) }
            byTrack[t, default: []].append((r, item.1))
        }
        let read = readTracks(rest, depth: depth)
        var nodes: [RenderNode] = []
        for t in order where read.contains(t) {
            let kids = build(byTrack[t] ?? [], depth: depth, forceNormal: false, under: [])
            if !kids.isEmpty { nodes.append(.pictureMatte(track: t, children: kids)) }
        }
        return (nodes, rest)
    }

    /// The tracks the Picture masks (clip masks and effect mask inputs) of level `depth` read: each drawn layer's own masks
    /// when it lives at that level, else those of its nested clip there.
    private static func readTracks(_ items: [(LayerRequest, RenderLayer)], depth: Int) -> Set<Track.ID> {
        var out = Set<Track.ID>()
        for (r, _) in items where r.matteFor == nil {
            let fx = r.groups.count > depth ? r.groups[depth].effects : r.effects
            for m in fx.masks where m.source == .picture { if let t = m.pictureTrack { out.insert(t) } }
            for s in fx.segments { for m in s.scope where m.source == .picture { if let t = m.pictureTrack { out.insert(t) } } }
        }
        return out
    }
}

/// What an Adjustment Layer does to the picture below it (`RenderNode.adjustment`).
public struct AdjustmentNode: Sendable {
    /// Motion (opacity 1: see `opacity`).
    public var transform: ClipTransform
    public var opacity: Double
    public var cornerRadius: Double
    public var effects: ClipEffects
    public var blendMode: BlendMode
    /// Lumetri: runs first, on the picture below (working-linear, handed to the chain as BT.709-encoded Rec.709).
    public var colorPipeline: ColorPipeline?
    /// Sub-frame Motion of the Transform effect's shutter (opacity 1 each); empty = sharp `transform`.
    public var motionSamples: [ClipTransform]
    /// Draw the unadjusted picture first. Off when the adjusted draw covers it exactly, and on a transition side (the side
    /// is only the adjusted picture; the unadjusted one is drawn under the transition anyway).
    public var drawsBase: Bool

    /// The adjusted draw covers the unadjusted one: full opacity, Normal, no Motion, crop, corner, mask or key, and only
    /// effects that keep the picture's coverage (Sharpen, Noise, the grade). A blur, shadow or moving filter softens the
    /// coverage at the frame edge, where the unadjusted picture shows through (as in Premiere).
    var coversBase: Bool {
        guard opacity >= 1, blendMode == .normal, transform == .identity, cornerRadius == 0, motionSamples.isEmpty,
              effects.masks.isEmpty else { return false }
        return effects.segments.allSatisfy { s in
            guard s.masks.isIdentity, s.keys.isEmpty, s.blurAfter == 0, s.shadow == nil else { return false }
            switch s.filter {
            case nil, .sharpen?, .unsharpMask?, .noise?: return true
            default: return false
            }
        }
    }
}

extension RenderNode {
    /// The node of an Adjustment Layer request over `below`; nil when it cannot change anything (nothing below, fully
    /// transparent, or no effect, no grade, no Motion and blend mode Normal), so the plain layers are drawn as they are.
    static func adjustment(_ req: LayerRequest, layer: RenderLayer, below: [RenderNode], transitionSide: Bool) -> RenderNode? {
        var t = req.transform
        let opacity = min(1, max(0, t.opacity))
        t.opacity = 1
        let blend = req.blendMode
        guard !below.isEmpty, opacity > 0, !req.effects.isEmpty else { return nil }
        var samples: [ClipTransform] = []
        if let mb = req.motionBlur, mb.transforms.count > 1 {
            samples = mb.transforms.map { var s = $0; s.opacity = 1; return s }
        }
        let color = layer.colorPipeline
        if req.effects.isIdentity, req.cornerRadius == 0, blend == .normal, t == .identity, samples.isEmpty, color == nil {
            return nil
        }
        var a = AdjustmentNode(transform: t, opacity: opacity, cornerRadius: req.cornerRadius, effects: req.effects,
                               blendMode: blend, colorPipeline: color, motionSamples: samples, drawsBase: false)
        a.drawsBase = !transitionSide && !a.coversBase
        return .adjustment(a, below: below)
    }
}

public enum CompositorError: Error, Sendable {
    case shaderCompilation(String)
    case missingFunction(String)
    case resourceAllocation
    case invalidTarget(String)
}

/// Which source frame pair a flow field belongs to: the cache key of `OpticalFlowEngine`. `variant` separates pictures
/// of the same frames that differ before the flow sees them (a stabilized frame, a reduced decode).
public struct FlowPairKey: Hashable, Sendable {
    public var media: UUID
    public var from: Time
    public var to: Time
    public var variant: Int

    public init(media: UUID, from: Time, to: Time, variant: Int = 0) {
        self.media = media; self.from = from; self.to = to; self.variant = variant
    }
}

/// Motion estimation effort. `.better` is what export and a settled playback frame use (the same pixels); `.faster`
/// (half the working size, fewer iterations) is only for frames while playing.
public enum FlowQuality: Sendable, Hashable {
    case faster, better

    /// Longest side of the image the motion is measured on (at most; see `OpticalFlowEngine.workingSize`).
    var workingLongSide: Int { self == .better ? 960 : 480 }
    /// Lucas-Kanade steps on the finest levels; the small coarse levels (cheap) get two more.
    var iterations: Int { self == .better ? 3 : 2 }
    var radius: Int32 { self == .better ? 3 : 2 }
}

/// Optical-flow interpolation of one layer: the frames' motion is measured and both frames are moved to the instant.
/// `key` nil = no caching (the field is measured for this render only).
public struct OpticalFlowRequest: Sendable, Hashable {
    public var key: FlowPairKey?
    public var quality: FlowQuality

    public init(key: FlowPairKey?, quality: FlowQuality = .better) { self.key = key; self.quality = quality }
}

/// Video Denoise / Deflicker input of a frame layer: the filter to run and the decoded neighbors of the layer's source
/// frame, nearest first on each side. Fewer neighbors than the filter asks for (clip edge, not decoded yet while playing)
/// is fine: the filter uses what it gets. Neighbors of another size or format family than the center are skipped.
public struct TemporalFrames: Sendable {
    public var filter: TemporalFilter
    public var before: [SQFrame]
    public var after: [SQFrame]
    public init(filter: TemporalFilter, before: [SQFrame] = [], after: [SQFrame] = []) {
        self.filter = filter; self.before = before; self.after = after
    }
}
