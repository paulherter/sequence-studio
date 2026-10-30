import Foundation
import Testing
@testable import SQCore

/// N8b: baking the live duck curve into volume keys on the Music tracks, which then leave live ducking (never ducked twice).
@Suite struct LiveDuckingBakeTests {
    let live = LiveDucking(amountDB: 12, fade: Time(1, 2))

    @Test func bakedKeysReproduceTheLiveCurveAndExcludeTheTrack() {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5), (30, 5)])
        let ranges = LiveDucking.dialogueRanges(in: t)
        let added = live.bake(into: &t)
        #expect(added > 0)
        #expect(t.tracks[1].isExcludedFromLiveDucking)
        #expect(!t.tracks[0].isExcludedFromLiveDucking)          // the dialogue track keeps ducking other music
        #expect(LiveDucking.duckedClipIDs(in: t).isEmpty)
        let c = t.tracks[1].clips[0]
        #expect(c.duckKeyIDs.count == added)
        for probe in [Time(5, 1), Time(39, 4), Time(12, 1), Time(61, 4), Time(16, 1), Time(20, 1), Time(119, 4), Time(32, 1), Time(36, 1)] {
            let baked = c.animation.volume.value(atLocal: probe - c.start)
            #expect(abs(baked - Double(live.gain(at: probe, ranges: ranges))) < 1e-5, "at \(probe)")
        }
    }

    @Test func bakeKeepsTheClipsOwnVolume() throws {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5)])
        var c = t.tracks[1].clips[0]; c.animation.volume = AnimatedProperty(0.5)
        try t.replaceClip(c)
        live.bake(into: &t)
        let v = t.tracks[1].clips[0].animation.volume
        #expect(abs(v.value(atLocal: Time(5, 1)) - 0.5) < 1e-9)
        #expect(abs(v.value(atLocal: Time(12, 1)) - 0.5 * pow(10, -12.0 / 20)) < 1e-6)
    }

    @Test func withoutDialogueNothingIsBakedOrExcluded() {
        var t = LiveDuckingTests.timeline(dialogue: [])
        #expect(live.bake(into: &t) == 0)
        #expect(!t.tracks[1].isExcludedFromLiveDucking)
        #expect(t.tracks[1].clips[0].animation.volume.track.isEmpty)
    }

    @Test func excludedAndNonMusicTracksAreLeftAlone() {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5)])
        var other = Track(kind: .audio, clips: [LiveDuckingTests.clip(0, 100)]); other.audioRole = .sfx
        var excluded = Track(kind: .audio, clips: [LiveDuckingTests.clip(0, 100)]); excluded.audioRole = .music
        excluded.isExcludedFromLiveDucking = true
        t.tracks += [other, excluded]
        live.bake(into: &t)
        #expect(t.tracks[2].clips[0].animation.volume.track.isEmpty && !t.tracks[2].isExcludedFromLiveDucking)
        #expect(t.tracks[3].clips[0].animation.volume.track.isEmpty)
    }
}

@Suite struct ClipRemoveDuckKeysTests {
    @Test func removesOnlyGeneratedKeysAndReportsCount() {
        var c = Clip(name: "m", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(30, 1)), start: .zero)
        #expect(c.removeDuckKeys() == 0)
        let added = c.applyDucking(dialogue: [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        #expect(added > 0)
        #expect(c.removeDuckKeys() == added)
        #expect(c.duckKeyIDs.isEmpty && c.animation.volume.track.isEmpty)
    }
}
