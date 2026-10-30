import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@Suite struct FitToFillTests {
    private func plan(_ m: SourceMarks, si: Time?, so: Time?, total: Int64 = 20) -> FitToFillPlan? {
        Timeline.fitToFillPlan(sourceMarks: m, total: s(total), sequenceIn: si, sequenceOut: so, frameDuration: fd)
    }

    @Test func longSourceIsSpedUpToTheSequenceRange() throws {
        let p = try #require(plan(SourceMarks(markIn: s(2), markOut: s(10)), si: s(5), so: s(9)))   // 8 s of source into 4 s
        #expect(p.source == TimeRange(start: s(2), end: s(10)))
        #expect(p.at == s(5) && p.length == s(4))
        #expect(p.speed == ClipSpeed(num: 2, den: 1))
    }

    @Test func shortSourceIsSlowedDown() throws {
        let p = try #require(plan(SourceMarks(markIn: s(0), markOut: s(2)), si: s(0), so: s(8)))
        #expect(p.speed == ClipSpeed(num: 1, den: 4))
    }

    @Test func needsBothSequenceMarks() {
        #expect(plan(SourceMarks(markIn: s(0), markOut: s(2)), si: s(0), so: nil) == nil)
        #expect(plan(SourceMarks(markIn: s(0), markOut: s(2)), si: nil, so: s(4)) == nil)
    }

    @Test func withoutSourceMarksTheWholeClipFills() throws {
        let p = try #require(plan(SourceMarks(), si: s(1), so: s(11), total: 5))
        #expect(p.source == TimeRange(start: .zero, duration: s(5)))
        #expect(p.speed == ClipSpeed(num: 1, den: 2))
    }

    @Test func placedClipLastsExactlyTheSequenceRange() throws {
        var t = Timeline(name: "T", format: SequenceFormat(frameDuration: fd), tracks: [Track(kind: .video)])
        let p = try #require(plan(SourceMarks(markIn: s(0), markOut: s(8)), si: s(3), so: s(7)))
        try t.threePointEdit(source: p.source, media: UUID(), mediaDuration: s(20), targets: [t.tracks[0].id], at: p.at,
                             mode: .overwrite, speed: p.speed)
        let c = try #require(t.tracks[0].clips.first)
        #expect(c.speed == ClipSpeed(num: 2, den: 1))
        #expect(c.timeline == TimeRange(start: s(3), end: s(7)))
    }
}
