import Foundation
import Testing
@testable import SQCore

/// N8b: pauses inside dialogue clips release the live duck (like the baked Auto Duck); without silence data the whole
/// clip ducks as before.
@Suite struct LiveDuckingSilenceTests {
    struct Fixed: DialogueSilenceProvider {
        let pauses: [UUID: [TimeRange]]
        func silences(of clip: Clip, trackVolumeDB: Double) -> [TimeRange]? { pauses[clip.id] }
    }

    static func sec(_ a: Int64, _ len: Int64) -> TimeRange { TimeRange(start: Time(a, 1), duration: Time(len, 1)) }

    @Test func pauseSplitsTheDialogueRange() {
        let t = LiveDuckingTests.timeline(dialogue: [(10, 10)])
        let id = t.tracks[0].clips[0].id
        let r = LiveDucking.dialogueRanges(in: t, silences: Fixed(pauses: [id: [Self.sec(13, 3)]]))
        #expect(r == [Self.sec(10, 3), Self.sec(16, 4)])
    }

    @Test func missingSilenceDataDucksTheWholeClip() {
        let t = LiveDuckingTests.timeline(dialogue: [(10, 10)])
        #expect(LiveDucking.dialogueRanges(in: t, silences: Fixed(pauses: [:])) == [Self.sec(10, 10)])
    }

    @Test func overlappingClipKeepsTheDuckThroughAPause() {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 10)])
        var d2 = Track(kind: .audio, clips: [LiveDuckingTests.clip(12, 6)]); d2.audioRole = .dialogue
        t.tracks.append(d2)
        let id = t.tracks[0].clips[0].id
        let r = LiveDucking.dialogueRanges(in: t, silences: Fixed(pauses: [id: [Self.sec(13, 3)]]))
        #expect(r == [Self.sec(10, 10)])
    }

    @Test func pauseReleasesTheMusic() {
        let t = LiveDuckingTests.timeline(dialogue: [(10, 10)])
        let id = t.tracks[0].clips[0].id
        let live = LiveDucking(amountDB: 12, fade: Time(1, 2))
        let ranges = LiveDucking.dialogueRanges(in: t, silences: Fixed(pauses: [id: [Self.sec(12, 4)]]))
        #expect(live.gain(at: Time(14, 1), ranges: ranges) == 1)
        #expect(live.gain(at: Time(11, 1), ranges: ranges) < 0.3)
    }

    @Test func activeRangesSubtractThePauses() {
        let r = LiveDucking.activeRanges(of: Self.sec(0, 10), silences: [Self.sec(8, 5), Self.sec(-2, 3), Self.sec(4, 1)])
        #expect(r == [Self.sec(1, 3), Self.sec(5, 3)])
    }

    @Test func bakeHonoursThePausesLikeLivePlayback() {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 10)])
        let id = t.tracks[0].clips[0].id
        let live = LiveDucking(amountDB: 12, fade: Time(1, 2))
        live.bake(into: &t, silences: Fixed(pauses: [id: [Self.sec(12, 4)]]))
        let music = t.tracks[1].clips[0]
        #expect(abs(music.volume(at: Time(14, 1)) - 1) < 1e-9)
        #expect(music.volume(at: Time(11, 1)) < 0.3)
    }
}
