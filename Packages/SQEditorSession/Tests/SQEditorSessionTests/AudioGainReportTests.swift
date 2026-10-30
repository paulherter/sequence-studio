import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct AudioGainReportTests {
    private func make(gains: [Double]) -> (EditorSession, [Clip]) {
        var clips: [Clip] = []
        var tracks: [Track] = []
        for g in gains {
            var c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
            c.audioGainDB = g
            var t = Track(kind: .audio)
            try! t.overwrite(c)
            clips.append(c); tracks.append(t)
        }
        let tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: tracks)
        return (EditorSession(project: Project(name: "P", timelines: [tl])), clips)
    }

    @Test func reportsStepAndNewGain() {
        let (sess, c) = make(gains: [2])
        sess.select(clips: [c[0].id], captions: [])
        #expect(sess.nudgeAudioGainReport(byDB: 1) == "Gain +1 dB (now +3 dB)")
        #expect(sess.nudgeAudioGainReport(byDB: -6) == "Gain -6 dB (now -3 dB)")
        #expect(sess.nudgeAudioGainReport(byDB: 3) == "Gain +3 dB (now 0 dB)")
    }

    @Test func clipsWithDifferentGainsReportTheCount() {
        let (sess, c) = make(gains: [0, 2])
        sess.select(clips: Set(c.map(\.id)), captions: [])
        #expect(sess.nudgeAudioGainReport(byDB: 1) == "Gain +1 dB on 2 clips")
    }

    @Test func nothingSelectedReportsNil() {
        let (sess, _) = make(gains: [0])
        #expect(sess.nudgeAudioGainReport(byDB: 1) == nil)
    }

    @Test func atTheFloorSaysGainAtLimit() {
        let (sess, c) = make(gains: [AudioGain.minGainDB])
        sess.select(clips: [c[0].id], captions: [])
        #expect(sess.nudgeAudioGainReport(byDB: -6) == "Gain at limit")
    }

    @Test func reportsTheStepActuallyApplied() {
        let (sess, c) = make(gains: [AudioGain.minGainDB + 2, 0])
        sess.select(clips: Set(c.map(\.id)), captions: [])
        // The first clip can only move 2 dB down, the second the full 6: the report names what happened to the second.
        #expect(sess.nudgeAudioGainReport(byDB: -6)?.hasPrefix("Gain -6 dB") == true)
    }
}
