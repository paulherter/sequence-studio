import Foundation
import Testing
@testable import SQCore

/// Invariant fuzz on top of `EditCoreCrashFuzzTests`: seeded random edit commands (insert, overwrite, ripple delete, lift,
/// extract, trim, roll, slip, slide, split, join cuts, paste, undo, redo) on generated timelines. The crash fuzz proves
/// nothing traps and the track stays valid; this suite checks what an editor relies on after every step:
/// - no overlap, no negative time, no zero-length clip, every edge on the frame grid (frame-exact inputs, no retiming);
/// - a link group never holds two clips on one track;
/// - a transition that still resolves with two clips joins clips that abut on one track;
/// - undo restores the byte-identical snapshot of before the edit, redo re-applies exactly the edit;
/// - conservation: a ripple delete keeps the offset of every surviving link group, a split followed by Join Cuts gives the
///   original clips back, an extract never lengthens a track.
/// Deterministic seeds. A failure prints the seed and the command list so far. `SQ_FUZZ_STEPS` / `SQ_FUZZ_SEED_COUNT`
/// widen a local run (the same variables as the crash fuzz).
@Suite struct EditInvariantFuzzTests {
    typealias LCG = EditCoreCrashFuzzTests.LCG
    static let fd = EditCoreCrashFuzzTests.fd
    static let seeds: [UInt64] = Array(101...(100 + UInt64(ProcessInfo.processInfo.environment["SQ_FUZZ_SEED_COUNT"].flatMap(Int.init) ?? 6)))
    static var steps: Int { ProcessInfo.processInfo.environment["SQ_FUZZ_STEPS"].flatMap(Int.init) ?? Soak.count(quick: 100, full: 300) }

    static func bytes(_ t: Timeline) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(t)) ?? Data()
    }

    /// Invariants that must hold for any timeline reachable by frame-exact edits.
    static func problems(_ t: Timeline) -> [String] {
        var out = EditCoreCrashFuzzTests.problems(t, frameExact: true)
        var onTrack: [UUID: [Int: Int]] = [:]
        for (i, tr) in t.tracks.enumerated() {
            for c in tr.clips {
                if c.start < .zero { out.append("track \(i): negative start") }
                if let l = c.link { onTrack[l, default: [:]][i, default: 0] += 1 }
            }
            for x in tr.transitions {
                guard let r = tr.resolve(x, frameDuration: t.frameDuration),
                      let o = r.outgoing, let n = r.incoming else { continue }
                guard let a = tr.clip(o), let b = tr.clip(n) else { out.append("track \(i): transition names a clip of another track"); continue }
                if a.timeline.end != b.start { out.append("track \(i): transition joins clips that do not abut") }
            }
        }
        for (l, lanes) in onTrack where lanes.values.contains(where: { $0 > 1 }) { out.append("link \(l) holds two clips on one track") }
        return out
    }

    /// Offset (start difference) of every pair of clips that share a link, keyed by the two clip IDs.
    static func linkOffsets(_ t: Timeline) -> [String: Time] {
        var groups: [UUID: [Clip]] = [:]
        for c in t.tracks.flatMap(\.clips) { if let l = c.link { groups[l, default: []].append(c) } }
        var out: [String: Time] = [:]
        for (_, g) in groups { for x in g { for y in g where x.id.uuidString < y.id.uuidString { out["\(x.id)|\(y.id)"] = y.start - x.start } } }
        return out
    }

    static func describe(_ a: Timeline, _ b: Timeline, _ key: String) -> String {
        let ids = key.split(separator: "|").map(String.init)
        func f(_ t: Timeline, _ id: String) -> String {
            for (i, tr) in t.tracks.enumerated() { if let c = tr.clips.first(where: { $0.id.uuidString == id }) {
                return "t\(i)\(tr.followsRipple ? "r" : "") \(Double(c.start.value) / Double(c.start.timescale))+\(Double(c.duration.value) / Double(c.duration.timescale))" } }
            return "gone"
        }
        return ids.map { "\(f(a, $0)) => \(f(b, $0))" }.joined(separator: "; ")
    }

    static func totalEnd(_ t: Timeline) -> [Track.ID: Time] {
        Dictionary(uniqueKeysWithValues: t.tracks.map { ($0.id, $0.clips.map(\.timeline.end).max() ?? .zero) })
    }

    @Test(arguments: seeds)
    func randomEditsKeepEveryInvariantAndUndoIsExact(seed: UInt64) {
        var rng = LCG(s: seed &* 7919)
        var hist = History(EditCoreCrashFuzzTests.make(seed: seed, retime: false), limit: 50)
        var log: [String] = []
        func fail(_ what: String) { Issue.record("seed \(seed): \(what)\ncommands: \(log.suffix(12).joined(separator: " | "))") }
        let first = Self.problems(hist.current)
        #expect(first.isEmpty, "seed \(seed): generated timeline invalid \(first)")
        var applied = 0
        for step in 0..<Self.steps {
            let t0 = hist.current
            let all = t0.tracks.flatMap(\.clips)
            if all.isEmpty || all.count > 60 || t0.tracks.count > 10 {
                hist = History(EditCoreCrashFuzzTests.make(seed: seed &+ UInt64(step) &+ 5000, retime: false), limit: 50)
                log.append("\(step): fresh timeline")
                continue
            }
            let fd = Self.fd
            let c = all[rng.int(all.count)]
            let d = rng.delta(maxFrames: 30, fd: fd, offFrame: false)
            let at = fd * Int64(rng.int(300))
            let ti = rng.int(t0.tracks.count)
            let track = t0.tracks[ti]
            let op = rng.int(18)
            var name = "op \(op)"
            var edit: ((inout Timeline) throws -> Void)?
            var rippleDeletes = false, extractRange: TimeRange?
            switch op {
            case 0, 1:
                // Insert (ripple) or overwrite a fresh clip on this track.
                let len = fd * Int64(1 + rng.int(40))
                let kind = track.kind
                let n = Clip(name: "n", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: len), start: at,
                             mediaDuration: len + fd * 10)
                if op == 0 { name = "insert \(len) at \(at) on \(ti)"; edit = { try $0.insert([(clip: n, track: track.id)], at: at) } }
                else { name = "overwrite \(len) at \(at) on \(ti)"; edit = { try $0.tracks[ti].overwrite(n) } }
            case 2: name = "ripple delete \(c.id)"; rippleDeletes = true; edit = { _ = try $0.rippleDelete([c.id]) }
            case 3, 4:
                let r = TimeRange(start: at, duration: fd * Int64(1 + rng.int(40)))
                if op == 3 { name = "lift \(r)"; edit = { try $0.lift(r, tracks: $0.tracks.map(\.id)) } }
                else { name = "extract \(r)"; extractRange = r; edit = { _ = try $0.extract(r, tracks: $0.tracks.map(\.id)) } }
            case 5: name = "trim tail \(d) \(c.id)"; edit = { _ = try $0.trim(c.id, edge: .tail, by: d) }
            case 6: name = "trim head \(d) \(c.id)"; edit = { _ = try $0.trim(c.id, edge: .head, by: d) }
            case 7: name = "ripple trim \(d) \(c.id)"; edit = { _ = try $0.rippleTrim(c.id, edge: rng.chance(2) ? .head : .tail, by: d) }
            case 8: name = "roll \(d) \(c.id)"; edit = { _ = try $0.roll(c.id, by: d) }
            case 9: name = "slip \(d) \(c.id)"; edit = { _ = try $0.slip(c.id, by: d, keyframes: .stay) }
            case 10: name = "slide \(d) \(c.id)"; edit = { _ = try $0.slide(c.id, by: d) }
            case 11: name = "split all at \(at)"; edit = { _ = try $0.addEdit(at: at, tracks: nil) }
            case 12: name = "join cuts"; edit = { _ = try $0.joinThroughEdits() }
            case 13:
                let ids: Set<Clip.ID> = rng.chance(2) ? [c.id] : Set(all.filter { _ in rng.chance(6) }.map(\.id))
                let insert = rng.chance(2)
                name = "paste \(ids.count) at \(at) insert \(insert)"
                edit = { tl in
                    guard let cb = tl.clipboard(copying: ids) else { throw EditError.clipNotFound }
                    _ = try tl.paste(cb, at: at, lanes: nil, insert: insert)
                }
            case 14: name = "move \(at) \(c.id)"; edit = { _ = try $0.move(c.id, to: at) }
            case 15: name = "undo"
            case 16: name = "redo"
            default: name = "close gap \(at) on \(ti)"; edit = { _ = try $0.closeGap(on: track.id, at: at) }
            }
            log.append("\(step): \(name)")
            switch op {
            case 15: hist.undo()
            case 16: hist.redo()
            default:
                do {
                    let beforeEnds = Self.totalEnd(t0), beforeOffsets = Self.linkOffsets(t0)
                    var probe = hist
                    try probe.commit(name) { try edit!(&$0) }
                    guard probe.current != t0 else { break }
                    hist = probe
                    applied += 1
                    // Undo restores the byte-identical snapshot; redo re-applies exactly the edit.
                    var round = hist
                    let after = hist.current
                    round.undo()
                    if round.current != t0 || Self.bytes(round.current) != Self.bytes(t0) { fail("undo did not restore the snapshot after \(name)") }
                    round.redo()
                    if round.current != after || Self.bytes(round.current) != Self.bytes(after) { fail("redo did not re-apply \(name)") }
                    if rippleDeletes {
                        // A pair whose members lie on both sides of the removed span legitimately changes offset (the
                        // later one moves); a pair entirely on one side must keep it.
                        let group = all.filter { $0.id == c.id || (c.link != nil && $0.link == c.link) }
                        let lo = group.map(\.start).min() ?? .zero, hi = group.map { $0.timeline.end }.max() ?? .zero
                        let side: [Clip.ID: Int] = Dictionary(all.map { ($0.id, $0.start >= hi ? 1 : $0.timeline.end <= lo ? -1 : 0) },
                                                              uniquingKeysWith: { a, _ in a })
                        let now = Self.linkOffsets(after)
                        for (k, v) in now {
                            let ids = k.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                            guard let was = beforeOffsets[k], was != v, ids.count == 2,
                                  let a = side[ids[0]], a != 0, a == side[ids[1]] else { continue }
                            fail("ripple delete changed the offset of linked pair \(k): \(was) -> \(v); \(Self.describe(t0, after, k))")
                        }
                    }
                    if let r = extractRange {
                        for (id, end) in Self.totalEnd(after) { if let was = beforeEnds[id], end > was { fail("extract \(r) lengthened a track") } }
                    }
                } catch is EditError {
                    // refused: nothing changed (hist untouched)
                } catch {
                    fail("non-EditError \(error) from \(name)")
                }
            }
            let p = Self.problems(hist.current)
            if !p.isEmpty { fail("after \(name): \(p)"); return }
        }
        #expect(applied > Self.steps / 6, "seed \(seed): the run did too little (applied \(applied))")
    }

    /// Conservation: a blade through every track and Join Cuts afterwards give back the same clips and the same total duration.
    @Test(arguments: seeds)
    func splitThenJoinCutsRestoresTheClips(seed: UInt64) throws {
        var rng = LCG(s: seed &* 31)
        let fd = Self.fd
        let original = EditCoreCrashFuzzTests.make(seed: seed, retime: false)
        var tl = original
        for _ in 0..<(1 + rng.int(6)) {
            let at = fd * Int64(rng.int(300))
            do { _ = try tl.addEdit(at: at, tracks: nil) } catch is EditError {}
        }
        let joined = try tl.joinThroughEdits()
        _ = joined
        func shape(_ t: Timeline) -> [[[Time]]] {
            t.tracks.map { $0.clips.map { [$0.start, $0.duration, $0.source.start] } }
        }
        #expect(shape(tl) == shape(original), "seed \(seed): split then join changed the clips")
        #expect(tl.tracks.map { $0.clips.reduce(Time.zero) { $0 + $1.duration } } ==
                original.tracks.map { $0.clips.reduce(Time.zero) { $0 + $1.duration } }, "seed \(seed): total duration changed")
    }
}
