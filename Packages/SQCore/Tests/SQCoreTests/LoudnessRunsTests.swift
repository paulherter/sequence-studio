import Foundation
import Testing
@testable import SQCore

@Suite struct LoudnessRunsTests {
    private func clip(_ start: Int64, _ dur: Int64, tag: AudioTag? = nil) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(dur, 1)), start: Time(start, 1))
        c.audioTag = tag
        return c
    }

    @Test func adjacentSameRoleClipsJoinAndOthersSplit() throws {
        let a = clip(0, 2), b = clip(2, 3), gap = clip(8, 2), music = clip(10, 2, tag: .music)
        var tr = Track(kind: .audio)
        for c in [a, b, gap, music] { try tr.overwrite(c) }
        let t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [tr])
        let runs = AudioGain.loudnessRuns(of: [a.id, music.id], in: t)
        #expect(runs.map { $0.map(\.id) } == [[a.id, b.id], [music.id]])
    }

    @Test func runOfOnlyUnselectedClipsIsDropped() throws {
        let a = clip(0, 2), b = clip(5, 2)
        var tr = Track(kind: .audio)
        try tr.overwrite(a); try tr.overwrite(b)
        let t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [tr])
        #expect(AudioGain.loudnessRuns(of: [b.id], in: t).map { $0.map(\.id) } == [[b.id]])
    }
}
