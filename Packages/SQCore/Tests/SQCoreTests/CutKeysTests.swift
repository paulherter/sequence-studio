import Foundation
import Testing
@testable import SQCore

/// Fast manual cutting (Q-CUT1 / Q-CUT2): Cut Out, close gaps at the playhead, piece between two edits, J / L cut by direction.
@Suite struct CutKeysTests {
    let fd = Time(1, 30)
    func s(_ n: Int64) -> Time { Time(n, 1) }

    func clip(_ kind: TrackKind, _ start: Int64, _ len: Int64, link: UUID? = nil, src: Int64 = 5) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(src), duration: s(len)), start: s(start),
             link: link, mediaDuration: s(60))
    }

    /// V1 + A1 with the given (start, length) pairs, same on both.
    func make(_ spans: [(Int64, Int64)], locked: Bool = false) -> Timeline {
        var v = Track(kind: .video, isTargeted: true), a = Track(kind: .audio, isTargeted: true)
        for (st, len) in spans {
            let l = UUID()
            try! v.overwrite(clip(.video, st, len, link: l)); try! a.overwrite(clip(.audio, st, len, link: l))
        }
        a.isLocked = locked
        return Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [v, a])
    }

    // MARK: Cut Out state machine

    @Test func firstPressMarksStart() {
        #expect(Timeline.cutOutStep(pending: nil, playhead: s(3)) == .markStart(s(3)))
    }

    @Test func secondPressExtractsSpan() {
        #expect(Timeline.cutOutStep(pending: s(3), playhead: s(5)) == .extract(TimeRange(start: s(3), end: s(5))))
    }

    @Test func secondPressAtOrBeforeStartRestarts() {
        #expect(Timeline.cutOutStep(pending: s(3), playhead: s(3)) == .markStart(s(3)))
        #expect(Timeline.cutOutStep(pending: s(3), playhead: s(2)) == .markStart(s(2)))
    }

    // MARK: Close gaps at the playhead

    @Test func closesTheGapOnAllTracksAtOnce() throws {
        var t = make([(0, 4), (6, 4)])
        let closed = try t.closeGapsAtPlayhead(at: s(5))
        #expect(closed == s(2))
        #expect(t.tracks[0].clips.map(\.start) == [s(0), s(4)])
        #expect(t.tracks[1].clips.map(\.start) == [s(0), s(4)])
    }

    @Test func noGapUnderPlayheadDoesNothing() throws {
        var t = make([(0, 4), (6, 4)])
        let before = t
        #expect(try t.closeGapsAtPlayhead(at: s(2)) == .zero)
        #expect(t == before)
    }

    @Test func lockedTrackKeepsItsGap() throws {
        var t = make([(0, 4), (6, 4)], locked: true)
        _ = try t.closeGapsAtPlayhead(at: s(5))
        #expect(t.tracks[0].clips.map(\.start) == [s(0), s(4)])
        #expect(t.tracks[1].clips.map(\.start) == [s(0), s(6)])
    }

    // MARK: Piece between the last two edits

    @Test func piecesBetweenTwoEditsAreTheMiddleClips() throws {
        var t = make([(0, 10)])
        _ = try t.addEdit(at: s(3), tracks: nil)
        _ = try t.addEdit(at: s(7), tracks: nil)
        let ids = t.clips(between: s(3), and: s(7))
        #expect(ids.count == 2)
        for id in ids { #expect(t.find(id)?.clip.start == s(3)); #expect(t.find(id)?.clip.timeline.end == s(7)) }
        #expect(t.clips(between: s(3), and: s(8)).isEmpty)
        #expect(t.clips(between: s(7), and: s(3)).count == 2)   // order of the two points does not matter
    }

    // MARK: J / L cut by direction

    @Test func jCutPullsTheNextAudioEditBackToThePlayhead() throws {
        var t = make([(0, 10), (10, 10)])
        let moved = try t.splitEditJL(.jCut, at: s(8))
        #expect(moved == s(-2))
        #expect(t.tracks[0].clips.map(\.start) == [s(0), s(10)])   // video stays
        #expect(t.tracks[1].clips.map(\.start) == [s(0), s(8)])
    }

    @Test func lCutLetsThePreviousAudioRunOnToThePlayhead() throws {
        var t = make([(0, 10), (10, 10)])
        let moved = try t.splitEditJL(.lCut, at: s(12))
        #expect(moved == s(2))
        #expect(t.tracks[1].clips.map(\.start) == [s(0), s(12)])
        #expect(t.tracks[0].clips.map(\.start) == [s(0), s(10)])
    }

    @Test func jCutPicksTheNearestCutAheadNotBehind() throws {
        var t = make([(0, 10), (10, 10), (20, 10)])
        _ = try t.splitEditJL(.jCut, at: s(18))
        #expect(t.tracks[1].clips.map(\.start) == [s(0), s(10), s(18)])
    }

    @Test func jCutWithNoCutAheadThrows() {
        var t = make([(0, 10), (10, 10)])
        #expect(throws: EditError.clipNotFound) { try t.splitEditJL(.jCut, at: s(12)) }
        #expect(throws: EditError.clipNotFound) { try t.splitEditJL(.lCut, at: s(5)) }
    }
}
