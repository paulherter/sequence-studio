import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Ducking follow-ups: one bake path (dialogue ranges as live hears them, never a silent key wipe, tagged and nested clips).
@MainActor @Suite struct DuckBakeUnifiedTests {
    private static func clip(_ start: Int64, _ len: Int64, tag: AudioTag? = nil, sequence: Timeline.ID? = nil) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(len, 1)),
                     start: Time(start, 1), sequence: sequence)
        c.audioTag = tag
        return c
    }

    private static func session(_ tracks: [Track]) -> EditorSession {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: tracks)
        return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
    }

    private static func track(_ role: AudioTag?, _ clips: [Clip], excluded: Bool = false) -> Track {
        var t = Track(kind: .audio, clips: clips); t.audioRole = role; t.isExcludedFromLiveDucking = excluded
        return t
    }

    private func clips(_ ses: EditorSession) -> [Clip] { ses.activeTimeline!.tracks.flatMap(\.clips) }

    /// Speech timing on a Music clip the live bake does not key (excluded track): the keys follow lookahead, hold and
    /// minimum pause, exactly the live gain curve.
    @Test func excludedMusicTrackFollowsLiveTiming() throws {
        let live = LiveDucking(amountDB: 12, timing: .speech)
        var second = Self.clip(12, 1)
        second.start = Time(12, 1) + Time(1, 5) + Time(2, 1)       // a short pause after the first line
        let dlg = Self.track(.dialogue, [Self.clip(10, 2), second])
        let music = Self.track(.music, [Self.clip(0, 60)], excluded: true)
        let ses = Self.session([dlg, music])
        let ranges = LiveDucking.dialogueRanges(in: ses.activeTimeline!)
        #expect(ses.bakeLiveDuckToKeys(live: live) > 0)
        let c = try #require(clips(ses).last)
        for ms in stride(from: 0, to: 20_000, by: 50) {
            let t = Time(Int64(ms), 1000)
            let want = Double(live.gain(at: t, ranges: ranges))
            #expect(abs(c.animation.volume.value(atLocal: t) - want) < 1e-3, "at \(ms) ms")
        }
    }

    /// No Dialogue clip: the bake changes nothing and leaves earlier keys alone (no silent wipe, no undo step).
    @Test func withoutDialogueOldKeysStay() throws {
        var m = Self.clip(0, 60)
        m.applyDucking(dialogue: [TimeRange(start: Time(10, 1), duration: Time(5, 1))])
        let keys = m.animation.volume.track.keys.count
        #expect(keys > 0)
        let ses = Self.session([Self.track(.music, [m], excluded: true)])
        let r = ses.bakeDuck(live: LiveDucking(amountDB: 12))
        #expect(r.keysAdded == 0 && !r.changed)
        #expect(clips(ses)[0].animation.volume.track.keys.count == keys)
        #expect(!ses.undo())
    }

    /// Dialogue exists but no longer over the clip: stale keys are replaced (changed), one undo step, and the result says so.
    @Test func staleKeysAreReportedAsChanged() throws {
        var m = Self.clip(0, 10)
        m.applyDucking(dialogue: [TimeRange(start: Time(2, 1), duration: Time(2, 1))])
        let ses = Self.session([Self.track(.dialogue, [Self.clip(30, 5)]), Self.track(.music, [m], excluded: true)])
        let r = ses.bakeDuck(live: LiveDucking(amountDB: 12))
        #expect(r.keysAdded == 0 && r.changed)
        #expect(clips(ses).last!.animation.volume.track.isEmpty)
        #expect(ses.undo())
    }

    /// Nested sequence clip tagged Music on a track without a role is baked like a plain one.
    @Test func nestedTaggedClipIsBaked() throws {
        let inner = Timeline(name: "in", frameDuration: Time(1, 30), tracks: [])
        let nested = Self.clip(0, 30, tag: .music, sequence: inner.id)
        let ses = Self.session([Self.track(.dialogue, [Self.clip(5, 5)]), Self.track(nil, [nested])])
        #expect(ses.bakeDuck(live: LiveDucking(amountDB: 12)).keysAdded > 0)
        #expect(!clips(ses).last!.duckKeyIDs.isEmpty)
    }

    /// The dialog path and the menu path are one: same keys.
    @Test func bakeLiveDuckingIsTheSamePath() throws {
        func make() -> EditorSession {
            Self.session([Self.track(.dialogue, [Self.clip(10, 5)]), Self.track(.music, [Self.clip(0, 60)])])
        }
        let a = make(), b = make()
        let live = LiveDucking(amountDB: 9, timing: .speech)
        let na = a.bakeLiveDucking(live), nb = b.bakeLiveDuckToKeys(live: live)
        #expect(na == nb && na > 0)
        #expect(clips(a)[1].animation.volume.track.keys.map(\.time) == clips(b)[1].animation.volume.track.keys.map(\.time))
    }
}
