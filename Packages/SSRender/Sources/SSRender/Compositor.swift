import CoreVideo
import Foundation
import Metal
import SSCore
import simd

public enum PlaceholderKind: Sendable { case offline, damaged, loading }

/// One layer of one display frame, built by the caller from `LayerRequest` + frame cache.
/// `transform` is the already evaluated `LayerRequest.transform`: position = offset from the canvas centre in
/// sequence px (y down), scale linear x/y, rotation in degrees (positive = clockwise on screen), anchor = offset from
/// the layer's (aspect-fitted) centre in sequence px, opacity 0...1. The layer is scaled/rotated about the anchor,
/// and the anchor lands on `canvas centre + position`.
public struct RenderLayer: @unchecked Sendable {
    public enum Content: @unchecked Sendable {
        case frame(CVPixelBuffer, colorHint: VideoTrackInfo)
        case placeholder(PlaceholderKind)
    }
    public var content: Content
    public var transform: ClipTransform
    /// Per-layer colour stage slot. nil = Rec.709 source: the compositor applies only the inverse BT.709 OETF
    /// (source-encoded -> working-linear). Non-nil = YCbCr->RGB into an intermediate, `ColorPipelineGPU.encode`
    /// (source-encoded -> working-linear, includes the output of the chain), then composite with no further transfer.
    public var colorPipeline: ColorPipeline?

    public init(content: Content, transform: ClipTransform = .identity, colorPipeline: ColorPipeline? = nil) {
        self.content = content; self.transform = transform; self.colorPipeline = colorPipeline
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
    private let renderPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let colorGPU: ColorPipelineGPU
    private let dummy: MTLTexture
    private let queueLock = NSLock()
    private var freeIntermediates: [MTLTexture] = []
    /// Frames that could not be sampled (unknown / unsupported compressed format) and were drawn as `.damaged`.
    /// The caller should then request an uncompressed format (`PixelFormats.uncompressedEquivalent`).
    public private(set) var unsupportedFrameCount = 0

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
        var pad: UInt32 = 0
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
    private final class Retainer: @unchecked Sendable {
        var textures: [CVMetalTexture] = []
        var pooled: [MTLTexture] = []
    }

    private struct Prepared {
        var u: Uniforms
        var tex0: MTLTexture
        var tex1: MTLTexture
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

    private func acquireIntermediate(width: Int, height: Int) -> MTLTexture? {
        queueLock.lock()
        if let i = freeIntermediates.firstIndex(where: { $0.width == width && $0.height == height }) {
            let t = freeIntermediates.remove(at: i)
            queueLock.unlock()
            return t
        }
        queueLock.unlock()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
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

    /// Aspect-fit size of `w x h` into the canvas.
    static func fitSize(_ w: Int, _ h: Int, canvas cw: Int, _ ch: Int) -> SIMD2<Float> {
        let s = min(Float(cw) / Float(w), Float(ch) / Float(h))
        return SIMD2(Float(w) * s, Float(h) * s)
    }

    private func geometry(_ u: inout Uniforms, transform t: ClipTransform, canvas: SequenceFormat, size: SIMD2<Float>) {
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
        guard target.pixelFormat == .rgba16Float else { throw CompositorError.invalidTarget("pixel format must be rgba16Float") }
        guard target.usage.contains(.renderTarget) else { throw CompositorError.invalidTarget("needs .renderTarget usage") }
        guard target.width == format.width, target.height == format.height else {
            throw CompositorError.invalidTarget("size \(target.width)x\(target.height) != sequence \(format.width)x\(format.height)")
        }
        let retainer = Retainer()
        var prepared: [Prepared] = []
        for layer in layers {
            var u = Uniforms()
            switch layer.content {
            case .placeholder(let kind):
                u.mode = 2; u.solid = Self.placeholderLinear(kind)
                geometry(&u, transform: layer.transform, canvas: format,
                         size: SIMD2(Float(format.width), Float(format.height)))
                prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
            case .frame(let pb, let hint):
                guard let info = PixelFormats.info(for: CVPixelBufferGetPixelFormatType(pb)) else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.width), Float(format.height)))
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    continue
                }
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                guard let t0 = planeTexture(pb, plane: 0, format: info.yFormat, retainer: retainer),
                      info.layout == .bgra8 || planeTexture(pb, plane: 1, format: info.cbcrFormat, retainer: retainer) != nil
                else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.width), Float(format.height)))
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    continue
                }
                let t1 = info.layout == .bgra8 ? dummy : CVMetalTextureGetTexture(retainer.textures.last!)!
                u.mode = info.layout == .bgra8 ? 1 : 0
                u.m = PixelFormats.ycbcrToRGB(PixelFormats.matrix(tag: hint.matrix))
                u.range = PixelFormats.rangeParams(info)
                geometry(&u, transform: layer.transform, canvas: format, size: Self.fitSize(w, h, canvas: format.width, format.height))
                var p = Prepared(u: u, tex0: t0, tex1: t1)
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
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw CompositorError.resourceAllocation }
        enc.setRenderPipelineState(renderPipeline)
        enc.setCullMode(.none)
        for var p in prepared {
            enc.setVertexBytes(&p.u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&p.u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(p.tex0, index: 0)
            enc.setFragmentTexture(p.tex1, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        let pooled = retainer.pooled
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.release(pooled)
            _ = retainer
        }
    }
}
