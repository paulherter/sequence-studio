import AVFoundation
import Foundation
import SQCore
import Testing
@testable import SQExport

// Sequence pixel shape on export: the stored size plus pasp when non-square, nothing for square.
struct PixelShapeExportTests {
    private func format(_ par: PixelAspect) -> SequenceFormat {
        var f = SequenceFormat(width: 1440, height: 1080, frameDuration: Time(1, 30))
        f.pixelAspect = par
        return f
    }

    @Test func squareAddsNothing() throws {
        let s = ExportPreset.matchSource.settings(matching: format(.square))
        for codec in [VideoCodec.h264, .hevc, .prores422] {
            var t = s; t.video.codec = codec
            #expect(ExportWriter.videoOutputSettings(t)[AVVideoPixelAspectRatioKey] == nil)
        }
        let data = try JSONEncoder().encode(s)
        #expect(!String(decoding: data, as: UTF8.self).contains("pixelAspect"))
    }

    @Test func nonSquareWritesStoredSizeAndPasp() {
        let s = ExportPreset.matchSource.settings(matching: format(PixelAspect(4, 3)!))
        for codec in [VideoCodec.h264, .hevc, .prores422] {
            var t = s; t.video.codec = codec
            let out = ExportWriter.videoOutputSettings(t)
            let pa = out[AVVideoPixelAspectRatioKey] as? [String: Int]
            #expect(pa?[AVVideoPixelAspectRatioHorizontalSpacingKey] == 4 && pa?[AVVideoPixelAspectRatioVerticalSpacingKey] == 3)
            #expect(out[AVVideoWidthKey] as? Int == 1440 && out[AVVideoHeightKey] as? Int == 1080)
        }
    }

    @Test func settingsRoundTrip() throws {
        let s = ExportPreset.matchSource.settings(matching: format(PixelAspect(2, 1)!))
        let back = try JSONDecoder().decode(ExportSettings.self, from: try JSONEncoder().encode(s))
        #expect(back.video.pixelAspect == PixelAspect(2, 1)!)
    }
}

// The file itself carries the pixel aspect (pasp): read it back from the track's format description.
struct PixelShapeFileTests {
    private func pasp(_ codec: VideoCodec, par: PixelAspect) async throws -> (h: Int, v: Int)? {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(codec.isProRes ? "o.mov" : "o.mp4")
        var s = smallSettings(codec: codec, width: 144, height: 108)
        s.video.pixelAspect = par
        let src = TestPatternSource(width: 144, height: 108, frameCount: 2, frameDuration: Time(1, 30))
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let fd = try #require(try await track.load(.formatDescriptions).first)
        guard let d = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any],
              let h = d[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? Int,
              let v = d[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? Int else { return nil }
        return (h, v)
    }

    @Test(.serialized, arguments: [VideoCodec.h264, .hevc, .prores422])
    func nonSquareFileCarriesPasp(codec: VideoCodec) async throws {
        let r = try await pasp(codec, par: PixelAspect(4, 3)!)
        #expect(r?.h == 4 && r?.v == 3)
    }

    @Test(.serialized, arguments: [VideoCodec.h264, .hevc, .prores422])
    func squareFileCarriesNoPasp(codec: VideoCodec) async throws {
        let r = try await pasp(codec, par: .square)
        #expect(r == nil || (r?.h == 1 && r?.v == 1))
    }
}
