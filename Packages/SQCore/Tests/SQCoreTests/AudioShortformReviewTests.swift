import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let frame = Time(1, 30)
private func audio(_ start: Int64 = 0, _ dur: Int64 = 10) -> Clip {
    Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}

@Suite struct FadeKeepsUserKeysTests {
    @Test func headFadeLeavesUserKeysInsideAndOutsideAlone() {
        var c = audio()
        let k1 = Keyframe(time: Time(1, 2), value: 0.8), k2 = Keyframe(time: s(5), value: 0.3)
        c.animation.volume.track.insert(k1); c.animation.volume.track.insert(k2)
        c.setAudioFadeIn(s(1), frameDuration: frame)
        let ids = Set(c.animation.volume.track.keys.map(\.id))
        #expect(ids.contains(k1.id) && ids.contains(k2.id))          // the user's key inside the fade region survives
        #expect(c.audioFadeIn == s(1))
        // The line goes floor -> user key -> level: the user key keeps its own value (documented).
        #expect(c.animation.volume.value(atLocal: Time(1, 2)) == 0.8)
        c.setAudioFadeIn(.zero, frameDuration: frame)
        #expect(c.animation.volume.track.keys.map(\.id) == [k1.id, k2.id])      // removing the fade removes only its own keys
        #expect(c.audioFadeIn == .zero && c.audioFades.head.isEmpty)
    }

    @Test func aTrackOfOnlyUserKeysWithoutFadeIsNotTakenForAFade() {
        var c = audio()
        c.animation.volume.track.insert(Keyframe(time: .zero, value: 0))      // looks like a fade, is not one
        c.animation.volume.track.insert(Keyframe(time: s(2), value: 1))
        #expect(c.audioFadeIn == .zero)
        c.setAudioFadeIn(.zero, frameDuration: frame)
        #expect(c.animation.volume.track.keys.count == 2)
    }

    @Test func tailFadeKeepsDuckKeysAndDropsNone() {
        var c = audio()
        c.animation.volume.track.insert(Keyframe(time: s(9), value: 0.2))
        c.setAudioFadeOut(s(2), frameDuration: frame)
        let before = c.animation.volume.track.keys.count
        c.setAudioFadeOut(s(3), frameDuration: frame)
        #expect(c.animation.volume.track.keys.count == before + 0)       // two fade keys swapped for two, the user key stays
        #expect(c.animation.volume.track.keys.contains { $0.time == s(9) && $0.value == 0.2 })
        #expect(c.audioFadeOut == s(3))
    }

    @Test func duckKeysSurviveFadesAndAreRemovedOnlyByTheirOwnRun() {
        var c = audio(0, 20)
        c.applyDucking(dialogue: [TimeRange(start: s(5), duration: s(2))])
        let duck = Set(c.duckKeyIDs)
        #expect(!duck.isEmpty)
        c.setAudioFadeIn(s(2), frameDuration: frame)
        c.setAudioFadeOut(s(2), frameDuration: frame)
        let ids = Set(c.animation.volume.track.keys.map(\.id))
        #expect(duck.isSubset(of: ids))
        c.applyDucking(dialogue: [])                                     // re-run without dialogue removes just the duck keys
        #expect(c.duckKeyIDs.isEmpty)
        #expect(c.audioFadeIn == s(2) && c.audioFadeOut == s(2))
    }

    @Test func prunesDuckAndFadeMarksWhenKeysAreRemoved() {
        var c = audio(0, 20)
        c.applyDucking(dialogue: [TimeRange(start: s(5), duration: s(2))])
        let gone = c.duckKeyIDs[0]
        c.removeVolumeKey(gone)
        c.setAudioFadeIn(s(1), frameDuration: frame)
        c.removeVolumeKey(c.audioFades.head[1])                          // the user deletes one fade key
        c.pruneAudioKeyMarks()
        #expect(!c.duckKeyIDs.contains(gone) && c.duckKeyIDs.count == 3)
        #expect(c.audioFades.head.isEmpty && c.audioFadeIn == .zero)
    }

    @Test func fadesThatMeetShareTheirKeyAndCanBeRemovedOneByOne() {
        var c = audio()
        c.setAudioFadeIn(s(1), frameDuration: frame)
        c.setAudioFadeOut(s(100), frameDuration: frame)                  // fills the rest: its start is the head's end
        #expect(c.audioFadeIn == s(1) && c.audioFadeOut == s(9))
        c.setAudioFadeIn(.zero, frameDuration: frame)
        #expect(c.audioFadeOut == s(9))                                  // the shared key stays for the tail
        c.setAudioFadeOut(.zero, frameDuration: frame)
        #expect(c.animation.volume.track.isEmpty)
    }

    @Test func marksSurviveCodingAndOldFilesDecode() throws {
        var c = audio()
        c.setAudioFadeIn(s(1), frameDuration: frame)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back.audioFades == c.audioFades && back.audioFadeIn == s(1))
    }

    @Test func anAudioTransitionReplacesTheFadeOnItsEdge() throws {
        let ma = UUID()
        var a = Clip(name: "A", media: ma, kind: .audio, source: TimeRange(start: s(1), duration: s(4)), start: .zero, mediaDuration: s(10))
        var b = Clip(name: "B", media: ma, kind: .audio, source: TimeRange(start: s(1), duration: s(4)), start: s(4), mediaDuration: s(10))
        a.setAudioFadeOut(s(1), frameDuration: frame); b.setAudioFadeIn(s(1), frameDuration: frame)
        a.setAudioFadeIn(s(1), frameDuration: frame)
        var track = Track(kind: .audio); try track.overwrite(a); try track.overwrite(b)
        var t = Timeline(name: "t", format: SequenceFormat(frameDuration: frame), tracks: [track])
        try t.addTransition(kind: .constantGain, track: track.id, outgoing: a.id, incoming: b.id, duration: frame * 15)
        t.normalizeAudioKeyMarks()
        let ta = t.tracks[0].clips[0], tb = t.tracks[0].clips[1]
        #expect(ta.audioFadeOut == .zero && tb.audioFadeIn == .zero)     // the transition wins on both sides of the cut
        #expect(ta.audioFadeIn == s(1))                                  // the outer edge has no transition: its fade stays
        #expect(t.hasAudioTransition(clip: a.id, head: false) && !t.hasAudioTransition(clip: a.id, head: true))
    }
}

@Suite struct ClipLevelsTests {
    private func peak(loudFrom: Int64, to: Int64) -> (TimeRange) -> Float {
        { r in r.end > s(loudFrom) && r.start < s(to) ? 1 : 0 }
    }

    @Test func gainVolumeAndTrackFaderRaiseAQuietPauseAboveTheThreshold() {
        var c = audio(0, 2)
        let quiet: (TimeRange) -> Float = { _ in 0.01 }                  // -40 dB
        #expect(ClipLevels.audible(of: c, sourcePeak: quiet).levels.allSatisfy { abs($0 - 0.01) < 1e-6 })
        c.audioGainDB = 20
        #expect(ClipLevels.audible(of: c, sourcePeak: quiet).levels.allSatisfy { abs($0 - 0.1) < 1e-5 })
        c.animation.volume = AnimatedProperty(0.5)
        #expect(ClipLevels.audible(of: c, sourcePeak: quiet).levels.allSatisfy { abs($0 - 0.05) < 1e-5 })
        #expect(ClipLevels.audible(of: c, trackVolumeDB: -20, sourcePeak: quiet).levels.allSatisfy { abs($0 - 0.005) < 1e-5 })
    }

    @Test func reversedClipHearsTheEndOfTheFileFirst() {
        var c = audio(10, 4)                                             // source 0...4, loud in source 0...1
        c.reversed = true
        let (levels, w) = ClipLevels.audible(of: c, sourcePeak: peak(loudFrom: 0, to: 1))
        let loud = levels.enumerated().filter { $0.element > 0.5 }.map { w * Int64($0.offset) }
        #expect(!loud.isEmpty && loud.allSatisfy { $0 >= s(3) - w })      // played last: timeline 3 s ... 4 s after the clip start
    }

    @Test func aSpeedRampMapsEachWindowThroughItsOwnSegment() {
        var c = Clip(name: "k", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(1)), start: .zero)
        c.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: s(1), from: ClipSpeed(percent: 100)),
                                            SpeedSegment(duration: s(1), from: ClipSpeed(percent: 200))], origin: .zero))
        // Source 0...1 plays in the first timeline second, source 1...3 in the second one (twice as fast).
        // Loud only at source 2...3: timeline 1.5 s ... 2 s.
        let (levels, w) = ClipLevels.audible(of: c, sourcePeak: peak(loudFrom: 2, to: 3))
        let silent = levels.enumerated().filter { $0.element < 0.5 }
        let firstLoud = Double(levels.firstIndex { $0 > 0.5 }!) * Double(w.value) / Double(w.timescale)
        #expect(abs(firstLoud - 1.5) < 0.02, "first loud window at \(firstLoud)")
        #expect(silent.count == levels.count - Int((0.5 / (Double(w.value) / Double(w.timescale))).rounded()) )
    }
}
