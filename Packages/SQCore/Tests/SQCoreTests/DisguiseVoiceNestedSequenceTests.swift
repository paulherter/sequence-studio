import Foundation
import Testing
@testable import SQCore

@Suite struct DisguiseVoiceNestedSequenceTests {
    private static let fmt = SequenceFormat(frameDuration: Time(1, 30))

    private static func seq(_ clips: [Clip]) throws -> Timeline {
        var t = Track(kind: .audio)
        for c in clips { try t.overwrite(c) }
        return Timeline(name: "S", format: fmt, tracks: [t])
    }

    private static func nest(of t: Timeline, disguised: Bool) -> Clip {
        var n = Clip(name: "n", media: t.id, kind: .audio, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero, sequence: t.id)
        if disguised { _ = n.addEffect(kind: ClipEffect.audioDisguiseVoiceKind) }
        return n
    }

    @Test func innerSequenceUnderADisguisedNestClipIsFlagged() throws {
        let inner = try Self.seq([])
        let outer = try Self.seq([Self.nest(of: inner, disguised: true)])
        let p = Project(name: "P", timelines: [outer, inner])
        #expect(p.sequencesNestedUnderDisguiseVoice() == [inner.id])
    }

    @Test func deeperLevelsAreFlaggedToo() throws {
        let deep = try Self.seq([])
        let mid = try Self.seq([Self.nest(of: deep, disguised: false)])
        let outer = try Self.seq([Self.nest(of: mid, disguised: true)])
        let p = Project(name: "P", timelines: [outer, mid, deep])
        #expect(p.sequencesNestedUnderDisguiseVoice() == [mid.id, deep.id])
    }

    @Test func plainNestsAndCyclesFlagNothing() throws {
        let inner = try Self.seq([])
        let outer = try Self.seq([Self.nest(of: inner, disguised: false)])
        #expect(Project(name: "P", timelines: [outer, inner]).sequencesNestedUnderDisguiseVoice().isEmpty)
        let a = Timeline(name: "A", format: Self.fmt, tracks: [Track(kind: .audio)]), b = Timeline(name: "B", format: Self.fmt, tracks: [Track(kind: .audio)])
        var ta = a.tracks[0], tb = b.tracks[0]
        try ta.overwrite(Self.nest(of: b, disguised: true)); try tb.overwrite(Self.nest(of: a, disguised: false))
        var a2 = a, b2 = b
        a2.tracks = [ta]; b2.tracks = [tb]
        #expect(Project(name: "P", timelines: [a2, b2]).sequencesNestedUnderDisguiseVoice() == [a.id, b.id])      // terminates
    }
}
