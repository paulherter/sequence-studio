import CoreVideo
import Foundation
import Metal
import SSCore
import Testing
@testable import SSRender

// MARK: Helpers

private struct Code { var y: Int, cb: Int, cr: Int }   // 8-bit codes (shifted up for 10-bit)

private func makeBuffer(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    let r = CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &pb)
    precondition(r == kCVReturnSuccess, "CVPixelBufferCreate \(r)")
    return pb!
}

/// Quadrants TL, TR, BL, BR (aligned to chroma blocks) in a bi-planar buffer.
private func makeYCbCr(_ w: Int, _ h: Int, fmt: OSType, bits: Int, chroma422: Bool = false, quads: [Code]) -> CVPixelBuffer {
    let pb = makeBuffer(w, h, fmt)
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let shift = bits - 8
    func store(_ v: Int, _ p: UnsafeMutableRawPointer, _ i: Int) {
        if bits == 8 { p.storeBytes(of: UInt8(v), toByteOffset: i, as: UInt8.self) }
        else { p.storeBytes(of: UInt16(v << 6), toByteOffset: i * 2, as: UInt16.self) }
    }
    func q(_ x: Int, _ y: Int, _ pw: Int, _ ph: Int) -> Code { quads[(y < ph / 2 ? 0 : 2) + (x < pw / 2 ? 0 : 1)] }
    let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    for y in 0..<h { for x in 0..<w {
        let c = q(x, y, w, h)
        let row = yp + y * yStride
        store(c.y << shift, row, x)
    } }
    let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    let cw = w / 2, ch = chroma422 ? h : h / 2
    for y in 0..<ch { for x in 0..<cw {
        let c = q(x, y, cw, ch)
        let row = cp + y * cStride
        store(c.cb << shift, row, x * 2); store(c.cr << shift, row, x * 2 + 1)
    } }
    return pb
}

private func makeBGRA(_ w: Int, _ h: Int, _ bgra: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    let pb = makeBuffer(w, h, kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<h { for x in 0..<w {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        p[0] = bgra.0; p[1] = bgra.1; p[2] = bgra.2; p[3] = bgra.3
    } }
    return pb
}

private func lin709(_ e: Double) -> Double {
    let e = max(0, e)
    return e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

/// Independent double-precision reference (BT.709, video range unless `full`).
private func expected(_ c: Code, bits: Int = 8, full: Bool = false, kr: Double = 0.2126, kb: Double = 0.0722) -> [Double] {
    let s = Double(1 << (bits - 8)), maxC = Double((1 << bits) - 1)
    let y = Double(c.y) * s, cb = Double(c.cb) * s, cr = Double(c.cr) * s
    let Y = full ? y / maxC : (y - 16 * s) / (219 * s)
    let Cb = full ? (cb - 128 * s) / maxC : (cb - 128 * s) / (224 * s)
    let Cr = full ? (cr - 128 * s) / maxC : (cr - 128 * s) / (224 * s)
    let r = Y + 2 * (1 - kr) * Cr, b = Y + 2 * (1 - kb) * Cb
    let g = (Y - kr * r - kb * b) / (1 - kr - kb)
    return [lin709(r), lin709(g), lin709(b)]
}

private func format(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }

private func hint(matrix: String? = nil) -> VideoTrackInfo {
    VideoTrackInfo(width: 64, height: 36, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false, matrix: matrix)
}

private func makeTarget(_ device: MTLDevice, _ w: Int, _ h: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    return device.makeTexture(descriptor: d)!
}

private func renderAndWait(_ comp: Compositor, _ layers: [RenderLayer], _ f: SequenceFormat, _ t: MTLTexture,
                           queue: MTLCommandQueue) throws {
    let cb = queue.makeCommandBuffer()!
    try comp.render(layers, format: f, into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
}

private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [Double] {
    var px = [Float16](repeating: 0, count: 4)
    t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return px.map { Double($0) }
}

private func near(_ a: [Double], _ e: [Double], _ tol: Double = 1.0 / 255, _ note: String = "") {
    for i in 0..<3 { #expect(abs(a[i] - e[i]) <= tol, "\(note) ch\(i): got \(a[i]) want \(e[i])") }
}

private let quads: [Code] = [Code(y: 235, cb: 128, cr: 128), Code(y: 82, cb: 90, cr: 240),
                             Code(y: 145, cb: 54, cr: 34), Code(y: 41, cb: 240, cr: 110)]

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

// MARK: Tests

@Test func ycbcr420vProbes() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(64, 36)
    let pb = makeYCbCr(64, 36, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bits: 8, quads: quads)
    let t = makeTarget(dev, 64, 36)
    try renderAndWait(comp, [RenderLayer(content: .frame(pb, colorHint: hint()))], f, t, queue: q)
    let probes = [(16, 9), (48, 9), (16, 27), (48, 27)]
    for (i, p) in probes.enumerated() { near(pixel(t, p.0, p.1), expected(quads[i]), 1.0 / 255, "420v q\(i)") }
}

@Test func ycbcr10BitProbes() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(64, 36)
    let t = makeTarget(dev, 64, 36)
    for (fmt, is422) in [(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, false),
                         (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, true)] {
        let pb = makeYCbCr(64, 36, fmt: fmt, bits: 10, chroma422: is422, quads: quads)
        try renderAndWait(comp, [RenderLayer(content: .frame(pb, colorHint: hint()))], f, t, queue: q)
        for (i, p) in [(16, 9), (48, 9), (16, 27), (48, 27)].enumerated() {
            near(pixel(t, p.0, p.1), expected(quads[i], bits: 10), 1.0 / 255, "10-bit \(is422 ? "422" : "420") q\(i)")
        }
    }
}

@Test func fullRangeAndBT601Matrix() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(64, 36)
    let t = makeTarget(dev, 64, 36)
    let pb = makeYCbCr(64, 36, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, bits: 8, quads: quads)
    try renderAndWait(comp, [RenderLayer(content: .frame(pb, colorHint: hint()))], f, t, queue: q)
    near(pixel(t, 48, 9), expected(quads[1], full: true), 1.0 / 255, "420f")
    let pb2 = makeYCbCr(64, 36, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bits: 8, quads: quads)
    try renderAndWait(comp, [RenderLayer(content: .frame(pb2, colorHint: hint(matrix: "ITU_R_601_4")))], f, t, queue: q)
    near(pixel(t, 16, 27), expected(quads[2], kr: 0.299, kb: 0.114), 1.0 / 255, "601")
}

@Test func pillarAndLetterbox() throws {
    guard let (dev, q, comp) = setup() else { return }
    // 16:9 layer in a 9:16 canvas: fitted 108 x 60.75, letterboxed top/bottom.
    let f = format(108, 192)
    let t = makeTarget(dev, 108, 192)
    let pb = makeYCbCr(192, 108, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bits: 8,
                       quads: Array(repeating: Code(y: 180, cb: 100, cr: 160), count: 4))
    try renderAndWait(comp, [RenderLayer(content: .frame(pb, colorHint: hint()))], f, t, queue: q)
    let want = expected(Code(y: 180, cb: 100, cr: 160))
    near(pixel(t, 54, 96), want, 1.0 / 255, "centre")
    near(pixel(t, 54, 70), want, 1.0 / 255, "inside top edge")   // fitted spans y 65.6 ... 126.4
    near(pixel(t, 54, 122), want, 1.0 / 255, "inside bottom edge")
    near(pixel(t, 54, 60), [0, 0, 0], 1.0 / 255, "letterbox top")
    near(pixel(t, 54, 131), [0, 0, 0], 1.0 / 255, "letterbox bottom")
    near(pixel(t, 0, 0), [0, 0, 0], 1.0 / 255, "corner")
    // 9:16 layer in a 16:9 canvas: pillarbox left/right.
    let f2 = format(192, 108), t2 = makeTarget(dev, 192, 108)
    let pb2 = makeYCbCr(108, 192, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bits: 8,
                        quads: Array(repeating: Code(y: 180, cb: 100, cr: 160), count: 4))
    try renderAndWait(comp, [RenderLayer(content: .frame(pb2, colorHint: hint()))], f2, t2, queue: q)
    near(pixel(t2, 96, 54), want, 1.0 / 255, "pillar centre")
    near(pixel(t2, 20, 54), [0, 0, 0], 1.0 / 255, "pillar left")
    near(pixel(t2, 172, 54), [0, 0, 0], 1.0 / 255, "pillar right")
}

@Test func transformPositionScaleRotationOpacity() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(100, 100)
    let t = makeTarget(dev, 100, 100)
    let white = makeBGRA(100, 100, (255, 255, 255, 255))
    // Half scale, moved +25 x (right) / -25 y (up): covers x 50..100, y 0..50 (centre 75, 25).
    let tr = ClipTransform(position: Vec2(25, -25), scale: Vec2(0.5, 0.5))
    try renderAndWait(comp, [RenderLayer(content: .frame(white, colorHint: hint()), transform: tr)], f, t, queue: q)
    near(pixel(t, 75, 25), [1, 1, 1], 1.0 / 255, "moved layer")
    near(pixel(t, 25, 75), [0, 0, 0], 1.0 / 255, "empty area")
    near(pixel(t, 45, 25), [0, 0, 0], 1.0 / 255, "left of moved layer")
    // Opacity 0.5 over a red base: linear mix.
    let red = makeBGRA(100, 100, (0, 0, 255, 255))
    let half = ClipTransform(opacity: 0.5)
    try renderAndWait(comp, [RenderLayer(content: .frame(red, colorHint: hint())),
                             RenderLayer(content: .frame(white, colorHint: hint()), transform: half)], f, t, queue: q)
    near(pixel(t, 50, 50), [1, 0.5, 0.5], 1.0 / 255, "opacity")
    // Rotation 90 deg clockwise of a 100x50 bar (16:9-ish) in a 100x100 canvas: bar becomes vertical.
    let bar = makeBGRA(100, 50, (255, 255, 255, 255))
    try renderAndWait(comp, [RenderLayer(content: .frame(bar, colorHint: hint()), transform: ClipTransform(rotation: 90))], f, t, queue: q)
    near(pixel(t, 50, 10), [1, 1, 1], 1.0 / 255, "rotated bar now vertical (covers top)")
    near(pixel(t, 10, 50), [0, 0, 0], 1.0 / 255, "rotated bar leaves the sides empty")
}

@Test func rotationIsClockwiseAboutAnchor() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(100, 100), t = makeTarget(dev, 100, 100)
    // 100x100 white layer scaled to 0.5 (50x50), anchor at its top-left corner offset (-25,-25), position 0:
    // the top-left corner sits on the canvas centre; rotated 90 deg clockwise the square lies in the bottom-left quadrant.
    let tr = ClipTransform(scale: Vec2(0.5, 0.5), rotation: 90, anchor: Vec2(-50, -50))
    let white = makeBGRA(100, 100, (255, 255, 255, 255))
    try renderAndWait(comp, [RenderLayer(content: .frame(white, colorHint: hint()), transform: tr)], f, t, queue: q)
    near(pixel(t, 38, 62), [1, 1, 1], 1.0 / 255, "bottom-left quadrant filled")
    near(pixel(t, 62, 38), [0, 0, 0], 1.0 / 255, "top-right empty")
    near(pixel(t, 62, 62), [0, 0, 0], 1.0 / 255, "bottom-right empty")
}

@Test func placeholdersAndFallback() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(32, 18), t = makeTarget(dev, 32, 18)
    for k in [PlaceholderKind.offline, .damaged, .loading] {
        try renderAndWait(comp, [RenderLayer(content: .placeholder(k))], f, t, queue: q)
        let e = Compositor.placeholderLinear(k)
        near(pixel(t, 16, 9), [Double(e.x), Double(e.y), Double(e.z)], 1.0 / 255, "\(k)")
    }
    // Unsupported pixel format (32ARGB) -> damaged placeholder + counter.
    let pb = makeBuffer(16, 16, kCVPixelFormatType_32ARGB)
    try renderAndWait(comp, [RenderLayer(content: .frame(pb, colorHint: hint()))], f, t, queue: q)
    let e = Compositor.placeholderLinear(.damaged)
    near(pixel(t, 16, 9), [Double(e.x), Double(e.y), Double(e.z)], 1.0 / 255, "fallback")
    #expect(comp.unsupportedFrameCount == 1)
}

@Test func emptyLayersAreBlack() throws {
    guard let (dev, q, comp) = setup() else { return }
    let t = makeTarget(dev, 8, 8)
    try renderAndWait(comp, [], format(8, 8), t, queue: q)
    near(pixel(t, 4, 4), [0, 0, 0])
}

@Test func colorStageSlotMatchesDirectPathForRec709() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(64, 36), t = makeTarget(dev, 64, 36)
    let pb = makeYCbCr(64, 36, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bits: 8, quads: quads)
    let pipe = ColorPipeline(source: .rec709)
    try renderAndWait(comp, [RenderLayer(content: .frame(pb, colorHint: hint()), colorPipeline: pipe)], f, t, queue: q)
    for (i, p) in [(16, 9), (48, 9), (16, 27), (48, 27)].enumerated() {
        near(pixel(t, p.0, p.1), expected(quads[i]), 2.0 / 255, "colour stage q\(i)")
    }
}

@Test func pixelFormatTables() {
    #expect(PixelFormats.info(for: PixelFormats.fourCC("420v")) == PixelFormats.info(for: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
    #expect(PixelFormats.info(for: PixelFormats.fourCC("x420"))?.bitDepth == 10)
    #expect(PixelFormats.info(for: PixelFormats.fourCC("x422"))?.fullRange == false)
    #expect(PixelFormats.info(for: PixelFormats.fourCC("&8v0"))?.compressed == true)
    #expect(PixelFormats.info(for: PixelFormats.fourCC("&xf2")) == nil)
    #expect(PixelFormats.uncompressedEquivalent(of: PixelFormats.fourCC("&xf2")) == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    #expect(PixelFormats.matrix(tag: nil) == .bt709)
    #expect(PixelFormats.matrix(tag: "ITU_R_601_4") == .bt601)
    #expect(PixelFormats.matrix(tag: "bt2020nc") == .bt2020)
}

@Test func threeStacked4KLayersTiming() throws {
    guard let (dev, q, comp) = setup() else { return }
    let w = 3840, h = 2160
    let f = format(w, h), t = makeTarget(dev, w, h)
    let layers = (0..<3).map { i -> RenderLayer in
        let pb = makeYCbCr(w, h, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bits: 8, quads: quads)
        return RenderLayer(content: .frame(pb, colorHint: hint()),
                           transform: ClipTransform(scale: Vec2(1 - Double(i) * 0.1, 1 - Double(i) * 0.1), opacity: i == 0 ? 1 : 0.7))
    }
    var best = Double.infinity, bestGPU = Double.infinity
    for _ in 0..<12 {
        let t0 = CFAbsoluteTimeGetCurrent()
        let cb = q.makeCommandBuffer()!
        try comp.render(layers, format: f, into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        best = min(best, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        bestGPU = min(bestGPU, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
    }
    print("E-07 compositor 3x4K 420v layers: encode+GPU wall best \(String(format: "%.2f", best)) ms, GPU-only best \(String(format: "%.2f", bestGPU)) ms (budget 4 ms)")
    #expect(best.isFinite)
}

// MARK: Rounded corners / edge antialiasing

@Test func roundedCornerMask() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(64, 64)
    let t = makeTarget(dev, 64, 64)
    let below = RenderLayer(content: .frame(makeBGRA(64, 64, (0, 255, 0, 255)), colorHint: hint()))
    // Top layer: 32 px square at 16..48 (scale 0.5). Radius 20 layer px = 10 screen px.
    func top(dx: Double = 0, radius: Double = 20, rotation: Double = 0) -> RenderLayer {
        RenderLayer(content: .frame(makeBGRA(64, 64, (0, 0, 255, 255)), colorHint: hint()),
                    transform: ClipTransform(position: Vec2(dx, 0), scale: Vec2(0.5, 0.5), rotation: rotation),
                    cornerRadius: radius)
    }
    try renderAndWait(comp, [below, top()], f, t, queue: q)
    near(pixel(t, 16, 16), [0, 1, 0], 1.0 / 255, "corner shows layer below")
    near(pixel(t, 32, 32), [1, 0, 0], 1.0 / 255, "centre opaque")
    near(pixel(t, 32, 16), [1, 0, 0], 1.0 / 255, "straight edge pixel inside")
    near(pixel(t, 10, 32), [0, 1, 0], 1.0 / 255, "outside")
    // Edge at x = 16.5: pixel 16 is half covered -> between, premultiplied blend over green.
    try renderAndWait(comp, [below, top(dx: 0.5)], f, t, queue: q)
    let e = pixel(t, 16, 32)
    #expect(abs(e[0] - 0.5) < 0.06 && abs(e[1] - 0.5) < 0.06, "AA edge \(e)")
    // Radius 0 and no rotation: no mask, hard edge as before.
    try renderAndWait(comp, [below, top(radius: 0)], f, t, queue: q)
    near(pixel(t, 16, 16), [1, 0, 0], 1.0 / 255, "square corner")
}

@Test func rotatedEdgeIsAntialiased() throws {
    guard let (dev, q, comp) = setup() else { return }
    let f = format(64, 64)
    let t = makeTarget(dev, 64, 64)
    let below = RenderLayer(content: .frame(makeBGRA(64, 64, (0, 255, 0, 255)), colorHint: hint()))
    let rot = RenderLayer(content: .frame(makeBGRA(64, 64, (0, 0, 255, 255)), colorHint: hint()),
                          transform: ClipTransform(scale: Vec2(0.5, 0.5), rotation: 45))
    try renderAndWait(comp, [below, rot], f, t, queue: q)
    var intermediate = 0
    for y in 0..<64 { for x in 0..<64 {
        let p = pixel(t, x, y)
        if p[0] > 0.1 && p[0] < 0.9 { intermediate += 1 }
    } }
    #expect(intermediate > 20, "expected antialiased diagonal edge pixels, got \(intermediate)")
    near(pixel(t, 32, 32), [1, 0, 0], 1.0 / 255, "centre")
}
