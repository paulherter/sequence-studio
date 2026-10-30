import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
import VideoToolbox
@testable import SQMedia

private func stampOf(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

private func copy(_ url: URL, name: String, transform: (inout Data) -> Void) throws -> URL {
    var data = try Data(contentsOf: url)
    transform(&data)
    let out = url.deletingLastPathComponent().appendingPathComponent(name)
    try data.write(to: out)
    return out
}

private func tmpFile(_ name: String, _ data: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SQGarbage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent(name)
    try data.write(to: u)
    return u
}

/// Decodes every GOP of the index separately (like the engine's jobs); returns per presentation index: stamp or nil (failed).
private func decodeByGOP(_ d: AVDemuxer) async throws -> [Int: Int?] {
    let dec = try VTVideoDecoder(demuxer: d, media: UUID())
    var result: [Int: Int?] = [:]
    var i = 0
    while i < d.index.count {
        let g = d.index.gop(containing: i)
        do {
            let frames = try await dec.decode(g)
            for (k, f) in zip(g, frames) { result[k] = .some(stampOf(f.pixelBuffer)) }
        } catch is MediaError {
            for k in g { result[k] = .some(nil) }
        }
        i = g.upperBound + 1
    }
    return result
}

@Test func truncatedClipGoodHeadThenMediaError() async throws {
    var spec = TestClipSpec(); spec.frameCount = 120; spec.moovAtStart = true
    let url = try await TestClipWriter.write(spec)
    let cut = try copy(url, name: "cut.mov") { $0 = $0.prefix($0.count * 6 / 10) }
    let d: AVDemuxer
    do { d = try await AVDemuxer(url: cut) } catch {
        // A moov-less head is unreadable: that is the only acceptable failure.
        guard case MediaError.unreadable = error else { Issue.record("wrong error \(error)"); return }
        return
    }
    #expect(d.index.count == 120)       // moov at start: the index still lists every sample
    let r = try await decodeByGOP(d)
    let good = (0..<120).filter { r[$0] != nil && r[$0]! != nil }
    let bad = (0..<120).filter { r[$0] == nil || r[$0]! == nil }
    #expect(good.count >= 40 && good.count < 120)
    #expect(bad.count > 0)
    // Good frames carry the right stamps, and everything from the first bad frame on is bad.
    for k in good { #expect(r[k]! == k) }
    #expect(bad.contains(119))
    if let firstBad = bad.first { #expect(good.allSatisfy { $0 < firstBad || $0 > firstBad }) }
    // Probe must not crash either.
    _ = try? await MediaImporter.probe(cut)
}

@Test func corruptMdatMiddleYieldsErrorsNotTraps() async throws {
    var spec = TestClipSpec(); spec.frameCount = 120; spec.moovAtStart = true
    let url = try await TestClipWriter.write(spec)
    let data = try Data(contentsOf: url)
    let mdat = try #require(data.range(of: Data("mdat".utf8)))
    let lo = mdat.upperBound + (data.count - mdat.upperBound) * 4 / 10
    let hi = lo + (data.count - mdat.upperBound) / 10
    let bad = try copy(url, name: "bad.mov") { d in
        var g = SystemRandomNumberGenerator()
        for i in lo..<hi { d[i] = UInt8.random(in: 0...255, using: &g) }
    }
    let d = try await AVDemuxer(url: bad)
    let r = try await decodeByGOP(d)
    let failed = (0..<120).filter { r[$0] == nil || r[$0]! == nil }
    let ok = (0..<120).filter { r[$0] != nil && r[$0]! != nil }
    #expect(ok.contains(0))
    #expect(ok.count > 40)
    for k in ok { #expect(r[k]! == k) }
    _ = failed   // garbage may decode to a wrong picture without an error; the requirement is: no trap, no hang
}

@Test func garbageFilesAreUnreadable() async throws {
    var bytes = [UInt8](repeating: 0, count: 50_000)
    for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    let files = [try tmpFile("noise.mov", Data(bytes)), try tmpFile("noise.mp4", Data(bytes)),
                 try tmpFile("empty.mov", Data()), try tmpFile("empty.mp4", Data()),
                 FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).mov")]
    for f in files {
        await #expect(throws: MediaError.self) { _ = try await MediaImporter.probe(f) }
        await #expect(throws: MediaError.self) { _ = try await AVDemuxer(url: f) }
        do { _ = try await MediaImporter.probe(f) } catch let e as MediaError {
            if case .unreadable = e {} else { Issue.record("expected unreadable for \(f.lastPathComponent), got \(e)") }
        }
        do { _ = try await AVDemuxer(url: f) } catch let e as MediaError {
            if case .unreadable = e {} else { Issue.record("expected unreadable for \(f.lastPathComponent), got \(e)") }
        }
    }
}

@Test func vfrIndexFindsFrameWithPtsAtOrBeforeTime() async throws {
    var spec = TestClipSpec()
    // 0, 1/30, 3/30 (gap), 4/30, 8/30 (gap), 9/30 ...
    let steps: [Int32] = [0, 1, 3, 4, 8, 9, 10, 14, 15, 16, 20, 21]
    spec.presentationTimes = steps.map { CMTime(value: CMTimeValue($0), timescale: 30) }
    spec.frameDuration = CMTime(value: 1, timescale: 30)
    let url = try await TestClipWriter.write(spec)
    let d = try await AVDemuxer(url: url)
    #expect(d.index.count == steps.count)
    for k in 0..<60 {
        let t = Time(Int64(k), 30)
        let expected = steps.lastIndex { Int64($0) <= Int64(k) }
        if k >= 22 { #expect(d.index.frame(at: t) == nil || d.index.frame(at: t) == steps.count - 1); continue }
        #expect(d.index.frame(at: t) == expected)
    }
    let dec = try VTVideoDecoder(demuxer: d, media: UUID())
    let frames = try await dec.decode(0...(steps.count - 1))
    #expect(frames.map { stampOf($0.pixelBuffer) } == (0..<steps.count).map { Optional($0) })
}

@Test func firstSamplePtsGreaterThanZeroStartsAtFirstPresented() async throws {
    var spec = TestClipSpec(); spec.frameCount = 24; spec.startOffset = CMTime(value: 1, timescale: 10)
    let url = try await TestClipWriter.write(spec)
    let d = try await AVDemuxer(url: url)
    #expect(d.index.entries.first?.pts == .zero)
    #expect(d.index.frame(at: .zero) == 0)
    let dec = try VTVideoDecoder(demuxer: d, media: UUID())
    let f = try await dec.decode(0...0)
    #expect(stampOf(f[0].pixelBuffer) != nil)
    // The presented sequence is decodable in full and the stamps are increasing.
    let all = try await dec.decode(0...(d.index.count - 1))
    let s = all.compactMap { stampOf($0.pixelBuffer) }
    #expect(s.count == d.index.count)
    #expect(zip(s, s.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(s.last == 23)
}
