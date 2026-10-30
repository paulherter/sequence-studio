#if canImport(Metal)
import Foundation
import Metal
import simd
import SQCore
import Testing
@testable import SQRender

/// Pro grade (Color Graph): lowering to color ops, the CPU reference of Steps / windows / qualifiers, GPU = CPU, pass
/// fitting of limited Steps, and the 4K cost of 6 and 12 Steps.
@Suite struct ColorGraphRenderTests {
    let media = UUID()

    static func primaries(_ k: Float = 1) -> StepPrimaries {
        var p = StepPrimaries()
        p.lift = ColorTriple(0.02 * k, 0, -0.01 * k); p.gamma = ColorTriple(1 + 0.1 * k, 0.95, 1)
        p.gain = ColorTriple(1.1, 1, 0.9 + 0.02 * k); p.offset = ColorTriple(0, 0.01, 0.005)
        p.contrast = 1.15; p.saturation = 0.85
        return p
    }

    static func curves() -> RGBCurves {
        var c = RGBCurves(); c.master = [CurvePoint(0, 0.03), CurvePoint(0.5, 0.55), CurvePoint(1, 0.97)]; return c
    }

    static func hueCurves() -> HueCurves {
        var h = HueCurves(); h.hueVsSat = [CurvePoint(0, 0.5), CurvePoint(0.3, 0.7), CurvePoint(1, 0.5)]; return h
    }

    static func qualifier() -> ColorQualifier {
        var q = ColorQualifier(); q.hueCenter = 30; q.hueWidth = 80; q.satMin = 5; q.softness = 40; return q
    }

    static func window(_ shape: StepWindow.Shape, invert: Bool = false) -> StepWindow {
        var w = StepWindow(shape: shape); w.centerX = 0.45; w.centerY = 0.55; w.width = 0.6; w.height = 0.4
        w.rotation = 20; w.softness = 0.3; w.invert = invert
        return w
    }

    static let look = GradeFusionTests.look

    /// Graph-shaped chains (the way `ColorPipeline.from` lowers a graph).
    static func chains(_ src: SourceColorSpace) -> [(String, ColorPipeline)] {
        var twelve: [ColorOp] = [.conversion(nil)]
        for i in 0..<12 {
            let p = ColorOp.primaries(primaries(Float(i) / 12))
            if i % 3 == 0 {
                twelve += [.stepBegin, p, .curves(curves()), .stepEnd(qualifier: qualifier(), window: window(.ellipse))]
            } else {
                twelve.append(p)
            }
        }
        twelve.append(.look(look, intensity: 1))
        let limited: [ColorOp] = [
            .conversion(nil), .primaries(primaries(0.5)), .stepBegin, .primaries(primaries()), .curves(curves()),
            .hueCurves(hueCurves()), .look(look, intensity: 0.7), .stepEnd(qualifier: qualifier(), window: window(.linear))]
        return [
            ("one step", ColorPipeline(source: src, ops: [.conversion(nil), .primaries(primaries())])),
            ("qualified step", ColorPipeline(source: src, ops: [.conversion(nil), .stepBegin, .primaries(primaries()),
                                                                .stepEnd(qualifier: qualifier(), window: nil)])),
            ("ellipse window", ColorPipeline(source: src, ops: [.conversion(nil), .stepBegin, .primaries(primaries()),
                                                                .curves(curves()), .stepEnd(qualifier: nil, window: window(.ellipse))])),
            ("rectangle window inverted", ColorPipeline(source: src, ops: [
                .conversion(nil), .stepBegin, .primaries(primaries()),
                .stepEnd(qualifier: nil, window: window(.rectangle, invert: true))])),
            ("linear window + qualifier + LUT", ColorPipeline(source: src, ops: limited)),
            ("twelve steps", ColorPipeline(source: src, ops: twelve)),
        ]
    }

    // MARK: Lowering

    @Test func graphLowersToStepOpsAfterTheInLUT() throws {
        let p = StubProvider()
        let inLUT = GradeFusionTests.conversionLUT
        p.table[.file("/in.cube")] = inLUT; p.table[.file("/step.cube")] = Self.look; p.table[.file("/out.cube")] = Self.look
        var g = ColorGraph()
        g.inputLUT = .file("/in.cube")
        g.update(g.steps[0].id) { $0.primaries = Self.primaries() }
        let off = g.addStep(after: nil)
        g.update(off) { $0.primaries.saturation = 0 }
        g.setEnabled(off, false)
        _ = g.addStep(after: nil)                                   // neutral: skipped
        let limited = g.addStep(after: nil)
        g.update(limited) {
            $0.curves = Self.curves(); $0.lut = .file("/step.cube"); $0.lutIntensity = 50
            $0.window = Self.window(.ellipse)
        }
        let window = g.addStep(after: nil)                          // a window alone changes nothing: neutral
        g.update(window) { $0.window = Self.window(.linear) }
        g.outputLUT = .file("/out.cube"); g.outputLUTIntensity = 80
        var color = ClipColor.default
        color.graph = g
        color.effects[0].basic.exposure = 2                         // ignored while the graph renders
        let pipe = ColorPipeline.from(clipColor: color, mediaID: media, mediaInfo: nil, lutProvider: p)
        let kinds = pipe.ops.map { op -> String in
            switch op {
            case .conversion(let l): l == nil ? "conv" : "convLUT"
            case .primaries: "prim"
            case .curves: "curves"
            case .look(_, let k): "look\(Int(k * 100))"
            case .stepBegin: "begin"
            case .stepEnd(_, let w, _): w == nil ? "end" : "endW"
            default: "other"
            }
        }
        #expect(kinds == ["convLUT", "prim", "begin", "curves", "look50", "endW", "look80"])
        // Pro's eye off (conversion only): just the In LUT.
        color.graph = g.conversionOnly
        let only = ColorPipeline.from(clipColor: color, mediaID: media, mediaInfo: nil, lutProvider: p)
        #expect(only.ops.count == 1 && only.conversionLUT != nil)
    }

    @Test func automaticInLUTFollowsTheSimpleRules() {
        let p = StubProvider(); p.table[.embedded(media)] = Self.look
        let slog = MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Look")
        var color = ClipColor.default
        color.graph = ColorGraph()
        #expect(ColorPipeline.from(clipColor: color, mediaID: media, mediaInfo: slog, lutProvider: p).conversionLUT != nil)
        color.useEmbeddedLUT = false
        #expect(ColorPipeline.from(clipColor: color, mediaID: media, mediaInfo: slog, lutProvider: p).conversionLUT == nil)
    }

    // MARK: CPU reference

    @Test func primariesStepMatchesTheModelOnTheDisplaySignal() {
        let pipe = ColorPipeline(source: .rec709, ops: [.conversion(nil), .primaries(Self.primaries())])
        let px = SIMD3<Float>(0.3, 0.5, 0.7)
        let t = Self.primaries().apply((0.3, 0.5, 0.7))
        let expected = TransferFunctions.bt709InverseOETF(SIMD3(t.0, t.1, t.2))
        #expect(simd_reduce_max(simd_abs(pipe.process(px) - expected)) < 1e-4)
    }

    @Test func windowLimitsTheStep() {
        let step: [ColorOp] = [.stepBegin, .primaries(Self.primaries(2)), .stepEnd(qualifier: nil, window: Self.window(.ellipse))]
        let plain = ColorPipeline(source: .rec709)
        let limited = ColorPipeline(source: .rec709, ops: [.conversion(nil)] + step)
        let full = ColorPipeline(source: .rec709, ops: [.conversion(nil), .primaries(Self.primaries(2))])
        let px = SIMD3<Float>(0.3, 0.5, 0.7)
        let center = SIMD2<Float>(0.45, 0.55), corner = SIMD2<Float>(0.02, 0.02)
        #expect(simd_reduce_max(simd_abs(limited.process(px, uv: center) - full.process(px, uv: center))) < 1e-6)
        #expect(simd_reduce_max(simd_abs(limited.process(px, uv: corner) - plain.process(px, uv: corner))) < 1e-6)
        var w = Self.window(.ellipse); w.invert = true
        let inverted = ColorPipeline(source: .rec709, ops: [.conversion(nil), .stepBegin, .primaries(Self.primaries(2)),
                                                           .stepEnd(qualifier: nil, window: w)])
        #expect(simd_reduce_max(simd_abs(inverted.process(px, uv: corner) - full.process(px, uv: corner))) < 1e-6)
        // A linear window selects the side above its edge.
        let lin = ColorPipeline(source: .rec709, ops: [.conversion(nil), .stepBegin, .primaries(Self.primaries(2)),
                                                      .stepEnd(qualifier: nil, window: StepWindow(shape: .linear))])
        let top = SIMD2<Float>(0.5, 0.05), bottom = SIMD2<Float>(0.5, 0.95)
        #expect(simd_reduce_max(simd_abs(lin.process(px, uv: top) - full.process(px, uv: top))) < 1e-6)
        #expect(simd_reduce_max(simd_abs(lin.process(px, uv: bottom) - plain.process(px, uv: bottom))) < 1e-6)
    }

    @Test func qualifierReadsTheStepInput() {
        var q = ColorQualifier(); q.hueCenter = 220; q.hueWidth = 60; q.satMin = 20; q.softness = 0
        let ops: [ColorOp] = [.conversion(nil), .stepBegin, .primaries(Self.primaries(2)), .stepEnd(qualifier: q, window: nil)]
        let limited = ColorPipeline(source: .rec709, ops: ops)
        let plain = ColorPipeline(source: .rec709)
        let full = ColorPipeline(source: .rec709, ops: [.conversion(nil), .primaries(Self.primaries(2))])
        let blue = SIMD3<Float>(0.1, 0.3, 0.8), red = SIMD3<Float>(0.8, 0.2, 0.1)
        #expect(simd_reduce_max(simd_abs(limited.process(blue) - full.process(blue))) < 1e-5)
        #expect(simd_reduce_max(simd_abs(limited.process(red) - plain.process(red))) < 1e-6)
    }

    // MARK: GPU

    @Test func passesKeepEveryLimitedStepInOnePass() {
        for (name, p) in Self.chains(.sLog3SGamut3Cine) {
            for pass in ColorPipelineGPU.passes(for: p) {
                var open = false
                for s in pass.sections {
                    if s.head.x == ColorPipelineGPU.kindStepBegin { #expect(!open, "\(name)"); open = true }
                    if s.head.x == ColorPipelineGPU.kindStepEnd { #expect(open, "\(name)"); open = false }
                }
                #expect(!open, "\(name): a Step crosses a pass boundary")
            }
        }
    }

    @Test(.enabled(if: GPUTest.device != nil, "no Metal device")) func gpuMatchesCPU() throws {
        var worst: Float = 0
        for src in [SourceColorSpace.rec709, .sLog3SGamut3Cine, .appleLog] {
            for (name, p) in Self.chains(src) {
                let (e, _) = try ColorPipelineGPUTests.compare(p, "\(src) \(name)", width: 96, height: 54)
                worst = max(worst, e)
            }
        }
        print("Color Graph GPU worst normalized error (<=1 passes):", worst)
    }

    /// Perf (printed): GPU ms of the chain alone on a 4K rgba16Float texture, specialised kernels (export / playback path).
    @Test(.enabled(if: GPUTest.device != nil, "no Metal device")) func timing4K() throws {
        let dev = GPUTest.device!, q = dev.makeCommandQueue()!
        let gpu = try ColorPipelineGPU(device: dev)
        gpu.specialization = .sync
        let t = GPUTest.makeTexture(dev, width: 3840, height: 2160, format: .rgba16Float)
        func steps(_ n: Int, curves: Bool) -> ColorPipeline {
            ColorPipeline(source: .sLog3SGamut3Cine, ops: [.conversion(nil)] + (0..<n).flatMap { i -> [ColorOp] in
                var o: [ColorOp] = [.primaries(Self.primaries(Float(i + 1) / Float(n)))]
                if curves && i % 2 == 0 { o.append(.curves(Self.curves())) }
                return o
            })
        }
        func best(_ p: ColorPipeline) throws -> Double {
            var b = Double.infinity
            for _ in 0..<10 {
                let cb = q.makeCommandBuffer()!
                try gpu.encode(p, source: t, destination: t, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                b = min(b, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return b
        }
        let six = steps(6, curves: false), twelve = steps(12, curves: false)
        let sixC = steps(6, curves: true), twelveC = steps(12, curves: true)
        let r = try (best(six), best(twelve), best(sixC), best(twelveC))
        print("PERF Color Graph 4K rgba16Float chain: 6 Steps \(r.0) ms (\(six.gpuPasses.count) pass), 12 Steps \(r.1) ms "
              + "(\(twelve.gpuPasses.count)); with curves on every 2nd Step: 6 \(r.2) ms (\(sixC.gpuPasses.count)), "
              + "12 \(r.3) ms (\(twelveC.gpuPasses.count))")
        // Budgets 1.5 / 4 ms; generous here (machine under load from parallel builds).
        #expect(r.0 < 6 && r.1 < 12)
    }
}
#endif
