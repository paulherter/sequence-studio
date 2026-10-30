import CoreVideo
import Foundation
import Metal
import SQCore
import SQText
import SQTranscribe
import simd

/// Where the caption block sits on the canvas.
public struct CaptionPlacement: Sendable, Hashable {
    /// Distance from the canvas bottom to the bottom of the text block, as a fraction of the canvas height
    /// (default: bottom safe area, clear of platform UI on 9:16).
    public var bottomMargin: Double
    /// Wrap width as a fraction of the canvas width.
    public var maxWidthFraction: Double
    public init(bottomMargin: Double = 0.12, maxWidthFraction: Double = 0.86) {
        self.bottomMargin = bottomMargin; self.maxWidthFraction = maxWidthFraction
    }
    public static let bottomSafeArea = CaptionPlacement()
}

/// What to draw for one frame: which caption, and its animation state at that time.
public struct CaptionDrawState: Sendable, Equatable {
    public var index: Int
    public var opacity: Double
    public var scale: Double
    /// Block offset (sequence px, y down) and rotation (degrees, clockwise) of the caption's animation.
    public var offset: Vec2 = .zero
    public var rotation: Double = 0
    /// Per-character text-animator states while an animator is between rest states; nil when every character is at rest
    /// (or no canvas was given, so there is no layout).
    public var characterStates: [TextCharacterState]? = nil
    /// The karaoke word(s) lit at this time, from the same function the Program monitor uses.
    public var highlight: TextHighlight?
}

/// Burns captions into the working-linear frame (before the output encode). Text is rasterized once per caption
/// with SQText `TextRenderer` (sequence pixel size), uploaded as a premultiplied linear rgba16Float texture and
/// drawn as a quad. The caption's animation is the SQCore `AnimationSet` of its look (W7.3, the same stack the Program
/// monitor plays through `TextGenerator`): opacity, scale, offset and rotation of the block from `sample`, and text
/// animators as per-character states, rasterized per frame while they move.
public final class CaptionBurnIn: @unchecked Sendable {
    /// Every caption, layer after layer (each layer sorted by start). `CaptionDrawState.index` points in here.
    public let captions: [Caption]
    /// Index range of each layer in `captions`, bottom first: one layer per caption track, drawn in track order like the
    /// Program monitor (`Timeline.captions(at:)`), so overlapping caption tracks all burn in.
    let layerRanges: [Range<Int>]
    /// Per layer: no two captions overlap (always true for a caption track); only such a layer hands over.
    private let layerIsDisjoint: [Bool]
    let frameDuration: Time
    public let placement: CaptionPlacement
    /// FB-Y: where the captions sit (the project's kit position; the library's when built from one).
    public let position: CaptionPosition
    /// Pixel Shape of the frames drawn into (the export's). Captions are laid out and drawn in the display canvas, so a
    /// non-square target squeezes them with the picture and glyphs keep their shape once shown. Square: no extra work.
    public var pixelAspect: PixelAspect = .square
    let style: @Sendable (String) -> TextStyle
    private let animation: @Sendable (String) -> KeyframeTemplate?
    private let lock = NSLock()
    private struct Cached { var texture: MTLTexture; var originX: Double, originY: Double; var pivot: (x: Double, y: Double) }
    private struct TextureKey: Hashable { var index: Int; var highlight: TextHighlight?; var states: [TextCharacterState]? }
    private var textures: [TextureKey: Cached] = [:]
    private var pipeline: MTLRenderPipelineState?
    private var device: MTLDevice?
    private struct UnitsKey: Hashable { var index: Int; var canvasWidth: Int; var canvasHeight: Int }
    private let unitsLock = NSLock()
    private var unitsCache: [UnitsKey: TextUnits] = [:]
    /// How often a caption was laid out for its animator units (tests: once per caption and canvas).
    private(set) var layoutRuns = 0

    /// - Parameter layers: the captions of each caption track, bottom track first (one caption per layer shows at a time).
    /// - Parameter frameDuration: the sequence frame, for the hand-over across a gap of up to
    ///   `CaptionHandover.gapFrames` frames; `.zero`: only captions that touch exactly hand over.
    public init(layers: [[Caption]], placement: CaptionPlacement = .bottomSafeArea, position: CaptionPosition = .default,
                frameDuration: Time = .zero,
                style: @escaping @Sendable (String) -> TextStyle,
                animation: @escaping @Sendable (String) -> KeyframeTemplate?) {
        var all: [Caption] = [], ranges: [Range<Int>] = [], disjoint: [Bool] = []
        for l in layers where !l.isEmpty {
            let lo = all.count
            let sorted = l.sorted { $0.range.start < $1.range.start }
            all += sorted
            ranges.append(lo..<all.count)
            disjoint.append(zip(sorted, sorted.dropFirst()).allSatisfy { $0.range.end <= $1.range.start })
        }
        captions = all; layerRanges = ranges; layerIsDisjoint = disjoint
        self.frameDuration = frameDuration
        self.placement = placement; self.position = position; self.style = style; self.animation = animation
    }

    /// One layer of captions (a single caption track).
    public convenience init(captions: [Caption], placement: CaptionPlacement = .bottomSafeArea, position: CaptionPosition = .default,
                            frameDuration: Time = .zero,
                            style: @escaping @Sendable (String) -> TextStyle,
                            animation: @escaping @Sendable (String) -> KeyframeTemplate?) {
        self.init(layers: [captions], placement: placement, position: position, frameDuration: frameDuration, style: style,
                  animation: animation)
    }

    public convenience init(captions: [Caption], library: CaptionPresetLibrary,
                            placement: CaptionPlacement = .bottomSafeArea, frameDuration: Time = .zero) {
        self.init(layers: [captions], library: library, placement: placement, frameDuration: frameDuration)
    }

    public convenience init(layers: [[Caption]], library: CaptionPresetLibrary,
                            placement: CaptionPlacement = .bottomSafeArea, frameDuration: Time = .zero) {
        self.init(layers: layers, placement: placement, position: library.position, frameDuration: frameDuration,
                  style: { library.style(for: $0) }, animation: { library.animation(for: $0) })
    }

    /// What one layer shows at an instant: the caption, its hand-over clip duration, and the caption before it when
    /// that one hands over to it (`CaptionHandover`, the rule the Program monitor's `Timeline.captionSlots` uses).
    private struct Shown { var index: Int; var duration: Time; var held = false; var tail: Int?; var tailDuration = Time.zero }

    private func shown(at t: Time) -> [Shown] {
        layerRanges.enumerated().compactMap { n, r in
            guard layerIsDisjoint[n] else {
                // A list with overlapping captions (never a caption track): the first one containing `t`, no hand-over.
                return r.first { captions[$0].range.contains(t) }.map { Shown(index: $0, duration: captions[$0].range.duration) }
            }
            var lo = r.lowerBound, hi = r.upperBound
            while lo < hi {
                let mid = (lo + hi) / 2
                if captions[mid].range.start <= t { lo = mid + 1 } else { hi = mid }
            }
            let i = lo - 1
            guard i >= r.lowerBound,
                  let res = CaptionHandover.resolve(previous: i > r.lowerBound ? captions[i - 1].range : nil,
                                                    current: captions[i].range,
                                                    next: i + 1 < r.upperBound ? captions[i + 1].range : nil, at: t,
                                                    frameDuration: frameDuration) else { return nil }
            return Shown(index: i, duration: res.duration, held: res.held, tail: res.tailDuration != nil ? i - 1 : nil,
                         tailDuration: res.tailDuration ?? .zero)
        }
    }

    /// Indices of the captions showing at `t`, one per layer, bottom layer first (a caption also shows in the small gap
    /// before the one it hands over to).
    func activeIndices(at t: Time) -> [Int] { shown(at: t).map(\.index) }

    /// The caption showing at `t` with its animation state, or nil. No GPU. With a canvas size the caption is laid out
    /// (as `encode` draws it) so text animators get their per-character states; without one only the block animates.
    public func state(at t: Time, canvasWidth: Int? = nil, canvasHeight: Int? = nil) -> CaptionDrawState? {
        guard let s = shown(at: t).first else { return nil }
        return state(index: s.index, local: t - captions[s.index].range.start, duration: s.duration, held: s.held,
                     canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    /// Every caption drawn at `t` with its animation state, in draw order, as the Program monitor draws them: per caption
    /// track (bottom first) the caption showing, and under it the caption before while that one hands over
    /// (ENGINE-NOTES "Caption hand-over").
    public func states(at t: Time, canvasWidth: Int? = nil, canvasHeight: Int? = nil) -> [CaptionDrawState] {
        var out: [CaptionDrawState] = []
        for s in shown(at: t) {
            var local = t - captions[s.index].range.start
            let unshifted = local
            if let tail = s.tail, let entering = AnimationSet(single: animation(captions[s.index].animationRef)) {
                // The same request the Program monitor makes (`CaptionHandover.draw`).
                let d = CaptionHandover.draw(previous: AnimationSet(single: animation(captions[tail].animationRef)),
                                             entering: entering, naturalClipTime: local, frameDuration: frameDuration) {
                    guard let cw = canvasWidth, let ch = canvasHeight else { return nil }
                    return units(for: s.index, canvasWidth: cw, canvasHeight: ch)
                }
                local = d.clipTime
                if d.tailOpacity > 0 {
                    var ts = state(index: tail, local: s.tailDuration, duration: s.tailDuration, held: true,
                                   canvasWidth: canvasWidth, canvasHeight: canvasHeight)
                    ts.opacity *= d.tailOpacity
                    out.append(ts)
                }
            }
            out.append(state(index: s.index, local: local, highlightLocal: unshifted, duration: s.duration, held: s.held,
                             canvasWidth: canvasWidth, canvasHeight: canvasHeight))
        }
        return out
    }

    /// Caption `i` at clip time `local` of `duration`. `held`: past its own end (in the gap before its neighbor, or as
    /// the tail under it), where it keeps the highlight it ended with.
    /// `highlightLocal`: the clip time of the karaoke highlight when it differs from the animation's `local` (the
    /// hand-over shift moves the animation sample only; the lit word is the one at the real time, as in the monitor).
    private func state(index i: Int, local: Time, highlightLocal: Time? = nil, duration: Time, held: Bool, canvasWidth: Int?,
                       canvasHeight: Int?) -> CaptionDrawState {
        let c = captions[i]
        let set = AnimationSet(single: animation(c.animationRef))
        let a = set?.sample(clipTime: local, clipDuration: duration) ?? .rest
        var lit: TextHighlight?
        if let k = c.karaoke {
            let item = CaptionItem(lines: c.lines, range: c.range, words: c.words)
            lit = held ? CaptionKaraoke.heldHighlight(for: item, style: k)
                       : CaptionKaraoke.highlight(for: item, style: k, at: c.range.start + (highlightLocal ?? local))
        }
        var states: [TextCharacterState]?
        if let set, set.hasTextAnimator, let cw = canvasWidth, let ch = canvasHeight {
            states = set.characterStates(units: units(for: i, canvasWidth: cw, canvasHeight: ch), clipTime: local,
                                         clipDuration: duration)
            if states?.allSatisfy(\.isRest) == true { states = nil }
        }
        return CaptionDrawState(index: i, opacity: a.opacity, scale: max(0, a.scale), offset: a.offset, rotation: a.rotation,
                                characterStates: states, highlight: lit)
    }

    /// The animator units of caption `index` at this canvas, laid out (CoreText) once and kept while that caption shows
    /// (one entry per caption track: a caption's layout goes when its layer moves on or the canvas changes).
    private func units(for index: Int, canvasWidth: Int, canvasHeight: Int) -> TextUnits {
        let key = UnitsKey(index: index, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        unitsLock.lock(); defer { unitsLock.unlock() }
        if let u = unitsCache[key] { return u }
        let tpl = template(for: captions[index], canvasWidth: canvasWidth, canvasHeight: canvasHeight, highlight: nil)
        let layout = TextLayout.layout(text: tpl.text, style: tpl.style, maxWidth: tpl.box?.width, boxHeight: tpl.box?.height)
        let u = TextUnits.segment(layout)
        // The caption before stays too: during a hand-over both are asked on every frame.
        let layer = layerRanges.firstIndex { $0.contains(index) }
        unitsCache = unitsCache.filter { k, _ in
            layerRanges.firstIndex { $0.contains(k.index) } != layer || abs(k.index - index) <= 1
        }
        unitsCache[key] = u; layoutRuns += 1
        return u
    }

    /// Same template and box as the Program monitor (`CaptionLayout`).
    private func template(for c: Caption, canvasWidth: Int, canvasHeight: Int, highlight: TextHighlight?) -> TextTemplate {
        CaptionLayout.template(text: c.lines.joined(separator: "\n"), style: style(c.styleRef),
                               canvasWidth: Double(canvasWidth), canvasHeight: Double(canvasHeight),
                               widthFraction: placement.maxWidthFraction, highlight: highlight, position: c.position ?? position)
    }

    // MARK: GPU

    private func makePipeline(_ device: MTLDevice) throws -> MTLRenderPipelineState {
        if let pipeline, self.device === device { return pipeline }
        let lib = try device.makeLibrary(source: ExportShaderSource.msl, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "overlayVertex")
        d.fragmentFunction = lib.makeFunction(name: "overlayFragment")
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = .rgba16Float
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let p = try device.makeRenderPipelineState(descriptor: d)
        pipeline = p; self.device = device
        return p
    }

    private func texture(for index: Int, highlight: TextHighlight?, states: [TextCharacterState]?, canvasWidth: Int,
                         canvasHeight: Int, device: MTLDevice) throws -> Cached? {
        let key = TextureKey(index: index, highlight: highlight, states: states)
        if let t = textures[key] { return t }
        let template = template(for: captions[index], canvasWidth: canvasWidth, canvasHeight: canvasHeight, highlight: highlight)
        let raster = try states.map {
            try TextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                    boxHeight: template.box?.height, highlight: template.highlight, characterStates: $0)
        } ?? TextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                 boxHeight: template.box?.height, highlight: template.highlight)
        guard let raster else { return nil }
        let pb = raster.linearBuffer
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: raster.pixelWidth,
                                                         height: raster.pixelHeight, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { throw CompositorOverlayError.allocation }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        tex.replace(region: MTLRegionMake2D(0, 0, raster.pixelWidth, raster.pixelHeight), mipmapLevel: 0,
                    withBytes: CVPixelBufferGetBaseAddress(pb)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        // An in-between animator frame is drawn once: only the static rasters and the frame being drawn stay.
        textures = textures.filter { $0.key.index != index || $0.key.states == nil || $0.key.states == states }
        let cached = Cached(texture: tex, originX: raster.originX, originY: raster.originY, pivot: CaptionLayout.pivot(of: raster))
        textures[key] = cached
        return cached
    }

    /// Draws every caption active at `t` (one per caption track, bottom first, like the Program monitor) over `target`
    /// (rgba16Float, `.renderTarget`, working-linear). Returns whether something was drawn.
    @discardableResult
    public func encode(at t: Time, into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> Bool {
        let all = states(at: t, canvasWidth: layoutWidth(of: target), canvasHeight: target.height)
        lock.lock(); defer { lock.unlock() }
        // Export runs forward: drop the rasters of captions that have ended, never those on screen.
        let live = Set(all.map(\.index))
        textures = textures.filter { live.contains($0.key.index) || captions[$0.key.index].range.end > t }
        var drew = false
        for s in all where s.opacity > 0 && s.scale > 0 {
            if try encode(s, into: target, commandBuffer: commandBuffer) { drew = true }
        }
        return drew
    }

    /// Width of the display canvas the captions are laid out in: the target width for square pixels.
    private func layoutWidth(of target: MTLTexture) -> Int {
        pixelAspect.isSquare ? target.width : pixelAspect.displayWidth(ofStored: target.width)
    }

    /// Draws one caption (caller holds `lock`).
    private func encode(_ s: CaptionDrawState, into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> Bool {
        let device = target.device
        let pipe = try makePipeline(device)
        let w = Float(layoutWidth(of: target)), h = Float(target.height)
        // The plain caption, then the lit words as a second layer (the same two layers the Program monitor draws).
        // A karaoke caption with a pill draws the plain layer with one pill per word (`CaptionKaraoke.plainHighlight`).
        let c0 = captions[s.index]
        let plain = CaptionKaraoke.plainHighlight(style: style(c0.styleRef), karaoke: c0.karaoke,
                                                  wordCount: c0.lines.reduce(0) { $0 + WordSegmentation.wordCount($1) })
        for (pass, highlight) in [plain, s.highlight].enumerated() {
            if pass == 1, highlight == nil { break }
            guard let cached = try texture(for: s.index, highlight: highlight, states: s.characterStates, canvasWidth: Int(w),
                                           canvasHeight: target.height, device: device) else {
                if pass == 0 { return false } else { continue }
            }
            let tex = cached.texture
            let size = SIMD2(Float(tex.width), Float(tex.height))
            // Where the monitor puts the raster: inside the shared caption box (`CaptionLayout`) at the caption position;
            // scale and rotation about the center of the text (FB-Y), as the monitor's anchored layer does.
            let c = CaptionLayout.rasterCentre(canvasWidth: Double(w), canvasHeight: Double(h), originX: cached.originX,
                                               originY: cached.originY, width: Double(size.x), height: Double(size.y),
                                               widthFraction: placement.maxWidthFraction, position: c0.position ?? position,
                                               bottomMargin: placement.bottomMargin)
            let d = CaptionLayout.drawCentre(rasterCentre: c, pivot: cached.pivot, scale: s.scale, rotationDegrees: s.rotation,
                                             offset: s.offset)
            let center = SIMD2(Float(d.x), Float(d.y))
            var u = OverlayUniforms(canvas: SIMD2(w, h), center: center, size: size, scale: Float(s.scale),
                                    opacity: Float(s.opacity), rotation: Float(s.rotation * .pi / 180))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw CompositorOverlayError.allocation }
            enc.setRenderPipelineState(pipe)
            enc.setVertexBytes(&u, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
        return true
    }
}

enum CompositorOverlayError: Error { case allocation }

struct OverlayUniforms {
    var canvas: SIMD2<Float>
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var scale: Float
    var opacity: Float
    /// Radians, clockwise on screen (y down), about `center`.
    var rotation: Float = 0
}
