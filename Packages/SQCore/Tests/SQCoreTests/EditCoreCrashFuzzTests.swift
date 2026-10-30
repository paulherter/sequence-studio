import Foundation
import Testing
@testable import SQCore

/// Crash fuzz for the edit core: seeded random edits (split, trim, ripple, roll, slip, slide, move, speed incl. ramps,
/// reverse, rate stretch, paste, jump cut, close gap, lift/extract, J/L split edits, transitions, keys, undo/redo) over
/// generated timelines with linked A/V, transitions, speed ramps and keyframes. Every user input must either apply or
/// throw an `EditError`; a trap kills the test run (and in the app, the current edit). After every step the timeline must
/// be valid: no overlap, every clip at least one frame, speed keys inside the clip and its media, transitions on clips of
/// their own track.
///
/// `SQ_FUZZ_TRACE=<path>` writes each step before it runs to `<path>-<seed>` (survives a trap: find the last line).
/// `SQ_FUZZ_STEPS=<n>` overrides the steps per seed for a longer local run.
@Suite struct EditCoreCrashFuzzTests {
    struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func chance(_ n: Int) -> Bool { int(n) == 0 }
        /// Whole frames (±max); with `offFrame`, sometimes an off-frame time (a drag at sample precision).
        mutating func delta(maxFrames: Int, fd: Time, offFrame: Bool) -> Time {
            let f = fd * Int64(int(maxFrames * 2 + 1) - maxFrames)
            return offFrame && chance(8) ? f + Time(Int64(int(1600)) - 800, 48_000) : f
        }
    }

    static let fd = Time(1001, 30000)
    /// 8 seeds x 400 steps per run (1250 with `SQ_TEST_SOAK=1`, 10k edits); `SQ_FUZZ_SEED_COUNT` / `SQ_FUZZ_STEPS` widen a local run.
    static let seeds: [UInt64] = Array(1...UInt64(ProcessInfo.processInfo.environment["SQ_FUZZ_SEED_COUNT"].flatMap(Int.init) ?? 8))
    static var steps: Int { ProcessInfo.processInfo.environment["SQ_FUZZ_STEPS"].flatMap(Int.init) ?? Soak.count(quick: 400, full: 1250) }

    // MARK: Generated timeline

    static func make(seed: UInt64, retime: Bool = true) -> Timeline {
        var rng = LCG(s: seed &* 104_729)
        var v = [Track(kind: .video), Track(kind: .video)], a = [Track(kind: .audio), Track(kind: .audio)]
        for lane in 0..<2 {
            var t = fd * Int64(rng.int(4))
            for _ in 0..<5 {
                let len = fd * Int64(8 + rng.int(60))
                let media = UUID(), link = UUID()
                let handle = fd * Int64(rng.int(30))
                let md = handle + len + fd * Int64(rng.int(30))
                var c = Clip(name: "v", media: media, kind: .video, source: TimeRange(start: handle, duration: len), start: t,
                             mediaDuration: md)
                c.link = link
                if rng.chance(3) { c.animation.opacity.track.insert(Keyframe(time: fd * Int64(rng.int(8)), value: 0.2)) }
                if rng.chance(3) { c.animation.opacity.track.insert(Keyframe(time: len - fd, value: 0.9)) }
                var s = Clip(name: "a", media: media, kind: .audio, source: c.source, start: t, mediaDuration: md)
                s.link = link
                if rng.chance(3) { s.animation.volume.track.insert(Keyframe(time: fd * Int64(rng.int(8)), value: 0.5)) }
                try? v[lane].overwrite(c)
                try? a[lane].overwrite(s)
                t += len + (rng.chance(2) ? .zero : fd * Int64(rng.int(12)))
            }
        }
        var tl = Timeline(name: "Fuzz", frameDuration: fd, tracks: v + a)
        // Speed, reverse and ramps on some clips; transitions at cuts and fades at edges.
        for c in tl.tracks.filter({ $0.kind == .video }).flatMap(\.clips) where retime {
            switch rng.int(5) {
            case 0: _ = try? tl.apply(SpeedChange(speed: ClipSpeed(percent: Double(25 + rng.int(300)))), to: c.id)
            case 1: _ = try? tl.apply(SpeedChange(reversed: true), to: c.id)
            case 2:
                _ = try? tl.editSpeedKeys(c.id) { k in
                    guard let (k2, b) = k.addingKey(at: k.duration.halved, frameDuration: fd) else { return nil }
                    let k3 = k2.settingSpeed(ofSegment: b, to: ClipSpeed(percent: 250), frameDuration: fd)
                    return k3.splittingKey(atBoundary: b, half: fd * 2, frameDuration: fd) ?? k3
                }
            default: break
            }
        }
        for ti in tl.tracks.indices {
            let kind: TransitionKind = tl.tracks[ti].kind == .video ? .crossDissolve : .constantPower
            let clips = tl.tracks[ti].clips
            for (l, r) in zip(clips, clips.dropFirst()) where l.timeline.end == r.start && rng.chance(2) {
                _ = try? tl.addTransition(point: .cut(outgoing: l.id, incoming: r.id), kind: kind, track: tl.tracks[ti].id,
                                          duration: fd * Int64(4 + rng.int(20)))
            }
            if let f = clips.first, rng.chance(2) {
                _ = try? tl.addTransition(point: .head(f.id), kind: kind, track: tl.tracks[ti].id, duration: fd * 10)
            }
        }
        return tl
    }

    // MARK: Invariants

    /// `frameExact`: every input was on frames and nothing was retimed, so every clip edge stays on the frame grid and
    /// every clip at least one frame long. Otherwise edges may leave the grid legitimately (a retimed clip's media limit
    /// is `handle / speed`, an audio edit at sample precision) and a clip only has to stay longer than zero.
    /// `slack`: how far a source edge may pass the media edge. Off-frame drags chain into fractions too large for Int64, which
    /// are then rounded (relative error ~1e-12): a microsecond is far below any frame or sample and still catches real bugs.
    static func problems(_ t: Timeline, frameExact wholeFrames: Bool, slack: Time = .zero) -> [String] {
        var out: [String] = []
        let neg = Time.zero - slack
        let f: (Time) -> String = { String(format: "%.4f", Double($0.value) / Double($0.timescale)) }
        for (i, tr) in t.tracks.enumerated() {
            if !tr.isConsistent { out.append("track \(i) overlaps or starts before 0: \(tr.clips.map { "\(f($0.start))+\(f($0.duration))" })") }
            for c in tr.clips {
                if wholeFrames, c.start.snapped(to: t.frameDuration) != c.start || c.duration.snapped(to: t.frameDuration) != c.duration {
                    out.append("track \(i): clip off the frame grid \(f(c.start))+\(f(c.duration))")
                }
                if wholeFrames ? c.duration < t.frameDuration : c.duration <= .zero {
                    out.append("track \(i): clip too short \(f(c.duration))")
                }
                if let k = c.speedKeys {
                    if k.segments.isEmpty { out.append("track \(i): speed track without segments") }
                    if k.segments.contains(where: { $0.duration <= .zero }) { out.append("track \(i): empty speed segment") }
                    if c.source != k.hull { out.append("track \(i): source is not the speed track's hull") }
                    // Speed-key positions are stored rounded to 2^-20 s (`Rational.time`): a clip trimmed exactly to the media
                    // edge may show its hull one tick past it.
                    let tick = max(slack, Time(1, 1 << 20))
                    if k.hull.start < .zero - tick || c.mediaDuration.map({ k.hull.end > $0 + tick }) == true {
                        out.append("track \(i): speed keys visit source outside the media \(k.hull) media \(String(describing: c.mediaDuration))")
                    }
                } else if c.holdFrame == nil, !c.isGenerator, !c.isStill {
                    if c.source.start < neg { out.append("track \(i): source before the media start \(f(c.source.start))") }
                    if let md = c.mediaDuration, c.source.end > md + slack { out.append("track \(i): source beyond the media end \(f(c.source.end)) > \(f(md))") }
                }
            }
            // A transition whose clips were cut away stays stored but resolves to nothing; resolving and evaluating the
            // track around every cut must not trap.
            for x in tr.transitions { _ = tr.resolve(x, frameDuration: t.frameDuration) }
            if !tr.transitions.isEmpty {
                for c in tr.clips {
                    for at in [c.start, c.start + c.duration.halved, c.timeline.end - Time(1, 48_000)] {
                        if tr.kind == .video { _ = tr.videoEntries(at: at, frameDuration: t.frameDuration) }
                    }
                }
            }
        }
        return out
    }

    // MARK: Run

    @Test(arguments: seeds)
    func randomEditsNeverTrapAndKeepTheTimelineValid(seed: UInt64) {
        if let only = ProcessInfo.processInfo.environment["SQ_FUZZ_SEED"].flatMap(UInt64.init), only != seed { return }
        var rng = LCG(s: seed &* 7919)
        // Seeds 1, 5: frame-exact edits without retiming; 4, 8: off-frame drags; the rest: whole frames with speed edits.
        let offFrame = seed % 4 == 0, frameExact = seed % 4 == 1
        let start = Self.make(seed: seed, retime: !frameExact)
        #expect(Self.problems(start, frameExact: frameExact).isEmpty, "seed \(seed): generated timeline invalid")
        var hist = History(start, limit: 50)
        let tracePath = ProcessInfo.processInfo.environment["SQ_FUZZ_TRACE"].map { "\($0)-\(seed)" }
        let trace: FileHandle? = tracePath.flatMap { p in
            FileManager.default.createFile(atPath: p, contents: nil)
            return FileHandle(forWritingAtPath: p)
        }
        defer { try? trace?.close() }
        var log: [String] = []
        var applied = 0
        let fd = Self.fd
        for step in 0..<Self.steps {
            let t0 = hist.current
            let all = t0.tracks.flatMap(\.clips)
            // Keep the timeline small (paste and jump cut grow it): start over from a fresh one.
            if all.isEmpty || all.count > 80 || t0.tracks.count > 10 {
                hist = History(Self.make(seed: seed &+ UInt64(step), retime: !frameExact), limit: 50)
                continue
            }
            let c = all[rng.int(all.count)]
            let d = rng.delta(maxFrames: 40, fd: fd, offFrame: offFrame)
            let at = rng.chance(3) ? c.start + fd * Int64(rng.int(max(Int(c.duration.frameIndex(frameDuration: fd)), 1)))
                                   : fd * Int64(rng.int(400))
            let track = t0.tracks[rng.int(t0.tracks.count)]
            var op = rng.int(30)
            if frameExact, (11...16).contains(op) { op = [0, 2, 3, 5, 7, 17][op - 11] }
            var name = "op \(op)"
            var edit: ((inout Timeline) throws -> Void)?
            switch op {
            case 0: name = "add edit all \(at)"; edit = { _ = try $0.addEdit(at: at, tracks: nil) }
            case 1: name = "add edit selection \(at)"; edit = { _ = try $0.addEdit(at: at, selection: [c.id]) }
            case 2: name = "trim tail \(d)"; edit = { _ = try $0.trim(c.id, edge: .tail, by: d) }
            case 3: name = "trim head \(d)"; edit = { _ = try $0.trim(c.id, edge: .head, by: d) }
            case 4: name = "ripple trim \(d)"; edit = { _ = try $0.rippleTrim(c.id, edge: rng.chance(2) ? .head : .tail, by: d) }
            case 5: name = "roll \(d)"; edit = { _ = try $0.roll(c.id, by: d) }
            case 6: name = "slip \(d)"; edit = { _ = try $0.slip(c.id, by: d, keyframes: rng.chance(2) ? .stay : .followContent) }
            case 7: name = "slide \(d)"; edit = { _ = try $0.slide(c.id, by: d) }
            case 8: name = "move \(at)"; edit = { _ = try $0.move(c.id, to: at) }
            case 9: name = "move insert \(at)"; edit = { _ = try $0.moveInsert(c.id, to: at) }
            case 10: name = "ripple delete"; edit = { try $0.rippleDelete([c.id]) }
            case 11:
                let p = Double([1, 10, 33, 50, 99, 100, 150, 200, 400, 1000, 10_000][rng.int(11)])
                let ripple = rng.chance(2), hold = rng.chance(4)
                name = "speed \(p)% ripple \(ripple) hold \(hold)"
                edit = { _ = try $0.apply(SpeedChange(speed: ClipSpeed(percent: p), ripple: ripple, holdingDuration: hold), to: c.id) }
            case 12:
                let dur = fd * Int64(rng.int(200)) + (rng.chance(4) ? Time(1, 96_000) : .zero)   // snapped by the edit
                name = "duration \(dur)"
                edit = { _ = try $0.apply(SpeedChange(duration: dur, ripple: rng.chance(2)), to: c.id) }
            case 13: name = "reverse"; edit = { _ = try $0.apply(SpeedChange(reversed: !c.reversed, ripple: rng.chance(2)), to: c.id) }
            case 14: name = "rate stretch \(d)"; edit = { _ = try $0.rateStretch(c.id, edge: rng.chance(2) ? .head : .tail, by: d) }
            case 15, 16:
                let local = fd * Int64(rng.int(Int(max(c.duration.frameIndex(frameDuration: fd), 1)) + 2)) - fd
                let seg = rng.int(6) - 1, b = rng.int(6) - 1
                let v = ClipSpeed(percent: Double([5, 50, 80, 120, 200, 400, 2000][rng.int(7)]))
                let w = fd * Int64(rng.int(30)), dd = d
                let kind = rng.int(9)
                name = "speed keys \(kind) local \(local) seg \(seg) b \(b) \(v) w \(w) d \(dd)"
                edit = { tl in
                    _ = try tl.editSpeedKeys(c.id) { k in
                        switch kind {
                        case 0: k.addingKey(at: local, frameDuration: fd)?.keys
                        case 1: k.settingSpeed(ofSegment: seg, to: v, frameDuration: fd)
                        case 2: k.splittingKey(atBoundary: b, half: w, frameDuration: fd)
                        case 3: k.splittingKey(atBoundary: b, takeLeft: w, takeRight: dd, frameDuration: fd)
                        case 4: k.removingRamp(atSegment: seg, frameDuration: fd)
                        case 5: k.settingRampWidth(ofSegment: seg, to: w, frameDuration: fd)
                        case 6: k.movingKey(atBoundary: b, by: dd, frameDuration: fd)
                        case 7: k.movingRamp(atSegment: seg, by: dd, frameDuration: fd)
                        default: k.removingKey(atBoundary: b)
                        }
                    }
                }
            case 17:
                let ids: Set<Clip.ID> = rng.chance(2) ? [c.id] : Set(all.filter { _ in rng.chance(6) }.map(\.id))
                let insert = rng.chance(2)
                let lanes: [TrackKind: Int]? = rng.chance(2) ? nil : [.video: rng.int(4), .audio: rng.int(4)]
                name = "paste \(ids.count) at \(at) insert \(insert)"
                edit = { tl in
                    guard let cb = tl.clipboard(copying: ids) else { throw EditError.clipNotFound }
                    _ = try tl.paste(cb, at: at, lanes: lanes, insert: insert)
                }
            case 18:
                let sel: Set<Clip.ID> = rng.chance(2) ? [c.id] : []
                let n = rng.int(12) - 1
                name = "jump cut at \(at) overlap \(n)"
                edit = { _ = try $0.jumpCutAlternate(at: at, selection: sel, overlapFrames: n) }
            case 19: name = "close gap \(at)"; edit = { _ = try $0.closeGap(on: track.id, at: at) }
            case 20, 21:
                let r = TimeRange(start: at, duration: fd * Int64(1 + rng.int(40)))
                let lift = op == 20
                name = "\(lift ? "lift" : "extract") \(r)"
                edit = { tl in
                    if lift { try tl.lift(r, tracks: tl.tracks.map(\.id)) } else { _ = try tl.extract(r, tracks: tl.tracks.map(\.id)) }
                }
            case 22:
                let side: SplitEditSide = rng.chance(2) ? .audio : .video
                name = "split edit \(side) cut \(at) to \(at + d)"
                edit = { _ = try $0.splitEdit(cut: at, side: side, to: at + d) }
            case 23:
                let jl: JLCut = rng.chance(2) ? .jCut : .lCut
                name = "J/L \(jl) at \(at)"
                edit = { _ = try $0.splitEditJL(jl, at: at) }
            case 24:
                let kind: TransitionKind = track.kind == .video ? [.crossDissolve, .dipToBlack][rng.int(2)] : .constantGain
                let dur = fd * Int64(rng.int(60)) + (rng.chance(5) ? Time(1, 48_000) : .zero)
                let clips = track.clips
                let point: TransitionPoint? = clips.isEmpty ? nil : {
                    let i = rng.int(clips.count)
                    if i + 1 < clips.count, rng.chance(2) { return .cut(outgoing: clips[i].id, incoming: clips[i + 1].id) }
                    return rng.chance(2) ? .head(clips[i].id) : .tail(clips[i].id)
                }()
                name = "transition \(String(describing: point)) \(dur)"
                edit = { tl in
                    guard let point else { throw EditError.clipNotFound }
                    _ = try tl.addTransition(point: point, kind: kind, track: track.id, duration: dur)
                }
            case 25:
                let kt = at - c.start + (rng.chance(3) ? d : .zero)
                name = "key at \(kt)"
                edit = { tl in
                    guard let ti = tl.tracks.firstIndex(where: { $0.clip(c.id) != nil }) else { throw EditError.clipNotFound }
                    var n = c
                    if c.kind == .video { n.animation.opacity.track.insert(Keyframe(time: kt, value: 0.5)) }
                    else { n.animation.volume.track.insert(Keyframe(time: kt, value: 0.5)) }
                    tl.tracks[ti].replace(n)
                }
            case 26: name = "nudge \(d)"; edit = { _ = try $0.nudge([c.id], by: d) }
            case 27: name = "undo"
            case 28: name = "redo"
            default: name = "undo x3"
            }
            if let trace { trace.write(Data("\(step) \(name)\n".utf8)) }
            if let tracePath, ProcessInfo.processInfo.environment["SQ_FUZZ_DUMP_STEP"] == "\(step)" {
                let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
                try? e.encode(hist.current).write(to: URL(fileURLWithPath: tracePath + ".json"))
            }
            switch op {
            case 27: hist.undo()
            case 28: hist.redo()
            case 29: for _ in 0..<3 { hist.undo() }
            default:
                do {
                    try hist.commit(name) { try edit!(&$0) }
                    applied += 1
                    log.append("\(step): \(name) ok")
                } catch is EditError {
                    log.append("\(step): \(name) refused")
                } catch {
                    Issue.record("seed \(seed) step \(step) \(name): non-EditError \(error)")
                }
            }
            if let trace { trace.write(Data("  check\n".utf8)) }
            let p = Self.problems(hist.current, frameExact: frameExact, slack: offFrame ? Time(1, 1_000_000) : .zero)
            if !p.isEmpty {
                if let tracePath { try? Data("step \(step) \(name): \(p)\n\(log.suffix(8).joined(separator: "\n"))".utf8).write(to: URL(fileURLWithPath: tracePath + ".fail")) }
                Issue.record("seed \(seed) step \(step) after \(name): \(p)\n\(log.suffix(8).joined(separator: "\n"))")
                return
            }
        }
        #expect(applied > Self.steps / 5, "seed \(seed): the fuzz run did too little (applied \(applied))")
        if let tracePath { try? FileManager.default.removeItem(atPath: tracePath) }
    }

    // MARK: Regressions the fuzz found

    @Test func rationalArithmeticNearInt64DoesNotTrap() {
        let big = Int128(Int64.max)
        let x = Rational(big - 1, big), y = Rational(1, big - 2)
        let sum = (x + y) * Rational(big - 4, big - 6)
        let t = sum.time
        #expect(t > Time(9, 10) && t < Time(11, 10))
    }

    @Test func cutsAtTimesBeyondInt64KeepTheTrackValid() {
        let start = Time(5_751_096_900_775_241_683, 3_191_884_280_944_025_598)
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: start)
        let at = start + Time(2_606_978_954_447_067_646, 2_345_708_184_549_944_590)
        var cut = Track(kind: .video); try? cut.overwrite(c)
        _ = try? cut.split(at: at)
        #expect(cut.isConsistent)
        var lifted = Track(kind: .video); try? lifted.overwrite(c)
        try? lifted.overwrite(Clip(name: "w", media: UUID(), kind: .video,
                                   source: TimeRange(start: .zero, duration: Time(1, 7)), start: at))
        #expect(lifted.isConsistent)
    }

    @Test func aSpeedKeyEditThatChangesNothingLeavesTheClip() throws {
        var tl = Self.make(seed: 3, retime: false)
        let c = try #require(tl.tracks[0].clips.first)
        let before = tl
        let change = try tl.editSpeedKeys(c.id) { $0 }
        #expect(change == .zero)
        #expect(tl == before)
    }
}
