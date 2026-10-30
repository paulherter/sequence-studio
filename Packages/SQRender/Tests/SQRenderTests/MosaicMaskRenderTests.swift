#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// F7.11: Mosaic and Gaussian Blur limited to a mask (the effect's mask input), on rendered pixels, and what the masked
// Mosaic costs on a 4K frame.

private func makeBGRA(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h {
        for x in 0..<w {
            let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            let c = f(x, y)
            px[0] = c.0; px[1] = c.1; px[2] = c.2; px[3] = c.3
        }
    }
    return b
}

private func info(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

private func target(_ dev: MTLDevice, _ w: Int, _ h: Int, shared: Bool) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = shared ? .shared : .private
    return dev.makeTexture(descriptor: d)!
}

/// Renders one `w` x `h` layer of `pb` 1:1 with `segs`; the green channel of every pixel.
private func green(_ pb: CVPixelBuffer, _ w: Int, _ h: Int, segs: [EffectSegment], mattes: [UUID: SubjectMatte] = [:]) throws -> [Float] {
    let (dev, q, comp) = try #require(setup())
    var layer = RenderLayer(content: .frame(pb, colorHint: info(w, h)), effects: ClipEffects(segments: segs, masks: []))
    layer.mattes = mattes
    let t = target(dev, w, h, shared: true)
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: [.layer(layer)], format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var px = [Float16](repeating: 0, count: w * h * 4)
    t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (0..<(w * h)).map { Float(px[$0 * 4 + 1]) }
}

private func rect(_ x0: Double, _ x1: Double, feather: Double = 0) -> MaskShape {
    MaskShape(polygon: MaskPath.rectangle(Vec2(x0, 0), Vec2(x1 - x0, 1)).polygon(), feather: feather)
}

private func magic(_ id: UUID) -> MaskShape {
    MaskShape(polygon: [], source: .magic, matteKey: id)
}

/// One-pixel black / white columns: a Mosaic block turns them into one flat value, anything else keeps the stripes.
private func stripes(_ w: Int, _ h: Int) -> CVPixelBuffer {
    makeBGRA(w, h) { x, _ in x % 2 == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
}

private let step: Float = 1.0 / 255 + 0.001

@Suite struct MosaicMaskRenderTests {
    private let mosaic = ImageFilter.mosaic(columns: 8, rows: 4, sharp: false)

    @Test func mosaicInsideAMaskLeavesTheRestOfThePictureUntouched() throws {
        let w = 64, h = 32, row = 16 * w
        let pb = stripes(w, h)
        let plain = try green(pb, w, h, segs: [])
        let all = try green(pb, w, h, segs: [EffectSegment(filter: mosaic), EffectSegment()])
        let got = try green(pb, w, h, segs: [EffectSegment(filter: mosaic, scope: [rect(0, 0.5)]), EffectSegment()])
        // Inside: exactly the Mosaic of the whole picture (the blocks are those of the frame, not of the mask).
        for x in 2..<28 { #expect(abs(got[row + x] - all[row + x]) <= step, "x \(x)") }
        #expect(abs(got[row + 10] - got[row + 11]) <= step)                   // one flat block, no stripes
        // Outside: exactly the picture.
        for x in 34..<w { #expect(abs(got[row + x] - plain[row + x]) <= step, "x \(x)") }
        #expect(abs(got[row + 40] - got[row + 41]) > 0.8)
    }

    @Test func aFeatheredMaskFadesTheMosaicIntoThePicture() throws {
        // Soft edge = the mask's Feather: the stripes come back gradually across the edge at x = 64.
        let w = 128, h = 32, row = 16 * w
        let pb = stripes(w, h)
        let got = try green(pb, w, h, segs: [EffectSegment(filter: .mosaic(columns: 16, rows: 4, sharp: false),
                                                           scope: [rect(0, 0.5, feather: 24)]), EffectSegment()])
        func contrast(_ x: Int) -> Float { abs(got[row + x] - got[row + x + 1]) }
        #expect(contrast(20) <= step)                                         // well inside: flat blocks
        #expect(contrast(110) > 0.9)                                          // well outside: the picture
        let c = [56, 60, 64, 68, 72].map(contrast)
        #expect(c[2] > 0.15 && c[2] < 0.85, "half way at the edge: \(c[2])")
        for i in 1..<c.count { #expect(c[i] >= c[i - 1] - step, "rises across the edge: \(c)") }
    }

    @Test func mosaicFollowsATrackedMatte() throws {
        // What Anonymize makes: a Mosaic whose mask input is a Magic mask (a matte per frame). The matte covers a block in
        // the middle; only there the stripes are gone.
        let w = 64, h = 32
        let pb = stripes(w, h)
        let id = UUID()
        let m = SubjectMatte(width: 16, height: 8, values: (0..<128).map { i in
            let x = i % 16, y = i / 16
            return (6..<10).contains(x) && (2..<6).contains(y) ? 1 : 0
        })
        let got = try green(pb, w, h, segs: [EffectSegment(filter: mosaic, scope: [magic(id)]), EffectSegment()], mattes: [id: m])
        #expect(abs(got[16 * w + 30] - got[16 * w + 31]) <= 0.05)             // covered
        #expect(abs(got[16 * w + 4] - got[16 * w + 5]) > 0.8)                 // left of the subject
        #expect(abs(got[16 * w + 56] - got[16 * w + 57]) > 0.8)               // right of it
        #expect(abs(got[2 * w + 30] - got[2 * w + 31]) > 0.8)                 // above it
    }

    /// The matte is in source-frame coordinates and Anonymize puts its cover first, so a Horizontal Flip on the clip flips
    /// the covered picture: the cover sits on the subject, which is on the other side now.
    @Test func aHorizontalFlipAfterTheCoverCarriesTheCoverWithTheSubject() throws {
        let w = 64, h = 32, row = 16 * w
        let pb = stripes(w, h)
        let id = UUID()
        // The subject fills the left quarter of the source frame.
        let m = SubjectMatte(width: 16, height: 8, values: (0..<128).map { $0 % 16 < 4 ? 1 : 0 })
        let flip = EffectSegment(filter: .flip(horizontal: true, vertical: false))
        let got = try green(pb, w, h, segs: [EffectSegment(filter: mosaic, scope: [magic(id)]), flip, EffectSegment()], mattes: [id: m])
        #expect(abs(got[row + 54] - got[row + 55]) <= 0.05)                   // right quarter: where the subject is shown
        #expect(abs(got[row + 6] - got[row + 7]) > 0.8)                       // left quarter: the plain picture
        #expect(abs(got[row + 30] - got[row + 31]) > 0.8)
        // The whole-frame fallback of a mask that must cover leaves no stripe anywhere.
        let all = try green(pb, w, h, segs: [EffectSegment(filter: mosaic, scope: [magic(id)]), flip, EffectSegment()],
                            mattes: [id: AnonymizeFallback.wholeFrame])
        for x in stride(from: 2, to: w - 2, by: 8) { #expect(abs(all[row + x] - all[row + x + 1]) <= 0.05, "x \(x)") }
    }

    /// Why the cover is pinned in front of every effect that moves pixels: the compositor reads a matte in the clip's
    /// source-frame coordinates for every segment and does not move it with the effects in front. A Horizontal Flip
    /// before the cover shows the subject on the right while the matte still covers the left. `Clip.effects(at:)` drops
    /// the cover's scope in that order (the whole frame), which is the second render here.
    @Test func aFlipInFrontOfTheCoverLeavesTheMatteBehindSoTheScopeMustBeDropped() throws {
        let w = 64, h = 32, row = 16 * w
        let pb = stripes(w, h)
        let id = UUID()
        let m = SubjectMatte(width: 16, height: 8, values: (0..<128).map { $0 % 16 < 4 ? 1 : 0 })   // the subject: the left quarter
        let flip = EffectSegment(filter: .flip(horizontal: true, vertical: false))
        let wrong = try green(pb, w, h, segs: [flip, EffectSegment(filter: mosaic, scope: [magic(id)]), EffectSegment()], mattes: [id: m])
        #expect(abs(wrong[row + 54] - wrong[row + 55]) > 0.8)                 // right quarter, where the subject is shown: not covered
        #expect(abs(wrong[row + 6] - wrong[row + 7]) <= 0.05)                 // the cover stayed on the left
        let safe = try green(pb, w, h, segs: [flip, EffectSegment(filter: mosaic), EffectSegment()], mattes: [id: m])
        for x in stride(from: 2, to: w - 2, by: 8) { #expect(abs(safe[row + x] - safe[row + x + 1]) <= 0.05, "x \(x)") }
    }

    @Test func gaussianBlurInsideAFeatheredMaskKeepsTheRestSharp() throws {
        let w = 128, h = 32, row = 16 * w
        let got = try green(stripes(w, h), w, h, segs: [EffectSegment(blurAfter: 4, blurRepeatsEdges: true,
                                                                      scope: [rect(0, 0.5, feather: 16)]), EffectSegment()])
        #expect(abs(got[row + 20] - got[row + 21]) < 0.05)
        #expect(abs(got[row + 110] - got[row + 111]) > 0.9)
    }

    /// GPU time of one 4K frame: plain, with a Mosaic, with a Mosaic limited to a tracked matte, with a masked blur.
    @Test func maskedMosaicCostOnA4KFrame() throws {
        let w = 3840, h = 2160
        guard let (dev, q, comp) = setup() else { return }
        let pb = makeBGRA(w, h) { x, y in (UInt8(x & 255), UInt8(y & 255), UInt8((x + y) & 255), 255) }
        let out = target(dev, w, h, shared: false)
        let id = UUID()
        let matte = SubjectMatte(width: 480, height: 270, values: (0..<(480 * 270)).map { i in
            let x = Double(i % 480) - 240, y = Double(i / 480) - 135
            return Float(min(max(1.5 - (x * x + y * y).squareRoot() / 60, 0), 1))
        })
        let grid = ClipEffect.mosaicGrid(blockSize: 48, width: w, height: h)
        let filter = ImageFilter.mosaic(columns: grid.columns, rows: grid.rows, sharp: false)
        let cases: [(String, [EffectSegment])] = [
            ("plain", []),
            ("mosaic", [EffectSegment(filter: filter), EffectSegment()]),
            ("mosaic in matte", [EffectSegment(filter: filter, scope: [magic(id)]), EffectSegment()]),
            ("blur in matte", [EffectSegment(blurAfter: 20, blurRepeatsEdges: true, scope: [magic(id)]), EffectSegment()]),
        ]
        var ms: [String: Double] = [:]
        for (name, segs) in cases {
            var layer = RenderLayer(content: .frame(pb, colorHint: info(w, h)), effects: ClipEffects(segments: segs, masks: []))
            layer.mattes = [id: matte]
            var best = Double.infinity
            for _ in 0..<6 {
                let cb = q.makeCommandBuffer()!
                try comp.render(nodes: [.layer(layer)], format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 30)),
                                into: out, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                #expect(cb.error == nil)
                best = min(best, cb.gpuEndTime - cb.gpuStartTime)
            }
            ms[name] = best * 1000
            let line = String(format: "anonymize 4K GPU cost %@: %.2f ms\n", name, best * 1000)
            NSLog("%@", line)
            if let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] {   // test.sh prints errors only; this keeps the numbers
                if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
                else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        }
        // Loose bound (other agents share the GPU while tests run); the measured numbers are reported with the task.
        let extra = (ms["mosaic in matte"] ?? 0) - (ms["plain"] ?? 0)
        #expect(extra < 6, "a masked Mosaic must stay a small part of a 4K frame, was \(extra) ms")
    }
}
#endif
