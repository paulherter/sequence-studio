import Foundation
#if canImport(simd)
import simd
#endif
import SQCore
import SQFrame
import SQGPU
import SQGPUKernels

/// The compositor on the portable GPU protocol (the Windows port plan, "Panel status: Engine"): the render-node tree of
/// the Metal `Compositor` drawn with the same Slang layer draws, uniform blocks (`Compositor.Uniforms`) and placement maths
/// (`Compositor.layerGeometry`), on any `GPUDevice` (D3D12 on Windows, Metal for the parity tests). Covered: pictures
/// (Y'CbCr planes, RGBA, linear premultiplied rasters incl. partial ones), solids and placeholders, transform, opacity,
/// tilt, corner radius, every blend mode (the destination is copied to input 6 before a blending draw, which D3D12 needs:
/// it has no framebuffer fetch), footage fill (stencil and inverted), nested groups, pairs, adjustment layers (picture
/// only) and fused transitions.
/// Clip grades and adjustment-layer grades run the shared color chain (`GPUColorChain`); clip effects run the Metal
/// compositor's effect chain (`GPUCompositor+Effects.swift`, passes shared through `EffectPasses`); frame blending mixes
/// two decoded frames (plain mix, or optical flow through the shared `OpticalFlowPasses`); temporal filters
/// (`TemporalPasses`), Picture mattes, mirrored transition edges and the long-blur pre-pass as in `Compositor`.
public final class GPUCompositor<D: GPUDevice>: @unchecked Sendable {
    /// A decoded source picture already on the GPU.
    public struct Picture {
        public enum Kind: Sendable {
            /// Y'CbCr: `planes.0` luma (read from r), `planes.1` interleaved Cb Cr (read from r g); unorm samples of
            /// `bitDepth` (10 bit MSB-aligned in 16) or float planes holding the same 0...1 values.
            case ycbcr(bitDepth: Int, fullRange: Bool)
            /// R'G'B'A, display-encoded BT.709. `alphaMode` as `Compositor.Uniforms.alphaMode` (0: premultiplied, 1: straight).
            case rgba(alphaMode: UInt32)
        }
        public var planes: (D.Texture, D.Texture?)
        public var kind: Kind
        public init(luma: D.Texture, chroma: D.Texture, bitDepth: Int, fullRange: Bool) {
            planes = (luma, chroma); kind = .ycbcr(bitDepth: bitDepth, fullRange: fullRange)
        }
        public init(rgba: D.Texture, alphaMode: UInt32) { planes = (rgba, nil); kind = .rgba(alphaMode: alphaMode) }
    }

    /// Turns a layer's frame into GPU planes (upload or wrap); nil draws the damaged placeholder.
    public typealias PictureSource = (SQFrame) -> Picture?

    public let device: D
    let layerOver: D.RenderPipeline, layerAdditive: D.RenderPipeline, layerBlend: D.RenderPipeline
    let transitionOver: D.RenderPipeline, transitionAdditive: D.RenderPipeline
    let dummy: D.Texture
    let dummyBuffer: D.Buffer, coverNeutral: D.Buffer
    /// Clip grades: the source conversion into an intermediate, then the color chain in place (`Compositor.prepareLayer`'s
    /// two-step path; the Metal fused first pass gives the same pixels).
    let chain: GPUColorChain<D>
    let convert: D.Pipeline
    let kernels: GPUKernels<D>
    /// Blur, Drop Shadow and the whole-picture filters (shared with the Metal compositor).
    let passes: EffectPasses<D>
    let lookPipeline: D.Pipeline, maskScopePipeline: D.Pipeline
    let coverPipeline: D.Pipeline, preBlurPipeline: D.Pipeline
    /// Deflicker, Video Denoise and Trails, compiled on first use.
    var temporalStore: TemporalPasses<D>?
    /// Optical flow (`FrameBlend.flow`): passes and field cache, built on first use (`flowPasses()`).
    var flowStore: GPUFlowStore<D>?
    /// C6: the Picture matte images of the current level, innermost last (`Compositor.Retainer.pictureScopes`).
    var pictureScopes: [[Track.ID: D.Texture]] = [[:]]
    /// Largest side of the long-blur pre-pass canvas (`Compositor.maxIntermediateSide`).
    var maxIntermediateSide = 16384
    private var free: [D.Texture] = []
    private var inFlight: [D.Texture] = []
    var freeBuffers: [D.Buffer] = []
    var inFlightBuffers: [D.Buffer] = []
    /// Subject / Magic matte uploads (cpuAccessible), free again at the next `render`.
    var freeMattes: [D.Texture] = []
    var matteTextures: [D.Texture] = []
    /// Uploaded mattes by storage (`matteTexture`), newest last.
    var matteCache: [(mattes: [SubjectMatte], texture: D.Texture)] = []
    /// Matte uploads so far (tests: a still matte uploads once).
    public internal(set) var matteUploads = 0
    /// Draws whose frame could not be turned into planes (tests).
    public private(set) var unsupportedFrameCount = 0
    /// As `Compositor.limitsColorWork`: a layer shown at half size or less runs its effect passes at half size.
    public var limitsColorWork = true
    /// Loads the LUTs of masked Color effects (`Compositor.colorResolver`); nil = masked grades without LUTs.
    public var colorResolver: LayerColorResolver?
    public var colorResolverBlocks = false

    public init(device: D) throws {
        self.device = device
        func draw(_ m: GPUShaderModule, _ fragment: String, _ blend: GPUBlend) throws -> D.RenderPipeline {
            try device.makeRenderPipeline(GPURenderKernel(m, vertex: "compositeVertex", fragment: fragment), format: .rgba16Float,
                                          blend: blend)
        }
        layerOver = try draw(GeneratedShaders.layer, "compositeFragment", .premultipliedOver)
        layerAdditive = try draw(GeneratedShaders.layer, "compositeFragment", .additive)
        layerBlend = try draw(GeneratedShaders.layer, "compositeFragmentBlend", .replace)
        transitionOver = try draw(GeneratedShaders.layerTransition, "compositeFragmentTransition", .premultipliedOver)
        transitionAdditive = try draw(GeneratedShaders.layerTransition, "compositeFragmentTransition", .additive)
        guard let t = device.makeTexture(GPUTextureDescriptor(width: 1, height: 1, format: .rgba16Float)),
              let b = device.makeBuffer(length: 16), let c = device.makeBuffer(length: 16) else {
            throw CompositorError.resourceAllocation
        }
        dummy = t; dummyBuffer = b; coverNeutral = c
        chain = try GPUColorChain(device: device)
        convert = try device.makePipeline(GPUKernel(GeneratedShaders.sourceConvert, "convertToRGB"))
        kernels = try GPUKernels(device: device)
        passes = try EffectPasses(device: device, kernels: kernels)
        lookPipeline = try device.makePipeline(GPUKernel(GeneratedShaders.filmLook, "filmLook"))
        maskScopePipeline = try device.makePipeline(GPUKernel(GeneratedShaders.maskScope, "maskScopeMix"))
        coverPipeline = try device.makePipeline(GPUKernel(GeneratedShaders.transitionCover, "transitionCoverMin"))
        preBlurPipeline = try device.makePipeline(GPUKernel(GeneratedShaders.transitionPreBlur, "transitionPreBlur"))
        let ones: [Float] = [1, 1, 0, 0]
        ones.withUnsafeBytes { device.upload($0, to: c) }
        let zero = [UInt8](repeating: 0, count: 8)
        zero.withUnsafeBytes { device.upload($0, bytesPerRow: 8, to: t) }
    }

    /// One draw on the target (the Metal compositor's `Prepared`, without the effect inputs).
    struct Draw {
        var u: Compositor.Uniforms
        var tex0: D.Texture
        var tex1: D.Texture
        var blend: BlendMode = .normal
        var stencil = false
        var mix: Compositor.TransitionUniforms? = nil
        /// Converts a corner radius in clip px (fitted into the canvas) to layer px, as `prepareLayer` did.
        var radiusFactor: Double = 1
        /// Clip mask entries (`Compositor.maskEntries`) and the matte texture they read; nil = none.
        var maskData: D.Buffer? = nil
        var matte: D.Texture? = nil
        /// Picture mask images (inputs 4 / 5).
        var picture0: D.Texture? = nil, picture1: D.Texture? = nil
        /// A transition's measured side coverage (mirrored edges); nil = both sides cover.
        var cover: D.Buffer? = nil
    }

    /// Renders the tree bottom -> top into `target` (rgba16Float, sequence size), over opaque black or transparent. The
    /// caller commits `commandBuffer`.
    /// shortcut: intermediates go back to the pool at the next `render`, so the caller must have finished the previous
    /// command buffer by then (true for `commitAndWait`); track completion per buffer once frames are in flight.
    public func render(nodes: [RenderNode], format: SequenceFormat, into target: D.Texture, commandBuffer cb: D.CommandBuffer,
                       transparent: Bool = false, pictures: PictureSource) throws {
        guard target.width == format.width, target.height == format.height else {
            throw CompositorError.invalidTarget("size \(target.width)x\(target.height) != sequence \(format.width)x\(format.height)")
        }
        free += inFlight; inFlight.removeAll()
        freeBuffers += inFlightBuffers; inFlightBuffers.removeAll()
        freeMattes += matteTextures; matteTextures.removeAll()
        flowStore?.beginRender()
        pictureScopes = [[:]]
        try encode(nodes, format: format, into: target, cb, clear: SIMD4(0, 0, 0, transparent ? 0 : 1), pictures: pictures)
    }

    func acquire(_ w: Int, _ h: Int) throws -> D.Texture {
        let t: D.Texture
        if let i = free.firstIndex(where: { $0.width == w && $0.height == h }) {
            t = free.remove(at: i)
        } else {
            guard let made = device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba16Float)) else {
                throw CompositorError.resourceAllocation
            }
            t = made
        }
        inFlight.append(t)
        return t
    }

    func encode(_ nodes: [RenderNode], format: SequenceFormat, into target: D.Texture, _ cb: D.CommandBuffer,
                        clear: SIMD4<Float>, additiveOnto: Bool = false, pictures: PictureSource) throws {
        var draws: [Draw] = []
        let scoped = try encodePictureMattes(nodes, format: format, cb, pictures: pictures)
        defer { if scoped { pictureScopes.removeLast() } }
        for node in nodes { try queue(node, format: format, cb, into: &draws, pictures: pictures) }
        try drawAll(draws, into: target, cb, clear: additiveOnto ? nil : clear, additive: additiveOnto)
    }

    func plain(_ tex: D.Texture, canvas: SequenceFormat, size: SIMD2<Float>) -> Draw {
        var u = Compositor.Uniforms()
        u.mode = 3
        Compositor.layerGeometry(&u, transform: .identity, canvas: canvas, size: size)
        return Draw(u: u, tex0: tex, tex1: dummy)
    }

    private func queue(_ node: RenderNode, format: SequenceFormat, _ cb: D.CommandBuffer, into draws: inout [Draw],
                       pictures: PictureSource) throws {
        let transparent = SIMD4<Float>(0, 0, 0, 0)
        switch node {
        case .layer(let layer) where layer.stencil:
            var inner = layer
            let opacity = min(1, max(0, inner.transform.opacity))
            inner.transform.opacity = 1; inner.footageFill = nil; inner.blendMode = .normal
            try queue(.stencil(opacity: opacity, children: [.layer(inner)]), format: format, cb, into: &draws, pictures: pictures)
        case .layer(let layer):
            if let d = try prepareLayer(layer, format: format, cb, pictures: pictures) {
                try finishLayer(d, layer: layer, format: format, cb, into: &draws)
            }
        case .group(let gf, let transform, let opacity, let radius, let children):
            try group(gf, transform, opacity, radius, children, effects: .none, blend: .normal, format: format, cb,
                      pictures: pictures, into: &draws)
        case .styledGroup(let gf, let transform, let opacity, let radius, let children, let fx, let blend):
            try group(gf, transform, opacity, radius, children, effects: fx, blend: blend, format: format, cb,
                      pictures: pictures, into: &draws)
        case .pair(let pf, let first, let second):
            let tex = try acquire(pf.width, pf.height)
            try encode(first, format: pf, into: tex, cb, clear: transparent, pictures: pictures)
            try encode(second, format: pf, into: tex, cb, clear: transparent, additiveOnto: true, pictures: pictures)
            draws.append(plain(tex, canvas: format.storedPixels, size: SIMD2(Float(pf.width), Float(pf.height))))
        case .transition(let pf, let render, let first, let second):
            let a = try acquire(pf.width, pf.height), b = try acquire(pf.width, pf.height)
            try encode(first, format: pf, into: a, cb, clear: transparent, pictures: pictures)
            try encode(second, format: pf, into: b, cb, clear: transparent, pictures: pictures)
            let (sides, tu, cover) = try transitionSides(render, a, b, pf, cb)
            var d = plain(sides.0, canvas: format.storedPixels, size: SIMD2(Float(pf.width), Float(pf.height)))
            d.tex1 = sides.1
            d.mix = tu
            d.cover = cover
            if pf.width != format.width || pf.height != format.height {
                // The fused draw reads the sides at target pixels: another canvas size gets its mix drawn first.
                let mixed = try acquire(pf.width, pf.height)
                var m = plain(sides.0, canvas: pf.storedPixels, size: SIMD2(Float(pf.width), Float(pf.height)))
                m.tex1 = sides.1; m.mix = d.mix; m.cover = cover
                try drawAll([m], into: mixed, cb, clear: transparent, additive: false)
                d = plain(mixed, canvas: format.storedPixels, size: SIMD2(Float(pf.width), Float(pf.height)))
            }
            draws.append(d)
        case .adjustment(let a, let below):
            let tex = try acquire(format.width, format.height)
            try encode(below, format: format, into: tex, cb, clear: transparent, pictures: pictures)
            let size = SIMD2(Float(format.displayWidth), Float(format.height))
            let base = plain(tex, canvas: format, size: size)
            if a.drawsBase { draws.append(base) }
            var src = base
            if let pipeline = a.colorPipeline {
                // `Compositor.gradeAdjustmentInput`: the composite BT.709-encoded, graded in place, drawn straight.
                let mid = try acquire(format.width, format.height)
                kernels.encode709(cb, tex, into: mid)
                try chain.encode(pipeline, texture: mid, commandBuffer: cb)
                src.tex0 = mid; src.u.mode = 1; src.u.linearize = 0; src.u.alphaMode = 1
            }
            try adjustment(a, src: src, size: size, format: format, cb, into: &draws)
        case .stencil(let opacity, let children):
            let tex = try acquire(format.width, format.height)
            try encode(children, format: format, into: tex, cb, clear: transparent, pictures: pictures)
            var d = plain(tex, canvas: format.storedPixels, size: SIMD2(Float(format.width), Float(format.height)))
            d.u.opacity = Float(opacity)
            d.stencil = true
            draws.append(d)
        case .pictureMatte, .pictureScope:
            break
        case .blended(let inner, let mode):
            let n = draws.count
            try queue(inner, format: format, cb, into: &draws, pictures: pictures)
            if draws.count > n {
                let last = draws.count - 1
                if mode != .normal, let mix = draws[last].mix {
                    // The blending draw reads one texture: the transition's mix is drawn first.
                    let mixed = try acquire(format.width, format.height)
                    var m = draws[last]; m.mix = mix
                    try drawAll([m], into: mixed, cb, clear: transparent, additive: false)
                    draws[last] = plain(mixed, canvas: format.storedPixels, size: SIMD2(Float(format.width), Float(format.height)))
                }
                draws[last].blend = mode
            }
        }
    }

    /// A nested sequence's children composited offscreen, queued as one layer with the nested clip's effects
    /// (`Compositor.encodeGroup`).
    private func group(_ gf: SequenceFormat, _ transform: ClipTransform, _ opacity: Double, _ radius: Double,
                       _ children: [RenderNode], effects: ClipEffects, blend: BlendMode, format: SequenceFormat,
                       _ cb: D.CommandBuffer, pictures: PictureSource, into draws: inout [Draw]) throws {
        let tex = try acquire(gf.width, gf.height)
        // A nested level: its Picture masks read only its own mattes.
        pictureScopes.append([:])
        do {
            defer { pictureScopes.removeLast() }
            try encode(children, format: gf, into: tex, cb, clear: SIMD4(0, 0, 0, 0), pictures: pictures)
        }
        var u = Compositor.Uniforms()
        u.mode = 3
        let factor = Compositor.radiusFactor(gf.displayWidth, gf.height, canvas: format)
        Compositor.layerGeometry(&u, transform: transform, canvas: format, size: SIMD2(Float(gf.displayWidth), Float(gf.height)),
                                 cornerRadius: radius * factor)
        u.opacity = Float(min(1, max(0, transform.opacity * opacity)))
        var d = Draw(u: u, tex0: tex, tex1: dummy)
        d.radiusFactor = factor
        let styled = RenderLayer(content: .placeholder(.loading), cornerRadius: radius, effects: effects, blendMode: blend)
        try finishLayer(d, layer: styled, format: format, cb, into: &draws)
    }

    /// The draw of one leaf layer, as `Compositor.prepareLayer`.
    private func prepareLayer(_ layer: RenderLayer, format: SequenceFormat, _ cb: D.CommandBuffer,
                              pictures: PictureSource) throws -> Draw? {
        var u = Compositor.Uniforms()
        let canvasSize = SIMD2(Float(format.displayWidth), Float(format.height))
        func fill(_ color: SIMD4<Float>) -> Draw {
            u.mode = 2; u.solid = color
            Compositor.layerGeometry(&u, transform: layer.transform, canvas: format, size: canvasSize, cornerRadius: layer.cornerRadius)
            return Draw(u: u, tex0: dummy, tex1: dummy)
        }
        switch layer.content {
        case .placeholder(let kind):
            return kind == .loading ? nil : fill(Compositor.placeholderLinear(kind))
        case .solid(let r, let g, let b):
            // A graded solid (Color Matte with a grade) runs the picture path on a tiny flat frame stretched to the canvas,
            // as `Compositor.prepareLayer` does, so it grades with the same code as footage.
            if layer.colorPipeline != nil, let t = solidTexture(r, g, b) {
                var framed = layer
                framed.nativeSize = (format.displayWidth, format.height)
                framed.temporal = nil; framed.blend = nil
                return try frameDraw(Picture(rgba: t, alphaMode: 0), hint: Self.solidHint, layer: framed, format: format, cb,
                                     pictures: pictures)
            }
            return fill(SIMD4(Compositor.lin(r), Compositor.lin(g), Compositor.lin(b), 1))
        case .linearPremultiplied(let raster, let w, let h):
            guard let pic = pictures(raster), case .rgba = pic.kind else {
                unsupportedFrameCount += 1
                return fill(Compositor.placeholderLinear(.damaged))
            }
            let t0 = pic.planes.0
            u.mode = 3
            if let cp = layer.contentPart {
                guard cp.holds(width: t0.width, height: t0.height) else {
                    unsupportedFrameCount += 1
                    return fill(Compositor.placeholderLinear(.damaged))
                }
                u.part = SIMD4(Float(cp.x), Float(cp.y), Float(cp.wholeWidth), Float(cp.wholeHeight))
            }
            Compositor.layerGeometry(&u, transform: layer.transform, canvas: format, size: SIMD2(Float(w), Float(h)),
                                     cornerRadius: layer.cornerRadius)
            return Draw(u: u, tex0: t0, tex1: dummy)
        case .frame(let source, let hint):
            guard let pic = pictures(source) else {
                unsupportedFrameCount += 1
                return fill(Compositor.placeholderLinear(.damaged))
            }
            return try frameDraw(pic, hint: hint, layer: layer, format: format, cb, pictures: pictures)
        }
    }

    static var solidHint: VideoTrackInfo {
        VideoTrackInfo(width: 2, height: 2, codec: "rgba", bitDepth: 8, chroma: "4:4:4", nominalFrameDuration: Time(1, 25),
                       isVariableFrameRate: false)
    }

    /// 2 x 2 RGBA8 textures of one display-encoded color, kept for the last few colors (never rewritten, so a frame in
    /// flight never sees a change).
    private var solidTextures: [SIMD3<UInt8>: D.Texture] = [:]
    private func solidTexture(_ r: Float, _ g: Float, _ b: Float) -> D.Texture? {
        func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        let key = SIMD3(byte(r), byte(g), byte(b))
        if let t = solidTextures[key] { return t }
        guard let t = device.makeTexture(GPUTextureDescriptor(width: 2, height: 2, format: .rgba8Unorm)) else { return nil }
        let px = [UInt8](repeating: 0, count: 16).enumerated().map { i, _ in i % 4 == 3 ? 255 : key[i % 4] }
        px.withUnsafeBytes { device.upload($0, bytesPerRow: 8, to: t) }
        if solidTextures.count >= 8 { solidTextures.removeAll() }
        solidTextures[key] = t
        return t
    }

    /// The draw of a decoded picture (`.frame` content, also a graded solid's flat frame).
    private func frameDraw(_ pic: Picture, hint: VideoTrackInfo, layer: RenderLayer, format: SequenceFormat, _ cb: D.CommandBuffer,
                           pictures: PictureSource) throws -> Draw? {
        var u = Compositor.Uniforms()
        let w = pic.planes.0.width, h = pic.planes.0.height
        let quarter = UInt32((hint.rotation / 90) & 3)
        let (nw, nh) = layer.nativeSize ?? (w, h)
        let (dw, dh) = quarter & 1 == 1 ? (nh, nw) : (nw, nh)
        switch pic.kind {
        case .ycbcr(let bits, let full):
            guard pic.planes.1 != nil else {
                unsupportedFrameCount += 1
                u.mode = 2; u.solid = Compositor.placeholderLinear(.damaged)
                Compositor.layerGeometry(&u, transform: layer.transform, canvas: format,
                                         size: SIMD2(Float(format.displayWidth), Float(format.height)), cornerRadius: layer.cornerRadius)
                return Draw(u: u, tex0: dummy, tex1: dummy)
            }
            u.mode = 0
            u.range = PixelFormats.rangeParams(bitDepth: bits, fullRange: full)
        case .rgba(let alphaMode):
            u.mode = 1
            u.alphaMode = alphaMode
            u.range = PixelFormats.rangeParams(bitDepth: 8, fullRange: true)
        }
        u.m = PixelFormats.ycbcrToRGB(PixelFormats.matrix(tag: hint.matrix))
        u.quarter = quarter
        Compositor.layerGeometry(&u, transform: layer.transform, canvas: format, size: SIMD2(Float(dw), Float(dh)),
                                 cornerRadius: layer.cornerRadius * Compositor.radiusFactor(dw, dh, canvas: format))
        let factor = Compositor.radiusFactor(dw, dh, canvas: format)
        if let tf = layer.temporal, !tf.filter.isIdentity,
           let mid = temporalIntermediate(pic, frames: tf, u: u, pipeline: layer.colorPipeline, cb, pictures: pictures) {
            // Deflicker, Video Denoise, Trails (`Compositor.temporalIntermediate`): already working-linear.
            u.mode = 1; u.linearize = 0
            u.alphaMode = u.alphaMode == 0 ? 0 : 1      // Compositor.intermediateAlphaMode
            return Draw(u: u, tex0: mid, tex1: dummy, radiusFactor: factor)
        }
        if let b = layer.blend, b.weight > 0, let next = pictures(b.next),
           let mid = try blendIntermediate(pic, next, weight: b.weight, flow: b.flow, u: u, pipeline: layer.colorPipeline, cb) {
            // Frame blending (`Compositor.blendIntermediate`): both frames converted (and graded), mixed light-linear.
            u.mode = 1; u.linearize = 0
            u.alphaMode = u.alphaMode == 0 ? 0 : 1      // Compositor.intermediateAlphaMode
            return Draw(u: u, tex0: mid, tex1: dummy, radiusFactor: factor)
        }
        if let pipeline = layer.colorPipeline {
            // The grade: conversion to source-encoded R'G'B' at the texture size, the chain in place, then drawn as
            // working-linear straight (premultiplied sources stay premultiplied).
            let mid = try acquire(w, h)
            guard let enc = cb.makeComputeEncoder() else { throw CompositorError.resourceAllocation }
            enc.setPipeline(convert)
            enc.setInput(pic.planes.0, at: 0)
            enc.setInput(pic.planes.1 ?? dummy, at: 1)
            withUnsafeBytes(of: &u) { enc.setConstantBytes($0, slot: 0) }
            var cv = Compositor.ConvertUniforms(origin: .zero, transfer: ColorPipelineGPU.shaderIndex(pipeline.source))
            withUnsafeBytes(of: &cv) { enc.setConstantBytes($0, slot: 1) }
            enc.setOutput(mid)
            enc.dispatch(width: w, height: h)
            enc.end()
            try chain.encode(pipeline, texture: mid, commandBuffer: cb, quarterTurned: quarter & 1 == 1)
            u.mode = 1; u.linearize = 0
            u.alphaMode = u.alphaMode == 0 ? 0 : 1      // Compositor.intermediateAlphaMode
            return Draw(u: u, tex0: mid, tex1: dummy, radiusFactor: factor)
        }
        return Draw(u: u, tex0: pic.planes.0, tex1: pic.planes.1 ?? dummy, radiusFactor: factor)
    }

    /// The Metal `drawPrepared` on the protocol. A blending draw (blend mode or stencil) ends the pass, copies the target to
    /// input 6 and draws on a new pass that keeps the target.
    func drawAll(_ draws: [Draw], into target: D.Texture, _ cb: D.CommandBuffer, clear: SIMD4<Float>?,
                         additive: Bool) throws {
        guard var enc = cb.makeRenderEncoder(target: target, clear: clear) else { throw CompositorError.resourceAllocation }
        var destination: D.Texture?
        for var d in draws {
            let wantsBlend = (d.blend != .normal || d.stencil) && d.mix == nil
            if wantsBlend {
                enc.end()
                let copy = try destination ?? acquire(target.width, target.height)
                destination = copy
                cb.copy(target, to: copy)
                guard let next = cb.makeRenderEncoder(target: target, clear: nil) else { throw CompositorError.resourceAllocation }
                enc = next
                enc.setPipeline(layerBlend)
                enc.setInput(copy, at: 6)
                d.u.blend = d.stencil ? BlendModes.stencilShaderID : BlendModes.shaderID(d.blend)
            } else if d.mix != nil {
                enc.setPipeline(additive ? transitionAdditive : transitionOver)
                d.u.blend = 0
            } else {
                enc.setPipeline(additive ? layerAdditive : layerOver)
                d.u.blend = 0
            }
            withUnsafeBytes(of: &d.u) { enc.setConstantBytes($0, slot: 0) }
            enc.setInput(d.tex0, at: 0)
            enc.setInput(d.tex1, at: 1)
            enc.setInput(d.matte ?? dummy, at: 3)
            enc.setInput(d.picture0 ?? dummy, at: 4)
            enc.setInput(d.picture1 ?? dummy, at: 5)
            if var tu = d.mix {
                withUnsafeBytes(of: &tu) { enc.setConstantBytes($0, slot: 1) }
                enc.setBuffer(d.cover ?? coverNeutral, at: 2)
            } else {
                enc.setBuffer(d.maskData ?? dummyBuffer, at: 2)
            }
            enc.draw(.triangleStrip, vertexCount: 4)
        }
        enc.end()
    }
}
