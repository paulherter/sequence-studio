import Foundation
import Testing
import SQCore
@testable import SQExport

@Suite struct DeliveryCheckTests {
    private func ids(_ i: [DeliveryCheck.Issue]) -> [String] { i.map(\.id) }

    @Test func cleanExportHasNoIssues() {
        var s = ExportPreset.youtube1080.settings
        s.video.frameDuration = Time(1, 30); s.audio.sampleRate = 48_000
        #expect(DeliveryCheck.issues(settings: s, preset: .youtube1080, duration: Time(60, 1), source: .init()).isEmpty)
    }

    @Test func sourceTraitsRaiseVfrAndInterlaced() {
        var s = ExportPreset.youtube1080.settings
        s.video.frameDuration = Time(1, 30)
        let i = DeliveryCheck.issues(settings: s, preset: .youtube1080, duration: Time(60, 1),
                                     source: .init(hasVariableFrameRate: true, hasInterlaced: true))
        #expect(ids(i) == ["vfr", "interlaced"])
        #expect(i.allSatisfy { $0.severity == .warning && !$0.text.isEmpty })
    }

    @Test func captionsInPlatformZoneWarn() {
        var s = ExportPreset.youtube1080.settings
        s.video.frameDuration = Time(1, 30)
        func run(_ n: Int, _ p: DeliveryPlatform?) -> [DeliveryCheck.Issue] {
            DeliveryCheck.issues(settings: s, preset: .youtube1080, duration: Time(10, 1),
                                 source: .init(captionsInZone: n), platform: p)
        }
        let w = run(2, .tiktok)
        #expect(ids(w) == ["zone"] && w[0].severity == .warning && w[0].text.contains("2") && w[0].text.contains("TikTok"))
        #expect(run(0, .tiktok).isEmpty)
        #expect(run(2, .youtube).isEmpty && run(2, nil).isEmpty)
    }

    @Test func frameRateAndAudioRateIssues() {
        var s = ExportPreset.youtube1080.settings
        s.video.frameDuration = Time(1, 120); s.audio.sampleRate = 44_100
        #expect(ids(DeliveryCheck.issues(settings: s, preset: .youtube1080, duration: Time(10, 1), source: .init())) == ["fps", "audioRate"])
    }

    @Test func platformLengthWarnings() {
        let reels = ExportPreset.preset(.reels, .h264)
        let s = reels.settings
        #expect(ids(DeliveryCheck.issues(settings: s, preset: reels, duration: Time(120, 1), source: .init())).contains("length"))
        #expect(!ids(DeliveryCheck.issues(settings: s, preset: reels, duration: Time(60, 1), source: .init())).contains("length"))
        let x = ExportPreset.xPost
        #expect(ids(DeliveryCheck.issues(settings: x.settings, preset: x, duration: Time(130, 1), source: .init())).contains("length"))
        #expect(!ids(DeliveryCheck.issues(settings: x.settings, preset: x, duration: Time(60, 1), source: .init())).contains("length"))
    }

    @Test func encoderHint() {
        var s = ExportPreset.matchSource.settings
        s.video.hardwareEncoding = true
        s.video.width = 1920; s.video.height = 1080
        #expect(DeliveryCheck.encoder(s)?.isHardware == true)
        s.video.hardwareEncoding = false
        let off = DeliveryCheck.encoder(s)
        #expect(off?.isHardware == false)
        #expect(off?.reason.contains("hardware encoding is off") == true)
        s.video.hardwareEncoding = true
        s.video.width = 7680; s.video.height = 4320
        #expect(DeliveryCheck.encoder(s)?.isHardware == false)
        s.video.codec = .prores422
        #expect(DeliveryCheck.encoder(s)?.reason.contains("ProRes") == true)
    }
}
