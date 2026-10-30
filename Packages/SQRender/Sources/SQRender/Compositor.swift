#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import SQFrame
import SQFrameCoreVideo
import SQGPU
import SQGPUKernels
import SQGPUMetal
import simd

/// Offscreen compositor: layers bottom -> top into an rgba16Float working-linear (Rec.709 primaries) target.
/// Used from the render thread only. Shaders are compiled at runtime (see `CompositorShaderSource`).
public final class Compositor: @unchecked Sendable {
    public let device: MTLDevice
    private let convertPipeline: MTLComputePipelineState
    /// Any-ratio downscaling convert of the display-size grade (preview only).
    private let convertScaledPipeline: MTLComputePipelineState
    /// Premultiplied working-linear -> straight BT.709-encoded (an Adjustment Layer's grade input).
    /// Seam 4 (the Windows port plan): kernels written once in Slang, run through the SQGPU protocol (Metal backend here).
    /// Blur, BT.709 encode, premultiply, frame blend and the Sharpen/Directional Blur/Mirror/Noise/Mosaic filters.
    let gpu: MetalGPUDevice
    let kernels: GPUKernels<MetalGPUDevice>
    let renderPipeline: MTLRenderPipelineState
    /// Same fragment with programmable blending (reads the destination); nil on GPUs without framebuffer fetch.
    let blendPipeline: MTLRenderPipelineState?
    /// Film / tape look: glow reduction chain (bright pass + 2x2 average) and the one pass that applies the look.
    let lookPipeline: MTLComputePipelineState
    /// Grain / scanlines only: the layer's upright draw with the look applied in the same fragment (no blending; the target
    /// is cleared and fully covered). Same bits as draw + `lookPipeline` (FilmLookRenderTests).
    let lookFusedPipeline: MTLRenderPipelineState
    /// Off only in tests that compare the fused look draw against the three-step pass.
    var fusesPointwiseLook = true
    /// Look passes drawn fused (tests).
    var fusedLookDraws = 0
    /// Drop Shadow and the whole-picture effects (`ImageFilters`), shared with `GPUCompositor`.
    let passes: EffectPasses<MetalGPUDevice>
    /// Combines the two sides of a motion transition (`RenderNode.transition`).
    private let transitionPipeline: MTLComputePipelineState
    private let transitionPreBlurPipeline: MTLComputePipelineState
    /// Exact smallest alpha of a transition side (`transitionCoverMin`): the mirrored-edges test.
    private let transitionCoverPipeline: MTLComputePipelineState
    /// Two floats of 1.0 (both sides cover): bound when a transition draw has no mirrored side.
    private let coverNeutral: MTLBuffer
    /// Same shader with additive blending (premultiplied sum): the second side of a transition pair.
    private let additivePipeline: MTLRenderPipelineState
    /// A transition's final draw with the mix computed in the fragment (normal / additive blending): no mix texture.
    private let transitionFusedPipeline: MTLRenderPipelineState
    private let transitionFusedAdditivePipeline: MTLRenderPipelineState
    /// Off only in tests that compare the fused transition draw against mix kernel + draw.
    var fusesTransitionMix = true
    /// Transition final draws that computed the mix in the fragment (tests).
    var fusedTransitionDraws = 0
    /// C6 Picture matte images rendered (tests: one per track and level, shared by every mask that reads it).
    var pictureMattePasses = 0
    /// Partial buffers copied into a whole picture so far (`RenderLayer.contentPart`; tests).
    public internal(set) var partialContentFills = 0
    /// Draws that read a partial buffer in place, with no whole picture made (tests).
    public internal(set) var partialContentDraws = 0
    /// A partial buffer (`RenderLayer.contentPart`) is sampled in place (ENGINE-NOTES "Animated captions"): the draw
    /// reads the buffer's own texture at the whole picture's texel coordinates (transparent outside the part), which
    /// saves one clear and one copy of the whole box per buffer and frame (0.25 to 0.5 ms of GPU time on a 4K box,
    /// `partInPlaceCostOnA4KBox`). false: the whole picture is made first (`wholeTexture`), a texel-exact copy by
    /// construction, which is what the tests compare the in-place read against.
    public var drawsContentPartsDirectly = true
    /// Loads and caches the LUTs of masked Color effects (`gradeSegment`). Set once by the engine before the first frame.
    public var colorResolver: LayerColorResolver?
    /// true (export): a masked effect's LUTs are read inline, so every frame has them. false (playback): background load,
    /// the effect shows without its LUT until the resolver's `onWarmed` redraw.
    public var colorResolverBlocks = false

    /// Most strips the draw of a turned plain part is split into (`partScissors`); 1 = its bounding box (tests).
    var partBands = Compositor.partBandLimit
    /// Whether this GPU reads a part in place with the bits of the whole picture (`CompositorPartCheck`): known for
    /// Apple GPUs, asked of any other one before the first in-place read; until then, and after a no, parts are copied.
    var partRead: PartRead
    /// A part was drawn by copy because the GPU has not been asked yet: the next render asks first.
    var partCheckWanted = false
    /// Tests: moves the in-place read by a fraction of a texel, so the check has something to find.
    var partReadSkew: SIMD2<Float> = .zero
    /// Where the check's answer for this GPU is kept (tests: one of their own).
    var partReadLedger = Compositor.sharedPartReadLedger
    /// Renders with a part still to pass before the check is tried again (`partCheckRetryRenders`).
    var partCheckHoldoff = 0
    /// Tests: stands in for the check (nil = it could not be made).
    var partCheckRunner: (() -> Bool?)?
    private let textureCache: CVMetalTextureCache
    /// Cache of `warmPlaneTextures` (its own, used under `warmLock` only, so a warm never races the draw's cache).
    private let warmCache: CVMetalTextureCache
    private let warmLock = NSLock()
    /// Plane textures of recently drawn or warmed pixel buffers, by buffer, plane and format (all under `planeLock`). Making
    /// a CVMetalTexture costs IOSurface kernel calls (0.3-0.7 ms per 4K frame on the render thread); a buffer drawn again
    /// (paused redraw, a text raster, Trails' and Denoise's neighbors) or warmed ahead is not wrapped again. An entry
    /// holds its buffer, so the identity cannot be reused while it lives; the texture is a view of the buffer's IOSurface
    /// (no copy), so it shows what the buffer holds at the draw, exactly like a new one. Kept while drawn (or warmed) in
    /// the last `planeMemoRenders` renders; `trimIntermediatePool` forgets everything.
    struct PlaneKey: Hashable { let buffer: ObjectIdentifier; let plane: Int; let format: UInt }
    struct PlaneEntry { let buffer: CVPixelBuffer; let texture: CVMetalTexture; var used: UInt64 }
    private let planeLock = NSLock()
    private var planeMemo: [PlaneKey: PlaneEntry] = [:]
    private var planeGeneration: UInt64 = 0
    /// Bumped by `trimIntermediatePool`: a texture made before a trim is not remembered after it (a warm running during a
    /// critical-pressure trim cannot fill the memo again).
    private var planeTrimEpoch: UInt64 = 0
    static let planeMemoRenders: UInt64 = 2
    /// Most entries (a new one beyond it is not remembered).
    static let planeMemoLimit = 128
    /// On for the monitor (its frames stay in the frame cache anyway). Off by default: export draws each decoded frame
    /// once, and held buffers would sit outside its decode byte budget.
    public var remembersPlaneTextures = false
    /// Plane textures the draws made (a memo hit does not count) and the ones `warmPlaneTextures` made (tests, bench).
    public var planeTextureCreates: Int { planeLock.withLock { planeCreates } }
    public var warmedPlaneTextures: Int { planeLock.withLock { planeWarms } }
    private var planeCreates = 0, planeWarms = 0
    /// Color chain kernels (internal: tests switch `specialization` to compare against the generic interpreter).
    let colorGPU: ColorPipelineGPU
    let dummy: MTLTexture
    /// Bound at fragment buffer 1 for draws without masks (the shader never reads it then).
    let dummyBuffer: MTLBuffer
    private let queueLock = NSLock()
    private let flowLock = NSLock()
    private var flowEngineStorage: OpticalFlowEngine?
    private var freeIntermediates: [MTLTexture] = []
    /// Bytes the free intermediate pool may hold (about four 4K transitions' worth of textures).
    public var intermediatePoolByteLimit = 1 << 30
    /// Largest side of a texture the device makes (Apple GPUs: 16384); tests lower it.
    var maxIntermediateSide = 16384
    /// Frames that could not be sampled (unknown / unsupported compressed format) and were drawn as `.damaged`.
    /// The caller should then request an uncompressed format (`PixelFormats.uncompressedEquivalent`).
    public private(set) var unsupportedFrameCount = 0
    /// Run a frame layer's color stage only where it shows: over the part of the source that lands on the canvas, at half
    /// resolution when the layer is shown at half size or less (`colorWork`). Off only in tests that compare both.
    public var limitsColorWork = true
    /// Preview only (playback and scrub in the monitor; export never sets it): a frame layer shown smaller than its
    /// texture whose whole chain is pointwise (`isPointwise`) is scaled to the size it is shown first and graded there
    /// (`displayColorWork`), instead of grading every source texel. Not byte-identical to export: within the tolerance
    /// in docs/PLAYBACK-PERF.md. Spatial effects keep their order (the layer falls back to the normal path).
    public var gradesAtDisplaySize = false
    /// With `gradesAtDisplaySize`: log and PQ sources (`averagesBeforeGrading` false) are graded at display size too,
    /// their conversion (tone map) per source sample and the rest of the chain per shown pixel (`sqFusedScaledTone`).
    /// Off (`SQ_DISPLAY_TONE=0`, tests, A/B): they grade at full size as in export.
    var tonesBeforeDisplayScale = ProcessInfo.processInfo.environment["SQ_DISPLAY_TONE"] != "0"
    /// Intermediate textures ever allocated (the pool reuses same-sized ones): a steady animation must not keep growing this.
    public private(set) var intermediateAllocations = 0
    /// W9.8: matte textures of the last few mattes (by array storage; the cache holds the matte, so its storage stays alive
    /// and cannot be reused by another one). A paused redraw draws the same matte again without uploading it.
    let matteLock = NSLock()
    var matteCache: [(matte: SubjectMatte, texture: MTLTexture)] = []
    /// Matte textures uploaded so far (a redraw of the same matte must not add one).
    public internal(set) var matteUploads = 0
    /// Several mattes of one draw packed into the channels of one rgba16Float texture (by their storages).
    var packedMatteCache: [(mattes: [SubjectMatte], keys: [Int], texture: MTLTexture)] = []   // mattes kept: their storages stay unique
    /// Matte pooling (all under `matteLock`): a texture leaving a cache goes back to `freeMattes` once no frame in flight
    /// reads it (`matteInFlight`, counted per frame through `Retainer.mattes`); until then it waits in `retiredMattes`.
    /// The next new matte of the same size and format is uploaded into it: playback with a new matte every frame
    /// allocates nothing once warm.
    var freeMattes: [MTLTexture] = []
    var matteInFlight: [ObjectIdentifier: Int] = [:]
    var retiredMattes: [ObjectIdentifier: MTLTexture] = [:]
    /// Matte textures ever allocated (uploads into a pooled texture do not count).
    var matteAllocations = 0
    /// Reused half-float staging for uploads.
    var matteScratch: [Float16] = []
    /// Reused float staging for packed (interleaved) matte uploads.
    var matteInterleaved: [Float] = []
    /// Mask data buffers (`Prepared.maskData`) back from finished frames, by power-of-two length.
    var freeMaskBuffers: [MTLBuffer] = []
    let maskScopePipeline: MTLComputePipelineState
    /// Video Denoise / Deflicker kernels (`TemporalPass`), compiled on first use.
    let temporalLock = NSLock()
    var temporalStore: TemporalPasses<MetalGPUDevice>?

    /// A compute encoder with the SQGPU samplers bound, for the Slang kernels (their samplers are not inline).
    func computeEncoder(_ commandBuffer: MTLCommandBuffer) -> MTLComputeCommandEncoder? {
        gpu.wrap(commandBuffer).makeComputeEncoder()?.encoder
    }

    /// A render encoder for layer draws (Layer.slang and its variants): samplers bound, no culling.
    func layerEncoder(_ commandBuffer: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor) -> MTLRenderCommandEncoder? {
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setCullMode(.none)
        gpu.bindSamplers(enc)
        return enc
    }

    /// One layer draw's inputs in the Slang layout: uniforms at buffer 0 of both stages, the picture planes at texture 0 / 1,
    /// mask data at buffer 2, the subject / Magic matte and the Picture mask sources at texture 3...5.
    func bindLayer(_ enc: MTLRenderCommandEncoder, _ u: inout Uniforms, _ tex0: MTLTexture, _ tex1: MTLTexture,
                   maskData: MTLBuffer? = nil, matte: MTLTexture? = nil, picture0: MTLTexture? = nil, picture1: MTLTexture? = nil) {
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(tex0, index: 0)
        enc.setFragmentTexture(tex1, index: 1)
        enc.setFragmentBuffer(maskData ?? dummyBuffer, offset: 0, index: 2)
        enc.setFragmentTexture(matte ?? dummy, index: 3)
        enc.setFragmentTexture(picture0 ?? dummy, index: 4)
        enc.setFragmentTexture(picture1 ?? dummy, index: 5)
    }

    public init(device: MTLDevice) throws {
        self.device = device
        partRead = Self.initialPartRead(device)
        let metal = try MetalGPUDevice(device: device)
        gpu = metal
        kernels = try GPUKernels(device: metal)
        passes = try EffectPasses(device: metal, kernels: kernels)
        // Seam 4: every kernel and draw below is Slang (SQGPUKernels); dispatch the kernels on `computeEncoder(_:)` and draw
        // on `layerEncoder(_:_:)` (samplers bound).
        func slang(_ m: GPUShaderModule, _ entry: String) throws -> MTLComputePipelineState {
            try metal.makePipeline(GPUKernel(m, entry)).state
        }
        func draw(_ m: GPUShaderModule, _ fragment: String, _ blend: GPUBlend) throws -> MTLRenderPipelineState {
            try metal.makeRenderPipeline(GPURenderKernel(m, vertex: "compositeVertex", fragment: fragment), format: .rgba16Float,
                                         blend: blend).state
        }
        convertPipeline = try slang(GeneratedShaders.sourceConvert, "convertToRGB")
        convertScaledPipeline = try slang(GeneratedShaders.sourceConvert, "convertToRGBScaled")
        renderPipeline = try draw(GeneratedShaders.layer, "compositeFragment", .premultipliedOver)
        lookPipeline = try slang(GeneratedShaders.filmLook, "filmLook")
        lookFusedPipeline = try draw(GeneratedShaders.layerLook, "compositeFragmentLook", .replace)
        transitionPipeline = try slang(GeneratedShaders.transitionMix, "transitionMix")
        maskScopePipeline = try slang(GeneratedShaders.maskScope, "maskScopeMix")
        transitionPreBlurPipeline = try slang(GeneratedShaders.transitionPreBlur, "transitionPreBlur")
        transitionCoverPipeline = try slang(GeneratedShaders.transitionCover, "transitionCoverMin")
        var ones: [UInt32] = [Float(1).bitPattern, Float(1).bitPattern]
        guard let cn = device.makeBuffer(bytes: &ones, length: 8, options: .storageModeShared) else {
            throw CompositorError.resourceAllocation
        }
        coverNeutral = cn
        // Programmable blending (reads the target in the fragment): Apple GPUs only.
        blendPipeline = device.supportsFamily(.apple1) ? try? draw(GeneratedShaders.layer, "compositeFragmentBlend", .replace) : nil
        transitionFusedPipeline = try draw(GeneratedShaders.layerTransition, "compositeFragmentTransition", .premultipliedOver)
        transitionFusedAdditivePipeline = try draw(GeneratedShaders.layerTransition, "compositeFragmentTransition", .additive)
        additivePipeline = try draw(GeneratedShaders.layer, "compositeFragment", .additive)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw CompositorError.resourceAllocation
        }
        textureCache = cache
        var warm: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &warm) == kCVReturnSuccess, let warm else {
            throw CompositorError.resourceAllocation
        }
        warmCache = warm
        colorGPU = try ColorPipelineGPU(device: device)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let dt = device.makeTexture(descriptor: d) else { throw CompositorError.resourceAllocation }
        dummy = dt
        guard let db = device.makeBuffer(length: 16, options: .storageModeShared) else { throw CompositorError.resourceAllocation }
        dummyBuffer = db
    }

    // MARK: Helpers

    /// Keeps CVMetalTextures (and pooled intermediates) alive until the GPU finished. It also holds the cache the
    /// textures came from and lets them go first: a CVMetalTexture released after its cache (the compositor was freed
    /// while its last frame was still on the GPU) crashes in `CVMetalTextureCache::bufferBackingNotInUse`.
    final class Retainer: @unchecked Sendable {
        private let caches: [CVMetalTextureCache]
        init(caches: [CVMetalTextureCache]) { self.caches = caches }
        deinit { withExtendedLifetime(caches) { textures.removeAll(); evicted.removeAll() } }
        var textures: [CVMetalTexture] = []
        /// Plane memo entries this render let go: released with the retainer (the command buffer's completion), not on
        /// the render thread.
        var evicted: [PlaneEntry] = []
        var pooled: [MTLTexture] = []
        /// Whole pictures made from partial buffers in this render (`RenderLayer.contentPart`), by buffer: the copies of
        /// a motion-blurred layer share one.
        var wholes: [ObjectIdentifier: (part: RenderLayer.ContentPart, texture: MTLTexture)] = [:]
        /// Matte textures and mask data buffers this frame reads (`releaseMasks` when it completed).
        var mattes: [MTLTexture] = []
        var maskBuffers: [MTLBuffer] = []
        /// C6: the Picture matte images by track, one scope per level being encoded (a nested group starts an empty one;
        /// pair / transition sides and an adjustment's picture below see their level's).
        var pictureScopes: [[Track.ID: MTLTexture]] = [[:]]
    }

    struct Prepared {
        var u: Uniforms
        var tex0: MTLTexture
        var tex1: MTLTexture
        /// Blend mode of this draw (single-layer composite; two-layer transition blending is a separate path).
        var blend: BlendMode = .normal
        /// A footage-fill draw (`RenderNode.stencil`): `tex0` is the matte, the draw keeps the destination under it.
        var stencil = false
        /// Converts a corner radius in clip px (fitted into the canvas) to layer px, as `prepareLayer` did.
        var radiusFactor: Double = 1
        /// W6.7 clip masks of this draw (`Compositor.maskBuffer`); nil = the empty `dummyBuffer`.
        var maskData: MTLBuffer? = nil
        /// W9.8 subject matte of this draw (fragment texture 2); nil = `dummy`.
        var matteTex: MTLTexture? = nil
        /// C6 Picture matte images of this draw (fragment textures 3 and 4); nil = `dummy`.
        var picture0: MTLTexture? = nil
        var picture1: MTLTexture? = nil
        /// A transition whose mix this draw computes (`tex0` / `tex1` are its two sides); nil = a plain draw of `tex0`.
        var mix: TransitionUniforms? = nil
        /// Smallest alpha of the two sides of `mix` (two floats, written by the GPU); nil = both cover (`coverNeutral`).
        var cover: MTLBuffer? = nil
        /// The only place this draw can paint: the corners of that quad as fractions of the canvas (`partCorners`); nil
        /// = anywhere. The quad drawn stays the whole layer's (the same texture coordinates in every fragment), the
        /// rasterizer just leaves the rest out (`partScissors`).
        var clip: [SIMD2<Double>]? = nil
    }

    struct PartBounds { var minX: Double, minY: Double, maxX: Double, maxY: Double }

    /// Where a partial buffer of `width` x `height` texels can show on the canvas (fractions of it, in order around
    /// the quad): the corners of the part, one texel wider on every side (what linear filtering reaches), through the
    /// layer's transform as the vertex stage applies it. nil when the numbers are not finite (the draw is then not
    /// limited).
    static func partCorners(_ part: RenderLayer.ContentPart, width: Int, height: Int, size: SIMD2<Double>,
                            transform t: ClipTransform, canvas: SequenceFormat) -> [SIMD2<Double>]? {
        guard part.wholeWidth > 0, part.wholeHeight > 0, canvas.displayWidth > 0, canvas.height > 0 else { return nil }
        let r = t.rotation * .pi / 180, c = cos(r), s = sin(r)
        let sx = max(0, t.scale.x), sy = max(0, t.scale.y)
        let (tx0, tx1) = (Double(part.x - 1), Double(part.x + width + 1))
        let (ty0, ty1) = (Double(part.y - 1), Double(part.y + height + 1))
        var out: [SIMD2<Double>] = []
        for (tx, ty) in [(tx0, ty0), (tx1, ty0), (tx1, ty1), (tx0, ty1)] {
            let lx = (tx / Double(part.wholeWidth) - 0.5) * size.x, ly = (ty / Double(part.wholeHeight) - 0.5) * size.y
            let px = (lx - t.anchor.x) * sx, py = (ly - t.anchor.y) * sy
            var off = Vec2(c * px - s * py, s * px + c * py)
            if t.isTilted {
                let radius = PerspectiveTilt.layerRadius(size: Vec2(size.x, size.y), anchor: t.anchor, scale: Vec2(sx, sy))
                let focal = PerspectiveTilt.focal(layerRadius: radius + 2, canvas: Vec2(Double(canvas.displayWidth), Double(canvas.height)))
                off = PerspectiveTilt.project(off, tiltX: t.tiltX, tiltY: t.tiltY, focal: focal)
            }
            let x = (Double(canvas.displayWidth) / 2 + t.position.x + off.x) / Double(canvas.displayWidth)
            let y = (Double(canvas.height) / 2 + t.position.y + off.y) / Double(canvas.height)
            guard x.isFinite, y.isFinite else { return nil }
            out.append(SIMD2(x, y))
        }
        return out
    }

    /// The bounding box of `partCorners`.
    static func partBounds(_ part: RenderLayer.ContentPart, width: Int, height: Int, size: SIMD2<Double>,
                           transform t: ClipTransform, canvas: SequenceFormat) -> PartBounds? {
        guard let q = partCorners(part, width: width, height: height, size: size, transform: t, canvas: canvas) else { return nil }
        var b = PartBounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for p in q { b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x); b.minY = min(b.minY, p.y); b.maxY = max(b.maxY, p.y) }
        return b
    }

    /// Most strips a turned part's draw is split into (`partScissors`), and the least width of one in pixels.
    static let partBandLimit = 16, partBandMinimum = 16

    /// The scissor rectangles that hold the quad `corners` (fractions of the canvas, in order around it) on a target
    /// of `tw` x `th` pixels, one pixel wider on every side (the vertex stage works in single precision, and an
    /// edge-antialiased quad is a pixel larger). They never overlap: the draw is repeated once per rectangle, and a
    /// pixel in two of them would be blended twice. An upright quad is its bounding box. A turned one is cut into
    /// strips, across whichever axis leaves fewer pixels, each as long as the quad is inside it: the bounding box of
    /// a long part turned by 19 degrees is 2.6 times the part, sixteen strips 1.1 times. Empty: off the target.
    static func partScissors(_ corners: [SIMD2<Double>], width tw: Int, height th: Int,
                             bands: Int = Compositor.partBandLimit) -> [MTLScissorRect] {
        guard corners.count == 4, tw > 0, th > 0 else { return [] }
        let p = corners.map { SIMD2($0.x * Double(tw), $0.y * Double(th)) }
        func low(_ v: Double, _ n: Int) -> Int { Int(min(max((v - 1).rounded(.down), 0), Double(n))) }
        func high(_ v: Double, _ n: Int) -> Int { Int(min(max((v + 1).rounded(.up), 0), Double(n))) }
        let xs = p.map(\.x), ys = p.map(\.y)
        let x0 = low(xs.min()!, tw), x1 = high(xs.max()!, tw), y0 = low(ys.min()!, th), y1 = high(ys.max()!, th)
        guard x1 > x0, y1 > y0 else { return [] }
        let box = [MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)]
        let boxArea = (x1 - x0) * (y1 - y0)
        /// Strips across axis `k` (0: columns, 1: rows) and the pixels they hold.
        func strips(_ k: Int) -> (rects: [MTLScissorRect], area: Int) {
            let (a0, a1) = k == 0 ? (x0, x1) : (y0, y1), (b0, b1, bn) = k == 0 ? (y0, y1, th) : (x0, x1, tw)
            let n = min(bands, (a1 - a0) / partBandMinimum)
            guard n > 1 else { return (box, boxArea) }
            var out: [MTLScissorRect] = [], area = 0
            for i in 0..<n {
                let s = a0 + (a1 - a0) * i / n, e = a0 + (a1 - a0) * (i + 1) / n
                // How far the quad reaches along the other axis inside this strip, the strip a pixel wider.
                let (ls, le) = (Double(s) - 1, Double(e) + 1)
                var least = Double.infinity, most = -Double.infinity
                for j in 0..<4 {
                    let u = p[j], v = p[(j + 1) % 4]
                    if u[k] >= ls, u[k] <= le { least = min(least, u[1 - k]); most = max(most, u[1 - k]) }
                    for edge in [ls, le] where (u[k] - edge) * (v[k] - edge) < 0 {
                        let w = u[1 - k] + (edge - u[k]) / (v[k] - u[k]) * (v[1 - k] - u[1 - k])
                        least = min(least, w); most = max(most, w)
                    }
                }
                guard least <= most else { continue }
                let c0 = max(b0, low(least, bn)), c1 = min(b1, high(most, bn))
                guard c1 > c0 else { continue }
                out.append(k == 0 ? MTLScissorRect(x: s, y: c0, width: e - s, height: c1 - c0)
                                  : MTLScissorRect(x: c0, y: s, width: c1 - c0, height: e - s))
                area += (e - s) * (c1 - c0)
            }
            return (out, area)
        }
        let columns = strips(0), rows = strips(1)
        let best = columns.area <= rows.area ? columns : rows
        // Not worth more draws for less than a seventh fewer pixels (an upright quad: none fewer).
        return best.area * 7 <= boxArea * 6 ? best.rects : box
    }

    func planeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, retainer: Retainer) -> MTLTexture? {
        let key = PlaneKey(buffer: ObjectIdentifier(pb), plane: plane, format: format.rawValue)
        planeLock.lock()
        if var e = planeMemo[key], let tex = CVMetalTextureGetTexture(e.texture) {
            e.used = planeGeneration
            planeMemo[key] = e
            planeLock.unlock()
            retainer.textures.append(e.texture)
            return tex
        }
        let epoch = planeTrimEpoch
        planeLock.unlock()
        guard let out = Self.makePlaneTexture(pb, plane: plane, format: format, cache: textureCache),
              let tex = CVMetalTextureGetTexture(out) else { return nil }
        planeLock.lock()
        planeCreates += 1
        if planeTrimEpoch == epoch { remember(key, PlaneEntry(buffer: pb, texture: out, used: planeGeneration)) }
        planeLock.unlock()
        retainer.textures.append(out)
        return tex
    }

    private static func makePlaneTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                                         cache: CVMetalTextureCache) -> CVMetalTexture? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var out: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &out)
        return r == kCVReturnSuccess ? out : nil
    }

    /// Under `planeLock`.
    private func remember(_ key: PlaneKey, _ entry: PlaneEntry) {
        guard remembersPlaneTextures, planeMemo[key] != nil || planeMemo.count < Self.planeMemoLimit else { return }
        planeMemo[key] = entry
    }

    /// A new render: entries not drawn or warmed in the last `planeMemoRenders` renders go (returned, so they are
    /// released outside the lock).
    private func advancePlaneMemo() -> [PlaneEntry] {
        planeLock.lock(); defer { planeLock.unlock() }
        planeGeneration &+= 1
        let g = planeGeneration
        guard planeMemo.values.contains(where: { $0.used &+ Self.planeMemoRenders < g }) else { return [] }
        var gone: [PlaneEntry] = []
        planeMemo = planeMemo.filter { _, e in
            if e.used &+ Self.planeMemoRenders < g { gone.append(e); return false }
            return true
        }
        return gone
    }

    /// Wraps the planes of `buffers` (decoded video frames the next render will draw) in Metal textures now, so that draw
    /// finds them made instead of making them on the render thread. The same textures a draw makes (plane formats from
    /// `PixelFormats`); a buffer of another format is skipped. Any thread (calls are serialized).
    public func warmPlaneTextures(_ frames: [SQFrame]) {
        guard remembersPlaneTextures else { return }
        warmLock.lock(); defer { warmLock.unlock() }
        let epoch = planeLock.withLock { planeTrimEpoch }
        for frame in frames {
            let pb = frame.pixelBuffer
            guard let info = PixelFormats.info(for: CVPixelBufferGetPixelFormatType(pb)) else { continue }
            let planes: [(Int, MTLPixelFormat)] = info.singlePlane ? [(0, info.yFormat)] : [(0, info.yFormat), (1, info.cbcrFormat)]
            for (plane, format) in planes {
                let key = PlaneKey(buffer: ObjectIdentifier(pb), plane: plane, format: format.rawValue)
                planeLock.lock()
                let known = planeMemo[key] != nil, trimmed = planeTrimEpoch != epoch
                planeLock.unlock()
                if trimmed { return }               // a trim ran meanwhile: warm nothing more
                if known { continue }
                guard let out = Self.makePlaneTexture(pb, plane: plane, format: format, cache: warmCache) else { break }
                warmMadeHook?()
                planeLock.lock()
                let kept = planeTrimEpoch == epoch
                if kept {
                    planeWarms += 1
                    remember(key, PlaneEntry(buffer: pb, texture: out, used: planeGeneration))
                }
                planeLock.unlock()
                if !kept { return }
            }
        }
    }

    /// Whether plane textures of `pb` are remembered (tests).
    func remembersPlanes(of pb: CVPixelBuffer) -> Bool {
        planeLock.lock(); defer { planeLock.unlock() }
        return planeMemo.keys.contains { $0.buffer == ObjectIdentifier(pb) }
    }

    /// Tests: runs inside a warm, after a texture is made and before it is remembered.
    var warmMadeHook: (() -> Void)?
    var planeTrimEpochForTests: UInt64 { planeLock.withLock { planeTrimEpoch } }

    /// Tests: renders counted by the plane memo, textures made by draws and by warms.
    var planeCountersForTests: [UInt64] { planeLock.withLock { [planeGeneration, UInt64(planeCreates), UInt64(planeWarms)] } }

    var rememberedPlaneCount: Int {
        planeLock.lock(); defer { planeLock.unlock() }
        return planeMemo.count
    }

    deinit {
        // The memo's textures go before their caches (see `Retainer`).
        withExtendedLifetime((textureCache, warmCache)) { planeMemo.removeAll() }
    }

    /// Converts both frames to RGB, takes both to working-linear (the layer's color pipeline, or the inverse BT.709 OETF without
    /// one) and mixes them there into one pooled intermediate, so the blend is a light-linear mix like the compositor's own maths
    /// and playback and export agree. nil when the second frame has another size or format family, or anything fails: the
    /// layer then shows its first frame. The result is working-linear: draw it with `linearize = 0`.
    private func blendIntermediate(a: (MTLTexture, MTLTexture), b: FrameBlend, info: PixelFormatInfo, u: Uniforms, pipeline: ColorPipeline?,
                                   width w: Int, height h: Int, commandBuffer: MTLCommandBuffer, retainer: Retainer) -> MTLTexture? {
        let pb = b.next.pixelBuffer
        guard CVPixelBufferGetWidth(pb) == w, CVPixelBufferGetHeight(pb) == h,
              PixelFormats.info(for: CVPixelBufferGetPixelFormatType(pb))?.layout == info.layout,
              let b0 = planeTexture(pb, plane: 0, format: info.yFormat, retainer: retainer),
              info.singlePlane || planeTexture(pb, plane: 1, format: info.cbcrFormat, retainer: retainer) != nil,
              let ma = acquireIntermediate(width: w, height: h) else { return nil }
        guard let mb = acquireIntermediate(width: w, height: h) else { releaseIntermediates([ma]); return nil }
        guard let mc = acquireIntermediate(width: w, height: h) else { releaseIntermediates([ma, mb]); return nil }
        guard let b1 = info.singlePlane ? dummy : retainer.textures.last.flatMap({ CVMetalTextureGetTexture($0) }) else {
            releaseIntermediates([ma, mb, mc]); return nil
        }
        retainer.pooled.append(ma); retainer.pooled.append(mb); retainer.pooled.append(mc)
        guard let enc = computeEncoder(commandBuffer) else { return nil }
        let tg = MTLSize(width: 16, height: 16, depth: 1), grid = MTLSize(width: w, height: h, depth: 1)
        var cu = u
        enc.setComputePipelineState(convertPipeline)
        enc.setTexture(a.0, index: 0); enc.setTexture(a.1, index: 1); enc.setTexture(ma, index: GPUBinding.metalOutputIndex)
        enc.setBytes(&cu, length: MemoryLayout<Uniforms>.stride, index: 0)
        var cv = ConvertUniforms(origin: .zero, transfer: UInt32.max)   // full size: the half-size average is not used
        enc.setBytes(&cv, length: MemoryLayout<ConvertUniforms>.stride, index: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        // The second frame's own alpha mode (same layout, but the tag could differ in theory).
        cu.alphaMode = Self.alphaMode(of: pb, info: info)
        enc.setBytes(&cu, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setTexture(b0, index: 0); enc.setTexture(b1, index: 1); enc.setTexture(mb, index: GPUBinding.metalOutputIndex)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        // Optical flow: the motion is measured on the source pictures, before any grade changes them (cached per pair).
        let field = b.flow.flatMap { req in flowEngine().flatMap { $0.field(a: ma, b: mb, request: req, commandBuffer: commandBuffer) } }
        var linearize: UInt32 = 1
        if let pipeline {
            let turned = u.quarter & 1 == 1
            guard (try? colorGPU.encode(pipeline, source: ma, destination: ma, commandBuffer: commandBuffer, quarterTurned: turned)) != nil,
                  (try? colorGPU.encode(pipeline, source: mb, destination: mb, commandBuffer: commandBuffer, quarterTurned: turned)) != nil else { return nil }
            linearize = 0
        }
        if let field, let engine = flowEngine() {
            engine.encodeInterpolation(a: ma, b: mb, field: field, t: b.weight, linearize: linearize != 0, into: mc,
                                       commandBuffer: commandBuffer)
            return mc
        }
        kernels.blendFrames(gpu.wrap(commandBuffer), MetalGPUTexture(ma), MetalGPUTexture(mb), into: MetalGPUTexture(mc),
                            weight: b.weight, encoded: linearize != 0)
        return mc
    }

    /// The optical-flow engine, built on first use (its kernels are the renderer's). Optional for callers that fall back
    /// to the plain frame blend.
    func flowEngine() -> OpticalFlowEngine? {
        flowLock.lock(); defer { flowLock.unlock() }
        if let e = flowEngineStorage { return e }
        flowEngineStorage = OpticalFlowEngine(gpu: gpu, kernels: kernels)
        return flowEngineStorage
    }

    /// `Uniforms.alphaMode` of a decoded frame. Alpha video ('y416') follows its `kCVImageBufferAlphaChannelModeKey` tag
    /// (untagged = straight, as SQMedia infers for ProRes 4444); BGRA is premultiplied (stills, legacy 0) unless tagged straight.
    static func alphaMode(of pb: CVPixelBuffer, info: PixelFormatInfo) -> UInt32 {
        let tag = CVBufferCopyAttachment(pb, kCVImageBufferAlphaChannelModeKey, nil) as? String
        let premultiplied = tag == kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String
        let straight = tag == kCVImageBufferAlphaChannelMode_StraightAlpha as String
        switch info.layout {
        case .ayuv16: return premultiplied ? 2 : 1
        case .bgra8: return straight ? 1 : 0
        case .biplanarYCbCr: return 0
        }
    }

    /// `alphaMode` of the straight-alpha intermediate (color stage, frame blend) made from a source with `source`: alpha
    /// sources keep the premultiplied filter (1); opaque and untagged ones (0) stay on the hardware-sampled path.
    static func intermediateAlphaMode(source: UInt32) -> UInt32 { source == 0 ? 0 : 1 }

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

    /// Returns textures to the free pool. The pool is capped by bytes, not count (a long blur's pre-pass texture can be
    /// nine canvases): the oldest go first, and one texture larger than the cap is never kept.
    func releaseIntermediates(_ textures: [MTLTexture]) {
        queueLock.lock()
        let limit = intermediatePoolByteLimit
        for t in textures where Self.bytes(t) <= limit { freeIntermediates.append(t) }
        var total = freeIntermediates.reduce(0) { $0 + Self.bytes($1) }
        var drop = 0
        while total > limit, drop < freeIntermediates.count { total -= Self.bytes(freeIntermediates[drop]); drop += 1 }
        freeIntermediates.removeFirst(drop)
        queueLock.unlock()
    }

    private static func bytes(_ t: MTLTexture) -> Int { t.width * t.height * 8 }     // rgba16Float

    /// Q-PERF2 rec 5: drops free pooled intermediates (oldest first) until at most `bytes` remain, and flushes the
    /// CVMetalTexture cache. Memory pressure (warning: 256 MB, critical: 0) and a long idle call it. In-flight textures
    /// are not in the free pool, so nothing the GPU still uses is touched. Any thread.
    public func trimIntermediatePool(toBytes bytes: Int) {
        queueLock.lock()
        var total = freeIntermediates.reduce(0) { $0 + Self.bytes($1) }
        var drop = 0
        while total > max(0, bytes), drop < freeIntermediates.count { total -= Self.bytes(freeIntermediates[drop]); drop += 1 }
        freeIntermediates.removeFirst(drop)
        queueLock.unlock()
        // The plane memo goes too (its buffers may be ones the frame cache let go); in-flight frames keep their own.
        planeLock.lock()
        var memo = planeMemo
        planeMemo = [:]
        planeTrimEpoch &+= 1
        planeLock.unlock()
        memo.removeAll()        // released before the flushes below, outside the lock
        CVMetalTextureCacheFlush(textureCache, 0)
        warmLock.lock(); CVMetalTextureCacheFlush(warmCache, 0); warmLock.unlock()
        if bytes == 0 { matteLock.lock(); freeMattes.removeAll(); freeMaskBuffers.removeAll(); matteLock.unlock() }
        if bytes == 0 { flowLock.lock(); let e = flowEngineStorage; flowLock.unlock(); e?.trim() }
    }

    /// Bytes held by the free pool (tests).
    var freeIntermediateBytes: Int {
        queueLock.lock(); defer { queueLock.unlock() }
        return freeIntermediates.reduce(0) { $0 + Self.bytes($1) }
    }

    // MARK: Render

    /// Renders layers bottom -> top over an opaque black background. `target`: rgba16Float, sequence size,
    /// `.renderTarget` usage. The caller commits `commandBuffer`; resources are retained until it completes.
    public func render(_ layers: [RenderLayer], format: SequenceFormat, into target: MTLTexture,
                       commandBuffer: MTLCommandBuffer) throws {
        try render(nodes: layers.map { .layer($0) }, format: format, into: target, commandBuffer: commandBuffer)
    }

    /// What the bottom layer composites over: opaque black (monitor, normal export) or transparent (alpha export: the
    /// target then holds premultiplied working-linear color with the coverage in alpha).
    public enum Background: Sendable { case black, transparent }

    /// Tree variant: groups are composited recursively into pooled offscreen textures that stay reserved until the
    /// command buffer completes (so no in-flight texture is ever reused), then returned to the pool.
    public func render(nodes: [RenderNode], format: SequenceFormat, into target: MTLTexture,
                       commandBuffer: MTLCommandBuffer, background: Background = .black) throws {
        guard target.pixelFormat == .rgba16Float else { throw CompositorError.invalidTarget("pixel format must be rgba16Float") }
        guard target.usage.contains(.renderTarget) else { throw CompositorError.invalidTarget("needs .renderTarget usage") }
        guard target.width == format.width, target.height == format.height else {
            throw CompositorError.invalidTarget("size \(target.width)x\(target.height) != sequence \(format.width)x\(format.height)")
        }
        if partCheckWanted { settlePartRead() }
        let retainer = Retainer(caches: [textureCache, warmCache])
        retainer.evicted = advancePlaneMemo()
        try encode(nodes, format: format, into: target, commandBuffer: commandBuffer, retainer: retainer,
                   clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: background == .black ? 1 : 0))
        let pooled = retainer.pooled
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.releaseIntermediates(pooled)
            self?.releaseMasks(retainer.mattes, buffers: retainer.maskBuffers)
        }
    }

    private func encode(_ nodes: [RenderNode], format: SequenceFormat, into target: MTLTexture, commandBuffer: MTLCommandBuffer,
                        retainer: Retainer, clear: MTLClearColor, additiveOnto: Bool = false) throws {
        var prepared: [Prepared] = []
        let scoped = try encodePictureMattes(nodes, format: format, commandBuffer: commandBuffer, retainer: retainer)
        defer { if scoped { retainer.pictureScopes.removeLast() } }
        for node in nodes {
            try queue(node, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
        }
        try drawPrepared(prepared, into: target, commandBuffer: commandBuffer, clear: clear, additiveOnto: additiveOnto)
    }

    /// C6: renders this node list's `.pictureMatte` nodes, each into a pooled transparent image of `format` (the level's
    /// canvas), and pushes them as the current Picture scope: on top of the enclosing one for a live list, or alone (possibly
    /// empty) for a list headed by `.pictureScope` (a held transition side reads only its own held-time mattes). true = a
    /// scope was pushed (the caller pops it). A matte's own layers read no Picture mattes.
    private func encodePictureMattes(_ nodes: [RenderNode], format: SequenceFormat, commandBuffer: MTLCommandBuffer,
                                     retainer: Retainer) throws -> Bool {
        let isolated = nodes.contains { if case .pictureScope = $0 { true } else { false } }
        let base = isolated ? [:] : (retainer.pictureScopes.last ?? [:])
        var scope: [Track.ID: MTLTexture]? = isolated ? [:] : nil
        for node in nodes {
            guard case .pictureMatte(let track, let children) = node else { continue }
            guard let tex = acquireIntermediate(width: format.width, height: format.height) else {
                throw CompositorError.resourceAllocation
            }
            retainer.pooled.append(tex)
            retainer.pictureScopes.append([:])
            defer { retainer.pictureScopes.removeLast() }
            try encode(children, format: format, into: tex, commandBuffer: commandBuffer, retainer: retainer,
                       clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
            if scope == nil { scope = base }
            scope?[track] = tex
            pictureMattePasses += 1
        }
        guard let scope else { return false }
        retainer.pictureScopes.append(scope)
        return true
    }

    /// Prepares the draw(s) of one node, in order.
    private func queue(_ node: RenderNode, format: SequenceFormat, commandBuffer: MTLCommandBuffer, retainer: Retainer,
                       into prepared: inout [Prepared]) throws {
        switch node {
        case .layer(let layer) where layer.stencil:
            var inner = layer
            let opacity = min(1, max(0, inner.transform.opacity))
            inner.transform.opacity = 1; inner.footageFill = nil; inner.blendMode = .normal
            try queue(.stencil(opacity: opacity, children: [.layer(inner)]), format: format, commandBuffer: commandBuffer,
                      retainer: retainer, into: &prepared)
        case .layer(let layer):
            var base: [Prepared] = []
            prepareLayer(layer, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &base)
            for p in base {
                finishLayer(p, layer: layer, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
            }
        case .group(let gf, let transform, let opacity, let radius, let children):
            try encodeGroup(gf, transform, opacity, radius, children, effects: .none, blend: .normal, format: format,
                            commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
        case .styledGroup(let gf, let transform, let opacity, let radius, let children, let fx, let blend):
            try encodeGroup(gf, transform, opacity, radius, children, effects: fx, blend: blend, format: format,
                            commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
        case .pair(let pf, let first, let second):
            guard let tex = acquireIntermediate(width: pf.width, height: pf.height) else { throw CompositorError.resourceAllocation }
            retainer.pooled.append(tex)
            let clearAll = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            try encode(first, format: pf, into: tex, commandBuffer: commandBuffer, retainer: retainer, clear: clearAll)
            try encode(second, format: pf, into: tex, commandBuffer: commandBuffer, retainer: retainer, clear: clearAll,
                       additiveOnto: true)
            var u = Uniforms()
            u.mode = 3
            geometry(&u, transform: .identity, canvas: format.storedPixels, size: SIMD2(Float(pf.width), Float(pf.height)))
            prepared.append(Prepared(u: u, tex0: tex, tex1: dummy))
        case .transition(let pf, let render, let first, let second):
            // Fused: the final draw computes the mix (same bits, no mix texture). Needs the transition canvas to be the
            // target, pixel for pixel; a blend mode (`.blended`) turns it back into a mix texture (`materialiseMix`).
            let fuses = fusesTransitionMix && pf.width == format.width && pf.height == format.height
            var texs: [MTLTexture] = []
            for _ in 0..<2 {
                guard let t = acquireIntermediate(width: pf.width, height: pf.height) else {
                    releaseIntermediates(texs); throw CompositorError.resourceAllocation
                }
                texs.append(t)
            }
            retainer.pooled += texs
            let clearAll = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            try encode(first, format: pf, into: texs[0], commandBuffer: commandBuffer, retainer: retainer, clear: clearAll)
            try encode(second, format: pf, into: texs[1], commandBuffer: commandBuffer, retainer: retainer, clear: clearAll)
            var tu = TransitionUniforms(render)
            let canvas = SIMD2(Float(pf.width), Float(pf.height))
            let group = MTLSize(width: 16, height: 16, depth: 1)
            var sides: [MTLTexture] = [texs[0], texs[1]]
            // A side that asks for mirrored edges is measured first: any pixel below full alpha (a hole, a small or moved
            // clip, a see-through one) turns the mirror off for that side, deterministically.
            var cover: MTLBuffer? = nil
            let mirrored = [tu.a.mirror > 0.5 && tu.a.opacity > 0, tu.b.mirror > 0.5 && tu.b.opacity > 0]
            if mirrored[0] || mirrored[1] {
                var ones: [UInt32] = [Float(1).bitPattern, Float(1).bitPattern]
                guard let cb = device.makeBuffer(bytes: &ones, length: 8, options: .storageModeShared),
                      let ce = computeEncoder(commandBuffer) else { throw CompositorError.resourceAllocation }
                ce.setComputePipelineState(transitionCoverPipeline)
                ce.setBuffer(cb, offset: 0, index: 2)
                for (i, on) in mirrored.enumerated() where on {
                    var slot = SIMD4<UInt32>(UInt32(i), 0, 0, 0)
                    ce.setTexture(texs[i], index: 0)
                    ce.setBytes(&slot, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 0)
                    // Whole 16 x 16 groups: the kernel's group minimum needs every thread (extra ones count as opaque).
                    ce.dispatchThreads(MTLSize(width: (pf.width + 15) / 16 * 16, height: (pf.height + 15) / 16 * 16, depth: 1),
                                       threadsPerThreadgroup: group)
                }
                ce.endEncoding()
                cover = cb
            }
            var enc: MTLComputeCommandEncoder?
            for (i, pre) in [tu.a.splitLongBlur(canvas: canvas), tu.b.splitLongBlur(canvas: canvas)].enumerated() {
                guard var (side, needed) = pre else { continue }
                let target = Self.longBlurTarget(width: pf.width, height: pf.height, pad: needed, maxSide: maxIntermediateSide)
                var pad = target.pad
                let bw = target.width, bh = target.height
                // This side samples the grown canvas at the bucketed pad's scale.
                if i == 0 { tu.a.scale = 1 + 2 * pad } else { tu.b.scale = 1 + 2 * pad }
                guard let t = acquireIntermediate(width: bw, height: bh) else {
                    enc?.endEncoding(); throw CompositorError.resourceAllocation
                }
                retainer.pooled.append(t)
                if enc == nil { enc = computeEncoder(commandBuffer) }
                guard let enc else { throw CompositorError.resourceAllocation }
                // Both passes address the grown canvas in normalized coordinates, so whole-pixel rounding moves nothing.
                var pre = PreBlurUniforms(canvas: canvas, pad: pad, slot: UInt32(i))
                enc.setComputePipelineState(transitionPreBlurPipeline)
                enc.setTexture(sides[i], index: 0); enc.setTexture(t, index: GPUBinding.metalOutputIndex)
                enc.setBytes(&side, length: MemoryLayout<TransitionSideUniforms>.stride, index: 0)
                enc.setBytes(&pre, length: MemoryLayout<PreBlurUniforms>.stride, index: 1)
                enc.setBuffer(cover ?? coverNeutral, offset: 0, index: 2)
                enc.dispatchThreads(MTLSize(width: bw, height: bh, depth: 1), threadsPerThreadgroup: group)
                sides[i] = t
            }
            enc?.endEncoding()
            var u = Uniforms()
            u.mode = 3
            geometry(&u, transform: .identity, canvas: format.storedPixels, size: canvas)   // target pixels: the mix reads them
            var p = Prepared(u: u, tex0: sides[0], tex1: sides[1])
            p.mix = tu
            p.cover = cover
            if !fuses { try materialiseMix(&p, size: pf, commandBuffer: commandBuffer, retainer: retainer) }
            prepared.append(p)
        case .adjustment(let a, let below):
            try encodeAdjustment(a, below: below, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
        case .stencil(let opacity, let children):
            guard let tex = acquireIntermediate(width: format.width, height: format.height) else {
                throw CompositorError.resourceAllocation
            }
            retainer.pooled.append(tex)
            try encode(children, format: format, into: tex, commandBuffer: commandBuffer, retainer: retainer,
                       clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
            var u = Uniforms()
            u.mode = 3
            geometry(&u, transform: .identity, canvas: format.storedPixels, size: SIMD2(Float(format.width), Float(format.height)))
            u.opacity = Float(opacity)
            var p = Prepared(u: u, tex0: tex, tex1: dummy)
            p.stencil = true
            prepared.append(p)
        case .pictureMatte, .pictureScope:
            break       // rendered by `encodePictureMattes` before this list's draws; never drawn itself
        case .blended(let inner, let mode):
            // The inner node (a pair's summed image, say) is composited with `mode` against what is below.
            let n = prepared.count
            try queue(inner, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
            if prepared.count > n {
                // The blending draw reads one texture: a fused transition gets its mix texture back.
                let last = prepared.count - 1
                if mode != .normal, blendPipeline != nil, prepared[last].mix != nil {
                    try materialiseMix(&prepared[last], size: format, commandBuffer: commandBuffer, retainer: retainer)
                }
                prepared[last].blend = mode
            }
        }
    }

    /// Runs a transition draw's mix kernel into a pooled texture of `size` (the transition canvas) and makes `p` a plain
    /// draw of it.
    private func materialiseMix(_ p: inout Prepared, size: SequenceFormat, commandBuffer: MTLCommandBuffer,
                                retainer: Retainer) throws {
        guard var tu = p.mix else { return }
        guard let out = acquireIntermediate(width: size.width, height: size.height) else { throw CompositorError.resourceAllocation }
        retainer.pooled.append(out)
        guard let enc = computeEncoder(commandBuffer) else { throw CompositorError.resourceAllocation }
        enc.setComputePipelineState(transitionPipeline)
        enc.setTexture(p.tex0, index: 0); enc.setTexture(p.tex1, index: 1); enc.setTexture(out, index: GPUBinding.metalOutputIndex)
        enc.setBytes(&tu, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
        enc.setBuffer(p.cover ?? coverNeutral, offset: 0, index: 2)
        enc.dispatchThreads(MTLSize(width: size.width, height: size.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        p.tex0 = out; p.tex1 = dummy; p.mix = nil; p.cover = nil
    }

    /// Adjustment Layer: composites `below` into one image, optionally queues it plainly, then queues it graded, with the
    /// effects, Motion (or the mean of its sub-frame copies), opacity and blend mode.
    private func encodeAdjustment(_ a: AdjustmentNode, below: [RenderNode], format: SequenceFormat, commandBuffer: MTLCommandBuffer,
                                  retainer: Retainer, into prepared: inout [Prepared]) throws {
        guard let tex = acquireIntermediate(width: format.width, height: format.height) else {
            throw CompositorError.resourceAllocation
        }
        retainer.pooled.append(tex)
        let clearAll = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        try encode(below, format: format, into: tex, commandBuffer: commandBuffer, retainer: retainer, clear: clearAll)
        let size = SIMD2(Float(format.displayWidth), Float(format.height))
        var plain = Uniforms()
        plain.mode = 3
        geometry(&plain, transform: .identity, canvas: format, size: size)
        if a.drawsBase { prepared.append(Prepared(u: plain, tex0: tex, tex1: dummy)) }     // the unadjusted picture
        // What the effects read: the composite (premultiplied working-linear), or its graded copy (straight working-linear).
        var src = Prepared(u: plain, tex0: tex, tex1: dummy)
        if let pipeline = a.colorPipeline,
           let graded = gradeAdjustmentInput(tex, pipeline: pipeline, commandBuffer: commandBuffer, retainer: retainer) {
            src.tex0 = graded; src.u.mode = 1; src.u.linearize = 0; src.u.alphaMode = 1
        }
        let factor = Self.radiusFactor(format.displayWidth, format.height, canvas: format)
        let styled = RenderLayer(content: .placeholder(.loading), cornerRadius: a.cornerRadius, effects: a.effects,
                                 blendMode: a.blendMode)
        func adjusted(_ t: ClipTransform, opacity: Double) -> Prepared {
            var p = src
            geometry(&p.u, transform: t, canvas: format, size: size, cornerRadius: a.cornerRadius * factor)
            p.u.opacity = Float(opacity)
            p.radiusFactor = factor
            return p
        }
        guard a.motionSamples.count > 1 else {
            finishLayer(adjusted(a.transform, opacity: a.opacity), layer: styled, format: format, commandBuffer: commandBuffer,
                        retainer: retainer, into: &prepared)
            return
        }
        // Motion blur: the copies at 1/n each, summed as premultiplied color in one transparent image (like
        // `RenderNode.motionBlurred`), which is then drawn with the opacity and blend mode.
        guard let sum = acquireIntermediate(width: format.width, height: format.height) else {
            throw CompositorError.resourceAllocation
        }
        retainer.pooled.append(sum)
        var normal = styled
        normal.blendMode = .normal
        let n = Double(a.motionSamples.count)
        for (k, t) in a.motionSamples.enumerated() {
            var copy: [Prepared] = []
            finishLayer(adjusted(t, opacity: 1 / n), layer: normal, format: format, commandBuffer: commandBuffer,
                        retainer: retainer, into: &copy)
            try drawPrepared(copy, into: sum, commandBuffer: commandBuffer, clear: clearAll, additiveOnto: k > 0)
        }
        var u = plain
        u.opacity = Float(a.opacity)
        var p = Prepared(u: u, tex0: sum, tex1: dummy)
        p.blend = a.blendMode
        prepared.append(p)
    }

    /// The Adjustment Layer's grade input: premultiplied working-linear -> straight BT.709-encoded (a Rec.709 source for the
    /// chain), then `ColorPipelineGPU` -> straight working-linear. nil when anything fails (the picture is then ungraded).
    private func gradeAdjustmentInput(_ tex: MTLTexture, pipeline: ColorPipeline, commandBuffer: MTLCommandBuffer,
                                      retainer: Retainer) -> MTLTexture? {
        guard let mid = acquireIntermediate(width: tex.width, height: tex.height) else { return nil }
        retainer.pooled.append(mid)
        kernels.encode709(gpu.wrap(commandBuffer), MetalGPUTexture(tex), into: MetalGPUTexture(mid))
        guard (try? colorGPU.encode(pipeline, source: mid, destination: mid, commandBuffer: commandBuffer)) != nil else { return nil }
        return mid
    }

    /// A Color effect with a mask input (`EffectSegment.grade`) on an effect-chain image `tex` (premultiplied
    /// working-linear): graded like an Adjustment Layer's input (BT.709-encoded in, that effect's ops after the Rec.709
    /// conversion), premultiplied again into a new texture. `tex` is untouched (the mask scope's "before"). LUTs of a masked
    /// Color effect come from `colorResolver` (playback: cached, loaded in the background; export: loaded inline); without
    /// a resolver they are not applied. nil when anything fails.
    func gradeSegment(_ grade: ColorEffect, _ tex: MTLTexture, commandBuffer: MTLCommandBuffer, retainer: Retainer) -> MTLTexture? {
        let color = Self.maskedGradeColor(grade)
        let resolved: ColorPipeline?
        if let colorResolver {
            let owner = Self.maskedGradeOwner(grade)
            resolved = colorResolverBlocks
                ? colorResolver.pipelineBlocking(for: color, media: Self.maskedGradeMedia, owner: owner)
                : colorResolver.pipeline(for: color, media: Self.maskedGradeMedia, owner: owner)
        } else {
            let p = ColorPipeline.from(clipColor: color, mediaID: Self.maskedGradeMedia, mediaInfo: nil, lutProvider: nil)
            resolved = p.isIdentity ? nil : p
        }
        guard let pipeline = resolved, !pipeline.isIdentity,
              let mid = gradeAdjustmentInput(tex, pipeline: pipeline, commandBuffer: commandBuffer, retainer: retainer),
              let out = acquireIntermediate(width: tex.width, height: tex.height) else { return nil }
        retainer.pooled.append(out)
        kernels.premultiply(gpu.wrap(commandBuffer), MetalGPUTexture(mid), into: MetalGPUTexture(out))
        return out
    }

    /// Composites a nested sequence's children into an offscreen image and queues it as one layer, with the nested clip's effects.
    private func encodeGroup(_ gf: SequenceFormat, _ transform: ClipTransform, _ opacity: Double, _ radius: Double,
                             _ children: [RenderNode], effects: ClipEffects, blend: BlendMode, format: SequenceFormat,
                             commandBuffer: MTLCommandBuffer, retainer: Retainer, into prepared: inout [Prepared]) throws {
        guard let tex = acquireIntermediate(width: gf.width, height: gf.height) else {
            throw CompositorError.resourceAllocation
        }
        retainer.pooled.append(tex)
        // A nested level: its Picture masks read only its own mattes.
        retainer.pictureScopes.append([:])
        do {
            defer { retainer.pictureScopes.removeLast() }
            try encode(children, format: gf, into: tex, commandBuffer: commandBuffer, retainer: retainer,
                       clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        }
        var u = Uniforms()
        u.mode = 3
        geometry(&u, transform: transform, canvas: format, size: SIMD2(Float(gf.displayWidth), Float(gf.height)),
                 cornerRadius: radius * Self.radiusFactor(gf.displayWidth, gf.height, canvas: format))
        u.opacity = Float(min(1, max(0, transform.opacity * opacity)))
        var p = Prepared(u: u, tex0: tex, tex1: dummy)
        p.radiusFactor = Self.radiusFactor(gf.displayWidth, gf.height, canvas: format)
        let styled = RenderLayer(content: .placeholder(.loading), cornerRadius: radius, effects: effects, blendMode: blend)
        finishLayer(p, layer: styled, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
    }

    private func drawPrepared(_ prepared: [Prepared], into target: MTLTexture, commandBuffer: MTLCommandBuffer,
                              clear: MTLClearColor, additiveOnto: Bool) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        // `additiveOnto`: keep what is in the target (the first side of a pair) and add this layer list on top.
        pass.colorAttachments[0].loadAction = additiveOnto ? .load : .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        guard let enc = layerEncoder(commandBuffer, pass) else { throw CompositorError.resourceAllocation }
        var current: MTLRenderPipelineState?
        let (tw, th) = (target.width, target.height)
        var limited = false
        for var p in prepared {
            var scissors: [MTLScissorRect]?
            if let c = p.clip {
                let rects = Self.partScissors(c, width: tw, height: th, bands: partBands)
                if rects.isEmpty { continue }   // the part lies off the canvas
                scissors = rects
                limited = true
            } else if limited {
                enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: tw, height: th))
                limited = false
            }
            // Blend modes need the destination: the programmable-blending pipeline for those draws, plain alpha-over otherwise.
            // A fused transition (`mix`) computes its mix in the fragment (never blended: `.blended` materialises it).
            let wantsBlend = (p.blend != .normal || p.stencil) && blendPipeline != nil && p.mix == nil
            let state: MTLRenderPipelineState
            if wantsBlend { state = blendPipeline! }
            else if p.mix != nil { state = additiveOnto ? transitionFusedAdditivePipeline : transitionFusedPipeline }
            else { state = additiveOnto ? additivePipeline : renderPipeline }
            if state !== current { enc.setRenderPipelineState(state); current = state }
            p.u.blend = wantsBlend ? (p.stencil ? BlendModes.stencilShaderID : BlendModes.shaderID(p.blend)) : 0
            bindLayer(enc, &p.u, p.tex0, p.tex1, maskData: p.maskData, matte: p.matteTex, picture0: p.picture0, picture1: p.picture1)
            if var tu = p.mix {
                // LayerTransition.slang: the transition at buffer 1, the sides' cover in place of the mask data.
                enc.setFragmentBytes(&tu, length: MemoryLayout<TransitionUniforms>.stride, index: 1)
                enc.setFragmentBuffer(p.cover ?? coverNeutral, offset: 0, index: 2)
                fusedTransitionDraws += 1
            }
            guard let scissors else {
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                continue
            }
            // The same quad once per rectangle: the same fragments with the same values, only fewer of them.
            for r in scissors {
                enc.setScissorRect(r)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        enc.endEncoding()
    }

    /// The whole picture of a partial buffer (`RenderLayer.contentPart`): a pooled texture of the whole size, cleared,
    /// with the buffer's texels copied to their place (a blit: no sampling, the same bits). One per buffer and render.
    /// nil when the part does not lie inside the whole picture or no texture could be made (drawn as damaged).
    private func wholeTexture(_ pb: CVPixelBuffer, _ t: MTLTexture, _ part: RenderLayer.ContentPart,
                              commandBuffer: MTLCommandBuffer, retainer: Retainer) -> MTLTexture? {
        let key = ObjectIdentifier(pb)
        if let made = retainer.wholes[key], made.part == part { return made.texture }
        guard part.holds(width: t.width, height: t.height),
              let whole = acquireIntermediate(width: part.wholeWidth, height: part.wholeHeight) else { return nil }
        retainer.pooled.append(whole)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = whole
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let clear = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        clear.endEncoding()
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: t.width, height: t.height, depth: 1),
                  to: whole, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: part.x, y: part.y, z: 0))
        blit.endEncoding()
        retainer.wholes[key] = (part, whole)
        partialContentFills += 1
        return whole
    }

    /// A 2 x 2 BGRA frame of one display-encoded color, kept for the last few colors.
    private var solidFrames: [SIMD3<UInt8>: CVPixelBuffer] = [:]
    private func solidFrame(_ r: Float, _ g: Float, _ b: Float) -> CVPixelBuffer? {
        func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        let key = SIMD3(byte(r), byte(g), byte(b))
        if let pb = solidFrames[key] { return pb }
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        guard CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<2 { for x in 0..<2 {
            let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            p[0] = key.z; p[1] = key.y; p[2] = key.x; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if solidFrames.count >= 8 { solidFrames.removeAll() }
        solidFrames[key] = pb
        return pb
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
                         size: SIMD2(Float(format.displayWidth), Float(format.height)), cornerRadius: layer.cornerRadius)
                prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
            case .solid(let r, let g, let b):
                // A graded solid (Color Matte with Lumetri) runs the picture path on a tiny flat frame stretched to the
                // canvas, so viewer and export grade it with the same code. An ungraded one stays a plain fill.
                if layer.colorPipeline != nil, let pb = solidFrame(r, g, b) {
                    var framed = layer
                    framed.content = .frame(pb, colorHint: VideoTrackInfo(width: 2, height: 2, codec: "bgra", bitDepth: 8, chroma: "4:4:4",
                                                                          nominalFrameDuration: Time(1, 25), isVariableFrameRate: false))
                    framed.nativeSize = (format.displayWidth, format.height)
                    prepareLayer(framed, format: format, commandBuffer: commandBuffer, retainer: retainer, into: &prepared)
                    return
                }
                u.mode = 2; u.solid = SIMD4(Self.lin(r), Self.lin(g), Self.lin(b), 1)
                geometry(&u, transform: layer.transform, canvas: format,
                         size: SIMD2(Float(format.displayWidth), Float(format.height)), cornerRadius: layer.cornerRadius)
                prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
            case .linearPremultiplied(let raster, let w, let h):
                let pb = raster.pixelBuffer
                let direct = drawsContentPartsDirectly && partRead == .trusted
                if drawsContentPartsDirectly, partRead == .unchecked, layer.contentPart != nil { partCheckWanted = true }
                guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf,
                      let part = planeTexture(pb, plane: 0, format: .rgba16Float, retainer: retainer),
                      let t0 = layer.contentPart == nil ? part
                        : direct ? (layer.contentPart!.holds(width: part.width, height: part.height) ? part : nil)
                        : wholeTexture(pb, part, layer.contentPart!, commandBuffer: commandBuffer, retainer: retainer) else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.displayWidth), Float(format.height)), cornerRadius: layer.cornerRadius)
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    return
                }
                u.mode = 3
                var clip: [SIMD2<Double>]?
                if direct, let cp = layer.contentPart {
                    u.part = SIMD4(Float(cp.x) + partReadSkew.x, Float(cp.y) + partReadSkew.y, Float(cp.wholeWidth), Float(cp.wholeHeight))
                    partialContentDraws += 1
                    // Nothing reads the layer's rectangle (plain alpha-over of a picture that is transparent outside
                    // the part): only the fragments the part can reach are drawn, not the whole box.
                    if layer.cornerRadius == 0, layer.effects == .none, layer.blendMode == .normal {
                        clip = Self.partCorners(cp, width: part.width, height: part.height, size: SIMD2(w, h),
                                                transform: layer.transform, canvas: format)
                    }
                }
                geometry(&u, transform: layer.transform, canvas: format, size: SIMD2(Float(w), Float(h)),
                         cornerRadius: layer.cornerRadius)
                prepared.append(Prepared(u: u, tex0: t0, tex1: dummy, clip: clip))
            case .frame(let source, let hint):
                let pb = source.pixelBuffer
                guard let info = PixelFormats.info(for: CVPixelBufferGetPixelFormatType(pb)) else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.displayWidth), Float(format.height)), cornerRadius: layer.cornerRadius)
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    return
                }
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                let quarter = UInt32((hint.rotation / 90) & 3)
                let (nw, nh) = layer.nativeSize ?? (w, h)
                let (dw, dh) = quarter & 1 == 1 ? (nh, nw) : (nw, nh)     // upright size after the turn
                guard let t0 = planeTexture(pb, plane: 0, format: info.yFormat, retainer: retainer),
                      info.singlePlane || planeTexture(pb, plane: 1, format: info.cbcrFormat, retainer: retainer) != nil
                else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.displayWidth), Float(format.height)), cornerRadius: layer.cornerRadius)
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    return
                }
                guard let t1 = info.singlePlane ? dummy : retainer.textures.last.flatMap({ CVMetalTextureGetTexture($0) }) else {
                    unsupportedFrameCount += 1
                    u.mode = 2; u.solid = Self.placeholderLinear(.damaged)
                    geometry(&u, transform: layer.transform, canvas: format,
                             size: SIMD2(Float(format.displayWidth), Float(format.height)), cornerRadius: layer.cornerRadius)
                    prepared.append(Prepared(u: u, tex0: dummy, tex1: dummy))
                    return
                }
                u.mode = info.layout == .bgra8 ? 1 : info.layout == .ayuv16 ? 4 : 0
                u.alphaMode = Self.alphaMode(of: pb, info: info)
                u.m = PixelFormats.ycbcrToRGB(PixelFormats.matrix(tag: hint.matrix))
                u.range = PixelFormats.rangeParams(info)
                u.quarter = quarter
                geometry(&u, transform: layer.transform, canvas: format, size: SIMD2(Float(dw), Float(dh)),
                         cornerRadius: layer.cornerRadius * Self.radiusFactor(dw, dh, canvas: format))
                var p = Prepared(u: u, tex0: t0, tex1: t1)
                p.radiusFactor = Self.radiusFactor(dw, dh, canvas: format)
                var blended: MTLTexture?
                if let tf = layer.temporal, !tf.filter.isIdentity,
                   let mid = temporalIntermediate(center: (t0, t1), frames: tf, info: info, u: u, pipeline: layer.colorPipeline,
                                                  width: w, height: h, commandBuffer: commandBuffer, retainer: retainer) {
                    blended = mid
                    p.u.mode = 1; p.tex0 = mid; p.tex1 = dummy; p.u.linearize = 0     // already working-linear
                    p.u.alphaMode = Self.intermediateAlphaMode(source: u.alphaMode)
                } else if let b = layer.blend, b.weight > 0,
                   let mid = blendIntermediate(a: (t0, t1), b: b, info: info, u: u, pipeline: layer.colorPipeline, width: w, height: h,
                                               commandBuffer: commandBuffer, retainer: retainer) {
                    blended = mid
                    p.u.mode = 1; p.tex0 = mid; p.tex1 = dummy; p.u.linearize = 0     // already working-linear
                    p.u.alphaMode = Self.intermediateAlphaMode(source: u.alphaMode)
                }
                if blended != nil {
                } else if let pipeline = layer.colorPipeline {
                    // Less work, same picture size on the canvas (see `colorWork`): only the visible part of the source,
                    // and at half resolution when the layer is shown at half size or less.
                    let texelsPerNative: Float = nw > 0 ? Float(w) / Float(nw) : 1
                    let pointwise = gradesAtDisplaySize && Self.isPointwise(pipeline, effects: layer.effects)
                    // Log and PQ: scaled after the tone map (the conversion runs per source sample), once its kernel
                    // is compiled; until then at full size.
                    let toneKernels = pointwise && tonesBeforeDisplayScale && !Self.averagesBeforeGrading(pipeline.source)
                        ? colorGPU.toneFirstKernels(for: pipeline) : nil
                    let toneFirst = toneKernels != nil
                    let display = pointwise
                        ? Self.displayColorWork(canvas: u.canvas, transform: layer.transform, size: u.size, texture: (w, h),
                                                texelsPerNativePixel: texelsPerNative, quarter: quarter,
                                                halves: toneFirst || Self.averagesBeforeGrading(pipeline.source))
                        : nil
                    let work = display ?? (limitsColorWork
                        ? Self.colorWork(canvas: u.canvas, transform: layer.transform, size: u.size, texture: (w, h),
                                         texelsPerNativePixel: texelsPerNative, quarter: quarter,
                                         onePass: layer.effects.segments.count <= 1,
                                         strongBlur: layer.effects.segments.count > 1
                                            && Self.effectChainFactor(layer.effects.segments, display: 1) >= 2,
                                         halves: Self.averagesBeforeGrading(pipeline.source))
                        : ColorWork(width: w, height: h, region: SourceRegion(x: 0, y: 0, width: w, height: h)))
                    if let region = work.region, let mid = acquireIntermediate(width: work.width, height: work.height) {
                        retainer.pooled.append(mid)
                        func bindConvert(_ enc: MTLComputeCommandEncoder) {
                            var cu = u
                            // Texture 2 and buffer 2 serve the grade's fused first pass (runtime MSL), texture 25 and
                            // buffer 1 the Slang conversion; buffer 1 starts with the origin both read.
                            enc.setTexture(t0, index: 0); enc.setTexture(t1, index: 1); enc.setTexture(mid, index: 2)
                            enc.setTexture(mid, index: GPUBinding.metalOutputIndex)
                            enc.setBytes(&cu, length: MemoryLayout<Uniforms>.stride, index: 0)
                            // The half-size 2 x 2 average runs in light through the source's own curve.
                            var cv = ConvertUniforms(origin: SIMD2(UInt32(region.x), UInt32(region.y)),
                                                     transfer: ColorPipelineGPU.shaderIndex(pipeline.source))
                            enc.setBytes(&cv, length: MemoryLayout<ConvertUniforms>.stride, index: 1)
                            enc.setBytes(&cv.transfer, length: MemoryLayout<UInt32>.stride, index: 2)
                        }
                        // Conversion fused into the grade's first pass (specialised kernels, same pixels); until those
                        // are compiled, conversion into `mid` and then the generic chain in place.
                        if colorGPU.encodeFused(pipeline, scaled: display != nil, toneFirst: display != nil ? toneKernels : nil,
                                                destination: mid, region: region,
                                                quarterTurned: quarter & 1 == 1, commandBuffer: commandBuffer,
                                                bindConvert: bindConvert) {
                            p.u.mode = 1; p.u.linearize = 0
                            p.u.alphaMode = Self.intermediateAlphaMode(source: u.alphaMode)
                            p.tex0 = mid; p.tex1 = dummy
                        } else if toneFirst && display != nil {
                            // No two-step twin (the generic scaled conversion would average before the tone map). The
                            // kernels were handed in, so the shared store cannot fail this; only an invalid LUT or no
                            // encoder can, and with those the chain cannot run at any size either.
                        } else if let enc = computeEncoder(commandBuffer) {
                            enc.setComputePipelineState(display != nil ? convertScaledPipeline : convertPipeline)
                            bindConvert(enc)
                            let tg = MTLSize(width: 16, height: 16, depth: 1)
                            enc.dispatchThreads(MTLSize(width: region.width, height: region.height, depth: 1), threadsPerThreadgroup: tg)
                            enc.endEncoding()
                            if (try? colorGPU.encode(pipeline, source: mid, destination: mid, commandBuffer: commandBuffer,
                                                     quarterTurned: quarter & 1 == 1, region: region)) != nil {
                                p.u.mode = 1; p.u.linearize = 0
                                p.u.alphaMode = Self.intermediateAlphaMode(source: u.alphaMode)
                                p.tex0 = mid; p.tex1 = dummy
                            }
                        }
                    }
                }
                prepared.append(p)
            }
    }
}
#endif
