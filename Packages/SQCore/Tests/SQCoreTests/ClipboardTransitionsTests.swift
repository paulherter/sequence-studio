import Foundation
import Testing
@testable import SQCore

// Copy/paste carries transitions (AUDIT F, P1): every paste path (Normal overwrite and insert, paste to targets, Fast
// Cut main-track and attached paste, another sequence) restores the transitions of the copied clips under new ids.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func clip(_ name: String, start: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: name, media: UUID(), kind: kind, source: TimeRange(start: f(30), duration: f(60)), start: f(start),
         link: link, mediaDuration: f(300))
}

private func twoTracks() throws -> (Timeline, a: Clip, b: Clip, c: Clip) {
    let a = clip("A", start: 0), b = clip("B", start: 60), c = clip("C", start: 120)
    var t = Track(kind: .video)
    try t.overwrite(a); try t.overwrite(b); try t.overwrite(c)
    var tl = Timeline(name: "t", frameDuration: fd, tracks: [t, Track(kind: .video)])
    let id = tl.tracks[0].id
    try tl.addTransition(kind: .crossDissolve, track: id, outgoing: a.id, incoming: b.id, duration: f(20))
    try tl.addTransition(kind: .dipToBlack, track: id, outgoing: nil, incoming: a.id, duration: f(10))
    return (tl, a, b, c)
}

@Suite struct ClipboardTransitionsTests {
    @Test func pasteToAnotherTrackCarriesTheCutAndTheFade() throws {
        var (t, a, b, _) = try twoTracks()
        let cb = try #require(t.clipboard(copying: [a.id, b.id]))
        #expect(cb.transitions.count == 2)
        try t.paste(cb, at: f(300), lanes: [.video: 1])
        #expect(t.resolvedTransitions(on: t.tracks[1].id).count == 2)
        #expect(t.resolvedTransitions(on: t.tracks[0].id).count == 2)
    }

    @Test func pasteIntoAnotherSequenceCarriesThem() throws {
        let (t, a, b, _) = try twoTracks()
        let cb = try #require(t.clipboard(copying: [a.id, b.id]))
        var other = Timeline(name: "o", frameDuration: fd, tracks: [Track(kind: .video)])
        try other.paste(cb, at: .zero)
        #expect(other.resolvedTransitions(on: other.tracks[0].id).count == 2)
        let ids = Set(other.tracks[0].transitions.map(\.id))
        #expect(ids.isDisjoint(with: Set(t.tracks[0].transitions.map(\.id))))
    }

    @Test func clipboardSurvivesAJSONRoundTrip() throws {
        let (t, a, b, _) = try twoTracks()
        let cb = try #require(t.clipboard(copying: [a.id, b.id]))
        let back = try JSONDecoder().decode(TimelineClipboard.self, from: JSONEncoder().encode(cb))
        #expect(back.transitions == cb.transitions)
    }

    @Test func fastCutMainPasteCarriesTransitions() throws {
        var (t, a, b, _) = try twoTracks()
        t.editMode = .magnetic
        let cb = try #require(t.magneticClipboard(copying: [a.id, b.id]))
        #expect(cb.transitions.count == 2)
        let made = try t.magneticPaste(cb, at: f(180))
        #expect(made.count == 2)
        #expect(t.tracks.flatMap(\.transitions).count == 4)
    }

    @Test func fastCutAttachedPasteCarriesTransitions() throws {
        var (t, a, b, _) = try twoTracks()
        t.editMode = .magnetic
        let cb = try #require(t.magneticClipboard(copying: [a.id, b.id]))
        _ = try t.magneticPaste(cb, at: f(10), attached: true)
        #expect(t.tracks.flatMap(\.transitions).count == 4)
    }

    @Test func duplicateKeepsTransitions() throws {
        var (t, a, b, _) = try twoTracks()
        _ = try t.duplicate([a.id, b.id])
        #expect(t.tracks.flatMap(\.transitions).count == 4)
    }
}
