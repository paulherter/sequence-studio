#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Perf stream: a motion transition's mix is computed inside the final draw (no mix texture written and read back).
// The fused draw must give the same bits as the mix kernel + mode-3 draw it replaces, for every compose kind.

private func gradient(_ w: Int, _ h: Int, seed: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        let a = UInt8(255 - ((x + y + seed) % 5) * 40)     // some partly transparent pixels (premultiplied BGRA)
        p[0] = UInt8((Int(a) * ((x * 7 + seed) & 255)) / 255); p[1] = UInt8((Int(a) * ((y * 13 + seed) & 255)) / 255)
        p[2] = UInt8((Int(a) * ((x * y + seed * 3) & 255)) / 255); p[3] = a
    } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

private let W = 97, H = 61
private let fmt = SequenceFormat(width: W, height: H, frameDuration: Time(1, 30))
private let info = VideoTrackInfo(width: W, height: H, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, matrix: nil)

@Suite(.serialized) struct TransitionFusionTests {
    let a = RenderNode.layer(RenderLayer(content: .frame(gradient(W, H, seed: 1), colorHint: info),
                                         transform: ClipTransform(position: Vec2(3, -2), scale: Vec2(0.9, 0.9), rotation: 4)))
    let b = RenderNode.layer(RenderLayer(content: .frame(gradient(W, H, seed: 7), colorHint: info)))
    let under = RenderNode.layer(RenderLayer(content: .frame(gradient(W, H, seed: 3), colorHint: info)))

    func cases() -> [(String, TransitionRender)] {
        var out: [(String, TransitionRender)] = []
        out.append(("push", TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.37, 0)),
                                             incoming: TransitionSide(offset: Vec2(0.63, 0)), compose: .sum)))
        out.append(("push blurred", TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.3, 0.1), blur: Vec2(-0.05, 0)),
                                                     incoming: TransitionSide(offset: Vec2(0.7, 0.1), blur: Vec2(-0.05, 0.02)),
                                                     compose: .sum)))
        out.append(("whip (pre-blur pass)", TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.2, 0), blur: Vec2(-1.5, 0)),
                                                             incoming: TransitionSide(offset: Vec2(0.8, 0), blur: Vec2(-1.5, 0)),
                                                             compose: .sum)))
        out.append(("zoom over", TransitionRender(outgoing: TransitionSide(scale: 1.3, opacity: 0.6, zoomBlur: 0.3),
                                                  incoming: TransitionSide(scale: 0.95, rotation: 0.2), compose: .outgoingOver)))
        out.append(("incoming over", TransitionRender(outgoing: TransitionSide(), incoming: TransitionSide(scale: 0.7, opacity: 0.8),
                                                      compose: .incomingOver)))
        out.append(("wipe", TransitionRender(compose: .wipe, wipe: .init(direction: Vec2(0.8, 0.6), front: 0.43, softness: 0.07))))
        var g = TransitionRender(compose: .glitch); g.glitch = .init(mix: 0.3, intensity: 0.8, seed: 99)
        out.append(("glitch", g))
        out.append(("iris", TransitionRender(compose: .iris, wipe: .init(front: 0.5, softness: 0.05))))
        out.append(("light leak", TransitionRender(compose: .lightLeak, wipe: .init(direction: Vec2(1, 0), front: 0.4, softness: 0.3))))
        out.append(("blur dissolve", TransitionRender(compose: .blurDissolve, wipe: .init(front: 0.6, softness: 0.08))))
        var s = TransitionRender(compose: .staticNoise); s.glitch = .init(mix: 0.7, intensity: 0.6, seed: 5)
        out.append(("static", s))
        out.append(("light noise", TransitionRender(compose: .lightNoise, wipe: .init(front: 0.45))))
        return out
    }

    func target(_ dev: MTLDevice, _ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        return dev.makeTexture(descriptor: d)!
    }

    func bits(_ comp: Compositor, _ q: MTLCommandQueue, _ t: MTLTexture, _ nodes: [RenderNode],
              format: SequenceFormat = fmt) throws -> [UInt16] {
        let cb = q.makeCommandBuffer()!
        try comp.render(nodes: nodes, format: format, into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)
        var out = [UInt16](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&out, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return out
    }

    /// Fused vs unfused: count of differing half values and the largest difference in ulps.
    func compare(_ comp: Compositor, _ q: MTLCommandQueue, _ t: MTLTexture, _ nodes: [RenderNode],
                 format: SequenceFormat = fmt) throws -> (diff: Int, maxUlp: Int, fused: Int) {
        comp.fusesTransitionMix = false
        let ref = try bits(comp, q, t, nodes, format: format)
        let before = comp.fusedTransitionDraws
        comp.fusesTransitionMix = true
        let got = try bits(comp, q, t, nodes, format: format)
        var diff = 0, maxUlp = 0
        var samples: [String] = []
        for (i, (x, y)) in zip(ref, got).enumerated() where x != y {
            diff += 1
            maxUlp = max(maxUlp, abs(Int(Int16(bitPattern: x)) - Int(Int16(bitPattern: y))))
            if samples.count < 6 {
                samples.append("\(i % 4)@\(i / 4): \(Float(Float16(bitPattern: x))) vs \(Float(Float16(bitPattern: y)))")
            }
        }
        if diff > 0, let path = ProcessInfo.processInfo.environment["SQ_DIAG_OUT"] {
            let line = "\(diff) max \(maxUlp) ulp: " + samples.joined(separator: ", ") + "\n"
            if let hd = FileHandle(forWritingAtPath: path) { try? hd.seekToEnd(); try? hd.write(contentsOf: Data(line.utf8)); try? hd.close() }
            else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        return (diff, maxUlp, comp.fusedTransitionDraws - before)
    }

    @Test func theFusedMixDrawIsBitIdenticalForEveryComposeKind() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        let t = target(dev, W, H)
        for (name, r) in cases() {
            for over in [false, true] {
                let node = RenderNode.transition(format: fmt, render: r, first: [a], second: [b])
                let res = try compare(comp, q, t, over ? [under, node] : [node])
                #expect(res.fused == 1, "\(name): fused path not taken")
                #expect(res.diff == 0, "\(name)\(over ? " over a layer" : ""): \(res.diff) half values differ, max \(res.maxUlp) ulp")
            }
        }
    }

    @Test func aTransitionInsideAPairOrGroupIsFusedAndUnchanged() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        let t = target(dev, W, H)
        let r = cases()[1].1
        let tr = RenderNode.transition(format: fmt, render: r, first: [a], second: [b])
        // Second side of a pair: drawn with additive blending.
        let pair = RenderNode.pair(format: fmt, first: [under], second: [tr])
        var res = try compare(comp, q, t, [pair])
        #expect(res.fused == 1)
        #expect(res.diff == 0, "pair: \(res.diff) differ, max \(res.maxUlp) ulp")
        // Inside a nested sequence image.
        let group = RenderNode.group(format: fmt, transform: ClipTransform(position: Vec2(4, 1), scale: Vec2(0.8, 0.8)),
                                     opacity: 0.9, cornerRadius: 0, children: [under, tr])
        res = try compare(comp, q, t, [group])
        #expect(res.fused == 1)
        #expect(res.diff == 0, "group: \(res.diff) differ, max \(res.maxUlp) ulp")
    }

    @Test func aBlendedOrResizedTransitionKeepsTheMixTexture() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        let t = target(dev, W, H)
        let r = cases()[0].1
        // Blend mode: the programmable-blending draw reads the mix texture.
        let blended = RenderNode.blended(.transition(format: fmt, render: r, first: [a], second: [b]), .multiply)
        var res = try compare(comp, q, t, [under, blended])
        #expect(res.fused == 0)
        #expect(res.diff == 0)
        // A transition canvas of another size than the target is scaled by the final draw.
        let small = SequenceFormat(width: 50, height: 31, frameDuration: Time(1, 30))
        res = try compare(comp, q, t, [under, .transition(format: small, render: r, first: [a], second: [b])])
        #expect(res.fused == 0)
        #expect(res.diff == 0)
    }

    @Test func fusingSavesTheMixTexture() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        let t = target(dev, W, H)
        let node = RenderNode.transition(format: fmt, render: cases()[0].1, first: [a], second: [b])
        comp.fusesTransitionMix = true
        _ = try bits(comp, q, t, [node])
        let fused = comp.intermediateAllocations
        let comp2 = try Compositor(device: dev)
        comp2.fusesTransitionMix = false
        _ = try bits(comp2, q, t, [node])
        #expect(fused == comp2.intermediateAllocations - 1)
    }
}
#endif
