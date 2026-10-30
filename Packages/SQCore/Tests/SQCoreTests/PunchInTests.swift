import Foundation
import Testing
@testable import SQCore

@Suite struct PunchInTests {
    func s(_ n: Int64) -> Time { Time(n, 1) }
    func make(_ n: Int = 2) -> (Timeline, [Clip]) {
        var v = Track(kind: .video)
        var clips: [Clip] = []
        for i in 0..<n {
            let c = Clip(name: "c\(i)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(Int64(i) * 2))
            try! v.overwrite(c); clips.append(c)
        }
        return (Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: [v]), clips)
    }
    func clip(_ t: Timeline, _ c: Clip) -> Clip { t.find(c.id)!.clip }

    @Test func punchAddsTransformStageAtDefaultScale() throws {
        var (t, cs) = make()
        let on = try t.togglePunchIn([cs[0].id])
        #expect(on)
        let e = try #require(clip(t, cs[0]).effects.first { $0.id == PunchIn.effectID(for: cs[0].id) })
        #expect(e.kind == ClipEffect.transformKind)
        #expect(e.parameters[ClipEffect.stageScaleKey]?.value == PunchIn.defaultScale)
        #expect(clip(t, cs[1]).effects.isEmpty)
        #expect(clip(t, cs[0]).animation == cs[0].animation)   // Motion untouched
    }

    @Test func toggleTwiceIsOriginal() throws {
        var (t, cs) = make()
        let before = t
        _ = try t.togglePunchIn([cs[0].id]); let off = try t.togglePunchIn([cs[0].id])
        #expect(!off)
        #expect(t == before)
    }

    @Test func mixedSelectionPunchesAllThenRemovesAll() throws {
        var (t, cs) = make()
        _ = try t.togglePunchIn([cs[0].id])
        let on = try t.togglePunchIn(cs.map(\.id))   // one already punched: the rest get it
        #expect(on)
        #expect(cs.allSatisfy { t.isPunchedIn(clip(t, $0)) })
        let off = try t.togglePunchIn(cs.map(\.id))
        #expect(!off)
        #expect(cs.allSatisfy { !t.isPunchedIn(clip(t, $0)) })
    }

    @Test func refusesAudioAndLocked() throws {
        var (t, cs) = make()
        t.tracks[0].isLocked = true
        #expect(throws: EditError.self) { _ = try t.togglePunchIn([cs[0].id]) }
        t.tracks[0].isLocked = false
        var a = Track(kind: .audio)
        let ac = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(1)), start: .zero)
        try a.overwrite(ac); t.tracks.append(a)
        #expect(throws: EditError.self) { _ = try t.togglePunchIn([ac.id]) }
    }

    @Test func punchSurvivesRename() throws {
        var (t, cs) = make()
        _ = try t.togglePunchIn([cs[0].id])
        var c = clip(t, cs[0]); c.name = "renamed"; t.tracks[0].replace(c)
        #expect(t.isPunchedIn(clip(t, cs[0])))
    }
}
