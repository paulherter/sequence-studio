import Foundation
import Testing
import SQCore
@testable import SQExport

@Suite struct DeliveryAdviceTests {
    @Test func shortsAndReelsLengthWarn() {
        let shorts = ExportPreset.preset(.shorts, .h264), reels = ExportPreset.preset(.reels, .h264)
        #expect(DeliveryAdvice.lengthWarning(preset: shorts, duration: Time(179, 1), presetName: "Shorts") == nil)
        #expect(DeliveryAdvice.lengthWarning(preset: shorts, duration: Time(200, 1), presetName: "Shorts") != nil)
        #expect(DeliveryAdvice.lengthWarning(preset: reels, duration: Time(95, 1), presetName: "Reels") != nil)
        #expect(DeliveryAdvice.lengthWarning(preset: .preset(.tiktok, .h264), duration: Time(600, 1), presetName: "T") == nil)
    }

    @Test func youtubeRateAndAudioNotes() {
        var s = ExportPreset.youtube1080.settings
        s.video.frameDuration = Time(1, 30)
        s.audio.sampleRate = 48_000
        #expect(DeliveryAdvice.settingsNotes(s, preset: .youtube1080).isEmpty)
        s.video.frameDuration = Time(1001, 24000)
        #expect(DeliveryAdvice.settingsNotes(s, preset: .youtube1080).isEmpty)
        s.video.frameDuration = Time(1, 120)
        #expect(DeliveryAdvice.settingsNotes(s, preset: .youtube1080).count == 1)
        s.video.frameDuration = Time(1, 30)
        s.audio.sampleRate = 44_100
        #expect(DeliveryAdvice.settingsNotes(s, preset: .youtube1080).count == 1)
    }

    @Test func oddSizeAndEncoder() {
        #expect(DeliveryAdvice.oddSizeNote(width: 1921, height: 1080)?.contains("1920x1080") == true)
        #expect(DeliveryAdvice.oddSizeNote(width: 1920, height: 1080) == nil)
        var s = ExportPreset.matchSource.settings
        #expect(DeliveryAdvice.encoderNote(s)?.hasPrefix("Hardware") == true)
        s.video.hardwareEncoding = false
        #expect(DeliveryAdvice.encoderNote(s)?.hasPrefix("Software") == true)
    }
}
