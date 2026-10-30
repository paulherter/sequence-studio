import Foundation
import Testing
import SQCore
@testable import SQExport

@Suite struct DeliveryTargetPresetTests {
    @Test func platformMapsToPreset() {
        let vertical = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        #expect(ExportPreset.defaultPreset(format: vertical, target: DeliveryTarget(platform: .tiktok)) == .preset(.tiktok, .h264))
        #expect(ExportPreset.defaultPreset(format: vertical, target: DeliveryTarget(platform: .reels)) == .preset(.reels, .h264))
        #expect(ExportPreset.defaultPreset(format: vertical, target: DeliveryTarget(platform: .shorts)) == .preset(.shorts, .h264))
        let hd = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let uhd = SequenceFormat(width: 3840, height: 2160, frameDuration: Time(1, 30))
        #expect(ExportPreset.defaultPreset(format: hd, target: DeliveryTarget(platform: .youtube)) == .youtube1080)
        #expect(ExportPreset.defaultPreset(format: uhd, target: DeliveryTarget(platform: .youtube)) == .youtube4K)
        let feed = SequenceFormat(width: 1080, height: 1350, frameDuration: Time(1, 30))
        #expect(ExportPreset.defaultPreset(format: feed, target: DeliveryTarget(platform: .socialFeed)) == .feedPortrait)
        let square = SequenceFormat(width: 1080, height: 1080, frameDuration: Time(1, 30))
        #expect(ExportPreset.defaultPreset(format: square, target: DeliveryTarget(platform: .socialFeed)) == .feedSquare)
        #expect(ExportPreset.defaultPreset(format: hd, target: nil) == .matchSource)
    }

    @Test func tiktokSequenceGivesVerticalSettingsWithLoudness() {
        let f = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        let t = DeliveryTarget(platform: .tiktok)
        let s = ExportPreset.defaultPreset(format: f, target: t).settings(matching: f, target: t)
        #expect(s.video.width == 1080 && s.video.height == 1920)
        #expect(s.audio.loudness == LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1))
    }

    @Test func noTargetMeansNoLoudness() {
        let f = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        #expect(ExportPreset.youtube1080.settings(matching: f, target: nil).audio.loudness == nil)
    }
}
