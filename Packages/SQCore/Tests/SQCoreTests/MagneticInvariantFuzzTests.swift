import Foundation
import Testing
@testable import SQCore

/// Invariant fuzz for the Fast Cut (magnetic) verbs, docs/research/FCP-MAGNETIC-TIMELINE.md section 6 (phase 1C).
/// Seeded random sequences of the public magnetic ops (Timeline+MagneticOps.swift) run on a generated sequence (V1 main
/// track with linked camera audio incl. J cuts, overlays on V2/V3, music on A2) with random Normal <-> Fast Cut
/// switches, undo and redo in between. After every step:
/// 1. V1 gains no hole except through the spacer verbs (Replace with Spacer, Insert Spacer, Lift off Main Track, Clear Range);
/// 2. every attachment is valid and `deriveAttachments` is a no-op (Fast Cut);
/// 3. followers follow: a main clip that moved whole by d takes every clip attached to it along (follow verbs only);
/// 4. content sync: an attached clip keeps the host source frame under its attach point (constant-speed hosts);
/// 5. no overlaps, frame grid, linked groups keep their internal offsets;
/// 6. undo restores the byte-identical timeline, redo the post-op one;
/// 7. a mode switch moves no clip (encoded tracks equal apart from attachments);
/// 8. valid tracks, no zero-length clips, no negative times; and a Normal-only run never writes a v67 key.
/// A failure prints the seed and the last 12 commands. `SQ_FUZZ_SEED_COUNT` / `SQ_FUZZ_STEPS` widen a run (default 6 x 300).
@Suite struct MagneticInvariantFuzzTests {
    typealias LCG = EditCoreCrashFuzzTests.LCG
    static let fd = EditCoreCrashFuzzTests.fd
    static let seeds: [UInt64] = Array(201...(200 + UInt64(ProcessInfo.processInfo.environment["SQ_FUZZ_SEED_COUNT"].flatMap(Int.init) ?? 6)))
    static var steps: Int { ProcessInfo.processInfo.environment["SQ_FUZZ_STEPS"].flatMap(Int.init) ?? Soak.count(quick: 100, full: 300) }

    // MARK: Generated sequence

    static func make(seed: UInt64) -> Timeline {
        var rng = LCG(s: seed &* 104_729)
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        var v2 = Track(kind: .video), v3 = Track(kind: .video), a2 = Track(kind: .audio)
        var t = Time.zero
        for i in 0..<(4 + rng.int(4)) {
            let len = fd * Int64(10 + rng.int(50))
            let media = UUID(), link = UUID()
            let handle = fd * Int64(6 + rng.int(20))
            let md = handle + len + fd * Int64(6 + rng.int(20))
            var v = Clip(name: "v\(i)", media: media, kind: .video, source: TimeRange(start: handle, duration: len), start: t, mediaDuration: md)
            v.link = link
            // J cut on every odd clip: the audio starts k frames early, the previous audio ends k frames early.
            let k = fd * Int64(2 + rng.int(4))
            var aStart = t, aSrc = v.source
            if i % 2 == 1 { aStart = t - k; aSrc = TimeRange(start: handle - k, duration: len + k) }
            var a = Clip(name: "a\(i)", media: media, kind: .audio, source: aSrc, start: aStart, mediaDuration: md)
            a.link = link
            try? v1.overwrite(v)
            if i % 2 == 1, let prev = a1.clips.last, prev.timeline.end > aStart {
                var p = prev
                p.source = TimeRange(start: p.source.start, duration: p.duration - (prev.timeline.end - aStart))
                a1.remove(prev.id)
                try? a1.overwrite(p)
            }
            try? a1.overwrite(a)
            t += len
        }
        func filler(_ track: inout Track, kind: TrackKind, count: Int, name: String) {
            var at = fd * Int64(rng.int(20))
            for i in 0..<count {
                let len = fd * Int64(8 + rng.int(40))
                let h = fd * Int64(rng.int(10))
                let c = Clip(name: "\(name)\(i)", media: UUID(), kind: kind, source: TimeRange(start: h, duration: len), start: at,
                             mediaDuration: h + len + fd * Int64(rng.int(15)))
                try? track.overwrite(c)
                at += len + fd * Int64(rng.int(30))
            }
        }
        filler(&v2, kind: .video, count: 2 + rng.int(3), name: "o")
        filler(&v3, kind: .video, count: rng.int(3), name: "p")
        filler(&a2, kind: .audio, count: 1 + rng.int(3), name: "m")
        var tl = Timeline(name: "Magnetic", frameDuration: fd, tracks: [v1, v2, v3, a1, a2])
        tl.setEditMode(.magnetic)
        return tl
    }

    // MARK: Helpers

    static func bytes(_ t: Timeline) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(t)) ?? Data()
    }

    /// The tracks encoded with every attachment removed (mode switches may only change attachments).
    static func tracksWithoutAttachments(_ t: Timeline) -> Data {
        var c = t
        for i in c.tracks.indices { c.tracks[i].mapClipsKeepingTiming { var x = $0; x.attachment = nil; return x } }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(c.tracks)) ?? Data()
    }

    /// Total length of every hole of V1: before the first clip and between clips.
    static func holes(_ t: Timeline) -> Time {
        guard let mi = t.mainTrackIndex else { return .zero }
        var total = Time.zero, at = Time.zero
        for c in t.tracks[mi].clips.sorted(by: { $0.start < $1.start }) {
            if c.start > at { total += c.start - at }
            at = max(at, c.timeline.end)
        }
        return total
    }

    static func problems(_ t: Timeline) -> [String] {
        var out = EditInvariantFuzzTests.problems(t)
        for tr in t.tracks { for c in tr.clips where c.start < .zero || c.duration <= .zero { out.append("bad clip \(c.name)") } }
        return out
    }

    /// Fast Cut: every attachable clip has a valid attachment and deriving changes nothing.
    static func attachmentProblems(_ t: Timeline) -> [String] {
        var out: [String] = []
        var d = t
        d.deriveAttachments()
        if d != t { out.append("deriveAttachments is not a no-op") }
        guard let mi = t.mainTrackIndex, !t.tracks[mi].clips.isEmpty else { return out }
        for tr in t.tracks { for c in tr.clips where t.isAttachable(c.id) {
            if c.attachment == nil { out.append("attachable clip \(c.name) has no attachment") }
            else if !t.isAttachmentValid(c.id) { out.append("attachment of \(c.name) invalid") }
        } }
        return out
    }

    struct Placed: Equatable { var start: Time; var duration: Time; var source: TimeRange; var media: UUID }
    static func placed(_ t: Timeline) -> [Clip.ID: Placed] {
        var out: [Clip.ID: Placed] = [:]
        for c in t.tracks.flatMap(\.clips) { out[c.id] = Placed(start: c.start, duration: c.duration, source: c.source, media: c.media) }
        return out
    }

    /// Media frame under timeline time `at` on V1 (constant speed material only).
    static func frameUnder(_ t: Timeline, _ at: Time) -> (UUID, Time)? {
        guard let mi = t.mainTrackIndex, let c = t.tracks[mi].clips.first(where: { $0.timeline.contains(at) }),
              c.speedKeys == nil else { return nil }
        return (c.media, c.source.start + (at - c.start))
    }
    static func cover(_ t: Timeline, _ media: UUID, _ s: Time) -> Int {
        guard let mi = t.mainTrackIndex else { return 0 }
        return t.tracks[mi].clips.filter { $0.media == media && $0.source.start <= s && s < $0.source.end }.count
    }

    enum Kind { case follow, spacer, other }

    /// True when every main clip and its linked partners cover the same span (no J/L cut, no trimmed-apart pair).
    static func pairsMatch(_ t: Timeline) -> Bool {
        guard let mi = t.mainTrackIndex else { return true }
        for c in t.tracks[mi].clips { guard let l = c.link else { continue }
            for (i, tr) in t.tracks.enumerated() where i != mi { for p in tr.clips where p.link == l && (p.start != c.start || p.duration != c.duration) { return false } } }
        return true
    }

    static func holeCount(_ t: Timeline) -> Int {
        guard let mi = t.mainTrackIndex else { return 0 }
        let c = t.tracks[mi].clips.sorted { $0.start < $1.start }
        return (c.first.map { $0.start > .zero ? 1 : 0 } ?? 0) + zip(c, c.dropFirst()).filter { $0.timeline.end < $1.start }.count
    }

    // MARK: Run

    @Test(arguments: seeds)
    func randomMagneticOpsKeepEveryInvariant(seed: UInt64) {
        if let only = ProcessInfo.processInfo.environment["SQ_FUZZ_SEED"].flatMap(UInt64.init), only != seed { return }
        var rng = LCG(s: seed &* 7919)
        var hist = History(Self.make(seed: seed), limit: 50)
        var log: [String] = []
        var ctx = ""
        var failed = false
        func fail(_ what: String) { failed = true; Issue.record("seed \(seed): \(what)\n\(ctx)\ncommands:\(log.suffix(12).joined(separator: " | "))") }
        let fd = Self.fd
        var applied = 0
        var tally: [String: Int] = [:]
        let first = Self.problems(hist.current) + Self.attachmentProblems(hist.current)
        if !first.isEmpty { fail("generated timeline invalid \(first)"); return }

        func fr(_ t: Time) -> String { String(format: "%.1ff", Double(t.value) / Double(t.timescale) / (Double(fd.value) / Double(fd.timescale))) }
        func sid(_ c: Clip) -> String { "\(c.name)#\(c.id.uuidString.prefix(4))" }

        func dump(_ t: Timeline) -> String {
            t.tracks.enumerated().map { i, tr in
                "T\(i)[" + tr.clips.map { c in
                    "\(sid(c)) \(fr(c.start))+\(fr(c.duration)) s\(fr(c.source.start))"
                        + (c.attachment.map { "<\($0.host.uuidString.prefix(4))@\(fr($0.point))>" } ?? "")
                }.joined(separator: ", ") + "]"
            }.joined(separator: "\n  ")
        }

        func newSource() -> [Clip] {
            let len = fd * Int64(1 + rng.int(40))
            let h = fd * Int64(rng.int(6))
            let md = h + len + fd * Int64(rng.int(10))
            let m = UUID()
            switch rng.int(4) {
            case 0:
                return [Clip(name: "n", media: m, kind: .audio, source: TimeRange(start: h, duration: len), start: .zero, mediaDuration: md)]
            case 1:
                let l = UUID()
                var v = Clip(name: "nv", media: m, kind: .video, source: TimeRange(start: h, duration: len), start: .zero, mediaDuration: md)
                var a = Clip(name: "na", media: m, kind: .audio, source: TimeRange(start: h, duration: len), start: .zero, mediaDuration: md)
                v.link = l; a.link = l
                return [v, a]
            default:
                return [Clip(name: "nv", media: m, kind: .video, source: TimeRange(start: h, duration: len), start: .zero, mediaDuration: md)]
            }
        }

        for step in 0..<Self.steps {
            let t0 = hist.current
            let all = t0.tracks.flatMap(\.clips)
            if all.isEmpty || all.count > 60 || t0.tracks.count > 10 || t0.mainTrackIndex.map({ t0.tracks[$0].clips.isEmpty }) == true {
                var f = Self.make(seed: seed &+ UInt64(step) &+ 9000)
                if t0.editMode == .normal { f.editMode = .normal }
                hist = History(f, limit: 50)
                log.append("\(step): fresh timeline")
                continue
            }
            let mi = t0.mainTrackIndex!
            let main = t0.tracks[mi].clips
            let endSeconds = Double(t0.mainTrackEnd.value) / Double(t0.mainTrackEnd.timescale)
            let endFrames = max(Int(endSeconds / (Double(fd.value) / Double(fd.timescale))), 1)
            let anyClip = all[rng.int(all.count)]
            let mainClip = main[rng.int(main.count)]
            let offMain = all.filter { c in !main.contains { $0.id == c.id } }
            let attachedClip = offMain.isEmpty ? anyClip : offMain[rng.int(offMain.count)]
            let at = fd * Int64(rng.int(endFrames + 20))
            let d = rng.delta(maxFrames: 25, fd: fd, offFrame: false)
            let keep = rng.chance(4)
            let tracksAll = t0.tracks.map(\.id)
            let someTracks = rng.chance(2) ? tracksAll : tracksAll.filter { _ in rng.chance(2) }
            let range = TimeRange(start: at, duration: fd * Int64(1 + rng.int(30)))
            let ids: Set<Clip.ID> = rng.chance(2) ? [anyClip.id] : Set(all.filter { _ in rng.chance(8) }.map(\.id))
            let runStart = rng.int(main.count)
            var runEnd = runStart
            for _ in 0..<rng.int(3) where runEnd + 1 < main.count && main[runEnd].timeline.end == main[runEnd + 1].start { runEnd += 1 }
            let runIds: Set<Clip.ID> = rng.chance(4) ? [attachedClip.id] : Set(main[runStart...runEnd].map(\.id))
            // Any track, V1 included (moveAttached / dragOff onto V1 must refuse).
            func pickTrack() -> Track.ID { tracksAll[rng.int(tracksAll.count)] }
            let op = rng.int(36)
            var name = "op \(op)"
            var kind = Kind.other
            var edit: ((inout Timeline) throws -> Void)?
            var modeSwitch: TimelineEditMode?
            var content = false          // invariant 4 applies
            var movers: [Clip.ID] = []   // attached clips exempt from 3/4
            switch op {
            case 0: let c = newSource(); name = "append \(c.count)x"; kind = .follow; content = true
                edit = { _ = try $0.appendToMainTrack(c, playhead: at) }
            case 1, 2: let c = newSource(); name = "insert \(c.count)x at \(fr(at))"; kind = .follow; content = true
                edit = { _ = try $0.insertOnMainTrack(c, at: at) }
            case 3: let c = newSource(); name = "overwrite \(c.count)x at \(fr(at))"
                edit = { _ = try $0.overwriteOnMainTrack(c, at: at) }
            case 4: let c = newSource(); let b = rng.chance(2); name = "attach \(c.count)x at \(fr(at)) back \(b)"
                edit = { _ = try $0.attach(c, at: at, backtimed: b) }
            case 5: let c = newSource(); let kl = rng.chance(2); name = "replace \(sid(mainClip)) keepLength \(kl)"
                edit = { try $0.replaceOnMainTrack(mainClip.id, with: c, keepLength: kl) }
            case 6, 7: name = "delete \(ids.count) keep \(keep)"; kind = keep ? .other : .follow; content = !keep
                edit = { try $0.magneticDelete(ids, keepAttached: keep) }
            case 8: name = "spacer-replace \(ids.count)"; kind = .spacer
                edit = { try $0.replaceWithSpacer(ids) }
            case 9: name = "delete spacer at \(fr(at)) keep \(keep)"
                edit = { _ = try $0.deleteSpacer(at: at, keepAttached: keep) }
            case 10: let l = fd * Int64(1 + rng.int(20)); name = "insert spacer \(fr(l)) at \(fr(at))"; kind = .spacer
                edit = { try $0.insertSpacer(at: at, duration: l) }
            case 11, 12: let e: ClipEdge = rng.chance(2) ? .head : .tail; name = "ripple trim \(e) \(fr(d)) \(sid(mainClip))"; kind = .follow; content = true
                edit = { _ = try $0.magneticRippleTrim(mainClip.id, edge: e, by: d) }
            case 13: let e: ClipEdge = rng.chance(2) ? .head : .tail; name = "ripple trim attached \(e) \(fr(d)) \(sid(attachedClip))"
                edit = { _ = try $0.magneticRippleTrim(attachedClip.id, edge: e, by: d) }
            case 14: name = "roll \(fr(d)) \(sid(anyClip))"
                edit = { _ = try $0.magneticRoll(anyClip.id, by: d) }
            case 15: name = "slip \(fr(d)) \(sid(anyClip))"
                edit = { _ = try $0.magneticSlip(anyClip.id, by: d, keyframes: .stay) }
            case 16: name = "slide \(fr(d)) \(sid(anyClip))"; kind = .follow
                edit = { _ = try $0.magneticSlide(anyClip.id, by: d) }
            case 17: name = "add edit at \(fr(at))"; content = true
                edit = { _ = try $0.magneticAddEdit(at: at, selection: ids) }
            case 18: name = "add edit all at \(fr(at))"; content = true
                edit = { _ = try $0.magneticAddEditAll(at: at) }
            case 19: let sel: Set<Clip.ID>? = rng.chance(2) ? nil : ids; name = "join \(sel?.count ?? -1)"; content = true
                edit = { _ = try $0.magneticJoin(selection: sel) }
            case 20, 21: name = "rearrange \(sid(mainClip)) to \(fr(at)) keep \(keep)"; kind = keep ? .other : .follow; content = !keep
                edit = { try $0.magneticRearrange(mainClip.id, to: at, keepAttached: keep) }
            case 22: name = "move attached \(sid(attachedClip)) to \(fr(at))"
                edit = { try $0.moveAttached(attachedClip.id, to: at) }
            case 23: let tr = pickTrack(); name = "move attached \(sid(attachedClip)) to \(fr(at)) track \(tr)"
                edit = { try $0.moveAttached(attachedClip.id, to: at, track: tr) }
            case 24: name = "lift off main \(ids.count)"; kind = .spacer
                edit = { try $0.liftOffMainTrack(ids) }
            case 25: name = "put on main \(ids.count)"; kind = .spacer
                edit = { try $0.putOnMainTrack(ids) }
            case 26: let tr = pickTrack(); name = "drag off \(sid(mainClip)) to \(tr) at \(fr(at)) keep \(keep)"
                edit = { try $0.dragOffMainTrack(mainClip.id, to: tr, at: at, keepAttached: keep) }
            case 27: let o = rng.chance(2); name = "drag onto main \(sid(attachedClip)) at \(fr(at)) overwrite \(o)"; if o { kind = .spacer }
                edit = { try $0.dragOntoMainTrack(attachedClip.id, at: at, overwrite: o) }
            case 28: name = "set attach point \(sid(attachedClip)) at \(fr(at))"
                edit = { try $0.setAttachPoint(attachedClip.id, at: at) }
            case 29, 30:
                let att = rng.chance(3); let ids = runIds; name = "paste \(ids.count) at \(fr(at)) attached \(att)"; content = !att
                edit = { tl in
                    guard let cb = tl.magneticClipboard(copying: ids) else { throw EditError.clipNotFound }
                    _ = try tl.magneticPaste(cb, at: at, attached: att)
                }
            case 31: let ids = runIds; name = "duplicate \(ids.count)"
                edit = { _ = try $0.magneticDuplicate(ids) }
            case 32:
                if rng.chance(2) { name = "extract \(fr(range.start))+\(fr(range.duration))"; edit = { _ = try $0.magneticExtract(range, tracks: someTracks) } }
                else { name = "clear range \(fr(range.start))+\(fr(range.duration))"; kind = .spacer; edit = { try $0.magneticClearRange(range, tracks: someTracks) } }
            case 33: let l = fd * Int64(1 + rng.int(20)); name = "insert frame hold \(sid(mainClip)) at \(fr(at))"; kind = .follow
                edit = { _ = try $0.magneticInsertFrameHold(of: mainClip.id, at: at, duration: l) }
            case 34: name = "add frame hold \(sid(anyClip)) at \(fr(at))"
                edit = { _ = try $0.magneticAddFrameHold(of: anyClip.id, at: at) }
            default:
                switch rng.int(5) {
                case 2: name = "undo"
                case 3: name = "redo"
                default: modeSwitch = t0.editMode == .normal ? .magnetic : .normal; name = "switch mode to \(modeSwitch!)"
                }
            }
            _ = movers
            log.append("\(step): \(name)")
            if name == "undo" { hist.undo() }
            else if name == "redo" { hist.redo() }
            else if let m = modeSwitch {
                var probe = hist
                probe.commit(name) { $0.setEditMode(m) }
                let after = probe.current
                if after.editMode != m { fail("mode not switched") }
                if Self.tracksWithoutAttachments(after) != Self.tracksWithoutAttachments(t0) { fail("mode switch moved clips or changed sources"); return }
                if m == .magnetic, !Self.attachmentProblems(after).isEmpty { fail("after switching to Fast Cut: \(Self.attachmentProblems(after))"); return }
                if m == .normal {
                    var same = t0; same.editMode = .normal
                    if Self.bytes(after) != Self.bytes(same) { fail("leaving Fast Cut changed more than the mode") }
                }
                hist = probe
            } else {
                do {
                    var probe = hist
                    try probe.commit(name) { try edit!(&$0) }
                    guard probe.current != t0 else { continue }
                    hist = probe
                    applied += 1
                    tally[String(name.prefix(while: { $0 != " " })), default: 0] += 1
                    let after = probe.current
                    ctx = "before:\n  \(dump(t0))\nafter:\n  \(dump(after))"
                    var round = hist
                    round.undo()
                    if round.current != t0 || Self.bytes(round.current) != Self.bytes(t0) { fail("undo did not restore the snapshot after \(name)") }
                    round.redo()
                    if round.current != after || Self.bytes(round.current) != Self.bytes(after) { fail("redo did not re-apply \(name)") }
                    if t0.isFastCut && after.isFastCut {
                        let trimLike = name.hasPrefix("slide") || name.hasPrefix("roll") || name.hasPrefix("ripple trim")
                        if kind != .spacer, trimLike ? Self.holeCount(after) > Self.holeCount(t0) : Self.holes(after) > Self.holes(t0) {
                            fail("V1 gained hole length after \(name): \(fr(Self.holes(t0))) -> \(fr(Self.holes(after)))")
                        }
                        let before = Self.placed(t0), now = Self.placed(after)
                        // 3: followers follow (follow verbs only, a main clip that moved whole).
                        if kind == .follow {
                            for x in main {
                                guard let b = before[x.id], let n = now[x.id], b.source == n.source, b.duration == n.duration, n.start != b.start,
                                      after.isOnMainTrack(x.id) else { continue }
                                let shift = n.start - b.start
                                let fits: (Clip) -> Bool = { $0.start + shift >= .zero }
                                for tr in t0.tracks where !tr.isLocked {
                                    for a in tr.clips where a.attachment?.host == x.id {
                                        guard let na = now[a.id], !after.isOnMainTrack(a.id) else { continue }
                                        if !fits(a) { continue }
                                        if let pa = before[a.id], pa.duration != na.duration || pa.source != na.source { continue }
                                        if na.start - a.start != shift {
                                            fail("\(name): clip \(a.name) attached to \(x.name) moved \(fr(na.start - a.start)) but host moved \(fr(shift))")
                                        }
                                    }
                                }
                            }
                        }
                        // 4: content sync.
                        if content {
                            for a in all where a.attachment != nil && t0.isAttachable(a.id) {
                                guard let na = after.find(a.id)?.clip, let nat = na.attachment,
                                      na.duration == a.duration, na.source == a.source, after.isAttachable(a.id), na.start > .zero else { continue }
                                let t = a.start + a.attachment!.point, t2 = na.start + nat.point
                                guard let (m, s) = Self.frameUnder(t0, t), Self.cover(t0, m, s) == 1, Self.cover(after, m, s) == 1,
                                      let (m2, s2) = Self.frameUnder(after, t2) else { continue }
                                if m != m2 || s != s2 {
                                    fail("\(name): attached \(a.name) lost its content frame (\(fr(s)) -> \(fr(s2)))")
                                }
                            }
                        }
                    }
                    // 5: linked groups keep their internal offsets (both members survive unchanged in length and source).
                    let exempt = ["move attached", "drag", "set attach", "put on", "slip", "roll", "slide", "lift off", "spacer", "insert spacer", "clear range"]
                    // Normal ripple trim / replace with a split-edit (J/L) pair: each track ripples from its own pivot,
                    // like Premiere, so a pair straddling it can shift (by design, Normal engine).
                    let normalSplitTrim = !t0.isFastCut && (name.hasPrefix("ripple trim") || name.hasPrefix("replace")) && !Self.pairsMatch(t0)
                    if !normalSplitTrim, !exempt.contains(where: { name.hasPrefix($0) }) {
                        let o0 = EditInvariantFuzzTests.linkOffsets(t0), o1 = EditInvariantFuzzTests.linkOffsets(after)
                        let b0 = Self.placed(t0), b1 = Self.placed(after)
                        for (k, v) in o1 {
                            guard let was = o0[k], was != v, (was < .zero ? .zero - was : was) <= fd * 10 else { continue }
                            let ids = k.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                            // Normal: a member on a track without sync lock does not ripple (Premiere desync, by design).
                            let unsynced = !t0.isFastCut && ids.contains { id in t0.find(id).map { !t0.tracks[$0.track].followsRipple } ?? false }
                            // Normal insert pushes from the insert point on every track: a split (J/L) pair across it
                            // separates, like Premiere (by design, Normal engine).
                            let normalSplitInsert = !t0.isFastCut && name.hasPrefix("insert") && was != .zero
                            if ids.count == 2, !unsynced, !normalSplitInsert, ids.allSatisfy({ b0[$0]?.duration == b1[$0]?.duration && b0[$0]?.source == b1[$0]?.source }) {
                                fail("\(name) [\(t0.isFastCut ? "Fast Cut" : "Normal")]: linked pair \(k) changed offset \(was) -> \(v)\n\(EditInvariantFuzzTests.describe(t0, after, k))")
                            }
                        }
                    }
                } catch is EditError {
                    // refused: nothing changed
                } catch {
                    fail("non-EditError \(error) from \(name)")
                }
            }
            if failed { return }
            let p = Self.problems(hist.current)
            if !p.isEmpty { fail("after \(name): \(p)"); return }
            if hist.current.isFastCut {
                let ap = Self.attachmentProblems(hist.current)
                if !ap.isEmpty { fail("state after \(name): \(ap)"); return }
            }
        }
        #expect(applied > Self.steps / 8, "seed \(seed): the run did too little (applied \(applied)): \(tally)")
    }

    /// Speed ramps and Speed/Duration on main and attached clips never leave V1 a hole or an overlap, and the attached
    /// clips stay attached (the retime verbs get their own run: the content-frame helpers above assume speed 1, and
    /// trims of retimed clips are a separate story).
    @Test(arguments: seeds)
    func speedEditsKeepFastCutGapless(seed: UInt64) {
        var rng = LCG(s: seed &* 17)
        var tl = Self.make(seed: seed)
        tl.setEditMode(.magnetic)
        var applied = 0
        for step in 0..<60 {
            let all = tl.tracks.flatMap(\.clips)
            guard let mi = tl.mainTrackIndex, !all.isEmpty, !tl.tracks[mi].clips.isEmpty else { return }
            let main = tl.tracks[mi].clips
            let c = rng.chance(3) ? all[rng.int(all.count)] : main[rng.int(main.count)]
            let pct = Double([50, 100, 150, 200, 400][rng.int(5)])
            var next = tl
            do {
                switch rng.int(3) {
                case 0:
                    try next.magneticApply(SpeedChange(speed: ClipSpeed(percent: pct)), to: [c.id])
                case 1:
                    try next.magneticEditSpeedKeys(c.id) { k in
                        let half = Time(k.duration.value, k.duration.timescale * 2)
                        guard half > .zero else { return nil }
                        return SpeedKeys(segments: [SpeedSegment(duration: half, from: .normal),
                                                    SpeedSegment(duration: k.duration - half, from: ClipSpeed(percent: pct))],
                                         origin: k.origin)
                    }
                default:
                    try next.magneticApply(SpeedChange(duration: Self.fd * Int64(2 + rng.int(40))), to: [c.id])
                }
            } catch is EditError { continue } catch { Issue.record("seed \(seed) step \(step): \(error)"); return }
            guard next != tl else { continue }
            applied += 1
            if Self.holeCount(next) > Self.holeCount(tl) { Issue.record("seed \(seed) step \(step): V1 gained a hole"); return }
            let p = Self.problems(next) + Self.attachmentProblems(next)
            if !p.isEmpty { Issue.record("seed \(seed) step \(step): \(p)"); return }
            tl = next
        }
        #expect(applied > 5, "seed \(seed): too little applied (\(applied))")
    }

    /// Invariant 8 / v66: a sequence that never enters Fast Cut stores no v67 key however the verbs run.
    @Test(arguments: seeds)
    func normalOnlyRunNeverWritesV67Keys(seed: UInt64) {
        var rng = LCG(s: seed &* 31)
        var tl = Self.make(seed: seed)
        for i in tl.tracks.indices { tl.tracks[i].mapClipsKeepingTiming { var x = $0; x.attachment = nil; return x } }
        tl.editMode = .normal
        let fd = Self.fd
        for _ in 0..<min(Self.steps, 200) {
            let all = tl.tracks.flatMap(\.clips)
            guard !all.isEmpty, all.count < 60 else { break }
            let c = all[rng.int(all.count)]
            let at = fd * Int64(rng.int(300)), d = rng.delta(maxFrames: 20, fd: fd, offFrame: false)
            let len = fd * Int64(1 + rng.int(30))
            let n = Clip(name: "n", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: len), start: .zero, mediaDuration: len + fd * 5)
            switch rng.int(8) {
            case 0: _ = try? tl.insertOnMainTrack([n], at: at)
            case 1: _ = try? tl.overwriteOnMainTrack([n], at: at)
            case 2: _ = try? tl.attach([n], at: at)
            case 3: try? tl.magneticDelete([c.id])
            case 4: _ = try? tl.magneticRippleTrim(c.id, edge: .tail, by: d)
            case 5: try? tl.magneticRearrange(c.id, to: at)
            case 6: _ = try? tl.magneticAddEdit(at: at, selection: [c.id])
            default: try? tl.insertSpacer(at: at, duration: len)
            }
            let s = String(decoding: Self.bytes(tl), as: UTF8.self)
            #expect(!s.contains("\"attachment\"") && !s.contains("\"editMode\""), "seed \(seed): Normal-only run wrote a v67 key")
            #expect(Self.problems(tl).isEmpty, "seed \(seed): \(Self.problems(tl))")
        }
    }
}
