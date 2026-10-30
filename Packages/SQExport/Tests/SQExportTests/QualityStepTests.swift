import Testing
import SQCore
@testable import SQExport

@Suite struct QualityStepTests {
    private func video(_ codec: VideoCodec) -> VideoSettings {
        var v = VideoSettings(); v.codec = codec; v.width = 1920; v.height = 1080; v.frameDuration = Time(1, 30); return v
    }

    @Test func standardMatchesDefaultBitrate() {
        var v = video(.h264)
        v.applyQuality(.standard)
        #expect(v.bitrate.averageBitsPerSecond == Int(1920.0 * 1080 * 30 * 0.18))
        #expect(v.qualityStep == .standard)
    }

    @Test func stepsOrderAndHevcIsSmaller() {
        var h = video(.h264), e = video(.hevc)
        h.applyQuality(.smaller); let hs = h.bitrate.averageBitsPerSecond
        h.applyQuality(.high); let hh = h.bitrate.averageBitsPerSecond
        e.applyQuality(.high)
        #expect(hs < hh)
        #expect(e.bitrate.averageBitsPerSecond < hh)
        #expect(h.qualityStep == .high)
    }

    @Test func customAndProResHaveNoStep() {
        var v = video(.h264)
        v.bitrate = .average(7_000_000)
        #expect(v.qualityStep == nil)
        var p = video(.prores422); p.applyQuality(.high)
        #expect(p.qualityStep == nil)
    }

    @Test func maximumKeepsRatio() {
        var v = video(.h264)
        v.bitrate = .averageAndMax(average: 10_000_000, max: 15_000_000)
        v.applyQuality(.high)
        #expect(v.bitrate.maxBitsPerSecond == v.bitrate.averageBitsPerSecond * 3 / 2)
    }
}
