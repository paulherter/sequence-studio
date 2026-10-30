import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

// Preview render cache reads (F_NOCACHE): `UncachedFileDemuxer` hands out the same compressed samples as `AVDemuxer`,
// byte for byte, with the same timing and sync flags, and decodes to the same frames.

private func bytes(_ sb: CMSampleBuffer) -> [UInt8] {
    guard let b = CMSampleBufferGetDataBuffer(sb) else { return [] }
    var out = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(b))
    _ = out.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    return out
}

private func notSync(_ sb: CMSampleBuffer) -> Bool {
    guard let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
          let d = a.first else { return false }
    return (d[kCMSampleAttachmentKey_NotSync] as? Bool) == true
}

@Suite struct UncachedFileDemuxerTests {
    @Test(arguments: [TestClipSpec.Codec.h264, .prores4444])
    func readsTheSameSamplesAsAVDemuxer(codec: TestClipSpec.Codec) async throws {
        var spec = TestClipSpec(); spec.codec = codec; spec.frameCount = 36
        let url = try await TestClipWriter.write(spec)
        let plain = try await AVDemuxer(url: url)
        let uncached = try await UncachedFileDemuxer(url: url)
        #expect(uncached.usesUncachedReads)
        #expect(uncached.index.entries == plain.index.entries)
        for range in [0...35, 14...20, 30...30] {
            let a = try await plain.samples(for: range), b = try await uncached.samples(for: range)
            #expect(a.count == b.count && !b.isEmpty)
            for (x, y) in zip(a, b) {
                #expect(bytes(x) == bytes(y))
                #expect(CMSampleBufferGetPresentationTimeStamp(x) == CMSampleBufferGetPresentationTimeStamp(y))
                #expect(CMSampleBufferGetDecodeTimeStamp(x) == CMSampleBufferGetDecodeTimeStamp(y))
                #expect(notSync(x) == notSync(y))
            }
            // The streaming reader from a later decode ordinal gives the tail of the same run.
            let from = plain.index.syncDecodeOrdinal(for: range.lowerBound) + 1
            let tailA = try await plain.samples(for: range, fromDecodeOrdinal: from)
            let reader = try #require(try uncached.sampleReader(for: range, fromDecodeOrdinal: from))
            #expect(reader.count == tailA.count)
            for x in tailA { #expect(bytes(try reader.next()) == bytes(x)) }
        }
    }

    @Test func decodesToTheSameFrames() async throws {
        var spec = TestClipSpec(); spec.frameCount = 24
        let url = try await TestClipWriter.write(spec)
        let a = try VTVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID())
        let b = try VTVideoDecoder(demuxer: try await UncachedFileDemuxer(url: url), media: UUID())
        let fa = try await a.decode(5...9), fb = try await b.decode(5...9)
        #expect(fa.count == 5 && fb.count == 5)
        for (x, y) in zip(fa, fb) {
            #expect(x.pts == y.pts)
            CVPixelBufferLockBaseAddress(x.pixelBuffer, .readOnly); CVPixelBufferLockBaseAddress(y.pixelBuffer, .readOnly)
            let px = CVPixelBufferGetBaseAddressOfPlane(x.pixelBuffer, 0)!, py = CVPixelBufferGetBaseAddressOfPlane(y.pixelBuffer, 0)!
            let n = CVPixelBufferGetBytesPerRowOfPlane(x.pixelBuffer, 0) * CVPixelBufferGetHeightOfPlane(x.pixelBuffer, 0)
            #expect(memcmp(px, py, n) == 0)
            CVPixelBufferUnlockBaseAddress(x.pixelBuffer, .readOnly); CVPixelBufferUnlockBaseAddress(y.pixelBuffer, .readOnly)
        }
    }
}
