import Foundation
import Testing
@testable import SQCore

/// The per-timeline-revision duck index answers exactly what the per-block walk answers (ranges and per-clip decision),
/// and a new index follows every edit, undo, mute/solo and role change.
@Suite struct LiveDuckingIndexTests {
    typealias R = AudioRoleTests

    /// Mixed timeline: dialogue/music/untagged tracks, tags, overlaps, a disabled clip, a generator, keyed music.
    static func mixedClips() -> [[Clip]] {
        var out: [[Clip]] = []
        for k in 0..<6 {
            var clips: [Clip] = (0..<40).map { i in
                R.clip(Int64(i * 5 + k), Int64(3 + (i + k) % 4), tag: (i + k) % 5 == 0 ? .dialogue : (i + k) % 7 == 0 ? .music : nil)
            }
            clips[3].isEnabled = false
            clips[5].duckKeyIDs = [UUID()]
            if k == 5 {
                var g = Clip(name: "gen", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(217, 1))
                g.generator = .solid(rgb: [0, 0, 0])
                g.audioTag = .dialogue
                clips.append(g)
            }
            out.append(clips)
        }
        return out
    }
    static func timeline(_ clips: [[Clip]]) -> Timeline {
        R.timeline(clips.enumerated().map { k, c in R.track(k < 2 ? .dialogue : k < 4 ? .music : nil, c) })
    }
    static func mixed() -> Timeline { timeline(mixedClips()) }

    static func windows() -> [TimeRange] {
        var w: [TimeRange] = [TimeRange(start: Time(-5, 1), duration: Time(500, 1))]
        for s in stride(from: -3, to: 215, by: 2) {
            w.append(TimeRange(start: Time(Int64(s), 1), duration: Time(1, 100)))
            w.append(TimeRange(start: Time(Int64(s) * 3 + 1, 3), duration: Time(7, 2)))
        }
        return w
    }

    /// Pauses for some clips (the third second of every clip whose start is a multiple of 3), nil for the rest.
    static func pauses(_ c: Clip, _ t: Track) -> [TimeRange]? {
        c.start.value % 3 == 0 ? [TimeRange(start: c.start + Time(1, 1), duration: Time(1, 2))] : nil
    }

    static func expectSame(_ t: Timeline, _ idx: LiveDuckingIndex, sourceLocation: SourceLocation = #_sourceLocation) {
        var buf: [TimeRange] = []
        for w in windows() {
            idx.dialogueRanges(in: t, window: w, pauses: pauses, into: &buf)
            #expect(buf == LiveDucking.dialogueRanges(in: t, window: w, pauses: pauses), sourceLocation: sourceLocation)
            idx.dialogueRanges(in: t, window: w, pauses: { _, _ in nil }, into: &buf)
            #expect(buf == LiveDucking.dialogueRanges(in: t, window: w), sourceLocation: sourceLocation)
        }
        for tr in t.tracks { for c in tr.clips {
            #expect(idx.ducks(clip: c.id) == LiveDucking.ducks(c, on: tr), sourceLocation: sourceLocation)
        } }
    }

    @Test func matchesTheWalk() {
        let t = Self.mixed()
        Self.expectSame(t, LiveDuckingIndex(t))
    }

    @Test func emptyAndVideoOnlyTimelines() {
        let empty = R.timeline([])
        Self.expectSame(empty, LiveDuckingIndex(empty))
        let video = R.timeline([Track(kind: .video, clips: [R.clip(0, 5, tag: .dialogue)])])
        Self.expectSame(video, LiveDuckingIndex(video))
    }

    /// Every timeline change the feeder sees rebuilds the index; each rebuilt index matches the walk again, and the old one
    /// (built before the change) would not have.
    @Test func followsEditsUndoMuteSoloAndRoles() {
        let clips = Self.mixedClips()
        let base = Self.timeline(clips)
        func with(_ f: (inout [[Clip]]) -> Void) -> Timeline { var c = clips; f(&c); return Self.timeline(c) }
        var changes: [(String, Timeline)] = []
        changes.append(("move", with { $0[0][10].start = Time(300, 1) }))
        changes.append(("clip tag", with { $0[3][1].audioTag = .dialogue }))
        changes.append(("disable", with { $0[0][0].isEnabled = false }))
        changes.append(("music tag off", with { $0[2][1].audioTag = .sfx }))
        var muted = base; muted.tracks[0].isMuted = true; changes.append(("mute", muted))
        var solo = base; solo.tracks[2].isSolo = true; changes.append(("solo", solo))
        var role = base; role.tracks[2].audioRole = .dialogue; changes.append(("track role", role))
        var excl = base; excl.tracks[1].isExcludedFromLiveDucking = true; changes.append(("exclude", excl))
        let old = LiveDuckingIndex(base)
        for (name, t) in changes {
            Self.expectSame(t, LiveDuckingIndex(t))
            var stale = false, buf: [TimeRange] = []
            for w in Self.windows() {
                old.dialogueRanges(in: t, window: w, pauses: { _, _ in nil }, into: &buf)
                if buf != LiveDucking.dialogueRanges(in: t, window: w) { stale = true; break }
            }
            for tr in t.tracks where !stale { for c in tr.clips where old.ducks(clip: c.id) != LiveDucking.ducks(c, on: tr) { stale = true } }
            #expect(stale, "\(name): the change must be visible to a rebuilt index only")
        }
        // Undo = the earlier snapshot again: an index of it equals the first one.
        Self.expectSame(base, LiveDuckingIndex(base))
        #expect(LiveDuckingIndex(base) == old)
    }

    /// The expanded ranges into a buffer and the gain over them equal the allocating API (bit for bit).
    @Test func expandedIntoBufferAndGainMatch() {
        let ranges = LiveDucking.dialogueRanges(in: Self.mixed(), pauses: Self.pauses)
        for timing in [DuckTiming.classic, .resolve, .speech] {
            let d = LiveDucking(amountDB: 12, timing: timing)
            var buf: [TimeRange] = []
            d.expanded(ranges, into: &buf)
            #expect(buf == d.expanded(ranges))
            for k in 0..<2000 {
                let t = Time(Int64(k) * 211, 1000)
                #expect(d.gain(at: t, expandedRanges: buf) == d.gain(at: t, ranges: ranges))
            }
        }
    }
}
