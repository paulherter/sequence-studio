import Foundation
import SQCore
import SQFrame
import SQGPU
import SQGPUKernels

/// A fixed render tree through `GPUCompositor` for the cross-backend check (scripts/win-compositor-check.sh: Metal on the
/// Mac vs D3D12 on the PC): a Y'CbCr picture (float planes, how the Windows decoder hands NV12 over), an RGBA picture
/// with straight alpha, solids, transform with rotation and tilt, opacity, corner radius, blend modes, a nested group,
/// a stencil inside it, a pair and a fused and a blended transition; clip effects (crop, corners, key, blur, Drop Shadow,
/// Outline, Glow, Long Shadow, path and subject masks, a mask scope, film look), frame blending (plain and optical
/// flow), a Picture mask, a mirrored long-blur transition and a motion-blurred adjustment layer.
public enum GPUCompositorReference {
    public static let width = 192, height = 128

    /// The SQFrame payload of a reference picture: which of the uploaded pictures it is.
    struct Storage: SQFrameStorage { let index: Int }

    /// 8-bit BT.709-encoded RGBA of the tree (alpha 255: the background is opaque black).
    public static func render<D: GPUDevice>(on device: D) throws -> [UInt8] {
        let kernels = try GPUKernels(device: device)
        let compositor = try GPUCompositor(device: device)
        guard let cb = device.makeCommandBuffer() else { throw GPUError.deviceUnavailable("command buffer") }
        func texture(_ w: Int, _ h: Int, _ f: GPUPixelFormat, cpu: Bool = false) throws -> D.Texture {
            guard let t = device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: f, cpuAccessible: cpu)) else {
                throw GPUError.deviceUnavailable("texture \(w)x\(h)")
            }
            return t
        }
        var keep: [D.Texture] = []
        /// rgba32Float rows -> rgba16Float (blendFrames with weight 0 copies).
        func floatPlane(_ px: [Float], _ w: Int, _ h: Int) throws -> D.Texture {
            let staging = try texture(w, h, .rgba32Float, cpu: true), t = try texture(w, h, .rgba16Float)
            px.withUnsafeBytes { device.upload($0, bytesPerRow: w * 16, to: staging) }
            kernels.blendFrames(cb, staging, staging, into: t, weight: 0, encoded: false)
            keep += [staging, t]
            return t
        }
        func rgba8(_ w: Int, _ h: Int, _ f: (Int, Int) -> SIMD4<UInt8>) throws -> D.Texture {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let c = f(x, y), i = (y * w + x) * 4
                bytes[i] = c.x; bytes[i + 1] = c.y; bytes[i + 2] = c.z; bytes[i + 3] = c.w
            } }
            let t = try texture(w, h, .rgba8Unorm, cpu: true)
            bytes.withUnsafeBytes { device.upload($0, bytesPerRow: w * 4, to: t) }
            keep.append(t)
            return t
        }

        // Picture 0: full-range BT.709 Y'CbCr, 4:2:0, a color ramp with a few hard edges.
        let w0 = width, h0 = height
        var luma = [Float](repeating: 1, count: w0 * h0 * 4), chroma = [Float](repeating: 1, count: w0 / 2 * h0 / 2 * 4)
        for y in 0..<h0 { for x in 0..<w0 {
            let r = Float(x) / Float(w0), g = Float(y) / Float(h0), b = (x / 24 + y / 16) % 2 == 0 ? 0.8 : 0.15
            let yy = 0.2126 * r + 0.7152 * g + 0.0722 * Float(b), i = (y * w0 + x) * 4
            luma[i] = yy; luma[i + 1] = yy; luma[i + 2] = yy
            if x % 2 == 0 && y % 2 == 0 {
                let j = ((y / 2) * (w0 / 2) + x / 2) * 4
                chroma[j] = (Float(b) - yy) / 1.8556 + 0.5; chroma[j + 1] = (r - yy) / 1.5748 + 0.5; chroma[j + 2] = 0
            }
        } }
        let ycbcr = GPUCompositor<D>.Picture(luma: try floatPlane(luma, w0, h0), chroma: try floatPlane(chroma, w0 / 2, h0 / 2),
                                             bitDepth: 8, fullRange: true)
        // Picture 1: straight-alpha RGBA with a soft transparent hole. Picture 2: an opaque checker.
        let hole = GPUCompositor<D>.Picture(rgba: try rgba8(120, 80) { x, y in
            let dx = Float(x - 60), dy = Float(y - 40), d = (dx * dx + dy * dy).squareRoot()
            let a = UInt8(max(0, min(255, (d - 14) * 20)))
            return SIMD4(UInt8(x * 2), UInt8(200 - y), 90, a)
        }, alphaMode: 1)
        let checker = GPUCompositor<D>.Picture(rgba: try rgba8(64, 48) { x, y in
            (x / 8 + y / 8) % 2 == 0 ? SIMD4(230, 220, 40, 255) : SIMD4(30, 60, 200, 255)
        }, alphaMode: 0)
        let shifted = GPUCompositor<D>.Picture(rgba: try rgba8(64, 48) { x, y in
            (x / 6 + y / 10) % 2 == 0 ? SIMD4(200, 40, 160, 255) : SIMD4(20, 180, 90, 255)
        }, alphaMode: 0)
        // Picture 4: picture 0's ramp moved 3 px right as RGBA (the optical-flow pair of a smooth pattern).
        let movedRamp = GPUCompositor<D>.Picture(rgba: try rgba8(64, 48) { x, y in
            let v = 0.5 + 0.3 * sin(Float(x - 3) * 0.3) * cos(Float(y) * 0.2)
            return SIMD4(UInt8(v * 255), UInt8(255 - v * 200), UInt8((x + y) * 2), 255)
        }, alphaMode: 0)
        let ramp = GPUCompositor<D>.Picture(rgba: try rgba8(64, 48) { x, y in
            let v = 0.5 + 0.3 * sin(Float(x) * 0.3) * cos(Float(y) * 0.2)
            return SIMD4(UInt8(v * 255), UInt8(255 - v * 200), UInt8((x + y) * 2), 255)
        }, alphaMode: 0)
        let pictures = [ycbcr, hole, checker, shifted, movedRamp, ramp]
        let info = VideoTrackInfo(width: w0, height: h0, codec: "ref", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        func layer(_ i: Int, _ w: Int, _ h: Int) -> RenderLayer {
            let f = SQFrame(width: w, height: h, pixelFormat: .bgra8, storage: Storage(index: i))
            return RenderLayer(content: .frame(f, colorHint: info))
        }

        let format = SequenceFormat(width: width, height: height, frameDuration: Time(1, 25))
        var turned = layer(1, 120, 80)
        turned.transform = ClipTransform(position: Vec2(20, -8), scale: Vec2(0.9, 0.9), rotation: 15, opacity: 0.9)
        turned.cornerRadius = 8
        var tilted = layer(2, 64, 48)
        tilted.transform = ClipTransform(position: Vec2(-50, 30), scale: Vec2(1.2, 1.2), tiltX: 25, tiltY: -15)
        var overlay = RenderLayer(content: .solid(red: 0.9, green: 0.4, blue: 0.2), blendMode: .overlay)
        overlay.transform = ClipTransform(position: Vec2(40, 30), scale: Vec2(0.4, 0.3))
        var white = RenderLayer(content: .solid(red: 1, green: 1, blue: 1))
        white.transform = ClipTransform(scale: Vec2(0.3, 0.3))
        let inner = SequenceFormat(width: 64, height: 48, frameDuration: Time(1, 25))
        let push = TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.3, 0)), incoming: TransitionSide(offset: Vec2(0.7, 0)),
                                    compose: .sum)
        let wipe = TransitionRender(incoming: TransitionSide(offset: Vec2(0.5, 0)), compose: .incomingOver)
        // Grades through the color chain: the Y'CbCr background (conversion, then the chain) and the tilted RGBA picture.
        var basic = BasicCorrection(); basic.exposure = 0.5; basic.saturation = 150; basic.contrast = 25; basic.temperature = 20
        var graded = layer(0, w0, h0)
        graded.colorPipeline = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        tilted.colorPipeline = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        var nodes: [RenderNode] = [
            .layer(graded),
            .layer(turned),
            .layer(tilted),
            .layer(overlay),
            .group(format: inner, transform: ClipTransform(position: Vec2(60, -35), rotation: -10), opacity: 0.8, cornerRadius: 6,
                   children: [.layer(layer(2, 64, 48)), .stencil(opacity: 0.85, children: [.layer(white)])]),
            .pair(format: format, first: [.layer(white)], second: [.layer(tilted)]),
            .transition(format: format, render: push, first: [.layer(layer(2, 64, 48))], second: [.layer(white)]),
            .blended(.transition(format: format, render: wipe, first: [.layer(turned)], second: [.layer(layer(2, 64, 48))]), .difference),
        ]
        // Clip effects, frame blending, a motion-blurred adjustment (GPUCompositor+Effects).
        func effected(_ i: Int, _ w: Int, _ h: Int, _ fx: ClipEffects, at p: Vec2, scale: Double = 0.8,
                      rotation: Double = 0) -> RenderNode {
            var l = layer(i, w, h)
            l.effects = fx
            l.transform = ClipTransform(position: p, scale: Vec2(scale, scale), rotation: rotation)
            return .layer(l)
        }
        let path = MaskShape(polygon: [Vec2(0.1, 0.1), Vec2(0.9, 0.2), Vec2(0.7, 0.9), Vec2(0.2, 0.8)], feather: 5)
        var masked = layer(2, 64, 48)
        masked.effects = ClipEffects(segments: [EffectSegment()], masks: [path, MaskShape(polygon: [], mode: .intersect,
                                                                                          source: .subject)])
        masked.subjectMatte = SubjectMatte(width: 16, height: 12, values: (0..<(16 * 12)).map { Float($0 % 16) / 15 })
        masked.transform = ClipTransform(position: Vec2(-70, -40), rotation: 8)
        var blended = layer(2, 64, 48)
        blended.blend = FrameBlend(next: SQFrame(width: 64, height: 48, pixelFormat: .bgra8, storage: Storage(index: 3)),
                                   weight: 0.4)
        blended.transform = ClipTransform(position: Vec2(70, 45))
        var flowed = layer(5, 64, 48)
        flowed.blend = FrameBlend(next: SQFrame(width: 64, height: 48, pixelFormat: .bgra8, storage: Storage(index: 4)),
                                  weight: 0.5, flow: OpticalFlowRequest(key: nil))
        flowed.transform = ClipTransform(position: Vec2(-75, 5), scale: Vec2(0.6, 0.6))
        // Temporal filters (TemporalPasses): denoise + deflicker + trails over the checker, the shifted checker as neighbors.
        var temporal = layer(2, 64, 48)
        let neighbor = SQFrame(width: 64, height: 48, pixelFormat: .bgra8, storage: Storage(index: 3))
        temporal.temporal = TemporalFrames(filter: TemporalFilter(denoise: .init(framesEachSide: 1, detailSize: 1, spatialLuma: 0.4),
                                                                  deflicker: .init(framesEachSide: 1, local: true),
                                                                  trails: .init(count: 2, spacing: 1, decay: 0.5, blend: .screen)),
                                           before: [neighbor, neighbor], after: [neighbor])
        temporal.transform = ClipTransform(position: Vec2(10, 45), scale: Vec2(0.7, 0.7))
        let shadowed = ClipEffects(segments: [
            EffectSegment(masks: EffectMasks(crop: CropInsets(left: 0.1), cornerRadius: 5), blurAfter: 1.5),
            EffectSegment(shadow: DropShadow(color: SIMD3(0.1, 0.2, 0.9), opacity: 0.8, dx: 4, dy: 3, sigma: 2)),
            EffectSegment(filter: .outline(width: 2, color: SIMD3(1, 1, 1), softness: 1, position: .outside)),
            EffectSegment(),
        ])
        let glowing = ClipEffects(segments: [
            EffectSegment(keys: [ChromaKey(hue: 60, halfWidth: 30, soft: 10, spill: 0.3)]),
            EffectSegment(filter: .glow(threshold: 0.3, sigma: 3, intensity: 0.7, color: nil)),
            EffectSegment(filter: .longShadow(angle: 135, length: 10, color: SIMD3(0, 0, 0), fade: 0.5, opacity: 0.7)),
            EffectSegment(blurAfter: 2, scope: [path]),
            EffectSegment(),
        ], look: FilmLook(chromaBleed: .init(bleed: 4, shift: 1)))
        var t1 = ClipTransform.identity, t2 = ClipTransform.identity
        t1.position = Vec2(-3, 0); t2.position = Vec2(3, 2)
        let adjust = AdjustmentNode(transform: .identity, opacity: 0.6, cornerRadius: 0,
                                    effects: ClipEffects(segments: [EffectSegment(blurAfter: 1), EffectSegment()]),
                                    blendMode: .normal, colorPipeline: nil, motionSamples: [t1, t2], drawsBase: true)
        nodes += [
            effected(2, 64, 48, shadowed, at: Vec2(-20, 35), rotation: 12),
            effected(3, 64, 48, glowing, at: Vec2(10, -30), scale: 1),
            .layer(masked),
            .layer(blended),
            .layer(flowed),
            .layer(temporal),
        ]
        // A Picture mask (matte from a white solid), a whip with mirrored edges and the long-blur pre-pass.
        let matteTrack = UUID()
        var pm = MaskShape(polygon: [], source: .picture)
        pm.pictureTrack = matteTrack
        var pictured = layer(3, 64, 48)
        pictured.effects = ClipEffects(segments: [EffectSegment()], masks: [pm])
        pictured.transform = ClipTransform(position: Vec2(-60, 40), scale: Vec2(1.4, 1.4))
        var whipOut = TransitionSide(offset: Vec2(-0.2, 0), blur: Vec2(-1.5, 0)); whipOut.mirrorEdges = true
        let whip = TransitionRender(outgoing: whipOut, incoming: TransitionSide(offset: Vec2(0.8, 0), blur: Vec2(-1.5, 0)),
                                    compose: .sum)
        nodes += [
            .pictureMatte(track: matteTrack, children: [.layer(white)]),
            .layer(pictured),
            .blended(.transition(format: format, render: whip, first: [.layer(layer(0, w0, h0))],
                                 second: [.layer(layer(2, 64, 48))]), .screen),
        ]
        nodes = [.adjustment(adjust, below: nodes)]
        let target = try texture(width, height, .rgba16Float)
        try compositor.render(nodes: nodes, format: format, into: target, commandBuffer: cb) { frame in
            (frame.storage as? Storage).map { pictures[$0.index] }
        }
        let out = try texture(width, height, .rgba32Float, cpu: true)
        kernels.blendFrames(cb, target, target, into: out, weight: 0, encoded: false)
        device.commitAndWait(cb)
        _ = keep
        let px = device.download(out).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 {
                let v = TransferFunctions.bt709OETF(max(0, min(1, px[i * 4 + c])))
                rgba[i * 4 + c] = UInt8((v * 255).rounded())
            }
        }
        return rgba
    }
}
