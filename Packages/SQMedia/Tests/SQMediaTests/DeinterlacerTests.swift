import CoreMedia
import CoreVideo
import Foundation
import Metal
import SQCore
import SQMediaTestSupport
import Synchronization
import Testing
@testable import SQMedia

/// A synthetic interlaced picture: a still background with detail (gradients, vertical bars, a one-line rule) and a
/// bright box that moves `shift` pixels between the two fields. `frame` weaves the scene at two times into one buffer.
private struct Scene {
    var width = 192, height = 96
    var shift = 12
    /// A bright first and last row (a still edge line, as a letterbox border or a title safe line gives).
    var edgeLines = false

    /// Luma (0...255) of the scene with the box at `boxX`.
    func luma(_ x: Int, _ y: Int, boxX: Int) -> Int {
        if edgeLines, y == 0 || y == height - 1 { return 230 }
        if (24..<60).contains(y), (boxX..<boxX + 40).contains(x) { return 220 }
        if y == 80 { return 200 }                                  // one-line rule in a still area
        if x >= 150 { return (x / 3) % 2 == 0 ? 60 : 150 }         // vertical bars
        return 40 + (x + 2 * y) / 4                                // diagonal gradient
    }

    /// Cb, Cr (0...255) at luma position: the box is saturated, the rest neutral with a slow ramp.
    func chroma(_ x: Int, _ y: Int, boxX: Int) -> (Int, Int) {
        if (24..<60).contains(y), (boxX..<boxX + 40).contains(x) { return (60, 200) }
        return (128 + x / 16, 128)
    }

    /// `first`: which rows hold the earlier field (box at 20); the other rows show the box `shift` pixels later.
    func frame(_ format: OSType, first: FieldOrder, moving: Bool = true) -> CVPixelBuffer {
        make(format) { y in (y & 1) == (first == .topFirst ? 0 : 1) || !moving ? 20 : 20 + shift }
    }

    /// The whole picture at the time of the earlier field (what a perfect deinterlacer returns).
    func progressive(_ format: OSType) -> CVPixelBuffer { make(format) { _ in 20 } }

    private func make(_ format: OSType, boxAt: (Int) -> Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb)
        let buffer = pb!
        let wide = Deinterlacer.layout(of: format)!.wide
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        func put(_ plane: Int, _ x: Int, _ y: Int, _ ch: Int, _ v: Int) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)! + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let n = plane + 1
            if wide { base.assumingMemoryBound(to: UInt16.self)[x * n + ch] = UInt16(v * 4) << 6 }
            else { base.assumingMemoryBound(to: UInt8.self)[x * n + ch] = UInt8(v) }
        }
        for y in 0..<height { for x in 0..<width { put(0, x, y, 0, luma(x, y, boxX: boxAt(y))) } }
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1), ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let sx = width / cw, sy = height / ch
        for j in 0..<ch {
            // Interlaced 4:2:0 stores chroma per field: chroma row j belongs to the field of its parity.
            let lumaRow = sy == 2 ? 2 * (j & ~1) + (j & 1) : j
            for i in 0..<cw {
                let (cb, cr) = chroma(i * sx, lumaRow, boxX: boxAt(sy == 2 ? j : lumaRow))
                put(1, i, j, 0, cb); put(1, i, j, 1, cr)
            }
        }
        return buffer
    }
}

/// Samples of a plane in the format's own code values (0...255 or 0...1023), row-major, channels interleaved.
private func samples(_ pb: CVPixelBuffer, plane: Int) -> [Double] {
    let wide = Deinterlacer.layout(of: CVPixelBufferGetPixelFormatType(pb))!.wide
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane + 1), h = CVPixelBufferGetHeightOfPlane(pb, plane)
    var out: [Double] = []
    out.reserveCapacity(w * h)
    for y in 0..<h {
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)! + y * CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        for x in 0..<w {
            out.append(wide ? Double(base.assumingMemoryBound(to: UInt16.self)[x]) / 64.0
                            : Double(base.assumingMemoryBound(to: UInt8.self)[x]))
        }
    }
    return out
}

/// A packed 'y416' picture (alpha video): all four channels carry the scene's luma, the box moves between the fields.
private func packedFrame(_ scene: Scene, first: FieldOrder, moving: Bool = true) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
    CVPixelBufferCreate(nil, scene.width, scene.height, kCVPixelFormatType_4444AYpCbCr16, attrs as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for y in 0..<scene.height {
        let row = (CVPixelBufferGetBaseAddress(buffer)! + y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt16.self)
        let boxX = (y & 1) == (first == .topFirst ? 0 : 1) || !moving ? 20 : 20 + scene.shift
        for x in 0..<scene.width {
            let v = UInt16(scene.luma(x, y, boxX: boxX) * 257)
            for ch in 0..<4 { row[x * 4 + ch] = ch == 3 ? v / 2 : v }
        }
    }
    return buffer
}

/// Samples of a packed picture in 8-bit code values, row-major, channels interleaved.
private func packedSamples(_ pb: CVPixelBuffer) -> [Double] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb) * 4, h = CVPixelBufferGetHeight(pb)
    var out: [Double] = []
    out.reserveCapacity(w * h)
    for y in 0..<h {
        let row = (CVPixelBufferGetBaseAddress(pb)! + y * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: UInt16.self)
        for x in 0..<w { out.append(Double(row[x]) / 257.0) }
    }
    return out
}

private func maxDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer, plane: Int) -> Double {
    zip(samples(a, plane: plane), samples(b, plane: plane)).map { abs($0 - $1) }.max() ?? 0
}

private let formats: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                                 kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                                 kCVPixelFormatType_444YpCbCr10BiPlanarFullRange]

@Suite struct DeinterlacerTests {
    @Test func aStillPictureIsWovenUnchanged() throws {
        for format in formats {
            for order in FieldOrder.allCases {
                let src = Scene().frame(format, first: order, moving: false)
                let out = try #require(Deinterlacer.deinterlaceCPU(src, fieldOrder: order))
                #expect(maxDifference(src, out, plane: 0) == 0)
                #expect(maxDifference(src, out, plane: 1) == 0)
            }
        }
    }

    @Test func theEarlierFieldIsKeptAsStored() throws {
        let scene = Scene()
        for order in FieldOrder.allCases {
            let src = scene.frame(kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, first: order)
            let out = try #require(Deinterlacer.deinterlaceCPU(src, fieldOrder: order))
            let (a, b) = (samples(src, plane: 0), samples(out, plane: 0))
            let keep = order == .topFirst ? 0 : 1
            for y in stride(from: keep, to: scene.height, by: 2) {
                #expect(a[(y * scene.width)..<((y + 1) * scene.width)] == b[(y * scene.width)..<((y + 1) * scene.width)])
            }
        }
    }

    @Test func movingAreasLoseTheCombInBothFieldOrders() throws {
        let scene = Scene()
        for format in formats {
            let truth = scene.progressive(format)
            for order in FieldOrder.allCases {
                let src = scene.frame(format, first: order)
                #expect(maxDifference(src, truth, plane: 0) > 100)          // the woven frame combs
                let out = try #require(Deinterlacer.deinterlaceCPU(src, fieldOrder: order))
                // Interpolated lines differ from the true picture only by the gradient's rounding and on the one line where
                // the box's horizontal edge moved (no comb there: a single line cannot tell motion from an edge).
                let (o, t) = (samples(out, plane: 0), samples(truth, plane: 0))
                let far = zip(o, t).filter { abs($0 - $1) > 3 }.count
                #expect(far <= 2 * scene.shift, "format \(format) order \(order): \(far) luma samples off")
                let (oc, tc) = (samples(out, plane: 1), samples(truth, plane: 1))
                let farChroma = zip(oc, tc).filter { abs($0 - $1) > 3 }.count
                #expect(farChroma <= 4 * scene.shift, "format \(format) order \(order): \(farChroma) chroma samples off")
            }
        }
    }

    @Test func theFieldOrderDecidesWhichFieldSurvives() throws {
        let scene = Scene(), format = kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
        let src = scene.frame(format, first: .topFirst)
        let wrong = try #require(Deinterlacer.deinterlaceCPU(src, fieldOrder: .bottomFirst))
        // Read as bottom field first, the later field (box 12 px further) is the one kept.
        let o = samples(wrong, plane: 0)
        // Inside the later box position only: column 65 is box at the later time, background at the earlier.
        for y in 30..<54 { #expect(o[y * scene.width + 65] == 220) }
        let right = samples(try #require(Deinterlacer.deinterlaceCPU(src, fieldOrder: .topFirst)), plane: 0)
        for y in 30..<54 { #expect(right[y * scene.width + 65] < 120) }
    }

    @Test func metalMatchesTheCPUReference() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        for format in formats {
            for order in FieldOrder.allCases {
                let src = Scene().frame(format, first: order)
                let cpu = try #require(Deinterlacer.deinterlaceCPU(src, fieldOrder: order))
                let gpu = try #require(Deinterlacer.deinterlaceMetal(src, fieldOrder: order))
                #expect(maxDifference(cpu, gpu, plane: 0) <= 1, "luma, format \(format)")
                #expect(maxDifference(cpu, gpu, plane: 1) <= 1, "chroma, format \(format)")
                #expect(maxDifference(src, gpu, plane: 0) > 100)
            }
        }
    }

    @Test func tagsMoveOverAndTheFieldTagsDoNot() throws {
        let src = Scene().frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, first: .topFirst)
        CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(src, kCVImageBufferFieldCountKey, 2 as CFNumber, .shouldPropagate)
        CVBufferSetAttachment(src, kCVImageBufferFieldDetailKey, kCVImageBufferFieldDetailTemporalTopFirst, .shouldPropagate)
        let out = Deinterlacer.deinterlace(src, fieldOrder: .topFirst)
        #expect(out !== src)
        #expect(CVBufferCopyAttachment(out, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        #expect(CVBufferCopyAttachment(out, kCVImageBufferFieldCountKey, nil) == nil)
        #expect(CVBufferCopyAttachment(out, kCVImageBufferFieldDetailKey, nil) == nil)
        #expect(CVPixelBufferGetIOSurface(out) != nil)
    }

    @Test func unknownFormatsPassThroughAndSayThatTheyDid() {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &pb)
        let out = Deinterlacer.deinterlace(pb!, fieldOrder: .topFirst)
        #expect(out === pb!)
        #expect(!Deinterlacer.isDeinterlaced(out))
        let known = Scene().frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, first: .topFirst)
        #expect(!Deinterlacer.isDeinterlaced(known))
        #expect(Deinterlacer.isDeinterlaced(Deinterlacer.deinterlace(known, fieldOrder: .topFirst)))
    }

    /// The first and last row have one neighbor: a still edge line there is not a comb, in either field order.
    @Test func edgeRowsAreLeftAlone() throws {
        var scene = Scene(); scene.edgeLines = true
        for format in formats {
            for order in FieldOrder.allCases {
                let still = scene.frame(format, first: order, moving: false)
                let cpu = try #require(Deinterlacer.deinterlaceCPU(still, fieldOrder: order))
                #expect(maxDifference(still, cpu, plane: 0) == 0, "CPU, format \(format) order \(order)")
                #expect(maxDifference(still, cpu, plane: 1) == 0)
                // With motion elsewhere the two edge rows still come out as stored.
                let moving = scene.frame(format, first: order)
                let out = try #require(Deinterlacer.deinterlaceCPU(moving, fieldOrder: order))
                let (a, b) = (samples(moving, plane: 0), samples(out, plane: 0))
                for y in [0, scene.height - 1] {
                    #expect(a[(y * scene.width)..<((y + 1) * scene.width)] == b[(y * scene.width)..<((y + 1) * scene.width)])
                }
                guard MTLCreateSystemDefaultDevice() != nil else { continue }
                let gpu = try #require(Deinterlacer.deinterlaceMetal(still, fieldOrder: order))
                #expect(maxDifference(still, gpu, plane: 0) == 0, "Metal, format \(format) order \(order)")
                #expect(maxDifference(still, gpu, plane: 1) == 0)
            }
        }
    }

    /// Interlaced video with alpha decodes to packed 'y416': the pass reads it too (it used to hand it back woven).
    @Test func packedAlphaPicturesAreDeinterlaced() throws {
        let scene = Scene()
        #expect(Deinterlacer.isSupported(DecodePixelFormat.alphaFormat))
        for order in FieldOrder.allCases {
            let still = packedFrame(scene, first: order, moving: false)
            let same = try #require(Deinterlacer.deinterlaceCPU(still, fieldOrder: order))
            #expect(packedSamples(still) == packedSamples(same))
            let src = packedFrame(scene, first: order)
            let truth = packedSamples(still)
            let woven: Double = zip(packedSamples(src), truth).map { abs($0 - $1) }.max() ?? 0
            #expect(woven > 100)
            let cpu = try #require(Deinterlacer.deinterlaceCPU(src, fieldOrder: order))
            let far = zip(packedSamples(cpu), truth).filter { abs($0 - $1) > 3 }.count
            #expect(far <= 8 * scene.shift, "order \(order): \(far) samples off")
            let whole = Deinterlacer.deinterlace(src, fieldOrder: order)
            #expect(Deinterlacer.isDeinterlaced(whole))
            guard MTLCreateSystemDefaultDevice() != nil else { continue }
            let gpu = try #require(Deinterlacer.deinterlaceMetal(src, fieldOrder: order))
            let apart: Double = zip(packedSamples(cpu), packedSamples(gpu)).map { abs($0 - $1) }.max() ?? 0
            #expect(apart <= 1)
        }
    }

    /// The decoder hook: frames leave it deinterlaced, each exactly once; the pass runs on the stored lines and a
    /// reduced decode gets the picture at the size its scale names.
    @Test func decoderDeinterlacesAfterDecodeAtFullSize() async throws {
        var spec = TestClipSpec(); spec.frameCount = 12; spec.width = 320; spec.height = 180
        let url = try await TestClipWriter.write(spec)
        let demuxer = try await AVDemuxer(url: url)
        let plain = try await VTVideoDecoder(demuxer: demuxer, media: UUID()).decode(0...11)
        let fields = try VTVideoDecoder(demuxer: demuxer, media: UUID(), deinterlace: .topFirst)
        // Two calls: the second continues the first (frames carried over are not processed twice).
        let out = try await fields.decode(0...5) + fields.decode(6...11)
        #expect(out.count == plain.count)
        #expect(out.map(\.pts) == plain.map(\.pts))
        for (a, b) in zip(plain, out) {
            #expect(CVPixelBufferGetHeight(b.pixelBuffer) == 180)
            #expect(Deinterlacer.isDeinterlaced(b.pixelBuffer))
            #expect(!Deinterlacer.isDeinterlaced(a.pixelBuffer))
            let want = try #require(Deinterlacer.deinterlaceCPU(a.pixelBuffer, fieldOrder: .topFirst))
            #expect(maxDifference(want, b.pixelBuffer, plane: 0) <= 1)
            #expect(maxDifference(want, b.pixelBuffer, plane: 1) <= 1)
        }
        // Reduced quality: the frame has the size the scale names (it is cached under that scale), not the stored size.
        for (scale, size) in [(DecodeScale.half, (160, 90)), (.quarter, (80, 44))] {
            let small = try VTVideoDecoder(demuxer: demuxer, media: UUID(), scale: scale, deinterlace: .topFirst)
            let frames = try await small.decode(0...5) + small.decode(6...11)
            #expect(frames.map(\.pts) == plain.map(\.pts))
            for f in frames {
                #expect(CVPixelBufferGetWidth(f.pixelBuffer) == size.0)
                #expect(CVPixelBufferGetHeight(f.pixelBuffer) == size.1)
                #expect(Deinterlacer.isDeinterlaced(f.pixelBuffer))
                #expect(CVPixelBufferGetIOSurface(f.pixelBuffer) != nil)
                #expect(CVBufferCopyAttachment(f.pixelBuffer, kCVImageBufferFieldCountKey, nil) == nil)
            }
            // The same picture, smaller: the mean luma agrees with the full-size result.
            let (a, b) = (samples(out[3].pixelBuffer, plane: 0), samples(frames[3].pixelBuffer, plane: 0))
            let meanA: Double = a.reduce(0, +) / Double(a.count)
            let meanB: Double = b.reduce(0, +) / Double(b.count)
            #expect(abs(meanA - meanB) < 2)
        }
        // Early delivery takes the same path.
        let early = Mutex<[DecodedFrame]>([])
        let again = try VTVideoDecoder(demuxer: demuxer, media: UUID(), deinterlace: .topFirst)
        let rest = try await again.decode(0...11) { f in early.withLock { $0.append(f) } }
        let all = (early.withLock { $0 } + rest).sorted { $0.pts < $1.pts }
        #expect(all.count == 12)
        for (a, b) in zip(out, all) { #expect(maxDifference(a.pixelBuffer, b.pixelBuffer, plane: 0) == 0) }
        // Without a field order the decoder hands out VT's own buffers: no pass, no copy.
        #expect(try makeVideoDecoder(demuxer: demuxer, media: UUID()) is VTVideoDecoder)
    }

    /// Five or more interlaced sizes at once must not throw every pool away each time one more shows up.
    @Test func bufferPoolsDropTheLeastRecentlyUsedOneOnly() throws {
        let buffers = DeinterlaceBuffers(capacity: 3)
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        func key(_ w: Int) -> DeinterlaceBuffers.Key { .init(format: format, width: w, height: 32) }
        for w in [64, 96, 128] { #expect(buffers.make(format: format, width: w, height: 32) != nil) }
        #expect(buffers.keys == [key(64), key(96), key(128)])
        #expect(buffers.make(format: format, width: 64, height: 32) != nil)        // 64 is in use again: 96 is the oldest
        let d = try #require(buffers.make(format: format, width: 160, height: 32))
        #expect(CVPixelBufferGetWidth(d) == 160)
        #expect(buffers.keys == [key(64), key(128), key(160)])
        #expect(buffers.make(format: format, width: 192, height: 32) != nil)
        #expect(buffers.keys == [key(64), key(160), key(192)])
        // Sizes that alternate inside the cap never lose their pool.
        for _ in 0..<4 { for w in [64, 160, 192] { _ = buffers.make(format: format, width: w, height: 32) } }
        #expect(buffers.keys == [key(64), key(160), key(192)])
        #expect(DeinterlaceBuffers.shared.capacity == 8)
    }

    /// PERF: cost of the pass per 1080i frame (4:2:2 10 bit, the FX6's format). Off costs nothing: the pass is not run.
    @Test func perf1080i() throws {
        var scene = Scene(); scene.width = 1920; scene.height = 1080; scene.shift = 24
        let src = scene.frame(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, first: .topFirst)
        let clock = ContinuousClock()
        var gpu = Duration.zero
        if MTLCreateSystemDefaultDevice() != nil {
            _ = Deinterlacer.deinterlaceMetal(src, fieldOrder: .topFirst)          // builds the kernel
            let n = 120
            gpu = clock.measure { for _ in 0..<n { _ = Deinterlacer.deinterlaceMetal(src, fieldOrder: .topFirst) } } / n
        }
        let cpu = clock.measure { _ = Deinterlacer.deinterlaceCPU(src, fieldOrder: .topFirst) }
        func ms(_ d: Duration) -> String { String(format: "%.2f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1e3) }
        print("PERF deinterlace 1920x1080 4:2:2 10-bit: Metal \(ms(gpu)) ms/frame, CPU reference \(ms(cpu)) ms/frame, off 0.00 ms (pass not run)")
        if MTLCreateSystemDefaultDevice() != nil { #expect(gpu < .milliseconds(20)) }     // one 50i frame period
    }
}
