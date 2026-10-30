import Testing
import AVFoundation
import VideoToolbox
import Foundation
import SQCore
@testable import SQExport

struct BitrateModeTests {
    private func comp(_ s: ExportSettings) -> [String: Any] {
        (ExportWriter.videoOutputSettings(s)[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
    }
    private func vt(_ s: ExportSettings) -> [String: Any] { ExportWriter.speedEncoderProperties(s).required }
    private let limits = kVTCompressionPropertyKey_DataRateLimits as String
    private let average = kVTCompressionPropertyKey_AverageBitRate as String

    @Test func oldBitrateModesAreVBRAndKeepTheirMeaning() {
        var s = ExportSettings()
        s.video.bitrate = .average(8_000_000)
        #expect(s.video.bitrateKind == .vbr && !ExportWriter.usesSpeedEncoder(s))
        #expect(comp(s)[AVVideoAverageBitRateKey] as? Int == 8_000_000)
        #expect(comp(s)[limits] == nil)
        s.video.bitrate = .averageAndMax(average: 8_000_000, max: 12_000_000)
        #expect(s.video.bitrateKind == .vbr)
        #expect(comp(s)[limits] != nil)
    }

    @Test func twoModesAndNoneForMasteringCodecs() {
        #expect(BitrateKind.allCases.map(\.title) == ["VBR", "CBR"])
        #expect(BitrateKind.available(for: .h264) == [.vbr, .cbr] && BitrateKind.available(for: .hevc) == [.vbr, .cbr])
        for c in [VideoCodec.prores422, .prores422HQ, .prores4444] { #expect(BitrateKind.available(for: c).isEmpty) }
        #expect(BitrateKind.vbr.showsMaximum && !BitrateKind.cbr.showsMaximum)
    }

    /// CBR encodes through the own session at every speed, without the VBR rate keys; a stored Maximum is ignored.
    @Test(arguments: [VideoCodec.h264, .hevc])
    func constantBitrateUsesTheSessionAndIgnoresTheMaximum(codec: VideoCodec) {
        var s = ExportSettings(); s.video.codec = codec
        s.video.bitrate = .averageAndMax(average: 8_000_000, max: 12_000_000)
        s.video.bitrateKind = .cbr
        #expect(s.video.usesConstantBitrate && ExportWriter.usesSpeedEncoder(s))
        #expect(s.video.bitrate.maxBitsPerSecond == 12_000_000)
        #expect(vt(s)[average] == nil && vt(s)[limits] == nil)
        let hints = ExportWriter.speedEncoderProperties(s).hints
        #expect(hints[limits] == nil)
        // The session a user waits for, also at Quality. RealTime stays unset with ConstantBitRate: false costs the
        // hardware encoders 23-37 % there (the software fallback sets it in the session).
        #expect((hints[kVTCompressionPropertyKey_RealTime as String] == nil) != ExportWriter.constantBitrateSetsRealTimeOff)
        #expect(hints[kVTCompressionPropertyKey_MaximizePowerEfficiency as String] as? Bool == false)
        var balancedVBR = s; balancedVBR.video.bitrateKind = .vbr; balancedVBR.encoderSpeed = .balanced
        #expect(ExportWriter.speedEncoderProperties(balancedVBR).hints[kVTCompressionPropertyKey_RealTime as String] as? Bool == false)
        let f = ExportWriter.constantBitrateFallback(s)
        #expect(f.required[average] as? Int == 8_000_000 && (f.limit[limits] as? [Int]) == [1_000_000, 1])
        // Quality stays free of the speed hints.
        #expect(ExportWriter.speedEncoderProperties(s).hints[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] == nil)
        s.video.bitrateKind = .vbr
        #expect(!ExportWriter.usesSpeedEncoder(s) && (comp(s)[limits] as? [Int]) == [1_500_000, 1])
    }

    /// Two segments would be two encoder sessions with separate rate buffers.
    @Test func constantBitrateExportsInOnePiece() {
        let src = SegmentablePattern(width: 64, height: 64, frameCount: 900)
        var s = ExportSettings(); s.video.frameDuration = Time(1, 30)
        #expect(ExportWriter.segmentCount(requested: nil, source: src, settings: s) == 2)
        s.video.bitrateKind = .cbr
        #expect(ExportWriter.segmentCount(requested: nil, source: src, settings: s) == 1)
        #expect(ExportWriter.segmentCount(requested: 4, source: src, settings: s) == 1)
    }

    /// The Maximum is best effort in the session: the software HEVC encoder refuses it and still encodes.
    @Test(arguments: [VideoCodec.h264, .hevc])
    func maximumIsBestEffortOnTheSoftwareEncoders(codec: VideoCodec) throws {
        var s = ExportSettings(); s.video.codec = codec
        s.video.width = 320; s.video.height = 180
        s.video.bitrate = .averageAndMax(average: 1_000_000, max: 1_500_000)
        s.video.hardwareEncoding = false
        s.encoderSpeed = .balanced
        let p = ExportWriter.speedEncoderProperties(s)
        #expect(p.required[limits] == nil && (p.hints[limits] as? [Int]) == [187_500, 1])
        let session = try SpeedEncoderSession(settings: s)
        #expect(session.rateControl == .average)
        #expect(session.maximumRefused == (codec == .hevc))
    }

    /// RealTime as the real session reports it: CBR hardware unset, VBR Balanced / Fast false, the CBR fallback false.
    @Test(arguments: [VideoCodec.h264, .hevc])
    func realTimeReadBackFromTheSession(codec: VideoCodec) throws {
        func realTime(_ s: ExportSettings) throws -> Bool? {
            let session = try SpeedEncoderSession(settings: s)
            var out: CFTypeRef?
            let st = session.copyProperty(kVTCompressionPropertyKey_RealTime, into: &out)
            guard st == noErr, let out else { return nil }
            return (out as? Bool) ?? (CFGetTypeID(out) == CFBooleanGetTypeID() ? CFBooleanGetValue((out as! CFBoolean)) : nil)
        }
        var s = ExportSettings(); s.video.codec = codec
        s.video.width = 640; s.video.height = 360; s.video.bitrate = .average(2_000_000)
        for speed in [EncoderSpeed.balanced, .fast] {
            s.video.bitrateKind = .vbr; s.encoderSpeed = speed
            #expect(try realTime(s) == false, "VBR \(speed)")
        }
        s.video.bitrateKind = .cbr; s.video.hardwareEncoding = false
        #expect(try realTime(s) == false, "CBR fallback")
        #if arch(arm64)
        s.video.hardwareEncoding = true; s.encoderSpeed = .quality
        let hard = try SpeedEncoderSession(settings: s)
        if hard.rateControl == .constant, !ExportWriter.constantBitrateSetsRealTimeOff {
            #expect(try realTime(s) == nil, "CBR hardware leaves RealTime unset")
        }
        #endif
    }

    @Test func proResIgnoresTheMode() {
        var s = ExportSettings.proRes422HQMaster
        s.video.bitrateKind = .cbr
        #expect(!s.video.usesConstantBitrate && !ExportWriter.usesSpeedEncoder(s))
    }

    /// Additive, optional key: VBR encodes exactly as before, settings written before the key decode as VBR.
    @Test func codingOmitsVBRAndOldSettingsDecodeAsVBR() throws {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let plain = try enc.encode(ExportSettings())
        #expect(!String(decoding: plain, as: UTF8.self).contains("constantBitrate"))
        #expect(try JSONDecoder().decode(ExportSettings.self, from: plain).video.bitrateKind == .vbr)
        var s = ExportSettings(); s.video.bitrateKind = .cbr
        let back = try JSONDecoder().decode(ExportSettings.self, from: enc.encode(s))
        #expect(back.video.bitrateKind == .cbr && back == s)
        s.video.bitrateKind = .vbr
        #expect(try enc.encode(s) == plain)
        let old = Data(#"{"codec":"hevc","bitrate":{"averageAndMax":{"average":10000000,"max":15000000}}}"#.utf8)
        let v = try JSONDecoder().decode(VideoSettings.self, from: old)
        #expect(v.bitrateKind == .vbr && v.bitrate.maxBitsPerSecond == 15_000_000 && v.codec == .hevc)
    }
}

/// General presets carry no data rate limit (it cost hard clips 3-4 VMAF); platform presets keep theirs.
struct PresetRateLimitTests {
    @Test func generalPresetsHaveNoDataRateLimit() {
        let fmt = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        #expect(ExportPreset.matchSource.settings.video.bitrate.maxBitsPerSecond == nil)
        #expect(ExportPreset.matchSource.settings(matching: fmt).video.bitrate.maxBitsPerSecond == nil)
        #expect(ExportPreset.youtube1080.settings.video.bitrate.maxBitsPerSecond != nil)
    }
}
