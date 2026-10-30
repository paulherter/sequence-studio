import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

/// Seek to exact frame: a GOP job says from which frame on the window needs it (`neededFrom`), so the decoder may skip
/// unreferenced pictures before it.
@Suite struct SeekNeededFromTests {
    private let fd = Time(1, 30)
    private func index(frames: Int, gop: Int = 30) -> SampleIndex {
        SampleIndex(entries: (0..<frames).map {
            SampleIndex.Entry(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 % gop == 0, decodeOrdinal: $0)
        })
    }
    private func timeline(_ m: UUID, seconds: Int64) throws -> Timeline {
        var t = Track(kind: .video)
        try t.overwrite(Clip(name: "c", media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(seconds, 1)), start: .zero))
        return Timeline(name: "t", frameDuration: fd, tracks: [t])
    }

    @Test func playJobUnderThePlayheadStartsAtThePlayhead() throws {
        let m = UUID()
        let tl = try timeline(m, seconds: 10)
        // Playhead at frame 45 (mid GOP 30...59), forward: the window needs 45 on (frames behind are only "passed").
        let jobs = PrefetchPlanner().jobs(timeline: tl, playhead: fd * 45, rate: .forward, indexes: [m: index(frames: 300)],
                                          cached: { _, _ in false })
        #expect(jobs.first?.frames == 30...59)
        #expect(jobs.first?.neededFrom == 45)
        // The next GOP is needed whole.
        #expect(jobs.first { $0.frames == 60...89 }?.neededFrom == 60)
    }

    @Test func reverseNeedsTheGopFromItsLowestWindowFrame() throws {
        let m = UUID()
        let tl = try timeline(m, seconds: 10)
        let jobs = PrefetchPlanner().jobs(timeline: tl, playhead: fd * 45, rate: .reverse, indexes: [m: index(frames: 300)],
                                          cached: { _, _ in false })
        #expect(jobs.first?.frames == 30...59)
        #expect(jobs.first?.neededFrom == 30)
    }

    @Test func pausedNeedsTheWindowAroundThePlayhead() throws {
        let m = UUID()
        let tl = try timeline(m, seconds: 10)
        // Paused radius 0.25 s = 7 frames each side: 38 on.
        let jobs = PrefetchPlanner().jobs(timeline: tl, playhead: fd * 45, rate: .zero, indexes: [m: index(frames: 300)],
                                          cached: { _, _ in false })
        #expect(jobs.first?.frames == 30...59)
        #expect(jobs.first?.neededFrom == 38)
    }

    @Test func neededFromIsNotPartOfTheJobIdentity() {
        let m = UUID()
        var a = PrefetchPlanner.Job(media: m, frames: 0...29, priority: 0)
        let b = a
        a.neededFrom = 12
        #expect(a.key == b.key)
    }

    @Test func remapKeepsNeededFrom() {
        let m = UUID(), p = UUID()
        var j = PrefetchPlanner.Job(media: m, frames: 0...29, priority: 3)
        j.neededFrom = 7
        let r = RenderLoop.remap([j], [m: p])
        #expect(r.first?.media == p)
        #expect(r.first?.neededFrom == 7)
        #expect(r.first?.priority == 3)
    }
}
