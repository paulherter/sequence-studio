import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

@Test func probe4444() async throws {
    for codec in [TestClipSpec.Codec.prores4444, .prores4444Alpha] {
        var spec = TestClipSpec(); spec.codec = codec; spec.width = codec == .prores4444 ? FrameStamp.minimumWidth : 64; spec.height = 32; spec.frameCount = 2
        let url = try await TestClipWriter.write(spec)
        let dec = try VTVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID())
        let fr = try await dec.decode(0...1)
        let pb = fr[0].pixelBuffer
        try? "\(codec) fmt=\(CVPixelBufferGetPixelFormatType(pb)) alpha=\(String(describing: dec.alpha)) chroma=\(dec.info.chroma) bd=\(dec.info.bitDepth)".write(toFile: NSTemporaryDirectory() + "probe-\(codec).txt", atomically: true, encoding: .utf8)
        let asset = AVURLAsset(url: url)
        let t = try await asset.loadTracks(withMediaType: .video)[0]
        let fd = try await t.load(.formatDescriptions)[0]
        try? "\(CMFormatDescriptionGetExtensions(fd) ?? [:] as CFDictionary)".write(toFile: NSTemporaryDirectory() + "probe-ext-\(codec).txt", atomically: true, encoding: .utf8)
    }
}
