import Foundation
import SQAnalysis
import SQCore
import SQFrame
import SQGPU
import SQGPUD3D12
import SQGPUKernels
import SQLottie
import SQMedia
import SQPlayback
import SQRender
import SQText

/// The Program picture on Windows, the Mac export path on the D3D12 backend: the frame's layer requests become
/// `RenderLayer`s and the Mac `RenderNode.tree`, SQRender's `GPUCompositor` draws it into an rgba16Float canvas and the
/// monitor's Present shader turns it into BT.709 code values in an RGBA8 texture. The window's UI renderer runs on the
/// same device and queue and samples that texture (`GPUPicture`); `download` reads it back for scopes, Export Frame and
/// the export frame source.
/// Decoded planes are 8-bit NV12 (r8/rg8) or P010 kept at 10 bits (r16/rg16, `Picture` bit depth 10).
/// shortcut: planes come through the CPU (FFmpeg's D3D11 frames are downloaded, then uploaded here); share the D3D11VA
/// textures with D3D12 when 4K upload time limits playback.
/// Clip and adjustment-layer grades come from `grade` (the Mac `LayerColorResolver`).
/// Titles and Date Stamps draw through the portable text raster (`TextGenerator.portableFrame`), uploaded once per text
/// picture (a text animator draws a new picture per in-between frame); captions (`CaptionLayerPlan`) the same way on top.
/// Shape clips draw through `PortableShapeRenderer` (the Mac `ShapeRenderer` on the same coverage masks), uploaded once
/// per shape style.
/// Lottie clips draw through ThorVG (`LottieRenderer.portableFrame`), one upload per animation frame.
/// shortcut: only the frames of the last render stay on the GPU (the Mac keeps a 256 MB frame cache), so a looping
/// sticker draws every pass again; add an LRU when Lottie playback shows up in profiles.
/// Not tied to an actor: the Program engine owns one on the main actor, each export frame source one on
/// `WinRenderActor` (each with its own device).
final class WinCompositor {
    /// One decoded picture of a layer: the plane cache key, the NV12 bytes and the track facts (rotation, matrix).
    /// `proxy`: the picture is the media's proxy (its own planes, never mixed with the original's of the same index).
    struct Source { let media: UUID; let index: Int; let picture: NV12Picture; let info: VideoTrackInfo; var proxy = false }
    private struct PlaneKey: Hashable { let media: UUID; let index: Int; let proxy: Bool; let width: Int }
    private struct Storage: SQFrameStorage { let slot: Int }
    private struct PresentU {   // Present.slang `PresentU`: SDR, unchanged gamma, linear sampling
        var m0 = SIMD4<Float>(1, 0, 0, 0), m1 = SIMD4<Float>(0, 1, 0, 0), m2 = SIMD4<Float>(0, 0, 1, 0)
        var mode: Float = 0, peak: Float = 1, knee: Float = 1, exponent: Float = 1
        var nearest: UInt32 = 0, pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    }
    typealias Picture = GPUCompositor<D3D12GPUDevice>.Picture

    let device: D3D12GPUDevice
    private let compositor: GPUCompositor<D3D12GPUDevice>
    private let present: D3D12GPURenderPipeline
    private var planes: [PlaneKey: Picture] = [:]
    /// Forgets the uploaded planes (the engine's pictures changed size for the same frame: playback quality).
    func dropPlanes() { planes = [:] }
    private var working: D3D12GPUTexture?, output: D3D12GPUTexture?
    /// The ungraded canvas of Color page Split (nil otherwise).
    private var splitWorking: D3D12GPUTexture?
    /// Image-sequence frames at another size than the sequence (`downloadLinear(size:)`).
    private var linearOutput: D3D12GPUTexture?
    /// Title rasters on the GPU by text ref (the raster depends on the ref only; the animation moves the layer).
    private var titles: [GeneratorRef: (frame: PortableTextFrame, picture: Picture)] = [:]
    /// Shape rasters on the GPU by style (an animated shape draws a new one per changed frame).
    private var shapes: [ShapeStyle: (shape: PortableShapeRenderer.Shape, picture: Picture)] = [:]
    /// Lottie frames on the GPU by frame key (the frames of the last render).
    private var lotties: [LottieRenderer.FrameKey: (picture: Picture, width: Int, height: Int)] = [:]
    private var usedLotties: [LottieRenderer.FrameKey: (picture: Picture, width: Int, height: Int)] = [:]
    /// Clip lengths by id: text animations anchor their out phase on them (`clipDurations(of:)`).
    var clipDurations: [Clip.ID: Time] = [:]
    /// CPU milliseconds of the last `render` (layers, uploads, recording; the GPU runs it after `commit`).
    private(set) var lastMilliseconds = 0.0
    /// With `render(readback: true)`: the picture's bytes, recorded into the frame's command buffer (`finish` waits for
    /// that frame only), so the export renders the next frame while the GPU still works on this one.
    private(set) var lastReadback: D3D12GPUDevice.Readback?

    init(device: D3D12GPUDevice) throws {
        self.device = device
        compositor = try GPUCompositor(device: device)
        present = try device.makeRenderPipeline(GPURenderKernel(GeneratedShaders.present, vertex: "presentVertex",
                                                                fragment: "presentFragment"), format: .rgba8Unorm, blend: .replace)
    }

    /// Composites `requests` (bottom to top) at the sequence size. `source` gives the decoded picture of a media layer.
    /// The result stays on the GPU (`NV12Picture.texture`, RGBA8 display code values, no bytes) until `download`.
    /// `transparent` (Transparency Grid): the composite starts transparent and the Present pass lays it over the gray
    /// checkerboard (Present.slang), so the picture stays opaque and the UI draws it unchanged.
    /// shortcut: the checker squares are 16 sequence pixels (the Mac draws 16 view pixels); move the checker into the
    /// monitor's video quad if they should keep their size while zooming.
    /// `outputSize` (export scaling, the Mac `TimelineFrameSource` width/height): the Present pass resamples the
    /// sequence-sized composite to it (stretched, bilinear).
    /// shortcut: one bilinear tap, so a downscale below half size aliases; add a box pre-filter when presets need it.
    /// `captions`: the caption layers on top of the picture (`CaptionLayerPlan`), laid out in `format.layoutFormat`.
    /// `splitGrade` (Color page Split, the Mac RenderLoop): the same layers composited again with these grades into a
    /// second canvas, whose left half (`ColorBypass.splitWidth`) is presented over the graded picture.
    /// The frame's command buffer is committed without waiting (frames in flight, `D3D12GPUDevice.commit`); the UI
    /// renderer on the same queue and `download` run after it in queue order.
    func render(_ requests: [LayerRequest], format: SequenceFormat, outputSize: (width: Int, height: Int)? = nil,
                transparent: Bool = false, readback: Bool = false, captions: [CaptionLayerRequest] = [], grade: (LayerRequest) -> ColorPipeline?,
                splitGrade: ((LayerRequest) -> ColorPipeline?)? = nil,
                source: (LayerRequest) -> Source?) throws -> NV12Picture {
        let start = DispatchTime.now().uptimeNanoseconds
        // The command buffer first: plane uploads then join it (one submit per frame instead of one per plane).
        guard let cb = device.makeCommandBuffer() else { throw AppError("compositor: no command buffer") }
        var pictures: [Picture] = []
        var used: [PlaneKey: Picture] = [:]
        var usedTitles: [GeneratorRef: (frame: PortableTextFrame, picture: Picture)] = [:]
        var usedShapes: [ShapeStyle: (shape: PortableShapeRenderer.Shape, picture: Picture)] = [:]
        usedLotties = [:]
        let layers = try requests.map { l -> RenderLayer in
            var r = try layer(for: l, format: format, source: source, pictures: &pictures, used: &used, titles: &usedTitles,
                              shapes: &usedShapes)
            if case .placeholder(.loading) = r.content, l.generator?.kind != GeneratorRef.adjustment {} else { r.colorPipeline = WinPlayStats.shared.time(.grade) { grade(l) } }
            // Magic masks read the mattes picked and tracked on this source frame (FrameMatteStore, WinMagicMasks).
            if !l.effects.magicMattes.isEmpty {
                r.mattes = FrameMatteStore.shared.mattes(for: l.effects, pts: Double(l.sourceTime.value) / Double(max(l.sourceTime.timescale, 1)),
                                                         frameWidth: Double(r.nativeSize?.0 ?? format.width))
            }
            return r
        }
        WinPlayStats.shared.add(.layers, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        var captionNodes: [RenderNode] = []
        for c in captions {
            if let r = try caption(c, format: format, pictures: &pictures, used: &usedTitles) { captionNodes.append(.layer(r)) }
        }
        titles = usedTitles
        shapes = usedShapes
        lotties = usedLotties
        planes = used   // shortcut: planes not drawn this frame are dropped; pool them when allocation shows up in profiles
        let w = format.width, h = format.height
        let (ow, oh) = outputSize ?? (w, h)
        if working?.width != w || working?.height != h {
            working = device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba16Float))
        }
        if output?.width != ow || output?.height != oh {
            output = device.makeTexture(GPUTextureDescriptor(width: ow, height: oh, format: .rgba8Unorm, cpuAccessible: true))
        }
        guard let working, let output else { throw AppError("compositor: no GPU resources") }
        try WinPlayStats.shared.time(.record) {
            try compositor.render(nodes: RenderNode.tree(requests: requests, layers: layers) + captionNodes, format: format, into: working,
                                  commandBuffer: cb, transparent: transparent) { f in (f.storage as? Storage).map { pictures[$0.slot] } }
        }
        try presentPass(working, into: output, cb)
        if let splitGrade {
            let ungraded = zip(requests, layers).map { l, r in
                var r = r
                if r.colorPipeline != nil { r.colorPipeline = splitGrade(l) }
                return r
            }
            if splitWorking?.width != w || splitWorking?.height != h {
                splitWorking = device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba16Float))
            }
            let half = ColorBypass.splitWidth(ow)
            if let other = splitWorking, half > 0 {
                try compositor.render(nodes: RenderNode.tree(requests: requests, layers: ungraded) + captionNodes, format: format,
                                      into: other, commandBuffer: cb, transparent: transparent) { f in
                    (f.storage as? Storage).map { pictures[$0.slot] }
                }
                try presentPass(other, into: output, cb, scissorWidth: half)
            }
        } else {
            splitWorking = nil      // a second canvas is only kept while Split is showing
        }
        lastReadback = readback ? device.readback(output, in: cb) : nil
        let resource = device.prepareForSampling(output)
        device.commit(cb)
        guard device.lastCommitSucceeded, let resource else { throw AppError("compositor: the frame did not fit the GPU budgets") }
        lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        return NV12Picture(bytes: [], width: ow, height: oh, fullRange: true, rgba: true,
                           texture: GPUPicture(texture: output, resource: resource))
    }

    /// The monitor's Present shader from a working canvas into `output`; `scissorWidth` limits it to the left columns.
    private func presentPass(_ canvas: D3D12GPUTexture, into output: D3D12GPUTexture, _ cb: D3D12GPUCommandBuffer,
                             scissorWidth: Int? = nil) throws {
        guard let enc = cb.makeRenderEncoder(target: output, clear: nil) else { throw AppError("compositor: present pass") }
        enc.setPipeline(present)
        enc.setInput(canvas, at: 0)
        enc.setConstants(PresentU())
        if let scissorWidth { enc.setScissor(x: 0, y: 0, width: scissorWidth, height: output.height) }
        enc.draw(.triangles, vertexCount: 3)
        enc.end()
    }

    /// The RGBA8 bytes of a picture `render` returned (rows top down, stride = width * 4); valid until the next render.
    func download(_ p: NV12Picture) -> NV12Picture {
        guard let t = p.texture else { return p }
        var out = p
        out.bytes = device.download(t.texture)
        out.texture = nil
        return out
    }

    /// The linear composite of the last `render` (rgba halves, premultiplied linear Rec.709, rows top down, stride =
    /// width * 8): the image-sequence export frame (the Mac rgbaHalf source). With `transparent` the empty areas stay
    /// clear. `size` other than the sequence's: stretched to it as the Mac does (`GPUCompositor.resampleLinear`).
    func downloadLinear(size: (width: Int, height: Int)? = nil) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let working else { return nil }
        var picture = working
        if let size, size.width != working.width || size.height != working.height {
            if linearOutput?.width != size.width || linearOutput?.height != size.height {
                linearOutput = device.makeTexture(GPUTextureDescriptor(width: size.width, height: size.height, format: .rgba16Float))
            }
            guard let out = linearOutput, let cb = device.makeCommandBuffer(),
                  (try? compositor.resampleLinear(working, into: out, commandBuffer: cb)) != nil else { return nil }
            device.commitAndWait(cb)
            picture = out
        }
        let b = device.download(picture)
        return b.isEmpty ? nil : (b, picture.width, picture.height)
    }

    /// The scopes of the last `render`'s linear composite, measured on the GPU (the shared `ScopePasses`, the Mac
    /// `ScopesGPU` passes); only the 1.6 MB counts buffer comes back, not the picture.
    func measureScopes(pixelStride: Int) -> ScopeCounts? {
        guard let working else { return nil }
        if scopes == nil { scopes = try? ScopePasses(device: device) }
        guard let scopes else { return nil }
        if scopeCounts == nil { scopeCounts = scopes.makeCounts() }
        guard let scopeCounts, let c = scopes.measure(working, counts: scopeCounts, pixelStride: pixelStride),
              device.lastCommitSucceeded else { return nil }
        return c
    }
    private var scopes: ScopePasses<D3D12GPUDevice>?
    private var scopeCounts: D3D12GPUDevice.Buffer?

    private func layer(for l: LayerRequest, format: SequenceFormat, source: (LayerRequest) -> Source?,
                       pictures: inout [Picture], used: inout [PlaneKey: Picture],
                       titles used2: inout [GeneratorRef: (frame: PortableTextFrame, picture: Picture)],
                       shapes used3: inout [ShapeStyle: (shape: PortableShapeRenderer.Shape, picture: Picture)]) throws -> RenderLayer {
        // The Mac `TimelineFrameSource.baseLayer`, for the generators that have a portable renderer.
        if let g = l.generator {
            if g.kind == GeneratorRef.text || g.kind == GeneratorRef.dateStamp {
                return try WinPlayStats.shared.time(.title) { try title(l, g, format: format, pictures: &pictures, used: &used2) }
            }
            if g.kind == GeneratorRef.solid {
                return RenderLayer.solid(payload: g.payload, transform: l.transform, cornerRadius: l.cornerRadius).applying(l)
            }
            if g.kind == GeneratorRef.adjustment { return RenderLayer.adjustment(transform: l.transform).applying(l) }
            if g.kind == GeneratorRef.shape { return try shape(l, pictures: &pictures, used: &used3) }
            if g.kind == GeneratorRef.lottie { return try lottie(l, format: format, pictures: &pictures).applying(l) }
            var hidden = l.transform; hidden.opacity = 0
            return RenderLayer(content: .placeholder(.loading), transform: hidden)
        }
        guard let s = source(l) else {
            return RenderLayer(content: .placeholder(.offline), transform: l.transform, cornerRadius: l.cornerRadius).applying(l)
        }
        let key = PlaneKey(media: s.media, index: s.index, proxy: s.proxy, width: s.picture.width)
        let pic: Picture
        if let p = used[key] ?? planes[key] { pic = p } else { pic = try upload(s.picture) }
        used[key] = pic
        pictures.append(pic)
        let p = s.picture
        let frame = SQFrame(width: p.width, height: p.height, pixelFormat: p.fullRange ? .nv12FullRange : .nv12,
                            storage: Storage(slot: pictures.count - 1))
        return RenderLayer(content: .frame(frame, colorHint: s.info), transform: l.transform, cornerRadius: l.cornerRadius,
                           nativeSize: (s.info.width, s.info.height)).applying(l)
    }

    /// The Mac `TimelineFrameSource.textLayer` on the portable raster: the raster as a linear premultiplied layer placed by
    /// `PortableTextFrame.layerTransform`; empty text draws nothing.
    private func title(_ l: LayerRequest, _ g: GeneratorRef, format: SequenceFormat, pictures: inout [Picture],
                       used: inout [GeneratorRef: (frame: PortableTextFrame, picture: Picture)]) throws -> RenderLayer {
        var hidden = l.transform; hidden.opacity = 0
        let ref = g.kind == GeneratorRef.dateStamp ? DateStampText.textRef(for: g) : g
        guard let ref else { return RenderLayer(content: .placeholder(.offline), transform: l.transform) }
        let dur = l.clipDuration ?? clipDurations[l.clip] ?? l.localTime
        guard let (frame, _) = try textPicture(ref, localTime: l.localTime, duration: dur, canvas: format, pictures: &pictures,
                                                 used: &used) else {
            return RenderLayer(content: .placeholder(.loading), transform: hidden)    // empty text: invisible
        }
        let raster = SQFrame(width: frame.picture.width, height: frame.picture.height, pixelFormat: .rgba32f,
                             storage: Storage(slot: pictures.count - 1))
        var r = RenderLayer(content: .linearPremultiplied(raster, width: frame.width, height: frame.height),
                            transform: frame.layerTransform(base: l.transform, canvas: format), cornerRadius: l.cornerRadius)
        if let fill = frame.footageFill { r.footageFill = fill == .stencil ? .stencil : .inverted }
        return r.applying(l)
    }

    /// The Mac `ShapeRenderer.layer(for:)`: the shape picture centered on the clip position; nothing to draw is invisible.
    private func shape(_ l: LayerRequest, pictures: inout [Picture],
                       used: inout [ShapeStyle: (shape: PortableShapeRenderer.Shape, picture: Picture)]) throws -> RenderLayer {
        var hidden = l.transform; hidden.opacity = 0
        guard let st = l.shape else { return RenderLayer(content: .placeholder(.loading), transform: hidden) }
        let entry: (shape: PortableShapeRenderer.Shape, picture: Picture)
        if let e = used[st] ?? shapes[st] { entry = e } else {
            guard let sh = PortableShapeRenderer.render(st) else {
                return RenderLayer(content: .placeholder(.loading), transform: hidden)
            }
            entry = (sh, try upload(sh.picture))
        }
        used[st] = entry
        pictures.append(entry.picture)
        let raster = SQFrame(width: entry.shape.picture.width, height: entry.shape.picture.height, pixelFormat: .rgba32f,
                             storage: Storage(slot: pictures.count - 1))
        return RenderLayer(content: .linearPremultiplied(raster, width: entry.shape.width, height: entry.shape.height),
                           transform: l.transform).applying(l)
    }

    /// The Mac `LottieRenderer.layer(for:canvas:)`: an unreadable file is the offline slate, a failed draw invisible.
    private func lottie(_ l: LayerRequest, format: SequenceFormat, pictures: inout [Picture]) throws -> RenderLayer {
        var hidden = l.transform; hidden.opacity = 0
        guard let key = LottieRenderer.frameKey(for: l, canvas: format) else {
            return RenderLayer(content: .placeholder(.offline), transform: l.transform, cornerRadius: l.cornerRadius)
        }
        let entry: (picture: Picture, width: Int, height: Int)
        if let e = usedLotties[key] ?? lotties[key] { entry = e } else {
            guard case .picture(_, let w, let h, let px) = LottieRenderer.portableFrame(for: l, canvas: format) else {
                return RenderLayer(content: .placeholder(.loading), transform: hidden)
            }
            entry = (try upload(PortableTextRenderer.Picture(width: w, height: h, pixels: px)), w, h)
        }
        usedLotties[key] = entry
        pictures.append(entry.picture)
        let raster = SQFrame(width: entry.width, height: entry.height, pixelFormat: .rgba32f, storage: Storage(slot: pictures.count - 1))
        return RenderLayer(content: .linearPremultiplied(raster, width: Double(entry.width), height: Double(entry.height)),
                           transform: l.transform)
    }

    /// A linear premultiplied RGBA float picture (text, shapes) as a GPU texture.
    private func upload(_ p: PortableTextRenderer.Picture) throws -> Picture {
        guard let t = device.makeTexture(GPUTextureDescriptor(width: p.width, height: p.height, format: .rgba32Float,
                                                              cpuAccessible: true)) else {
            throw AppError("compositor: picture texture \(p.width)x\(p.height)")
        }
        p.pixels.withUnsafeBytes { device.upload($0, bytesPerRow: p.width * 16, to: t) }
        return Picture(rgba: t, alphaMode: 0)
    }

    /// The Mac `RenderLoop.captionNodes` layer: the caption raster about its text center, at the caption box's position.
    private func caption(_ c: CaptionLayerRequest, format: SequenceFormat, pictures: inout [Picture],
                         used: inout [GeneratorRef: (frame: PortableTextFrame, picture: Picture)]) throws -> RenderLayer? {
        let canvas = format.layoutFormat
        guard let (frame, _) = try textPicture(c.ref, localTime: c.localTime, duration: c.duration, canvas: canvas,
                                               pictures: &pictures, used: &used) else { return nil }
        var tr = frame.layerTransform(base: ClipTransform(position: c.position), canvas: canvas, pivotAtText: true)
        tr.opacity *= c.opacity
        let raster = SQFrame(width: frame.picture.width, height: frame.picture.height, pixelFormat: .rgba32f,
                             storage: Storage(slot: pictures.count - 1))
        return RenderLayer(content: .linearPremultiplied(raster, width: frame.width, height: frame.height), transform: tr)
    }

    /// The text frame of `ref` at `localTime` and its picture on the GPU (appended to `pictures`): the picture of the last
    /// frame is kept while the text animators' states stay the same; nil for empty text.
    private func textPicture(_ ref: GeneratorRef, localTime: Time, duration: Time, canvas: SequenceFormat, pictures: inout [Picture],
                             used: inout [GeneratorRef: (frame: PortableTextFrame, picture: Picture)]) throws
        -> (PortableTextFrame, Picture)? {
        let cached = used[ref] ?? titles[ref]
        guard let f = try TextGenerator.portableFrame(ref: ref, localTime: localTime, clipDuration: duration, canvas: canvas,
                                                      raster: cached?.frame) else { return nil }
        let pic: Picture
        if let cached, f.sharesPicture(with: cached.frame) { pic = cached.picture } else { pic = try upload(f.picture) }
        used[ref] = (f, pic)
        pictures.append(pic)
        return (f, pic)
    }

    /// Every clip's length by id over the sequence and its nested sequences (`TimelineFrameSource.clipDurations`).
    static func clipDurations(of timeline: Timeline, sequences: [Timeline.ID: Timeline]) -> [Clip.ID: Time] {
        var out: [Clip.ID: Time] = [:]
        for tl in [timeline] + Array(sequences.values) { for t in tl.tracks { for c in t.clips { out[c.id] = c.source.duration } } }
        return out
    }

    private func upload(_ p: NV12Picture) throws -> Picture {
        let w = p.width, h = p.height, deep = p.bitDepth > 8, sample = deep ? 2 : 1
        let t0 = DispatchTime.now().uptimeNanoseconds
        let luma = device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: deep ? .r16Unorm : .r8Unorm, cpuAccessible: true))
        let chroma = device.makeTexture(GPUTextureDescriptor(width: w / 2, height: h / 2, format: deep ? .rg16Unorm : .rg8Unorm,
                                                             cpuAccessible: true))
        WinPlayStats.shared.add(.texture, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        guard let luma, let chroma else {
            throw AppError("compositor: plane textures \(w)x\(h)")
        }
        WinPlayStats.shared.time(.upload) { p.bytes.withUnsafeBytes { raw in
            device.upload(UnsafeRawBufferPointer(rebasing: raw[0..<(w * h * sample)]), bytesPerRow: w * sample, to: luma)
            device.upload(UnsafeRawBufferPointer(rebasing: raw[(w * h * sample)...]), bytesPerRow: w * sample, to: chroma)
        } }
        return Picture(luma: luma, chroma: chroma, bitDepth: p.bitDepth, fullRange: p.fullRange)
    }
}
