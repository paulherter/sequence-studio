import Foundation
import SQCore
import Testing
@testable import SQEditorSession

// Fast Cut + Delete (the maintainer's rough-cut gesture: click a clip, Backspace, gone, V1 closed, attached clips follow).
// Session level, the way the Delete key runs it (AppController: `session.deleteSelection(ripple:)`).

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(10), duration: s(dur)), start: s(start),
         link: link, mediaDuration: s(100))
}
private func span(_ t: Timeline?, _ id: Clip.ID) -> [Int64]? {
    guard let t else { return nil }
    for tr in t.tracks { if let c = tr.clips.first(where: { $0.id == id }) { return [c.start.value / c.start.timescale, c.timeline.end.value / c.timeline.end.timescale] } }
    return nil
}

/// V1: A[0-4] B[4-8] C[8-12] (each linked to its sound on A1), V2: X[9-11] b-roll over C with its own sound on A2.
@MainActor
struct MagneticDeleteTests {
    let la = UUID(), lb = UUID(), lc = UUID(), lx = UUID()
    let a: Clip, b: Clip, c: Clip, aa: Clip, ab: Clip, ac: Clip, x: Clip, xa: Clip

    init() {
        a = clip(0, 4, link: la); b = clip(4, 4, link: lb); c = clip(8, 4, link: lc)
        aa = clip(0, 4, kind: .audio, link: la); ab = clip(4, 4, kind: .audio, link: lb); ac = clip(8, 4, kind: .audio, link: lc)
        x = clip(9, 2, link: lx); xa = clip(9, 2, kind: .audio, link: lx)
    }

    private func session(transitions: Bool = false, mode: TimelineEditMode = .magnetic) throws -> EditorSession {
        var t = Timeline(name: "t", frameDuration: Time(1, 24),
                         tracks: [Track(kind: .video, clips: [a, b, c]), Track(kind: .video, clips: [x]),
                                  Track(kind: .audio, clips: [aa, ab, ac]), Track(kind: .audio, clips: [xa])])
        if transitions {
            let v1 = t.tracks[0].id
            try t.addTransition(kind: .crossDissolve, track: v1, outgoing: a.id, incoming: b.id, duration: s(1))
            try t.addTransition(kind: .crossDissolve, track: v1, outgoing: b.id, incoming: c.id, duration: s(1))
        }
        t.setEditMode(mode)
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    @Test func deleteOfALinkedMainClipClosesTheGapAndCarriesTheBroll() throws {
        let ses = try session()
        let before = try #require(ses.activeTimeline)
        ses.select(clips: [b.id, ab.id])                       // linked selection: the click selects video + sound
        ses.deleteSelection(ripple: false)
        let t = ses.activeTimeline
        #expect(span(t, b.id) == nil && span(t, ab.id) == nil)
        #expect(span(t, c.id) == [4, 8] && span(t, ac.id) == [4, 8])
        #expect(span(t, x.id) == [5, 7] && span(t, xa.id) == [5, 7])
        #expect(ses.lastError == nil)
        ses.undo()
        #expect(ses.activeTimeline == before)                  // one undo step
    }

    @Test func holdingBacktickKeepsTheAttachedClipsOnTheirFrame() throws {
        let ses = try session()
        ses.keepAttachedHeld = true
        ses.select(clips: [c.id, ac.id])
        ses.deleteSelection(ripple: false)
        let t = ses.activeTimeline
        #expect(span(t, c.id) == nil)
        #expect(span(t, x.id) == [9, 11])                      // stays, re-attached to what is under it now
    }

    @Test func deleteOfTheLastClip() throws {
        let ses = try session()
        ses.select(clips: [c.id, ac.id])
        ses.deleteSelection(ripple: false)
        let t = ses.activeTimeline
        #expect(span(t, c.id) == nil && span(t, ac.id) == nil)
        #expect(span(t, b.id) == [4, 8])
        #expect(span(t, x.id) == nil)                          // attached clips go with their main clip
    }

    @Test func deleteOfAClipWithTransitions() throws {
        let ses = try session(transitions: true)
        ses.select(clips: [b.id, ab.id])
        ses.deleteSelection(ripple: false)
        let t = ses.activeTimeline
        #expect(span(t, b.id) == nil)
        #expect(span(t, c.id) == [4, 8])
        #expect(span(t, x.id) == [5, 7])
    }

    @Test func multiSelectDeletesBothAndCloses() throws {
        let ses = try session()
        ses.select(clips: [a.id, aa.id, c.id, ac.id])
        ses.deleteSelection(ripple: false)
        let t = ses.activeTimeline
        #expect(span(t, a.id) == nil && span(t, c.id) == nil)
        #expect(span(t, b.id) == [0, 4] && span(t, ab.id) == [0, 4])
    }

    @Test func deleteOfAnAttachedClipMovesNothing() throws {
        let ses = try session()
        ses.select(clips: [x.id, xa.id])
        ses.deleteSelection(ripple: false)
        let t = ses.activeTimeline
        #expect(span(t, x.id) == nil && span(t, xa.id) == nil)
        #expect(span(t, c.id) == [8, 12])                      // nothing on the main track moves
    }

    @Test func rippleDeleteSettingAlsoClosesV1() throws {
        let ses = try session()
        ses.select(clips: [b.id, ab.id])
        ses.deleteSelection(ripple: true)
        let t = ses.activeTimeline
        #expect(span(t, c.id) == [4, 8])
        #expect(span(t, x.id) == [5, 7])
    }

    @Test func normalSequenceDeleteStillLifts() throws {
        let ses = try session(mode: .normal)
        ses.select(clips: [b.id, ab.id])
        ses.deleteSelection(ripple: false)
        let t = ses.activeTimeline
        #expect(span(t, b.id) == nil)
        #expect(span(t, c.id) == [8, 12] && span(t, x.id) == [9, 11])
    }
}

@MainActor
struct MagneticDeleteKeyTests {
    /// Backspace and forward delete both arrive as `Key.delete` (App KeyMapping: key codes 51 and 117).
    @Test func deleteKeyIsDeleteInTheTimelineInBothKeySets() {
        for map in [CommandMap.premiereDefault, CommandMap.sqDefault] {
            #expect(map.command(for: KeyBinding(.delete), focus: .timeline) == .delete)
            #expect(map.command(for: KeyBinding(.delete, .shift), focus: .timeline) == .rippleDelete)
        }
    }
}
