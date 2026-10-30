import Foundation
import Testing
@testable import SQCore

/// Per-class regression sweep (docs/FILMCRAFT-PRS.md "Watch for" classes 2, 3, 5) on top of `EditInvariantFuzzTests`:
/// the same invariants (`EditInvariantFuzzTests.problems`: no overlap, source inside the media, transitions abut) after
/// seeded random verbs, but on timelines where the class under test is everywhere.
/// - reversed clips under every verb that touches a source handle or the timeline;
/// - transitions under every verb that moves or cuts clips, plus "no transition names a clip of another track";
/// - locked tracks stay identical under every verb (unlinking may clear an orphaned link id).
@Suite struct EditClassSweepFuzzTests {
    typealias LCG = EditCoreCrashFuzzTests.LCG
    static let fd = EditCoreCrashFuzzTests.fd
    static let seeds: [UInt64] = Array(201...(200 + UInt64(ProcessInfo.processInfo.environment["SQ_FUZZ_SEED_COUNT"].flatMap(Int.init) ?? 6)))
    static var steps: Int { ProcessInfo.processInfo.environment["SQ_FUZZ_STEPS"].flatMap(Int.init) ?? 200 }

    typealias Edit = (inout Timeline) throws -> Void

    /// One random frame-exact verb on `c`.
    static func verb(_ rng: inout LCG, _ t: Timeline, _ c: Clip) -> (String, Edit) {
        let fd = Self.fd
        let d = rng.delta(maxFrames: 30, fd: fd, offFrame: false)
        let at = fd * Int64(rng.int(300))
        let head = rng.chance(2)
        let edge: ClipEdge = head ? .head : .tail
        let all = t.tracks.map(\.id)
        let flip = rng.chance(2)
        let pct = Double(25 + rng.int(300))
        let len = fd * Int64(1 + rng.int(60))
        switch rng.int(24) {
        case 0: return ("trim \(edge) \(d)", { _ = try $0.trim(c.id, edge: edge, by: d) })
        case 1: return ("ripple trim \(edge) \(d)", { _ = try $0.rippleTrim(c.id, edge: edge, by: d) })
        case 2: return ("roll \(d)", { _ = try $0.roll(c.id, by: d) })
        case 3: return ("slip \(d)", { _ = try $0.slip(c.id, by: d, keyframes: .stay) })
        case 4: return ("slide \(d)", { _ = try $0.slide(c.id, by: d) })
        case 5: return ("move \(at)", { _ = try $0.move(c.id, to: at) })
        case 6: return ("move insert \(at)", { try $0.moveInsert(c.id, to: at) })
        case 7: return ("nudge \(d)", { _ = try $0.nudge([c.id], by: d) })
        case 8: return ("rate stretch \(edge) \(d)", { _ = try $0.rateStretch(c.id, edge: edge, by: d) })
        case 9: return ("speed \(pct)", { _ = try $0.apply(SpeedChange(speed: ClipSpeed(percent: pct), ripple: flip), to: c.id) })
        case 10: return ("reverse", { _ = try $0.apply(SpeedChange(reversed: true), to: c.id) })
        case 11: return ("extend edit \(edge) \(at)", { _ = try $0.extendEdit(c.id, edge: edge, to: at) })
        case 12: return ("trim to playhead \(at)", { _ = try $0.trimToPlayhead(edge, at: at, tracks: all, mode: flip ? .ripple : .plain) })
        case 13: return ("split \(at)", { _ = try $0.addEdit(at: at, selection: [c.id]) })
        case 14: return ("ripple delete", { _ = try $0.rippleDelete([c.id]) })
        case 15: return ("add edit all \(at)", { _ = try $0.addEdit(at: at, tracks: nil) })
        case 16: return ("join cuts", { _ = try $0.joinThroughEdits() })
        case 17:
            let r = TimeRange(start: at, duration: len)
            return ("lift \(r)", { try $0.lift(r, tracks: all) })
        case 18:
            let r = TimeRange(start: at, duration: len)
            return ("extract \(r)", { _ = try $0.extract(r, tracks: all) })
        case 19: return ("close gap \(at)", { tl in _ = try tl.closeGap(on: tl.tracks.first { $0.clip(c.id) != nil }?.id ?? all[0], at: at) })
        case 20:
            return ("paste \(at)", { tl in
                guard let cb = tl.clipboard(copying: [c.id]) else { throw EditError.clipNotFound }
                _ = try tl.paste(cb, at: at, lanes: nil, insert: flip)
            })
        case 21: return ("split edit \(d)", { _ = try $0.splitEdit(cut: c.timeline.end, side: flip ? .audio : .video, to: c.timeline.end + d) })
        case 22: return ("unlink", { try $0.unlink([c.id]) })
        default: return ("set duration \(len)", { _ = try $0.setDuration(c.id, to: len) })
        }
    }

    /// Runs `steps` random verbs; calls `check(before, after, name)` after every applied one. Returns the applied count.
    static func run(seed: UInt64, start: Timeline, steps: Int, pick: (inout LCG, Timeline) -> Clip?,
                    check: (Timeline, Timeline, String) -> [String]) -> Int {
        var rng = LCG(s: seed &* 7933)
        var tl = start
        var log: [String] = []
        var applied = 0
        for step in 0..<steps {
            if tl.tracks.flatMap(\.clips).count > 60 { tl = start }
            guard let c = pick(&rng, tl) else { break }
            let (name, edit) = verb(&rng, tl, c)
            log.append("\(step): \(name) \(c.id.uuidString.prefix(4))")
            var next = tl
            do { try edit(&next) } catch is EditError { continue } catch {
                Issue.record("seed \(seed): non-EditError \(error) from \(name)"); return applied
            }
            guard next != tl else { continue }
            applied += 1
            // `Project.edit` prunes transitions after every edit.
            for i in next.tracks.indices { next.tracks[i].pruneTransitions(frameDuration: next.frameDuration) }
            let p = EditInvariantFuzzTests.problems(next) + check(tl, next, name)
            if !p.isEmpty {
                Issue.record("seed \(seed): after \(name): \(p)\ncommands: \(log.suffix(10).joined(separator: " | "))")
                return applied
            }
            tl = next
        }
        return applied
    }

    static func reversedTimeline(seed: UInt64) -> Timeline {
        var rng = LCG(s: seed &* 17)
        var tl = EditCoreCrashFuzzTests.make(seed: seed, retime: false)
        for c in tl.tracks.flatMap(\.clips) where rng.chance(2) && tl.find(c.id)?.clip.reversed == false {
            _ = try? tl.apply(SpeedChange(reversed: true), to: c.id)
        }
        return tl
    }

    // MARK: class 2: reversed clips

    @Test(arguments: seeds)
    func reversedClipsKeepTheirSourceInsideTheMediaUnderEveryVerb(seed: UInt64) {
        let start = Self.reversedTimeline(seed: seed)
        #expect(start.tracks.flatMap(\.clips).contains { $0.reversed })
        let applied = Self.run(seed: seed, start: start, steps: Self.steps, pick: { rng, t in
            let all = t.tracks.flatMap(\.clips)
            let r = all.filter(\.reversed)
            return r.isEmpty ? all.first : r[rng.int(r.count)]
        }, check: { _, _, _ in [] })
        #expect(applied > Self.steps / 6, "seed \(seed): the run did too little (applied \(applied))")
    }

    // MARK: class 3: transitions follow the clip

    @Test(arguments: seeds)
    func transitionsNeverDangleUnderEveryMoveVerb(seed: UInt64) {
        let start = EditCoreCrashFuzzTests.make(seed: seed, retime: false)
        #expect(start.tracks.contains { !$0.transitions.isEmpty })
        let applied = Self.run(seed: seed, start: start, steps: Self.steps, pick: { rng, t in
            let withX = t.tracks.flatMap { tr in tr.transitions.compactMap { $0.outgoing ?? $0.incoming }.compactMap { tr.clip($0) } }
            let all = t.tracks.flatMap(\.clips)
            if !withX.isEmpty, rng.chance(2) { return withX[rng.int(withX.count)] }
            return all.isEmpty ? nil : all[rng.int(all.count)]
        }, check: { _, after, _ in
            var out: [String] = []
            for (i, tr) in after.tracks.enumerated() {
                for x in tr.transitions where [x.outgoing, x.incoming].compactMap({ $0 }).contains(where: { tr.clip($0) == nil }) {
                    out.append("track \(i): dangling transition")
                }
            }
            return out
        })
        #expect(applied > Self.steps / 6, "seed \(seed): the run did too little (applied \(applied))")
    }

    // MARK: class 5: locked tracks

    @Test(arguments: seeds)
    func lockedTracksStayIdenticalUnderEveryVerb(seed: UInt64) {
        var rng = LCG(s: seed &* 29)
        var start = EditCoreCrashFuzzTests.make(seed: seed, retime: false)
        let locked = Set((0..<(1 + rng.int(2))).map { _ in rng.int(start.tracks.count) })
        for i in locked { start.tracks[i].isLocked = true }
        let lockedIDs = locked.map { start.tracks[$0].id }
        let applied = Self.run(seed: seed, start: start, steps: Self.steps, pick: { rng, t in
            // Mostly clips on unlocked tracks (verbs on a locked clip must refuse, which the run also covers).
            let open = t.tracks.filter { !$0.isLocked }.flatMap(\.clips)
            let all = t.tracks.flatMap(\.clips)
            let pool = rng.chance(5) || open.isEmpty ? all : open
            return pool.isEmpty ? nil : pool[rng.int(pool.count)]
        }, check: { before, after, name in
            var out: [String] = []
            for id in lockedIDs {
                guard let a = before.tracks.first(where: { $0.id == id }), let b = after.tracks.first(where: { $0.id == id }) else { continue }
                // Unlink clears an orphaned link id on a locked partner: bookkeeping only.
                func strip(_ t: Track) -> [Clip] {
                    t.clips.map { var c = $0; if name == "unlink" { c.link = nil }; return c }
                }
                if strip(a) != strip(b) || a.transitions != b.transitions { out.append("locked track \(id.uuidString.prefix(4)) changed") }
            }
            return out
        })
        #expect(applied > Self.steps / 8, "seed \(seed): the run did too little (applied \(applied))")
    }

    // MARK: setParameter sanitizes on write

    @Test func setParameterNeverStoresNaNOrInfinity() {
        var checked = 0
        for spec in EffectCatalog.everySpec + EffectCatalog.everyAudioSpec {
            var c = Clip(name: "c", media: UUID(), kind: ClipEffect.isAudioKind(spec.kind) ? .audio : .video,
                         source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero, mediaDuration: Time(10, 1))
            guard let id = c.addEffect(kind: spec.kind) else { continue }
            for p in spec.params {
                for d in [Double.nan, .infinity, -.infinity] {
                    c.setParameter(id, p.key, to: d)
                    let stored = c.effects.first { $0.id == id }?.parameters[p.key]?.value
                    #expect(stored?.isFinite == true, "\(spec.kind).\(p.key) = \(d) stored \(String(describing: stored))")
                    if let s = stored { #expect(p.range.contains(s)) }
                    checked += 1
                }
            }
        }
        #expect(checked > 100)
    }
}
