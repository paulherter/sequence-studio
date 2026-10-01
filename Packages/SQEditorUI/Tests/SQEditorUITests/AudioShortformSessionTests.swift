import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@MainActor @Suite struct AudioShortformSessionTests {
    /// Video v (linked to audio a), music m, dialogue d, a third audio x.
    private func make() -> (EditorSession, v: Clip, a: Clip, m: Clip, d: Clip, x: Clip) {
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        var m = Clip(name: "m", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        var d = Clip(name: "d", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        let x = Clip(name: "x", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        a.audioTag = nil; m.audioTag = .music; d.audioTag = .dialogue
        var vt = Track(kind: .video), t1 = Track(kind: .audio), t2 = Track(kind: .audio), t3 = Track(kind: .audio), t4 = Track(kind: .audio)
        try! vt.overwrite(v); try! t1.overwrite(a); try! t2.overwrite(m); try! t3.overwrite(d); try! t4.overwrite(x)
        let tl = Timeline(name: "T", frameDuration: fd, tracks: [vt, t1, t2, t3, t4])
        return (EditorSession(project: Project(name: "P", timelines: [tl])), v, a, m, d, x)
    }
    private func clip(_ s: EditorSession, _ id: Clip.ID) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }

    @Test func bracketKeysRaiseThreeClipsInOneUndoStep() {
        let (sess, v, a, m, d, _) = make()
        sess.select(clips: [v.id, a.id, m.id, d.id], captions: [])
        let depth = sess.undoDepth
        #expect(sess.nudgeAudioGain(byDB: 1))
        #expect(sess.undoDepth == depth + 1)
        #expect([a, m, d].allSatisfy { clip(sess, $0.id).audioGainDB == 1 })
        #expect(clip(sess, v.id).audioGainDB == 0)                           // video ignored
        #expect(sess.nudgeAudioGain(byDB: 6))
        #expect(clip(sess, a.id).audioGainDB == 7)
        sess.undo(); sess.undo()
        #expect([a, m, d].allSatisfy { clip(sess, $0.id).audioGainDB == 0 })
    }

    @Test func gainStopsAtTheFloorAndDoesNotMute() {
        let (sess, _, a, _, _, _) = make()
        sess.select(clips: [a.id], captions: [])
        for _ in 0..<40 { sess.nudgeAudioGain(byDB: -6) }
        let g = clip(sess, a.id).audioGainDB
        #expect(g == AudioGain.minGainDB)
        #expect(sess.nudgeAudioGain(byDB: 1))
        #expect(clip(sess, a.id).audioGainDB == AudioGain.minGainDB + 1)
        let (s2, v, _, _, _, _) = make()
        s2.select(clips: [v.id], captions: [])
        #expect(!s2.nudgeAudioGain(byDB: 1))                                  // only a video clip: nothing to do
    }

    @Test func tagsToggleInOneStep() {
        let (sess, _, _, _, _, x) = make()
        sess.select(clips: [x.id], captions: [])
        #expect(sess.toggleAudioTag(.sfx) && clip(sess, x.id).audioTag == .sfx)
        #expect(sess.toggleAudioTag(.sfx) && clip(sess, x.id).audioTag == nil)
        #expect(sess.toggleAudioTag(.music) && clip(sess, x.id).audioTag == .music)
    }

    @Test func autoDuckLowersMusicOnlyWhereDialogueIsAndRerunReplaces() {
        let (sess, _, _, m, _, _) = make()
        sess.select(clips: [], captions: [])
        let depth = sess.undoDepth
        // The dialogue clip is silent from 4 s on.
        let n = sess.autoDuckMusic(silences: { _ in [TimeRange(start: s(4), duration: s(6))] }, amountDB: 12, fade: Time(1, 2))
        #expect(n > 0 && sess.undoDepth == depth + 1)
        let c = clip(sess, m.id)
        #expect(c.volume(at: s(2)) < 0.3 && c.volume(at: s(8)) == 1)
        let n2 = sess.autoDuckMusic(silences: { _ in [TimeRange(start: s(0), duration: s(6))] }, amountDB: 12, fade: Time(1, 2))
        let c2 = clip(sess, m.id)
        #expect(c2.volume(at: s(2)) == 1 && c2.volume(at: s(8)) < 0.3)
        #expect(c2.animation.volume.track.keys.count == n2)
    }

    @Test func noDialogueNoDuck() {
        let (sess, _, _, m, d, _) = make()
        sess.select(clips: [d.id], captions: [])
        sess.toggleAudioTag(.dialogue)                                       // untag the only dialogue clip
        let depth = sess.undoDepth
        #expect(sess.autoDuckMusic(silences: { _ in [] }) == 0)
        #expect(clip(sess, m.id).animation.volume.track.isEmpty && sess.undoDepth == depth)
    }

    @Test func removingSilencesIsOneUndoStepOnLinkedTracks() {
        let (sess, v, a, _, _, _) = make()
        sess.select(clips: [a.id], captions: [])
        let cuts = sess.silenceCuts(for: [a], silences: { _ in [TimeRange(start: s(2), duration: s(2)), TimeRange(start: s(6), duration: s(3))] },
                                    padding: Time(1, 10))
        #expect(cuts.count == 2)
        let depth = sess.undoDepth
        #expect(sess.removeSilences(cuts: cuts, from: [a]))
        #expect(sess.undoDepth == depth + 1)
        let tl = sess.activeTimeline!
        let removed = cuts.reduce(Time.zero) { $0 + $1.duration }
        #expect(tl.tracks[0].end == s(10) - removed && tl.tracks[1].end == s(10) - removed)    // the picture was cut as well
        #expect(v.id != a.id)
        sess.undo()
        #expect(sess.activeTimeline!.tracks[0].end == s(10))
    }
}

@Suite struct AudioShortformHelpersTests {
    @Test func activeRangesAreTheClipMinusPauses() {
        let r = AudioShortform.activeRanges(of: TimeRange(start: s(10), duration: s(10)),
                                            silences: [TimeRange(start: s(12), duration: s(2)), TimeRange(start: s(18), duration: s(5))])
        #expect(r == [TimeRange(start: s(10), duration: s(2)), TimeRange(start: s(14), duration: s(4))])
        #expect(AudioShortform.activeRanges(of: TimeRange(start: .zero, duration: s(4)), silences: []) == [TimeRange(start: .zero, duration: s(4))])
    }

    @Test func mergedJoinsOverlaps() {
        let r = AudioShortform.merged([TimeRange(start: s(5), duration: s(2)), TimeRange(start: s(1), duration: s(2)), TimeRange(start: s(2), duration: s(2)),
                                       TimeRange(start: s(7), duration: s(1))])
        #expect(r == [TimeRange(start: s(1), duration: s(3)), TimeRange(start: s(5), duration: s(3))])
    }

    @Test func silencesComeFromWaveformPeaks() {
        // Mono, 1000 frames/s, 10 buckets of 1000 frames each = 1 s per bucket: loud, quiet x3, loud.
        let peaks: [Float] = [-0.5, 0.5, -0.001, 0.001, -0.001, 0.001, -0.001, 0.001, -0.5, 0.5]
        let data = WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 5000, baseBucketSize: 1000, levels: [peaks])
        let clip = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: s(20))
        let r = AudioShortform.silences(of: clip, in: data, thresholdDB: -40, minimumLength: Time(1, 1))
        #expect(r.count == 1)
        #expect(r[0].start == s(21) && r[0].end == s(24))
    }
}
