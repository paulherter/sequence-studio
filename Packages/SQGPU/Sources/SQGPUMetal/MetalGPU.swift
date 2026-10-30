#if canImport(Metal)
import Foundation
import Metal
import SQGPU

// Metal backend of the SQGPU protocol (Mac). Wrappers are one-reference structs around the Metal objects, so wrapping a
// renderer texture or command buffer costs nothing; the renderer keeps using Metal directly for everything not yet moved.

public struct MetalGPUTexture: GPUTexture {
    public let texture: MTLTexture
    public init(_ texture: MTLTexture) { self.texture = texture }
    public var width: Int { texture.width }
    public var height: Int { texture.height }
    public var depth: Int { texture.depth }
    public var format: GPUPixelFormat {
        switch texture.pixelFormat {
        case .rgba32Float: .rgba32Float
        case .rgba8Unorm: .rgba8Unorm
        case .r32Float: .r32Float
        case .rg32Float: .rg32Float
        case .r8Unorm: .r8Unorm
        case .rg8Unorm: .rg8Unorm
        case .r16Unorm: .r16Unorm
        case .rg16Unorm: .rg16Unorm
        default: .rgba16Float
        }
    }
}

public struct MetalGPUBuffer: GPUBuffer {
    public let buffer: MTLBuffer
    public init(_ buffer: MTLBuffer) { self.buffer = buffer }
    public var length: Int { buffer.length }
}

public struct MetalGPUPipeline {
    public let state: MTLComputePipelineState
}

public struct MetalGPUComputeEncoder: GPUComputeEncoder {
    public let encoder: MTLComputeCommandEncoder
    public func setPipeline(_ pipeline: MetalGPUPipeline) { encoder.setComputePipelineState(pipeline.state) }
    public func setInput(_ texture: MetalGPUTexture, at slot: Int) { encoder.setTexture(texture.texture, index: slot) }
    public func setOutput(_ texture: MetalGPUTexture) { encoder.setTexture(texture.texture, index: GPUBinding.metalOutputIndex) }
    public func setBuffer(_ buffer: MetalGPUBuffer, at slot: Int) { encoder.setBuffer(buffer.buffer, offset: 0, index: slot) }
    public func setConstantBytes(_ bytes: UnsafeRawBufferPointer, slot: Int) {
        encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: slot)
    }
    public func dispatch(width: Int, height: Int) {
        let s = GPUBinding.groupSide
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: s, height: s, depth: 1))
    }
    public func end() { encoder.endEncoding() }
}

public struct MetalGPURenderPipeline {
    public let state: MTLRenderPipelineState
}

public struct MetalGPURenderEncoder: GPURenderEncoder {
    public let encoder: MTLRenderCommandEncoder
    public func setPipeline(_ pipeline: MetalGPURenderPipeline) { encoder.setRenderPipelineState(pipeline.state) }
    public func setInput(_ texture: MetalGPUTexture, at slot: Int) { encoder.setFragmentTexture(texture.texture, index: slot) }
    public func setBuffer(_ buffer: MetalGPUBuffer, at slot: Int) { encoder.setFragmentBuffer(buffer.buffer, offset: 0, index: slot) }
    public func setConstantBytes(_ bytes: UnsafeRawBufferPointer, slot: Int) {
        encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: slot)
        encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: slot)
    }
    public func setViewport(x: Double, y: Double, width: Double, height: Double) {
        encoder.setViewport(MTLViewport(originX: x, originY: y, width: width, height: height, znear: 0, zfar: 1))
    }
    public func setScissor(x: Int, y: Int, width: Int, height: Int) {
        encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: width, height: height))
    }
    public func draw(_ primitive: GPUPrimitive, vertexCount: Int) {
        encoder.drawPrimitives(type: primitive == .triangles ? .triangle : .triangleStrip, vertexStart: 0, vertexCount: vertexCount)
    }
    public func end() { encoder.endEncoding() }
}

public struct MetalGPUCommandBuffer: GPUCommandBuffer {
    public let buffer: MTLCommandBuffer
    let samplers: [MTLSamplerState]
    public func makeComputeEncoder() -> MetalGPUComputeEncoder? {
        guard let enc = buffer.makeComputeCommandEncoder() else { return nil }
        // One call per sampler: the array form bridges a Swift array on every encoder.
        for (i, s) in samplers.enumerated() { enc.setSamplerState(s, index: i) }
        return MetalGPUComputeEncoder(encoder: enc)
    }
    public func makeRenderEncoder(target: MetalGPUTexture, clear: SIMD4<Float>?) -> MetalGPURenderEncoder? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        pass.colorAttachments[0].storeAction = .store
        if let c = clear {
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: Double(c.w))
        } else {
            pass.colorAttachments[0].loadAction = .load
        }
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        MetalGPUDevice.bindSamplers(samplers, enc)
        return MetalGPURenderEncoder(encoder: enc)
    }
    @discardableResult public func copy(_ source: MetalGPUTexture, to destination: MetalGPUTexture) -> Bool {
        guard let blit = buffer.makeBlitCommandEncoder() else { return false }
        blit.copy(from: source.texture, to: destination.texture)
        blit.endEncoding()
        return true
    }
}

public final class MetalGPUDevice: GPUDevice, @unchecked Sendable {
    public let device: MTLDevice
    /// Indexed by GPUSampler.rawValue.
    let samplers: [MTLSamplerState]
    private let lock = NSLock()
    private var libraries: [String: MTLLibrary] = [:]
    /// Own queue for headless use (tests, reference renders), made on first use: the renderer wraps its own buffers.
    private var queue: MTLCommandQueue?

    public init(device: MTLDevice) throws {
        self.device = device
        func sampler(_ address: MTLSamplerAddressMode, filter: MTLSamplerMinMagFilter = .linear) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter; d.magFilter = filter; d.normalizedCoordinates = true
            d.sAddressMode = address; d.tAddressMode = address
            guard let s = device.makeSamplerState(descriptor: d) else { throw GPUError.deviceUnavailable("no sampler") }
            return s
        }
        samplers = [try sampler(.clampToZero), try sampler(.clampToEdge), try sampler(.clampToEdge, filter: .nearest)]
    }

    /// Binds the fixed samplers on a renderer's own draw encoder (fragment stage), as `makeRenderEncoder` does.
    public func bindSamplers(_ encoder: MTLRenderCommandEncoder) { Self.bindSamplers(samplers, encoder) }

    static func bindSamplers(_ samplers: [MTLSamplerState], _ encoder: MTLRenderCommandEncoder) {
        for (i, s) in samplers.enumerated() { encoder.setFragmentSamplerState(s, index: i) }
    }

    public var name: String { device.name }

    /// Wraps a renderer command buffer (no copy, no ownership change).
    public func wrap(_ buffer: MTLCommandBuffer) -> MetalGPUCommandBuffer { MetalGPUCommandBuffer(buffer: buffer, samplers: samplers) }

    public func makePipeline(_ kernel: GPUKernel) throws -> MetalGPUPipeline {
        let lib = try library(kernel.module)
        guard let f = lib.makeFunction(name: kernel.entry) else { throw GPUError.missingEntry(kernel.entry) }
        do { return MetalGPUPipeline(state: try device.makeComputePipelineState(function: f)) }
        catch { throw GPUError.shaderCompilation("\(kernel.entry): \(error)") }
    }

    public func makeRenderPipeline(_ kernel: GPURenderKernel, format: GPUPixelFormat, blend: GPUBlend) throws -> MetalGPURenderPipeline {
        try makeRenderPipeline(kernel, pixelFormat: Self.pixelFormat(format), blend: blend)
    }

    /// Any Metal target format (drawables: bgra8Unorm, rgba16Float, bgr10a2Unorm).
    public func makeRenderPipeline(_ kernel: GPURenderKernel, pixelFormat: MTLPixelFormat, blend: GPUBlend) throws -> MetalGPURenderPipeline {
        let lib = try library(kernel.module)
        guard let v = lib.makeFunction(name: kernel.vertex) else { throw GPUError.missingEntry(kernel.vertex) }
        guard let f = lib.makeFunction(name: kernel.fragment) else { throw GPUError.missingEntry(kernel.fragment) }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = pixelFormat
        if blend != .replace {
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
            let dst: MTLBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
            ca.destinationRGBBlendFactor = dst; ca.destinationAlphaBlendFactor = dst
        }
        do { return MetalGPURenderPipeline(state: try device.makeRenderPipelineState(descriptor: d)) }
        catch { throw GPUError.shaderCompilation("\(kernel.fragment): \(error)") }
    }

    private func library(_ module: GPUShaderModule) throws -> MTLLibrary {
        if let l = lock.withLock({ libraries[module.name] }) { return l }
        // Same options as the renderer's own MSL (no fast math), so converted kernels stay bit-identical.
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.languageVersion = .version3_1
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: module.msl, options: options) }
        catch { throw GPUError.shaderCompilation("\(module.name): \(error)") }
        lock.withLock { libraries[module.name] = lib }
        return lib
    }

    private static func pixelFormat(_ f: GPUPixelFormat) -> MTLPixelFormat {
        switch f {
        case .rgba16Float: .rgba16Float
        case .rgba32Float: .rgba32Float
        case .rgba8Unorm: .rgba8Unorm
        case .r32Float: .r32Float
        case .rg32Float: .rg32Float
        case .r8Unorm: .r8Unorm
        case .rg8Unorm: .rg8Unorm
        case .r16Unorm: .r16Unorm
        case .rg16Unorm: .rg16Unorm
        }
    }

    public func makeTexture3D(width: Int, height: Int, depth: Int, format: GPUPixelFormat) -> MetalGPUTexture? {
        let td = MTLTextureDescriptor()
        td.textureType = .type3D
        td.pixelFormat = Self.pixelFormat(format)
        td.width = width; td.height = height; td.depth = depth
        td.usage = [.shaderRead]
        td.storageMode = .shared
        return device.makeTexture(descriptor: td).map(MetalGPUTexture.init)
    }

    public func makeBuffer(length: Int) -> MetalGPUBuffer? {
        device.makeBuffer(length: max(length, 4), options: .storageModeShared).map(MetalGPUBuffer.init)
    }

    public func upload(_ bytes: UnsafeRawBufferPointer, to buffer: MetalGPUBuffer) {
        guard let base = bytes.baseAddress else { return }
        buffer.buffer.contents().copyMemory(from: base, byteCount: min(bytes.count, buffer.length))
    }

    public func download(_ buffer: MetalGPUBuffer) -> [UInt8] {
        Array(UnsafeRawBufferPointer(start: buffer.buffer.contents(), count: buffer.length))
    }

    public func makeTexture(_ d: GPUTextureDescriptor) -> MetalGPUTexture? {
        let pf = Self.pixelFormat(d.format)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: d.width, height: d.height, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite, .renderTarget]
        td.storageMode = d.cpuAccessible ? .shared : .private
        return device.makeTexture(descriptor: td).map(MetalGPUTexture.init)
    }

    public func makeCommandBuffer() -> MetalGPUCommandBuffer? {
        let q = lock.withLock {
            if queue == nil { queue = device.makeCommandQueue() }
            return queue
        }
        return q?.makeCommandBuffer().map(wrap)
    }

    public func commitAndWait(_ commandBuffer: MetalGPUCommandBuffer) {
        commandBuffer.buffer.commit()
        commandBuffer.buffer.waitUntilCompleted()
    }

    public func upload(_ bytes: UnsafeRawBufferPointer, bytesPerRow: Int, to texture: MetalGPUTexture) {
        let t = texture.texture
        t.replace(region: MTLRegionMake3D(0, 0, 0, t.width, t.height, t.depth), mipmapLevel: 0, slice: 0,
                  withBytes: bytes.baseAddress!, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerRow * t.height)
    }

    public func download(_ texture: MetalGPUTexture) -> [UInt8] {
        let t = texture.texture, row = t.width * texture.format.bytesPerPixel
        var out = [UInt8](repeating: 0, count: row * t.height)
        out.withUnsafeMutableBytes {
            t.getBytes($0.baseAddress!, bytesPerRow: row, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return out
    }
}
#endif
