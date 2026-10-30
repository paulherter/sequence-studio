import Foundation

/// W8.1 Jump cut to the alternate track (the maintainer's checkerboard, docs/research/A1-edit-model.md: the take alternates between
/// V1/A1 and V2/A2 with a median 0.3 s overlap). One command cuts the take at the playhead and moves the rest onto the
/// alternate track of its pair (V1<->V2, V3<->V4, A1<->A2, ...), its head pulled back N frames into the handle so the
/// two halves overlap; on audio the overlap is an equal crossfade (fade handles on both halves). No file format change.
public enum JumpCut {
    /// Default overlap: 0.3 s (the maintainer's median track-switch overlap) in whole frames of the sequence.
    public static func defaultOverlapFrames(frameDuration fd: Time) -> Int {
        Int(Time(3, 10).frameIndex(frameDuration: fd))
    }

    /// Where one linked group's clips of one kind go, by index among the tracks of that kind. Normally each goes to the
    /// other track of its pair (0<->1, 2<->3). When the group fills both tracks of a pair (dual-mono audio on A1 + A2),
    /// the whole block moves together by its width rounded up to even (A1+A2 <-> A3+A4), keeping the channel order.
    static func destinations(_ k: [Int]) -> [Int] {
        let set = Set(k)
        guard k.contains(where: { set.contains($0 ^ 1) }), let lo = k.min(), let hi = k.max() else { return k.map { $0 ^ 1 } }
        let w = hi - lo + 1, b = w + (w & 1)
        var shift = (lo / b).isMultiple(of: 2) ? b : -b
        if lo + shift < 0 { shift = b }
        return k.map { $0 + shift }
    }
}

extension Timeline {
    /// Index of the track at `i` among the tracks of its kind.
    private func kindIndex(_ i: Int) -> Int { tracks[..<i].filter { $0.kind == tracks[i].kind }.count }

    /// Absolute index of the `k`-th track of `kind`, nil when it does not exist.
    private func trackIndex(kind: TrackKind, _ k: Int) -> Int? {
        let same = tracks.indices.filter { tracks[$0].kind == kind }
        return k >= 0 && k < same.count ? same[k] : nil
    }

    /// The clip strictly spanning `t` on track `i`.
    private func spanning(_ i: Int, _ t: Time) -> Clip? { tracks[i].clips.first { $0.start < t && t < $0.timeline.end } }

    /// `c` (on track `i`) was already jump cut at `t`: a clip of the same media ends exactly at `t` on another track of
    /// the same kind. Pressing again at the same playhead is then a no-op instead of leaving a sliver.
    private func alreadyJumpCut(_ c: Clip, track i: Int, at t: Time) -> Bool {
        tracks.indices.contains { j in
            j != i && tracks[j].kind == tracks[i].kind && tracks[j].clips.contains { $0.media == c.media && $0.timeline.end == t }
        }
    }

    /// Seeds of a jump cut at `t`. Tracks: the edit target rule (selection > targeted > all); for the targeted tier a
    /// targeted track with no clip under `t` is replaced by the other track of its pair, so the take keeps being found
    /// after it moved to V2/A2 and nothing is selected.
    private func jumpCutSeeds(at t: Time, selection: Set<Clip.ID>) -> (seeds: [Clip.ID], locked: Bool, alreadyCut: Bool) {
        let rule = editTargets(selection: selection)
        var scope: [Int] = []
        for id in rule.tracks {
            guard var i = tracks.firstIndex(where: { $0.id == id }) else { continue }
            if rule.source == .targeted, spanning(i, t) == nil,
               let p = trackIndex(kind: tracks[i].kind, kindIndex(i) ^ 1) { i = p }
            if !scope.contains(i) { scope.append(i) }
        }
        var seeds: [Clip.ID] = [], locked = false, done = false
        for i in scope {
            guard let c = spanning(i, t) else { continue }
            if tracks[i].isLocked { locked = true; continue }
            if alreadyJumpCut(c, track: i, at: t) { done = true; continue }
            seeds.append(c.id)
        }
        return (seeds, locked, done)
    }

    /// Clips the jump cut would cut at `t` (see `jumpCutSeeds`); empty when there is nothing (left) to cut.
    public func jumpCutCandidates(at t: Time, selection: Set<Clip.ID>) -> [Clip.ID] {
        jumpCutSeeds(at: t, selection: selection).seeds
    }

    /// True when the clip under `t` was already jump cut exactly at `t` (a second press would do nothing).
    public func isJumpCut(at t: Time, selection: Set<Clip.ID>) -> Bool {
        jumpCutSeeds(at: t, selection: selection).alreadyCut
    }

    /// Cuts the clips under `t` (`jumpCutSeeds`, linked partners included) and moves each right half onto its alternate
    /// track (`JumpCut.destinations`), head extended by `overlapFrames` frames. The overlap is limited by the media
    /// handle, by the left half's length, by time 0 and by the last clip ending before `t` on the alternate track; the
    /// whole cut uses the smallest, so linked A/V stays in sync. Audio halves get matching fade-out / fade-in over the
    /// overlap. Missing alternate tracks are created. A tail fade transition moves with the right half; a transition into
    /// the next clip on the old track is dropped.
    /// Throws `.clipNotFound` (nothing under `t`, or already jump cut there), `.trackLocked` (a source, partner or
    /// alternate track is locked) and `.collision` (an alternate track is occupied after `t`, or is another clip's source
    /// track); nothing changes then. Returns the moved halves' ids.
    @discardableResult
    public mutating func jumpCutAlternate(at t: Time, selection: Set<Clip.ID>, overlapFrames n: Int) throws -> [Clip.ID] {
        let fd = format.frameDuration
        let found = jumpCutSeeds(at: t, selection: selection)
        if found.seeds.isEmpty { throw found.locked ? EditError.trackLocked : EditError.clipNotFound }

        // Seeds plus their linked partners that also span `t` (a partner offset past the cut is not cut), per group.
        var groups: [[Member]] = []
        var seen = Set<Clip.ID>()
        for id in found.seeds where !seen.contains(id) {
            var g: [Member] = []
            for m in try linkedGroup(id) where seen.insert(m.clip.id).inserted {
                if m.clip.start < t && t < m.clip.timeline.end { g.append(m) }
            }
            if !g.isEmpty { groups.append(g) }
        }
        let members = groups.flatMap { $0 }
        if members.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }

        var work = self
        // Alternate tracks per group and kind, created when missing (appending keeps the indices of existing tracks).
        var destOf: [Clip.ID: Int] = [:]
        for g in groups {
            for kind in [TrackKind.video, .audio] {
                let ms = g.filter { work.tracks[$0.track].kind == kind }
                guard !ms.isEmpty else { continue }
                let targets = JumpCut.destinations(ms.map { work.kindIndex($0.track) })
                for (m, k) in zip(ms, targets) {
                    while work.trackIndex(kind: kind, k) == nil { work.addTrack(kind: kind) }
                    guard let d = work.trackIndex(kind: kind, k) else { throw EditError.collision }
                    destOf[m.clip.id] = d
                }
            }
        }
        let dest = try members.map { m in
            guard let d = destOf[m.clip.id] else { throw EditError.collision }
            return d
        }
        let sources = Set(members.map(\.track))
        for d in dest {
            if work.tracks[d].isLocked { throw EditError.trackLocked }
            if sources.contains(d) { throw EditError.collision }      // another cut clip sits on the alternate track
        }
        if Set(dest).count != dest.count { throw EditError.collision }

        // Split; right halves of one group share one new link.
        var relinks: [UUID: UUID] = [:]
        var rights: [Clip] = []
        for m in members {
            try work.tracks[m.track].split(at: t, relinks: &relinks)
            guard let r = work.tracks[m.track].clips.first(where: { $0.start == t }) else { throw EditError.clipNotFound }
            rights.append(r)
        }

        // One overlap for everyone.
        var ov = fd * Int64(max(n, 0))
        ov = min(ov, t)
        for (i, (r, d)) in zip(rights, dest).enumerated() {
            if let h = r.headHandle { ov = min(ov, h) }
            ov = min(ov, t - members[i].clip.start)           // never into material cut out before the left half
            let others = work.tracks[d].clips
            if others.contains(where: { $0.timeline.end > t && $0.start < r.timeline.end }) { throw EditError.collision }
            let prevEnd = others.filter { $0.timeline.end <= t }.map { $0.timeline.end }.max() ?? .zero
            ov = min(ov, t - prevEnd)
        }
        ov = FadeKeys.snapDown(ov, fd)

        for (i, m) in members.enumerated() {
            var r = rights[i]
            let d = dest[i]
            let oldID = r.id
            work.tracks[m.track].remove(oldID)
            // Transitions from the right half's tail: a fade out goes along, a cut into the next clip cannot.
            var carried: [Transition] = []
            work.tracks[m.track].transitions.removeAll { tr in
                guard tr.outgoing == oldID else { return false }
                if tr.incoming == nil { carried.append(tr) }
                return true
            }
            if ov > .zero {
                r.start -= ov
                r.extendHead(by: ov)
                if r.kind == .audio {
                    r.setAudioFadeIn(ov, frameDuration: fd)
                    if var l = work.tracks[m.track].clips.first(where: { $0.id == m.clip.id }) {
                        l.setAudioFadeOut(ov, frameDuration: fd)
                        work.tracks[m.track].replace(l)
                    }
                }
            }
            try work.tracks[d].overwrite(r)
            work.tracks[d].transitions.append(contentsOf: carried)
        }
        guard work.tracks.allSatisfy(\.isConsistent) else { throw EditError.collision }
        self = work
        return rights.map(\.id)
    }
}
