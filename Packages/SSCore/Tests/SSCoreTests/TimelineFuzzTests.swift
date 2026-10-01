import Foundation
import Testing
@testable import SSCore

/// Random edit sequences on a small linked A/V timeline. After every operation the timeline must stay valid
/// (clips sorted, no overlaps, nothing before 0, no empty clips, media ranges inside the media), and an operation that
/// throws must leave the timeline exactly as it was (atomic).
private extension Time { var f: String { String(format: "%.3f", Double(value) / Double(timescale)) } }

@Suite struct TimelineFuzzTests {
    struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func time(maxFrames: Int, fd: Time) -> Time { fd * Int64(int(maxFrames * 2 + 1) - maxFrames) }
    }

    static let fd = Time(1001, 30000)

    static func start(seed: UInt64) throws -> Timeline {
        var v1 = Track(kind: .video), v2 = Track(kind: .video), a1 = Track(kind: .audio), a2 = Track(kind: .audio)
        var rng = LCG(s: seed)
        for (n, (vt, at)) in [(0, 0), (1, 1)].enumerated() {
            _ = vt; _ = at
            var t = Time.zero
            for i in 0..<4 {
                let len = fd * Int64(10 + rng.int(40))
                let gap = i == 0 ? Time.zero : fd * Int64(rng.int(6))
                t += gap
                let media = UUID(), link = UUID()
                let md = len + fd * Int64(rng.int(20))
                var c = Clip(name: "v", media: media, kind: .video,
                             source: TimeRange(start: fd * Int64(rng.int(10)), duration: len), start: t, mediaDuration: md + fd * 10)
                c.link = link
                var a = Clip(name: "a", media: media, kind: .audio, source: c.source, start: t, mediaDuration: c.mediaDuration)
                a.link = link
                if n == 0 { try v1.overwrite(c); try a1.overwrite(a) } else { try v2.overwrite(c); try a2.overwrite(a) }
                t += len
            }
        }
        return Timeline(name: "T", frameDuration: fd, tracks: [v1, v2, a1, a2])
    }

    static func problems(_ t: Timeline) -> [String] {
        var out: [String] = []
        for (i, tr) in t.tracks.enumerated() {
            if !tr.isConsistent { out.append("track \(i) overlaps or starts before 0: \(tr.clips.map { "\($0.start.f)+\($0.timeline.duration.f)" })") }
            for c in tr.clips {
                if c.timeline.duration <= .zero { out.append("track \(i): empty clip \(c.name)") }
                if !c.isGenerator, !c.isStill {
                    if c.source.start < .zero { out.append("track \(i): source before the media start \(c.source.start.f)") }
                    if let md = c.mediaDuration, c.source.end > md { out.append("track \(i): source beyond the media end \(c.source.end.f) > \(md.f)") }
                }
            }
        }
        return out
    }

    @Test(arguments: Array(1...40) as [UInt64])
    func randomEditsKeepTheTimelineValidAndAtomic(seed: UInt64) throws {
        var rng = LCG(s: seed &* 7919)
        var t = try Self.start(seed: seed)
        #expect(Self.problems(t).isEmpty)
        var log: [String] = []
        var applied = 0, changed = 0
        for step in 0..<250 {
            let before = t
            let clips = t.tracks.flatMap(\.clips)
            guard let c = clips.isEmpty ? nil : clips[rng.int(clips.count)] else { break }
            let d = rng.time(maxFrames: 40, fd: Self.fd)
            let at = Self.fd * Int64(rng.int(200))
            let op = rng.int(13)
            var name = ""
            do {
                switch op {
                case 0: name = "trim tail \(d.f)"; try t.trim(c.id, edge: .tail, by: d)
                case 1: name = "trim head \(d.f)"; try t.trim(c.id, edge: .head, by: d)
                case 2: name = "roll \(d.f)"; try t.roll(c.id, by: d)
                case 3: name = "slip \(d.f)"; try t.slip(c.id, by: d)
                case 4: name = "slide \(d.f)"; try t.slide(c.id, by: d)
                case 5: name = "move to \(at.f)"; try t.move(c.id, to: at)
                case 6: name = "move-insert to \(at.f)"; try t.moveInsert(c.id, to: at)
                case 7: name = "ripple delete"; try t.rippleDelete([c.id])
                case 8: name = "ripple trim tail \(d.f)"; try t.rippleTrim(c.id, edge: .tail, by: d)
                case 9: name = "ripple trim head \(d.f)"; try t.rippleTrim(c.id, edge: .head, by: d)
                case 10: name = "add edit at \(at.f)"; try t.addEdit(at: at, tracks: nil)
                case 11:
                    let r = TimeRange(start: at, duration: Self.fd * Int64(1 + rng.int(40)))
                    name = "lift \(r.start.f)+\(r.duration.f)"
                    try t.lift(r, tracks: t.tracks.map(\.id))
                default:
                    let r = TimeRange(start: at, duration: Self.fd * Int64(1 + rng.int(40)))
                    name = "extract \(r.start.f)+\(r.duration.f)"
                    try t.extract(r, tracks: t.tracks.map(\.id))
                }
                log.append("\(step): \(name) ok")
                applied += 1
                if t != before { changed += 1 }
            } catch {
                log.append("\(step): \(name) refused \(error)")
                #expect(t == before, "seed \(seed) step \(step) \(name): a refused edit changed the timeline")
                t = before
            }
            let p = Self.problems(t)
            #expect(p.isEmpty, "seed \(seed) step \(step) after \(name): \(p)\n\(log.suffix(6).joined(separator: "\n"))")
            if !p.isEmpty { return }
        }
        #expect(applied > 30 && changed > 20, "seed \(seed): the fuzz run did too little (applied \(applied), changed \(changed))")
    }
}
