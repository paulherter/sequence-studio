import Foundation
import Testing
@testable import SQCore

// Regression tests for verified code-review findings in the edit core (trim mode, speed ripple, Time, Fast Cut derive).

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private let half = Time(1, 60)                              // half a frame: a clip shorter than one frame

private func clip(_ start: Time, frames dur: Time, from: Int64 = 30, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: dur), start: start,
         link: link, mediaDuration: f(3000))
}

private func timeline(_ tracks: [(TrackKind, [Clip])]) throws -> Timeline {
    var ts: [Track] = []
    for (k, cs) in tracks {
        var t = Track(kind: k)
        for c in cs { try t.overwrite(c) }
        ts.append(t)
    }
    return Timeline(name: "t", frameDuration: fd, tracks: ts)
}

@Suite struct EditCoreReviewFixTests {
    // MARK: trimEdit on a clip shorter than one frame

    @Test func trimOutgoingOnSubFrameClipDoesNotReverse() throws {
        let a = clip(.zero, frames: half), b = clip(half, frames: f(60))
        var t = try timeline([(.video, [a, b])])
        let before = t.tracks
        let p = try #require(t.nearestTrimPoint(to: half))
        let moved = try t.trimEdit(p, side: .outgoing, by: .zero - fd)      // shorten: must not lengthen instead
        #expect(moved == .zero)
        #expect(t.tracks == before)
    }

    @Test func trimIncomingOnSubFrameClipDoesNotReverse() throws {
        let a = clip(.zero, frames: f(60)), b = clip(f(60), frames: half)
        var t = try timeline([(.video, [a, b])])
        let before = t.tracks
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        let moved = try t.trimEdit(p, side: .incoming, by: fd)              // shorten the head: must not extend it
        #expect(moved == .zero)
        #expect(t.tracks == before)
    }

    @Test func rollTowardSubFrameClipDoesNotReverse() throws {
        let a = clip(.zero, frames: half), b = clip(half, frames: f(60))
        var t = try timeline([(.video, [a, b])])
        let before = t.tracks
        let p = try #require(t.nearestTrimPoint(to: half))
        let moved = try t.trimEdit(p, side: .roll, by: .zero - fd)          // earlier: must not roll later
        #expect(moved == .zero)
        #expect(t.tracks == before)

        let c = clip(.zero, frames: f(60)), d = clip(f(60), frames: half)
        var u = try timeline([(.video, [c, d])])
        let before2 = u.tracks
        let q = try #require(u.nearestTrimPoint(to: f(60)))
        #expect(try u.trimEdit(q, side: .roll, by: fd) == .zero)            // later: must not roll earlier
        #expect(u.tracks == before2)
    }

    // MARK: setSpeed ripple keeps split edits (J/L cuts) together

    @Test func speedRippleMovesStraddlingSplitEditPartner() throws {
        // V1: X 0-30 (retimed). V2: B 15-45 straddles the edit point 30. A1: B' 32-50, linked with B, starts after it.
        let link = UUID()
        let x = clip(.zero, frames: f(30), from: 0)
        let b = clip(f(15), frames: f(30), link: link)
        let bs = clip(f(32), frames: f(18), kind: .audio, link: link)
        var t = try timeline([(.video, [x]), (.video, [b]), (.audio, [bs])])
        let change = try t.setSpeed(x.id, to: ClipSpeed(percent: 50), ripple: true)
        #expect(change == f(30))
        let nb = try #require(t.find(b.id)?.clip), nbs = try #require(t.find(bs.id)?.clip)
        #expect(nbs.start == f(62))
        #expect(nb.start == f(45))                                           // follows its partner: sync kept
        #expect(nbs.start - nb.start == bs.start - b.start)
    }

    // MARK: Time with a zero frame duration

    @Test func frameIndexAndCeiledWithZeroFrameDurationDoNotTrap() {
        let t = Time(7, 30)
        #expect(t.frameIndex(frameDuration: .zero) == 0)
        #expect(t.ceiled(to: .zero) == t)
        #expect(t.snapped(to: .zero) == t)
    }

    // MARK: ColorEffect.setEnabled no-op

    @Test func colorEffectSetEnabledNoOpKeepsTheValue() {
        var c = ColorEffect(id: 1)
        let fresh = c
        c.setEnabled(.curves, true)
        #expect(c == fresh)
        c.setEnabled(.curves, false); c.setEnabled(.basicCorrection, false)
        let off = c
        c.setEnabled(.curves, false)
        #expect(c == off)
        #expect(c.disabled == ColorSectionKind.allCases.filter { $0 == .curves || $0 == .basicCorrection })
    }

    // MARK: deriveAttachments matches the per-clip reference on random timelines

    @Test func deriveAttachmentsMatchesReference() throws {
        var rng = LCG(seed: 0x5EED)
        for _ in 0..<200 {
            let t = randomTimeline(&rng)
            var fast = t
            fast.deriveAttachments()
            var ref = t
            referenceDerive(&ref)
            #expect(fast == ref)
        }
    }
}

// MARK: - Reference (the pre-index algorithm, through the public per-clip API)

private func referenceDerive(_ tl: inout Timeline) {
    guard let mi = tl.mainTrackIndex else {
        for i in tl.tracks.indices { tl.tracks[i].mapClipsKeepingTiming { var c = $0; c.attachment = nil; return c } }
        return
    }
    let mainLinks = Set(tl.tracks[mi].clips.compactMap(\.link))
    var decided: [Clip.ID: ClipAttachment?] = [:]
    var groups: [UUID: [Clip]] = [:], order: [UUID] = []
    for (i, t) in tl.tracks.enumerated() where i != mi {
        for c in t.clips {
            if let l = c.link, mainLinks.contains(l) { decided[c.id] = .some(nil); continue }
            let key = c.link ?? c.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(c)
        }
    }
    for key in order {
        let members = groups[key]!.sorted { $0.start < $1.start }
        if members.allSatisfy({ tl.isAttachmentValid($0.id) }) {
            for m in members { decided[m.id] = .some(m.attachment) }
            continue
        }
        let lo = members.map(\.start).min()!, hi = members.map { $0.timeline.end }.max()!
        let stored = members.lazy.compactMap { m in m.attachment.map { m.start + $0.point } }.first { $0 >= lo && $0 <= hi }
        let t = stored ?? lo
        let host = tl.attachHost(at: t)
        for m in members { decided[m.id] = .some(host.map { ClipAttachment(host: $0, point: t - m.start) }) }
    }
    for i in tl.tracks.indices {
        tl.tracks[i].mapClipsKeepingTiming { c in
            var c = c
            c.attachment = i == mi ? nil : (decided[c.id] ?? nil)
            return c
        }
    }
}

private struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
}

private func randomTimeline(_ rng: inout LCG) -> Timeline {
    let links = (0..<4).map { _ in UUID() }
    func s(_ x: Int) -> Time { Time(Int64(x), 2) }                         // half seconds
    func lane(_ kind: TrackKind, count: Int) -> [Clip] {
        var out: [Clip] = [], at = rng.next(3)
        for _ in 0..<count {
            let len = 1 + rng.next(4)
            let link: UUID? = rng.next(3) == 0 ? links[rng.next(links.count)] : nil
            out.append(Clip(name: "x", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(len)),
                            start: s(at), link: link, mediaDuration: s(100)))
            at += len + rng.next(3)
        }
        return out
    }
    let main = rng.next(6) == 0 ? [] : lane(.video, count: 1 + rng.next(5))
    var tracks = [Track(kind: .video, clips: main)]
    for k in [TrackKind.video, .video, .audio, .audio] { tracks.append(Track(kind: k, clips: lane(k, count: rng.next(5)))) }
    // Random attachments: a real host or a stranger, any point; some copied across a linked group so it can be valid.
    let hosts = main.map(\.id) + [UUID()]
    for i in 1..<tracks.count {
        tracks[i].mapClipsKeepingTiming { c in
            var c = c
            if rng.next(4) != 0 { c.attachment = ClipAttachment(host: hosts[rng.next(hosts.count)], point: s(rng.next(9) - 4)) }
            return c
        }
    }
    // Make some groups consistent (same host and attach time), so the valid branch runs too.
    for l in links where rng.next(2) == 0 {
        let members = tracks.indices.dropFirst().flatMap { i in tracks[i].clips.filter { $0.link == l } }
        guard let first = members.first, !main.isEmpty else { continue }
        let at = first.start, host = main[rng.next(main.count)].id
        for i in tracks.indices.dropFirst() {
            tracks[i].mapClipsKeepingTiming { c in
                var c = c
                if c.link == l { c.attachment = ClipAttachment(host: host, point: at - c.start) }
                return c
            }
        }
    }
    var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks)
    tl.editMode = .magnetic
    return tl
}
