#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Color Matte (a solid layer) honors the clip's color pipeline and rounded corners like any picture.

private func renderSolid(_ layer: RenderLayer, _ w: Int, _ h: Int) throws -> [SIMD4<Float>]? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let comp = try? Compositor(device: d) else { return nil }
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
    let t = d.makeTexture(descriptor: td)!
    let cb = q.makeCommandBuffer()!
    try comp.render([layer], format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var px = [Float16](repeating: 0, count: w * h * 4)
    t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    var out: [SIMD4<Float>] = []
    for i in 0..<(w * h) {
        let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2]), a = Float(px[i * 4 + 3])
        out.append(SIMD4<Float>(r, g, b, a))
    }
    return out
}

@Suite struct SolidLayerGradeTests {
    private let w = 64, h = 36
    private var payload: Data { Data([40, 40, 46]) }

    @Test func aGradeChangesTheMatte() throws {
        var basic = BasicCorrection(); basic.exposure = 1.0; basic.saturation = 160
        let grade = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        var graded = RenderLayer.solid(payload: payload)
        graded.colorPipeline = grade
        guard let plain = try renderSolid(RenderLayer.solid(payload: payload), w, h),
              let out = try renderSolid(graded, w, h) else { return }
        let c = plain[(h / 2) * w + w / 2], g = out[(h / 2) * w + w / 2]
        #expect(abs(g.x - c.x) > 0.02, "the grade must change the matte's pixel (plain \(c), graded \(g))")
    }

    @Test func anIdentityGradeKeepsThePlainMattePixel() throws {
        let grade = ColorPipeline(source: .rec709)
        var graded = RenderLayer.solid(payload: payload)
        graded.colorPipeline = grade
        guard let plain = try renderSolid(RenderLayer.solid(payload: payload), w, h),
              let out = try renderSolid(graded, w, h) else { return }
        let i = (h / 2) * w + w / 2
        #expect(abs(out[i].x - plain[i].x) < 4e-3 && abs(out[i].z - plain[i].z) < 4e-3)
        #expect(abs(out[0].w - 1) < 1e-3, "the graded matte still covers the whole canvas")
    }

    @Test func cornerRadiusRoundsTheMatte() throws {
        let layer = RenderLayer.solid(payload: payload, cornerRadius: 20)
        guard let out = try renderSolid(layer, w, h) else { return }
        #expect(out[0].x < 0.5 * out[(h / 2) * w + w / 2].x, "the corner pixel is cut away")
        #expect(out[(h / 2) * w + w / 2].x > 0.01)
    }

    @Test func gradedMatteKeepsCornersAndIsRounded() throws {
        var basic = BasicCorrection(); basic.exposure = 1.0
        var layer = RenderLayer.solid(payload: payload, cornerRadius: 20)
        layer.colorPipeline = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        guard let out = try renderSolid(layer, w, h) else { return }
        #expect(out[0].x < 0.5 * out[(h / 2) * w + w / 2].x)
        #expect(out[(h / 2) * w + w / 2].x > 0.01)
    }
}
#endif
