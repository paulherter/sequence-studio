import Testing
import Foundation
import SQCore
@testable import SQExport

@Suite struct SettingsTests {
    @Test func defaultsAreNineSixteenH264Rec709() {
        let s = ExportSettings()
        #expect(s.video.codec == .h264)
        #expect(s.video.width == 1080 && s.video.height == 1920)
        #expect(s.video.frameDuration == Time(1, 30))
        #expect(s.color == ColorSettings.rec709)
        #expect(s.color.primaries == .itu709 && s.color.transfer == .itu709 && s.color.matrix == .itu709)
        #expect(s.audio.codec == .aac && s.audio.sampleRate == 48_000 && s.audio.channels == 2)
        #expect(s.captions == .none)
        #expect(s.range == .entireSequence)
        #expect(s.validate().isEmpty)
    }

    @Test func codableRoundTrip() throws {
        var s = ExportSettings()
        s.video.codec = .hevc
        s.video.bitrate = .averageAndMax(average: 8_000_000, max: 12_000_000)
        s.audio.loudness = LoudnessNormalization(targetLUFS: -16, truePeakCeilingDB: -2)
        s.captions = .sidecarSRT
        s.range = .inOut(TimeRange(start: Time(1, 1), duration: Time(5, 1)))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ExportSettings.self, from: data)
        #expect(back == s)
    }

    @Test func validationFindsProblems() {
        var s = ExportSettings()
        s.video.width = 1081
        s.video.height = 0
        s.video.bitrate = .average(0)
        s.video.keyframeInterval = 0
        s.audio.channels = 0
        s.audio.sampleRate = 0
        let issues = s.validate()
        #expect(issues.contains(.oddDimensions))
        #expect(issues.contains(.nonPositiveBitrate))
        #expect(issues.contains(.invalidKeyframeInterval))
        #expect(issues.contains(.invalidAudio))
    }

    @Test func maxBelowAverageIsInvalid() {
        var s = ExportSettings()
        s.video.bitrate = .averageAndMax(average: 10_000_000, max: 5_000_000)
        #expect(s.validate().contains(.nonPositiveBitrate))
    }

    @Test func sizeEstimate() {
        var s = ExportSettings()
        s.video.bitrate = .average(8_000_000)
        s.audio.bitrate = 128_000
        // 10 s => (8_000_000 + 128_000) * 10 / 8 bytes
        #expect(s.estimatedFileSize(duration: Time(10, 1)) == 10_160_000)
        s.audio.enabled = false
        #expect(s.estimatedFileSize(duration: Time(10, 1)) == 10_000_000)
        #expect(s.estimatedFileSize(duration: Time(1, 3)) == 333_333)
    }

    /// EXP-04: each ProRes profile has its own rate (147 / 220 / 330 Mbit/s at 1080p29.97).
    @Test func proResProfilesHaveOwnRates() {
        var s = ExportSettings.proRes422HQMaster
        s.video.width = 1920; s.video.height = 1080; s.video.frameDuration = Time(1001, 30000)
        s.video.codec = .prores422
        #expect(s.estimatedVideoBitsPerSecond == 147_000_000)
        s.video.codec = .prores422HQ
        #expect(s.estimatedVideoBitsPerSecond == 220_000_000)
        s.video.codec = .prores4444
        #expect(s.estimatedVideoBitsPerSecond == 330_000_000)
    }

    /// EXP-04: ProRes ignores the (12 Mbit/s default) bitrate field; 1080p29.97 HQ is about 220 Mbit/s plus 24-bit PCM.
    @Test func proResSizeEstimate() {
        var s = ExportSettings.proRes422HQMaster
        s.video.frameDuration = Time(1001, 30000)
        // 10 s: 220 Mbit/s video = 275_000_000 bytes, PCM 48k*2*24 = 2_304_000 bit/s = 2_880_000 bytes
        #expect(s.estimatedFileSize(duration: Time(10, 1)) == 275_000_000 + 2_880_000)
        s.audio.enabled = false
        s.video.width = 3840; s.video.height = 2160
        #expect(s.estimatedFileSize(duration: Time(10, 1)) == 1_100_000_000)
    }
}
