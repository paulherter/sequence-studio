import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ d: Int64) -> TimeRange { TimeRange(start: s(a), duration: s(d)) }

/// Linked V1/A1 over 0-20 s.
private func makeTimeline() -> (Timeline, Clip) {
    let m = UUID(), link = UUID()
    let v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
    let a = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
    var vt = Track(kind: .video), at = Track(kind: .audio)
    try! vt.overwrite(v); try! at.overwrite(a)
    return (Timeline(name: "t", frameDuration: Time(1, 30), tracks: [vt, at]), a)
}

/// Crossfade at the joins of Remove Silences: every audio join gets a short fade out and fade in, in the same undo step.
@Suite struct JoinFadeTests {
    @Test func acceptWithJoinFadeSoftensEveryJoinOfTheAudio() throws {
        var (tl, a) = makeTimeline()
        tl.proposeCuts([r(2, 1), r(6, 2)], kind: .silence)
        try tl.acceptProposedCuts(nil, around: [a.id], joinFade: Time(1, 15))
        let audio = tl.tracks[1].clips
        #expect(audio.map(\.start) == [.zero, s(2), s(5)])
        #expect(audio[0].audioFadeOut == Time(1, 15) && audio[0].audioFadeIn == .zero)
        #expect(audio[1].audioFadeIn == Time(1, 15) && audio[1].audioFadeOut == Time(1, 15))
        #expect(audio[2].audioFadeIn == Time(1, 15) && audio[2].audioFadeOut == .zero)
        #expect(tl.tracks[0].clips.allSatisfy { $0.audioFadeIn == .zero && $0.audioFadeOut == .zero })
    }

    @Test func removeSilencesTakesTheSameFade() throws {
        var (tl, a) = makeTimeline()
        try tl.removeSilences([r(4, 2)], around: [a.id], joinFade: Time(1, 15))
        let audio = tl.tracks[1].clips
        #expect(audio.count == 2 && audio[0].audioFadeOut == Time(1, 15) && audio[1].audioFadeIn == Time(1, 15))
    }

    @Test func noFadeByDefault() throws {
        var (tl, a) = makeTimeline()
        tl.proposeCuts([r(2, 1)], kind: .silence)
        try tl.acceptProposedCuts(nil, around: [a.id])
        #expect(tl.tracks[1].clips.allSatisfy { $0.audioFadeIn == .zero && $0.audioFadeOut == .zero })
    }

    @Test func aLongerFadeThatAlreadyExistsIsKept() throws {
        var (tl, a) = makeTimeline()
        var own = tl.tracks[1].clips[0]
        own.setAudioFadeOut(Time(1, 2), frameDuration: Time(1, 30))   // the clip's own end
        try tl.replaceClip(own)
        try tl.removeSilences([r(2, 1)], around: [a.id], joinFade: Time(1, 15))
        let audio = tl.tracks[1].clips
        #expect(audio.count == 2)
        #expect(audio[1].audioFadeOut == Time(1, 2))
        #expect(audio[0].audioFadeOut == Time(1, 15))
    }
}
