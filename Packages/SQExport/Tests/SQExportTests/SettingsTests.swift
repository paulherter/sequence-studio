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
}
