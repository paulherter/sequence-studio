import Foundation
import Testing
@testable import SQCore

// Fast Cut 1B review fixes (Timeline+Magnetic.swift, Timeline+MagneticOps.swift).
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

    /// Adds `c` to track `index` (no attachment check; the edits derive them).
    mutating func add(_ c: Clip, track index: Int) {
        tl.tracks[index].setClips(tl.tracks[index].clips + [c])
    }
}

private func span(_ tl: Timeline, _ id: Clip.ID) -> [Double]? {
    tl.find(id).map { [d($0.clip.start), d($0.clip.timeline.end)] }
}
private func trackOf(_ tl: Timeline, _ id: Clip.ID) -> Int? { tl.find(id)?.track }
private func main(_ tl: Timeline) -> [Clip] { tl.tracks[tl.mainTrackIndex!].clips }
private func mainSpans(_ tl: Timeline) -> [[Double]] { main(tl).map { [d($0.start), d($0.timeline.end)] } }
private func encoded(_ tl: Timeline) throws -> Data {
    let e = JSONEncoder(); e.outputFormatting = .sortedKeys
    return try e.encode(tl)
}
private func noHole(_ tl: Timeline) -> Bool {
    let m = main(tl)
    return (m.first.map { $0.start == .zero } ?? true) && zip(m, m.dropFirst()).allSatisfy { $0.timeline.end == $1.start }
}

/// The encoded timeline with every UUID replaced by its order of first appearance: byte equality up to the fresh ids
/// an edit makes (cut halves, pasted copies, new links).
private func canonical(_ tl: Timeline) throws -> String {
    let text = String(decoding: try encoded(tl), as: UTF8.self)
    let re = try NSRegularExpression(pattern: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
    var names: [String: String] = [:]
    var out = "", last = text.startIndex
    for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let r = Range(m.range, in: text)!
        let id = String(text[r])
        if names[id] == nil { names[id] = "#\(names.count)" }
        out += text[last..<r.lowerBound] + names[id]!
        last = r.upperBound
    }
    return out + text[last...]
}

/// Runs `a` and `b` on copies of `tl`; both must throw, or both must give byte-identical timelines.
private func same(_ tl: Timeline, _ a: (inout Timeline) throws -> Void, _ b: (inout Timeline) throws -> Void,
                  sourceLocation: SourceLocation = #_sourceLocation) throws {
    var x = tl, y = tl
    let ex: Error?, ey: Error?
    do { try a(&x); ex = nil } catch { ex = error }
    do { try b(&y); ey = nil } catch { ey = error }
    #expect((ex == nil) == (ey == nil), "one threw: \(String(describing: ex)) / \(String(describing: ey))", sourceLocation: sourceLocation)
    if ex == nil, ey == nil { #expect(try canonical(x) == canonical(y), sourceLocation: sourceLocation) }
}

@Suite struct MagneticEditFixTests {
    // MARK: 1. Attached clips see their track neighbors

    /// x 8-9, y 9-10, z 10-11 on V2, attached to c3.
    private func xyz() -> (F, x: UUID, y: UUID, z: UUID) {
        var f = F()
        let x = UUID(), y = UUID(), z = UUID()
        f.add(clip(x, .video, 8, 1), track: 1)
        f.add(clip(y, .video, 9, 1), track: 1)
        f.add(clip(z, .video, 10, 1), track: 1)
        f.tl.deriveAttachments()
        return (f, x, y, z)
    }

    private func othersUnchanged(_ f: F, _ before: Timeline) {
        #expect(mainSpans(f.tl) == mainSpans(before))
        for id in [f.title, f.music, f.c1a] {
            #expect(span(f.tl, id) == span(before, id))
            #expect(trackOf(f.tl, id) == trackOf(before, id))
        }
    }

    @Test func rollAttachedClipWithItsNeighbour() throws {
        var (f, x, y, z) = xyz()
        let before = f.tl
        let moved = try f.tl.magneticRoll(x, by: s(0.5))
        #expect(moved == s(0.5))
        #expect(span(f.tl, x) == [8, 9.5])
        #expect(span(f.tl, y) == [9.5, 10])
        #expect(span(f.tl, z) == [10, 11])
        #expect([x, y, z].allSatisfy { trackOf(f.tl, $0) == 1 })
        othersUnchanged(f, before)
    }

    @Test func slideAttachedClipTrimsBothNeighbours() throws {
        var (f, x, y, z) = xyz()
        let before = f.tl
        try f.tl.magneticSlide(y, by: s(0.5))
        #expect(span(f.tl, x) == [8, 9.5])
        #expect(span(f.tl, y) == [9.5, 10.5])
        #expect(span(f.tl, z) == [10.5, 11])
        #expect([x, y, z].allSatisfy { trackOf(f.tl, $0) == 1 })
        othersUnchanged(f, before)
    }

    @Test func trimAttachedTailIsClampedByItsNeighbour() throws {
        var (f, x, y, z) = xyz()
        let before = f.tl
        let moved = try f.tl.magneticRippleTrim(x, edge: .tail, by: s(0.5))
        #expect(moved == .zero)
        #expect(span(f.tl, x) == [8, 9])
        #expect(span(f.tl, y) == [9, 10])
        #expect([x, y, z].allSatisfy { trackOf(f.tl, $0) == 1 })
        othersUnchanged(f, before)
    }

    @Test func nudgeAttachedClipCutsItsNeighbourLikeNormal() throws {
        var (f, x, y, z) = xyz()
        let before = f.tl
        try f.tl.magneticNudge([y], by: s(0.5))
        #expect(span(f.tl, x) == [8, 9])
        #expect(span(f.tl, y) == [9.5, 10.5])
        #expect(span(f.tl, z) == [10.5, 11])
        #expect([x, y, z].allSatisfy { trackOf(f.tl, $0) == 1 })
        othersUnchanged(f, before)
    }

    /// A group that stays (keep attached) keeps its track; a moved group landing on its spot goes elsewhere.
    @Test func unmovedGroupKeepsItsTrack() throws {
        var f = F()
        let u = UUID()
        f.add(clip(u, .video, 9, 1), track: 1)                       // attached to c3, stays (keep attached)
        f.tl.deriveAttachments()
        try f.tl.magneticRearrange(f.c3, to: .zero, keepAttached: true)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(span(f.tl, u) == [9, 10])
        #expect(trackOf(f.tl, u) == 1)
        #expect(span(f.tl, f.title) == [8.5, 10.5])                 // follows c2 (+4)
        #expect(trackOf(f.tl, f.title) != 1)
    }

    // MARK: 2. Nudge of adjacent main clips moves them as one block

    @Test func nudgeAdjacentMainClipsMovesThemAsABlock() throws {
        var f = F()
        try f.tl.magneticNudge([f.c2, f.c3], by: s(1))
        #expect(mainSpans(f.tl) == [[0, 5], [5, 9], [9, 13]])
        #expect(span(f.tl, f.c2) == [5, 9])
        #expect(span(f.tl, f.title) == [5.5, 7.5])
        #expect(span(f.tl, f.music) == [1, 7])
        #expect(noHole(f.tl))
    }

    @Test func nudgeAdjacentMainClipsLeft() throws {
        var f = F()
        try f.tl.magneticNudge([f.c2, f.c3], by: s(-1))
        #expect(mainSpans(f.tl) == [[0, 3], [3, 7], [7, 11]])
        #expect(noHole(f.tl))
    }

    /// An attached clip selected with its host goes along once, not twice.
    @Test func nudgeHostWithItsAttachedClipMovesItOnce() throws {
        var f = F()
        try f.tl.magneticNudge([f.c2, f.title], by: s(1))
        #expect(span(f.tl, f.title) == [5.5, 7.5])
    }

    // MARK: 3. No hole at the head of V1

    @Test func nudgeFirstMainClipRightIsClamped() throws {
        var f = F()
        let before = try encoded(f.tl)
        try f.tl.magneticNudge([f.c1], by: s(1))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(noHole(f.tl))
        #expect(try encoded(f.tl) == before)
    }

    @Test func slideFirstMainClipRightIsClamped() throws {
        var f = F()
        let moved = try f.tl.magneticSlide(f.c1, by: s(1))
        #expect(moved == .zero)
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
        #expect(span(f.tl, f.c1a) == [0, 4])
    }

    @Test func nudgeWholeMainTrackRightIsClamped() throws {
        var f = F()
        try f.tl.magneticNudge([f.c1, f.c2, f.c3], by: s(1))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12]])
    }

    // MARK: 4. Paste / duplicate of non-adjacent main clips: contiguous on V1

    @Test func duplicateNonAdjacentMainClipsStaysContiguous() throws {
        var f = F()
        let w = UUID()
        f.add(clip(w, .video, 9, 1), track: 1)                       // attached to c3 at 9
        f.tl.deriveAttachments()
        let made = try f.tl.magneticDuplicate([f.c1, f.c3])
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12], [12, 16], [16, 20]])
        #expect(noHole(f.tl))
        // Attached copies keep their point relative to their copied host.
        let copies = made.compactMap { f.tl.find($0)?.clip }
        let musicCopy = copies.first { $0.kind == .audio && $0.timeline.duration == s(6) }
        #expect(musicCopy.map { d($0.start) } == 13)
        let wCopy = copies.first { $0.kind == .video && $0.timeline.duration == s(1) }
        #expect(wCopy.map { d($0.start) } == 17)
    }

    @Test func pasteNonAdjacentMainClipsStaysContiguous() throws {
        var f = F()
        let cb = try #require(f.tl.magneticClipboard(copying: [f.c1, f.c3]))
        _ = try f.tl.magneticPaste(cb, at: s(4))
        #expect(mainSpans(f.tl) == [[0, 4], [4, 8], [8, 12], [12, 16], [16, 20]])
        #expect(noHole(f.tl))
    }

    // MARK: 5. Linked group across a locked and an unlocked track keeps its offset

    @Test func lockedLinkedGroupKeepsItsOffset() throws {
        var f = F()
        let l = UUID(), broll = UUID(), sound = UUID()
        f.tl.tracks.insert(Track(kind: .video, clips: [clip(broll, .video, 9, 1, link: l)]), at: 2)   // V3
        f.tl.tracks.append(Track(kind: .audio, clips: [clip(sound, .audio, 8.5, 2, link: l)]))      // A3
        f.tl.tracks[2].isLocked = true
        f.tl.deriveAttachments()
        try f.tl.magneticDelete([f.c1])
        let b = try #require(f.tl.find(broll)?.clip), a = try #require(f.tl.find(sound)?.clip)
        #expect(b.start - a.start == s(0.5))
        #expect(span(f.tl, broll) == [9, 10])
    }

    // MARK: 6. Normal fallbacks are the Normal verbs, byte for byte

    @Test func normalVerbsEqualTheirCounterparts() throws {
        var f = F()
        f.tl.editMode = .normal
        let tl = f.tl
        let v1 = tl.tracks[0].id, v2 = tl.tracks[1].id, a1 = tl.tracks[2].id, a2 = tl.tracks[3].id
        try same(tl, { try $0.magneticDelete([f.c2]) }, { try $0.lift([f.c2]) })
        try same(tl, { try $0.magneticDelete([f.c2], keepAttached: true) }, { try $0.lift([f.c2]) })
        try same(tl, { try $0.replaceWithSpacer([f.c2]) }, { try $0.lift([f.c2]) })
        var gap = tl
        try gap.lift([f.c2])
        try same(gap, { _ = try $0.deleteSpacer(at: s(5)) }, { _ = try $0.closeGap(on: v1, at: s(5)) })
        try same(tl, { _ = try $0.magneticRippleTrim(f.c2, edge: .tail, by: s(-1)) },
                 { _ = try $0.rippleTrim(f.c2, edge: .tail, by: s(-1)) })
        try same(tl, { _ = try $0.magneticRippleTrim(f.title, edge: .tail, by: s(1)) },
                 { _ = try $0.rippleTrim(f.title, edge: .tail, by: s(1)) })
        try same(tl, { _ = try $0.magneticRippleTrimToPlayhead(.head, at: s(5), tracks: [v1]) },
                 { _ = try $0.rippleTrimToPlayheadOutcome(.head, at: s(5), tracks: [v1]) })
        try same(tl, { _ = try $0.magneticRoll(f.c2, by: s(0.5)) }, { _ = try $0.roll(f.c2, by: s(0.5)) })
        try same(tl, { _ = try $0.magneticSlip(f.c2, by: s(0.5)) }, { _ = try $0.slip(f.c2, by: s(0.5)) })
        try same(tl, { _ = try $0.magneticSlide(f.c2, by: s(0.5)) }, { _ = try $0.slide(f.c2, by: s(0.5)) })
        try same(tl, { _ = try $0.magneticSlide(f.c1, by: s(0.5)) }, { _ = try $0.slide(f.c1, by: s(0.5)) })
        try same(tl, { try $0.magneticNudge([f.c2, f.c3], by: s(1)) }, { _ = try $0.nudge([f.c2, f.c3], by: s(1)) })
        try same(tl, { _ = try $0.magneticAddEdit(at: s(5), selection: []) }, { _ = try $0.addEdit(at: s(5), selection: []) })
        try same(tl, { _ = try $0.magneticAddEdit(at: s(5), selection: [f.title]) },
                 { _ = try $0.addEdit(at: s(5), selection: [f.title]) })
        try same(tl, { _ = try $0.magneticAddEditAll(at: s(5)) }, { _ = try $0.addEdit(at: s(5), tracks: nil) })
        var cut = tl
        _ = try cut.addEdit(at: s(5), tracks: nil)
        try same(cut, { _ = try $0.magneticJoin() }, { _ = try $0.joinThroughEdits() })
        try same(tl, { try $0.magneticRearrange(f.c3, to: .zero) }, { _ = try $0.move(f.c3, to: .zero) })
        try same(tl, { try $0.magneticRearrange(f.c2, to: s(13)) }, { _ = try $0.move(f.c2, to: s(13)) })
        try same(tl, { try $0.moveAttached(f.title, to: s(9), track: v2) }, { _ = try $0.move(f.title, to: s(9), track: v2) })
        try same(tl, { try $0.liftOffMainTrack([f.c2]) }, { _ = try $0.moveToLane([f.c2], up: true) })
        try same(tl, { try $0.dragOffMainTrack(f.c3, to: v2, at: s(13)) }, { _ = try $0.move(f.c3, to: s(13), track: v2) })
        try same(tl, { try $0.dragOntoMainTrack(f.title, at: s(13)) }, { _ = try $0.move(f.title, to: s(13), track: v1) })
        try same(tl, { try $0.putOnMainTrack([f.title]) }, { _ = try $0.move(f.title, to: s(4.5), track: v1) })

        // Source edits go to the targeted tracks, like a Normal insert / overwrite.
        var targeted = tl
        targeted.tracks[1].isTargeted = true
        targeted.tracks[3].isTargeted = true
        let pkg = sourcePackage(2)
        try same(targeted, { _ = try $0.insertOnMainTrack(pkg, at: s(5)) },
                 { try $0.insert(pkg.map { ($0, $0.kind == .video ? v2 : a2) }, at: s(5)) })
        try same(targeted, { _ = try $0.overwriteOnMainTrack(pkg, at: s(5)) },
                 { try $0.overwrite(pkg.map { ($0, $0.kind == .video ? v2 : a2) }, at: s(5)) })
        try same(tl, { _ = try $0.insertOnMainTrack(pkg, at: s(5)) },
                 { try $0.insert(pkg.map { ($0, $0.kind == .video ? v1 : a1) }, at: s(5)) })
        let audioOnly = sourcePackage(2, video: false)
        try same(targeted, { _ = try $0.insertOnMainTrack(audioOnly, at: s(5)) },
                 { try $0.insert(audioOnly.map { ($0, a2) }, at: s(5)) })

        let cb = try #require(tl.clipboard(copying: [f.c2]))
        #expect(tl.magneticClipboard(copying: [f.c2]) == cb)
        try same(tl, { _ = try $0.magneticPaste(cb, at: s(13)) }, { _ = try $0.paste(cb, at: s(13)) })
        let r = TimeRange(start: s(5), duration: s(1))
        try same(tl, { _ = try $0.magneticExtract(r, tracks: [v1]) }, { _ = try $0.extractOutcome(r, tracks: [v1]) })
        try same(tl, { try $0.magneticClearRange(r, tracks: [v1]) }, { try $0.lift(r, tracks: [v1]) })
        // Engine: no main-track rules in Normal.
        try same(tl, { _ = try $0.magneticEdit(involving: [f.c1]) { _ = try $0.rippleDelete([f.c1]) } },
                 { _ = try $0.rippleDelete([f.c1]) })
    }

    /// Duplicate in Normal: `duplicate` (ids differ per run, so compare the layout).
    @Test func normalDuplicateIsDuplicate() throws {
        var f = F()
        f.tl.editMode = .normal
        var a = f.tl, b = f.tl
        _ = try a.magneticDuplicate([f.c2])
        _ = try b.duplicate([f.c2])
        #expect(a.tracks.map { $0.clips.map { [d($0.start), d($0.timeline.end)] } }
                == b.tracks.map { $0.clips.map { [d($0.start), d($0.timeline.end)] } })
    }

    /// Undo restores the exact bytes, redo the edited bytes.
    @Test func undoAndRedoAreByteIdentical() throws {
        let f = F()
        let before = try encoded(f.tl)
        var h = History(f.tl)
        try h.commit("Nudge") { try $0.magneticNudge([f.c2, f.c3], by: s(1)) }
        let after = try encoded(h.current)
        #expect(after != before)
        h.undo()
        #expect(try encoded(h.current) == before)
        #expect(h.current == f.tl)
        h.redo()
        #expect(try encoded(h.current) == after)
    }

    // MARK: Fuzz finds: Fast Cut ripple trim keeps every linked pair together

    /// V1 c1 0-4 | c2 4-8 | c3 8-12, each linked to its audio on A1: c1a 0-4, c2a 4-7 (trimmed short), x 7-7.5 (a stray
    /// piece of c1's audio, L cut), c3a 7-12 (J cut, starts 1s before c3).
    private func pairs() -> (Timeline, c1: UUID, c2: UUID, c3: UUID, c2a: UUID, x: UUID, c3a: UUID) {
        let l1 = UUID(), l2 = UUID(), l3 = UUID()
        let c1 = UUID(), c2 = UUID(), c3 = UUID(), c1a = UUID(), c2a = UUID(), x = UUID(), c3a = UUID()
        let v1 = Track(kind: .video, clips: [clip(c1, .video, 0, 4, link: l1), clip(c2, .video, 4, 4, link: l2),
                                             clip(c3, .video, 8, 4, link: l3)])
        let a1 = Track(kind: .audio, clips: [clip(c1a, .audio, 0, 4, link: l1), clip(c2a, .audio, 4, 3, link: l2),
                                             clip(x, .audio, 7.5, 0.5, link: l1)])
        let a2 = Track(kind: .audio, clips: [clip(c3a, .audio, 7, 5, link: l3)])
        var tl = Timeline(name: "S", frameDuration: fd, tracks: [v1, a1, a2])
        tl.editMode = .magnetic
        return (tl, c1, c2, c3, c2a, x, c3a)
    }

    @Test func rippleTrimTailOfMainClipMovesOnlyLaterPairs() throws {
        var (tl, _, c2, _, c2a, x, c3a) = pairs()
        try tl.magneticRippleTrim(c2, edge: .tail, by: s(1))
        #expect(mainSpans(tl) == [[0, 4], [4, 9], [9, 13]])
        #expect(span(tl, c2a) == [4, 7])          // ends before c2's tail: not trimmed
        #expect(span(tl, x) == [7.5, 8])          // c1's piece: c1 did not move
        #expect(span(tl, c3a) == [8, 13])         // goes with c3
    }

    @Test func rippleTrimHeadOfMainClipTrimsAllPartners() throws {
        var (tl, _, c2, _, c2a, x, c3a) = pairs()
        try tl.magneticRippleTrim(c2, edge: .head, by: s(1))
        #expect(mainSpans(tl) == [[0, 4], [4, 7], [7, 11]])
        #expect(span(tl, c2a) == [4, 6])
        #expect(tl.find(c2a)!.clip.source.start == s(11))
        #expect(span(tl, x) == [7.5, 8])
        #expect(span(tl, c3a) == [6, 11])
    }
}

private func sourcePackage(_ len: Double, video: Bool = true) -> [Clip] {
    let link: UUID? = video ? UUID() : nil, media = UUID()
    var out: [Clip] = []
    if video { out.append(Clip(name: "src", media: media, kind: .video, source: TimeRange(start: .zero, duration: s(len)), start: .zero, link: link, mediaDuration: s(100))) }
    out.append(Clip(name: "src", media: media, kind: .audio, source: TimeRange(start: .zero, duration: s(len)), start: .zero, link: link, mediaDuration: s(100)))
    return out
}
