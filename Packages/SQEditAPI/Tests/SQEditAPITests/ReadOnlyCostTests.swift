import Foundation
import Testing
import SQCore
@testable import SQEditAPI

/// PALMIER-ISSUES #107 / #556 / #68: a read-only EditAPI call (state read, dry run) must not hold the main actor for
/// long (playback's render loop shares it) and must not touch the model. Many empty lanes and a 60 fps source in a
/// 30 fps sequence are the shapes that hurt other editors.
@Suite struct ReadOnlyCostTests {
    /// 30 fps sequence, `lanes` empty video and audio lanes, one clip of 60 fps media on V1.
    static func sparse(lanes: Int) -> (project: Project, seq: Timeline.ID, clip: Clip.ID) {
        var media = MediaRef(name: "p60.mov", path: "/x/p60.mov", fingerprint: MediaFingerprint(size: 7), duration: Time(60, 1))
        media.duration = Time(60, 1)
        let c = Clip(name: "p60", media: media.id, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)),
                     start: .zero, mediaDuration: Time(60, 1))
        var tracks = [Track(kind: .video, clips: [c], name: "V1", isTargeted: true)]
        for i in 0..<lanes { tracks.append(Track(kind: .video, clips: [], name: "V\(i + 2)")) }
        for i in 0..<lanes { tracks.append(Track(kind: .audio, clips: [], name: "A\(i + 1)")) }
        let t = Timeline(name: "S", frameDuration: Time(1, 30), tracks: tracks)
        var p = Project(name: "P", timelines: [t])
        p.add(media)
        return (p, t.id, c.id)
    }

    @Test func manyEmptyLanesStateAndDryRunAreCheap() throws {
        let s = Self.sparse(lanes: 300)
        let ops: [EditOperation] = (1...200).map { .razor(at: Time(Int64($0), 30), tracks: nil) }
        var diffCount = 0
        let stateMs = SQTiming.bestMs(runs: 3) {
            let st = ProjectState(s.project)
            diffCount = (try? JSONEncoder().encode(st).count) ?? 0
        }
        let applyMs = SQTiming.bestMs(runs: 3) {
            var p = s.project
            try? EditTransaction.apply(ops, to: &p, sequence: s.seq)
        }
        print("ReadOnlyCost state \(stateMs) ms (\(diffCount) B), dry-run apply \(applyMs) ms")
        #expect(diffCount > 0)
        #expect(stateMs < SQTiming.budget(100))
        #expect(applyMs < SQTiming.budget(1500))
    }

    /// The dry run's heavy part runs off the main actor: a ticker on the main actor keeps its beat while 200 razors
    /// over 600 lanes (about 340 ms of work) are applied. Inline on the main actor the largest gap is the whole run.
    @Test @MainActor func offActorApplyKeepsTheMainActorFree() async throws {
        let s = Self.sparse(lanes: 300)
        let ops: [EditOperation] = (1...200).map { .razor(at: Time(Int64($0), 30), tracks: nil) }
        let clock = ContinuousClock()
        var maxGap = 0.0
        var ticks = 0
        let ticker = Task { @MainActor in
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                let now = clock.now
                maxGap = max(maxGap, SQTiming.ms(last.duration(to: now)))
                ticks += 1
                last = now
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let applied = try await EditTransaction.applyOffActor(ops, to: s.project, sequence: s.seq)
        ticker.cancel()
        #expect(applied != s.project)
        #expect(ticks > 5)
        #expect(maxGap < SQTiming.budget(60), "main actor stalled \(maxGap) ms")
    }

    @Test func dryRunLeavesTheModelUntouched() throws {
        let s = Self.sparse(lanes: 50)
        let before = s.project
        var p = s.project
        try EditTransaction.apply([.razor(at: Time(5, 1), tracks: nil)], to: &p, sequence: s.seq)
        #expect(p != before)
        #expect(s.project == before)
    }

    /// 60 fps source in a 30 fps sequence: a cut at a 1/30 s boundary stays an exact rational and the diff is exact.
    @Test func sixtyFpsSourceInThirtyFpsSequenceCutsExactly() throws {
        let s = Self.sparse(lanes: 1)
        var p = s.project
        try EditTransaction.apply([.razor(at: Time(91, 30), tracks: nil)], to: &p, sequence: s.seq)
        let v1 = try #require(p.timeline(s.seq)?.tracks.first)
        #expect(v1.clips.count == 2)
        #expect(v1.clips[1].start == Time(91, 30))
        #expect(v1.clips[0].duration + v1.clips[1].duration == Time(10, 1))
    }
}
