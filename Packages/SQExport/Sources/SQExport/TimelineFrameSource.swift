import CoreVideo
import Foundation
import Metal
import SQCore
import SQRender
import SQText

/// A decoded source frame plus what the compositor needs to interpret it.
public struct ProvidedFrame: @unchecked Sendable {
    public var buffer: CVPixelBuffer
    public var info: VideoTrackInfo
    /// Presentation start and duration of this source frame in the media (nil = unknown: no Frame Blending).
    public var start: Time?
    public var duration: Time?
    public init(buffer: CVPixelBuffer, info: VideoTrackInfo, start: Time? = nil, duration: Time? = nil) {
        self.buffer = buffer; self.info = info; self.start = start; self.duration = duration
    }
}

/// Decoded-frame supply for export (the real decoder plugs in with E-03/E-09). Returns nil when the media is
/// offline; the layer is then drawn as the offline placeholder.
public protocol FrameProvider: Sendable {
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame?
}

public enum ExportPixelFormat: Sendable { case bgra8, yuv420v }

/// Carries CoreVideo references across an isolation boundary (they are thread-safe, just not annotated).
struct Box<T>: @unchecked Sendable {
    let buffer: T
    init(_ b: T) { buffer = b }
}

public enum TimelineFrameSourceError: Error, Sendable, Equatable {
    case noMetalDevice, invalidSize, oddDimensionsFor420, commandBufferFailed(String), bufferCreationFailed(Int32)
}

/// Renders timeline frames for export: `Timeline.videoLayers(at:)` -> decoded frames -> `Compositor`
/// (working-linear rgba16Float) -> optional caption burn-in -> BT.709 OETF output pass -> BGRA or 420v buffer
/// tagged 1-1-1. One command buffer per frame; output buffers come from a pool.
public final class TimelineFrameSource: FrameSource {
    public let frameCount: Int
    public let frameDuration: Time
    public let startTime: Time
    public let width: Int, height: Int
    public let pixelFormat: ExportPixelFormat
    private let renderer: Renderer

    /// - Parameters:
    ///   - width/height: output size (the working frame is sequence-sized and resampled if they differ).
    ///   - startTime: timeline time of frame 0 (range start).
    public init(timeline: Timeline, sequences: [Timeline.ID: Timeline] = [:], provider: any FrameProvider, width: Int, height: Int,
                frameDuration: Time, frameCount: Int, startTime: Time = .zero,
                pixelFormat: ExportPixelFormat = .bgra8, captions: CaptionBurnIn? = nil,
                colorResolver: LayerColorResolver? = nil,
                device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw TimelineFrameSourceError.noMetalDevice }
        guard width > 0, height > 0, timeline.format.width > 0, timeline.format.height > 0 else {
            throw TimelineFrameSourceError.invalidSize
        }
        if pixelFormat == .yuv420v, width % 2 != 0 || height % 2 != 0 { throw TimelineFrameSourceError.oddDimensionsFor420 }
        self.frameCount = frameCount; self.frameDuration = frameDuration; self.startTime = startTime
        self.width = width; self.height = height; self.pixelFormat = pixelFormat
        renderer = try Renderer(timeline: timeline, sequences: sequences, provider: provider, width: width, height: height,
                                format: pixelFormat, captions: captions, colorResolver: colorResolver,
                                device: device, queue: queue)
    }

    public func frame(at index: Int) async throws -> CVPixelBuffer {
        guard index >= 0, index < frameCount else { throw FrameSourceError.indexOutOfRange(index) }
        try Task.checkCancellation()
        return try await renderer.render(at: startTime + frameDuration * Int64(index)).buffer
    }

    // MARK: Renderer (serialises compositor use)

    private actor Renderer {
        let timeline: Timeline
        let sequences: [Timeline.ID: Timeline]
        let clipDurations: [Clip.ID: Time]
        let provider: any FrameProvider
        let width: Int, height: Int
        let format: ExportPixelFormat
        let captions: CaptionBurnIn?
        let colorResolver: LayerColorResolver?
        let device: MTLDevice
        let queue: MTLCommandQueue
        let compositor: Compositor
        let cache: CVMetalTextureCache
        let pool: CVPixelBufferPool
        let bgraPipe: MTLComputePipelineState, lumaPipe: MTLComputePipelineState, chromaPipe: MTLComputePipelineState
        var freeWorking: [MTLTexture] = []

        init(timeline: Timeline, sequences: [Timeline.ID: Timeline], provider: any FrameProvider, width: Int, height: Int, format: ExportPixelFormat,
             captions: CaptionBurnIn?, colorResolver: LayerColorResolver?, device: MTLDevice, queue: MTLCommandQueue) throws {
            self.timeline = timeline; self.sequences = sequences; self.provider = provider
            var durations: [Clip.ID: Time] = [:]
            for tl in [timeline] + Array(sequences.values) { for t in tl.tracks { for c in t.clips { durations[c.id] = c.source.duration } } }
            clipDurations = durations; self.width = width; self.height = height
            self.format = format; self.captions = captions; self.colorResolver = colorResolver; self.device = device; self.queue = queue
            compositor = try Compositor(device: device)
            let lib = try device.makeLibrary(source: ExportShaderSource.msl, options: nil)
            func pipe(_ n: String) throws -> MTLComputePipelineState {
                try device.makeComputePipelineState(function: lib.makeFunction(name: n)!)
            }
            bgraPipe = try pipe("encodeBGRA"); lumaPipe = try pipe("encodeLuma"); chromaPipe = try pipe("encodeChroma")
            let usage = MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
            var c: CVMetalTextureCache?
            let cs = CVMetalTextureCacheCreate(nil, nil, device, [kCVMetalTextureUsage: usage] as CFDictionary, &c)
            guard cs == kCVReturnSuccess, let c else { throw TimelineFrameSourceError.bufferCreationFailed(cs) }
            cache = c
            let fmt: OSType = format == .bgra8 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: fmt, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
            var p: CVPixelBufferPool?
            let ps = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &p)
            guard ps == kCVReturnSuccess, let p else { throw TimelineFrameSourceError.bufferCreationFailed(ps) }
            pool = p
        }

        func workingTexture() throws -> MTLTexture {
            if let t = freeWorking.popLast() { return t }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: timeline.format.width,
                                                             height: timeline.format.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw TimelineFrameSourceError.bufferCreationFailed(-1) }
            return t
        }

        func planeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, keep: inout [CVMetalTexture]) throws -> MTLTexture {
            let planar = CVPixelBufferIsPlanar(pb)
            let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
            let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
            var out: CVMetalTexture?
            let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &out)
            guard r == kCVReturnSuccess, let out, let tex = CVMetalTextureGetTexture(out) else {
                throw TimelineFrameSourceError.bufferCreationFailed(r)
            }
            keep.append(out)
            return tex
        }

        func dispatch(_ p: MTLComputePipelineState, src: MTLTexture, dst: MTLTexture, _ cb: MTLCommandBuffer) throws {
            guard let enc = cb.makeComputeCommandEncoder() else { throw TimelineFrameSourceError.commandBufferFailed("encoder") }
            enc.setComputePipelineState(p)
            enc.setTexture(src, index: 0); enc.setTexture(dst, index: 1)
            enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }

        /// Text generator layer: the raster's centre placed relative to the canvas centre; the animation factors
        /// (opacity, scale, offset, rotation) are folded into the layer transform.
        func textLayer(_ l: LayerRequest, _ ref: GeneratorRef) throws -> RenderLayer {
            let dur = clipDurations[l.clip] ?? l.localTime
            guard let f = try TextGenerator.frame(ref: ref, localTime: l.localTime, clipDuration: dur,
                                                  canvas: timeline.format, scale: 1) else {
                var tr = l.transform; tr.opacity = 0
                return RenderLayer(content: .placeholder(.loading), transform: tr)   // empty text: invisible
            }
            let tr = f.layerTransform(base: l.transform, canvas: timeline.format)
            return RenderLayer(content: .linearPremultiplied(f.buffer, width: f.width, height: f.height), transform: tr,
                               cornerRadius: l.cornerRadius)
        }

        /// The layer with the clip's effects (Crop, Rounded Corners, Gaussian Blur) and blend mode attached, like playback.
        func layer(for l: LayerRequest) async throws -> RenderLayer {
            try await baseLayer(for: l).applying(l)
        }

        func baseLayer(for l: LayerRequest) async throws -> RenderLayer {
            if let g = l.generator {
                if g.kind == GeneratorRef.solid { return RenderLayer.solid(payload: g.payload, transform: l.transform) }
                if g.kind == GeneratorRef.text { return try textLayer(l, g) }
                return RenderLayer(content: .placeholder(.offline), transform: l.transform, cornerRadius: l.cornerRadius)
            }
            if let f = try await provider.frame(media: l.media, at: l.sourceTime) {
                // Frame Blending: mix with the next source frame by the fractional source position.
                var blend: FrameBlend?
                if l.interpolation == .frameBlend, let s = f.start, let d = f.duration {
                    let w = FrameBlend.weight(sourceTime: l.sourceTime, frameStart: s, frameDuration: d)
                    if w > 0, l.sourceEnd.map({ s + d < $0 }) ?? true, let n = try await provider.frame(media: l.media, at: s + d), n.buffer !== f.buffer {
                        blend = FrameBlend(next: n.buffer, weight: w)
                    }
                }
                return RenderLayer(content: .frame(f.buffer, colorHint: f.info), transform: l.transform,
                                   colorPipeline: colorResolver?.pipelineBlocking(for: l.color, media: l.media), cornerRadius: l.cornerRadius,
                                   nativeSize: (f.info.width, f.info.height), blend: blend)
            }
            return RenderLayer(content: .placeholder(.offline), transform: l.transform, cornerRadius: l.cornerRadius)
        }

        func render(at t: Time) async throws -> Box<CVPixelBuffer> {
            let requests = timeline.videoLayers(at: t, sequences: { [sequences] in sequences[$0] })
            var layers: [RenderLayer] = []
            for l in requests {
                try Task.checkCancellation()
                layers.append(try await layer(for: l))
            }
            try Task.checkCancellation()

            var out: CVPixelBuffer?
            let st = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard st == kCVReturnSuccess, let out else { throw TimelineFrameSourceError.bufferCreationFailed(st) }
            let working = try workingTexture()
            guard let cb = queue.makeCommandBuffer() else { throw TimelineFrameSourceError.commandBufferFailed("command buffer") }
            var keep: [CVMetalTexture] = []
            do {
                try compositor.render(nodes: RenderNode.tree(requests: requests, layers: layers), format: timeline.format, into: working, commandBuffer: cb)
                try captions?.encode(at: t, into: working, commandBuffer: cb)
                switch format {
                case .bgra8:
                    try dispatch(bgraPipe, src: working, dst: planeTexture(out, plane: 0, format: .bgra8Unorm, keep: &keep), cb)
                case .yuv420v:
                    try dispatch(lumaPipe, src: working, dst: planeTexture(out, plane: 0, format: .r8Unorm, keep: &keep), cb)
                    try dispatch(chromaPipe, src: working, dst: planeTexture(out, plane: 1, format: .rg8Unorm, keep: &keep), cb)
                }
            } catch {
                freeWorking.append(working)
                throw error
            }
            let keepAlive = Box(keep)
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    cb.addCompletedHandler { b in
                        _ = keepAlive
                        if let e = b.error { c.resume(throwing: e) } else { c.resume() }
                    }
                    cb.commit()
                }
            } catch {
                freeWorking.append(working)
                throw error
            }
            freeWorking.append(working)
            try Task.checkCancellation()
            Self.tag(out)
            CVMetalTextureCacheFlush(cache, 0)
            return Box(out)
        }

        static func tag(_ pb: CVPixelBuffer) {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
    }
}
