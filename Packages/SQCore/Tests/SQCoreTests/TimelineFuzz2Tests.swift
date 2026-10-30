import Foundation
import Testing
@testable import SQCore

/// Second edit-core fuzz: speed, rate stretch, nudge, duplicate, frame holds, transitions, lanes, gaps and extend edits on
/// top of the basic trims (TimelineFuzzTests). After every operation (and the transition prune `Project.edit` runs) the
/// timeline must stay valid, a refused edit must change nothing, transitions must point at clips of their own track, and
/// evaluation (video layers, audio segments) must not trap and must stay inside the timeline.
@Suite struct TimelineFuzz2Tests {
    typealias LCG = TimelineFuzzTests.LCG
    static let fd = TimelineFuzzTests.fd

    static func extraProblems(_ t: Timeline, rng: inout LCG) -> [String] {
        var out = TimelineFuzzTests.problems(t)
        for (i, tr) in t.tracks.enumerated() {
            let ids = Set(tr.clips.map(\.id))
            for x in tr.transitions {
                if let o = x.outgoing, !ids.contains(o) { out.append("track \(i): transition outgoing clip missing") }
                if let n = x.incoming, !ids.contains(n) { out.append("track \(i): transition incoming clip missing") }
                if x.outgoing == nil && x.incoming == nil { out.append("track \(i): transition without clips") }
                if x.duration <= .zero { out.append("track \(i): empty transition") }
            }
        }
        let end = t.duration
        guard end > .zero else { return out }
        let all = TimeRange(start: .zero, duration: end)
        for s in t.audioSegments(in: all) {
            if s.timeline.duration <= .zero { out.append("audio segment of zero length") }
            if s.timeline.start < .zero || s.timeline.end > end { out.append("audio segment outside the timeline") }
        }
        for _ in 0..<4 {
            let at = fd * Int64(rng.int(Int(max(1, end.frameIndex(frameDuration: fd)))))
            _ = t.videoLayers(at: at)
            let r = TimeRange(start: at, duration: fd * Int64(1 + rng.int(30)))
            for s in t.audioSegments(in: r) where !(s.timeline.start >= r.start && s.timeline.end <= r.end) {
                out.append("audio segment \(s.timeline) outside the queried range \(r)")
            }
        }
        return out
    }

    @Test(arguments: Array(1...UInt64(Soak.count(quick: 10, full: 30))))
    func richEditSequencesKeepTheTimelineValid(seed: UInt64) throws {
        var rng = LCG(s: seed &* 104_729)
        var t = try TimelineFuzzTests.start(seed: seed)
        var log: [String] = []
        var applied = 0
        for step in 0..<200 {
            let before = t
            let clips = t.tracks.flatMap(\.clips)
            guard let c = clips.isEmpty ? nil : clips[rng.int(clips.count)] else { break }
            let other = clips[rng.int(clips.count)]
            let d = rng.time(maxFrames: 30, fd: Self.fd)
            let at = Self.fd * Int64(rng.int(200))
            let track = t.tracks[rng.int(t.tracks.count)]
            var name = ""
            do {
                switch rng.int(16) {
                case 0:
                    let p = [25.0, 50, 100, 150, 200, 400][rng.int(6)]
                    let rev = rng.int(3) == 0, ripple = rng.int(2) == 0
                    name = "speed \(p)% rev \(rev) ripple \(ripple)"
                    _ = try t.setSpeed(c.id, to: ClipSpeed(percent: p), reversed: rev, ripple: ripple)
                case 1: name = "rate stretch tail \(d)"; _ = try t.rateStretch(c.id, edge: .tail, by: d)
                case 2: name = "rate stretch head \(d)"; _ = try t.rateStretch(c.id, edge: .head, by: d)
                case 3: name = "nudge \(d)"; _ = try t.nudge([c.id], by: d)
                case 4: name = "duplicate"; _ = try t.duplicate(Set([c.id]))
                case 5: name = "frame hold at \(at)"; _ = try t.addFrameHold(of: c.id, at: c.start + Self.fd * Int64(rng.int(10)))
                case 6:
                    name = "insert frame hold at \(at)"
                    _ = try t.insertFrameHold(of: c.id, at: c.start + Self.fd * Int64(rng.int(10)), duration: Self.fd * Int64(1 + rng.int(20)))
                case 7:
                    let tr = t.tracks.first { $0.clips.contains { $0.id == c.id } }!
                    let kind: TransitionKind = tr.kind == .audio ? .constantPower : [.crossDissolve, .dipToBlack, .push][rng.int(3)]
                    let i = tr.clips.firstIndex { $0.id == c.id }!
                    let point: TransitionPoint = i + 1 < tr.clips.count && rng.int(2) == 0
                        ? .cut(outgoing: c.id, incoming: tr.clips[i + 1].id) : (rng.int(2) == 0 ? .head(c.id) : .tail(c.id))
                    name = "transition \(kind) \(point)"
                    _ = try t.addTransition(point: point, kind: kind, track: tr.id, duration: Self.fd * Int64(1 + rng.int(30)))
                case 8:
                    let xs = t.tracks.flatMap(\.transitions); guard !xs.isEmpty else { continue }; let x = xs[rng.int(xs.count)]
                    name = "remove transition"; try t.removeTransition(x.id)
                case 9: name = "insert move to \(at)"; try t.insertMove(c.id, to: at)
                case 10: name = "close gap \(at)"; _ = try t.closeGap(on: track.id, at: at)
                case 11: name = "extend tail to \(at)"; _ = try t.extendEdit(c.id, edge: .tail, to: at)
                case 12: name = "extend head to \(at)"; _ = try t.extendEdit(c.id, edge: .head, to: at)
                case 13: name = "lane \(rng.int(2) == 0)"; _ = try t.moveToLane([c.id], up: rng.int(2) == 0)
                case 14: name = "lift \(other.name)"; try t.lift([other.id])
                default: name = "add edit selection at \(at)"; _ = try t.addEdit(at: c.start + Self.fd * Int64(1 + rng.int(20)), selection: [c.id])
                }
                t.pruneTransitions()
                log.append("\(step): \(name) ok")
                applied += 1
            } catch {
                log.append("\(step): \(name) refused \(error)")
                #expect(t == before, "seed \(seed) step \(step) \(name): a refused edit changed the timeline")
                t = before
            }
            let p = Self.extraProblems(t, rng: &rng)
            #expect(p.isEmpty, "seed \(seed) step \(step) after \(name): \(p)\n\(log.suffix(6).joined(separator: "\n"))")
            if !p.isEmpty { return }
        }
        #expect(applied > 20, "seed \(seed): only \(applied) edits applied")
    }
}

