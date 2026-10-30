import Testing
import AVFoundation
import CoreMedia
import Foundation
import SQCore
import VideoToolbox
@testable import SQExport

@Suite(.serialized) struct EncoderHardwareMultiPassTests {
    private func settings(_ codec: VideoCodec = .h264, w: Int = 640, h: Int = 360) -> ExportSettings {
        var s = ExportSettings()
        s.video.codec = codec; s.video.width = w; s.video.height = h
        s.video.frameDuration = Time(1, 30); s.video.keyframeInterval = 15
        s.video.bitrate = .average(2_000_000)
        s.audio.enabled = false
        return s
    }

    @Test func verdictTable() {
        typealias W = ExportWriter
        #expect(W.hardwareVerdict(requested: false, usingHardware: false, hardwareEncoderExists: true) == .notRequested)
        #expect(W.hardwareVerdict(requested: true, usingHardware: true, hardwareEncoderExists: true) == .hardware)
        #expect(W.hardwareVerdict(requested: true, usingHardware: false, hardwareEncoderExists: true) == .softwareUnexpected)
        #expect(W.hardwareVerdict(requested: true, usingHardware: false, hardwareEncoderExists: false) == .softwareAllowed)
    }

    @Test func silentSoftwareFallbackThrowsLoudly() {
        let s = settings()
        ExportWriter.$hardwareReadbackOverride.withValue((usingHardware: false, encoderExists: true)) {
            #expect(throws: ExportError.self) { _ = try SpeedEncoderSession(settings: s) }
        }
        // The Quality path (AVAssetWriter) is checked through the same session.
        ExportWriter.$hardwareReadbackOverride.withValue((usingHardware: false, encoderExists: true)) {
            #expect(throws: ExportError.self) { try ExportWriter.verifyHardwareForWriter(s) }
        }
    }

    @Test func softwareStaysAllowedWithoutAHardwareEncoderOrOnPurpose() throws {
        var s = settings()
        try ExportWriter.$hardwareReadbackOverride.withValue((usingHardware: false, encoderExists: false)) {
            let h = try SpeedEncoderSession(settings: s).hardware
            #expect(h == .softwareAllowed)
        }
        s.video.hardwareEncoding = false
        try ExportWriter.$hardwareReadbackOverride.withValue((usingHardware: false, encoderExists: true)) {
            let h = try SpeedEncoderSession(settings: s).hardware
            #expect(h == .notRequested)
        }
    }

    @Test(arguments: [VideoCodec.h264, .hevc])
    func realSessionReportsItsEncoder(codec: VideoCodec) throws {
        // Either hardware, or software on a Mac without a hardware encoder; never the unexpected fallback (that throws).
        let session = try SpeedEncoderSession(settings: settings(codec))
        #expect(session.hardware == .hardware || session.hardware == .softwareAllowed)
    }

    @Test func entropyModeAndSpeedHints() {
        func hints(_ s: ExportSettings) -> [String: Any] { ExportWriter.speedEncoderProperties(s).hints }
        let cabac = kVTCompressionPropertyKey_H264EntropyMode as String
        let prioritize = kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
        var s = settings(); s.video.profile = .high; s.encoderSpeed = .fast
        #expect(hints(s)[cabac] as? String == kVTH264EntropyMode_CABAC as String)
        #expect(hints(s)[prioritize] as? Bool == true)
        s.video.profile = .baseline
        #expect(hints(s)[cabac] == nil)
        var hevc = settings(.hevc); hevc.encoderSpeed = .balanced
        #expect(hevc.video.codec == .hevc && hints(hevc)[cabac] == nil)
        // Best-quality preset: the speed hint is set to false, whatever the Mac's speed preference is.
        var best = ExportPreset.bestAtSize.settings; best.encoderSpeed = .fast
        #expect(best.usesMultiPass && ExportWriter.usesSpeedEncoder(best))
        #expect(hints(best)[prioritize] as? Bool == false)
        #expect(ExportWriter.speedEncoderProperties(best).required[kVTCompressionPropertyKey_AllowFrameReordering as String] as? Bool == false)
    }

    @Test func plainQualityStaysUnchanged() {
        let s = settings()
        #expect(!s.usesMultiPass && !ExportWriter.usesSpeedEncoder(s))
        let comp = ExportWriter.videoOutputSettings(s)[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        #expect(comp[kVTCompressionPropertyKey_H264EntropyMode as String] == nil)
        // Old stored settings (no multi-pass key) decode as one pass.
        let data = try? JSONEncoder().encode(s)
        #expect(String(decoding: data ?? Data(), as: UTF8.self).contains("multiPass") == false)
    }

    @Test func multiPassPresetIsOnePieceAndOffForConstantBitrate() throws {
        var p = ExportPreset.bestAtSize.settings
        #expect(p.usesMultiPass && p.video.codec == .h264 && !p.video.hardwareEncoding)
        p.video.bitrateKind = .cbr
        #expect(!p.usesMultiPass)
        var hw = ExportPreset.bestAtSize.settings; hw.video.hardwareEncoding = true
        #expect(!hw.usesMultiPass)   // the hardware encoders malfunction in multi-pass
        let src = try CalmThenNoisySource(width: 640, height: 360, frameCount: 600, frameDuration: Time(1, 30))
        #expect(ExportWriter.segmentCount(requested: 2, source: src, settings: ExportPreset.bestAtSize.settings) == 1)
    }

    @Test(arguments: [(15, 640, 360), (15, 1920, 1080), (60, 1920, 1080)])
    func multiPassExportWritesEveryFrameOnce(frames: Int, w: Int, h: Int) async throws {
        var s = settings(.h264, w: w, h: h)
        s.video.hardwareEncoding = false; s.video.allowsFrameReordering = false
        s.video.profile = .high
        s.multiPass = true
        let src = try CalmThenNoisySource(width: w, height: h, frameCount: frames, frameDuration: Time(1, 30))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - Double(frames) / 30) < 0.05)
        let nominal = try await track.load(.nominalFrameRate)
        #expect(nominal > 25 && nominal < 35)
    }
}
