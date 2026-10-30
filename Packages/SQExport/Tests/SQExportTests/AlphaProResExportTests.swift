@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
@testable import SQExport

// W9.2: ProRes 4444 export with alpha. A transparent clip alone on the timeline renders over transparent, and the file
// carries straight color plus the coverage in alpha (tagged straight). Without the setting the export stays opaque.

@Suite(.serialized) struct AlphaProResExportTests {
    struct Probe { var alpha: [Double]; var luma: [Double]; var mode: String?; var containsAlpha: Bool }

    /// Exports the alpha test clip alone (ProRes 4444, `preservesAlpha`) and reads frame 0 back as y416.
    func export(preservesAlpha: Bool) async throws -> Probe {
        var spec = TestClipSpec(); spec.codec = .prores4444Alpha; spec.width = 64; spec.height = 32; spec.frameCount = 4
        let clipURL = try await TestClipWriter.write(spec); defer { try? FileManager.default.removeItem(at: clipURL) }
        let media = UUID()
        let provider = DecoderFrameProvider(resolver: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: clipURL)]))
        let fd = Time(1, 30)
        let clip = Clip(name: "fg", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 30)), start: .zero)
        let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 32, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [clip])])
        var s = ExportSettings.proRes422HQMaster
        s.video.codec = .prores4444; s.video.preservesAlpha = preservesAlpha
        s.video.width = 64; s.video.height = 32; s.video.frameDuration = fd
        s.audio.enabled = false
        let src = try TimelineFrameSource(timeline: tl, provider: provider, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 4, pixelFormat: s.sourcePixelFormat)
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mov")
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })

        let asset = AVURLAsset(url: url)
        let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let f = try #require(try await v.load(.formatDescriptions).first)
        let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] ?? [:]
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_4444AYpCbCr16])
        r.add(o); r.startReading()
        let pb = try #require(o.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let row = (CVPixelBufferGetBaseAddress(pb)! + 16 * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: UInt16.self)
        let xs = [12, 40, 58]
        return Probe(alpha: xs.map { Double(row[$0 * 4]) / 65535 },
                     luma: xs.map { (Double(row[$0 * 4 + 1]) - 4096) / (60160 - 4096) },
                     mode: ext[kCMFormatDescriptionExtension_AlphaChannelMode as String] as? String,
                     containsAlpha: (ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) == true)
    }

    /// Y' of the pattern color (straight, BT.709).
    var patternLuma: Double {
        let c = AlphaTestPattern.color
        return (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
    }

    @Test func proRes4444WithAlphaKeepsCoverageAndStraightColour() async throws {
        let p = try await export(preservesAlpha: true)
        #expect(p.containsAlpha)
        #expect(p.mode == (kCMFormatDescriptionAlphaChannelMode_StraightAlpha as String))
        #expect(p.alpha[0] > 0.99, "\(p.alpha)")
        #expect(abs(p.alpha[1] - 128.0 / 255) < 0.01, "\(p.alpha)")
        #expect(p.alpha[2] < 0.01, "\(p.alpha)")
        // Straight color: the half-covered column keeps the full pattern color (not darkened by alpha).
        #expect(abs(p.luma[0] - patternLuma) < 0.02, "\(p.luma)")
        #expect(abs(p.luma[1] - patternLuma) < 0.02, "\(p.luma)")
    }

    @Test func proRes4444WithoutTheSettingStaysOpaque() async throws {
        let p = try await export(preservesAlpha: false)
        for a in p.alpha { #expect(a > 0.99, "\(p.alpha)") }
        // Over black: the half column is darker than the pattern, the transparent one black.
        #expect(p.luma[1] < patternLuma - 0.1, "\(p.luma)")
        #expect(p.luma[2] < 0.01, "\(p.luma)")
    }

    @Test func alphaPixelFormatOnlyForProRes4444() {
        var s = ExportSettings.proRes422HQMaster
        s.video.preservesAlpha = true
        #expect(s.sourcePixelFormat == .yuv422v10)
        s.video.codec = .prores4444
        #expect(s.sourcePixelFormat == .ayuv4444Alpha)
        s.video.preservesAlpha = false
        #expect(s.sourcePixelFormat == .ayuv4444)
    }

    @Test func preservesAlphaRoundTripsAndDefaultsOff() throws {
        var v = VideoSettings(); v.preservesAlpha = true
        let back = try JSONDecoder().decode(VideoSettings.self, from: JSONEncoder().encode(v))
        #expect(back.preservesAlpha)
        let legacy = try JSONDecoder().decode(VideoSettings.self, from: Data(#"{"codec":"prores4444"}"#.utf8))
        #expect(!legacy.preservesAlpha)
    }
}
