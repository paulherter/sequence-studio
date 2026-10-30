import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Synchronization
import Testing
import VideoToolbox
@testable import SQMedia

/// VT delivers the native (often Apple-lossless compressed) format, which FrameStamp cannot read: convert to BGRA first.
private func readStamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}
private func stamps(_ frames: [DecodedFrame]) -> [Int?] { frames.map { readStamp($0.pixelBuffer) } }

private func makeDecoder(_ spec: TestClipSpec) async throws -> (VTVideoDecoder, AVDemuxer) {
    let url = try await TestClipWriter.write(spec)
    let d = try await AVDemuxer(url: url)
    return (try VTVideoDecoder(demuxer: d, media: UUID()), d)
}

@Test func fullClipDecodesInOrder() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let (dec, d) = try await makeDecoder(spec)
    let frames = try await dec.decode(0...59)
    #expect(stamps(frames) == (0..<60).map { Optional($0) })
    #expect(frames.map(\.pts) == d.index.entries.map(\.pts))
    #expect(frames[0].byteCost > 0)
}

@Test func midGopRangeReturnsExactlyRequested() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let (dec, _) = try await makeDecoder(spec)
    let frames = try await dec.decode(14...20)
    #expect(stamps(frames) == (14...20).map { Optional($0) })
}

@Test func contiguousRangesDoNotReseek() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let (dec, _) = try await makeDecoder(spec)
    let a = try await dec.decode(0...11)
    #expect(stamps(a) == (0...11).map { Optional($0) })
    #expect(dec.stats.reseeks == 1)
    let before = dec.stats
    let b = try await dec.decode(12...23)
    #expect(stamps(b) == (12...23).map { Optional($0) })
    #expect(dec.stats.reseeks == 1)
    // Only samples after the first call's last one were submitted (no re-decode of GOP 0 / the sync at 11).
    #expect(dec.stats.samplesSubmitted - before.samplesSubmitted <= 14)
    let c = try await dec.decode(24...47)
    #expect(stamps(c) == (24...47).map { Optional($0) })
    #expect(dec.stats.reseeks == 1)
}

@Test func backwardJumpReseeks() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let (dec, _) = try await makeDecoder(spec)
    _ = try await dec.decode(30...40)
    #expect(dec.stats.reseeks == 1)
    let f = try await dec.decode(5...9)
    #expect(stamps(f) == (5...9).map { Optional($0) })
    #expect(dec.stats.reseeks == 2)
}

@Test func invalidateThenDecodeWorks() async throws {
    var spec = TestClipSpec(); spec.frameCount = 24
    let (dec, _) = try await makeDecoder(spec)
    _ = try await dec.decode(0...5)
    dec.invalidate()
    let f = try await dec.decode(6...8)
    #expect(stamps(f) == [6, 7, 8])
    await #expect(throws: MediaError.self) { _ = try await dec.decode(0...999) }
}

@Test func cancelledDecodeThrows() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let (dec, _) = try await makeDecoder(spec)
    let t = Task { try await dec.decode(0...59) }
    t.cancel()
    await #expect(throws: CancellationError.self) { _ = try await t.value }
    let f = try await dec.decode(0...3)       // decoder stays usable
    #expect(stamps(f) == [0, 1, 2, 3])
}

@Test func halfScaleHalvesOutput() async throws {
    var spec = TestClipSpec(); spec.frameCount = 12
    let url = try await TestClipWriter.write(spec)
    let d = try await AVDemuxer(url: url)
    let dec = try VTVideoDecoder(demuxer: d, media: UUID(), scale: .half)
    let f = try await dec.decode(0...2)
    #expect(CVPixelBufferGetWidth(f[0].pixelBuffer) == 160 && CVPixelBufferGetHeight(f[0].pixelBuffer) == 90)
}

/// ProRes decodes at the reduced size itself (VT scaled output costs 4.9 ms per 4K frame vs 0.7 ms reduced, decode-hw
/// bench); only for preview scales, full size never sets it (export pixels unchanged). H.264 has no reduced decode.
@Test func proResPreviewScalesUseReducedResolutionDecode() async throws {
    var spec = TestClipSpec(); spec.codec = .prores4444; spec.frameCount = 4
    let d = try await AVDemuxer(url: try await TestClipWriter.write(spec))
    let full = try VTVideoDecoder(demuxer: d, media: UUID())
    #expect(!full.usesReducedResolutionDecode)
    for (scale, w, h) in [(DecodeScale.half, 160, 90), (.quarter, 80, 44)] {
        let dec = try VTVideoDecoder(demuxer: d, media: UUID(), scale: scale)
        #expect(dec.usesReducedResolutionDecode)
        let f = try await dec.decode(0...3)
        #expect(f.count == 4)
        #expect(CVPixelBufferGetWidth(f[0].pixelBuffer) == w && CVPixelBufferGetHeight(f[0].pixelBuffer) == h)
    }
    var h264 = TestClipSpec(); h264.frameCount = 4
    let hd = try await AVDemuxer(url: try await TestClipWriter.write(h264))
    #expect(try !VTVideoDecoder(demuxer: hd, media: UUID(), scale: .half).usesReducedResolutionDecode)
}

/// Hardware probe used by the AutoProxy software-decode hint: H.264 / HEVC decode in hardware on Apple silicon.
@Test func hardwareDecodeProbe() async throws {
    var spec = TestClipSpec(); spec.frameCount = 2
    let d = try await AVDemuxer(url: try await TestClipWriter.write(spec))
    #if arch(arm64)
    #expect(HardwareDecode.isHardware(d.formatDescription))
    #expect(HardwareDecode.isHardware(d.formatDescription))   // cached
    #endif
}

@Test func hevcMain10Decodes() async throws {
    var spec = TestClipSpec(); spec.codec = .hevcMain10; spec.frameCount = 36
    let (dec, _) = try await makeDecoder(spec)
    let frames = try await dec.decode(0...35)
    #expect(stamps(frames) == (0..<36).map { Optional($0) })
    let mid = try await dec.decode(14...20)
    #expect(stamps(mid) == (14...20).map { Optional($0) })
}

@Test func sonyGopDecodesInHardware() async throws {
    let root = ProcessInfo.processInfo.environment["SQ_MEDIA_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Videos")
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
          let url = (en.allObjects as? [URL])?.first(where: { $0.lastPathComponent == "C2160.MP4" })
    else { return }     // clip absent: skip
    let d = try await AVDemuxer(url: url)
    let dec = try VTVideoDecoder(demuxer: d, media: UUID())
    #expect(dec.isHardware)
    let frames = try await dec.decode(0...29)
    #expect(frames.count == 30)
    #expect(frames.map(\.pts) == d.index.entries[0...29].map(\.pts))
}

@Test func nativeUncompressedDecodeFormat() {
    func info(_ chroma: String, _ bits: Int) -> VideoTrackInfo {
        VideoTrackInfo(width: 16, height: 16, codec: "avc1", bitDepth: bits, chroma: chroma,
                       nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
    }
    typealias F = DecodePixelFormat
    #expect(F.nativeUncompressed(for: info("4:2:2", 10), fullRange: true) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
    #expect(F.nativeUncompressed(for: info("4:2:2", 10), fullRange: false) == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    #expect(F.nativeUncompressed(for: info("4:2:0", 10), fullRange: false) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    #expect(F.nativeUncompressed(for: info("4:2:0", 8), fullRange: false) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    #expect(F.nativeUncompressed(for: info("4:2:0", 8), fullRange: true) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    #expect(F.nativeUncompressed(for: info("4:4:4", 12), fullRange: false) == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
    #expect(F.nativeUncompressed(for: info("4:2:2", 8), fullRange: false) == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange)
}

/// Early-delivered frames belong to the caller (the playback cache, which may drop far ones at once): the decoder must not
/// pin a whole long GOP until the job ends (4 jobs x 150 frames x 32 MB of 4K 10-bit = 19 GB).
@Test func earlyDeliveredFramesAreNotHeldUntilTheJobEnds() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let (dec, _) = try await makeDecoder(spec)
    let got = Mutex<[Int?]>([])
    let rest = try await dec.decode(0...59, deliver: { f in let s = readStamp(f.pixelBuffer); got.withLock { $0.append(s) } })
    #expect(got.withLock { $0 }.sorted { ($0 ?? -1) < ($1 ?? -1) } == (0..<60).map { Optional($0) }, "every frame delivered")
    #expect(rest.isEmpty, "delivered frames are not returned again")
    let frameBytes = 320 * 180 * 2
    #expect(dec.peakHeldFrames * frameBytes <= 4 * frameBytes, "only reorder look-ahead is held, not the GOP")
    // Without early delivery everything is returned as before.
    let all = try await dec.decode(0...59)
    #expect(stamps(all) == (0..<60).map { Optional($0) })
}
