import CoreVideo
import Foundation
import Metal
import SQCore
import SQMedia
import SQMediaTestSupport
import SQRender
import Testing

// FB-D: a transparent MOV (written by AVAssetWriter, decoded by VTVideoDecoder) must composite to its own color and alpha,
// not a flat color. Pixel values of the whole file -> decode -> compositor path.

private func lin709(_ e: Double) -> Double { e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45) }

private func compositeFirstFrame(_ codec: TestClipSpec.Codec, width: Int = 64, height: Int = 32,
                                 scale: DecodeScale = .full) async throws -> [[Double]]? {
    var spec = TestClipSpec(); spec.codec = codec; spec.width = width; spec.height = height; spec.frameCount = 2
    let url: URL
    do { url = try await TestClipWriter.write(spec) } catch TestClipError.encoderUnavailable { return nil }
    let dec = try VTVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID(), scale: scale)
    let pb = try #require(try await dec.decode(0...1).first?.pixelBuffer)
    guard let device = MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue(), let comp = try? Compositor(device: device) else { return nil }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = try #require(device.makeTexture(descriptor: d))
    let cb = try #require(q.makeCommandBuffer())
    let blue = RenderLayer(content: .solid(red: 0, green: 0, blue: 1))
    let f = SequenceFormat(width: width, height: height, frameDuration: Time(1, 25))
    try comp.render([blue, RenderLayer(content: .frame(pb, colorHint: dec.info), nativeSize: (dec.info.width, dec.info.height))],
                    format: f, into: t, commandBuffer: cb)
    cb.commit(); await cb.completed()
    #expect(comp.unsupportedFrameCount == 0, "format \(CVPixelBufferGetPixelFormatType(pb)) unsupported")
    return [width / 8, width * 5 / 8, width * 15 / 16].map { x in
        var px = [Float16](repeating: 0, count: 4)
        t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, height / 2, 1, 1), mipmapLevel: 0)
        return px.map { Double($0) }
    }
}

private func check(_ codec: TestClipSpec.Codec, width: Int = 64, height: Int = 32, scale: DecodeScale = .full) async throws {
    guard let p = try await compositeFirstFrame(codec, width: width, height: height, scale: scale) else { return }
    let c = AlphaTestPattern.color
    let fg = [lin709(Double(c.r) / 255), lin709(Double(c.g) / 255), lin709(Double(c.b) / 255)]
    let blue = [0.0, 0, 1]
    for (i, a) in [1.0, 128.0 / 255, 0.0].enumerated() {
        let want = (0..<3).map { fg[$0] * a + blue[$0] * (1 - a) }
        for ch in 0..<3 { #expect(abs(p[i][ch] - want[ch]) < 0.03, "\(codec) column \(i) ch\(ch): got \(p[i][ch]) want \(want[ch])") }
    }
}

@Test func proResAlphaFileCompositesToItsColour() async throws { try await check(.prores4444Alpha) }
@Test func hevcAlphaFileCompositesToItsColour() async throws { try await check(.hevcAlpha) }
@Test func proResAlphaHDFileCompositesToItsColour() async throws { try await check(.prores4444Alpha, width: 1920, height: 1080) }
@Test func proResAlphaHalfDecodeCompositesToItsColour() async throws { try await check(.prores4444Alpha, width: 1920, height: 1080, scale: .half) }
@Test func hevcAlphaHalfDecodeCompositesToItsColour() async throws { try await check(.hevcAlpha, width: 1920, height: 1080, scale: .half) }

/// Opaque ProRes 4444 (x444 bi-planar decode): the neutral FrameStamp background must stay neutral (no chroma lost).
@Test func opaqueProRes4444StaysNeutral() async throws {
    var spec = TestClipSpec(); spec.codec = .prores4444; spec.width = FrameStamp.minimumWidth; spec.height = 32; spec.frameCount = 2
    let url = try await TestClipWriter.write(spec)
    let dec = try VTVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID())
    let pb = try #require(try await dec.decode(0...1).first?.pixelBuffer)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let q = try #require(device.makeCommandQueue()), comp = try Compositor(device: device)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: spec.width, height: 32, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = try #require(device.makeTexture(descriptor: d))
    let cb = try #require(q.makeCommandBuffer())
    try comp.render([RenderLayer(content: .frame(pb, colorHint: dec.info))],
                    format: SequenceFormat(width: spec.width, height: 32, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
    cb.commit(); await cb.completed()
    var px = [Float16](repeating: 0, count: 4)
    t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(200, 24, 1, 1), mipmapLevel: 0)
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    #expect(abs(Double(px[0]) - Double(px[1])) < 0.02 && abs(Double(px[1]) - Double(px[2])) < 0.02,
            "format \(fmt) rgb \(px[0]) \(px[1]) \(px[2])")
}
