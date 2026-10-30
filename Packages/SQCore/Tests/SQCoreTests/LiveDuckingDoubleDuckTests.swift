import Foundation
import Testing
@testable import SQCore

/// Consolidation step 4: keys from an earlier Auto Duck on a track that live ducking still ducks are found and removable
/// (one pass), and a bake leaves no track that ducks twice.
@Suite struct LiveDuckingDoubleDuckTests {
    let live = LiveDucking(amountDB: 12, fade: Time(1, 2))

    /// Dialogue 10-15 s; the music clip carries keys from an old Auto Duck run.
    private func timelineWithOldAutoDuck() throws -> Timeline {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5)])
        var c = t.tracks[1].clips[0]
        c.applyDucking(dialogue: [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        try t.replaceClip(c)
        return t
    }

    @Test func oldKeysOnALiveDuckedTrackAreFound() throws {
        let t = try timelineWithOldAutoDuck()
        #expect(LiveDucking.clipsDuckingTwice(in: t) == [t.tracks[1].clips[0].id])
    }

    @Test func noDoubleWhenTheTrackIsExcludedOrKeysAreAbsent() throws {
        var t = try timelineWithOldAutoDuck()
        t.tracks[1].isExcludedFromLiveDucking = true
        #expect(LiveDucking.clipsDuckingTwice(in: t).isEmpty)
        #expect(LiveDucking.clipsDuckingTwice(in: LiveDuckingTests.timeline(dialogue: [(10, 5)])).isEmpty)
    }

    @Test func removingTheKeysRestoresTheCleanVolumeLine() throws {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5)])
        var c = t.tracks[1].clips[0]; c.animation.volume = AnimatedProperty(0.5)
        c.applyDucking(dialogue: [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        try t.replaceClip(c)
        let n = LiveDucking.removeKeysDuckingTwice(from: &t)
        #expect(n > 0)
        let after = t.tracks[1].clips[0]
        #expect(after.duckKeyIDs.isEmpty && after.animation.volume.track.keys.isEmpty)
        #expect(abs(after.animation.volume.value(atLocal: Time(12, 1)) - 0.5) < 1e-9)
        #expect(LiveDucking.clipsDuckingTwice(in: t).isEmpty)
        #expect(!t.tracks[1].isExcludedFromLiveDucking)          // live ducking keeps ducking: that is the point
    }

    @Test func rebakeReplacesOldKeysAndNeverLeavesBothActive() throws {
        var t = try timelineWithOldAutoDuck()
        #expect(live.bake(into: &t) > 0)
        #expect(LiveDucking.duckedClipIDs(in: t).isEmpty)
        #expect(LiveDucking.clipsDuckingTwice(in: t).isEmpty)
        let c = t.tracks[1].clips[0]
        let ranges = LiveDucking.dialogueRanges(in: t)
        // only the new bake's keys exist and they equal the live curve
        #expect(c.duckKeyIDs.count == c.animation.volume.track.keys.count)
        for p in [Time(5, 1), Time(12, 1), Time(39, 4), Time(16, 1)] {
            #expect(abs(c.animation.volume.value(atLocal: p - c.start) - Double(live.gain(at: p, ranges: ranges))) < 1e-5)
        }
    }
}
