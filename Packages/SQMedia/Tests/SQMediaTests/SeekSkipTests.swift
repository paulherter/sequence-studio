import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Synchronization
import Testing
import VideoToolbox
@testable import SQMedia

// Seek: non-reference H.264 frames before the target are not decoded (PLAYBACK-PERF, seek-to-exact-frame).

private func readStamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

/// AVCC sample of NAL units: each tuple is the NAL header byte and payload length.
private func avcc(_ nals: [(UInt8, Int)], lengthSize: Int = 4) -> [UInt8] {
    var out: [UInt8] = []
    for (h, n) in nals {
        let len = n + 1
        for k in stride(from: lengthSize - 1, through: 0, by: -1) { out.append(UInt8((len >> (8 * k)) & 0xFF)) }
        out.append(h)
        out += [UInt8](repeating: 0xAB, count: n)
    }
    return out
}

@Test func h264DisposableNeedsEverySliceUnreferenced() {
    func check(_ b: [UInt8], _ ls: Int = 4) -> Bool { H264NAL.isDisposable(b, lengthSize: ls) }
    // nal_ref_idc 0 slice (type 1): disposable; SEI (6) / AUD (9) around it do not matter.
    #expect(check(avcc([(0x09, 1), (0x06, 5), (0x01, 40)])))
    // Reference slice (nal_ref_idc 2, type 1) and IDR (0x65).
    #expect(!check(avcc([(0x41, 40)])))
    #expect(!check(avcc([(0x65, 40)])))
    // Two slices, one referenced: not disposable.
    #expect(!check(avcc([(0x01, 20), (0x21, 20)])))
    // No slice at all, empty, truncated length: never disposable (decode it).
    #expect(!check(avcc([(0x06, 5)])))
    #expect(!check([]))
    #expect(!check([0, 0, 0, 200, 0x01]))
    // 2-byte lengths.
    #expect(check(avcc([(0x01, 300)], lengthSize: 2), 2))
}

@Test func seekSkipsUnreferencedFramesBeforeTheTarget() async throws {
    var spec = TestClipSpec(); spec.frameCount = 60
    let url = try await TestClipWriter.write(spec)
    let d = try await AVDemuxer(url: url)
    let dec = try VTVideoDecoder(demuxer: d, media: UUID())
    let gop = d.index.gop(containing: 0)
    let target = gop.lowerBound + gop.count / 2
    let got = Mutex<[Int?]>([])
    let rest = try await dec.decode(gop, neededFrom: target, deliver: { f in
        let s = readStamp(f.pixelBuffer); got.withLock { $0.append(s) }
    })
    let all = (got.withLock { $0 } + rest.map { readStamp($0.pixelBuffer) }).compactMap { $0 }.sorted()
    // Every frame from the target on is exact; frames before it may be missing, never wrong.
    #expect(all.filter { $0 >= target } == Array(target...gop.upperBound))
    #expect(Set(all).isSubset(of: Set(gop)))
    #expect(dec.stats.samplesSkipped > 0, "the test clip's B frames are not referenced")
    // The next GOP continues without a reseek, exact.
    let next = d.index.gop(containing: gop.upperBound + 1)
    let n = try await dec.decode(next)
    #expect(n.map { readStamp($0.pixelBuffer) } == next.map { Optional($0) })
    #expect(dec.stats.reseeks == 1)
    // Without a target nothing is skipped.
    let dec2 = try VTVideoDecoder(demuxer: d, media: UUID())
    let full = try await dec2.decode(gop, neededFrom: nil, deliver: { _ in })
    _ = full
    #expect(dec2.stats.samplesSkipped == 0)
}
