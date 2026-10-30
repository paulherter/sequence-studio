#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Transition layer (DECISIONS 2026-10-05): requests tagged with `stackTransitions` become one `.transition` node whose sides are
// the whole stacks below, each composited on its own.

private func bgra(_ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        p[0] = c.0; p[1] = c.1; p[2] = c.2; p[3] = c.3
    } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

private let W = 32, H = 16
private let fmt = SequenceFormat(width: W, height: H, frameDuration: Time(1, 30))
private let info = VideoTrackInfo(width: W, height: H, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, matrix: nil)
private func layer(_ c: (UInt8, UInt8, UInt8, UInt8), opacity: Double = 1) -> RenderLayer {
    RenderLayer(content: .frame(bgra(W, H, c), colorHint: info), transform: ClipTransform(opacity: opacity))
}
private let red: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 255)
private let green: (UInt8, UInt8, UInt8, UInt8) = (0, 255, 0, 255)
private let blue: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)

private func dissolve(_ w: Double) -> TransitionRender {
    TransitionRender(outgoing: TransitionSide(opacity: 1 - w), incoming: TransitionSide(opacity: w), compose: .sum)
}

private func req(_ tags: [(UUID, LayerRequest.PairRole)], depth: Int = 0, render: TransitionRender = dissolve(0.5),
                 opacity: Double = 1) -> LayerRequest {
    var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, transform: ClipTransform(opacity: opacity))
    r.stackTransitions = tags.map { StackTransition(id: $0.0, role: $0.1, format: fmt, depth: depth, render: render) }
    return r
}

@Suite struct TransitionLayerRenderTests {
    @Test func taggedRequestsBecomeOneTransitionNodeOverTheirStacks() {
        let id = UUID()
        let reqs = [req([]), req([(id, .first)]), req([(id, .first)]), req([(id, .second)]), req([(id, .second)]), req([])]
        let tree = RenderNode.tree(requests: reqs, layers: reqs.map { _ in layer(red) })
        #expect(tree.count == 3)
        guard case .transition(_, let render, let first, let second) = tree[1] else { Issue.record("expected a transition"); return }
        #expect(render == dissolve(0.5))
        #expect(first.count == 2 && second.count == 2)
    }

    @Test func aCutTransitionBelowStaysAPairInsideItsSide() {
        let id = UUID(), pid = UUID()
        var a = req([(id, .first)]), b = req([(id, .first)])
        a.pair = LayerRequest.PairInfo(id: pid, role: .first, format: fmt, depth: 0)
        b.pair = LayerRequest.PairInfo(id: pid, role: .second, format: fmt, depth: 0)
        let reqs = [a, b, req([(id, .second)])]
        let tree = RenderNode.tree(requests: reqs, layers: reqs.map { _ in layer(red) })
        #expect(tree.count == 1)
        guard case .transition(_, _, let first, let second) = tree[0] else { Issue.record("expected a transition"); return }
        #expect(second.count == 1)
        guard first.count == 1, case .pair = first[0] else { Issue.record("expected the pair inside the outgoing side"); return }
    }

    @Test func stackedLayersNestOuterAroundInner() {
        let outer = UUID(), inner = UUID()
        let reqs = [req([(outer, .first), (inner, .first)]), req([(outer, .first), (inner, .second)]),
                    req([(outer, .second), (inner, .first)]), req([(outer, .second), (inner, .second)])]
        let tree = RenderNode.tree(requests: reqs, layers: reqs.map { _ in layer(red) })
        #expect(tree.count == 1)
        guard case .transition(_, _, let first, let second) = tree[0] else { Issue.record("expected a transition"); return }
        for side in [first, second] {
            guard side.count == 1, case .transition(_, _, let a, let b) = side[0] else { Issue.record("expected an inner transition"); return }
            #expect(a.count == 1 && b.count == 1)
        }
    }

    /// Each side is composited whole before the mix: green at 50 % over red is (0.5, 0.5, 0); mixed half with blue that is
    /// (0.25, 0.25, 0.5). Folding the weight into each layer's opacity would give a different picture.
    @Test func eachSideIsCompositedWholeThenMixed() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        let id = UUID()
        let items: [(LayerRequest, RenderLayer)] = [
            (req([(id, .first)]), layer(red)),
            (req([(id, .first)], opacity: 0.5), layer(green, opacity: 0.5)),
            (req([(id, .second)]), layer(blue)),
        ]
        let nodes = RenderNode.tree(requests: items.map(\.0), layers: items.map(\.1))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = dev.makeTexture(descriptor: d)!
        let cb = q.makeCommandBuffer()!
        try comp.render(nodes: nodes, format: fmt, into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)
        var px = [Float16](repeating: 0, count: 4)
        t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(W / 2, H / 2, 1, 1), mipmapLevel: 0)
        let got = px.map { Double($0) }
        for (i, e) in [0.25, 0.25, 0.5].enumerated() { #expect(abs(got[i] - e) < 0.01, "ch\(i): \(got[i]) want \(e)") }
    }
}
#endif
