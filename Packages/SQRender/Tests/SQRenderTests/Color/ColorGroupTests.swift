#if canImport(Metal)
import Foundation
import Metal
import simd
import SQCore
import Testing
@testable import SQRender

/// Pro grade: Parallel and Layer Steps (columns lowered to a group) and the per-Step Mix: lowering, the CPU reference,
/// GPU = CPU in the generic and the specialised kernels, one pass per group, and the unchanged cost of serial graphs.
@Suite struct ColorGroupTests {
    let media = UUID()

    private func ops(_ g: ColorGraph, lut: StubProvider? = nil) -> [ColorOp] {
        ColorPipeline.graphOps(g, lutProvider: lut)
    }

    private func tag(_ o: ColorOp) -> String {
        switch o {
        case .primaries: "prim"
        case .curves: "curves"
        case .hueCurves: "hue"
        case .look: "look"
        case .stepBegin: "begin"
        case .stepEnd(_, _, let m): m < 1 ? "endMix" : "end"
        case .groupBegin: "gbegin"
        case .branchEnd(let layer, _, _, _): layer ? "layer" : "branch"
        case .groupMerge(let n): "merge\(n)"
        case .groupEnd: "gend"
        default: "other"
        }
    }

    private func graph(_ edit: (inout ColorGraph) -> Void) -> ColorGraph {
        var g = ColorGraph()
        g.update(g.steps[0].id) { $0.primaries = ColorGraphRenderTests.primaries(1) }
        edit(&g)
        return g
    }

    // MARK: Lowering

    @Test func serialOnlyGraphLowersLikeBefore() {
        let g = graph { g in
            let b = g.addStep(after: nil)
            g.update(b) { $0.primaries = ColorGraphRenderTests.primaries(2); $0.curves = ColorGraphRenderTests.curves() }
        }
        #expect(ops(g).map(tag) == ["prim", "prim", "curves"], "no registers, no extra ops")
    }

    @Test func mixBelow100WrapsASerialStep() {
        let g = graph { $0.update($0.steps[0].id) { $0.mix = 40 } }
        let o = ops(g)
        #expect(o.map(tag) == ["begin", "prim", "endMix"])
        if case .stepEnd(_, _, let m) = o[2] { #expect(abs(m - 0.4) < 1e-6) }
        let zero = graph { $0.update($0.steps[0].id) { $0.mix = 0 } }
        #expect(ops(zero).isEmpty, "Mix 0 shows nothing of the Step")
    }

    @Test func parallelColumnLowersToAGroup() {
        let g = graph { g in
            let p = g.addStep(after: nil, kind: .parallel)
            g.update(p) { $0.primaries = ColorGraphRenderTests.primaries(3) }
        }
        #expect(ops(g).map(tag) == ["gbegin", "prim", "branch", "prim", "branch", "merge2", "gend"])
    }

    @Test func layerWithoutParallelsStillAveragesTheHead() {
        let g = graph { g in
            let l = g.addStep(after: nil, kind: .layer)
            g.update(l) { $0.primaries = ColorGraphRenderTests.primaries(3); $0.qualifier = ColorGraphRenderTests.qualifier() }
        }
        #expect(ops(g).map(tag) == ["gbegin", "prim", "branch", "merge1", "prim", "layer", "gend"])
    }

    @Test func neutralLayerAndDisabledBranchesAreSkipped() {
        let g = graph { g in
            _ = g.addStep(after: nil, kind: .layer)                    // neutral
            let p = g.addStep(after: nil, kind: .parallel)
            g.update(p) { $0.primaries = ColorGraphRenderTests.primaries(3) }
            g.setEnabled(p, false)
        }
        #expect(ops(g).map(tag) == ["prim"], "falls back to the plain serial Step")
    }

    @Test func aGroupThatDoesNotFitDropsTheBranchThatWouldNot() {
        let lut = StubProvider()
        lut.table[.file("/a.cube")] = ColorGraphRenderTests.look
        lut.table[.file("/b.cube")] = ColorGraphRenderTests.look
        let g = graph { g in
            g.update(g.steps[0].id) { $0.lut = .file("/a.cube") }
            let p = g.addStep(after: nil, kind: .parallel)
            g.update(p) { $0.lut = .file("/b.cube") }                  // a second LUT cannot share the pass
            let q = g.addStep(after: p, kind: .parallel)
            g.update(q) { $0.primaries = ColorGraphRenderTests.primaries(3) }
        }
        let o = ops(g, lut: lut)
        #expect(o.filter { if case .look = $0 { true } else { false } }.count == 1)
        #expect(o.map(tag).contains("merge2"), "head and the third branch stay")
    }

    @Test func groupsLandInOnePass() {
        let g = graph { g in
            for k in 0..<3 {
                let p = g.addStep(after: g.steps[g.steps.count - 1].id, kind: .parallel)
                g.update(p) { $0.primaries = ColorGraphRenderTests.primaries(Float(k + 2)); $0.curves = k == 0 ? ColorGraphRenderTests.curves() : RGBCurves() }
            }
            let l = g.addStep(after: nil, kind: .layer)
            g.update(l) { $0.primaries = ColorGraphRenderTests.primaries(5); $0.window = ColorGraphRenderTests.window(.ellipse) }
        }
        let p = ColorPipeline(source: .rec709, ops: [.conversion(nil)] + ops(g))
        var open = false
        for pass in p.gpuPasses {
            for s in pass.sections {
                if s.head.x == ColorPipelineGPU.kindGroupBegin { #expect(!open); open = true }
                if s.head.x == ColorPipelineGPU.kindGroupEnd { #expect(open); open = false }
            }
            #expect(open == false, "a column crosses a pass boundary")
        }
    }

    // MARK: CPU reference

    private func pipe(_ g: ColorGraph) -> ColorPipeline {
        ColorPipeline(source: .rec709, ops: [.conversion(nil)] + ops(g))
    }

    private func single(_ s: ColorStep) -> ColorPipeline {
        var g = ColorGraph(); g.steps = [s]; return pipe(g)
    }

    private let px = SIMD3<Float>(0.3, 0.5, 0.7)

    @Test func mixBlendsTheStepWithItsInput() {
        var s = ColorStep(label: "A"); s.primaries = ColorGraphRenderTests.primaries(2)
        let plain = ColorPipeline(source: .rec709).process(px)
        let full = single(s).process(px)
        s.mix = 25
        let quarter = single(s).process(px)
        let dp = TransferFunctions.bt709OETF(plain), df = TransferFunctions.bt709OETF(full)
        let expected = TransferFunctions.bt709InverseOETF(dp + (df - dp) * 0.25)
        #expect(simd_reduce_max(simd_abs(quarter - expected)) < 1e-4, "the blend happens on the display signal")
    }

    @Test func parallelAveragesTheBranches() {
        var a = ColorStep(label: "A"); a.primaries = ColorGraphRenderTests.primaries(2)
        var b = ColorStep(label: "B"); b.primaries = ColorGraphRenderTests.primaries(5); b.kind = .parallel
        var g = ColorGraph(); g.steps = [a, b]
        var a1 = a; a1.kind = .serial
        let ra = single(a1).process(px)
        var b1 = b; b1.kind = .serial
        let rb = single(b1).process(px)
        let avg = pipe(g).process(px)
        // The average is taken on the display signal; compare on it.
        let da = TransferFunctions.bt709OETF(ra), db = TransferFunctions.bt709OETF(rb)
        let expected = TransferFunctions.bt709InverseOETF((da + db) * 0.5)
        #expect(simd_reduce_max(simd_abs(avg - expected)) < 1e-4)
    }

    @Test func layerReplacesWithoutAKeyAndFollowsTheKeyWithOne() {
        var a = ColorStep(label: "A"); a.primaries = ColorGraphRenderTests.primaries(2)
        var l = ColorStep(label: "L"); l.primaries = ColorGraphRenderTests.primaries(6); l.kind = .layer
        var g = ColorGraph(); g.steps = [a, l]
        var alone = l; alone.kind = .serial
        let onlyLayer = single(alone).process(px)
        #expect(simd_reduce_max(simd_abs(pipe(g).process(px) - onlyLayer)) < 1e-5, "no key: the layer replaces the column")
        // A qualifier that misses the pixel keeps the column's result.
        var q = ColorQualifier(); q.hueCenter = 30; q.hueWidth = 10; q.satMin = 90; q.softness = 0
        l.qualifier = q
        g.steps = [a, l]
        var a1 = a; a1.kind = .serial
        #expect(simd_reduce_max(simd_abs(pipe(g).process(px) - single(a1).process(px))) < 1e-5)
        // Mix 50 of a keyless layer: halfway between the column and the layer.
        l.qualifier = nil; l.mix = 50
        g.steps = [a, l]
        let half = pipe(g).process(px)
        let da = TransferFunctions.bt709OETF(single(a1).process(px)), dl = TransferFunctions.bt709OETF(onlyLayer)
        #expect(simd_reduce_max(simd_abs(half - TransferFunctions.bt709InverseOETF((da + dl) * 0.5))) < 1e-4)
    }

    // MARK: GPU

    private func columnGraphs() -> [(String, ColorGraph)] {
        let par = graph { g in
            let p = g.addStep(after: nil, kind: .parallel)
            g.update(p) { $0.primaries = ColorGraphRenderTests.primaries(4); $0.curves = ColorGraphRenderTests.curves() }
            let q = g.addStep(after: p, kind: .parallel)
            g.update(q) { $0.primaries = ColorGraphRenderTests.primaries(2); $0.mix = 60; $0.qualifier = ColorGraphRenderTests.qualifier() }
        }
        let lay = graph { g in
            let l = g.addStep(after: nil, kind: .layer)
            g.update(l) {
                $0.primaries = ColorGraphRenderTests.primaries(5); $0.window = ColorGraphRenderTests.window(.ellipse)
                $0.qualifier = ColorGraphRenderTests.qualifier(); $0.mix = 80
            }
            let m = g.addStep(after: l, kind: .layer)
            g.update(m) { $0.primaries = ColorGraphRenderTests.primaries(3) }
            let s = g.addStep(after: nil)
            g.update(s) { $0.primaries = ColorGraphRenderTests.primaries(1); $0.mix = 30 }
        }
        return [("parallel", par), ("layers", lay)]
    }

    @Test(.enabled(if: GPUTest.device != nil, "no Metal device")) func gpuMatchesCPU() throws {
        for src in [SourceColorSpace.rec709, .sLog3SGamut3Cine] {
            for (name, g) in columnGraphs() {
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
        let px = ColorPipelineGPUTests.randomPixels(count: 64 * 48, seed: 7)
        for (name, g) in columnGraphs() {
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
#endif
