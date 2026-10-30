#if canImport(Metal)
import Foundation
import Metal
import simd
import SQCore
import Testing
@testable import SQRender

/// Pro grade: key wires (a Step's key limits another Step; keys into a mixer box combine), the inverted key ("outside")
/// and the Layer mix: lowering, the CPU reference, GPU = CPU, and old graphs rendering as before.
@Suite struct ColorGraphKeyTests {
    private let px = SIMD3<Float>(0.3, 0.5, 0.7)
    private let inside = SIMD2<Float>(0.45, 0.55)    // the center of `ColorGraphRenderTests.window`
    private let outside = SIMD2<Float>(0.02, 0.02)

    private func ops(_ g: ColorGraph) -> [ColorOp] { ColorPipeline.graphOps(g, lutProvider: nil) }
    private func pipe(_ g: ColorGraph) -> ColorPipeline { ColorPipeline(source: .rec709, ops: [.conversion(nil)] + ops(g)) }
    private func run(_ g: ColorGraph, _ uv: SIMD2<Float>) -> SIMD3<Float> { pipe(g).process(px, uv: uv, aspect: 16.0 / 9) }
    private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-4) -> Bool { simd_reduce_max(simd_abs(a - b)) < tol }
    private func display(_ c: SIMD3<Float>) -> SIMD3<Float> { TransferFunctions.bt709OETF(c) }
    private func linear(_ c: SIMD3<Float>) -> SIMD3<Float> { TransferFunctions.bt709InverseOETF(c) }

    /// Donor (window) -> B (primaries): a graph [donor, B] with the key wire donor -> B.
    private func keyedStep(outside: Bool = false, qualifier: ColorQualifier? = nil) -> ColorGraph {
        var g = ColorGraph()
        let d = g.steps[0].id
        g.update(d) { $0.window = ColorGraphRenderTests.window(.ellipse); $0.keyOutside = outside; $0.qualifier = qualifier }
        let b = g.addStep(after: d)
        g.update(b) { $0.primaries = ColorGraphRenderTests.primaries(3) }
        #expect(g.connectKey(from: d, to: .step(b)) == nil)
        return g
    }

    private func plainB() -> ColorGraph {
        var g = ColorGraph(); g.update(g.steps[0].id) { $0.primaries = ColorGraphRenderTests.primaries(3) }; return g
    }

    // MARK: Old graphs

    @Test func graphsWithoutKeysLowerAndRenderAsBefore() {
        var g = ColorGraph()
        g.update(g.steps[0].id) { $0.primaries = ColorGraphRenderTests.primaries(2); $0.window = ColorGraphRenderTests.window(.ellipse) }
        let b = g.addStep(after: nil)
        g.update(b) { $0.primaries = ColorGraphRenderTests.primaries(4); $0.mix = 50 }
        let by = ops(g)
        func kind(_ o: ColorOp) -> String {
            switch o {
            case .stepBegin: "begin"; case .stepEnd: "end"; case .primaries: "prim"; default: "other"
            }
        }
        #expect(by.map(kind) == ["begin", "prim", "end", "begin", "prim", "end"], "no key ops for a graph without key wires")
        let hand: [ColorOp] = [.conversion(nil),
            .stepBegin, .primaries(ColorGraphRenderTests.primaries(2)),
            .stepEnd(qualifier: nil, window: ColorGraphRenderTests.window(.ellipse), mix: 1),
            .stepBegin, .primaries(ColorGraphRenderTests.primaries(4)), .stepEnd(qualifier: nil, window: nil, mix: 0.5)]
        let old = ColorPipeline(source: .rec709, ops: hand)
        for uv in [inside, outside] {
            #expect(pipe(g).process(px, uv: uv, aspect: 2) == old.process(px, uv: uv, aspect: 2), "bit for bit")
        }
    }

    @Test func aLayerAtNormalMixIsTheOldLayer() {
        var a = ColorStep(label: "A"); a.primaries = ColorGraphRenderTests.primaries(2)
        var l = ColorStep(label: "L"); l.primaries = ColorGraphRenderTests.primaries(6); l.kind = .layer; l.mix = 70
        var g = ColorGraph(); g.steps = [a, l]
        let o = ops(g)
        #expect(!o.contains { if case .layerMix = $0 { true } else { false } })
        var h = g; h.update(l.id) { $0.layerMix = .normal }
        #expect(pipe(g).process(px) == pipe(h).process(px))
    }

    // MARK: Step key

    @Test func aStepKeyLimitsTheStepItFeeds() {
        let g = keyedStep()
        let plain = run(ColorGraph(), inside)
        let full = run(plainB(), inside)
        #expect(near(run(g, inside), full), "inside the donor's window the Step shows fully")
        #expect(near(run(g, outside), plain), "outside the window the Step shows nothing")
        #expect(!near(full, plain))
    }

    @Test func outsideInvertsTheKey() {
        let g = keyedStep(outside: true)
        #expect(near(run(g, inside), run(ColorGraph(), inside)))
        #expect(near(run(g, outside), run(plainB(), outside)))
    }

    @Test func aDonorQualifierLimitsByColor() {
        var q = ColorQualifier(); q.hueCenter = 30; q.hueWidth = 10; q.satMin = 90; q.softness = 0   // misses the test pixel
        let g = keyedStep(qualifier: q)
        #expect(near(run(g, inside), run(ColorGraph(), inside)), "the qualifier selects nothing: no effect")
        let hit = keyedStep(outside: true, qualifier: q)
        #expect(near(run(hit, outside), run(plainB(), outside)), "outside of nothing is everything (window 0 -> 1 anyway)")
    }

    @Test func aDisabledDonorGivesNoKey() {
        var g = keyedStep()
        g.update(g.steps[0].id) { $0.enabled = false }
        #expect(near(run(g, outside), run(plainB(), outside)))
    }

    // MARK: Key mixer

    /// [D1, D2, A, P(parallel)]: D1 selects the window, D2 its inverse; both wired into the mixer of A's stack.
    private func mixed(_ mode: KeyMixMode) -> ColorGraph {
        var g = ColorGraph()
        let d1 = g.steps[0].id
        g.update(d1) { $0.window = ColorGraphRenderTests.window(.ellipse) }
        let d2 = g.addStep(after: d1)
        g.update(d2) { $0.window = ColorGraphRenderTests.window(.ellipse); $0.keyOutside = true }
        let a = g.addStep(after: d2)
        g.update(a) { $0.primaries = ColorGraphRenderTests.primaries(3); $0.keyMix = mode }
        let p = g.addStep(after: a, kind: .parallel)
        g.update(p) { $0.primaries = ColorGraphRenderTests.primaries(5) }
        #expect(g.connectKey(from: d1, to: .mixer(a)) == nil)
        #expect(g.connectKey(from: d2, to: .mixer(a)) == nil)
        return g
    }

    @Test func keysIntoAMixerCombineAndLimitTheStack() {
        var stack = mixed(.multiply)
        stack.removeKeyLinksForTest()
        let unkeyed = run(stack, inside)
        let base = run(ColorGraph(), inside)
        #expect(!near(unkeyed, base))
        // d1 = window, d2 = 1 - window. Inside: (1, 0). Outside: (0, 1).
        let expect: [(KeyMixMode, Float, Float)] = [(.add, 1, 1), (.multiply, 0, 0), (.subtract, 1, 0), (.max, 1, 1)]
        for (mode, kIn, kOut) in expect {
            let g = mixed(mode)
            for (uv, k) in [(inside, kIn), (outside, kOut)] {
                let full = run(stack, uv), none = run(ColorGraph(), uv)
                let want = linear(display(none) + (display(full) - display(none)) * k)
                #expect(near(run(g, uv), want, 2e-4), "\(mode) at \(uv)")
            }
        }
    }

    // MARK: Layer mix

    private func layerGraph(_ mode: LayerMixMode, mix: Float = 100) -> ColorGraph {
        var a = ColorStep(label: "A"); a.primaries = ColorGraphRenderTests.primaries(2)
        var l = ColorStep(label: "L"); l.primaries = ColorGraphRenderTests.primaries(6); l.kind = .layer
        l.layerMix = mode; l.mix = mix
        var g = ColorGraph(); g.steps = [a, l]
        return g
    }

    @Test func layerMixCompositesOverTheResultBelow() {
        var a1 = ColorStep(label: "A"); a1.primaries = ColorGraphRenderTests.primaries(2)
        var l1 = ColorStep(label: "L"); l1.primaries = ColorGraphRenderTests.primaries(6)
        var ga = ColorGraph(); ga.steps = [a1]
        var gl = ColorGraph(); gl.steps = [l1]
        let below = display(run(ga, inside)), top = display(run(gl, inside))
        let one = SIMD3<Float>(repeating: 1)
        let cases: [(LayerMixMode, SIMD3<Float>)] = [
            (.normal, top), (.add, below + top), (.subtract, below - top), (.multiply, below * top),
            (.screen, one - (one - below) * (one - top)), (.lighten, simd_max(below, top)), (.darken, simd_min(below, top)),
        ]
        for (mode, want) in cases {
            #expect(near(run(layerGraph(mode), inside), linear(want), 2e-4), "\(mode)")
            // The Step's Mix is the strength: half way between the result below and the composite.
            let half = linear(below + (want - below) * 0.5)
            #expect(near(run(layerGraph(mode, mix: 50), inside), half, 2e-4), "\(mode) at Mix 50")
        }
    }

    @Test func aLayerKeyFromAnotherStepControlsTheStrength() {
        var g = ColorGraph()
        let d = g.steps[0].id
        g.update(d) { $0.window = ColorGraphRenderTests.window(.ellipse) }
        let a = g.addStep(after: d)
        g.update(a) { $0.primaries = ColorGraphRenderTests.primaries(2) }
        let l = g.addStep(after: a, kind: .layer)
        g.update(l) { $0.primaries = ColorGraphRenderTests.primaries(6); $0.layerMix = .multiply }
        #expect(g.connectKey(from: d, to: .step(l)) == nil)
        var plain = g; plain.removeKeyLinksForTest()
        #expect(near(run(g, inside), run(plain, inside)), "full strength inside the window")
        var colOnly = plain; colOnly.update(l) { $0.enabled = false }
        #expect(near(run(g, outside), run(colOnly, outside)), "no layer outside the window")
    }

    // MARK: GPU

    private func gpuGraphs() -> [(String, ColorGraph)] {
        var q = ColorQualifier(); q.hueCenter = 30; q.hueWidth = 80; q.satMin = 5; q.softness = 40
        let step = keyedStep(outside: true, qualifier: q)
        var layers = layerGraph(.screen, mix: 60)
        let d = layers.steps[0].id
        _ = d
        var withKey = ColorGraph()
        let dd = withKey.steps[0].id
        withKey.update(dd) { $0.window = ColorGraphRenderTests.window(.rectangle); $0.qualifier = q }
        let a = withKey.addStep(after: dd)
        withKey.update(a) { $0.primaries = ColorGraphRenderTests.primaries(2) }
        let l = withKey.addStep(after: a, kind: .layer)
        withKey.update(l) { $0.primaries = ColorGraphRenderTests.primaries(6); $0.layerMix = .multiply; $0.curves = ColorGraphRenderTests.curves() }
        _ = withKey.connectKey(from: dd, to: .step(l))
        layers.update(layers.steps[0].id) { _ in }
        return [("step key", step), ("layer key", withKey), ("mixer add", mixed(.add)), ("mixer multiply", mixed(.multiply)),
                ("mixer subtract", mixed(.subtract)), ("mixer max", mixed(.max)),
                ("add", layerGraph(.add)), ("subtract", layerGraph(.subtract)), ("multiply", layerGraph(.multiply)),
                ("screen", layerGraph(.screen)), ("lighten", layerGraph(.lighten)), ("darken", layerGraph(.darken))]
    }

    @Test(.enabled(if: GPUTest.device != nil, "no Metal device")) func gpuMatchesCPU() throws {
        for src in [SourceColorSpace.rec709, .sLog3SGamut3Cine] {
            for (name, g) in gpuGraphs() {
                try ColorPipelineGPUTests.compare(ColorPipeline(source: src, ops: [.conversion(nil)] + ops(g)), "\(src) \(name)",
                                                  width: 96, height: 54)
            }
        }
    }

    @Test(.enabled(if: GPUTest.device != nil, "no Metal device")) func specialisedKernelsMatchTheGenericOnes() throws {
        let dev = GPUTest.device!, q = dev.makeCommandQueue()!
        let generic = try ColorPipelineGPU(device: dev), special = try ColorPipelineGPU(device: dev)
        generic.specialization = .off
        special.specialization = .sync
        let px = ColorPipelineGPUTests.randomPixels(count: 64 * 48, seed: 11)
        for (name, g) in gpuGraphs() {
            let p = ColorPipeline(source: .sLog3SGamut3Cine, ops: [.conversion(nil)] + ops(g))
            var outs: [[SIMD3<Float>]] = []
            for gpu in [generic, special] {
                let s = GPUTest.makeTexture(dev, width: 64, height: 48, format: .rgba32Float)
                let d = GPUTest.makeTexture(dev, width: 64, height: 48, format: .rgba32Float)
                GPUTest.upload(s, px, alpha: nil)
                _ = GPUTest.run(q) { try? gpu.encode(p, source: s, destination: d, commandBuffer: $0) }
                outs.append(GPUTest.download(d))
            }
            #expect(outs[0] == outs[1], "\(name): specialised != generic")
        }
    }
}

private extension ColorGraph {
    /// Test helper: the same Steps without key wires.
    mutating func removeKeyLinksForTest() { for l in keyLinks { disconnectKey(l) } }
}
#endif
