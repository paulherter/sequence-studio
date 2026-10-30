import Foundation
import Testing
@testable import SQCore

// Fast Cut model (ClipAttachment.swift): edit mode, main track, attachment validity and derivation, id remapping.
//
// V1: c1 2-5 | c2 5-8 | hole 8-10 | c3 10-13
// V2: lead 0-1 (leading hole), t1 6-7 (on c2), t2 9-9.5 (hole after c2), tail 14-15 (after the last clip)
// V3: broll 3.5-4.5, linked with music on A2 3-6 (group attach time 3 -> c1)
// A1: c1Sound 2-5, linked with c1 (camera audio: part of the main track)

private func s(_ x: Double) -> Time { Time(Int64(x * 10), 10) }

private struct Fixture {
    var tl: Timeline
    let c1 = UUID(), c2 = UUID(), c3 = UUID(), c1Sound = UUID()
    let lead = UUID(), t1 = UUID(), t2 = UUID(), tail = UUID(), broll = UUID(), music = UUID()

    init() {
        let camLink = UUID(), rollLink = UUID()
        func clip(_ id: UUID, _ kind: TrackKind, _ start: Double, _ len: Double, link: UUID? = nil) -> Clip {
            Clip(id: id, name: "x", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(len)),
                 start: s(start), link: link, mediaDuration: s(100))
        }
        let v1 = Track(kind: .video, clips: [clip(c1, .video, 2, 3, link: camLink), clip(c2, .video, 5, 3), clip(c3, .video, 10, 3)])
        let v2 = Track(kind: .video, clips: [clip(lead, .video, 0, 1), clip(t1, .video, 6, 1), clip(t2, .video, 9, 0.5),
                                             clip(tail, .video, 14, 1)])
        let v3 = Track(kind: .video, clips: [clip(broll, .video, 3.5, 1, link: rollLink)])
        let a1 = Track(kind: .audio, clips: [clip(c1Sound, .audio, 2, 3, link: camLink)])
        let a2 = Track(kind: .audio, clips: [clip(music, .audio, 3, 3, link: rollLink)])
        tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [v1, v2, v3, a1, a2])
    }

    func clip(_ id: UUID) -> Clip { tl.find(id)!.clip }
    func att(_ id: UUID) -> ClipAttachment? { clip(id).attachment }
    func positions(_ t: Timeline) -> [[Clip.ID: TimeRange]] {
        t.tracks.map { Dictionary(uniqueKeysWithValues: $0.clips.map { ($0.id, $0.timeline) }) }
    }

    mutating func set(_ id: UUID, _ a: ClipAttachment?) {
        let ti = tl.find(id)!.track
        tl.tracks[ti].mapClipsKeepingTiming { c in var c = c; if c.id == id { c.attachment = a }; return c }
    }
}

@Suite struct ClipAttachmentTests {
    // MARK: Types and coding

    @Test func attachmentCodesOnlyWhenSet() throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: .zero)
        #expect(!String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("attachment"))
        c.attachment = ClipAttachment(host: UUID(), point: s(0.5))
        let back = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(c))
        #expect(back == c)
        #expect(back.attachment == c.attachment)
    }

    @Test func editModeDefaultsToNormalAndCodesOnlyWhenMagnetic() throws {
        var t = Timeline(name: "S", frameDuration: Time(1, 30))
        #expect(t.editMode == .normal)
        #expect(!String(decoding: try JSONEncoder().encode(t), as: UTF8.self).contains("editMode"))
        t.editMode = .magnetic
        let data = try JSONEncoder().encode(t)
        #expect(String(decoding: data, as: UTF8.self).contains("\"editMode\":\"magnetic\""))
        #expect(try JSONDecoder().decode(Timeline.self, from: data).editMode == .magnetic)
        t.editMode = .normal
        #expect(t == Timeline(id: t.id, name: "S", frameDuration: Time(1, 30)))
    }

    // MARK: Main track

    @Test func mainTrackIsTheFirstVideoTrackEvenWhenEmpty() {
        var f = Fixture()
        #expect(f.tl.mainTrackID == f.tl.tracks[0].id)
        f.tl.tracks.insert(Track(kind: .video), at: 0)
        #expect(f.tl.mainTrackID == f.tl.tracks[0].id)
        #expect(f.tl.mainTrackIndex == 0)
        #expect(Timeline(name: "A", frameDuration: Time(1, 30), tracks: [Track(kind: .audio)]).mainTrackID == nil)
    }

    @Test func attachableExcludesMainTrackAndCameraAudio() {
        let f = Fixture()
        #expect(!f.tl.isAttachable(f.c1))
        #expect(!f.tl.isAttachable(f.c1Sound))
        #expect(f.tl.isAttachable(f.t1))
        #expect(f.tl.isAttachable(f.music))
        #expect(!f.tl.isAttachable(UUID()))
    }

    @Test func attachHostRule() {
        let f = Fixture()
        #expect(f.tl.attachHost(at: s(0)) == f.c1)      // leading hole: the first clip
        #expect(f.tl.attachHost(at: s(2)) == f.c1)
        #expect(f.tl.attachHost(at: s(5)) == f.c2)      // a cut belongs to the clip that starts there
        #expect(f.tl.attachHost(at: s(9)) == f.c2)      // hole: the clip before it
        #expect(f.tl.attachHost(at: s(20)) == f.c3)     // after the last clip
        var empty = f.tl
        empty.tracks[0] = Track(kind: .video)
        #expect(empty.attachHost(at: s(3)) == nil)
    }

    // MARK: Validity

    @Test func validityFollowsThePositions() {
        var f = Fixture()
        #expect(!f.tl.isAttachmentValid(f.t1))                                  // none stored
        f.set(f.t1, ClipAttachment(host: f.c2))
        #expect(f.tl.isAttachmentValid(f.t1))                                   // on the host
        f.set(f.t1, ClipAttachment(host: f.c1))
        #expect(!f.tl.isAttachmentValid(f.t1))                                  // on another clip
        f.set(f.t2, ClipAttachment(host: f.c2))
        #expect(f.tl.isAttachmentValid(f.t2))                                   // the hole after the host
        f.set(f.t2, ClipAttachment(host: f.c3))
        #expect(!f.tl.isAttachmentValid(f.t2))                                  // the hole before the host
        f.set(f.lead, ClipAttachment(host: f.c1))
        #expect(f.tl.isAttachmentValid(f.lead))                                 // leading hole: first clip
        f.set(f.tail, ClipAttachment(host: f.c3))
        #expect(f.tl.isAttachmentValid(f.tail))                                 // after the last clip
        f.set(f.t1, ClipAttachment(host: UUID()))
        #expect(!f.tl.isAttachmentValid(f.t1))                                  // host gone
        f.set(f.t1, ClipAttachment(host: f.t2))
        #expect(!f.tl.isAttachmentValid(f.t1))                                  // host not on the main track
        f.set(f.t1, ClipAttachment(host: f.c2, point: s(2)))
        #expect(!f.tl.isAttachmentValid(f.t1))                                  // point past the clip's end
        f.set(f.t1, ClipAttachment(host: f.c2, point: s(1)))
        #expect(f.tl.isAttachmentValid(f.t1))                                   // point at the clip's end
        f.set(f.t1, ClipAttachment(host: f.c2, point: s(-0.5)))
        #expect(!f.tl.isAttachmentValid(f.t1))                                  // point before the clip
        f.set(f.c1Sound, ClipAttachment(host: f.c1))
        #expect(!f.tl.isAttachmentValid(f.c1Sound))                             // camera audio never attaches
    }

    @Test func linkedGroupMustAgree() {
        var f = Fixture()
        f.set(f.music, ClipAttachment(host: f.c1, point: .zero))                 // attach time 3
        f.set(f.broll, ClipAttachment(host: f.c1, point: s(-0.5)))               // 3.5 - 0.5 = 3
        #expect(f.tl.isAttachmentValid(f.music) && f.tl.isAttachmentValid(f.broll))
        f.set(f.broll, ClipAttachment(host: f.c1, point: .zero))                 // 3.5: disagrees
        #expect(!f.tl.isAttachmentValid(f.music) && !f.tl.isAttachmentValid(f.broll))
        f.set(f.broll, nil)
        #expect(!f.tl.isAttachmentValid(f.music))
    }

    // MARK: Derivation

    @Test func deriveFromPositions() {
        var f = Fixture()
        let before = f.positions(f.tl)
        f.tl.deriveAttachments()
        #expect(f.positions(f.tl) == before)
        #expect(f.att(f.lead) == ClipAttachment(host: f.c1, point: .zero))
        #expect(f.att(f.t1) == ClipAttachment(host: f.c2, point: .zero))
        #expect(f.att(f.t2) == ClipAttachment(host: f.c2, point: .zero))
        #expect(f.att(f.tail) == ClipAttachment(host: f.c3, point: .zero))
        #expect(f.att(f.music) == ClipAttachment(host: f.c1, point: .zero))
        #expect(f.att(f.broll) == ClipAttachment(host: f.c1, point: s(-0.5)))
        #expect(f.att(f.c1) == nil && f.att(f.c2) == nil && f.att(f.c1Sound) == nil)
        for id in [f.lead, f.t1, f.t2, f.tail, f.music, f.broll] { #expect(f.tl.isAttachmentValid(id)) }
    }

    @Test func deriveKeepsValidAndRederivesInvalidKeepingThePoint() {
        var f = Fixture()
        f.set(f.t1, ClipAttachment(host: f.c2, point: s(0.5)))                  // valid, not point 0
        f.set(f.t2, ClipAttachment(host: f.c1, point: s(0.25)))                 // wrong host
        f.set(f.lead, ClipAttachment(host: UUID(), point: s(5)))                // gone host, point outside the clip
        f.set(f.c2, ClipAttachment(host: f.c1))                                 // main-track clip
        f.set(f.c1Sound, ClipAttachment(host: f.c1))                            // camera audio
        f.tl.deriveAttachments()
        #expect(f.att(f.t1) == ClipAttachment(host: f.c2, point: s(0.5)))
        #expect(f.att(f.t2) == ClipAttachment(host: f.c2, point: s(0.25)))
        #expect(f.att(f.lead) == ClipAttachment(host: f.c1, point: .zero))
        #expect(f.att(f.c2) == nil)
        #expect(f.att(f.c1Sound) == nil)
    }

    @Test func deriveKeepsAGroupsStoredAttachTime() {
        var f = Fixture()
        f.set(f.broll, ClipAttachment(host: UUID(), point: s(0.5)))             // attach time 4, inside the group span
        f.tl.deriveAttachments()
        #expect(f.att(f.broll) == ClipAttachment(host: f.c1, point: s(0.5)))
        #expect(f.att(f.music) == ClipAttachment(host: f.c1, point: s(1)))
    }

    @Test func deriveAfterAMoveRehosts() {
        var f = Fixture()
        f.tl.deriveAttachments()
        // Normal-mode move of t1 over c3: the stored attachment stays (invalid) until the next derive.
        let ti = f.tl.find(f.t1)!.track, t1 = f.t1
        f.tl.tracks[ti].mapClipsKeepingTiming { c in var c = c; if c.id == t1 { c.start = s(11) }; return c }
        #expect(f.att(f.t1)?.host == f.c2)
        #expect(!f.tl.isAttachmentValid(f.t1))
        f.tl.deriveAttachments()
        #expect(f.att(f.t1) == ClipAttachment(host: f.c3, point: .zero))
    }

    @Test func deriveWithEmptyMainTrackDropsEverything() {
        var f = Fixture()
        f.tl.deriveAttachments()
        f.tl.tracks[0] = Track(kind: .video)
        f.tl.deriveAttachments()
        #expect(f.tl.tracks.flatMap(\.clips).allSatisfy { $0.attachment == nil })
    }

    // MARK: Mode switching

    @Test func switchingModesMovesNoClipAndIsOneUndoStep() throws {
        let f = Fixture()
        var p = Project(name: "P", timelines: [f.tl])
        let id = f.tl.id
        var h = History(p)
        try h.commit("Fast Cut") { try $0.setEditMode(.magnetic, of: id) }
        p = h.current
        let on = try #require(p.timeline(id))
        #expect(on.editMode == .magnetic)
        #expect(f.positions(on) == f.positions(f.tl))
        #expect(on.tracks.map { $0.clips.map(\.source) } == f.tl.tracks.map { $0.clips.map(\.source) })
        #expect(on.tracks.flatMap(\.clips).contains { $0.attachment != nil })
        let undone = h.undo()
        #expect(undone)
        #expect(h.current.timeline(id) == f.tl)
        let redone = h.redo()
        #expect(redone)
        try h.commit("Normal") { try $0.setEditMode(.normal, of: id) }
        let off = try #require(h.current.timeline(id))
        #expect(off.editMode == .normal)
        #expect(f.positions(off) == f.positions(f.tl))
        #expect(off.tracks.flatMap(\.clips).map(\.attachment) == on.tracks.flatMap(\.clips).map(\.attachment))   // kept
        #expect(throws: EditError.timelineNotFound) { try p.setEditMode(.magnetic, of: UUID()) }
    }

    // MARK: Id remapping

    @Test func duplicateRemapsHostsWithinTheCopyAndDropsTheRest() throws {
        var f = Fixture()
        f.tl.deriveAttachments()
        // c3 with tail (attached to c3): the copy of tail follows the copy of c3.
        let made = try f.tl.duplicate([f.c3, f.tail])
        let copies = made.map { f.tl.find($0)!.clip }
        let c3Copy = try #require(copies.first { $0.start == s(15) && f.tl.find($0.id)!.track == 0 })
        let tailCopy = try #require(copies.first { $0.id != c3Copy.id })
        #expect(tailCopy.attachment?.host == c3Copy.id)
        // A title copied without its host loses the attachment.
        let alone = try f.tl.duplicate([f.t1])
        #expect(f.tl.find(alone[0])!.clip.attachment == nil)
        #expect(f.att(f.t1)?.host == f.c2)
    }

    @Test func pasteRemapsHosts() throws {
        var f = Fixture()
        f.tl.deriveAttachments()
        let cb = try #require(f.tl.clipboard(copying: [f.c2, f.t1]))
        var other = Timeline(name: "O", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video)])
        let made = try other.paste(cb, at: .zero)
        let clips = made.map { other.find($0)!.clip }
        let host = try #require(clips.first { other.find($0.id)!.track == 0 })
        let title = try #require(clips.first { $0.id != host.id })
        #expect(title.attachment == ClipAttachment(host: host.id, point: .zero))
    }

    @Test func duplicateSequenceRemapsHosts() throws {
        var f = Fixture()
        f.tl.setEditMode(.magnetic)
        var p = Project(name: "P", timelines: [f.tl])
        let copyID = try p.duplicateSequence(f.tl.id, as: f.tl.format, mode: .fit)
        let copy = try #require(p.timeline(copyID))
        #expect(copy.editMode == .magnetic)
        let oldIDs = Set(f.tl.tracks.flatMap(\.clips).map(\.id))
        for c in copy.tracks.flatMap(\.clips) {
            #expect(!oldIDs.contains(c.id))
            if let a = c.attachment { #expect(!oldIDs.contains(a.host)) }
        }
        for c in copy.tracks.flatMap(\.clips) where c.attachment != nil { #expect(copy.isAttachmentValid(c.id)) }
        let copied: Int = copy.tracks.flatMap(\.clips).filter { $0.attachment != nil }.count
        let original: Int = f.tl.tracks.flatMap(\.clips).filter { $0.attachment != nil }.count
        #expect(copied == original)
    }

    @Test func nestRehostsOuterClipsAndDropsInnerHostsOutside() throws {
        var f = Fixture()
        f.tl.deriveAttachments()
        var p = Project(name: "P", timelines: [f.tl])
        // Nest c2 with t1 (both attached to c2 inside); t2 (attached to c2) stays outside and moves to the nested clip.
        let seqID = try p.nest(clips: [f.c2, f.t1], in: f.tl.id)
        let outer = try #require(p.timeline(f.tl.id))
        let inner = try #require(p.timeline(seqID))
        let nested = try #require(outer.tracks[0].clips.first { $0.sequence == seqID })
        #expect(outer.find(f.t2)!.clip.attachment?.host == nested.id)     // was on c2, now on the nested clip
        #expect(outer.isAttachmentValid(f.t2))
        #expect(inner.find(f.t1)!.clip.attachment?.host == f.c2)          // host nested along: kept
        var g = Fixture()
        g.tl.deriveAttachments()
        var q = Project(name: "Q", timelines: [g.tl])
        let seq2 = try q.nest(clips: [g.t1], in: g.tl.id)
        #expect(q.timeline(seq2)!.find(g.t1)!.clip.attachment == nil)    // host left outside: dropped
    }

    @Test func titleTemplateInstanceRemapsHosts() throws {
        var f = Fixture()
        f.tl.deriveAttachments()
        let tmpl = TitleTemplate(name: "T", content: f.tl)
        let (inner, _) = tmpl.instantiated()
        let ids = Set(inner.tracks.flatMap(\.clips).map(\.id))
        let attached = inner.tracks.flatMap(\.clips).filter { $0.attachment != nil }
        #expect(!attached.isEmpty)
        #expect(attached.allSatisfy { ids.contains($0.attachment!.host) })
    }
}
