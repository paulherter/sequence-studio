import CoreVideo
import Foundation
import Metal
import SQCore
import simd

public enum PlaceholderKind: Sendable { case offline, damaged, loading }

/// One layer of one display frame, built by the caller from `LayerRequest` + frame cache.
/// `transform` is the already evaluated `LayerRequest.transform`: position = offset from the canvas centre in
/// sequence px (y down), scale linear x/y, rotation in degrees (positive = clockwise on screen), anchor = offset from
/// the layer's centre in sequence px, opacity 0...1. The layer is drawn at its own (upright) pixel size, one source pixel
/// per sequence pixel at scale 1 (Premiere: 100 % = source pixels; "Set to Frame Size" writes the fit value into the
/// scale), scaled/rotated about the anchor; the anchor lands on `canvas centre + position`.
public struct RenderLayer: @unchecked Sendable {
    public enum Content: @unchecked Sendable {
        case frame(CVPixelBuffer, colorHint: VideoTrackInfo)
        case placeholder(PlaceholderKind)
        /// Linear-light premultiplied `kCVPixelFormatType_64RGBAHalf` raster (text), drawn at exactly `width` x `height`
        /// sequence px (no aspect fit); `transform` positions its centre like any other layer.
        case linearPremultiplied(CVPixelBuffer, width: Double, height: Double)
    }
    public var content: Content
    public var transform: ClipTransform
    /// Per-layer colour stage slot. nil = Rec.709 source: the compositor applies only the inverse BT.709 OETF
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

    public init(content: Content, transform: ClipTransform = .identity, colorPipeline: ColorPipeline? = nil,
                cornerRadius: Double = 0, nativeSize: (width: Int, height: Int)? = nil,
                effects: ClipEffects = .none, blendMode: BlendMode = .normal) {
        self.content = content; self.transform = transform; self.colorPipeline = colorPipeline
        self.cornerRadius = cornerRadius; self.nativeSize = nativeSize
        self.effects = effects; self.blendMode = blendMode
    }

    /// The same layer with the effects and blend mode of the request it was built from.
    public func applying(_ request: LayerRequest) -> RenderLayer {
        var l = self
        l.effects = request.effects
        l.blendMode = request.blendMode
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

    /// Builds the tree from flat `LayerRequest`s (bottom -> top) and their prepared layers (`layers[i]` belongs to
    /// `requests[i]`). Consecutive layers sharing the same `groups` prefix (same nested clip) form one group,
    /// recursively. The group node's `opacity` is the nested clip's `transform.opacity`; its `transform.opacity` is 1.
    public static func tree(requests: [LayerRequest], layers: [RenderLayer]) -> [RenderNode] {
        precondition(requests.count == layers.count, "requests and layers must match")
        return build(Array(zip(requests, layers)), depth: 0)
    }

    private static func build(_ items: [(LayerRequest, RenderLayer)], depth: Int) -> [RenderNode] {
        var out: [RenderNode] = []
        var i = 0
        while i < items.count {
            let (req, layer) = items[i]
            guard req.groups.count > depth else { out.append(.layer(layer)); i += 1; continue }
            let g = req.groups[depth]
            var j = i + 1
            while j < items.count, items[j].0.groups.count > depth, items[j].0.groups[depth].clip == g.clip { j += 1 }
            var t = g.transform
            let opacity = t.opacity
            t.opacity = 1
            out.append(.group(format: g.format, transform: t, opacity: opacity, cornerRadius: g.cornerRadius,
                              children: build(Array(items[i..<j]), depth: depth + 1)))
            i = j
        }
        return out
    }
}

public enum CompositorError: Error, Sendable {
    case shaderCompilation(String)
    case missingFunction(String)
    case resourceAllocation
    case invalidTarget(String)
}

/// Offscreen compositor: layers bottom -> top into an rgba16Float working-linear (Rec.709 primaries) target.
/// Used from the render thread only. Shaders are compiled at runtime (see `CompositorShaderSource`).
public final class Compositor: @unchecked Sendable {
    public let device: MTLDevice
    private let convertPipeline: MTLComputePipelineState
    let renderPipeline: MTLRenderPipelineState
    /// Same fragment with programmable blending (reads the destination); nil on GPUs without framebuffer fetch.
    let blendPipeline: MTLRenderPipelineState?
    let blurPipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let colorGPU: ColorPipelineGPU
    let dummy: MTLTexture
    private let queueLock = NSLock()
    private var freeIntermediates: [MTLTexture] = []
    /// Frames that could not be sampled (unknown / unsupported compressed format) and were drawn as `.damaged`.
    /// The caller should then request an uncompressed format (`PixelFormats.uncompressedEquivalent`).
    public private(set) var unsupportedFrameCount = 0
    /// Intermediate textures ever allocated (the pool reuses same-sized ones): a steady animation must not keep growing this.
    public private(set) var intermediateAllocations = 0

    struct Uniforms {
        var m = matrix_identity_float3x3
        var solid = SIMD4<Float>(0, 0, 0, 1)
        var range = SIMD4<Float>(1, 0, 1, 0)
        var canvas = SIMD2<Float>(1, 1)
        var size = SIMD2<Float>(1, 1)
        var position = SIMD2<Float>(0, 0)
        var anchor = SIMD2<Float>(0, 0)
        var scale = SIMD2<Float>(1, 1)
        var rotCos: Float = 1, rotSin: Float = 0, opacity: Float = 1
        var mode: UInt32 = 0
        var linearize: UInt32 = 1
        var cornerRadius: Float = 0
        /// Clockwise quarter turns of a source picture (0...3): the layer quad is upright, the texture lookup turns.
        var quarter: UInt32 = 0
        /// Blend mode id for the blending pipeline (0 = normal; see `BlendModes.shaderID`).
        var blend: UInt32 = 0
        /// Size of the rectangle Crop and Rounded Corners work on (the layer's own picture); zero = `size`.
        var maskSize = SIMD2<Float>(0, 0)
        /// Crop insets as fractions of `maskSize`: left, top, right, bottom.
        var crop = SIMD4<Float>(0, 0, 0, 0)
        /// Ultra Keys: hue, half width, soft edge, spill (degrees / fractions); `keyCount` of them are used.
        var key0 = SIMD4<Float>(0, 0, 0, 0)
        var key1 = SIMD4<Float>(0, 0, 0, 0)
        var keyCount: UInt32 = 0
        /// 1 = Rounded Corners came before Crop: round the whole frame, then cut straight crop edges into it.
        var roundFirst: UInt32 = 0
    }

    public init(device: MTLDevice) throws {
        self.device = device
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.languageVersion = .version3_1
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: CompositorShaderSource.msl, options: options) }
        catch { throw CompositorError.shaderCompilation("\(error)") }
        func fn(_ n: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: n) else { throw CompositorError.missingFunction(n) }
            return f
        }
        convertPipeline = try device.makeComputePipelineState(function: fn("convertToRGB"))
        let rp = MTLRenderPipelineDescriptor()
        rp.vertexFunction = try fn("compositeVertex")
        rp.fragmentFunction = try fn("compositeFragment")
        let ca = rp.colorAttachments[0]!
        ca.pixelFormat = .rgba16Float
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        renderPipeline = try device.makeRenderPipelineState(descriptor: rp)
        blurPipeline = try device.makeComputePipelineState(function: fn("gaussianBlur1D"))
        if device.supportsFamily(.apple1), let bf = library.makeFunction(name: "compositeFragmentBlend") {
            let bp = MTLRenderPipelineDescriptor()
            bp.vertexFunction = try fn("compositeVertex")
            bp.fragmentFunction = bf
            bp.colorAttachments[0].pixelFormat = .rgba16Float
            bp.colorAttachments[0].isBlendingEnabled = false
            blendPipeline = try? device.makeRenderPipelineState(descriptor: bp)
        } else {
            blendPipeline = nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw CompositorError.resourceAllocation
        }
        textureCache = cache
        colorGPU = try ColorPipelineGPU(device: device)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let dt = device.makeTexture(descriptor: d) else { throw CompositorError.resourceAllocation }
        dummy = dt
    }

    // MARK: Helpers

    /// Keeps CVMetalTextures (and pooled intermediates) alive until the GPU finished.
    final class Retainer: @unchecked Sendable {
        var textures: [CVMetalTexture] = []
        var pooled: [MTLTexture] = []
    }

    struct Prepared {
        var u: Uniforms
        var tex0: MTLTexture
        var tex1: MTLTexture
        /// Blend mode of this draw (single-layer composite; two-layer transition blending is a separate path).
        var blend: BlendMode = .normal
        /// Converts a corner radius in clip px (fitted into the canvas) to layer px, as `prepareLayer` did.
        var radiusFactor: Double = 1
    }

    private func planeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, retainer: Retainer) -> MTLTexture? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var out: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, plane, &out)
        guard r == kCVReturnSuccess, let out, let tex = CVMetalTextureGetTexture(out) else { return nil }
        retainer.textures.append(out)
        return tex
    }

    func acquireIntermediate(width: Int, height: Int) -> MTLTexture? {
        queueLock.lock()
        if let i = freeIntermediates.firstIndex(where: { $0.width == width && $0.height == height }) {
            let t = freeIntermediates.remove(at: i)
            queueLock.unlock()
            return t
        }
        queueLock.unlock()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        queueLock.lock(); intermediateAllocations += 1; queueLock.unlock()
        return device.makeTexture(descriptor: d)
    }

    private func release(_ textures: [MTLTexture]) {
        queueLock.lock()
        freeIntermediates.append(contentsOf: textures)
        if freeIntermediates.count > 6 { freeIntermediates.removeFirst(freeIntermediates.count - 6) }
        queueLock.unlock()
    }

    /// Placeholder display colours (sRGB-ish, then linearised): offline = dark red, damaged = amber, loading = grey.
    static func placeholderLinear(_ k: PlaceholderKind) -> SIMD4<Float> {
        let d: SIMD3<Float>
        switch k {
        case .offline: d = SIMD3(0.45, 0.10, 0.10)
        case .damaged: d = SIMD3(0.45, 0.33, 0.05)
        case .loading: d = SIMD3(0.20, 0.20, 0.20)
        }
        func lin(_ e: Float) -> Float { e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45) }
        return SIMD4(lin(d.x), lin(d.y), lin(d.z), 1)
    }

    /// Corner radii are given in px of the layer fitted into the canvas (what they meant before Scale became relative to
    /// source pixels); the layer is now drawn at its own size, so the radius is converted: native / fitted.
    static func radiusFactor(_ w: Int, _ h: Int, canvas: SequenceFormat) -> Double {
        let fit = fitSize(w, h, canvas: canvas.width, canvas.height)
        return fit.x > 0 ? Double(Float(w) / fit.x) : 1
    }

    /// Aspect-fit size of `w x h` into the canvas.
    static func fitSize(_ w: Int, _ h: Int, canvas cw: Int, _ ch: Int) -> SIMD2<Float> {
        let s = min(Float(cw) / Float(w), Float(ch) / Float(h))
        return SIMD2(Float(w) * s, Float(h) * s)
    }

    private func geometry(_ u: inout Uniforms, transform t: ClipTransform, canvas: SequenceFormat, size: SIMD2<Float>,
                          cornerRadius: Double = 0) {
        u.cornerRadius = Float(max(0, cornerRadius))
        u.canvas = SIMD2(Float(canvas.width), Float(canvas.height))
        u.size = size
        u.position = SIMD2(Float(t.position.x), Float(t.position.y))
        u.anchor = SIMD2(Float(t.anchor.x), Float(t.anchor.y))
        u.scale = SIMD2(Float(max(0, t.scale.x)), Float(max(0, t.scale.y)))
        let r = t.rotation * .pi / 180
        u.rotCos = Float(cos(r)); u.rotSin = Float(sin(r))
        u.opacity = Float(min(1, max(0, t.opacity)))
    }

    // MARK: Render

    /// Renders layers bottom -> top over an opaque black background. `target`: rgba16Float, sequence size,
    /// `.renderTarget` usage. The caller commits `commandBuffer`; resources are retained until it completes.
    public func render(_ layers: [RenderLayer], format: SequenceFormat, into target: MTLTexture,
                       commandBuffer: MTLCommandBuffer) throws {
        try render(nodes: layers.map { .layer($0) }, format: format, into: target, commandBuffer: commandBuffer)
    }

    /// Tree variant: groups are composited recursively into pooled offscreen textures that stay reserved until the
    /// command buffer completes (so no in-flight texture is ever reused), then returned to the pool.
    public func render(nodes: [RenderNode], format: SequenceFormat, into target: MTLTexture,
                       commandBuffer: MTLCommandBuffer) throws {
        guard target.pixelFormat == .rgba16Float else { throw CompositorError.invalidTarget("pixel format must be rgba16Float") }
        guard target.usage.contains(.renderTarget) else { throw CompositorError.invalidTarget("needs .renderTarget usage") }
        guard target.width == format.width, target.height == format.height else {
            throw CompositorError.invalidTarget("size \(target.width)x\(target.height) != sequence \(format.width)x\(format.height)")
        }
        let retainer = Retainer()
        try encode(nodes, format: format, into: target, commandBuffer: commandBuffer, retainer: retainer,
                   clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
        let pooled = retainer.pooled
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.release(pooled)
            _ = retainer
        }
    }

    private func encode(_ nodes: [RenderNode], format: SequenceFormat, into target: MTLTexture, commandBuffer: MTLCommandBuffer,
                        retainer: Retainer, clear: MTLClearColor) throws {
        var prepared: [Prepared] = []
        for node in nodes {
            switch node {
            case .layer(let layer):
                var base: [Prepared] = []
                prepareLayer(layer, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &base)
                for p in base {
                    finishLayer(p, layer: layer, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
                }
            case .group(let gf, let transform, let opacity, let radius, let children):
                guard let tex = acquireIntermediate(width: gf.width, height: gf.height) else {
                    throw CompositorError.resourceAllocation
                }
                retainer.pooled.append(tex)
                try encode(children, format: gf, into: tex, commandBuffer: commandBuffer, retainer: retainer,
                           clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
                var u = Uniforms()
                u.mode = 3
                geometry(&u, transform: transform, canvas: format, size: SIMD2(Float(gf.width), Float(gf.height)),
                         cornerRadius: radius * Self.radiusFactor(gf.width, gf.height, canvas: format))
                u.opacity = Float(min(1, max(0, transform.opacity * opacity)))
                prepared.append(Prepared(u: u, tex0: tex, tex1: dummy))
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw CompositorError.resourceAllocation }
        enc.setRenderPipelineState(renderPipeline)
        enc.setCullMode(.none)
        var usingBlendPipeline = false
        for var p in prepared {
            // Blend modes need the destination: the programmable-blending pipeline for those draws, plain alpha-over otherwise.
            let wantsBlend = p.blend != .normal && blendPipeline != nil
            if wantsBlend != usingBlendPipeline {
                enc.setRenderPipelineState(wantsBlend ? blendPipeline! : renderPipeline)
                usingBlendPipeline = wantsBlend
            }
            p.u.blend = wantsBlend ? BlendModes.shaderID(p.blend) : 0
            enc.setVertexBytes(&p.u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&p.u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(p.tex0, index: 0)
            enc.setFragmentTexture(p.tex1, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    private func prepareLayer(_ layer: RenderLayer, format: SequenceFormat, commandBuffer: MTLCommandBuffer,
                              retainer: Retainer, into prepared: inout [Prepared]) {
            var u = Uniforms()
            switch layer.content {
            case .placeholder(let kind):
                // "Loading" draws nothing: a frame that is not decoded yet must never cover the layers below.
                if kind == .loading { return }
                u.mode = 2; u.solid = Self.placeholderLinear(kind)
                geometry(&u, transform: layer.transform, canvas: format,
                         size: SIMD2(Float(format.width), Float(format.height)), cornerRadius: layer.cornerRadius)
                prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
            case .linearPremultiplied(let pb, let w, let h):
                guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf,
                      let t0 = planeTexture(pb, plane: 0, format: .rgba16Float, retainer: retainer) else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.width), Float(format.height)), cornerRadius: layer.cornerRadius)
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    return
                }
                u.mode = 3
                geometry(&u, transform: layer.transform, canvas: format, size: SIMD2(Float(w), Float(h)),
                         cornerRadius: layer.cornerRadius)
                prepared.append(Prepared(u: u, tex0: t0, tex1: dummy))
            case .frame(let pb, let hint):
                guard let info = PixelFormats.info(for: CVPixelBufferGetPixelFormatType(pb)) else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.width), Float(format.height)), cornerRadius: layer.cornerRadius)
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    return
                }
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                let quarter = UInt32((hint.rotation / 90) & 3)
                let (nw, nh) = layer.nativeSize ?? (w, h)
                let (dw, dh) = quarter & 1 == 1 ? (nh, nw) : (nw, nh)     // upright size after the turn
                guard let t0 = planeTexture(pb, plane: 0, format: info.yFormat, retainer: retainer),
                      info.layout == .bgra8 || planeTexture(pb, plane: 1, format: info.cbcrFormat, retainer: retainer) != nil
                else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.width), Float(format.height)), cornerRadius: layer.cornerRadius)
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    return
                }
                let t1 = info.layout == .bgra8 ? dummy : CVMetalTextureGetTexture(retainer.textures.last!)!
                u.mode = info.layout == .bgra8 ? 1 : 0
                u.m = PixelFormats.ycbcrToRGB(PixelFormats.matrix(tag: hint.matrix))
                u.range = PixelFormats.rangeParams(info)
                u.quarter = quarter
                geometry(&u, transform: layer.transform, canvas: format, size: SIMD2(Float(dw), Float(dh)),
                         cornerRadius: layer.cornerRadius * Self.radiusFactor(dw, dh, canvas: format))
                var p = Prepared(u: u, tex0: t0, tex1: t1)
                p.radiusFactor = Self.radiusFactor(dw, dh, canvas: format)
                if let pipeline = layer.colorPipeline {
                    if let mid = acquireIntermediate(width: w, height: h) {
                        retainer.pooled.append(mid)
                        if let enc = commandBuffer.makeComputeCommandEncoder() {
                            var cu = u
                            enc.setComputePipelineState(convertPipeline)
                            enc.setTexture(t0, index: 0); enc.setTexture(t1, index: 1); enc.setTexture(mid, index: 2)
                            enc.setBytes(&cu, length: MemoryLayout<Uniforms>.stride, index: 0)
                            let tg = MTLSize(width: 16, height: 16, depth: 1)
                            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: tg)
                            enc.endEncoding()
                            if (try? colorGPU.encode(pipeline, source: mid, destination: mid, commandBuffer: commandBuffer)) != nil {
                                p.u.mode = 1; p.u.linearize = 0
                                p.tex0 = mid; p.tex1 = dummy
                            }
                        }
                    }
                }
                prepared.append(p)
            }
    }
}
