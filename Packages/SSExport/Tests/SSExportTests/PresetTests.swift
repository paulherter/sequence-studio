import Testing
import SSCore
@testable import SSExport

@Suite struct PresetTests {
    @Test func allPresetsAreValidNineSixteenRec709() {
        #expect(ExportPreset.social.count == 6)
        for p in ExportPreset.social {
            let s = p.settings
            #expect(s.validate().isEmpty, "\(p.id)")
            #expect(s.video.width == 1080 && s.video.height == 1920)
            #expect(s.video.frameDuration == Time(1, 30))
            #expect(s.color == .rec709)
        }
    }
    @Test func platformsAndCodecs() {
        for platform in SocialPlatform.allCases {
            #expect(ExportPreset.preset(platform, .h264).settings.video.codec == .h264)
            #expect(ExportPreset.preset(platform, .hevc).settings.video.codec == .hevc)
        }
        let ids = Set(ExportPreset.social.map(\.id))
        #expect(ids.count == 6)
    }
    @Test func hevcUsesLowerBitrateThanH264() {
        for platform in SocialPlatform.allCases {
            let a = ExportPreset.preset(platform, .h264).settings.video.bitrate.averageBitsPerSecond
            let b = ExportPreset.preset(platform, .hevc).settings.video.bitrate.averageBitsPerSecond
            #expect(b < a)
        }
    }
    @Test func defaultIsTikTokH264() {
        #expect(ExportPreset.default.platform == .tiktok)
        #expect(ExportPreset.default.settings.video.codec == .h264)
        #expect(ExportPreset.default.settings == ExportSettings.socialDefault)
    }
}
