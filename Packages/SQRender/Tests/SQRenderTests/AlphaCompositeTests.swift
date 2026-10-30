#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// W9.2: packed 'y416' (A, Y', Cb, Cr, 16 bit) frames from transparent video (ProRes 4444 / HEVC with alpha) composite
// over lower tracks in the linear pipeline, straight or premultiplied, without dark or bright fringes when resampled.

private struct YCC { var y: Int, cb: Int, cr: Int }   // 8-bit codes (shifted up to 16 bit in the buffer)

/// Straight orange (sRGB-ish 230, 120, 40 in BT.709 video range).
private let orange = YCC(y: 134, cb: 82, cr: 180)
private let black = YCC(y: 16, cb: 128, cr: 128)

private func lin709(_ e: Double) -> Double {
    let e = max(0, e)
    return e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

/// Working-linear RGB of a straight BT.709 video-range code (independent double reference).
private func linear(_ c: YCC) -> [Double] {
    let Y = Double(c.y - 16) / 219, Cb = Double(c.cb - 128) / 224, Cr = Double(c.cr - 128) / 224
    let r = Y + 2 * (1 - 0.2126) * Cr, b = Y + 2 * (1 - 0.0722) * Cb
    let g = (Y - 0.2126 * r - 0.0722 * b) / (1 - 0.2126 - 0.0722)
    return [lin709(r), lin709(g), lin709(b)]
}

/// y416 buffer; `pixel(x, y)` gives alpha 0...1 and the straight color. `premultiplied` stores color * alpha.
private func makeY416(_ w: Int, _ h: Int, premultiplied: Bool, mode: CFString?,
                      _ pixel: (Int, Int) -> (Double, YCC)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_4444AYpCbCr16, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let base = CVPixelBufferGetBaseAddress(buf)!, stride = CVPixelBufferGetBytesPerRow(buf)
    for y in 0..<h {
        let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
        for x in 0..<w {
            let (a, c) = pixel(x, y)
            func code(_ v: Int, _ zero: Int) -> UInt16 {
                let s = Double(v << 8), z = Double(zero << 8)
                return UInt16(((premultiplied ? z + (s - z) * a : s)).rounded())
            }
            row[x * 4] = UInt16((a * 65535).rounded())
            row[x * 4 + 1] = code(c.y, 16); row[x * 4 + 2] = code(c.cb, 128); row[x * 4 + 3] = code(c.cr, 128)
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    if let mode { CVBufferSetAttachment(buf, kCVImageBufferAlphaChannelModeKey, mode, .shouldPropagate) }
    return buf
}

private func makeBGRA(_ w: Int, _ h: Int, _ bgra: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!, stride = CVPixelBufferGetBytesPerRow(pb!)
    for y in 0..<h { for x in 0..<w {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        p[0] = bgra.0; p[1] = bgra.1; p[2] = bgra.2; p[3] = bgra.3
    } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

private func hint() -> VideoTrackInfo {
    VideoTrackInfo(width: 16, height: 16, codec: "ap4h", bitDepth: 12, chroma: "4:4:4",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

private func render(_ comp: Compositor, _ dev: MTLDevice, _ q: MTLCommandQueue, _ layers: [RenderLayer],
                    transparent: Bool = false) throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    let f = SequenceFormat(width: 16, height: 16, frameDuration: Time(1, 25))
    if transparent {
        try comp.render(nodes: layers.map { .layer($0) }, format: f, into: t, commandBuffer: cb, background: .transparent)
    } else {
        try comp.render(layers, format: f, into: t, commandBuffer: cb)
    }
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    return t
}

private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [Double] {
    var px = [Float16](repeating: 0, count: 4)
    t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return px.map { Double($0) }
}

private func near(_ a: [Double], _ e: [Double], _ tol: Double, _ note: String) {
    for i in 0..<3 { #expect(abs(a[i] - e[i]) <= tol, "\(note) ch\(i): got \(a[i]) want \(e[i])") }
}

private let half = 32768.0 / 65535
/// Columns: 0..<8 opaque orange, 8..<12 half-transparent orange, 12..<16 transparent (color black).
private func columns(_ x: Int, _ y: Int) -> (Double, YCC) { x < 8 ? (1, orange) : x < 12 ? (half, orange) : (0, black) }

private func over(_ fg: [Double], _ a: Double, _ bg: [Double]) -> [Double] { (0..<3).map { fg[$0] * a + bg[$0] * (1 - a) } }

private let blue = [0.0, 0, 1]

@Test func y416FormatTable() {
    let i = PixelFormats.info(for: kCVPixelFormatType_4444AYpCbCr16)
    #expect(i?.layout == .ayuv16)
    #expect(i?.bitDepth == 16)
    #expect(i?.fullRange == false)
    #expect(i?.yFormat == .rgba16Unorm)
    #expect(i?.hasAlpha == true)
    #expect(PixelFormats.info(for: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)?.hasAlpha == false)
}

@Test func straightAlphaFrameCompositesOverLowerTrack() throws {
    guard let (dev, q, comp) = setup() else { return }
    let fg = makeY416(16, 16, premultiplied: false, mode: kCVImageBufferAlphaChannelMode_StraightAlpha, columns)
    let t = try render(comp, dev, q, [RenderLayer(content: .frame(makeBGRA(16, 16, (255, 0, 0, 255)), colorHint: hint())),
                                      RenderLayer(content: .frame(fg, colorHint: hint()))])
    near(pixel(t, 4, 8), linear(orange), 1.0 / 255, "opaque")
    near(pixel(t, 9, 8), over(linear(orange), half, blue), 1.0 / 255, "half")
    near(pixel(t, 14, 8), blue, 1.0 / 255, "transparent")
}

@Test func untaggedY416IsStraight() throws {
    guard let (dev, q, comp) = setup() else { return }
    let fg = makeY416(16, 16, premultiplied: false, mode: nil, columns)
    let t = try render(comp, dev, q, [RenderLayer(content: .frame(makeBGRA(16, 16, (255, 0, 0, 255)), colorHint: hint())),
                                      RenderLayer(content: .frame(fg, colorHint: hint()))])
    near(pixel(t, 9, 8), over(linear(orange), half, blue), 1.0 / 255, "half")
}

@Test func premultipliedAlphaFrameMatchesStraight() throws {
    guard let (dev, q, comp) = setup() else { return }
    let fg = makeY416(16, 16, premultiplied: true, mode: kCVImageBufferAlphaChannelMode_PremultipliedAlpha, columns)
    let t = try render(comp, dev, q, [RenderLayer(content: .frame(makeBGRA(16, 16, (255, 0, 0, 255)), colorHint: hint())),
                                      RenderLayer(content: .frame(fg, colorHint: hint()))])
    near(pixel(t, 4, 8), linear(orange), 1.0 / 255, "opaque")
    near(pixel(t, 9, 8), over(linear(orange), half, blue), 2.0 / 255, "half")
    near(pixel(t, 14, 8), blue, 1.0 / 255, "transparent")
}

@Test func alphaSurvivesTheColourStage() throws {
    guard let (dev, q, comp) = setup() else { return }
    for premul in [false, true] {
        let mode = premul ? kCVImageBufferAlphaChannelMode_PremultipliedAlpha : kCVImageBufferAlphaChannelMode_StraightAlpha
        let fg = makeY416(16, 16, premultiplied: premul, mode: mode, columns)
        let t = try render(comp, dev, q, [RenderLayer(content: .frame(makeBGRA(16, 16, (255, 0, 0, 255)), colorHint: hint())),
                                          RenderLayer(content: .frame(fg, colorHint: hint()), colorPipeline: ColorPipeline(source: .rec709))])
        near(pixel(t, 4, 8), linear(orange), 2.0 / 255, "opaque premul=\(premul)")
        near(pixel(t, 9, 8), over(linear(orange), half, blue), 2.0 / 255, "half premul=\(premul)")
        near(pixel(t, 14, 8), blue, 1.0 / 255, "transparent premul=\(premul)")
    }
}

/// Edge between opaque orange and transparent black, drawn half a pixel off (the sampler mixes the two texels). Over white,
/// result = a * fg + (1 - a): every channel must give the same coverage `a`. Filtering straight color would mix in the
/// invisible black (dark fringe), filtering premultiplied color as straight would brighten it.
@Test func resampledEdgeHasNoFringe() throws {
    guard let (dev, q, comp) = setup() else { return }
    let fgLin = linear(orange)
    for (premul, mode) in [(false, kCVImageBufferAlphaChannelMode_StraightAlpha), (true, kCVImageBufferAlphaChannelMode_PremultipliedAlpha)] {
        for pipeline in [nil, ColorPipeline(source: .rec709)] {
            let fg = makeY416(16, 16, premultiplied: premul, mode: mode) { x, _ in x < 8 ? (1, orange) : (0, black) }
            var tr = ClipTransform.identity
            tr.position = Vec2(0.5, 0)
            let t = try render(comp, dev, q, [RenderLayer(content: .frame(makeBGRA(16, 16, (255, 255, 255, 255)), colorHint: hint())),
                                              RenderLayer(content: .frame(fg, colorHint: hint()), transform: tr, colorPipeline: pipeline)])
            let p = pixel(t, 8, 8)
            let cover = (0..<3).map { (1 - p[$0]) / (1 - fgLin[$0]) }
            let note = "premul=\(premul) stage=\(pipeline != nil)"
            #expect(cover[0] > 0.3 && cover[0] < 0.7, "\(note) edge coverage \(cover)")
            #expect(abs(cover[0] - cover[1]) < 0.02 && abs(cover[1] - cover[2]) < 0.02, "\(note) fringe: coverage per channel \(cover)")
        }
    }
}

/// Opaque media keeps its exact path: a y416 frame with alpha 1 everywhere matches the plain color.
@Test func opaqueY416IsTheSourceColour() throws {
    guard let (dev, q, comp) = setup() else { return }
    let fg = makeY416(16, 16, premultiplied: false, mode: kCVImageBufferAlphaChannelMode_StraightAlpha) { _, _ in (1, orange) }
    let t = try render(comp, dev, q, [RenderLayer(content: .frame(fg, colorHint: hint()))])
    near(pixel(t, 3, 3), linear(orange), 1.0 / 255, "opaque")
    #expect(abs(pixel(t, 3, 3)[3] - 1) < 1e-3)
}

/// A transparent background (alpha export) keeps the clip's coverage in the target's alpha: premultiplied linear output.
@Test func transparentBackgroundKeepsAlpha() throws {
    guard let (dev, q, comp) = setup() else { return }
    let fg = makeY416(16, 16, premultiplied: false, mode: kCVImageBufferAlphaChannelMode_StraightAlpha, columns)
    let t = try render(comp, dev, q, [RenderLayer(content: .frame(fg, colorHint: hint()))], transparent: true)
    #expect(abs(pixel(t, 4, 8)[3] - 1) < 1e-3)
    #expect(abs(pixel(t, 9, 8)[3] - half) < 2e-3)
    near(pixel(t, 9, 8), linear(orange).map { $0 * half }, 1.0 / 255, "premultiplied half")
    #expect(pixel(t, 14, 8) == [0, 0, 0, 0])
}

/// Lossy premultiplied alpha (HEVC) can code color above its alpha at soft edges; un-premultiplying that would blow up
/// into a bright halo. Color is clamped to alpha first: a white texel at alpha 0.1 coded as if it had 0.5 stays white.
@Test func premultipliedOvershootIsClampedToAlpha() throws {
    guard let (dev, q, comp) = setup() else { return }
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_4444AYpCbCr16, attrs as CFDictionary, &pb)
    let fg = pb!
    CVPixelBufferLockBaseAddress(fg, [])
    let base = CVPixelBufferGetBaseAddress(fg)!, stride = CVPixelBufferGetBytesPerRow(fg)
    for y in 0..<16 {
        let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
        for x in 0..<16 {
            row[x * 4] = UInt16(0.1 * 65535)
            row[x * 4 + 1] = UInt16(Double(16 << 8) + Double(219 << 8) * 0.5)   // white premultiplied by 0.5
            row[x * 4 + 2] = UInt16(128 << 8); row[x * 4 + 3] = UInt16(128 << 8)
        }
    }
    CVPixelBufferUnlockBaseAddress(fg, [])
    CVBufferSetAttachment(fg, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
    let a = Double(UInt16(0.1 * 65535)) / 65535
    for pipeline in [nil, ColorPipeline(source: .rec709)] {
        let t = try render(comp, dev, q, [RenderLayer(content: .frame(makeBGRA(16, 16, (255, 0, 0, 255)), colorHint: hint())),
                                          RenderLayer(content: .frame(fg, colorHint: hint()), colorPipeline: pipeline)])
        near(pixel(t, 8, 8), over([1, 1, 1], a, blue), 2.0 / 255, "clamped stage=\(pipeline != nil)")
    }
}

/// The color stage / frame blend output of an opaque or untagged source stays on the hardware-sampled path (bit-identical
/// to before W9.2); only alpha sources take the premultiplied 4-tap filter.
@Test func intermediateAlphaModeFollowsTheSource() {
    #expect(Compositor.intermediateAlphaMode(source: 0) == 0)
    #expect(Compositor.intermediateAlphaMode(source: 1) == 1)
    #expect(Compositor.intermediateAlphaMode(source: 2) == 1)
    let bgra = PixelFormats.info(for: kCVPixelFormatType_32BGRA)!
    let still = makeBGRA(4, 4, (0, 0, 255, 255))
    #expect(Compositor.alphaMode(of: still, info: bgra) == 0)
    CVBufferSetAttachment(still, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
    #expect(Compositor.alphaMode(of: still, info: bgra) == 1)
}

/// Swift `Compositor.Uniforms` must match MSL `CompositeUniforms` byte for byte (fields after roundFirst: alphaMode, maskCount, cropFeather; Ultra Key key0/key1/matte0/matte1/shape0/shape1/cc0/cc1 precede keyCount).
@Test func uniformsLayoutMatchesShader() {
    #expect(MemoryLayout<Compositor.Uniforms>.offset(of: \Compositor.Uniforms.roundFirst) == 308)
    #expect(MemoryLayout<Compositor.Uniforms>.offset(of: \Compositor.Uniforms.alphaMode) == 312)
    #expect(MemoryLayout<Compositor.Uniforms>.offset(of: \Compositor.Uniforms.maskCount) == 316)
    #expect(MemoryLayout<Compositor.Uniforms>.offset(of: \Compositor.Uniforms.cropFeather) == 320)
    #expect(MemoryLayout<Compositor.Uniforms>.offset(of: \Compositor.Uniforms.part) == 336)
    #expect(MemoryLayout<Compositor.Uniforms>.offset(of: \Compositor.Uniforms.tilt) == 352)   // float3 after part
    #expect(MemoryLayout<Compositor.Uniforms>.stride == 368)
}
#endif
