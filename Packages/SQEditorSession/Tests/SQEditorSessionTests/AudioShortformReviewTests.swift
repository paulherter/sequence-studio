import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)
private func aclip(_ start: Int64, _ dur: Int64, tag: AudioTag? = nil) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
    c.audioTag = tag
    return c
}

@MainActor @Suite struct AudioShortformReviewTests {
    private func session(_ tracks: [Track]) -> EditorSession {
        EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: tracks)]))
    }
    private func track(_ c: Clip, muted: Bool = false, solo: Bool = false) -> Track {
        var t = Track(kind: .audio); try! t.overwrite(c); t.isMuted = muted; t.isSolo = solo
        return t
    }

    @Test func disabledMutedAndNonSoloDialogueDoesNotDuck() {
        let on = aclip(0, 4, tag: .dialogue)
        var off = aclip(0, 10, tag: .dialogue); off.isEnabled = false
        let muted = aclip(0, 10, tag: .dialogue)
        let sess = session([track(on), track(off), track(muted, muted: true)])
        #expect(sess.dialogueRanges { _ in [] } == [TimeRange(start: .zero, duration: s(4))])
        let soloOnly = session([track(aclip(0, 3, tag: .dialogue), solo: true), track(aclip(0, 8, tag: .dialogue))])
        #expect(soloOnly.dialogueRanges { _ in [] } == [TimeRange(start: .zero, duration: s(3))])     // the non-solo track is not heard
    }

    @Test func overlappingClipsArePausesOnlyWhereAllAreSilent() {
        let a = aclip(0, 10), b = aclip(5, 10)
        let r = AudioShortform.combinedSilences([(a.timeline, [TimeRange(start: s(2), duration: s(8))]),          // a silent 2...10
                                                 (b.timeline, [TimeRange(start: s(5), duration: s(3))])])         // b silent 5...8
        // a is silent 2...10, b speaks 8...15, so 2...8 is the pause (b is silent 5...8, nobody covers 2...5 but a).
        #expect(r == [TimeRange(start: s(2), duration: s(6))])
    }

    @Test func nonOverlappingClipsKeepTheUnion() {
        let a = aclip(0, 5), b = aclip(5, 5)
        let r = AudioShortform.combinedSilences([(a.timeline, [TimeRange(start: s(3), duration: s(2))]),
                                                 (b.timeline, [TimeRange(start: s(5), duration: s(2))])])
        #expect(r == [TimeRange(start: s(3), duration: s(4))])                                                      // touching pauses join
    }

    @Test func removeSilencesWithOverlappingClipsKeepsTheSpokenPart() {
        let a = aclip(0, 10), b = aclip(0, 10)
        var t1 = Track(kind: .audio), t2 = Track(kind: .audio)
        try! t1.overwrite(a); try! t2.overwrite(b)
        let sess = session([t1, t2])
        let cuts = sess.silenceCuts(for: [a, b], silences: { $0.id == a.id ? [TimeRange(start: s(2), duration: s(6))] : [] }, padding: .zero)
        #expect(cuts.isEmpty)                                                                                         // b is never silent
    }

    @Test func disabledClipsAreNotPausesEither() {
        var a = aclip(0, 10); a.isEnabled = false
        let sess = session([track(a)])
        #expect(sess.silenceCuts(for: [a], silences: { _ in [TimeRange(start: s(2), duration: s(6))] }, padding: .zero).isEmpty)
    }

    @Test func detectionSeesGainVolumeAndTrackFader() {
        var c = aclip(0, 4)
        let quiet: (TimeRange) -> Float = { _ in 0.01 }                         // -40 dB
        #expect(AudioShortform.silences(of: c, thresholdDB: -30, minimumLength: s(1), sourcePeak: quiet).count == 1)
        c.audioGainDB = 20                                                      // now -20 dB: speech, not a pause
        #expect(AudioShortform.silences(of: c, thresholdDB: -30, minimumLength: s(1), sourcePeak: quiet).isEmpty)
        #expect(AudioShortform.silences(of: c, trackVolumeDB: -20, thresholdDB: -30, minimumLength: s(1), sourcePeak: quiet).count == 1)
    }

    @Test func reversedDetectionLandsOnTheTimelineSide() {
        var c = aclip(10, 4); c.reversed = true
        let loudAtFileStart: (TimeRange) -> Float = { $0.start < s(1) ? 1 : 0 }
        let r = AudioShortform.silences(of: c, thresholdDB: -40, minimumLength: Time(1, 2), sourcePeak: loudAtFileStart)
        // Played backwards the file's first second is the LAST second of the clip: the pause is its first 3 s.
        #expect(r.count == 1 && r[0].start == s(10) && r[0].end >= s(13) - Time(1, 50) && r[0].end <= s(13) + Time(1, 50))
    }

    @Test func fadeOnAnEdgeWithATransitionIsRemovedByTheEditPipeline() throws {
        var a = aclip(0, 4), b = aclip(4, 4)
        a.setAudioFadeOut(s(1), frameDuration: fd); b.setAudioFadeIn(s(1), frameDuration: fd)
        var t = Track(kind: .audio); try t.overwrite(a); try t.overwrite(b)
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [t])
        let tr = tl.tracks[0].id
        _ = try tl.addTransition(kind: .constantGain, track: tr, outgoing: a.id, incoming: b.id, duration: fd * 15)
        let sess = EditorSession(project: Project(name: "P", timelines: [tl]))
        sess.select(clips: [a.id], captions: [])
        #expect(sess.nudgeAudioGain(byDB: 1))                                   // any edit runs the normalizing hook
        let clips = sess.activeTimeline!.tracks[0].clips
        #expect(clips[0].audioFadeOut == .zero && clips[1].audioFadeIn == .zero)
    }
}
