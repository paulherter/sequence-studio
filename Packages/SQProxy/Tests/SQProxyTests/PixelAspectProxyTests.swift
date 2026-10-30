@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQProxy

// F7.3: a proxy of a file that carries a pixel aspect tag. The engines draw a proxy at the original's size in the
// item's shape (RenderLoop `proxyDivisor` compares the proxy's stored width with the original's stored width), so the
// proxy must keep the original's stored pixel grid, divided by the kind's divisor: not the desqueezed size.
@Suite(.serialized) struct PixelAspectProxyTests {
    struct Shape { var stored: CMVideoDimensions; var natural: CGSize }

    func shape(_ url: URL) async throws -> Shape {
        let v = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let f = try #require(try await v.load(.formatDescriptions).first)
        return Shape(stored: CMVideoFormatDescriptionGetDimensions(f), natural: try await v.load(.naturalSize))
    }

    @Test(arguments: [ProxyKind.optimized, .proxyHalf])
    func taggedFileGetsAProxyOnTheSameStoredGrid(kind: ProxyKind) async throws {
        var spec = TestClipSpec(); spec.width = 512; spec.height = 288; spec.frameCount = 6
        spec.pixelAspect = (2, 1)
        let src = try await TestClipWriter.write(spec)
        defer { try? FileManager.default.removeItem(at: src) }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("p.mov")
        _ = try await ProxyTranscoder().transcode(source: src, kind: kind, destination: out, timeRange: nil) { _ in }
        let o = try await shape(src), p = try await shape(out)
        #expect(o.natural.width == 1024, "the test file carries its 2:1 tag: naturalSize is the desqueezed size")
        #expect(p.natural.width == CGFloat(p.stored.width), "the proxy is untagged")
        #expect(Int(p.stored.width) == Int(o.stored.width) / kind.scaleDivisor, "\(kind): stored \(p.stored.width), original \(o.stored.width)")
        #expect(Int(p.stored.height) == Int(o.stored.height) / kind.scaleDivisor)
    }
}
