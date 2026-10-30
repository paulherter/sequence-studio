import Foundation
import Testing
import SQCore
@testable import SQExport

@Suite struct InstagramPresetTests {
    @Test func feedAndStoriesSizes() {
        #expect(ExportPreset.feedPortrait.settings.video.width == 1080 && ExportPreset.feedPortrait.settings.video.height == 1350)
        #expect(ExportPreset.feedSquare.settings.video.width == 1080 && ExportPreset.feedSquare.settings.video.height == 1080)
        #expect(ExportPreset.stories.settings.video.width == 1080 && ExportPreset.stories.settings.video.height == 1920)
    }
    @Test func presetsAreValidH264Rec709ThirtyFps() {
        for p in [ExportPreset.feedPortrait, .feedSquare, .stories] {
            let s = p.settings
            #expect(s.validate().isEmpty, "\(p.id)")
            #expect(s.video.codec == .h264)
            #expect(s.color == .rec709)
            #expect(s.video.frameDuration == Time(1, 30))
        }
    }
    @Test func presetsKeepTheirSizeWhateverTheSequenceIs() {
        let f = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let s = ExportPreset.feedPortrait.settings(matching: f)
        #expect(s.video.width == 1080 && s.video.height == 1350)
    }
    @Test func listedWithUniqueIDsAndNames() {
        let all = ExportPreset.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
        for p in [ExportPreset.feedPortrait, .feedSquare, .stories] { #expect(all.contains(p)) }
        #expect(ExportPreset.stories.name.contains("Stories"))
    }
}

@Suite struct PlatformPresetTests {
    @Test func youtube1440Table() {
        let s = ExportPreset.youtube1440.settings
        #expect(s.video.width == 2560 && s.video.height == 1440)
        #expect(s.video.bitrate.averageBitsPerSecond == 16_000_000)
        #expect(s.validate().isEmpty)
    }
    @Test func youtubeDefaultFollowsFrameWidth() {
        let t = DeliveryTarget(platform: .youtube)
        func p(_ w: Int, _ h: Int) -> ExportPreset {
            .defaultPreset(format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 30)), target: t)
        }
        #expect(p(1920, 1080) == .youtube1080)
        #expect(p(2560, 1440) == .youtube1440)
        #expect(p(3840, 2160) == .youtube4K)
    }
    @Test func xAndFacebookArePresentValidAndUnique() {
        for p in [ExportPreset.xPost, .facebook] {
            #expect(ExportPreset.all.contains(p))
            #expect(p.settings.validate().isEmpty)
            #expect(p.settings.video.codec == .h264)
        }
        #expect(Set(ExportPreset.all.map(\.id)).count == ExportPreset.all.count)
        #expect(ExportPreset.xPost.limits?.maxDuration == Time(140, 1))
        #expect(ExportPreset.facebook.limits == nil)
    }
}
