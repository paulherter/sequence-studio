#if canImport(Metal)
import Foundation
import Metal
import SQGPUKernels

/// The Mac GPU backend of the Canvas: one instanced draw of the frame's `DrawQuad`s with the shared quad shader
/// (`Packages/SQGPU/Shaders/DrawQuads.slang`, the module the Windows D3D12 shim compiles as HLSL). The atlas is an R8
/// texture, the image slots RGBA8 textures (straight alpha, as on Windows); the quads go to the GPU as they are (80 bytes).
/// `punchesVideo`: picture quads are cleared to transparent instead of drawn (the Program picture is a Metal layer under
/// the see-through draw list, `SharedUIView`), so what the panels draw after the quad stays on top of the picture.
/// Blending: color `src * a + dst * (1 - a)` in sRGB code values (as CoreGraphics and the reference rasterizer), alpha
/// `a + dstA * (1 - a)`, so the target holds premultiplied color for a non-opaque layer.
/// `CoreGraphicsRenderer` stays the fallback (no Metal device, `SQ_SHARED_UI_CG=1`) and draws the offscreen shots.
public final class MetalDrawListRenderer {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    private let queue: MTLCommandQueue
    private let blend: MTLRenderPipelineState
    private let punch: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let blank: MTLTexture
    private var atlasTexture: MTLTexture?
    private var atlasGeneration = -1
    private var images: [MTLTexture?] = Array(repeating: nil, count: DrawList.imageSlots)
    private var imageGenerations: [Int] = Array(repeating: Int.min, count: DrawList.imageSlots)

    /// Quad buffer index of the generated MSL (Slang numbers it after `t3`), constants at 0.
    static let quadBufferIndex = 3

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.pixelFormat = pixelFormat; self.queue = queue
        do {
            let lib = try device.makeLibrary(source: GeneratedShaders.drawQuads.msl, options: nil)
            func pipeline(_ fragment: String, blends: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: "quadVertex")
                d.fragmentFunction = lib.makeFunction(name: fragment)
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = pixelFormat
                if blends {
                    ca.isBlendingEnabled = true
                    ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            blend = try pipeline("quadFragment", blends: true)
            punch = try pipeline("quadClear", blends: false)
        } catch {
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sd) else { return nil }
        sampler = s
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let b = device.makeTexture(descriptor: bd) else { return nil }
        b.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4)
        blank = b
    }

    /// Uploads the atlas when its generation moved.
    public func setAtlas(_ atlas: GlyphAtlas) {
        guard atlas.generation != atlasGeneration || atlasTexture?.width != atlas.size else { return }
        if atlasTexture?.width != atlas.size {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: atlas.size, height: atlas.size, mipmapped: false)
            atlasTexture = device.makeTexture(descriptor: d)
        }
        atlas.pixels.withUnsafeBytes {
            atlasTexture?.replace(region: MTLRegionMake2D(0, 0, atlas.size, atlas.size), mipmapLevel: 0,
                                  withBytes: $0.baseAddress!, bytesPerRow: atlas.size)
        }
        atlasGeneration = atlas.generation
    }

    /// Image slot `slot` (RGBA8 rows top down); uploads only when `generation` moved. nil clears the slot.
    public func setImage(slot: Int, _ img: RGBAImage?, generation: Int) {
        guard images.indices.contains(slot), generation != imageGenerations[slot] else { return }
        imageGenerations[slot] = generation
        guard let img, img.width > 0, img.height > 0, img.pixels.count >= img.width * img.height * 4 else { images[slot] = nil; return }
        var t = images[slot]
        if t?.width != img.width || t?.height != img.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
            t = device.makeTexture(descriptor: d)
        }
        img.pixels.withUnsafeBytes {
            t?.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                       bytesPerRow: img.width * 4)
        }
        images[slot] = t
    }

    /// Encodes `list` into `target` (cleared to `clear` first) on a new command buffer, which the caller commits (after
    /// `present` for a drawable).
    /// `viewScale`: target pixels per list pixel (1 = the list's own size; below 1 the shader supersamples a reduced view).
    public func encode(_ list: DrawList, into target: MTLTexture, clear: DrawColor, punchesVideo: Bool, viewScale: Float = 1) -> MTLCommandBuffer? {
        guard let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.r * clear.a), green: Double(clear.g * clear.a),
                                                            blue: Double(clear.b * clear.a), alpha: Double(clear.a))
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        defer { enc.endEncoding() }
        let quads = list.quads
        guard !quads.isEmpty else { return cb }
        let stride = MemoryLayout<DrawQuad>.stride
        guard let buf = quads.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: quads.count * stride,
                                                                   options: .storageModeShared) }) else { return cb }
        // C: screen (target pixels), fullRange, hasVideo, viewExponent, viewScale, then a float2 pad: 8 floats (the buffer is 12).
        var constants: [Float] = [list.width * viewScale, list.height * viewScale, 0, 0, 1, viewScale, 0, 0, 0, 0, 0, 0]
        enc.setVertexBytes(&constants, length: constants.count * 4, index: 0)
        enc.setFragmentBytes(&constants, length: constants.count * 4, index: 0)
        enc.setFragmentTexture(atlasTexture ?? blank, index: 0)
        enc.setFragmentTexture(blank, index: 1)
        enc.setFragmentTexture(blank, index: 2)
        for (i, t) in images.enumerated() { enc.setFragmentTexture(t ?? blank, index: 4 + i) }
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: Self.quadBufferIndex)
        enc.setFragmentBuffer(buf, offset: 0, index: Self.quadBufferIndex)
        // Runs between picture quads: the instance index is relative to the bound offset (no base instance).
        func draw(_ range: Range<Int>, _ state: MTLRenderPipelineState) {
            guard !range.isEmpty else { return }
            enc.setRenderPipelineState(state)
            enc.setVertexBufferOffset(range.lowerBound * stride, index: Self.quadBufferIndex)
            enc.setFragmentBufferOffset(range.lowerBound * stride, index: Self.quadBufferIndex)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: range.count)
        }
        var start = 0
        if punchesVideo {
            let video = DrawQuad.Kind.video.rawValue
            for (i, q) in quads.enumerated() where q.kind == video {
                draw(start..<i, blend)
                draw(i..<(i + 1), punch)
                start = i + 1
            }
        }
        draw(start..<quads.count, blend)
        return cb
    }

    /// Offscreen: `list` into a new RGBA image (rows top down, opaque `clear` background), the GPU time in ms.
    public func render(_ list: DrawList, width: Int, height: Int, clear: DrawColor, viewScale: Float = 1) -> (image: RGBAImage, gpuMs: Double)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        guard let target = device.makeTexture(descriptor: d),
              let cb = encode(list, into: target, clear: clear.alpha(1), punchesVideo: false, viewScale: viewScale) else { return nil }
        if let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: target); blit.endEncoding() }
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: width * height * 4)
        px.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        if pixelFormat == .bgra8Unorm { for i in Swift.stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) } }
        return (RGBAImage(width: width, height: height, pixels: px), (cb.gpuEndTime - cb.gpuStartTime) * 1000)
    }
}
#endif
