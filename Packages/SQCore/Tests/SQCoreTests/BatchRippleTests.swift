import Foundation
import Testing
@testable import SQCore

/// One-sweep batch ripple ("Remove Silences", filler words, accepted proposed cuts): `removeSilences` removes every cut in
/// one pass. The oracle is the old sequential path (one `extract` per cut, last cut first), kept here as
/// `removeSilencesSequential`: on seeded random timelines (linked A/V with J/L cuts, gaps, transitions, keys, speed,
/// B-roll with linked sound, music, tracks with and without sync lock, locked tracks, captions with word timings, point
/// and range markers, In/Out) both must give the same timeline up to the fresh IDs of new pieces, the same removed time,
/// the same playhead, or the same error.
@Suite struct BatchRippleTests {
    typealias LCG = EditCoreCrashFuzzTests.LCG

    // MARK: Equivalence

    @Test(arguments: Array(UInt64(1)...UInt64(160)))
    func batchEqualsSequentialOnRandomTimelines(seed: UInt64) throws {
        var rng = LCG(s: seed &* 7_919 &+ 3)
        let (tl, around) = Self.randomTimeline(&rng)
        let cuts = Self.randomCuts(&rng, end: tl.duration + Self.fd * 40)
        let fd = Self.fd
        try Self.expectSame(tl, cuts: cuts, around: around, playhead: fd * Int64(rng.int(Int(tl.duration.frameIndex(frameDuration: fd)) + 40)))
    }

    /// The crash-fuzz timelines (speed ramps, reverse, transitions at cuts and heads, keys) as a second source.
    @Test(arguments: Array(UInt64(1)...UInt64(24)))
    func batchEqualsSequentialOnFuzzTimelines(seed: UInt64) throws {
        let tl = EditCoreCrashFuzzTests.make(seed: seed)
        let fd = tl.frameDuration
        var rng = LCG(s: seed &* 31 &+ 17)
        let clips = tl.tracks.flatMap(\.clips)
        let around: Set<Clip.ID> = clips.isEmpty ? [] : [clips[rng.int(clips.count)].id]
        var cuts: [TimeRange] = []
        let frames = Int(tl.duration.frameIndex(frameDuration: fd)) + 10
        for _ in 0..<(1 + rng.int(30)) {
            cuts.append(TimeRange(start: fd * Int64(rng.int(frames)), duration: fd * Int64(1 + rng.int(20))))
        }
        try Self.expectSame(tl, cuts: cuts, around: around, playhead: fd * Int64(rng.int(frames)))
    }

    /// Accepting proposed cuts (silence and filler proposals as range markers) runs the batch too.
    @Test func acceptProposedCutsMatchesSequential() throws {
        var rng = LCG(s: 99)
        for _ in 0..<20 {
            var (tl, around) = Self.randomTimeline(&rng)
            tl.proposeCuts(Self.randomCuts(&rng, end: tl.duration), kind: .silence)
            var a = tl, b = tl
            let ra = Result { try a.acceptProposedCuts(nil, around: around) }
            let rb = Result { () throws -> Time in
                let chosen = b.proposedCuts
                let removed = try b.removeSilencesSequential(chosen.map(\.range), around: around)
                let gone = Set(chosen.map(\.id))
                b.markers.removeAll { gone.contains($0.id) }
                return removed
            }
            #expect(Self.same(ra, rb))
            if case .success = ra { #expect(Self.canonical(a) == Self.canonical(b)) }
        }
    }

    // MARK: Behavior

    @Test func playheadFollowsTheClosedSpans() throws {
        let m = UUID(), link = UUID()
        let v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
        let a = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [a])])
        let cuts = [TimeRange(start: s(2), duration: s(1)), TimeRange(start: s(6), duration: s(2)), TimeRange(start: s(15), duration: s(1))]
        let landed = try tl.followingRipple(playhead: s(10)) { _ = try $0.removeSilences(cuts, around: [a.id]) }
        #expect(landed == s(7))                       // 3 s closed before it, the cut at 15 s after it
        #expect(landed == Timeline.playheadAfterRipple(s(10), closing: cuts.reversed()))
        let inside = try tl.followingRipple(playhead: s(6)) { _ = try $0.removeSilences([TimeRange(start: s(5), duration: s(2))], around: [a.id]) }
        #expect(inside == s(5))
    }

    @Test func lockedTrackRefusesAndChangesNothing() throws {
        let m = UUID(), link = UUID()
        let v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        let a = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [Track(kind: .video, clips: [v], isLocked: true), Track(kind: .audio, clips: [a])])
        let before = tl
        #expect(throws: EditError.trackLocked) { try tl.removeSilences([TimeRange(start: s(2), duration: s(1))], around: [a.id]) }
        #expect(tl == before)
    }

    // MARK: Performance

    /// 600 cuts on a 30-minute talking head (V1/A1 in 60 linked takes with J/L cuts, music, B-roll, 900 captions, markers).
    /// `SQ_BATCH_RIPPLE_BENCH=<path>` also times the old sequential path and writes both numbers to `<path>`.
    @Test func sixHundredCutsOnThirtyMinutesIsFast() throws {
        let fd = Time(1, 30)
        var v = Track(kind: .video), b = Track(kind: .video), a = Track(kind: .audio), music = Track(kind: .audio)
        var around = Set<Clip.ID>()
        for i in 0..<60 {
            let t = s(Int64(i) * 30), m = UUID(), link = UUID()
            let jl = fd * Int64(i % 3 == 0 ? 6 : 0)          // every third take: picture cut 6 frames after the sound cut
            let vc = Clip(name: "v\(i)", media: m, kind: .video, source: TimeRange(start: s(1) + jl, duration: s(30)), start: t + jl,
                          link: link, mediaDuration: s(40))
            let ac = Clip(name: "a\(i)", media: m, kind: .audio, source: TimeRange(start: s(1), duration: s(30)), start: t,
                          link: link, mediaDuration: s(40))
            try v.overwrite(vc); try a.overwrite(ac); around.insert(ac.id)
            if i % 4 == 1 { try b.overwrite(Clip(name: "b\(i)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: t + s(10))) }
        }
        try music.overwrite(Clip(name: "music", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(1800)), start: .zero))
        let caps = (0..<900).map { CaptionItem(lines: ["line \($0)"], range: TimeRange(start: s(Int64($0) * 2), duration: s(2))) }
        var tl = Timeline(name: "long", frameDuration: fd, tracks: [v, b, a, music])
        tl.captionTracks = [CaptionTrack(items: caps)]
        tl.markers = (0..<100).map { Marker(time: s(Int64($0) * 18)) }
        let cuts = (0..<600).map { TimeRange(start: s(Int64($0) * 3) + fd * 20, duration: fd * 15) }

        var batch = tl
        let clock = ContinuousClock()
        let t0 = clock.now
        let removed = try batch.removeSilences(cuts, around: around)
        let batchTime = clock.now - t0
        #expect(removed == fd * 15 * 600)
        #expect(batchTime < .seconds(1))
        #expect(batch.tracks.allSatisfy { $0.isConsistent })

        if let path = ProcessInfo.processInfo.environment["SQ_BATCH_RIPPLE_BENCH"] {
            var seq = tl
            let t1 = clock.now
            _ = try seq.removeSilencesSequential(cuts, around: around)
            let seqTime = clock.now - t1
            #expect(Self.canonical(seq) == Self.canonical(batch))
            try "batch \(batchTime)\nsequential \(seqTime)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Helpers

    static let fd = Time(1001, 30000)
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    static func expectSame(_ tl: Timeline, cuts: [TimeRange], around: Set<Clip.ID>, playhead: Time,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        var a = tl, b = tl
        var removedA = Time.zero, removedB = Time.zero
        let ra = Result { try a.followingRipple(playhead: playhead) { removedA = try $0.removeSilences(cuts, around: around) } }
        let rb = Result { try b.followingRipple(playhead: playhead) { removedB = try $0.removeSilencesSequential(cuts, around: around) } }
        #expect(same(ra, rb), "batch \(ra) vs sequential \(rb)", sourceLocation: sourceLocation)
        guard case .success = ra, case .success = rb else { return }
        #expect(removedA == removedB, sourceLocation: sourceLocation)
        let ca = canonical(a), cb = canonical(b)
        #expect(ca == cb, "timelines differ", sourceLocation: sourceLocation)
        if ca != cb { firstDifference(ca, cb) }
    }

    static func same<T: Equatable>(_ a: Result<T, any Error>, _ b: Result<T, any Error>) -> Bool {
        switch (a, b) {
        case let (.success(x), .success(y)): return x == y
        case let (.failure(x), .failure(y)): return (x as? EditError) == (y as? EditError)
        default: return false
        }
    }

    /// JSON with every UUID replaced by the order it first appears in: fresh IDs of new pieces and links compare equal
    /// when they sit in the same places.
    static func canonical(_ tl: Timeline) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: (try? enc.encode(tl)) ?? Data(), as: UTF8.self)
        let re = try! NSRegularExpression(pattern: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
        var names: [String: Int] = [:]
        var out = ""
        var last = json.startIndex
        for m in re.matches(in: json, range: NSRange(json.startIndex..., in: json)) {
            let r = Range(m.range, in: json)!
            out += json[last..<r.lowerBound]
            let id = String(json[r])
            let n = names[id] ?? names.count
            names[id] = n
            out += "#\(n)"
            last = r.upperBound
        }
        out += json[last...]
        return out
    }

    private static func firstDifference(_ a: String, _ b: String) {
        let x = Array(a.utf8), y = Array(b.utf8)
        let i = (0..<min(x.count, y.count)).first { x[$0] != y[$0] } ?? min(x.count, y.count)
        let lo = max(0, i - 200)
        Issue.record("first difference at \(i):\nbatch      \(String(decoding: x[lo..<min(x.count, i + 200)], as: UTF8.self))\nsequential \(String(decoding: y[lo..<min(y.count, i + 200)], as: UTF8.self))")
    }

    static func randomCuts(_ rng: inout LCG, end: Time) -> [TimeRange] {
        let frames = max(Int(end.frameIndex(frameDuration: fd)), 10)
        return (0..<(1 + rng.int(25))).map { _ in
            TimeRange(start: fd * Int64(rng.int(frames)), duration: fd * Int64(1 + rng.int(rng.chance(4) ? 90 : 15)))
        }
    }

    /// V1/A1 talking head (linked, J/L offsets, gaps, transitions, keys), V2 B-roll with linked sound on A3, A2 music,
    /// random sync lock and locks, two caption tracks (one with word timings), point and range markers, In/Out.
    static func randomTimeline(_ rng: inout LCG) -> (Timeline, Set<Clip.ID>) {
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        var v2 = Track(kind: .video, syncLock: !rng.chance(3)), a2 = Track(kind: .audio, syncLock: !rng.chance(3))
        var a3 = Track(kind: .audio, syncLock: !rng.chance(2))
        var t = fd * Int64(rng.int(10))
        var vEnd = Time.zero, aEnd = Time.zero
        var around = Set<Clip.ID>()
        for _ in 0..<(2 + rng.int(6)) {
            let len = fd * Int64(20 + rng.int(120))
            let m = UUID(), link = UUID()
            let handle = fd * 60
            let vs = max(t, vEnd), ve = t + len
            // J cut: sound starts before the picture; L cut: sound runs past it.
            let as0 = max(aEnd, t - fd * Int64(rng.chance(3) ? rng.int(12) : 0))
            let ae = ve + fd * Int64(rng.chance(3) ? rng.int(12) : 0) - fd * Int64(rng.chance(4) ? rng.int(8) : 0)
            guard ve > vs, ae > as0 else { t = ve; continue }
            var vc = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: handle + (vs - t), duration: ve - vs), start: vs,
                          link: link, mediaDuration: handle * 3 + len)
            var ac = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: handle + (as0 - t), duration: ae - as0), start: as0,
                          link: link, mediaDuration: handle * 3 + len)
            if rng.chance(3) { vc.animation.opacity.track.insert(Keyframe(time: fd * Int64(rng.int(10)), value: 0.3)) }
            if rng.chance(3) { ac.animation.volume.track.insert(Keyframe(time: fd * Int64(rng.int(10)), value: 0.6)) }
            if rng.chance(4) { vc.markers = [Marker(time: fd * Int64(rng.int(10)), name: "clip")] }
            try? v1.overwrite(vc); try? a1.overwrite(ac)
            if rng.chance(4) == false || around.isEmpty { around.insert(ac.id) }
            vEnd = ve; aEnd = ae
            t = ve + (rng.chance(3) ? fd * Int64(rng.int(30)) : .zero)
        }
        // B-roll, some with linked sound on A3.
        var bt = fd * Int64(rng.int(40))
        for _ in 0..<rng.int(5) {
            let len = fd * Int64(10 + rng.int(60))
            let m = UUID()
            var c = Clip(name: "b", media: m, kind: .video, source: TimeRange(start: .zero, duration: len), start: bt)
            if rng.chance(2) {
                let link = UUID(); c.link = link
                try? a3.overwrite(Clip(name: "bs", media: m, kind: .audio, source: c.source, start: bt, link: link))
            }
            try? v2.overwrite(c)
            bt += len + fd * Int64(rng.int(40))
        }
        if rng.chance(4) == false {
            let end = max(vEnd, aEnd) + fd * Int64(rng.int(30))
            try? a2.overwrite(Clip(name: "music", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: end), start: .zero))
        }
        var tl = Timeline(name: "r", frameDuration: fd, tracks: [v1, v2, a1, a2, a3])
        if rng.chance(8) { tl.tracks[1].isLocked = true }
        if rng.chance(8) { tl.tracks[4].isLocked = true }
        if rng.chance(12) { tl.tracks[0].isLocked = true }
        // Transitions at touching cuts on V1/A1 and a head fade.
        for ti in [0, 2] {
            let kind: TransitionKind = ti == 0 ? .crossDissolve : .constantPower
            let clips = tl.tracks[ti].clips
            for (l, r) in zip(clips, clips.dropFirst()) where l.timeline.end == r.start && rng.chance(2) {
                _ = try? tl.addTransition(point: .cut(outgoing: l.id, incoming: r.id), kind: kind, track: tl.tracks[ti].id, duration: fd * 6)
            }
            if let f = clips.first, rng.chance(2) { _ = try? tl.addTransition(point: .head(f.id), kind: kind, track: tl.tracks[ti].id, duration: fd * 8) }
            if let l = clips.last, rng.chance(2) { _ = try? tl.addTransition(point: .tail(l.id), kind: kind, track: tl.tracks[ti].id, duration: fd * 8) }
        }
        // Captions (one track with word timings, one maybe without sync lock or locked).
        let end = tl.duration
        let frames = max(Int(end.frameIndex(frameDuration: fd)), 10)
        var items: [CaptionItem] = [], plain: [CaptionItem] = []
        var ct = Time.zero
        while ct < end {
            let len = fd * Int64(10 + rng.int(50))
            let half = fd * Int64(5)
            items.append(CaptionItem(lines: ["w x"], range: TimeRange(start: ct, duration: len),
                                     words: rng.chance(2) ? [CaptionWord(text: "w", range: TimeRange(start: ct, duration: half)),
                                                              CaptionWord(text: "x", range: TimeRange(start: ct + half, end: ct + len))] : []))
            if rng.chance(2) { plain.append(CaptionItem(lines: ["p"], range: TimeRange(start: ct, duration: len))) }
            ct += len + fd * Int64(rng.int(8))
        }
        tl.captionTracks = [CaptionTrack(items: items), CaptionTrack(isLocked: rng.chance(4), syncLock: !rng.chance(3), items: plain)]
        tl.markers = (0..<rng.int(12)).map { _ in
            Marker(time: fd * Int64(rng.int(frames + 20)), duration: rng.chance(3) ? fd * Int64(1 + rng.int(60)) : .zero)
        }.sorted { $0.time != $1.time ? $0.time < $1.time : $0.id.uuidString < $1.id.uuidString }
        if rng.chance(2) {
            let a = fd * Int64(rng.int(frames)), b = a + fd * Int64(1 + rng.int(frames))
            let kind = [InOutKind.both, .inOnly, .outOnly, nil][rng.int(4)]
            tl.inOut = TimeRange(start: kind == .outOnly ? .zero : a, end: b)   // an Out without In starts at 0
            tl.inOutKind = kind
        }
        return (tl, around)
    }
}

extension Timeline {
    /// The old sequential "Remove Silences" (one `extract` per cut, last cut first): the oracle for the batch path.
    mutating func removeSilencesSequential(_ cuts: [TimeRange], around clips: Set<Clip.ID>) throws -> Time {
        let links = Set(tracks.flatMap(\.clips).filter { clips.contains($0.id) }.compactMap(\.link))
        var ids = Set<Track.ID>()
        for t in tracks {
            let owns = t.clips.contains { clips.contains($0.id) || ($0.link.map(links.contains) ?? false) }
            if owns || t.followsRipple { ids.insert(t.id) }
        }
        let normalized = SilenceRemoval.normalized(cuts)
        if let first = normalized.first?.start {
            var grew = true
            while grew {
                let moved = Set(tracks.filter { ids.contains($0.id) }.flatMap(\.clips)
                    .filter { $0.timeline.end > first }.compactMap(\.link))
                grew = false
                for t in tracks where !ids.contains(t.id) && t.clips.contains(where: { $0.link.map(moved.contains) ?? false }) {
                    if t.isLocked { throw EditError.trackLocked }
                    ids.insert(t.id); grew = true
                }
            }
        }
        let end = tracks.filter { ids.contains($0.id) }.map(\.end).max() ?? .zero
        let clamped = normalized.compactMap { c -> TimeRange? in
            let b = min(c.end, end)
            return b > c.start ? TimeRange(start: c.start, duration: b - c.start) : nil
        }
        let order = tracks.map(\.id).filter(ids.contains)
        var work = self
        var removed = Time.zero
        for c in clamped.reversed() {
            let d = try work.extract(c, tracks: order)
            guard d == c.duration else { throw EditError.collision }
            removed = removed + d
        }
        self = work
        return removed
    }
}
