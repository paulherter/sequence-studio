#if os(Windows)
import CSQGPUD3D12
import SQGPU

// D3D12 backend of the SQGPU protocol (Windows). Thin wrappers over the C shim in CSQGPUD3D12; textures are reference
// counted there, so a list keeps every texture it binds alive until its commit.

public final class D3D12GPUTexture: GPUTexture {
    let handle: OpaquePointer
    public let width: Int, height: Int, depth: Int
    public let format: GPUPixelFormat
    init(handle: OpaquePointer, width: Int, height: Int, depth: Int = 1, format: GPUPixelFormat) {
        self.handle = handle; self.width = width; self.height = height; self.depth = depth; self.format = format
    }
    deinit { sqd3d_texture_release(handle) }
}

public final class D3D12GPUBuffer: GPUBuffer {
    let handle: OpaquePointer
    public let length: Int
    init(handle: OpaquePointer, length: Int) { self.handle = handle; self.length = length }
    deinit { sqd3d_texture_release(handle) }
}

public struct D3D12GPUPipeline {
    let index: Int32
}

public struct D3D12GPUComputeEncoder: GPUComputeEncoder {
    let list: OpaquePointer
    public func setPipeline(_ pipeline: D3D12GPUPipeline) { sqd3d_set_pipeline(list, pipeline.index) }
    public func setInput(_ texture: D3D12GPUTexture, at slot: Int) { sqd3d_set_input(list, Int32(slot), texture.handle) }
    public func setOutput(_ texture: D3D12GPUTexture) { sqd3d_set_output(list, texture.handle) }
    public func setBuffer(_ buffer: D3D12GPUBuffer, at slot: Int) { sqd3d_set_buffer(list, Int32(slot), buffer.handle) }
    public func setConstantBytes(_ bytes: UnsafeRawBufferPointer, slot: Int) {
        sqd3d_set_constants(list, Int32(slot), bytes.baseAddress, Int32(bytes.count))
    }
    public func dispatch(width: Int, height: Int) { sqd3d_dispatch(list, Int32(width), Int32(height)) }
    public func end() {}
}

public struct D3D12GPURenderPipeline {
    let index: Int32
}

public struct D3D12GPURenderEncoder: GPURenderEncoder {
    let list: OpaquePointer
    public func setPipeline(_ pipeline: D3D12GPURenderPipeline) { sqd3d_set_pipeline(list, pipeline.index) }
    public func setInput(_ texture: D3D12GPUTexture, at slot: Int) { sqd3d_set_input(list, Int32(slot), texture.handle) }
    public func setBuffer(_ buffer: D3D12GPUBuffer, at slot: Int) { sqd3d_set_buffer(list, Int32(slot), buffer.handle) }
    public func setConstantBytes(_ bytes: UnsafeRawBufferPointer, slot: Int) {
        sqd3d_set_constants(list, Int32(slot), bytes.baseAddress, Int32(bytes.count))
    }
    public func setViewport(x: Double, y: Double, width: Double, height: Double) {
        sqd3d_set_viewport(list, Float(x), Float(y), Float(width), Float(height))
    }
    public func setScissor(x: Int, y: Int, width: Int, height: Int) {
        sqd3d_set_scissor(list, Int32(x), Int32(y), Int32(width), Int32(height))
    }
    public func draw(_ primitive: GPUPrimitive, vertexCount: Int) {
        sqd3d_draw(list, Int32(vertexCount), primitive == .triangleStrip ? 1 : 0)
    }
    public func end() {}
}

public final class D3D12GPUCommandBuffer: GPUCommandBuffer {
    fileprivate var list: OpaquePointer?
    fileprivate init(list: OpaquePointer) { self.list = list }
    /// A buffer dropped without commit still has to close its list (one list per device at a time).
    deinit { if let list { _ = sqd3d_commit_wait(list) } }

    public func makeComputeEncoder() -> D3D12GPUComputeEncoder? { list.map(D3D12GPUComputeEncoder.init) }

    public func makeRenderEncoder(target: D3D12GPUTexture, clear: SIMD4<Float>?) -> D3D12GPURenderEncoder? {
        guard let list else { return nil }
        var rgba: [Float] = clear.map { [$0.x, $0.y, $0.z, $0.w] } ?? [0, 0, 0, 0]
        sqd3d_begin_render(list, target.handle, clear == nil ? 0 : 1, &rgba)
        return D3D12GPURenderEncoder(list: list)
    }

    @discardableResult public func copy(_ source: D3D12GPUTexture, to destination: D3D12GPUTexture) -> Bool {
        guard let list else { return false }
        return sqd3d_copy(list, source.handle, destination.handle) != 0
    }
}

public final class D3D12GPUDevice: GPUDevice {
    let handle: OpaquePointer
    /// False when a commit ran out of descriptors or constant space (see the shim's budgets).
    public private(set) var lastCommitSucceeded = true

    public init() throws {
        var err = [CChar](repeating: 0, count: 512)
        guard let g = sqd3d_create(&err, Int32(err.count)) else { throw GPUError.deviceUnavailable(Self.string(err)) }
        handle = g
    }

    deinit { sqd3d_destroy(handle) }

    public var name: String { String(cString: sqd3d_name(handle)) }

    public func makePipeline(_ kernel: GPUKernel) throws -> D3D12GPUPipeline {
        guard let hlsl = kernel.module.hlsl[kernel.entry] else { throw GPUError.missingEntry(kernel.entry) }
        var err = [CChar](repeating: 0, count: 2048)
        let index = sqd3d_pipeline(handle, hlsl, kernel.entry, &err, Int32(err.count))
        guard index >= 0 else { throw GPUError.shaderCompilation(Self.string(err)) }
        return D3D12GPUPipeline(index: index)
    }

    public func makeRenderPipeline(_ kernel: GPURenderKernel, format: GPUPixelFormat, blend: GPUBlend) throws -> D3D12GPURenderPipeline {
        guard let vs = kernel.module.hlsl[kernel.vertex] else { throw GPUError.missingEntry(kernel.vertex) }
        guard let ps = kernel.module.hlsl[kernel.fragment] else { throw GPUError.missingEntry(kernel.fragment) }
        var err = [CChar](repeating: 0, count: 2048)
        let b: Int32 = switch blend { case .replace: 0; case .premultipliedOver: 1; case .additive: 2 }
        let index = sqd3d_render_pipeline(handle, vs, kernel.vertex, ps, kernel.fragment, Self.code(format), b, &err, Int32(err.count))
        guard index >= 0 else { throw GPUError.shaderCompilation(Self.string(err)) }
        return D3D12GPURenderPipeline(index: index)
    }

    private static func code(_ f: GPUPixelFormat) -> Int32 {
        switch f {
        case .rgba16Float: 0
        case .rgba32Float: 1
        case .rgba8Unorm: 2
        case .r32Float: 3
        case .rg32Float: 4
        case .r8Unorm: 5
        case .rg8Unorm: 6
        case .r16Unorm: 7
        case .rg16Unorm: 8
        }
    }

    public func makeTexture(_ d: GPUTextureDescriptor) -> D3D12GPUTexture? {
        guard let t = sqd3d_texture(handle, Int32(d.width), Int32(d.height), Self.code(d.format)) else { return nil }
        return D3D12GPUTexture(handle: t, width: d.width, height: d.height, format: d.format)
    }

    public func makeTexture3D(width: Int, height: Int, depth: Int, format: GPUPixelFormat) -> D3D12GPUTexture? {
        guard let t = sqd3d_texture3d(handle, Int32(width), Int32(height), Int32(depth), Self.code(format)) else { return nil }
        return D3D12GPUTexture(handle: t, width: width, height: height, depth: depth, format: format)
    }

    public func makeBuffer(length: Int) -> D3D12GPUBuffer? {
        guard let b = sqd3d_buffer(handle, Int32(length)) else { return nil }
        let buffer = D3D12GPUBuffer(handle: b, length: (max(length, 4) + 3) / 4 * 4)
        upload(UnsafeRawBufferPointer(start: nil, count: 0), to: buffer)  // zero fill
        return buffer
    }

    public func upload(_ bytes: UnsafeRawBufferPointer, to buffer: D3D12GPUBuffer) {
        var all = [UInt8](repeating: 0, count: buffer.length)
        all.withUnsafeMutableBytes { dst in
            if let base = bytes.baseAddress { dst.baseAddress!.copyMemory(from: base, byteCount: min(bytes.count, buffer.length)) }
        }
        _ = all.withUnsafeBytes { sqd3d_upload(handle, buffer.handle, $0.baseAddress, Int32(buffer.length)) }
    }

    public func download(_ buffer: D3D12GPUBuffer) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: buffer.length)
        let ok = out.withUnsafeMutableBytes { sqd3d_download(handle, buffer.handle, $0.baseAddress, Int32(buffer.length)) == 0 }
        return ok ? out : []
    }

    public func makeCommandBuffer() -> D3D12GPUCommandBuffer? { sqd3d_begin(handle).map(D3D12GPUCommandBuffer.init) }

    public func commitAndWait(_ commandBuffer: D3D12GPUCommandBuffer) {
        guard let list = commandBuffer.list else { return }
        commandBuffer.list = nil
        lastCommitSucceeded = sqd3d_commit_wait(list) == 0
    }

    /// Submits without waiting: up to three command buffers run while the CPU records the next (the textures they use
    /// stay alive until the GPU finished them). `download` and `commitAndWait` afterwards still see their results.
    public func commit(_ commandBuffer: D3D12GPUCommandBuffer) {
        guard let list = commandBuffer.list else { return }
        commandBuffer.list = nil
        lastCommitSucceeded = sqd3d_commit(list) == 0
    }

    /// The most command buffers that were submitted and not finished at one time.
    public var inFlightMax: Int { Int(sqd3d_in_flight_max(handle)) }

    /// Records a readback of `texture` into `commandBuffer` (before its `commit`); `Readback.finish` waits only for that
    /// buffer. nil when the buffer is already committed.
    public func readback(_ texture: D3D12GPUTexture, in commandBuffer: D3D12GPUCommandBuffer) -> Readback? {
        guard let list = commandBuffer.list, let r = sqd3d_readback(list, texture.handle) else { return nil }
        return Readback(ticket: r, width: texture.width, height: texture.height, bytesPerPixel: texture.format.bytesPerPixel)
    }

    /// A pending readback: `finish` once (tightly packed rows); a ticket dropped unfinished still returns its buffer.
    public final class Readback {
        private var ticket: OpaquePointer?
        public let width: Int, height: Int
        let bytesPerPixel: Int
        init(ticket: OpaquePointer, width: Int, height: Int, bytesPerPixel: Int) {
            self.ticket = ticket; self.width = width; self.height = height; self.bytesPerPixel = bytesPerPixel
        }
        public func finish() -> [UInt8] {
            guard let t = ticket else { return [] }
            ticket = nil
            let row = width * bytesPerPixel
            var out = [UInt8](repeating: 0, count: row * height)
            let ok = out.withUnsafeMutableBytes { sqd3d_readback_finish(t, $0.baseAddress, Int32(row)) == 0 }
            return ok ? out : []
        }
        deinit { if ticket != nil { _ = finish() } }
    }

    public func upload(_ bytes: UnsafeRawBufferPointer, bytesPerRow: Int, to texture: D3D12GPUTexture) {
        guard let base = bytes.baseAddress else { return }
        _ = sqd3d_upload(handle, texture.handle, base, Int32(bytesPerRow))
    }

    public func download(_ texture: D3D12GPUTexture) -> [UInt8] {
        let row = texture.width * texture.format.bytesPerPixel
        var out = [UInt8](repeating: 0, count: row * texture.height)
        let ok = out.withUnsafeMutableBytes { sqd3d_download(handle, texture.handle, $0.baseAddress, Int32(row)) == 0 }
        return ok ? out : []
    }

    /// The ID3D12Device and direct ID3D12CommandQueue under this device, for a renderer that shares them (the app
    /// window's swap chain). Work submitted on the queue runs in order with this device's command buffers.
    public var nativeDevice: UnsafeMutableRawPointer { sqd3d_native_device(handle) }
    public var nativeQueue: UnsafeMutableRawPointer { sqd3d_native_queue(handle) }

    /// The texture's ID3D12Resource in the shader resource state, for sampling by a renderer on `nativeQueue`. Joins
    /// the open command buffer (call it before `commitAndWait`), else runs at once. The next pass that writes the
    /// texture moves it out of that state again.
    public func prepareForSampling(_ texture: D3D12GPUTexture) -> UnsafeMutableRawPointer? {
        sqd3d_texture_for_sampling(handle, texture.handle)
    }

    private static func string(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
