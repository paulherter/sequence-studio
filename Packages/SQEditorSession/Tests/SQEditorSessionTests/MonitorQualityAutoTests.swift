import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

@Suite struct MonitorQualityAutoTests {
    @Test func retiredEighthAndSixteenthReadAsQuarter() {
        #expect(MonitorQuality.stored("eighth") == .quarter)
        #expect(MonitorQuality.stored("sixteenth") == .quarter)
        #expect(MonitorQuality.stored("half") == .half)
        #expect(MonitorQuality(rawValue: "eighth") == nil)
    }

    @Test func fixedChoicesExcludeAutoAndMenuIncludesIt() {
        #expect(MonitorQuality.allCases == [.full, .half, .quarter])
        #expect(MonitorQuality.menuCases.last == .auto)
        #expect(MonitorQuality.auto.title == "Auto")
        #expect(MonitorQuality(rawValue: "auto") == .auto)
    }

    @Test func governorStepsDownOnDropsAndResetsWhenAPlayRunStarts() {
        let n = AutoQualityGovernor.dropsPerStep
        var g = AutoQualityGovernor(base: .full)
        #expect(g.current == .full)
        g.update(dropped: 0, isPlaying: true)
        g.update(dropped: n - 1, isPlaying: true)
        #expect(g.current == .full)                       // below the step threshold
        g.update(dropped: n, isPlaying: true)
        #expect(g.current == .half)
        g.update(dropped: n * 2, isPlaying: true)
        #expect(g.current == .quarter)
        g.update(dropped: n * 9, isPlaying: true)
        #expect(g.current == .quarter)                    // never below the decoder floor
        g.update(dropped: n * 9, isPlaying: false)
        #expect(g.current == .quarter)                    // stays while stopped
        g.update(dropped: n * 9, isPlaying: true)
        #expect(g.current == .full)                       // a new run starts at the base again
    }

    @Test func governorIgnoresDropsWhilePaused() {
        var g = AutoQualityGovernor(base: .half)
        g.update(dropped: 50, isPlaying: false)
        #expect(g.current == .half)
    }

    @Test func offlineNameFindsTopmostOfflineVideoClipAtTime() throws {
        let a = UUID(), b = UUID()
        var tracks = Timeline.defaultTracks(video: 2, audio: 0)
        try tracks[0].overwrite(Clip(name: "a", media: a, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero))
        try tracks[1].overwrite(Clip(name: "b", media: b, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero))
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: tracks)
        let names: [UUID: String] = [a: "A.mov", b: "B.mov"]
        #expect(MediaOfflineCard.fileName(in: tl, at: Time(1, 1), offlineName: { names[$0] }) == "B.mov")
        #expect(MediaOfflineCard.fileName(in: tl, at: Time(1, 1), offlineName: { $0 == a ? names[$0] : nil }) == "A.mov")
        #expect(MediaOfflineCard.fileName(in: tl, at: Time(1, 1), offlineName: { _ in nil }) == nil)
        #expect(MediaOfflineCard.fileName(in: tl, at: Time(20, 1), offlineName: { names[$0] }) == nil)
    }
}
