// Thin GPU backend protocol under the renderer (the Windows port plan, Phase 1 seam 4). Portable: no Apple imports, builds
// on Windows. Backends: Metal (SQGPUMetal, Mac) and D3D12 (SQGPUD3D12, Windows). Kernels are written once in Slang
// (Packages/SQGPU/Shaders) and compiled to MSL and HLSL by scripts/gpu-shaders.sh.
//
// Binding layout (fixed for every kernel, see Shaders/Bindings.slang): up to `GPUBinding.inputs` read textures, a 3D table
// (`GPUBinding.tableSlot`), one written texture, `GPUBinding.constantSlots` small constant blocks, read-write data buffers
// (`GPUBinding.bufferSlots`), three fixed samplers (`GPUSampler`). Draws (`GPURenderEncoder`) use the same slots and
// write a render target instead of the output texture. Associated types instead of
// existentials, so a pass written against the protocol specializes to direct backend calls (no boxing per dispatch).

/// Texel formats the passes use (working images are rgba16Float).
public enum GPUPixelFormat: Sendable, Equatable {
    case rgba16Float, rgba32Float, rgba8Unorm
    /// One- and two-channel float planes (optical flow luma, gradients and fields); shaders read them as (r, g, 0, 1).
    case r32Float, rg32Float
    /// 8-bit video planes (NV12 luma and interleaved chroma), read as normalized (code / 255).
    case r8Unorm, rg8Unorm
    /// 16-bit video planes (P010 luma and interleaved chroma, 10 bits MSB-aligned), read as normalized (code / 65535).
    case r16Unorm, rg16Unorm

    public var bytesPerPixel: Int {
        switch self {
        case .rgba16Float: 8
        case .rgba32Float: 16
        case .rgba8Unorm: 4
        case .r32Float: 4
        case .rg32Float: 8
        case .r8Unorm: 1
        case .rg8Unorm: 2
        case .r16Unorm: 2
        case .rg16Unorm: 4
        }
    }
}

public struct GPUTextureDescriptor: Sendable, Equatable {
    public var width: Int, height: Int
    public var format: GPUPixelFormat
    /// true: the CPU can upload/download (tests, readback); false: GPU-only (the renderer's intermediates).
    public var cpuAccessible: Bool
    public init(width: Int, height: Int, format: GPUPixelFormat = .rgba16Float, cpuAccessible: Bool = false) {
        self.width = width; self.height = height; self.format = format; self.cpuAccessible = cpuAccessible
    }
}

public enum GPUBinding {
    /// Read textures in0...in23 (Metal texture(0...23), HLSL t0...t23); Video Denoise binds 22.
    public static let inputs = 24
    /// Input slot of the 3D table lut0 (Metal texture(24), HLSL t24): `setInput` with a texture from `makeTexture3D`.
    public static let tableSlot = 24
    /// Metal texture index of out0 (HLSL u0).
    public static let metalOutputIndex = 25
    /// Read-write data buffers of uint/float elements (Metal buffer(2...4), HLSL u2...u4; Slang RWStructuredBuffer).
    public static let bufferSlots = 2...4
    /// Constant blocks (Metal buffer(0...1), HLSL b0...b1).
    public static let constantSlots = 2
    /// Largest constant block a pass may set (Metal setBytes limit; the D3D12 upload ring sizes to it).
    public static let maxConstantBytes = 4_096
    /// Threads per group along x and y (every kernel is [numthreads(16, 16, 1)] and bound-checks its grid).
    public static let groupSide = 16
}

/// The samplers every kernel and draw sees (fixed: D3D12 static samplers s0...s2, Metal sampler(0)...(2)).
public enum GPUSampler: Int, Sendable, CaseIterable {
    /// Linear, normalized coordinates, transparent black outside (Metal clamp_to_zero, D3D12 border).
    case linearClampToZero = 0
    /// Linear, normalized coordinates, clamp to edge.
    case linearClampToEdge = 1
    /// Nearest, normalized coordinates, clamp to edge (the monitor at 100 % and above).
    case nearestClampToEdge = 2
}

/// Fixed-function blending of a draw's output onto its target (premultiplied colors).
public enum GPUBlend: Sendable, Equatable {
    /// The fragment's value replaces the target pixel.
    case replace
    /// out = src + dst * (1 - src.a).
    case premultipliedOver
    /// out = src + dst.
    case additive
}

public enum GPUPrimitive: Sendable, Equatable {
    case triangles, triangleStrip
}

public enum GPUShaderStage: Sendable, Equatable {
    case compute, vertex, fragment
}

/// One Slang module compiled for every backend: MSL holds all entries; HLSL has one source per entry.
public struct GPUShaderModule: Sendable {
    public let name: String
    public let entries: [String]
    public let msl: String
    public let hlsl: [String: String]
    /// Draw entries; every other entry is a compute kernel.
    public let stages: [String: GPUShaderStage]
    public init(name: String, entries: [String], stages: [String: GPUShaderStage] = [:], msl: String, hlsl: [String: String]) {
        self.name = name; self.entries = entries; self.stages = stages; self.msl = msl; self.hlsl = hlsl
    }
    public func stage(of entry: String) -> GPUShaderStage { stages[entry] ?? .compute }
}

public struct GPUKernel: Sendable {
    public let module: GPUShaderModule
    public let entry: String
    public init(_ module: GPUShaderModule, _ entry: String) { self.module = module; self.entry = entry }
}

/// A draw: vertex and fragment entry of one module (they share its constant blocks and inputs).
public struct GPURenderKernel: Sendable {
    public let module: GPUShaderModule
    public let vertex: String
    public let fragment: String
    public init(_ module: GPUShaderModule, vertex: String, fragment: String) {
        self.module = module; self.vertex = vertex; self.fragment = fragment
    }
}

public enum GPUError: Error, Equatable {
    case shaderCompilation(String)
    case missingEntry(String)
    case deviceUnavailable(String)
}

public protocol GPUTexture {
    var width: Int { get }
    var height: Int { get }
    /// 1 for a 2D texture; the slice count of a 3D table.
    var depth: Int { get }
    var format: GPUPixelFormat { get }
}

/// Plain bytes the kernels read and write as 4-byte elements (counts, means, gains). CPU-readable through the device.
public protocol GPUBuffer {
    var length: Int { get }
}

public protocol GPUComputeEncoder {
    associatedtype Texture: GPUTexture
    associatedtype Pipeline
    associatedtype Buffer: GPUBuffer
    func setPipeline(_ pipeline: Pipeline)
    /// `slot` 0..<GPUBinding.inputs.
    func setInput(_ texture: Texture, at slot: Int)
    func setOutput(_ texture: Texture)
    /// `slot` in GPUBinding.bufferSlots.
    func setBuffer(_ buffer: Buffer, at slot: Int)
    /// Copies `bytes` (at most GPUBinding.maxConstantBytes) into constant block `slot`; valid for the following dispatches.
    func setConstantBytes(_ bytes: UnsafeRawBufferPointer, slot: Int)
    /// One thread per (x, y) in width x height; kernels bound-check, so the grid may be any size.
    func dispatch(width: Int, height: Int)
    func end()
}

extension GPUComputeEncoder {
    /// Bitwise copy of a plain struct (its layout must mirror the shader's constant block).
    public func setConstants<T: BitwiseCopyable>(_ value: T, slot: Int = 0) {
        withUnsafeBytes(of: value) { setConstantBytes($0, slot: slot) }
    }
}

/// Draws into one target texture. Inputs, data buffers and constant blocks have the compute slots (both stages see the
/// constant blocks; the fragment sees inputs and buffers).
public protocol GPURenderEncoder {
    associatedtype Texture: GPUTexture
    associatedtype RenderPipeline
    associatedtype Buffer: GPUBuffer
    func setPipeline(_ pipeline: RenderPipeline)
    func setInput(_ texture: Texture, at slot: Int)
    func setBuffer(_ buffer: Buffer, at slot: Int)
    func setConstantBytes(_ bytes: UnsafeRawBufferPointer, slot: Int)
    /// Target pixels the draw maps to (origin top-left); default the whole target.
    func setViewport(x: Double, y: Double, width: Double, height: Double)
    /// Target pixels the draw may write; default the whole target.
    func setScissor(x: Int, y: Int, width: Int, height: Int)
    /// Vertices carry no attributes: the vertex entry builds them from SV_VertexID.
    func draw(_ primitive: GPUPrimitive, vertexCount: Int)
    func end()
}

extension GPURenderEncoder {
    public func setConstants<T: BitwiseCopyable>(_ value: T, slot: Int = 0) {
        withUnsafeBytes(of: value) { setConstantBytes($0, slot: slot) }
    }
}

public protocol GPUCommandBuffer {
    associatedtype Encoder: GPUComputeEncoder
    associatedtype RenderEncoder: GPURenderEncoder
        where RenderEncoder.Texture == Encoder.Texture, RenderEncoder.Buffer == Encoder.Buffer
    func makeComputeEncoder() -> Encoder?
    /// Draws into `target` (its whole area); `clear` = RGBA it is cleared to first, nil keeps its content.
    func makeRenderEncoder(target: Encoder.Texture, clear: SIMD4<Float>?) -> RenderEncoder?
    /// Whole-texture copy (same size and format). false when it could not be encoded.
    @discardableResult func copy(_ source: Encoder.Texture, to destination: Encoder.Texture) -> Bool
}

public protocol GPUDevice: AnyObject {
    associatedtype CommandBuffer: GPUCommandBuffer
    typealias Texture = CommandBuffer.Encoder.Texture
    typealias Pipeline = CommandBuffer.Encoder.Pipeline
    typealias Buffer = CommandBuffer.Encoder.Buffer
    typealias RenderPipeline = CommandBuffer.RenderEncoder.RenderPipeline

    var name: String { get }
    func makePipeline(_ kernel: GPUKernel) throws -> Pipeline
    /// A draw pipeline writing `format` targets with `blend`.
    func makeRenderPipeline(_ kernel: GPURenderKernel, format: GPUPixelFormat, blend: GPUBlend) throws -> RenderPipeline
    func makeTexture(_ descriptor: GPUTextureDescriptor) -> Texture?
    /// A read-only 3D table (color LUT), filled with `upload` (rows of `bytesPerRow`, slices one after another).
    func makeTexture3D(width: Int, height: Int, depth: Int, format: GPUPixelFormat) -> Texture?
    /// Zero-filled, CPU-readable through upload/download.
    func makeBuffer(length: Int) -> Buffer?
    func makeCommandBuffer() -> CommandBuffer?
    /// Submits and blocks until the GPU finished (tests, headless renders).
    func commitAndWait(_ commandBuffer: CommandBuffer)
    /// Rows of `bytesPerRow` into a cpuAccessible texture.
    func upload(_ bytes: UnsafeRawBufferPointer, bytesPerRow: Int, to texture: Texture)
    /// Tightly packed rows of a cpuAccessible texture (call after commitAndWait).
    func download(_ texture: Texture) -> [UInt8]
    func upload(_ bytes: UnsafeRawBufferPointer, to buffer: Buffer)
    /// The whole buffer (call after commitAndWait).
    func download(_ buffer: Buffer) -> [UInt8]
}
