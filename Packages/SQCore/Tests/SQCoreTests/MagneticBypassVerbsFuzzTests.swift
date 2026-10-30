import Foundation
import Testing
@testable import SQCore

/// Third Fast Cut gap fuzz: the Normal-engine verbs the session still calls directly (no `magneticEdit` wrapper):
/// split edits and J/L cuts, Trim mode, Snap/Cut to Beats, Move/Slip into Sync, Close Gap at playhead, Detach Audio,
/// Move Clip Up/Down, extend edit, with random track locks and sync-lock flags. After every applied op: V1 gains no
/// hole, no overlap, attachments are valid, nothing on a locked track changed.
extension MagneticInvariantFuzzTests {
    @Test(arguments: seeds)
    func directSessionVerbsKeepFastCutGapless(seed: UInt64) {
        var rng = LCG(s: seed &* 6_151)
        let fd = Self.fd
        var tl = Self.make(seed: seed)
        var log: [String] = []
        var applied = 0
        var tally: [String: Int] = [:]
        func fr(_ t: Time) -> String { String(format: "%.1ff", Double(t.value) / Double(t.timescale) / (Double(fd.value) / Double(fd.timescale))) }
        func dump(_ t: Timeline) -> String {
            t.tracks.enumerated().map { i, tr in
                "T\(i)\(tr.isLocked ? "L" : "")\(tr.syncLock ? "" : "u")[" + tr.clips.map {
                    "\($0.name)#\($0.id.uuidString.prefix(4)) \(fr($0.start))+\(fr($0.duration))s\(fr($0.source.start))"
                        + ($0.attachment.map { "<\($0.host.uuidString.prefix(4))@\(fr($0.point))>" } ?? "")
                }.joined(separator: ", ") + "]"
            }.joined(separator: "\n  ")
        }
        for step in 0..<Self.steps {
            let all = tl.tracks.flatMap(\.clips)
            guard let mi = tl.mainTrackIndex, !tl.tracks[mi].clips.isEmpty, all.count < 50 else {
                tl = Self.make(seed: seed &+ UInt64(step) &+ 7000); continue
            }
            let main = tl.tracks[mi].clips
            let endFrames = max(Int(Double(tl.mainTrackEnd.value) / Double(tl.mainTrackEnd.timescale) / (Double(fd.value) / Double(fd.timescale))), 1)
            let at = fd * Int64(rng.int(endFrames + 10))
            let d = rng.delta(maxFrames: 20, fd: fd, offFrame: false)
            let anyClip = all[rng.int(all.count)]
            let mainClip = main[rng.int(main.count)]
            let ids: Set<Clip.ID> = rng.chance(2) ? [anyClip.id] : Set(all.filter { _ in rng.chance(6) }.map(\.id))
            var name = ""
            var edit: ((inout Timeline) throws -> Void)?
            var setup: ((inout Timeline) -> Void)?
            func beats() -> (inout Timeline) -> Void {
                let n = 2 + rng.int(8)
                let times = (0..<n).map { _ in fd * Int64(rng.int(endFrames + 20)) }
                return { t in _ = t.replaceBeatMarkers(in: TimeRange(start: .zero, duration: t.mainTrackEnd + fd * 40), with: times) }
            }
            switch rng.int(24) {
            case 0, 1:
                let side: SplitEditSide = rng.chance(2) ? .audio : .video
                let cuts = main.dropFirst().map(\.start)
                let cut = cuts.isEmpty ? at : cuts[rng.int(cuts.count)]
                name = "split edit \(side) cut \(fr(cut)) to \(fr(cut + d))"
                edit = { _ = try $0.splitEdit(cut: cut, side: side, to: cut + d) }
            case 2:
                let k: JLCut = rng.chance(2) ? .jCut : .lCut
                name = "jl \(k) at \(fr(at))"
                edit = { _ = try $0.splitEditJL(k, at: at) }
            case 3, 4, 5:
                let tr = tl.tracks[rng.int(tl.tracks.count)]
                guard !tr.clips.isEmpty else { continue }
                let c = tr.clips[rng.int(tr.clips.count)]
                let prev = tr.clips.first { $0.timeline.end == c.start }
                let side = TrimSide.allCases[rng.int(3)]
                let p = TrimPoint(track: tr.id, outgoing: rng.chance(4) ? nil : prev?.id, incoming: c.id, time: c.start)
                name = "trim edit \(side) \(fr(d)) on \(c.name) (T\(tl.tracks.firstIndex { $0.id == tr.id }!))"
                edit = { _ = try $0.trimEdit(p, side: side, by: d) }
            case 6, 7:
                name = "snap to beats \(ids.count)"
                setup = beats()
                edit = { _ = try $0.snapToBeats(clips: Array(ids)) }
            case 8:
                name = "cut to beats \(ids.count)"
                setup = beats()
                edit = { _ = try $0.cutToBeats(clips: ids) }
            case 9, 10, 11:
                // Drift a clip out of sync, then bring it back with Move into Sync / Slip into Sync.
                let slip = rng.chance(2)
                let pick = rng.chance(2) ? mainClip : anyClip
                guard pick.link != nil else { continue }
                let k = fd * Int64(1 + rng.int(6))
                name = "\(slip ? "slip" : "move") into sync \(pick.name)"
                setup = { t in
                    guard let ti = t.tracks.firstIndex(where: { $0.clip(pick.id) != nil }), var c = t.tracks[ti].clip(pick.id) else { return }
                    if let md = c.mediaDuration, c.source.end + k > md { c.source.start -= k } else { c.source.start += k }
                    guard c.source.start >= .zero else { return }
                    t.tracks[ti].replace(c)
                }
                edit = { slip ? try $0.slipIntoSync(pick.id) : try $0.moveIntoSync(pick.id) }
            case 12, 13:
                // The session guards Close Gap in Fast Cut (Delete Spacer); the raw verb only runs on tracks with a gap.
                name = "delete spacer at \(fr(at))"
                edit = { _ = try $0.deleteSpacer(at: at, keepAttached: false) }
            case 14:
                name = "detach audio \(ids.count)"
                edit = { _ = try $0.detachAudio(of: ids) }
            case 15, 16:
                let up = rng.chance(2)
                // A main-track clip going up is Lift off Main Track: its spacer stays by design.
                let lift = up && ids.contains { tl.isOnMainTrack($0) }
                name = lift ? "spacer lane up \(ids.count)" : "move to lane \(up ? "up" : "down") \(ids.count)"
                edit = { _ = try $0.magneticMoveToLane(ids, up: up) }
            case 17:
                let i = rng.int(tl.tracks.count)
                name = "toggle lock T\(i)"
                edit = { $0.tracks[i].isLocked.toggle() }
            case 18:
                let i = rng.int(tl.tracks.count)
                name = "toggle sync lock T\(i)"
                edit = { $0.tracks[i].syncLock.toggle() }
            case 19:
                let e: ClipEdge = rng.chance(2) ? .head : .tail
                name = "extend edit \(mainClip.name) \(e) to \(fr(at))"
                edit = { tl in try tl.magneticEdit(stay: .all) { _ = try $0.extendEdit(mainClip.id, edge: e, to: at) } }
            case 20:
                let e: ClipEdge = rng.chance(2) ? .head : .tail
                name = "ripple trim to playhead \(e) at \(fr(at))"
                edit = { _ = try $0.magneticRippleTrimToPlayhead(e, at: at) }
            case 21:
                name = "add edit at \(fr(at)) all tracks"
                edit = { _ = try $0.magneticAddEditAll(at: at) }
            case 22:
                let l = Set(all.filter { $0.link != nil && $0.link == anyClip.link }.map(\.id))
                name = "unlink group of \(anyClip.name)"
                edit = { try $0.unlink(l) }
            default:
                let sel = Set(main.filter { $0.start >= mainClip.start }.prefix(2).map(\.id))
                name = "nudge \(sel.count) by \(fr(d))"
                edit = { _ = try $0.magneticNudge(sel, by: d) }
            }
            log.append("\(step): \(name)")
            var work = tl
            setup?(&work)
            let t0 = work
            do { try edit!(&work) } catch is EditError { tl = t0; continue } catch { Issue.record("seed \(seed): non-EditError \(error) from \(name)"); return }
            guard work != t0 else { tl = t0; continue }
            applied += 1
            tally[String(name.prefix(while: { $0 != " " })), default: 0] += 1
            func fail(_ what: String) {
                Issue.record("seed \(seed) step \(step): \(what)\nbefore:\n  \(dump(t0))\nafter:\n  \(dump(work))\ncommands:\(log.suffix(6).joined(separator: " | "))")
            }
            let probs = Self.problems(work)
            if !probs.isEmpty { fail("\(name): \(probs)"); return }
            if !name.hasPrefix("spacer"), Self.holes(work) > Self.holes(t0) { fail("V1 gained hole after \(name): \(fr(Self.holes(t0))) -> \(fr(Self.holes(work)))"); return }
            // Attachments are not checked: these raw verbs leave them stale and the next `magneticEdit` re-derives them.
            if !name.hasPrefix("toggle") {
                let b0 = Self.placed(t0), b1 = Self.placed(work)
                for tk in t0.tracks where tk.isLocked {
                    for c in tk.clips where b0[c.id] != b1[c.id] { fail("\(name) changed \(c.name) on a locked track"); return }
                }
            }
            // A spacer (Lift off Main Track) leaves a hole by design; later ops on a holey V1 may widen it, so start over.
            tl = Self.holes(work) == .zero ? work : Self.make(seed: seed &+ UInt64(step) &+ 9000)
        }
        #expect(applied > Self.steps / 10, "seed \(seed): too little applied (\(applied)): \(tally)")
    }
}
