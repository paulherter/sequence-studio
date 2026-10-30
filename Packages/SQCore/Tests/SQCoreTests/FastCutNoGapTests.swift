import Foundation
import Testing
@testable import SQCore

// Fast Cut: the main lane never has a gap except through the spacer verbs, and attached clips keep their offset to
// their host. One test per move path. Layout (30 fps):
// V1: a 0-4 | b 4-8 | c 8-12 | d 12-16, each with linked camera audio on A1
// V2: title attached to b (point 1), A2: music attached to c (point 0.5)

private func s(_ x: Double) -> Time { Time(Int64((x * 30).rounded()), 30) }
private let fd = Time(1, 30)

private struct G {
    var tl: Timeline
    let ids = (0..<4).map { _ in UUID() }
    let audio = (0..<4).map { _ in UUID() }
    let title = UUID(), music = UUID()
    var a: Clip.ID { ids[0] }
    var b: Clip.ID { ids[1] }
    var c: Clip.ID { ids[2] }
    var d: Clip.ID { ids[3] }

    init() {
        var v: [Clip] = [], au: [Clip] = []
        for i in 0..<4 {
            let link = UUID(), media = UUID()
            v.append(Clip(id: ids[i], name: "v\(i)", media: media, kind: .video, source: TimeRange(start: s(10), duration: s(4)),
                          start: s(Double(i * 4)), link: link, mediaDuration: s(100)))
            au.append(Clip(id: audio[i], name: "a\(i)", media: media, kind: .audio, source: TimeRange(start: s(10), duration: s(4)),
                           start: s(Double(i * 4)), link: link, mediaDuration: s(100)))
        }
        var t = Clip(id: title, name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)),
                     start: s(4.5), mediaDuration: s(50))
        t.attachment = ClipAttachment(host: ids[1], point: s(1))
        var m = Clip(id: music, name: "m", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(3)),
                     start: s(8), mediaDuration: s(50))
        m.attachment = ClipAttachment(host: ids[2], point: s(0.5))
        tl = Timeline(name: "G", frameDuration: fd, tracks: [Track(kind: .video, clips: v), Track(kind: .video, clips: [t]),
                                                           Track(kind: .audio, clips: au), Track(kind: .audio, clips: [m])])
        tl.editMode = .magnetic
    }
}

private func main(_ tl: Timeline) -> [Clip] { tl.tracks[tl.mainTrackIndex!].clips.sorted { $0.start < $1.start } }
private func gapFree(_ tl: Timeline) -> Bool {
    let m = main(tl)
    return (m.first.map { $0.start == .zero } ?? true) && zip(m, m.dropFirst()).allSatisfy { $0.timeline.end == $1.start }
}
private func layout(_ tl: Timeline) -> String {
    main(tl).map { "\(Double($0.start.value) / Double($0.start.timescale))+\(Double($0.timeline.duration.value) / Double($0.timeline.duration.timescale))" }.joined(separator: " ")
}
/// Attach time minus host start, for every attached clip.
/// Only hosts whose own content frame range is untouched are comparable: a head trim or cut legitimately moves the
/// attach offset because attached clips are anchored to a host frame.
private func offsets(_ tl: Timeline) -> [Clip.ID: [Time]] {
    var out: [Clip.ID: [Time]] = [:]
    for t in tl.tracks { for c in t.clips {
        guard tl.isAttachable(c.id), let a = c.attachment, let h = tl.find(a.host)?.clip else { continue }
        out[c.id] = [c.start + a.point - h.start, h.source.start, h.timeline.duration]
    } }
    return out
}

@Suite struct FastCutNoGapTests {
    private func check(_ name: String, _ g: G, keepsOffsets: Bool = true, _ edit: (inout Timeline) throws -> Void,
                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        var tl = g.tl
        let before = offsets(tl)
        try edit(&tl)
        #expect(gapFree(tl), "\(name): gap on V1: \(layout(tl))", sourceLocation: sourceLocation)
        let consistent = tl.tracks.allSatisfy { $0.isConsistent }
        #expect(consistent, "\(name): overlap", sourceLocation: sourceLocation)
        var d = tl; d.deriveAttachments()
        #expect(d == tl, "\(name): attachments not derived", sourceLocation: sourceLocation)
        if keepsOffsets {
            let after = offsets(tl)
            for (id, o) in before { if let n = after[id], n[1] == o[1], n[2] == o[2] { #expect(n[0] == o[0], "\(name): attach offset changed", sourceLocation: sourceLocation) } }
        }
    }

    @Test func dragLeft() throws { let g = G(); try check("left", g) { try $0.magneticRearrange(g.b, to: s(0)) } }
    @Test func dragLeftPastStart() throws { let g = G(); try check("left past", g) { try $0.magneticRearrange(g.b, to: s(-3)) } }
    @Test func dragRight() throws { let g = G(); try check("right", g) { try $0.magneticRearrange(g.a, to: s(9)) } }
    @Test func dragRightPastEnd() throws { let g = G(); try check("right past", g) { try $0.magneticRearrange(g.a, to: s(40)) } }
    @Test func dragBetweenTwo() throws { let g = G(); try check("between", g) { try $0.magneticRearrange(g.d, to: s(7.5)) } }
    @Test func dragOntoSelf() throws { let g = G(); try check("self", g) { try $0.magneticRearrange(g.b, to: s(4.7)) } }
    @Test func dragAudioPartner() throws { let g = G(); try check("audio", g) { try $0.magneticRearrange(g.audio[0], to: s(9)) } }
    @Test func dragKeepAttached() throws { let g = G(); try check("keep", g, keepsOffsets: false) { try $0.magneticRearrange(g.b, to: s(12), keepAttached: true) } }
    @Test func offAndBack() throws {
        let g = G()
        var tl = g.tl
        let v2 = tl.tracks[1].id
        try tl.dragOffMainTrack([g.b], to: v2, by: s(0))
        #expect(gapFree(tl), "off: \(layout(tl))"); #expect(!tl.isOnMainTrack(g.b))
        try tl.dragOntoMainTrack(g.b, at: s(8))
        #expect(gapFree(tl), "back: \(layout(tl))"); #expect(tl.isOnMainTrack(g.b))
    }
    @Test func dragOffSingle() throws {
        let g = G(); let v2 = g.tl.tracks[1].id
        try check("off", g, keepsOffsets: false) { try $0.dragOffMainTrack(g.a, to: v2, at: s(20)) }
    }
    @Test func nudgeLeft() throws { let g = G(); try check("nudge-", g) { try $0.magneticNudge([g.b], by: s(-0.5)) } }
    @Test func nudgeRight() throws { let g = G(); try check("nudge+", g) { try $0.magneticNudge([g.b], by: s(0.5)) } }
    @Test func nudgeFirst() throws { let g = G(); try check("nudge first", g) { try $0.magneticNudge([g.a], by: s(0.5)) } }
    @Test func nudgeLast() throws { let g = G(); try check("nudge last", g) { try $0.magneticNudge([g.d], by: s(0.5)) } }
    @Test func nudgeRun() throws { let g = G(); try check("nudge run", g) { try $0.magneticNudge([g.b, g.c], by: s(-0.5)) } }
    @Test func blockLeft() throws { let g = G(); try check("block left", g) { try $0.magneticRearrangeBlock([g.c, g.d], by: s(-9)) } }
    @Test func blockRight() throws { let g = G(); try check("block right", g) { try $0.magneticRearrangeBlock([g.a, g.b], by: s(11)) } }
    @Test func blockApart() throws { let g = G(); try check("block apart", g) { try $0.magneticRearrangeBlock([g.a, g.c], by: s(5)) } }
    @Test func blockOff() throws {
        let g = G(); let v2 = g.tl.tracks[1].id
        try check("block off", g, keepsOffsets: false) { try $0.dragOffMainTrack([g.a, g.c], to: v2, by: s(1)) }
    }
    @Test func deleteMiddle() throws { let g = G(); try check("delete", g) { try $0.magneticDelete([g.b]) } }
    @Test func deleteKeep() throws { let g = G(); try check("delete keep", g, keepsOffsets: false) { try $0.magneticDelete([g.b], keepAttached: true) } }
    @Test func deleteTwo() throws { let g = G(); try check("delete two", g) { try $0.magneticDelete([g.a, g.c]) } }
    @Test func deleteAudioOnly() throws { let g = G(); try check("delete audio", g) { try $0.magneticDelete([g.audio[1]]) } }
    @Test func pasteMiddle() throws {
        let g = G()
        try check("paste", g) { tl in
            let cb = try #require(tl.magneticClipboard(copying: [g.a]))
            _ = try tl.magneticPaste(cb, at: s(5))
        }
    }
    @Test func pasteTwoApart() throws {
        let g = G()
        try check("paste apart", g) { tl in
            let cb = try #require(tl.magneticClipboard(copying: [g.a, g.c]))
            _ = try tl.magneticPaste(cb, at: s(30))
        }
    }
    private func newClip() -> Clip {
        Clip(name: "n", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(3)), start: .zero, mediaDuration: s(10))
    }
    @Test func projectDropMiddle() throws { let g = G(); try check("drop", g) { _ = try $0.insertOnMainTrack([newClip()], at: s(5)) } }
    @Test func projectDropFarPast() throws { let g = G(); try check("drop far", g) { _ = try $0.insertOnMainTrack([newClip()], at: s(60)) } }
    @Test func projectOverwrite() throws { let g = G(); try check("overwrite", g, keepsOffsets: false) { _ = try $0.overwriteOnMainTrack([newClip()], at: s(5)) } }
    @Test func trimHeadShorter() throws { let g = G(); try check("trim head -", g) { _ = try $0.magneticRippleTrim(g.b, edge: .head, by: s(1)) } }
    @Test func trimHeadLonger() throws { let g = G(); try check("trim head +", g) { _ = try $0.magneticRippleTrim(g.b, edge: .head, by: s(-1)) } }
    @Test func trimTailShorter() throws { let g = G(); try check("trim tail -", g) { _ = try $0.magneticRippleTrim(g.b, edge: .tail, by: s(-1)) } }
    @Test func trimTailLonger() throws { let g = G(); try check("trim tail +", g) { _ = try $0.magneticRippleTrim(g.b, edge: .tail, by: s(1)) } }
    @Test func trimFirstHead() throws { let g = G(); try check("trim first head", g) { _ = try $0.magneticRippleTrim(g.a, edge: .head, by: s(1)) } }
    @Test func speedUp() throws { let g = G(); try check("speed", g) { try $0.magneticApply(SpeedChange(duration: s(2)), to: [g.b]) } }
    @Test func speedDown() throws { let g = G(); try check("slow", g) { try $0.magneticApply(SpeedChange(duration: s(6)), to: [g.b]) } }
    @Test func rateStretch() throws { let g = G(); try check("stretch", g) { _ = try $0.magneticRateStretch(g.b, edge: .tail, by: s(1)) } }
    // Moving up a lane is a lift (spacer verb): the hole is deliberate, so only overlap/attachments are checked.
    @Test func moveToLaneUpLeavesSpacer() throws {
        var tl = G().tl; let g = G()
        tl = g.tl
        _ = try tl.magneticMoveToLane([g.b], up: true)
        let consistent = tl.tracks.allSatisfy { $0.isConsistent }
        #expect(consistent)
    }
    @Test func overwriteFarPast() throws { let g = G(); try check("overwrite far", g, keepsOffsets: false) { _ = try $0.overwriteOnMainTrack([newClip()], at: s(90)) } }
    @Test func liftOffAndPutBack() throws {
        let g = G()
        var tl = g.tl
        try tl.liftOffMainTrack([g.b])
        try tl.putOnMainTrack([g.b])
        #expect(gapFree(tl), "lift+put: \(layout(tl))")
    }
}
