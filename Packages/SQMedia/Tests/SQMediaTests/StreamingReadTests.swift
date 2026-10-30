import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Synchronization
import Testing
@testable import SQMedia

// Seek: exact frame sooner (PLAYBACK-PERF): the decoder pulls samples one at a time from a streaming reader and submits
// each at once. The pixels must equal the path that reads the whole run first.

/// A demuxer without a streaming reader (the protocol default): the decoder reads the whole run first.
private final class WholeRunDemuxer: Demuxing, @unchecked Sendable {
    let inner: AVDemuxer
    init(_ d: AVDemuxer) { inner = d }
    var index: SampleIndex { inner.index }
    var formatDescription: CMFormatDescription { inner.formatDescription }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] { try await inner.samples(for: range) }
    func samples(for range: ClosedRange<Int>, fromDecodeOrdinal o: Int) async throws -> [CMSampleBuffer] {
        try await inner.samples(for: range, fromDecodeOrdinal: o)
    }
}

private func key(_ sb: CMSampleBuffer) -> [Int64] {
    let p = CMSampleBufferGetPresentationTimeStamp(sb), d = CMSampleBufferGetDecodeTimeStamp(sb)
    return [p.value, Int64(p.timescale), d.value, Int64(d.timescale), Int64(CMSampleBufferGetTotalSampleSize(sb))]
}

private func hash(_ pb: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    var h = Hasher()
    let planar = CVPixelBufferGetPlaneCount(pb) > 0
    for plane in 0..<max(1, CVPixelBufferGetPlaneCount(pb)) {
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, plane) : CVPixelBufferGetBaseAddress(pb) else { continue }
        let rows = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, plane) : CVPixelBufferGetBytesPerRow(pb)
        h.combine(bytes: UnsafeRawBufferPointer(start: base, count: rows * stride))
    }
    return h.finalize()
}

@Test func sampleReaderYieldsTheSamplesOfTheArrayRead() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let d = try await AVDemuxer(url: try await TestClipWriter.write(spec))
    let gop = d.index.gop(containing: 0)
    let range = gop.lowerBound...(gop.lowerBound + gop.count - 2)
    let sync = d.index.syncDecodeOrdinal(for: range.lowerBound)
    let all = try await d.samples(for: range)
    for skip in [0, 2, all.count - 1] {
        let r = try #require(try d.sampleReader(for: range, fromDecodeOrdinal: sync + skip))
        #expect(r.count == all.count - skip)
        var got: [[Int64]] = []
        while r.count > 0 { got.append(key(try r.next())) }
        #expect(got == all.dropFirst(skip).map(key), "skip \(skip)")
        #expect(throws: (any Error).self) { try r.next() }
    }
}

@Test func streamingDecodeEqualsWholeRunDecodePixelForPixel() async throws {
    var spec = TestClipSpec(); spec.frameCount = 90
    let url = try await TestClipWriter.write(spec)
    let streaming = try VTVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID())
    let whole = try VTVideoDecoder(demuxer: WholeRunDemuxer(try await AVDemuxer(url: url)), media: UUID())
    // Far jumps with a target deep in the GOP (the seek path: frames before it are not needed), then more jumps.
    for (range, needed) in [(30...59, 55), (0...29, 29), (60...89, 60), (10...29, 10)] {
        func run(_ d: VTVideoDecoder) async throws -> [Int: Int] {
            let out = Mutex<[Int: Int]>([:])
            let rest = try await d.decode(range, neededFrom: needed) { f in out.withLock { $0[Int(f.pts.value)] = hash(f.pixelBuffer) } }
            for f in rest { out.withLock { $0[Int(f.pts.value)] = hash(f.pixelBuffer) } }
            return out.withLock { $0 }
        }
        let a = try await run(streaming), b = try await run(whole)
        #expect(!a.isEmpty)
        #expect(a == b, "range \(range) needed \(needed)")
    }
}
