import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Synchronization
import Testing
import VideoToolbox
@testable import SQMedia

// Export speed (PLAYBACK-PERF "Export speed"): a decoder that continues a GOP reads only the samples it has not
// submitted yet, not the GOP again from its sync sample (frame-by-frame export read GOP^2 / 2 samples).

/// Counts the compressed samples handed out.
private final class CountingDemuxer: Demuxing, @unchecked Sendable {
    let inner: AVDemuxer
    let read = Mutex(0)
    init(_ d: AVDemuxer) { inner = d }
    var index: SampleIndex { inner.index }
    var formatDescription: CMFormatDescription { inner.formatDescription }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        let s = try await inner.samples(for: range); read.withLock { $0 += s.count }; return s
    }
    func samples(for range: ClosedRange<Int>, fromDecodeOrdinal o: Int) async throws -> [CMSampleBuffer] {
        let s = try await inner.samples(for: range, fromDecodeOrdinal: o); read.withLock { $0 += s.count }; return s
    }
}

private func stamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

private func key(_ sb: CMSampleBuffer) -> [Int64] {
    let p = CMSampleBufferGetPresentationTimeStamp(sb), d = CMSampleBufferGetDecodeTimeStamp(sb)
    return [p.value, Int64(p.timescale), d.value, Int64(d.timescale), Int64(CMSampleBufferGetTotalSampleSize(sb))]
}

@Test func samplesFromADecodeOrdinalAreTheSuffixOfTheGop() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let d = try await AVDemuxer(url: try await TestClipWriter.write(spec))
    let gop = d.index.gop(containing: 0)
    let range = gop.lowerBound...(gop.lowerBound + gop.count - 2)
    let all = try await d.samples(for: range)
    let sync = d.index.syncDecodeOrdinal(for: range.lowerBound)
    for skip in [0, 1, 3, all.count - 1] {
        let part = try await d.samples(for: range, fromDecodeOrdinal: sync + skip)
        #expect(part.map(key) == all.dropFirst(skip).map(key), "skip \(skip)")
    }
    // Past the last sample the range needs: nothing; before the sync sample: from the sync sample.
    #expect(try await d.samples(for: range, fromDecodeOrdinal: sync + all.count).isEmpty)
    #expect(try await d.samples(for: range, fromDecodeOrdinal: -5).map(key) == all.map(key))
}

@Test func frameByFrameDecodeReadsEachSampleOnce() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let d = CountingDemuxer(try await AVDemuxer(url: try await TestClipWriter.write(spec)))
    let dec = try VTVideoDecoder(demuxer: d, media: UUID())
    var got: [Int?] = []
    for i in 0..<60 {
        let f = try await dec.decode(i...i)
        got += f.map { stamp($0.pixelBuffer) }
    }
    #expect(got == (0..<60).map { Optional($0) })
    #expect(dec.stats.reseeks == 1)
    // Each sample once, plus at most a B-frame look-ahead per request that ends before it.
    #expect(d.read.withLock { $0 } <= 60 + 2, "read \(d.read.withLock { $0 }) samples for 60 frames")
}
