import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

private let fd = Time(1, 30)
private func sec(_ n: Int64, _ d: Int64 = 1) -> Time { Time(n, d) }

/// 30 fps, no B-frames, sync every `gop` frames.
private func index(frames: Int, gop: Int = 15) -> SampleIndex {
    SampleIndex(entries: (0..<frames).map {
        SampleIndex.Entry(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 % gop == 0, decodeOrdinal: $0)
    })
}
private func clip(_ media: UUID, start: Time = .zero, src: Time = .zero, dur: Time) -> Clip {
    Clip(name: "c", media: media, kind: .video, source: TimeRange(start: src, duration: dur), start: start)
}
private func timeline(_ rows: [[Clip]]) throws -> Timeline {
    var tracks: [Track] = []
    for row in rows { var t = Track(kind: .video); for c in row { try t.overwrite(c) }; tracks.append(t) }
    return Timeline(name: "t", frameDuration: fd, tracks: tracks)
}
private let none: @Sendable (UUID, Int) -> Bool = { _, _ in false }
private let planner = PrefetchPlanner()

@Suite struct PrefetchPlannerTests {
    @Test func forwardWindowExpandsToGOPsNearestFirst() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(10))]])
        let jobs = planner.jobs(timeline: tl, playhead: sec(1), rate: .forward, indexes: [m: index(frames: 300)], cached: none)
        #expect(jobs.first?.frames == 30...44)
        #expect(Set(jobs.map(\.frames.lowerBound)) == Set(stride(from: 15, through: 90, by: 15)))
        #expect(jobs.map(\.priority) == Array(0..<jobs.count))
        let ahead = jobs.filter { $0.frames.lowerBound > 30 }.map(\.frames.lowerBound)
        #expect(ahead == ahead.sorted())
        #expect(jobs.allSatisfy { $0.media == m })
    }

    @Test func sourceOffsetMapsToSourceFrames() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, src: sec(2), dur: sec(5))]])
        let jobs = planner.jobs(timeline: tl, playhead: .zero, rate: .forward, indexes: [m: index(frames: 300)], cached: none)
        #expect(jobs.first?.frames == 60...74)
    }

    @Test func reverseGoesBackToFrontStartingUnderPlayhead() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(10))]])
        let jobs = planner.jobs(timeline: tl, playhead: sec(5), rate: .reverse, indexes: [m: index(frames: 300)], cached: none)
        #expect(jobs.first?.frames == 150...164)
        let behind = jobs.filter { $0.frames.lowerBound < 150 }.map(\.frames.lowerBound)
        #expect(behind == behind.sorted(by: >))
        #expect(behind.last == 90)          // 2 s behind in play direction: frame 90 is t = 3 s
        #expect(jobs.map(\.frames.lowerBound).max()! <= 165)   // only 0.5 s in the opposite direction
    }

    @Test func eightTimesWidensTheWindow() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(30))]])
        let ix = [m: index(frames: 900)]
        let normal = planner.jobs(timeline: tl, playhead: sec(2), rate: .forward, indexes: ix, cached: none)
        let fast = planner.jobs(timeline: tl, playhead: sec(2), rate: PlaybackRate(8), indexes: ix, cached: none)
        #expect(normal.map(\.frames.upperBound).max() == 134)   // 2 s + 2 s = frame 120 -> GOP 120...134
        #expect(fast.map(\.frames.upperBound).max() == 554)     // 2 s + 16 s = frame 540
        #expect(fast.count > normal.count)
        let slow = planner.jobs(timeline: tl, playhead: sec(2), rate: PlaybackRate(1, 4), indexes: ix, cached: none)
        #expect(slow.map(\.frames.upperBound).max() == 89)      // 0.5 s ahead -> frame 75 -> GOP 75...89
    }

    @Test func seekProducesAnIndependentWindow() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(30))]])
        let ix = [m: index(frames: 900)]
        let a = planner.jobs(timeline: tl, playhead: sec(1), rate: .forward, indexes: ix, cached: none)
        let b = planner.jobs(timeline: tl, playhead: sec(20), rate: .forward, indexes: ix, cached: none)
        #expect(Set(a.map(\.frames)).isDisjoint(with: Set(b.map(\.frames))))
        #expect(b.first?.frames == 600...614)
    }

    @Test func cachedGOPsAreSkippedPartialOnesAreNot() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(10))]])
        let ix = [m: index(frames: 300)]
        let full = planner.jobs(timeline: tl, playhead: sec(1), rate: .forward, indexes: ix,
                                cached: { _, f in (30...44).contains(f) })
        #expect(!full.contains { $0.frames == 30...44 })
        #expect(full.first?.frames == 15...29 && full.first?.priority == 0)
        let partial = planner.jobs(timeline: tl, playhead: sec(1), rate: .forward, indexes: ix,
                                   cached: { _, f in (30...44).contains(f) && f != 40 })
        #expect(partial.first?.frames == 30...44)
    }

    /// Decode thrash on the real project: frames already shown (evicted first, behind the playhead) made the GOP under the
    /// playhead look uncached, so it was decoded again and again while the media's one decoder was needed for the next GOP.
    @Test func gopUnderPlayheadIsNotRedecodedForFramesAlreadyShown() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(10))]])
        let ix = [m: index(frames: 300)]
        let jobs = planner.jobs(timeline: tl, playhead: fd * 37, rate: .forward, indexes: ix,
                                cached: { _, f in (37...44).contains(f) })
        #expect(!jobs.contains { $0.frames == 30...44 })
        #expect(jobs.first?.frames == 45...59)
        // A frame still to come is missing: the GOP is decoded again.
        let missing = planner.jobs(timeline: tl, playhead: fd * 37, rate: .forward, indexes: ix,
                                   cached: { _, f in (37...44).contains(f) && f != 42 })
        #expect(missing.first?.frames == 30...44)
        // Paused: both sides of the playhead count.
        let paused = planner.jobs(timeline: tl, playhead: fd * 37, rate: .zero, indexes: ix,
                                  cached: { _, f in (37...44).contains(f) })
        #expect(paused.first?.frames == 30...44)
        // Being decoded: stays listed, so the scheduler does not cancel it half way.
        let running = planner.jobs(timeline: tl, playhead: fd * 37, rate: .forward, indexes: ix,
                                   cached: { _, f in (37...44).contains(f) }, running: { $1 == 30...44 })
        #expect(running.first?.frames == 30...44)
    }

    /// GOP frames outside the clip's source range are never shown (the cache evicts them first): they do not count.
    @Test func gopFramesOutsideTheClipDoNotCount() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, src: fd * 35, dur: sec(5))]])
        let jobs = planner.jobs(timeline: tl, playhead: .zero, rate: .forward, indexes: [m: index(frames: 300)],
                                cached: { _, f in (35...44).contains(f) })
        #expect(!jobs.contains { $0.frames == 30...44 })
        #expect(jobs.first?.frames == 45...59)
    }

    @Test func threeStackedClipsInterleaveByTime() throws {
        let ms = [UUID(), UUID(), UUID()]
        let tl = try timeline(ms.map { [clip($0, dur: sec(10))] })
        let ix = Dictionary(uniqueKeysWithValues: ms.map { ($0, index(frames: 300)) })
        let jobs = planner.jobs(timeline: tl, playhead: sec(1), rate: .forward, indexes: ix, cached: none)
        #expect(Array(jobs.prefix(3).map(\.media)) == ms)
        #expect(Set(jobs.prefix(3).map(\.frames)) == [30...44])
        // Next group: the GOP just behind the playhead, again all three clips before anything farther.
        #expect(Set(jobs[3..<6].map(\.media)) == Set(ms))
        #expect(Set(jobs[3..<6].map(\.frames)).count == 1)
        #expect(jobs.count == 6 * 3)
    }

    @Test func windowIsClippedAtTimelineStartAndEnd() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(2))]])
        let ix = [m: index(frames: 300)]
        let start = planner.jobs(timeline: tl, playhead: sec(1, 10), rate: .forward, indexes: ix, cached: none)
        #expect(start.first?.frames == 0...14)
        #expect(start.map(\.frames.lowerBound).min() == 0)
        let end = planner.jobs(timeline: tl, playhead: sec(19, 10), rate: .forward, indexes: ix, cached: none)
        #expect(end.map(\.frames.upperBound).max() == 59)   // timeline ends at 2 s
        let beyond = planner.jobs(timeline: tl, playhead: sec(5), rate: .forward, indexes: ix, cached: none)
        #expect(beyond.isEmpty)
        let before = planner.jobs(timeline: tl, playhead: sec(-1), rate: .forward, indexes: ix, cached: none)
        #expect(before.first?.frames == 0...14)             // 2 s ahead reaches into the clip
    }

    @Test func gapsProduceNoJobsAndAreLookedThrough() throws {
        let a = UUID(), b = UUID()
        let tl = try timeline([[clip(a, dur: sec(1)), clip(b, start: sec(3), dur: sec(1))]])
        let ix = [a: index(frames: 300), b: index(frames: 300)]
        let inA = planner.jobs(timeline: tl, playhead: sec(1, 2), rate: .forward, indexes: ix, cached: none)
        #expect(Set(inA.map(\.media)) == [a])               // b starts 2.5 s ahead, outside the 2 s window
        let inGap = planner.jobs(timeline: tl, playhead: sec(2), rate: .forward, indexes: ix, cached: none)
        #expect(Set(inGap.map(\.media)) == [b])
        #expect(inGap.first?.frames == 0...14)
        #expect(planner.jobs(timeline: tl, playhead: sec(2), rate: .zero, indexes: ix, cached: none).isEmpty)
    }

    @Test func mediaWithoutIndexAndGeneratorsAreIgnored() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(2))]])
        #expect(planner.jobs(timeline: tl, playhead: .zero, rate: .forward, indexes: [:], cached: none).isEmpty)
    }
}

/// PLAYBACK-PERF "Prefetch window memo": the planner's per-frame layer evaluation was ~85 % of the render thread's CPU per
/// tick on a 210-clip project. While playing the window slides one frame per tick, so only the new edge is evaluated.
@Suite struct PlanSourceMemoTests {
    @Test func memoizedPlanningGivesTheSameJobs() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let tl = try timeline([[clip(a, dur: sec(3)), clip(b, start: sec(3), src: sec(1), dur: sec(4))],
                               [clip(c, start: sec(1), dur: sec(5))]])
        let ix = [a: index(frames: 300), b: index(frames: 300), c: index(frames: 300)]
        let memo = PlanSourceMemo()
        for k in 0..<120 {
            let p = fd * Int64(k)
            for rate in [PlaybackRate.forward, .reverse, .zero] {
                let plain = planner.jobs(timeline: tl, playhead: p, rate: rate, indexes: ix, cached: none)
                let memoized = memo.withSources(epoch: 1, evaluate: { PrefetchPlanner.sources(tl, sequences: [:], at: $0) }) { src in
                    planner.jobs(timeline: tl, playhead: p, rate: rate, indexes: ix, cached: none, sources: src)
                }
                #expect(plain == memoized)
                #expect(plain.map(\.neededFrom) == memoized.map(\.neededFrom))
            }
        }
    }

    @Test func slidingWindowEvaluatesOnlyTheNewFrames() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(30))]])
        let ix = [m: index(frames: 900)]
        let memo = PlanSourceMemo()
        var count = 0
        func plan(_ p: Time, epoch: UInt64 = 1, revision: UInt64 = 0) {
            _ = memo.withSources(epoch: epoch, revision: revision, evaluate: { t in
                count += 1
                return PrefetchPlanner.sources(tl, sequences: [:], at: t)
            }) { src in planner.jobs(timeline: tl, playhead: p, rate: .forward, indexes: ix, cached: none, sources: src) }
        }
        plan(sec(5))
        #expect(count == 1 + 60 + 15)       // 2 s ahead + 0.5 s behind at 30 fps
        count = 0
        plan(sec(5) + fd)
        #expect(count == 1)                 // one new frame at the front edge
        count = 0
        plan(sec(5) + fd, epoch: 2)         // a new timeline: nothing is reused
        #expect(count == 76)
        count = 0
        plan(sec(20), epoch: 2)             // a seek: a fresh window
        #expect(count == 76)
        count = 0
        plan(sec(20), epoch: 2, revision: 1)        // what counts as hidden changed: nothing is reused
        #expect(count == 76)
        count = 0
        plan(sec(20) + fd, epoch: 2, revision: 1)
        #expect(count == 1)
    }

    @Test func sourcesSkipGeneratorsAndResolveNests() throws {
        let m = UUID()
        let inner = try timeline([[clip(m, src: sec(2), dur: sec(4))]])
        var nest = Clip(name: "n", media: UUID(), kind: .video, source: TimeRange(start: sec(1), duration: sec(2)), start: .zero)
        nest.sequence = inner.id
        var text = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: sec(2)), start: .zero)
        text.generator = GeneratorRef.solid(rgb: [255, 255, 255])
        let tl = try timeline([[nest], [text]])
        let s = PrefetchPlanner.sources(tl, sequences: [inner.id: inner], at: sec(1, 2))
        #expect(s == [PlanSource(media: m, sourceTime: sec(7, 2))])    // nest 1 s + 0.5 s = inner 1.5 s -> source 2 + 1.5
    }
}
