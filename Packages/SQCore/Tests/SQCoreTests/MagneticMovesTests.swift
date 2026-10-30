import Foundation
import Testing
@testable import SQCore

// Fast Cut phase 2 review fixes (Timeline+MagneticMoves.swift): gap close on an attached lane, copies, several main-track
// clips dragged at once, and a Fast Cut clipboard pasted into a Normal sequence.
//
// V1: c1 0-4 (linked with c1a) | c2 4-8 | c3 8-12
// V2: title 4.5-6.5, attached to c2 at point 1 (attach time 5.5)
// A1: c1a 0-4 (camera audio of c1)
// A2: music 1-7, attached to c1 at point 0 (attach time 1)

private func s(_ x: Double) -> Time { Time(Int64((x * 30).rounded()), 30) }
private let fd = Time(1, 30)
private func d(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

private func clip(_ id: UUID, _ kind: TrackKind, _ start: Double, _ len: Double, link: UUID? = nil, media: UUID = UUID(),
                  attach: (UUID, Double)? = nil) -> Clip {
    var c = Clip(id: id, name: "x", media: media, kind: kind, source: TimeRange(start: s(10), duration: s(len)),
                 start: s(start), link: link, mediaDuration: s(100))
    if let attach { c.attachment = ClipAttachment(host: attach.0, point: s(attach.1)) }
    return c
}

private struct F {
    var tl: Timeline
    let c1 = UUID(), c2 = UUID(), c3 = UUID(), c1a = UUID(), title = UUID(), music = UUID()

    init() {
        let cam = UUID(), camMedia = UUID()
        let v1 = Track(kind: .video, clips: [clip(c1, .video, 0, 4, link: cam, media: camMedia), clip(c2, .video, 4, 4),
                                             clip(c3, .video, 8, 4)])
        let v2 = Track(kind: .video, clips: [clip(title, .video, 4.5, 2, attach: (c2, 1))])
        let a1 = Track(kind: .audio, clips: [clip(c1a, .audio, 0, 4, link: cam, media: camMedia)])
        let a2 = Track(kind: .audio, clips: [clip(music, .audio, 1, 6, attach: (c1, 0))])
        tl = Timeline(name: "S", frameDuration: fd, tracks: [v1, v2, a1, a2])
        tl.editMode = .magnetic
    }

    mutating func add(_ c: Clip, track index: Int) {
        tl.tracks[index].setClips(tl.tracks[index].clips + [c])
    }
}

private func span(_ tl: Timeline, _ id: Clip.ID) -> [Double]? {
    tl.find(id).map { [d($0.clip.start), d($0.clip.timeline.end)] }
}
private func trackOf(_ tl: Timeline, _ id: Clip.ID) -> Int? { tl.find(id)?.track }
private func main(_ tl: Timeline) -> [Clip] { tl.tracks[tl.mainTrackIndex!].clips }
private func mainIDs(_ tl: Timeline) -> [Clip.ID] { main(tl).map(\.id) }
private func noHole(_ tl: Timeline) -> Bool {
    let m = main(tl)
    return (m.first.map { $0.start == .zero } ?? true) && zip(m, m.dropFirst()).allSatisfy { $0.timeline.end == $1.start }
}

@Suite struct MagneticMovesTests {
    // MARK: Gap close on an attached lane

    @Test func closingAGapOnAnAttachedLaneMovesOnlyThatLane() throws {
        var f = F()
        let late = UUID()
        f.add(clip(late, .video, 9, 1), track: 1)
        f.tl.deriveAttachments()
        let before = f.tl
        let closed = try f.tl.closeLaneGap(on: f.tl.tracks[1].id, at: s(7.5))
        #expect(closed == s(2.5))
        #expect(span(f.tl, late) == [6.5, 7.5])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(main(f.tl) == main(before))                     // V1 never ripples
        #expect(span(f.tl, f.c1a) == span(before, f.c1a))       // nor the camera audio
        #expect(span(f.tl, f.music) == span(before, f.music))
    }

    @Test func closingALaneGapTakesTheLinkedPartnerOffV1Along() throws {
        var f = F()
        let v = UUID(), a = UUID(), l = UUID()
        f.add(clip(v, .video, 9, 1, link: l), track: 1)
        f.tl.tracks.append(Track(kind: .audio, clips: [clip(a, .audio, 9, 1, link: l)]))
        f.tl.deriveAttachments()
        try f.tl.closeLaneGap(on: f.tl.tracks[1].id, at: s(7.5))
        #expect(span(f.tl, v) == [6.5, 7.5])
        #expect(span(f.tl, a) == [6.5, 7.5])
        #expect(mainIDs(f.tl) == [f.c1, f.c2, f.c3])
    }

    @Test func closeLaneGapInNormalIsCloseGap() throws {
        var f = F()
        f.tl.editMode = .normal
        let late = UUID()
        f.add(clip(late, .video, 9, 1), track: 1)
        var a = f.tl, b = f.tl
        try a.closeLaneGap(on: f.tl.tracks[1].id, at: s(7.5))
        try b.closeGap(on: f.tl.tracks[1].id, at: s(7.5))
        #expect(a == b)
    }

    // MARK: Copies

    private func copy(_ id: Clip.ID, track: Track.ID? = nil, partners: [Clip.ID: Track.ID] = [:],
                      ids: [Clip.ID: Clip.ID]) -> MagneticCopy {
        MagneticCopy(clip: id, track: track, partners: partners, spec: CopySpec(ids: ids, link: UUID()))
    }

    @Test func copyOfAMainClipPastTheEndOfV1IsAppendedWithoutAHole() throws {
        var f = F()
        let v = UUID(), a = UUID()
        let made = try f.tl.magneticCopy([copy(f.c1, ids: [f.c1: v, f.c1a: a])], by: s(30))
        #expect(Set(made) == [v, a])
        #expect(mainIDs(f.tl) == [f.c1, f.c2, f.c3, v])
        #expect(span(f.tl, v) == [12, 16])
        #expect(span(f.tl, a) == [12, 16])                     // its sound comes along, linked
        #expect(f.tl.find(v)?.clip.link == f.tl.find(a)?.clip.link)
        #expect(noHole(f.tl))
    }

    @Test func copyOfAMainClipInsertsAtTheNearestEditAndAttachedFollow() throws {
        var f = F()
        let v = UUID()
        try f.tl.magneticCopy([copy(f.c3, ids: [f.c3: v])], by: s(-4.5))   // start 3.5 -> nearest edit 4
        #expect(mainIDs(f.tl) == [f.c1, v, f.c2, f.c3])
        #expect(span(f.tl, v) == [4, 8])
        #expect(span(f.tl, f.title) == [8.5, 10.5])             // follows c2
        #expect(span(f.tl, f.c3) == [12, 16])
        #expect(noHole(f.tl))
    }

    @Test func copyOfAnAttachedClipAttachesWhereItLands() throws {
        var f = F()
        let before = f.tl
        let t = UUID()
        try f.tl.magneticCopy([copy(f.title, ids: [f.title: t])], by: s(4))
        #expect(span(f.tl, t) == [8.5, 10.5])
        #expect(trackOf(f.tl, t) == 1)
        #expect(f.tl.find(t)?.clip.attachment?.host == f.c3)
        #expect(main(f.tl) == main(before))
        #expect(span(f.tl, f.title) == [4.5, 6.5])
    }

    @Test func copyOfAMainClipOntoAnotherTrackNeverCutsV1() throws {
        var f = F()
        let before = f.tl
        let v = UUID()
        try f.tl.magneticCopy([copy(f.c3, track: f.tl.tracks[1].id, ids: [f.c3: v])], by: s(-7))
        #expect(main(f.tl) == main(before))
        #expect(span(f.tl, v) == [1, 5])
        #expect(trackOf(f.tl, v) != 0)
        #expect(f.tl.find(v)?.clip.attachment?.host == f.c1)
    }

    @Test func copyOfAnAttachedClipOntoV1Inserts() throws {
        var f = F()
        let t = UUID()
        try f.tl.magneticCopy([copy(f.title, track: f.tl.mainTrackID, ids: [f.title: t])], by: s(3.7))   // 8.2 -> edit 8
        #expect(mainIDs(f.tl) == [f.c1, f.c2, t, f.c3])
        #expect(span(f.tl, t) == [8, 10])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(noHole(f.tl))
    }

    @Test func copyOfSeveralMainClipsPacksThemIntoOneRun() throws {
        var f = F()
        let v1 = UUID(), a1 = UUID(), v3 = UUID(), t = UUID()
        // c1 and c3 (not adjacent) with c2's title copied along by the same distance (it rides on c2: not copied host).
        try f.tl.magneticCopy([copy(f.c1, ids: [f.c1: v1, f.c1a: a1]), copy(f.c3, ids: [f.c3: v3]),
                               copy(f.title, ids: [f.title: t])], by: s(12))
        #expect(mainIDs(f.tl) == [f.c1, f.c2, f.c3, v1, v3])
        #expect(span(f.tl, v1) == [12, 16])
        #expect(span(f.tl, v3) == [16, 20])
        #expect(noHole(f.tl))
        #expect(trackOf(f.tl, t) != 0)
    }

    @Test func copyInNormalIsTheOverwriteCopy() throws {
        var f = F()
        f.tl.editMode = .normal
        let v = UUID()
        var a = f.tl, b = f.tl
        try a.magneticCopy([copy(f.c2, ids: [f.c2: v])], by: s(10))
        try b.move(f.c2, to: s(14), copy: CopySpec(ids: [f.c2: v], link: UUID()))
        #expect(a.tracks.map { $0.clips.map(\.timeline) } == b.tracks.map { $0.clips.map(\.timeline) })
        #expect(span(a, v) == [14, 18])
    }

    // MARK: Several main clips dragged at once

    @Test func blockRearrangeMovesTheSelectionAsOneRun() throws {
        var f = F()
        try f.tl.magneticRearrangeBlock([f.c1, f.c2], by: s(10.2), keepAttached: false)   // start 10.2 -> edit 12 (end)
        #expect(mainIDs(f.tl) == [f.c3, f.c1, f.c2])
        #expect(span(f.tl, f.c3) == [0, 4])
        #expect(span(f.tl, f.c1) == [4, 8])
        #expect(span(f.tl, f.c1a) == [4, 8])
        #expect(span(f.tl, f.title) == [8.5, 10.5])             // travels with c2
        #expect(span(f.tl, f.music) == [5, 11])                 // travels with c1
        #expect(noHole(f.tl))
    }

    @Test func blockRearrangeOfSeparateClipsClosesBothHoles() throws {
        var f = F()
        try f.tl.magneticRearrangeBlock([f.c1, f.c3], by: s(-1), keepAttached: false)   // start -1 -> edit 0
        #expect(mainIDs(f.tl) == [f.c1, f.c3, f.c2])
        #expect(span(f.tl, f.c2) == [8, 12])
        #expect(span(f.tl, f.title) == [8.5, 10.5])
        #expect(noHole(f.tl))
    }

    @Test func blockRearrangeFarPastTheEndLeavesNoHole() throws {
        var f = F()
        try f.tl.magneticRearrangeBlock([f.c1, f.c2, f.c3], by: s(100), keepAttached: false)
        #expect(mainIDs(f.tl) == [f.c1, f.c2, f.c3])
        #expect(noHole(f.tl))
    }

    @Test func blockRearrangeKeepAttachedLeavesAttachedClipsOnTheirFrame() throws {
        var f = F()
        try f.tl.magneticRearrangeBlock([f.c1, f.c2], by: s(10.2), keepAttached: true)
        #expect(mainIDs(f.tl) == [f.c3, f.c1, f.c2])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(span(f.tl, f.music) == [1, 7])
    }

    @Test func blockDragOffClosesV1AndAttachesTheClips() throws {
        var f = F()
        let v2 = f.tl.tracks[1].id
        try f.tl.dragOffMainTrack([f.c2, f.c3], to: v2, by: .zero, keepAttached: false)
        #expect(mainIDs(f.tl) == [f.c1])
        #expect(noHole(f.tl))
        #expect(trackOf(f.tl, f.c2) != 0 && trackOf(f.tl, f.c3) != 0)
        #expect(f.tl.find(f.c2)?.clip.attachment?.host == f.c1)
    }

    // MARK: Clipboard into Normal

    @Test func fastCutClipboardPastedIntoNormalCarriesNoAttachments() throws {
        let f = F()
        let cb = try #require(f.tl.magneticClipboard(copying: [f.c2]))
        #expect(cb.entries.contains { $0.clip.attachment != nil })
        var normal = Timeline(name: "N", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .video),
                                                                     Track(kind: .audio)])
        let made = try normal.magneticPaste(cb, at: .zero)
        #expect(!made.isEmpty)
        #expect(!normal.hasAttachments)
        #expect(!cb.strippingAttachments().entries.contains { $0.clip.attachment != nil })
    }

    // MARK: Trim to playhead, speed, rate stretch

    @Test func plainTrimToPlayheadOnV1RipplesInsteadOfLeavingAHole() throws {
        var f = F()
        try f.tl.magneticTrimToPlayhead(.tail, at: s(6), mode: .plain)   // c2 4-8 -> 4-6; title (5.5) under 6 too
        #expect(span(f.tl, f.c2) == [4, 6])
        #expect(span(f.tl, f.c3) == [6, 10])
        #expect(noHole(f.tl))
        #expect(span(f.tl, f.title) == [4.5, 6])                // the attached clip under the playhead is trimmed alone
        #expect(f.tl.find(f.title)?.clip.attachment?.host == f.c2)
    }

    @Test func plainTrimToPlayheadInNormalLeavesTheGap() throws {
        var f = F()
        f.tl.editMode = .normal
        var a = f.tl, b = f.tl
        try a.magneticTrimToPlayhead(.tail, at: s(6), mode: .plain)
        try b.trimToPlayhead(.tail, at: s(6), tracks: nil, mode: .plain)
        #expect(a == b)
    }

    @Test func speedOnAMainClipRipplesV1WithoutTheRippleSetting() throws {
        var f = F()
        try f.tl.magneticApply(SpeedChange(speed: ClipSpeed(percent: 200)), to: [f.c2])
        #expect(span(f.tl, f.c2) == [4, 6])
        #expect(span(f.tl, f.c3) == [6, 10])
        #expect(noHole(f.tl))
        #expect(f.tl.find(f.title)?.clip.attachment?.host == f.c2)
    }

    @Test func slowerMainClipPushesLaterClipsInsteadOfTruncating() throws {
        var f = F()
        try f.tl.magneticApply(SpeedChange(speed: ClipSpeed(percent: 50)), to: [f.c2])
        #expect(span(f.tl, f.c2) == [4, 12])
        #expect(span(f.tl, f.c3) == [12, 16])
        #expect(noHole(f.tl))
    }

    @Test func reverseOnAnAttachedClipMovesNothingElse() throws {
        var f = F()
        let before = f.tl
        try f.tl.magneticApply(SpeedChange(reversed: true), to: [f.title])
        #expect(f.tl.find(f.title)?.clip.reversed == true)
        #expect(main(f.tl) == main(before))
        #expect(span(f.tl, f.title) == [4.5, 6.5])
    }

    @Test func rateStretchOfAMainClipClosesV1() throws {
        var f = F()
        let moved = try f.tl.magneticRateStretch(f.c2, edge: .tail, by: s(-2))
        #expect(moved == s(-2))
        #expect(span(f.tl, f.c2) == [4, 6])
        #expect(span(f.tl, f.c3) == [6, 10])
        #expect(noHole(f.tl))
    }

    @Test func rateStretchOfAMainClipGrowsByPushingLaterClips() throws {
        var f = F()
        try f.tl.magneticRateStretch(f.c2, edge: .head, by: s(-2))     // head dragged left: 2 s longer, start stays
        #expect(span(f.tl, f.c2) == [4, 10])
        #expect(span(f.tl, f.c3) == [10, 14])
        #expect(noHole(f.tl))
    }

    // MARK: Speed ramp edits

    private func constant(_ percent: Double,_ out: Double) -> (SpeedKeys) -> SpeedKeys? {
        { _ in SpeedKeys(constant: ClipSpeed(percent: percent), reversed: false, duration: s(out), origin: s(10)) }
    }

    @Test func speedRampThatShortensAMainClipClosesV1() throws {
        var f = F()
        let change = try f.tl.magneticEditSpeedKeys(f.c2, constant(200, 2))
        #expect(change == s(-2))
        #expect(span(f.tl, f.c2) == [4, 6])
        #expect(span(f.tl, f.c3) == [6, 10])
        #expect(noHole(f.tl))
        #expect(span(f.tl, f.title) == [4.5, 6.5])      // attached clip stays on its host
    }

    @Test func speedRampThatLengthensAMainClipPushesLaterClips() throws {
        var f = F()
        let change = try f.tl.magneticEditSpeedKeys(f.c2, constant(50, 8))
        #expect(change == s(4))
        #expect(span(f.tl, f.c2) == [4, 12])
        #expect(span(f.tl, f.c3) == [12, 16])
        #expect(noHole(f.tl))
    }

    @Test func speedRampOnMainClipWithLinkedAudioMovesThePartnerAlong() throws {
        var f = F()
        try f.tl.magneticEditSpeedKeys(f.c1, constant(200, 2))
        #expect(span(f.tl, f.c1) == [0, 2])
        #expect(span(f.tl, f.c1a) == [0, 2])
        #expect(span(f.tl, f.c2) == [2, 6])
        #expect(noHole(f.tl))
    }

    @Test func speedRampOnAnAttachedClipRipplesNothing() throws {
        var f = F()
        try f.tl.magneticEditSpeedKeys(f.title, constant(200, 1))
        #expect(span(f.tl, f.title) == [4.5, 5.5])
        #expect(span(f.tl, f.c3) == [8, 12])
        #expect(noHole(f.tl))
    }

    // MARK: Frame hold

    @Test func insertFrameHoldOnAMainClipKeepsV1GaplessAndAttachmentsOnTheirHosts() throws {
        var f = F()
        _ = try f.tl.magneticInsertFrameHold(of: f.c2, at: s(5), duration: s(2))
        #expect(noHole(f.tl))
        #expect(d(f.tl.mainTrackEnd) == 14)
        #expect(span(f.tl, f.c3) == [10, 14])
        #expect(span(f.tl, f.title) == [4.5, 6.5])      // its content frame (host at 5.5) sits before the cut
    }

    @Test func insertFrameHoldOnAnAttachedClipIsRefusedInFastCut() throws {
        var f = F()
        #expect(throws: EditError.self) { _ = try f.tl.magneticInsertFrameHold(of: f.title, at: s(5), duration: s(1)) }
    }

    @Test func addFrameHoldOnAMainClipMovesNothing() throws {
        var f = F()
        _ = try f.tl.magneticAddFrameHold(of: f.c2, at: s(5))
        #expect(noHole(f.tl))
        #expect(span(f.tl, f.c3) == [8, 12])
        #expect(span(f.tl, f.title) == [4.5, 6.5])
    }

    // MARK: Opt+Up / Opt+Down

    @Test func optDownOnAClipRightAboveV1PutsItOnTheMainTrack() throws {
        var f = F()
        #expect(try f.tl.magneticMoveToLane([f.title], up: false))
        #expect(trackOf(f.tl, f.title) == 0)
        #expect(span(f.tl, f.title) == [4.5, 6.5])
        #expect(trackOf(f.tl, f.music) == 3)                         // other clips stay
    }

    @Test func optDownKeepsTheLinkedPartnersOfAClipPutOnTheMainTrack() throws {
        var f = F()
        let link = UUID(), b = UUID(), ba = UUID()
        f.add(clip(b, .video, 9, 2, link: link, attach: (f.c3, 1)), track: 1)
        f.add(clip(ba, .audio, 9, 2, link: link, attach: (f.c3, 1)), track: 3)
        f.tl.tracks[3].setClips(f.tl.tracks[3].clips.filter { $0.id != f.music })
        #expect(try f.tl.magneticMoveToLane([b, ba], up: false))
        #expect(trackOf(f.tl, b) == 0)
        #expect(trackOf(f.tl, ba) == 3)
        #expect(span(f.tl, ba) == [9, 11])
    }

    @Test func optDownOnAMainClipMovesNothing() throws {
        var f = F()
        let before = f.tl
        #expect(try f.tl.magneticMoveToLane([f.c2], up: false) == false)
        #expect(f.tl == before)
    }

    @Test func optUpOnAMainClipLiftsItOff() throws {
        var f = F()
        #expect(try f.tl.magneticMoveToLane([f.c3], up: true))
        #expect(trackOf(f.tl, f.c3) == 1)
        #expect(f.tl.find(f.c3)?.clip.attachment != nil)
    }
}
