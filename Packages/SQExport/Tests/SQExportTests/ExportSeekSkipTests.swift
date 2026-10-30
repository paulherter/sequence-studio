import CoreVideo
import Foundation
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
import Testing
import VideoToolbox
@testable import SQExport

// Export seeks (PLAYBACK-PERF "Export: seeks skip unreferenced frames"): the provider's seeks (first frame, a segment's
// start, clip starts it prefetches) do not decode H.264 pictures nothing references before the target; the target is
// bit-identical to decoding the whole GOP.

private func stamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

/// Every plane's visible bytes.
private func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    var out: [UInt8] = []
    let planes = max(1, CVPixelBufferGetPlaneCount(pb))
    for p in 0..<planes {
        let planar = CVPixelBufferIsPlanar(pb)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, p) : CVPixelBufferGetBaseAddress(pb) else { continue }
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetHeight(pb)
        let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, p) : CVPixelBufferGetWidth(pb)
        let used = min(row, w * (row / max(1, w)))
        for y in 0..<h { out += UnsafeRawBufferPointer(start: base + y * row, count: used) }
    }
    return out
}

@Suite(.serialized) struct ExportSeekSkipTests {
    private func clip() async throws -> (StaticMediaResolver, UUID, AVDemuxer) {
        var spec = TestClipSpec(); spec.frameCount = 60
        let id = UUID()
        let d = try await AVDemuxer(url: try await TestClipWriter.write(spec))
        return (StaticMediaResolver(demuxers: [id: d], audio: [:]), id, d)
    }

    /// Frame `target` decoded with its whole GOP before it (no seek hint).
    private func reference(_ d: AVDemuxer, _ target: Int) async throws -> CVPixelBuffer {
        let dec = try VTVideoDecoder(demuxer: d, media: UUID())
        let gop = d.index.gop(containing: target)
        let frames = try await dec.decode(gop.lowerBound...target)
        return try #require(frames.last { d.index.frame(at: $0.pts) == target }).pixelBuffer
    }

    @Test func requestSeekSkipsUnreferencedFramesAndStaysExact() async throws {
        let (r, m, d) = try await clip()
        let gop = d.index.gop(containing: 0)
        let target = gop.lowerBound + gop.count / 2 + 1
        let p = DecoderFrameProvider(resolver: r, lookAhead: 0)
        let f = try #require(try await p.frame(media: m, at: d.index.entries[target].pts))
        #expect(stamp(f.buffer) == target)
        // No `seekSkips > 0` here: under a loaded full run the first GOP sometimes has no skippable picture before the
        // target (flaky); the prefetch test below checks the skip, this one the exact bytes.
        #expect(bytes(f.buffer) == bytes(try await reference(d, target)))
    }

    @Test func prefetchSeekSkipsUnreferencedFramesAndStaysExact() async throws {
        let (r, m, d) = try await clip()
        let gop = d.index.gop(containing: 30)
        let target = gop.lowerBound + gop.count / 2 + 1
        let p = DecoderFrameProvider(resolver: r, lookAhead: 0)
        await p.prefetch(media: m, at: d.index.entries[target].pts)
        await p.settle()
        #expect(await p.seekSkips > 0)
        let f = try #require(try await p.frame(media: m, at: d.index.entries[target].pts))
        #expect(await p.requestDecodes == 0, "the prefetch holds the frame")
        #expect(stamp(f.buffer) == target)
        #expect(bytes(f.buffer) == bytes(try await reference(d, target)))
    }
}
