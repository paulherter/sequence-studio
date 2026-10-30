import Foundation

/// Live ducking decisions of one timeline revision, built once off the audio thread (`AudioFeeder.setTimeline`), so a mix
/// block does no walk over every clip: the dialogue candidates sorted by start (binary search per block) and the set of
/// clips the duck acts on. Answers exactly `LiveDucking.dialogueRanges(in:window:pauses:)` and `LiveDucking.ducks(_:on:)`
/// for the timeline it was built from; any change of the timeline (edit, undo, mute, solo, role, opt-out) needs a new index.
public struct LiveDuckingIndex: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var range: TimeRange
        var track: Int32, clip: Int32
    }
    /// Dialogue-role, enabled, non-generator clips on audible audio tracks still in live ducking, sorted by start.
    let entries: [Entry]
    /// `maxEnd[i]`: the latest end among `entries[0...i]` (non-decreasing, so the first entry that can reach a window is found
    /// by binary search).
    let maxEnd: [Time]
    /// Top-level clips live ducking acts on (`LiveDucking.ducks`).
    let ducked: Set<Clip.ID>

    public init(_ t: Timeline) {
        var e: [Entry] = []
        let tracks = t.tracks
        let solo = tracks.contains { $0.kind == .audio && !$0.isMuted && $0.isSolo }
        for ti in tracks.indices {
            guard tracks[ti].kind == .audio, !tracks[ti].isMuted, !solo || tracks[ti].isSolo, !tracks[ti].isExcludedFromLiveDucking else { continue }
            let clips = tracks[ti].clips, role = tracks[ti].audioRole
            for i in clips.indices where (clips[i].audioTag ?? role) == .dialogue && clips[i].isEnabled && !clips[i].isGenerator {
                e.append(Entry(range: clips[i].timeline, track: Int32(ti), clip: Int32(i)))
            }
        }
        e.sort { $0.range.start < $1.range.start }
        var m: [Time] = []
        m.reserveCapacity(e.count)
        for x in e { m.append(m.last.map { max($0, x.range.end) } ?? x.range.end) }
        entries = e; maxEnd = m
        ducked = LiveDucking.duckedClipIDs(in: t)
    }

    /// Whether live ducking acts on the top-level clip `id` (same as `LiveDucking.ducks(clip, on: its track)`). No allocation.
    @inline(__always)
    public func ducks(clip id: Clip.ID) -> Bool { ducked.contains(id) }

    /// `LiveDucking.dialogueRanges(in: t, window:, pauses:)` into `out` (replaced; its capacity is kept, so a reused buffer does
    /// not allocate once sized). `t` must be the timeline this index was built from.
    public func dialogueRanges(in t: Timeline, window: TimeRange, pauses: (Clip, Track) -> [TimeRange]?, into out: inout [TimeRange]) {
        out.removeAll(keepingCapacity: true)
        guard !entries.isEmpty else { return }
        // First entry whose running max end reaches the window; entries from the first start past the window end are out.
        var lo = 0, hi = maxEnd.count
        while lo < hi { let mid = (lo + hi) / 2; if maxEnd[mid] < window.start { lo = mid + 1 } else { hi = mid } }
        var sorted = true
        var i = lo
        while i < entries.count {
            let e = entries[i]
            i += 1
            if e.range.start > window.end { break }
            if e.range.end < window.start { continue }
            let track = t.tracks[Int(e.track)], clip = track.clips[Int(e.clip)]
            if let s = pauses(clip, track), !s.isEmpty {
                let before = out.count
                LiveDucking.appendActiveRanges(of: e.range, silences: s, into: &out)
                if before > 0, out.count > before, out[before].start < out[before - 1].start { sorted = false }
            } else {
                if let last = out.last, e.range.start < last.start { sorted = false }
                out.append(e.range)
            }
        }
        LiveDucking.mergeInPlace(&out, sorted: sorted)
    }

    /// Same with the pauses from a silence provider (nil = every clip ducks over its whole length).
    public func dialogueRanges(in t: Timeline, window: TimeRange, silences: (any DialogueSilenceProvider)?, into out: inout [TimeRange]) {
        if let silences {
            dialogueRanges(in: t, window: window, pauses: { c, track in silences.silences(of: c, trackVolumeDB: track.volumeDB) }, into: &out)
        } else {
            dialogueRanges(in: t, window: window, pauses: { _, _ in nil }, into: &out)
        }
    }
}

extension LiveDucking {
    /// `activeRanges(of:silences:)` appended to `out` (no allocation when `silences` is sorted and `out` has room).
    static func appendActiveRanges(of clip: TimeRange, silences: [TimeRange], into out: inout [TimeRange]) {
        var isSorted = true
        for k in silences.indices.dropFirst() where silences[k].start < silences[k - 1].start { isSorted = false; break }
        let s = isSorted ? silences : silences.sorted(by: { $0.start < $1.start })
        var cursor = clip.start
        for p in s {
            let a = max(p.start, clip.start), b = min(p.end, clip.end)
            guard b > a else { continue }
            if a > cursor { out.append(TimeRange(start: cursor, duration: a - cursor)) }
            cursor = max(cursor, b)
        }
        if clip.end > cursor { out.append(TimeRange(start: cursor, duration: clip.end - cursor)) }
    }

    /// The merge of `dialogueRanges`, in place: empty ranges dropped, touching or overlapping ones joined, sorted by start.
    /// `sorted`: the input is already sorted by start (skips the sort).
    static func mergeInPlace(_ a: inout [TimeRange], sorted: Bool) {
        guard !a.isEmpty else { return }
        if !sorted { a.sort { $0.start < $1.start } }
        var w = 0
        for k in a.indices where !a[k].isEmpty {
            let r = a[k]
            if w > 0, r.start <= a[w - 1].end {
                let last = a[w - 1]
                a[w - 1] = TimeRange(start: last.start, duration: max(last.end, r.end) - last.start)
            } else { a[w] = r; w += 1 }
        }
        a.removeLast(a.count - w)
    }

    /// `expanded(_:)` into `out` (replaced, capacity kept). Input sorted by start (as `dialogueRanges` returns).
    public func expanded(_ ranges: [TimeRange], into out: inout [TimeRange]) {
        out.removeAll(keepingCapacity: true)
        let tm = timing
        guard tm.lookaheadMs > 0 || tm.holdMs > 0 || tm.minPauseMs > 0 else { out.append(contentsOf: ranges); return }
        let look = tm.lookahead, hold = tm.hold, pause = tm.minPause
        var isSorted = true
        for k in ranges.indices.dropFirst() where ranges[k].start < ranges[k - 1].start { isSorted = false; break }
        for r in isSorted ? ranges : ranges.sorted(by: { $0.start < $1.start }) {
            let e = TimeRange(start: r.start - look, end: r.end + hold)
            if let last = out.last, e.start - last.end <= pause { out[out.count - 1] = TimeRange(start: last.start, end: max(last.end, e.end)) }
            else { out.append(e) }
        }
    }

    /// `gain(at:ranges:)` over ranges already passed through `expanded` (once per block instead of once per gain chunk).
    public func gain(at time: Time, expandedRanges: [TimeRange]) -> Float {
        guard !isOff else { return 1 }
        return rawGain(at: time, ranges: expandedRanges)
    }
}
