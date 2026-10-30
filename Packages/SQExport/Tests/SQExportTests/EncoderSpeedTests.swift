import Testing
import AVFoundation
import Foundation
import SQCore
import VideoToolbox
@testable import SQExport

@Suite(.serialized) struct EncoderSpeedTests {
    private func comp(_ s: ExportSettings) -> [String: Any] {
        (ExportWriter.videoOutputSettings(s)[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
    }
    private let prioritize = kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
    private let realTime = kVTCompressionPropertyKey_RealTime as String
    private let refs = kVTCompressionPropertyKey_ReferenceBufferCount as String
    private let power = kVTCompressionPropertyKey_MaximizePowerEfficiency as String

    @Test func defaultIsQualityAndAddsNoKeys() {
        let s = ExportSettings()
        #expect(s.encoderSpeed == .quality && !ExportWriter.usesSpeedEncoder(s))
        let c = comp(s)
        #expect(c[prioritize] == nil && c[realTime] == nil && c[refs] == nil && c[power] == nil)
        #expect(c[AVVideoAllowFrameReorderingKey] as? Bool == true)
    }

    private func vt(_ s: ExportSettings) -> [String: Any] {
        let p = ExportWriter.speedEncoderProperties(s)
        return p.required.merging(p.hints) { a, _ in a }
    }
    private let reorderVT = kVTCompressionPropertyKey_AllowFrameReordering as String

    @Test(.serialized, arguments: [VideoCodec.h264, .hevc])
    func balancedPrioritisesSpeedKeepsBFrames(codec: VideoCodec) {
        var s = ExportSettings(); s.video.codec = codec; s.encoderSpeed = .balanced
        #expect(ExportWriter.usesSpeedEncoder(s))
        let c = vt(s)
        #expect(c[prioritize] as? Bool == true)
        #expect(c[realTime] as? Bool == false)
        #expect(c[power] as? Bool == false)
        #expect(c[refs] == nil)
        #expect(c[reorderVT] as? Bool == true)
        #expect(c[kVTCompressionPropertyKey_AverageBitRate as String] as? Int == s.video.bitrate.averageBitsPerSecond)
        #expect(c[kVTCompressionPropertyKey_MaxKeyFrameInterval as String] as? Int == s.video.keyframeInterval)
        #expect(c[kVTCompressionPropertyKey_ColorPrimaries as String] as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        // Rate, keyframes, reordering and color may not be refused; the speed keys are hints.
        let req = ExportWriter.speedEncoderProperties(s).required
        #expect(req[prioritize] == nil && req[reorderVT] != nil)
    }

    @Test(.serialized, arguments: [VideoCodec.h264, .hevc])
    func fastDropsBFramesAndLimitsReferences(codec: VideoCodec) {
        var s = ExportSettings(); s.video.codec = codec; s.encoderSpeed = .fast
        let c = vt(s)
        #expect(c[prioritize] as? Bool == true)
        #expect(c[realTime] as? Bool == false)
        #expect(c[refs] as? Int == 1)
        #expect(c[reorderVT] as? Bool == false)
    }

    @Test func profileAndRateLimitsCarryOver() {
        var s = ExportSettings(); s.video.codec = .hevc; s.video.profile = .main10; s.encoderSpeed = .balanced
        s.video.bitrate = .averageAndMax(average: 10_000_000, max: 16_000_000)
        let c = vt(s)
        #expect(c[kVTCompressionPropertyKey_ProfileLevel as String] as? String == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        // Best effort (the software HEVC encoder refuses it): a hint, not a required property.
        #expect(ExportWriter.speedEncoderProperties(s).required[kVTCompressionPropertyKey_DataRateLimits as String] == nil)
        #expect((ExportWriter.speedEncoderProperties(s).hints[kVTCompressionPropertyKey_DataRateLimits as String] as? [Int]) == [2_000_000, 1])
        s.video.codec = .h264; s.video.profile = .baseline
        #expect(vt(s)[reorderVT] as? Bool == false)
        #expect(ExportWriter.speedEncoderSpecification(s) == nil)
        s.video.hardwareEncoding = false
        #expect(ExportWriter.speedEncoderSpecification(s)?[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool == false)
    }

    @Test func proResIgnoresSpeed() {
        var s = ExportSettings.proRes422HQMaster
        s.encoderSpeed = .fast
        #expect(!ExportWriter.usesSpeedEncoder(s))
        #expect(ExportWriter.videoOutputSettings(s)[AVVideoCompressionPropertiesKey] == nil)
    }

    @Test func codingOmitsQualityAndRoundTrips() throws {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let plain = try enc.encode(ExportSettings())
        #expect(!String(decoding: plain, as: UTF8.self).contains("speed"))
        var s = ExportSettings(); s.encoderSpeed = .fast
        #expect(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s)).encoderSpeed == .fast)
        s.encoderSpeed = .quality
        #expect(try enc.encode(s) == plain)
    }

    @Test func suggestionOnlyOnSmallMacs() {
        let gib: UInt64 = 1 << 30
        #expect(EncoderSpeed.suggested(physicalMemory: 8 * gib) == .balanced)
        #expect(EncoderSpeed.suggested(physicalMemory: 4 * gib) == .balanced)
        #expect(EncoderSpeed.suggested(physicalMemory: 16 * gib) == nil)
        #expect(EncoderSpeed.allCases.map(\.displayName) == ["Quality", "Balanced", "Fast"])
    }

    /// AVAssetWriter rejects unknown compression keys at init: every speed must actually encode.
    @Test(.serialized, arguments: [VideoCodec.h264, .hevc])
    func everySpeedEncodes(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for speed in EncoderSpeed.allCases {
            var s = smallSettings(codec: codec, width: 128, height: 128)
            s.encoderSpeed = speed
            let url = dir.appendingPathComponent("\(speed).mp4")
            let src = TestPatternSource(width: 128, height: 128, frameCount: 20, frameDuration: Time(1, 30))
            try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
            let e = try await readEncoded(url)
            #expect(e.times.count == 20, "\(codec) \(speed)")
            if speed == .fast { #expect(!e.hasReordering) }
            func ext(_ k: CFString) -> String? { CMFormatDescriptionGetExtension(e.format, extensionKey: k) as? String }
            #expect(ext(kCMFormatDescriptionExtension_ColorPrimaries) == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
            #expect(ext(kCMFormatDescriptionExtension_YCbCrMatrix) == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
            let fills = try await decodedCounterFills(url)
            #expect(fills.count == 20 && fills == fills.sorted(), "\(codec) \(speed): frames in order")
        }
    }

    /// Balanced with audio and two parallel segments: the session path feeds audio and the segment join.
    @Test func balancedWithAudioAndSegments() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = smallSettings(codec: .h264, width: 128, height: 128)
        s.encoderSpeed = .balanced; s.video.keyframeInterval = 30
        s.audio.enabled = true; s.video.hardwareEncoding = true
        let url = dir.appendingPathComponent("bal.mp4")
        let src = SegmentablePattern(width: 128, height: 128, frameCount: 120)
        let audio = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(4, 1), frequency: 1000, amplitude: 0.1)
        try await ExportWriter.export(video: src, audio: audio, settings: s, to: url, segments: 2, progress: { _ in })
        let e = try await readEncoded(url)
        #expect(e.times.count == 120)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(e.duration - 4) < 0.05)
    }
}
