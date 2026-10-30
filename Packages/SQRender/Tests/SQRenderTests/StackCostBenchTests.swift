#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

/// Perf stream: GPU and CPU cost of one representative playback frame (4K 10-bit 4:2:2 clip, Motion, grade, Gaussian Blur +
/// Film Grain, Magic mask, transition layer to a second graded clip, captions text layer) at 1080p and 4K canvases, plus
/// the same stack with one feature taken out at a time (the difference is that feature's cost).
/// Run: `SQ_STACK_BENCH=1 SQ_TEST_FILTER=StackCostBench scripts/test.sh SQRender`; numbers go to `SQ_PERF_OUT` (or
/// $TMPDIR/sqstackcost.txt). Best of N (machine shared with other agents: noise only adds time).
@Suite(.serialized) struct StackCostBench {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SQ_STACK_BENCH"] != nil }

    struct Config {
        var name: String
        var grade = true, blur = true, grain = true, magic = true, transition = true, captions = true
        /// Without the transition: draw clip B under clip A anyway (so "full - stack" is the transition's own cost).
        var stackB = false
        /// Only clip B (graded or not), no transition: the cost of one plain 4K layer.
        var onlyB = false
    }

    static func source422(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, attrs as CFDictionary, &pb)
                     == kCVReturnSuccess)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let yp = CVPixelBufferGetBaseAddressOfPlane(b, 0)!, ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        for y in 0..<h {
            let row = (yp + y * ys).assumingMemoryBound(to: UInt16.self)
            for x in 0..<w { row[x] = UInt16(64 + (x * 7 + y * 3) % 876) << 6 }
        }
        let cp = CVPixelBufferGetBaseAddressOfPlane(b, 1)!, cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
        for y in 0..<h {
            let row = (cp + y * cs).assumingMemoryBound(to: UInt16.self)
            for x in 0..<w { row[x] = UInt16(400 + (x + y) % 224) << 6 }
        }
        return b
    }

    static func caption(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb) == kCVReturnSuccess)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<h {
            let row = (base + y * stride).assumingMemoryBound(to: Float16.self)
            for x in 0..<w {
                let a: Float16 = (x / 24 + y / 24) % 3 == 0 ? 1 : 0
                row[x * 4] = a; row[x * 4 + 1] = a; row[x * 4 + 2] = a; row[x * 4 + 3] = a
            }
        }
        return b
    }

    static func hint(_ w: Int, _ h: Int) -> VideoTrackInfo {
        VideoTrackInfo(width: w, height: h, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                       nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    }

    static func grade() -> ColorPipeline {
        var basic = BasicCorrection(); basic.exposure = 0.3; basic.contrast = 25; basic.saturation = 120
        var curves = RGBCurves()
        curves.master = [CurvePoint(0, 0.02), CurvePoint(0.3, 0.25), CurvePoint(0.7, 0.78), CurvePoint(1, 1)]
        var creative = CreativeLook(); creative.vibrance = 15
        return ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic), .creative(creative), .curves(curves)])
    }

    /// Clip A's effects: Gaussian Blur (Blurriness 10) + Film Grain + one Magic mask.
    static func effects(_ c: Config, matte: UUID) -> ClipEffects {
        var clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        if c.blur, let id = clip.addEffect(kind: ClipEffect.gaussianBlurKind), let i = clip.effects.firstIndex(where: { $0.id == id }) {
            clip.effects[i].parameters[ClipEffect.blurrinessKey] = AnimatedProperty(10)
        }
        if c.grain { _ = clip.addEffect(kind: ClipEffect.grainKind) }
        var fx = clip.effects(at: Time(1, 1))
        if c.magic { fx.masks = [MaskShape(polygon: [], feather: 0, source: .magic, matteKey: matte)] }
        return fx
    }

    /// A new matte every frame (as in playback: each frame has its own tracked matte).
    static func matte(frame: Int) -> SubjectMatte {
        let w = 512, h = 288
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { v[y * w + x] = (x + frame) % 512 < 300 ? 1 : 0 } }
        return SubjectMatte(width: w, height: h, values: v)
    }

    static func nodes(_ c: Config, canvas w: Int, _ h: Int, a: CVPixelBuffer, b: CVPixelBuffer, cap: CVPixelBuffer,
                      frame: Int) -> [RenderNode] {
        let s = Double(w) / 3840
        let id = UUID()
        var la = RenderLayer(content: .frame(a, colorHint: hint(3840, 2160)),
                             transform: ClipTransform(position: Vec2(12, -8), scale: Vec2(s * 1.05, s * 1.05), rotation: 2),
                             colorPipeline: c.grade ? grade() : nil, effects: effects(c, matte: id))
        if c.magic { la.mattes = [id: matte(frame: frame)] }
        let lb = RenderLayer(content: .frame(b, colorHint: hint(3840, 2160)), transform: ClipTransform(scale: Vec2(s, s)),
                             colorPipeline: c.grade ? grade() : nil)
        var out: [RenderNode]
        if c.transition {
            let push = TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.4, 0)), incoming: TransitionSide(offset: Vec2(0.6, 0)),
                                        compose: .sum)
            out = [.transition(format: fmt(w, h), render: push, first: [.layer(la)], second: [.layer(lb)])]
        } else {
            out = c.onlyB ? [.layer(lb)] : c.stackB ? [.layer(lb), .layer(la)] : [.layer(la)]
        }
        if c.captions {
            out.append(.layer(RenderLayer(content: .linearPremultiplied(cap, width: Double(w) * 0.8, height: Double(h) * 0.12),
                                          transform: ClipTransform(position: Vec2(0, Double(h) * 0.3)))))
        }
        return out
    }

    static func fmt(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 30)) }

    struct Cost { var gpu: Double; var cpu: Double }

    /// Best GPU ms and best CPU encode ms (building the command buffer) over `runs` frames after 3 warm-ups.
    static func measure(_ c: Config, comp: Compositor, queue q: MTLCommandQueue, w: Int, h: Int, a: CVPixelBuffer,
                        b: CVPixelBuffer, cap: CVPixelBuffer, target t: MTLTexture, runs: Int) throws -> Cost {
        var gpu = Double.infinity, cpu = Double.infinity
        let clock = ContinuousClock()
        for i in 0..<(runs + 3) {
            let n = nodes(c, canvas: w, h, a: a, b: b, cap: cap, frame: i)
            let cb = q.makeCommandBuffer()!
            let d = try clock.measure { try comp.render(nodes: n, format: fmt(w, h), into: t, commandBuffer: cb) }
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            if i >= 3 {
                gpu = min(gpu, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
                cpu = min(cpu, SQTiming.ms(d))
            }
        }
        return Cost(gpu: gpu, cpu: cpu)
    }

    @Test(.enabled(if: StackCostBench.enabled)) func measureStack() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let a = Self.source422(3840, 2160), b = Self.source422(3840, 2160)
        let configs: [Config] = [
            Config(name: "full"),
            { var c = Config(name: "-magic"); c.magic = false; return c }(),
            { var c = Config(name: "-blur"); c.blur = false; return c }(),
            { var c = Config(name: "-grain"); c.grain = false; return c }(),
            { var c = Config(name: "-blur-grain"); c.blur = false; c.grain = false; return c }(),
            { var c = Config(name: "-transition"); c.transition = false; return c }(),
            { var c = Config(name: "stack"); c.transition = false; c.stackB = true; return c }(),
            { var c = Config(name: "B"); c.transition = false; c.onlyB = true; c.captions = false; return c }(),
            { var c = Config(name: "B-grade"); c.transition = false; c.onlyB = true; c.captions = false; c.grade = false; return c }(),
            { var c = Config(name: "-captions"); c.captions = false; return c }(),
            { var c = Config(name: "-grade"); c.grade = false; return c }(),
            Config(name: "plain", grade: false, blur: false, grain: false, magic: false, transition: false, captions: false),
        ]
        let runs = Int(ProcessInfo.processInfo.environment["SQ_STACK_RUNS"] ?? "") ?? 15
        var lines: [String] = []
        for (w, h, name) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            for playback in [true, false] {
                let comp = try Compositor(device: dev)
                comp.colorGPU.specialization = .sync      // steady state: the app's async compile is done after a few frames
                comp.gradesAtDisplaySize = playback
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
                td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
                let t = dev.makeTexture(descriptor: td)!
                let cap = Self.caption(Int(Double(w) * 0.8), Int(Double(h) * 0.12))
                var line = "SQSTACK \(name) \(playback ? "play" : "export"):"
                for c in configs {
                    let r = try Self.measure(c, comp: comp, queue: q, w: w, h: h, a: a, b: b, cap: cap, target: t, runs: runs)
                    line += String(format: " %@ %.2f/%.2f", c.name, r.gpu, r.cpu)
                }
                lines.append(line)
                NSLog("%@", line)
            }
        }
        let text = "gpu/cpu-encode ms, best of \(runs)\n" + lines.joined(separator: "\n") + "\n"
        let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] ?? (NSTemporaryDirectory() + "sqstackcost.txt")
        if let hd = FileHandle(forWritingAtPath: path) { try? hd.seekToEnd(); try? hd.write(contentsOf: Data(text.utf8)); try? hd.close() }
        else { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    /// A/B of one switch, interleaved frame by frame (a loaded machine slows both sides alike): GPU ms best of N, off / on.
    static func measureAB(_ name: String, nodes: [RenderNode], w: Int, h: Int, runs: Int,
                          set: (Compositor, Bool) -> Void) throws -> String {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return "" }
        let comp = try Compositor(device: dev)
        comp.colorGPU.specialization = .sync
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let t = dev.makeTexture(descriptor: td)!
        var best = [Double.infinity, Double.infinity]
        for i in 0..<(runs + 3) {
            for side in 0..<2 {
                set(comp, side == 1)
                let cb = q.makeCommandBuffer()!
                try comp.render(nodes: nodes, format: fmt(w, h), into: t, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                if i >= 3 { best[side] = min(best[side], (cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
        }
        return String(format: "%@ %.2f -> %.2f", name, best[0], best[1])
    }

    static func appendOut(_ line: String) {
        NSLog("%@", line)
        let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] ?? (NSTemporaryDirectory() + "sqstackcost.txt")
        if let hd = FileHandle(forWritingAtPath: path) { try? hd.seekToEnd(); try? hd.write(contentsOf: Data((line + "\n").utf8)); try? hd.close() }
        else { try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }

    /// Fused grain / scanlines draw vs the three-step look pass.
    @Test(.enabled(if: StackCostBench.enabled)) func measureLookFusion() throws {
        let runs = Int(ProcessInfo.processInfo.environment["SQ_STACK_RUNS"] ?? "") ?? 15
        let a = Self.source422(3840, 2160)
        var line = "SQLOOKFUSION"
        for (w, h, name) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            for graded in [false, true] {
                var c = Config(name: "grain"); c.grade = graded; c.blur = false; c.magic = false
                c.transition = false; c.captions = false
                let n = Self.nodes(c, canvas: w, h, a: a, b: a, cap: Self.caption(8, 8), frame: 0)
                line += " | " + (try Self.measureAB("\(name) \(graded ? "graded" : "plain")", nodes: n, w: w, h: h, runs: runs) {
                    $0.fusesPointwiseLook = $1
                })
            }
        }
        Self.appendOut(line)
    }

    /// Transition mix in the final draw vs mix kernel + texture + draw (ungraded sides, so the transition plumbing dominates).
    @Test(.enabled(if: StackCostBench.enabled)) func measureTransitionFusion() throws {
        let runs = Int(ProcessInfo.processInfo.environment["SQ_STACK_RUNS"] ?? "") ?? 15
        let a = Self.source422(3840, 2160)
        var line = "SQTRANSITIONFUSION"
        for (w, h, name) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            for graded in [false, true] {
                var c = Config(name: "push"); c.grade = graded; c.blur = false; c.grain = false; c.magic = false; c.captions = false
                let n = Self.nodes(c, canvas: w, h, a: a, b: a, cap: Self.caption(8, 8), frame: 0)
                line += " | " + (try Self.measureAB("\(name) \(graded ? "graded" : "plain")", nodes: n, w: w, h: h, runs: runs) {
                    $0.fusesTransitionMix = $1
                })
            }
        }
        Self.appendOut(line)
    }

    /// One 4K 10-bit 4:2:2 layer at 1:1 in a 4K canvas, graded with each op alone (GPU ms, best of N).
    @Test(.enabled(if: StackCostBench.enabled)) func measureGradeOps() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let src = Self.source422(3840, 2160)
        var basic = BasicCorrection(); basic.exposure = 0.3; basic.contrast = 25; basic.saturation = 120
        var curves = RGBCurves()
        curves.master = [CurvePoint(0, 0.02), CurvePoint(0.3, 0.25), CurvePoint(0.7, 0.78), CurvePoint(1, 1)]
        var creative = CreativeLook(); creative.vibrance = 15
        let sets: [(String, [ColorOp]?)] = [
            ("none", nil), ("conv", [.conversion(nil)]), ("basic", [.conversion(nil), .basic(basic)]),
            ("creative", [.conversion(nil), .creative(creative)]), ("curves", [.conversion(nil), .curves(curves)]),
            ("all", [.conversion(nil), .basic(basic), .creative(creative), .curves(curves)]),
        ]
        let comp = try Compositor(device: dev)
        comp.colorGPU.specialization = .sync
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 3840, height: 2160, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let t = dev.makeTexture(descriptor: td)!
        var line = "SQGRADEOPS 4K:"
        for (name, ops) in sets {
            let layer = RenderLayer(content: .frame(src, colorHint: Self.hint(3840, 2160)),
                                    colorPipeline: ops.map { ColorPipeline(source: .rec709, ops: $0) })
            var best = Double.infinity
            for i in 0..<40 {
                let cb = q.makeCommandBuffer()!
                try comp.render([layer], format: Self.fmt(3840, 2160), into: t, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                if i >= 10 { best = min(best, (cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
            line += String(format: " %@ %.2f", name, best)
        }
        line += " (specialised passes \(comp.colorGPU.specialisedPasses))"
        NSLog("%@", line)
        let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] ?? (NSTemporaryDirectory() + "sqstackcost.txt")
        if let hd = FileHandle(forWritingAtPath: path) { try? hd.seekToEnd(); try? hd.write(contentsOf: Data((line + "\n").utf8)); try? hd.close() }
        else { try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }

    /// Mask stream: a new Magic matte every frame (one mask; two masks packed into one texture; one mask as an effect's
    /// input) on one 4K layer 1:1. CPU = building the command buffer (matte upload, mask buffer), GPU = the frame.
    /// Median and best of N, plus matte textures allocated over the run (pooling keeps this flat).
    @Test(.enabled(if: StackCostBench.enabled)) func measureMatteUpload() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let runs = Int(ProcessInfo.processInfo.environment["SQ_STACK_RUNS"] ?? "") ?? 15
        let src = Self.source422(3840, 2160)
        let a = UUID(), b = UUID()
        let mattes = (0..<(runs + 3)).map { Self.matte(frame: $0) }
        let mattes2 = (0..<(runs + 3)).map { Self.matte(frame: $0 + 200) }
        let one = MaskShape(polygon: [], feather: 0, source: .magic, matteKey: a)
        let two = MaskShape(polygon: [], feather: 0, mode: .subtract, source: .magic, matteKey: b)
        let cases: [(String, (Int) -> RenderLayer)] = [
            ("one", { i in var l = RenderLayer(content: .frame(src, colorHint: Self.hint(3840, 2160)),
                                               effects: ClipEffects(segments: [], masks: [one]))
                      l.mattes = [a: mattes[i]]; return l }),
            ("packed", { i in var l = RenderLayer(content: .frame(src, colorHint: Self.hint(3840, 2160)),
                                                  effects: ClipEffects(segments: [], masks: [one, two]))
                         l.mattes = [a: mattes[i], b: mattes2[i]]; return l }),
            ("input", { i in var l = RenderLayer(content: .frame(src, colorHint: Self.hint(3840, 2160)),
                                                 effects: ClipEffects(segments: [EffectSegment(filter: .invert(channel: 0, blend: 0),
                                                                                               scope: [one]), EffectSegment()]))
                        l.mattes = [a: mattes[i]]; return l }),
        ]
        var line = "SQMATTEUPLOAD 4K (cpu med/best, gpu med/best ms, matte textures made):"
        for (name, make) in cases {
            let comp = try Compositor(device: dev)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 3840, height: 2160, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
            let t = dev.makeTexture(descriptor: td)!
            var cpu: [Double] = [], gpu: [Double] = []
            let clock = ContinuousClock()
            for i in 0..<(runs + 3) {
                let layer = make(i)
                let cb = q.makeCommandBuffer()!
                let d = try clock.measure { try comp.render([layer], format: Self.fmt(3840, 2160), into: t, commandBuffer: cb) }
                cb.commit(); cb.waitUntilCompleted()
                if i >= 3 { cpu.append(SQTiming.ms(d)); gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
            cpu.sort(); gpu.sort()
            line += String(format: " | %@ %.3f/%.3f, %.3f/%.3f, %d", name, cpu[cpu.count / 2], cpu[0], gpu[gpu.count / 2], gpu[0],
                           comp.matteTexturesMade)
        }
        Self.appendOut(line)
    }
}
#endif
