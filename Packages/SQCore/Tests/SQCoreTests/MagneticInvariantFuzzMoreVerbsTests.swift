import Foundation
import Testing
@testable import SQCore

/// Second invariant fuzz of the Fast Cut verbs (see MagneticInvariantFuzzTests): the verbs the main run does not reach.
/// Speed keys (add, set value, remove), speed and reverse, frame holds on main / attached / audio clips, nest and unnest,
/// transitions on V1 and audio cuts, link / unlink / add track, caption edits, locked tracks, `.only`-scoped moves of
/// linked audio (what the session builds for an unlinked-selection drag), mixed with delete / ripple trim / rearrange so
/// the verbs meet transitions. After every applied op: V1 is gapless (the sequence starts gapless and none of these makes
/// a spacer), attachments are valid, no clip of a locked track changed, linked groups keep their offsets (the group an
/// op edits on purpose is exempt), caption edits leave every clip alone.
extension MagneticInvariantFuzzTests {
    @Test(arguments: seeds)
    func moreVerbsKeepFastCutGaplessAndInSync(seed: UInt64) {
        var rng = LCG(s: seed &* 4_241)
        let fd = Self.fd
        var tl0 = Self.make(seed: seed)
        for ti in tl0.tracks.indices {
            let kind: TransitionKind = tl0.tracks[ti].kind == .video ? .crossDissolve : .constantPower
            let clips = tl0.tracks[ti].clips
            for (l, r) in zip(clips, clips.dropFirst()) where l.timeline.end == r.start && rng.chance(3) {
                _ = try? tl0.addTransition(point: .cut(outgoing: l.id, incoming: r.id), kind: kind, track: tl0.tracks[ti].id,
                                           duration: fd * Int64(2 + rng.int(8)))
            }
        }
        let capTrack = tl0.addCaptionTrack()
        let items = (0..<4).map { i in CaptionItem(lines: ["c\(i)"], range: TimeRange(start: fd * Int64(i * 40), duration: fd * 30)) }
        _ = try? tl0.replaceCaptions(items, track: capTrack)
        let first = Self.problems(tl0) + Self.attachmentProblems(tl0)
        guard first.isEmpty, Self.holes(tl0) == .zero else { Issue.record("seed \(seed): generated \(first)"); return }
        var project = Project(name: "P", timelines: [tl0])
        var log: [String] = []
        var applied = 0
        var tally: [String: Int] = [:]

        func fr(_ t: Time) -> String { String(format: "%.1ff", Double(t.value) / Double(t.timescale) / (Double(fd.value) / Double(fd.timescale))) }
        func fail(_ what: String, _ before: Timeline, _ after: Timeline) {
            func dump(_ t: Timeline) -> String {
                t.tracks.enumerated().map { i, tr in
                    "T\(i)\(tr.isLocked ? "L" : "")[" + tr.clips.map {
                        "\($0.name)#\($0.id.uuidString.prefix(4)) \(fr($0.start))+\(fr($0.duration))s\(fr($0.source.start))"
                            + ($0.link.map { "~\($0.uuidString.prefix(3))" } ?? "")
                    }.joined(separator: ", ") + "]"
                }.joined(separator: "\n  ")
            }
            Issue.record("seed \(seed): \(what)\nbefore:\n  \(dump(before))\nafter:\n  \(dump(after))\ncommands:\(log.suffix(10).joined(separator: " | "))")
        }

        for step in 0..<Self.steps {
            let t0 = project.timelines[0]
            let all = t0.tracks.flatMap(\.clips)
            guard t0.isFastCut, !all.isEmpty, all.count < 50, t0.tracks.count < 9, t0.mainTrackIndex.map({ !t0.tracks[$0].clips.isEmpty }) == true else {
                project = Project(name: "P", timelines: [Self.make(seed: seed &+ UInt64(step) &+ 5000)])
                log.append("\(step): fresh"); continue
            }
            let mi = t0.mainTrackIndex!
            let main = t0.tracks[mi].clips
            let anyClip = all[rng.int(all.count)]
            let mainClip = main[rng.int(main.count)]
            let linkedAudio = all.filter { a in a.kind == .audio && a.link != nil && main.contains { $0.link == a.link } }
            let audio: Clip? = linkedAudio.isEmpty ? nil : linkedAudio[rng.int(linkedAudio.count)]
            let endFrames = max(Int(Double(t0.mainTrackEnd.value) / Double(t0.mainTrackEnd.timescale) / (Double(fd.value) / Double(fd.timescale))), 1)
            let at = fd * Int64(rng.int(endFrames + 10))
            let d = rng.delta(maxFrames: 20, fd: fd, offFrame: false)
            let pct = Double([25, 50, 100, 150, 250, 400][rng.int(6)])
            let tr = t0.tracks[rng.int(t0.tracks.count)]
            var name = ""
            var group: UUID?                 // link group the op edits on purpose (its offsets may change)
            var edit: ((inout Project) throws -> Void)?
            var tlEdit: ((inout Timeline) throws -> Void)?
            var captionOp = false
            switch rng.int(30) {
            case 0, 1:
                name = "speed \(Int(pct))% \(anyClip.name)"; group = anyClip.link
                tlEdit = { try $0.magneticApply(SpeedChange(speed: ClipSpeed(percent: pct)), to: [anyClip.id]) }
            case 2:
                name = "reverse \(mainClip.name)"; group = mainClip.link
                tlEdit = { try $0.magneticApply(SpeedChange(reversed: true), to: [mainClip.id]) }
            case 3, 4:
                name = "speed keys add+set \(Int(pct))% \(anyClip.name)"; group = anyClip.link
                tlEdit = { tl in
                    try tl.magneticEditSpeedKeys(anyClip.id) { k in
                        guard let (k2, b) = k.addingKey(at: k.duration.halved.snapped(to: fd), frameDuration: fd) else { return nil }
                        return k2.settingSpeed(ofSegment: b, to: ClipSpeed(percent: pct), frameDuration: fd)
                    }
                }
            case 5, 6, 7:
                let local = fd * Int64(rng.int(30))
                name = "set key value \(Int(pct))% at \(fr(local)) \(anyClip.name)"; group = anyClip.link
                tlEdit = { try $0.magneticEditSpeedKeys(anyClip.id, keepingKeys: true, refuseShortening: true) {
                    $0.settingKeySpeed(atLocal: local, to: ClipSpeed(percent: pct), frameDuration: fd) } }
            case 8:
                name = "remove speed key \(anyClip.name)"; group = anyClip.link
                tlEdit = { try $0.magneticEditSpeedKeys(anyClip.id) { k in k.segments.count > 1 ? k.removingKey(atBoundary: 1) : nil } }
            case 9:
                name = "remove ramp \(anyClip.name)"; group = anyClip.link
                tlEdit = { try $0.magneticEditSpeedKeys(anyClip.id) { k in
                    let h = k.hull
                    return SpeedKeys(constant: .normal, reversed: false, duration: h.duration, origin: h.start) } }
            case 10:
                let l = fd * Int64(1 + rng.int(15))
                name = "insert hold \(anyClip.name) at \(fr(at))"
                tlEdit = { _ = try $0.magneticInsertFrameHold(of: anyClip.id, at: at, duration: l) }
            case 11:
                name = "add hold \(anyClip.name) at \(fr(at))"
                tlEdit = { _ = try $0.magneticAddFrameHold(of: anyClip.id, at: at) }
            case 12:
                let ids = Array(main.filter { $0.start >= mainClip.start }.prefix(1 + rng.int(3)).map(\.id))
                name = "nest \(ids.count)"
                edit = { _ = try $0.magneticNest(clips: ids, in: t0.id) }
            case 13:
                guard let n = all.first(where: { $0.sequence != nil }) else { continue }
                name = "unnest \(n.name)"
                edit = { _ = try $0.unnest(clip: n.id, in: t0.id) }
            case 14, 15:
                let kind: TransitionKind = tr.kind == .video ? .crossDissolve : .constantPower
                let cl = tr.clips
                guard cl.count > 1 else { continue }
                let k = rng.int(cl.count - 1), dur = fd * Int64(2 + rng.int(10))
                name = "transition at cut \(k) of \(tr.kind)"
                tlEdit = { _ = try $0.addTransition(point: .cut(outgoing: cl[k].id, incoming: cl[k + 1].id), kind: kind, track: tr.id, duration: dur) }
            case 16:
                guard let x = tr.transitions.first else { continue }
                name = "remove transition"
                tlEdit = { try $0.removeTransition(x.id) }
            case 17:
                name = "unlink \(anyClip.name)"
                tlEdit = { try $0.unlink([anyClip.id]) }
            case 18:
                // A pair that plays together: a clip of the other kind overlapping a main clip.
                guard let m = main.first(where: { $0.kind != anyClip.kind && $0.timeline.contains(anyClip.start) }) else { continue }
                name = "link \(anyClip.name)+\(m.name)"
                tlEdit = { try $0.link([anyClip.id, m.id]) }
            case 19:
                let k: TrackKind = rng.chance(2) ? .video : .audio
                name = "add track \(k)"
                tlEdit = { _ = $0.addTrack(kind: k) }
            case 20:
                guard let ct = t0.captionTracks.first, !ct.items.isEmpty else { continue }
                let c = ct.items[rng.int(ct.items.count)]
                captionOp = true
                switch rng.int(3) {
                case 0: name = "move caption"; tlEdit = { _ = try $0.moveCaption(c.id, to: at) }
                case 1: let e: ClipEdge = rng.chance(2) ? .head : .tail; name = "trim caption"; tlEdit = { _ = try $0.trimCaption(c.id, edge: e, to: at) }
                default: name = "delete caption"; tlEdit = { try $0.deleteCaption(c.id) }
                }
            case 21:
                // Lock / unlock a track (V1 included: every verb then refuses).
                let i = rng.int(t0.tracks.count)
                name = "toggle lock T\(i)"
                tlEdit = { $0.tracks[i].isLocked.toggle() }
            case 22, 23:
                guard let a = audio else { continue }
                name = "only move \(a.name) to \(fr(at))"; group = a.link
                tlEdit = { tl in try tl.editing(only: [a.id]) { try $0.moveAttached(a.id, to: at, track: nil) } }
            case 24:
                guard let a = audio else { continue }
                let e: ClipEdge = rng.chance(2) ? .head : .tail
                name = "only ripple trim \(e) \(fr(d)) \(a.name)"; group = a.link
                tlEdit = { tl in try tl.editing(only: [a.id]) { _ = try $0.magneticRippleTrim(a.id, edge: e, by: d) } }
            case 25:
                guard let a = audio else { continue }
                name = "only delete \(a.name)"; group = a.link
                tlEdit = { tl in try tl.editing(only: [a.id]) { try $0.magneticDelete([a.id]) } }
            case 26:
                guard let a = audio else { continue }
                name = "only slip \(fr(d)) \(a.name)"; group = a.link
                tlEdit = { tl in try tl.editing(only: [a.id]) { _ = try $0.magneticSlip(a.id, by: d, keyframes: .stay) } }
            case 27:
                name = "delete \(mainClip.name)"
                tlEdit = { try $0.magneticDelete([mainClip.id]) }
            case 28:
                let e: ClipEdge = rng.chance(2) ? .head : .tail
                name = "ripple trim \(e) \(fr(d)) \(mainClip.name)"
                tlEdit = { _ = try $0.magneticRippleTrim(mainClip.id, edge: e, by: d) }
            default:
                name = "rearrange \(mainClip.name) to \(fr(at))"
                tlEdit = { try $0.magneticRearrange(mainClip.id, to: at) }
            }
            log.append("\(step): \(name)")
            var p = project
            do {
                if let tlEdit { try tlEdit(&p.timelines[0]) } else if let edit { try edit(&p) }
            } catch is EditError { continue } catch { Issue.record("seed \(seed): non-EditError \(error) from \(name)"); return }
            guard p.timelines[0] != t0 else { continue }
            let after = p.timelines[0]
            applied += 1
            tally[String(name.prefix(while: { $0 != " " })), default: 0] += 1
            let lockToggle = name.hasPrefix("toggle lock")
            let probs = Self.problems(after) + (after.isFastCut ? Self.attachmentProblems(after) : [])
            if !probs.isEmpty { fail("after \(name): \(probs)", t0, after); return }
            if Self.holes(after) > .zero { fail("V1 gained a hole after \(name): \(fr(Self.holes(after)))", t0, after); return }
            if captionOp, after.tracks != t0.tracks { fail("\(name) moved clips", t0, after); return }
            let b0 = Self.placed(t0), b1 = Self.placed(after)
            if !lockToggle {
                for tk in t0.tracks where tk.isLocked {
                    for c in tk.clips where b0[c.id] != b1[c.id] { fail("\(name) changed \(c.name) on a locked track", t0, after); return }
                }
            }
            // Linked groups other than the edited one keep their offsets; the edited one is checked only for the
            // retime verbs, whose members all keep their start (the clip start stays).
            let o0 = EditInvariantFuzzTests.linkOffsets(t0), o1 = EditInvariantFuzzTests.linkOffsets(after)
            let structural = ["link", "unlink", "nest", "unnest", "toggle"].contains { name.hasPrefix($0) }
            if !structural {
                for (k, v) in o1 {
                    // Pairs that played together (a partner moved far away by an unlinked edit follows its own track).
                    guard let was = o0[k], was != v, (was < .zero ? .zero - was : was) <= fd * 10 else { continue }
                    let ids = k.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                    guard ids.count == 2, ids.allSatisfy({ b0[$0]?.duration == b1[$0]?.duration && b0[$0]?.source == b1[$0]?.source }) else { continue }
                    if let g = group, t0.find(ids[0])?.clip.link == g { continue }
                    if ids.contains(where: { id in t0.find(id).map { t0.tracks[$0.track].isLocked } ?? false }) { continue }
                    fail("\(name): linked pair \(k) changed offset \(fr(was)) -> \(fr(v))", t0, after); return
                }
            }
            project = p
        }
        #expect(applied > Self.steps / 8, "seed \(seed): too little applied (\(applied)): \(tally)")
    }
}
