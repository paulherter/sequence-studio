import Foundation
import Testing
@testable import SQCore

// Fast Cut Move Left / Move Right (swap with the neighbor), Delete Selection Only and attach-point re-anchoring
// (docs/research/editor-architecture/F2-fcp-magnetic-timeline.md sections 7 and 8).
//
// V1: c1 0-4 (linked with c1a) | c2 4-8 | c3 8-12
// V2: title 4.5-6.5, attached to c2 at point 1
// A1: c1a 0-4 (camera audio of c1)
// A2: music 1-7, attached to c1 at point 0;  V3: tail 10-11, attached to c3 at point 2

private func s(_ x: Double) -> Time { Time(Int64((x * 30).rounded()), 30) }
private func d(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

private struct F {
    var tl: Timeline
    let c1 = UUID(), c2 = UUID(), c3 = UUID(), c1a = UUID(), title = UUID(), music = UUID(), tail = UUID()

    init() {
        let cam = UUID(), camMedia = UUID()
        func clip(_ id: UUID, _ kind: TrackKind, _ start: Double, _ len: Double, link: UUID? = nil, media: UUID = UUID(),
                  attach: (UUID, Double)? = nil) -> Clip {
            var c = Clip(id: id, name: "x", media: media, kind: kind, source: TimeRange(start: s(10), duration: s(len)),
                         start: s(start), link: link, mediaDuration: s(100))
            if let attach { c.attachment = ClipAttachment(host: attach.0, point: s(attach.1)) }
            return c
        }
        let v1 = Track(kind: .video, clips: [clip(c1, .video, 0, 4, link: cam, media: camMedia), clip(c2, .video, 4, 4), clip(c3, .video, 8, 4)])
        let v2 = Track(kind: .video, clips: [clip(title, .video, 4.5, 2, attach: (c2, 1))])
        let a1 = Track(kind: .audio, clips: [clip(c1a, .audio, 0, 4, link: cam, media: camMedia)])
        let a2 = Track(kind: .audio, clips: [clip(music, .audio, 1, 6, attach: (c1, 0))])
        let v3 = Track(kind: .video, clips: [clip(tail, .video, 10, 1, attach: (c3, 2))])
        tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [v1, v2, a1, a2, v3])
        tl.editMode = .magnetic
    }
}

private func span(_ tl: Timeline, _ id: Clip.ID) -> [Double]? { tl.find(id).map { [d($0.clip.start), d($0.clip.timeline.end)] } }
private func host(_ tl: Timeline, _ id: Clip.ID) -> Clip.ID? { tl.find(id)?.clip.attachment?.host }
private func mainSpans(_ tl: Timeline) -> [[Double]] { tl.tracks[tl.mainTrackIndex!].clips.map { [d($0.start), d($0.timeline.end)] } }
private func mainIDs(_ tl: Timeline) -> [Clip.ID] { tl.tracks[tl.mainTrackIndex!].clips.map(\.id) }
private func valid(_ tl: Timeline, sourceLocation: SourceLocation = #_sourceLocation) {
    let m = tl.tracks[tl.mainTrackIndex!].clips
    #expect(zip(m, m.dropFirst()).allSatisfy { $0.timeline.end == $1.start }, "hole on V1", sourceLocation: sourceLocation)
    let consistent = tl.tracks.allSatisfy { $0.isConsistent }
    #expect(consistent, sourceLocation: sourceLocation)
    for t in tl.tracks { for c in t.clips where tl.isAttachable(c.id) {
        #expect(tl.isAttachmentValid(c.id), "attachment of \(c.id) invalid", sourceLocation: sourceLocation)
    } }
}

@Suite struct MagneticMoveStepTests {
    @Test func moveRightSwapsWithTheNextClip() throws {
        var f = F()
        try f.tl.magneticMove(f.c2, step: 1)
        #expect(mainIDs(f.tl) == [f.c1, f.c3, f.c2])
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(span(f.tl, f.c3) == [4, 8])
        valid(f.tl)
    }

    @Test func attachedClipsAndLinkedPartnersTravel() throws {
        var f = F()
        try f.tl.magneticMove(f.c1, step: 1)
        #expect(mainIDs(f.tl) == [f.c2, f.c1, f.c3])
        #expect(span(f.tl, f.c1a) == [4, 8])            // camera audio
        #expect(span(f.tl, f.music) == [5, 11])         // attached to c1: attach time 1 -> 5
        #expect(host(f.tl, f.music) == f.c1)
        #expect(span(f.tl, f.title) == [0.5, 2.5])      // attached to the neighbor: it swaps too
        #expect(host(f.tl, f.title) == f.c2)
        valid(f.tl)
    }

    @Test func moveLeftFromThePartnerMovesTheMainClip() throws {
        var f = F()
        try f.tl.magneticMove(f.c2, step: -1)
        #expect(mainIDs(f.tl) == [f.c2, f.c1, f.c3])
        var g = F()
        try g.tl.magneticMove(g.c1a, step: 1)           // the audio partner of c1
        #expect(mainIDs(g.tl) == [g.c2, g.c1, g.c3])
        #expect(mainSpans(f.tl) == mainSpans(g.tl))
    }

    @Test func movingBackAndForthRestoresTheSequence() throws {
        var f = F()
        let before = f.tl
        try f.tl.magneticMove(f.c2, step: 1)
        try f.tl.magneticMove(f.c2, step: -1)
        #expect(mainIDs(f.tl) == mainIDs(before))
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(span(f.tl, f.tail) == [10, 11])
        valid(f.tl)
    }

    @Test func attachedClipSpanningTheCutStaysWithItsHost() throws {
        var f = F()
        try f.tl.magneticMove(f.c1, step: 1)            // music (1-7) spans the c1/c2 cut
        #expect(host(f.tl, f.music) == f.c1)
        valid(f.tl)
    }

    @Test func firstClipLeftAndLastClipRightDoNothing() throws {
        var f = F()
        let before = f.tl
        try f.tl.magneticMove(f.c1, step: -1)
        try f.tl.magneticMove(f.c3, step: 1)
        #expect(mainIDs(f.tl) == mainIDs(before))
        #expect(mainSpans(f.tl) == mainSpans(before))
    }

    @Test func attachedClipIsNotMoved() throws {
        var f = F()
        let before = f.tl
        try f.tl.magneticMove(f.title, step: 1)
        #expect(span(f.tl, f.title) == span(before, f.title))
        #expect(mainIDs(f.tl) == mainIDs(before))
    }

    // MARK: Delete Selection Only

    @Test func deleteSelectionOnlyKeepsTheLastClipsAttachedClip() throws {
        var f = F()
        try f.tl.magneticDelete([f.c3], keepAttached: true)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8]])
        #expect(span(f.tl, f.tail) == [10, 11])         // stays on its frame, past the end of V1
        valid(f.tl)
    }

    @Test func deleteSelectionOnlyOnSpacerKeepsTheClipsInIt() throws {
        var f = F()
        try f.tl.replaceWithSpacer([f.c2])
        try f.tl.deleteSpacer(at: s(5), keepAttached: true)
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        valid(f.tl)
    }

    // MARK: Re-anchor

    @Test func hostTrimmedShorterThanTheAttachPointClampsIt() throws {
        var f = F()
        _ = try f.tl.magneticRippleTrim(f.c3, edge: .tail, by: s(-3))     // c3 is 1 s now; tail attached at point 2
        #expect(host(f.tl, f.tail) == f.c3)
        let t = f.tl.find(f.tail)!.clip
        let a = t.start + t.attachment!.point
        #expect(a >= s(8) && a < s(9))
        valid(f.tl)
    }

    @Test func removedHostWithKeepAttachedRehostsToTheClipUnderIt() throws {
        var f = F()
        try f.tl.magneticDelete([f.c1], keepAttached: true)
        #expect(span(f.tl, f.music) == [1, 7])
        #expect(host(f.tl, f.music) == f.c2)            // c2 now plays 0-4; the music's point lies under it
        valid(f.tl)
    }
}
