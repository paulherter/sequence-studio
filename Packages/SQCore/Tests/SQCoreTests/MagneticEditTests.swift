import Foundation
import Testing
@testable import SQCore

// Fast Cut edit core (Timeline+Magnetic.swift engine, Timeline+MagneticOps.swift verbs): one test per row of
// docs/research/FCP-MAGNETIC-TIMELINE.md table 5.6, on one small fixture.
//
// V1: c1 0-4 (linked with c1a) | c2 4-8 | c3 8-12
// V2: title 4.5-6.5, attached to c2 at point 1 (attach time 5.5)
// A1: c1a 0-4 (camera audio of c1: part of the main track)
// A2: music 1-7, attached to c1 at point 0 (attach time 1)

private func s(_ x: Double) -> Time { Time(Int64((x * 30).rounded()), 30) }
private let fd = Time(1, 30)
private func d(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

private struct F {
    var tl: Timeline
    let c1 = UUID(), c2 = UUID(), c3 = UUID(), c1a = UUID(), title = UUID(), music = UUID()

    init() {
        let cam = UUID(), camMedia = UUID()
        func clip(_ id: UUID, _ kind: TrackKind, _ start: Double, _ len: Double, link: UUID? = nil, media: UUID = UUID(),
                  attach: (UUID, Double)? = nil) -> Clip {
            var c = Clip(id: id, name: "x", media: media, kind: kind, source: TimeRange(start: s(10), duration: s(len)),
                         start: s(start), link: link, mediaDuration: s(100))
            if let attach { c.attachment = ClipAttachment(host: attach.0, point: s(attach.1)) }
            return c
        }
        let v1 = Track(kind: .video, clips: [clip(c1, .video, 0, 4, link: cam, media: camMedia), clip(c2, .video, 4, 4),
                                             clip(c3, .video, 8, 4)])
        let v2 = Track(kind: .video, clips: [clip(title, .video, 4.5, 2, attach: (c2, 1))])
        let a1 = Track(kind: .audio, clips: [clip(c1a, .audio, 0, 4, link: cam, media: camMedia)])
        let a2 = Track(kind: .audio, clips: [clip(music, .audio, 1, 6, attach: (c1, 0))])
        tl = Timeline(name: "S", frameDuration: fd, tracks: [v1, v2, a1, a2])
        tl.editMode = .magnetic
    }
}

private func span(_ tl: Timeline, _ id: Clip.ID) -> [Double]? {
    tl.find(id).map { [d($0.clip.start), d($0.clip.timeline.end)] }
}
private func trackOf(_ tl: Timeline, _ id: Clip.ID) -> Int? { tl.find(id)?.track }
private func host(_ tl: Timeline, _ id: Clip.ID) -> Clip.ID? { tl.find(id)?.clip.attachment?.host }
private func attachTime(_ tl: Timeline, _ id: Clip.ID) -> Double? {
    tl.find(id).flatMap { m in m.clip.attachment.map { d(m.clip.start + $0.point) } }
}
private func main(_ tl: Timeline) -> [Clip] { tl.tracks[tl.mainTrackIndex!].clips }
private func mainSpans(_ tl: Timeline) -> [[Double]] { main(tl).map { [d($0.start), d($0.timeline.end)] } }
private func encoded(_ tl: Timeline) throws -> Data {
    let e = JSONEncoder(); e.outputFormatting = .sortedKeys
    return try e.encode(tl)
}

/// Fast Cut invariants after every op: no hole on V1 (unless `holes`), every attachable clip attached and valid, no overlaps.
private func checkInvariants(_ tl: Timeline, holes: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
    let m = main(tl)
    if !holes {
        #expect(zip(m, m.dropFirst()).allSatisfy { $0.timeline.end == $1.start }, "hole on the main track", sourceLocation: sourceLocation)
    }
    let consistent = tl.tracks.allSatisfy { $0.isConsistent }
    #expect(consistent, sourceLocation: sourceLocation)
    for t in tl.tracks { for c in t.clips {
        if tl.isAttachable(c.id), !m.isEmpty {
            #expect(tl.isAttachmentValid(c.id), "attachment of \(c.id) invalid", sourceLocation: sourceLocation)
        } else {
            #expect(c.attachment == nil, sourceLocation: sourceLocation)
        }
    } }
}

/// A source range as Fast Cut source edits get it: video and its linked audio, both starting at 0.
private func package(_ len: Double, audio: Bool = true, video: Bool = true) -> [Clip] {
    let link: UUID? = audio && video ? UUID() : nil, media = UUID()
    var out: [Clip] = []
    if video { out.append(Clip(name: "src", media: media, kind: .video, source: TimeRange(start: .zero, duration: s(len)), start: .zero, link: link, mediaDuration: s(100))) }
    if audio { out.append(Clip(name: "src", media: media, kind: .audio, source: TimeRange(start: .zero, duration: s(len)), start: .zero, link: link, mediaDuration: s(100))) }
    return out
}

@Suite struct MagneticEditTests {
    // MARK: Delete

    @Test func fixtureIsValid() {
        let f = F()
        checkInvariants(f.tl)
        #expect(attachTime(f.tl, f.title) == 5.5)
    }

    /// Delete on a V1 clip: ripple delete; its attached clips are deleted too.
    @Test func deleteMainClipDeletesItsAttachedClips() throws {
        var f = F()
        try f.tl.magneticDelete([f.c2])
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8]])
        #expect(f.tl.find(f.title) == nil)
        #expect(span(f.tl, f.music) == [1, 7])
        #expect(host(f.tl, f.music) == f.c1)
        checkInvariants(f.tl)
    }

    /// Hold ` while deleting: the attached clips stay where they are and re-attach to the clip now under their point.
    @Test func deleteMainClipKeepingAttachedClips() throws {
        var f = F()
        try f.tl.magneticDelete([f.c2], keepAttached: true)
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, f.title) == f.c3)
        checkInvariants(f.tl)
    }

    @Test func deleteFirstMainClipCarriesLaterAttachedClips() throws {
        var f = F()
        try f.tl.magneticDelete([f.c1])
        #expect(f.tl.find(f.c1a) == nil)                // camera audio goes with its clip
        #expect(f.tl.find(f.music) == nil)              // attached to c1
        #expect(span(f.tl, f.c2) == [0, 4])
        #expect(span(f.tl, f.title) == [0.5, 2.5])
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl)
    }

    /// Delete on an attached clip: removed; nothing moves, no gap.
    @Test func deleteAttachedClipMovesNothing() throws {
        var f = F()
        let before = mainSpans(f.tl)
        try f.tl.magneticDelete([f.title])
        #expect(f.tl.find(f.title) == nil)
        #expect(mainSpans(f.tl) == before)
        #expect(span(f.tl, f.music) == [1, 7])
        checkInvariants(f.tl)
    }

    /// Shift+Delete on a V1 clip: Replace with Spacer; attached clips stay and re-host to the clip before the hole.
    @Test func replaceWithSpacerKeepsAttachedClips() throws {
        var f = F()
        try f.tl.replaceWithSpacer([f.c2])
        #expect(mainSpans(f.tl) == [[0, 4], [8, 12]])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, f.title) == f.c1)
        checkInvariants(f.tl, holes: true)
    }

    /// Delete on a spacer: closes; clips attached in it are deleted (keep: they stay and re-host).
    @Test func deleteSpacerFollowsTheDeleteRule() throws {
        var f = F()
        try f.tl.replaceWithSpacer([f.c2])
        var keep = f.tl
        let closed = try f.tl.deleteSpacer(at: s(5))
        #expect(closed == s(4))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8]])
        #expect(f.tl.find(f.title) == nil)
        checkInvariants(f.tl)
        try keep.deleteSpacer(at: s(5), keepAttached: true)
        #expect(span(keep, f.title) == [4.5, 6.5])
        #expect(host(keep, f.title) == f.c3)
        checkInvariants(keep)
    }

    /// Close Gap at Playhead on V1 is Delete on the spacer under the playhead.
    @Test func closeGapAtPlayheadDeletesTheSpacer() throws {
        var f = F()
        try f.tl.replaceWithSpacer([f.c3])        // trailing: not a hole
        #expect(try f.tl.deleteSpacer(at: s(9)) == .zero)
        try f.tl.replaceWithSpacer([f.c1])        // leading hole 0-4; music attached in it
        try f.tl.deleteSpacer(at: s(1))
        #expect(mainSpans(f.tl) == [[0, 4]])
        #expect(f.tl.find(f.music) == nil)
        #expect(span(f.tl, f.title) == [0.5, 2.5])
        checkInvariants(f.tl)
    }

    // MARK: Trim

    /// Drag a V1 edge / ripple trim tail: later clips and their attached clips move.
    @Test func rippleTrimTail() throws {
        var f = F()
        try f.tl.magneticRippleTrim(f.c1, edge: .tail, by: s(-1))
        #expect(mainSpans(f.tl) == [[0, 3], [3, 7], [7, 11]])
        #expect(span(f.tl, f.c1a) == [0, 3])
        #expect(span(f.tl, f.title) == [3.5, 5.5])
        #expect(span(f.tl, f.music) == [1, 7])
        checkInvariants(f.tl)
    }

    /// Head trim: the trimmed clip's attached clips keep their content frame.
    @Test func rippleTrimHeadKeepsTheContentFrame() throws {
        var f = F()
        try f.tl.magneticRippleTrim(f.c2, edge: .head, by: s(1))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 7], [7, 11]])
        #expect(attachTime(f.tl, f.title) == 4.5)
        #expect(span(f.tl, f.title) == [3.5, 5.5])
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl)
    }

    /// A point trimmed away sticks to the nearest remaining edge.
    @Test func rippleTrimHeadPastThePointSticksToTheEdge() throws {
        var f = F()
        try f.tl.magneticRippleTrim(f.c2, edge: .head, by: s(2))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 6], [6, 10]])
        #expect(attachTime(f.tl, f.title) == 4)
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl)
    }

    /// Q / E: ripple trim to the playhead on V1.
    @Test func rippleTrimToPlayhead() throws {
        var f = F()
        _ = try f.tl.magneticRippleTrimToPlayhead(.head, at: s(5))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 7], [7, 11]])
        #expect(attachTime(f.tl, f.title) == 4.5)
        checkInvariants(f.tl)
    }

    /// Roll: attached clips stay on their timeline frame and re-host to the clip now under their point.
    @Test func rollKeepsAttachedOnTheirFrame() throws {
        var f = F()
        try f.tl.magneticRoll(f.c1, by: s(2))
        #expect(span(f.tl, f.c1) == [0, 6])
        #expect(span(f.tl, f.c2) == [6, 8])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, f.title) == f.c1)
        checkInvariants(f.tl)
    }

    /// Slip (decision 2026-10-07 Q4): attached clips stay where they are.
    @Test func slipLeavesAttachedInPlace() throws {
        var f = F()
        try f.tl.magneticSlip(f.c2, by: s(1))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl)
    }

    /// Slide: the slid clip's attached clips move with it.
    @Test func slideCarriesAttachedClips() throws {
        var f = F()
        try f.tl.magneticSlide(f.c2, by: s(1))
        #expect(mainSpans(f.tl) == [[0, 5], [5, 9], [9, 12]])
        #expect(span(f.tl, f.title) == [5.5, 7.5])
        #expect(span(f.tl, f.music) == [1, 7])
        checkInvariants(f.tl)
    }

    /// Nudge on V1 is a one-frame slide; attached clips follow.
    @Test func nudgeMainClipSlides() throws {
        var f = F()
        try f.tl.magneticNudge([f.c2], by: fd)
        #expect(f.tl.find(f.c2)!.clip.start == s(4) + fd)
        #expect(f.tl.find(f.title)!.clip.start == s(4.5) + fd)
        #expect(f.tl.find(f.c3)!.clip.start == s(8) + fd)       // the neighbor trims, its end stays
        #expect(f.tl.find(f.c3)!.clip.timeline.end == s(12))
        checkInvariants(f.tl)
    }

    /// Nudge on an attached clip: a move; nothing else changes.
    @Test func nudgeAttachedClipMoves() throws {
        var f = F()
        try f.tl.magneticNudge([f.title], by: fd)
        #expect(f.tl.find(f.title)!.clip.start == s(4.5) + fd)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        checkInvariants(f.tl)
    }

    // MARK: Cut and join

    /// Cmd+K, nothing selected: V1 and its linked audio only; attached clips hang on the half holding their point.
    @Test func addEditCutsTheMainTrackOnly() throws {
        var f = F()
        let made = try f.tl.magneticAddEdit(at: s(5), selection: [])
        #expect(made.count == 1)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 5], [5, 8], [8, 12]])
        #expect(host(f.tl, f.title) == made[0])
        #expect(f.tl.tracks[3].clips.count == 1)         // music not cut
        checkInvariants(f.tl)
    }

    /// Cmd+Shift+K: every unlocked track; the right half of a cut attached clip attaches at its own first frame.
    @Test func addEditAllTracksCutsAttachedClipsToo() throws {
        var f = F()
        _ = try f.tl.magneticAddEditAll(at: s(5))
        #expect(f.tl.tracks[3].clips.count == 2)
        let right = f.tl.tracks[3].clips[1]
        #expect(right.attachment?.point == .zero)
        #expect(host(f.tl, right.id) == main(f.tl)[2].id)   // c2's right half
        #expect(host(f.tl, f.music) == f.c1)
        checkInvariants(f.tl)
    }

    @Test func joinRehostsToTheJoinedClip() throws {
        var f = F()
        _ = try f.tl.magneticAddEdit(at: s(5), selection: [])
        #expect(try f.tl.magneticJoin() == 1)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl)
    }

    // MARK: Source edits

    /// Insert from Source: V1 at the playhead (split + ripple); attached clips of the split clip stay with their content.
    @Test func insertSplitsAndCarries() throws {
        var f = F()
        let made = try f.tl.insertOnMainTrack(package(2), at: s(5))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 5], [5, 7], [7, 10], [10, 14]])
        #expect(span(f.tl, f.title) == [6.5, 8.5])
        #expect(host(f.tl, f.title) == main(f.tl)[3].id)
        #expect(span(f.tl, f.music) == [1, 7])
        let audio = try #require(made.compactMap { f.tl.find($0) }.first { $0.clip.kind == .audio })
        #expect(audio.track == 2)                          // A1, linked with the new video
        #expect([d(audio.clip.start), d(audio.clip.timeline.end)] == [5, 7])
        checkInvariants(f.tl)
        var g = F()
        try g.tl.insertOnMainTrack(package(2), at: s(6))
        #expect(span(g.tl, g.title) == [4.5, 6.5])
        #expect(host(g.tl, g.title) == g.c2)
        checkInvariants(g.tl)
    }

    /// Overwrite from Source: nothing ripples; attached clips of overwritten material stay and re-host to the new clip.
    @Test func overwriteKeepsAttachedInPlace() throws {
        var f = F()
        let made = try f.tl.overwriteOnMainTrack(package(2), at: s(5))
        let video = try #require(made.first { f.tl.find($0)?.clip.kind == .video })
        #expect(mainSpans(f.tl) == [[0, 4], [4, 5], [5, 7], [7, 8], [8, 12]])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, f.title) == video)
        #expect(span(f.tl, f.music) == [1, 7])          // A2 untouched by the A1 overwrite
        checkInvariants(f.tl)
    }

    /// Insert or overwrite past the end of V1 lands at its end: Fast Cut never opens a hole by itself.
    @Test func sourceEditPastTheEndOpensNoHole() throws {
        var f = F()
        try f.tl.overwriteOnMainTrack(package(2), at: s(20))
        #expect(mainSpans(f.tl).last == [12, 14])
        try f.tl.insertOnMainTrack(package(1), at: s(30))
        #expect(mainSpans(f.tl).last == [14, 15])
        checkInvariants(f.tl)
    }

    /// Append to Main Track: after the last V1 clip.
    @Test func appendGoesAfterTheLastMainClip() throws {
        var f = F()
        let made = try f.tl.appendToMainTrack(package(2), playhead: s(3))
        #expect(made.count == 2)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12], [12, 14]])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        checkInvariants(f.tl)
    }

    /// Audio-only sources attach below the main track at the playhead.
    @Test func audioOnlySourceAttachesBelow() throws {
        var f = F()
        let made = try f.tl.appendToMainTrack(package(2, video: false), playhead: s(3))
        let a = try #require(f.tl.find(made[0]))
        #expect(a.clip.kind == .audio)
        #expect(a.track != 2)                              // never on A1 (main-track sound)
        #expect(host(f.tl, a.clip.id) == f.c1)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        checkInvariants(f.tl)
    }

    /// Place on Top = Attach: point 0, host = V1 clip under the playhead.
    @Test func attachPlacesOnTopAtItsFirstFrame() throws {
        var f = F()
        let made = try f.tl.attach(package(2), at: s(9))
        #expect(made.count == 2)
        for id in made {
            #expect(span(f.tl, id) == [9, 11])
            #expect(host(f.tl, id) == f.c3)
            #expect(f.tl.find(id)!.clip.attachment?.point == .zero)
        }
        let v = made.compactMap { f.tl.find($0) }.first { $0.clip.kind == .video }!
        #expect(v.track == 1)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        checkInvariants(f.tl)
    }

    /// Attach Backtimed: the range ends at the playhead; point = its last frame.
    @Test func attachBacktimed() throws {
        var f = F()
        let made = try f.tl.attach(package(2), at: s(9), backtimed: true)
        for id in made {
            #expect(span(f.tl, id) == [7, 9])
            #expect(f.tl.find(id)!.clip.attachment?.point == s(2) - fd)
            #expect(host(f.tl, id) == f.c3)
        }
        checkInvariants(f.tl)
    }

    /// Attach Backtimed from a source edit (`attachOnTracks(backtimed:)`): `t` is where the run ENDS, like `attach`;
    /// the point is its last frame.
    @Test func attachOnTracksBacktimedEndsAtT() throws {
        var f = F()
        let clip = Clip(name: "x", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(2)), start: .zero, mediaDuration: s(100))
        let plain = try f.tl.attachOnTracks([(clip, f.tl.tracks[1].id)], at: s(7))
        #expect(span(f.tl, plain[0]) == [7, 9] && host(f.tl, plain[0]) == f.c2)
        var g = F()
        let back = try g.tl.attachOnTracks([(clip, g.tl.tracks[1].id)], at: s(9), backtimed: true)
        #expect(span(g.tl, back[0]) == [7, 9])
        #expect(host(g.tl, back[0]) == g.c3)
        #expect(g.tl.find(back[0])!.clip.attachment?.point == s(2) - fd)
        checkInvariants(g.tl)
    }

    /// No room before the sequence start: the head is cut, the clip starts at 0 and still ends at `t`; the point stays the last frame.
    @Test func attachBacktimedCutsTheHeadWhenThereIsNoRoom() throws {
        var f = F()
        let clip = Clip(name: "x", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(3)), start: .zero, mediaDuration: s(100))
        let made = try f.tl.attachOnTracks([(clip, f.tl.tracks[1].id)], at: s(1), backtimed: true)
        #expect(span(f.tl, made[0]) == [0, 1])
        #expect(f.tl.find(made[0])!.clip.source == TimeRange(start: s(12), duration: s(1)))   // the last second of the source
        #expect(f.tl.find(made[0])!.clip.attachment?.point == s(1) - fd)
        #expect(host(f.tl, made[0]) == f.c1)
        var g = F()
        let viaAttach = try g.tl.attach([clip], at: s(1), backtimed: true)
        #expect(span(g.tl, viaAttach[0]) == [0, 1])
        #expect(g.tl.find(viaAttach[0])!.clip.source == TimeRange(start: s(12), duration: s(1)))
        #expect(g.tl.find(viaAttach[0])!.clip.attachment?.point == s(1) - fd)
        checkInvariants(g.tl)
    }

    /// A linked video + sound pair is cut by the same amount.
    @Test func attachBacktimedCutsLinkedPairsAlike() throws {
        var f = F()
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(3)), start: .zero, link: link, mediaDuration: s(100))
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: s(10), duration: s(3)), start: .zero, link: link, mediaDuration: s(100))
        let made = try f.tl.attach([v, a], at: s(2), backtimed: true)
        for id in made { #expect(span(f.tl, id) == [0, 2]) }
        #expect(f.tl.find(v.id)!.clip.source.start == s(11) && f.tl.find(a.id)!.clip.source.start == s(11))
    }

    @Test func attachBacktimedAtZeroIsRefused() {
        var f = F()
        let clip = Clip(name: "x", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(3)), start: .zero, mediaDuration: s(100))
        #expect(throws: EditError.self) { try f.tl.attachOnTracks([(clip, f.tl.tracks[1].id)], at: .zero, backtimed: true) }
    }

    /// Replace with Source Length: ripples; the replaced clip keeps its id and its attached clips.
    @Test func replaceWithSourceLengthRipples() throws {
        var f = F()
        try f.tl.replaceOnMainTrack(f.c2, with: package(6), keepLength: false)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 10], [10, 14]])
        #expect(main(f.tl)[1].id == f.c2)
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl)
    }

    /// Replace (from Start): keeps the length; nothing ripples.
    @Test func replaceFromStartKeepsTheLength() throws {
        var f = F()
        let media = package(6)[0].media
        var src = package(6)
        for i in src.indices { src[i].media = media }
        try f.tl.replaceOnMainTrack(f.c2, with: src, keepLength: true)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(main(f.tl)[1].media == media)
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl)
    }

    // MARK: Replace modes (F2)

    private func sharedMedia(_ len: Double) -> [Clip] {
        var src = package(len)
        let media = src[0].media
        for i in src.indices { src[i].media = media }
        return src
    }

    @Test func replaceFromEndKeepsTheOutPoint() throws {
        var f = F()
        let out = try f.tl.replaceOnMainTrack(f.c2, with: sharedMedia(6), mode: .fromEnd)
        #expect(!out.isShort)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(main(f.tl)[1].source.start == s(2) && main(f.tl)[1].source.end == s(6))
        checkInvariants(f.tl)
    }

    @Test func replaceAtPlayheadAlignsTheAnchor() throws {
        var f = F()   // c2 is 4-8; playhead 5 shows source second 10
        let out = try f.tl.replaceOnMainTrack(f.c2, with: sharedMedia(20), mode: .atPlayhead, playhead: s(5), sourceAnchor: s(10))
        #expect(!out.isShort)
        #expect(main(f.tl)[1].source.start == s(9) && main(f.tl)[1].source.end == s(13))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        checkInvariants(f.tl)
    }

    @Test func replaceWithRetimeFitsTheWholeSource() throws {
        var f = F()
        try f.tl.replaceOnMainTrack(f.c2, with: sharedMedia(8), mode: .withRetime)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(main(f.tl)[1].source.duration == s(8) && main(f.tl)[1].speed == ClipSpeed(num: 2, den: 1))
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl)
    }

    @Test func replaceWithShortMediaWarns() throws {
        var f = F()
        let out = try f.tl.replaceOnMainTrack(f.c2, with: sharedMedia(3), mode: .fromStart)
        #expect(out.isShort && out.shortBy == s(1) && out.warning != nil)
        var g = F()
        let late = try g.tl.replaceOnMainTrack(g.c2, with: sharedMedia(10), mode: .atPlayhead, playhead: s(5), sourceAnchor: s(0))
        #expect(late.isShort)
    }

    // MARK: Moving

    /// Drag a V1 clip along V1: rearrange at the nearest V1 edit; attached clips travel (hold `: they stay).
    @Test func rearrangeCarriesAttachedClips() throws {
        var f = F()
        var keep = f.tl
        try f.tl.magneticRearrange(f.c2, to: s(11.5))
        #expect(span(f.tl, f.c3) == [4, 8])
        #expect(span(f.tl, f.c2) == [8, 12])
        #expect(span(f.tl, f.title) == [8.5, 10.5])
        #expect(host(f.tl, f.title) == f.c2)
        #expect(span(f.tl, f.music) == [1, 7])
        checkInvariants(f.tl)
        try keep.magneticRearrange(f.c2, to: s(11.5), keepAttached: true)
        #expect(span(keep, f.title) == [4.5, 6.5])
        #expect(host(keep, f.title) == f.c3)
        checkInvariants(keep)
    }

    /// Drag a V1 clip to another track: Lift off Main Track with a ripple; it becomes attached where dropped and its
    /// attached clips travel with it (never overwriting).
    @Test func dragOffMainTrack() throws {
        var f = F()
        try f.tl.dragOffMainTrack(f.c2, to: f.tl.tracks[1].id, at: s(9))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8]])
        #expect(span(f.tl, f.c2) == [9, 13])
        #expect(trackOf(f.tl, f.c2) == 1)
        #expect(span(f.tl, f.title) == [9.5, 11.5])
        #expect(trackOf(f.tl, f.title) != 1)              // collided with c2: next free track
        #expect(host(f.tl, f.c2) == f.c3)
        checkInvariants(f.tl)
    }

    /// Drag a clip from another track onto V1: insert at the nearest V1 edit.
    @Test func dragOntoMainTrackInserts() throws {
        var f = F()
        try f.tl.dragOntoMainTrack(f.title, at: s(7.5))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 10], [10, 14]])
        #expect(main(f.tl)[2].id == f.title)
        #expect(f.tl.find(f.title)!.clip.attachment == nil)
        #expect(span(f.tl, f.music) == [1, 7])
        checkInvariants(f.tl)
    }

    /// Cmd while dropping onto V1: overwrite at the drop time.
    @Test func dragOntoMainTrackOverwrites() throws {
        var f = F()
        try f.tl.dragOntoMainTrack(f.title, at: s(9), overwrite: true)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 9], [9, 11], [11, 12]])
        checkInvariants(f.tl)
    }

    /// Drag an attached clip within its lanes: moves; re-attaches under its point; never ripples.
    @Test func moveAttachedRehosts() throws {
        var f = F()
        try f.tl.moveAttached(f.title, to: s(9))
        #expect(span(f.tl, f.title) == [9, 11])
        #expect(host(f.tl, f.title) == f.c3)
        #expect(attachTime(f.tl, f.title) == 10)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        checkInvariants(f.tl)
    }

    /// Opt+Cmd+Up: selected V1 clips go up at the same time; a spacer stays; their attached clips re-host before it.
    @Test func liftOffMainTrackLeavesASpacer() throws {
        var f = F()
        try f.tl.liftOffMainTrack([f.c2])
        #expect(mainSpans(f.tl) == [[0, 4], [8, 12]])
        #expect(span(f.tl, f.c2) == [4, 8])
        let t = try #require(trackOf(f.tl, f.c2))
        #expect(f.tl.tracks[t].kind == .video && t != 0 && t != 1)   // V2 is busy with the title
        #expect(host(f.tl, f.c2) == f.c1)
        #expect(host(f.tl, f.title) == f.c1)
        checkInvariants(f.tl, holes: true)
    }

    /// Opt+Cmd+Down: the attached clip overwrites V1 at its own position.
    @Test func putOnMainTrackOverwritesInPlace() throws {
        var f = F()
        try f.tl.putOnMainTrack([f.title])
        #expect(mainSpans(f.tl) == [[0, 4], [4, 4.5], [4.5, 6.5], [6.5, 8], [8, 12]])
        #expect(trackOf(f.tl, f.title) == 0)
        #expect(f.tl.find(f.title)!.clip.attachment == nil)
        checkInvariants(f.tl)
    }

    // MARK: Spacers, attach point

    /// Ctrl+W: a hole at the playhead on V1; later clips and their attached clips ripple.
    @Test func insertSpacer() throws {
        var f = F()
        try f.tl.insertSpacer(at: s(5), duration: s(2))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 5], [7, 10], [10, 14]])
        #expect(span(f.tl, f.title) == [6.5, 8.5])
        #expect(host(f.tl, f.title) == main(f.tl)[2].id)
        #expect(span(f.tl, f.music) == [1, 7])
        checkInvariants(f.tl, holes: true)
    }

    /// Cmd+Opt+click: point = clicked time; host = V1 clip under it.
    @Test func setAttachPoint() throws {
        var f = F()
        try f.tl.setAttachPoint(f.title, at: s(6))
        #expect(host(f.tl, f.title) == f.c2)
        #expect(f.tl.find(f.title)!.clip.attachment?.point == s(1.5))
        try f.tl.setAttachPoint(f.music, at: s(5))
        #expect(host(f.tl, f.music) == f.c2)
        #expect(f.tl.find(f.music)!.clip.attachment?.point == s(4))
        try f.tl.setAttachPoint(f.music, at: s(50))      // clamped into the clip
        #expect(attachTime(f.tl, f.music) == d(s(7) - fd))
        #expect(throws: EditError.self) { try f.tl.setAttachPoint(f.c1, at: s(1)) }
        // The point now decides who follows whom.
        try f.tl.magneticDelete([f.c3])
        #expect(f.tl.find(f.music) != nil)
        checkInvariants(f.tl)
    }

    // MARK: Clipboard, nest

    /// Paste: copied V1 clips insert on V1 at the playhead with their copied attached clips.
    @Test func pasteCarriesAttachedClips() throws {
        var f = F()
        let cb = try #require(f.tl.magneticClipboard(copying: [f.c2]))
        #expect(cb.entries.count == 2)                    // the title travels with its host
        let made = try f.tl.magneticPaste(cb, at: s(8))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12], [12, 16]])
        let copies = made.compactMap { f.tl.find($0)?.clip }
        let hostCopy = try #require(copies.first { $0.attachment == nil })
        let titleCopy = try #require(copies.first { $0.attachment != nil })
        #expect([d(titleCopy.start), d(titleCopy.timeline.end)] == [8.5, 10.5])
        #expect(titleCopy.attachment?.host == hostCopy.id)
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        checkInvariants(f.tl)
    }

    /// Copied attached clips alone attach at the playhead (first frame), never overwriting.
    @Test func pasteAttachedClipsAlone() throws {
        var f = F()
        let cb = try #require(f.tl.magneticClipboard(copying: [f.title]))
        let made = try f.tl.magneticPaste(cb, at: s(5))
        let c = try #require(f.tl.find(made[0]))
        #expect([d(c.clip.start), d(c.clip.timeline.end)] == [5, 7])
        #expect(c.track != 1)                                // the title is there
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, made[0]) == f.c2)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        checkInvariants(f.tl)
    }

    /// Paste Attached (Opt+V): everything copied lands attached at the playhead; V1 untouched.
    @Test func pasteAsAttached() throws {
        var f = F()
        let cb = try #require(f.tl.magneticClipboard(copying: [f.c2]))
        let made = try f.tl.magneticPaste(cb, at: s(9), attached: true)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        for id in made { #expect(trackOf(f.tl, id) != 0) }
        checkInvariants(f.tl)
    }

    /// Duplicate: V1 clips insert after the selection with their attached clips.
    @Test func duplicateInsertsAfterTheSelection() throws {
        var f = F()
        try f.tl.magneticDuplicate([f.c2])
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12], [12, 16]])
        #expect(f.tl.tracks.flatMap(\.clips).filter { $0.attachment?.host == main(f.tl)[2].id }.count == 1)
        checkInvariants(f.tl)
    }

    /// Nest: V1 clips take their attached clips (those inside their span) into the nest, which sits on V1.
    @Test func nestTakesAttachedClipsAlong() throws {
        let f = F()
        var p = Project(name: "P", timelines: [f.tl])
        let seq = try p.magneticNest(clips: [f.c2], in: f.tl.id)
        let outer = try #require(p.timeline(f.tl.id))
        let inner = try #require(p.timeline(seq))
        #expect(mainSpans(outer) == [[0, 4], [4, 8], [8, 12]])
        #expect(main(outer)[1].sequence == seq)
        #expect(outer.find(f.title) == nil)
        #expect(inner.find(f.title) != nil)
        #expect(host(outer, f.music) == f.c1)
        checkInvariants(outer)
    }

    // MARK: Ranges

    /// Delete Range / Cut Out: V1 closes; attached clips inside the range are kept and slide to the cut.
    @Test func deleteRangeSlidesAttachedToTheCut() throws {
        var f = F()
        let v1 = f.tl.tracks[0].id
        _ = try f.tl.magneticExtract(TimeRange(start: s(5), end: s(6)), tracks: [v1])
        #expect(mainSpans(f.tl) == [[0, 4], [4, 5], [5, 7], [7, 11]])
        #expect(attachTime(f.tl, f.title) == d(s(5) - fd))   // on its host's last frame before the cut
        #expect(f.tl.find(f.title) != nil)
        checkInvariants(f.tl)
    }

    /// Clear Range with V1 in range: Replace with Spacer for that range.
    @Test func clearRangeLeavesASpacer() throws {
        var f = F()
        let v1 = f.tl.tracks[0].id
        try f.tl.magneticClearRange(TimeRange(start: s(5), end: s(6)), tracks: [v1])
        #expect(mainSpans(f.tl) == [[0, 4], [4, 5], [6, 8], [8, 12]])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(host(f.tl, f.title) == f.c2)
        checkInvariants(f.tl, holes: true)
    }

    // MARK: Engine rules

    /// Collisions of attached clips: the later one goes to the nearest free track, never overwriting.
    @Test func collidingAttachedClipGoesToTheNearestFreeTrack() throws {
        var f = F()
        let x = Clip(name: "x", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(2.5),
                     mediaDuration: s(100))
        try f.tl.tracks[1].overwrite(x)                    // V2: x 2.5-4.5 (on c1), title 4.5-6.5 (on c2)
        f.tl.deriveAttachments()
        try f.tl.magneticRippleTrim(f.c1, edge: .tail, by: s(-1))
        #expect(span(f.tl, x.id) == [2.5, 4.5])            // c1 keeps its start
        #expect(trackOf(f.tl, x.id) == 1)
        #expect(span(f.tl, f.title) == [3.5, 5.5])
        #expect(trackOf(f.tl, f.title) != 1)
        #expect(f.tl.tracks[trackOf(f.tl, f.title)!].kind == .video)
        checkInvariants(f.tl)
    }

    /// A linked attached group (b-roll with its sound, J-cut) keeps its internal offsets.
    @Test func linkedAttachedGroupKeepsItsOffsets() throws {
        var f = F()
        let link = UUID()
        let broll = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: s(9),
                         link: link, mediaDuration: s(100))
        let sound = Clip(name: "b", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(2)), start: s(8.5),
                         link: link, mediaDuration: s(100))
        f.tl.tracks.append(Track(kind: .video, clips: [broll]))
        f.tl.tracks.append(Track(kind: .audio, clips: [sound]))
        f.tl.deriveAttachments()
        #expect(host(f.tl, broll.id) == f.c3)
        try f.tl.magneticDelete([f.c2])
        #expect(span(f.tl, broll.id) == [5, 6])
        #expect(span(f.tl, sound.id) == [4.5, 6.5])
        checkInvariants(f.tl)
    }

    /// Sync lock has no meaning in Fast Cut: attachments decide who follows.
    @Test func syncLockOffDoesNotStopFollowers() throws {
        var f = F()
        for i in f.tl.tracks.indices { f.tl.tracks[i].syncLock = false }
        try f.tl.magneticDelete([f.c1])
        #expect(span(f.tl, f.title) == [0.5, 2.5])
        #expect(f.tl.tracks.allSatisfy { !$0.syncLock })   // the flags are kept for Normal mode
        checkInvariants(f.tl)
    }

    /// An attached clip on a locked track stays put.
    @Test func attachedClipOnALockedTrackStays() throws {
        var f = F()
        f.tl.tracks[1].isLocked = true
        try f.tl.magneticDelete([f.c1])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
    }

    // Normal mode, verb by verb against its Normal counterpart: MagneticEditFixTests.normalVerbsEqualTheirCounterparts.

    /// Undo is the snapshot from before the op, byte-identical; redo the edited bytes; a refused op changes nothing.
    @Test func undoIsAByteIdenticalSnapshot() throws {
        let f = F()
        let before = try encoded(f.tl)
        var h = History(f.tl)
        try h.commit("Delete") { try $0.magneticDelete([f.c2]) }
        let after = try encoded(h.current)
        #expect(after != before)
        h.undo()
        #expect(try encoded(h.current) == before)
        #expect(h.current == f.tl)
        h.redo()
        #expect(try encoded(h.current) == after)
        var locked = f.tl
        locked.tracks[0].isLocked = true
        let lockedBytes = try encoded(locked)
        #expect(throws: EditError.trackLocked) { try locked.magneticDelete([f.c2]) }
        #expect(try encoded(locked) == lockedBytes)
    }
}
