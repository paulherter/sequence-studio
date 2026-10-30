import Testing
import SQCore
@testable import SQAnalysis

@Suite struct MusicFitTests {
    /// 120 BPM, 4/4: a bar is 2 s; 16 bars = 32 s.
    private func grid() -> BeatGrid {
        let beats = (0..<64).map { Time(Int64($0), 2) }
        return BeatGrid(beats: beats, downbeatBeatIndices: Array(stride(from: 0, to: 64, by: 4)), beatsPerBar: 4, bpm: 120)
    }
    private let dur = Time(32, 1)

    @Test func shorteningLandsOnBarsAndHitsTarget() {
        let vs = MusicFit.propose(grid: grid(), duration: dur, target: Time(20, 1))
        #expect(vs.count == 3)
        for v in vs {
            #expect(v.length == Time(20, 1))
            #expect(v.lengthError == .zero)
            #expect(v.jumpBars == 6)
            #expect(v.removesAudio)
            #expect(v.segments.first!.source.start == .zero)
            #expect(v.segments.last!.source.end == dur)
            for j in v.joins { #expect(j.value * 2 % Int64(j.timescale) == 0) }
        }
        #expect(Set(vs.map { $0.joins[0] }).count == 3)
    }

    @Test func lengtheningLoopsWholeBars() {
        let vs = MusicFit.propose(grid: grid(), duration: dur, target: Time(40, 1))
        #expect(!vs.isEmpty)
        #expect(vs[0].length == Time(40, 1))
        #expect(!vs[0].removesAudio)
        #expect(vs[0].segments.last!.source.end == dur)
    }

    @Test func degenerateInputs() {
        #expect(MusicFit.propose(grid: grid(), duration: dur, target: dur).isEmpty)
        let one = BeatGrid(beats: [.zero], downbeatBeatIndices: [0], beatsPerBar: 4, bpm: 120)
        #expect(MusicFit.propose(grid: one, duration: dur, target: Time(10, 1)).isEmpty)
    }

    @Test func barBoundariesStayInsideDuration() {
        #expect(MusicFit.barBoundaries(grid: grid(), duration: Time(7, 1)).count == 4)
    }
}
