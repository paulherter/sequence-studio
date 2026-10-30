import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorUI
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

// The plan itself is tested in SQCore (AudioGainPlanTests); here the waveform peak and the forwarders.
@MainActor @Suite struct AudioGainDialogPeakTests {
    @Test func forwardersMatchTheCorePlan() {
        #expect(AudioGainDialog.peakModeNote(itemCount: 3) == AudioGainPlan.peakModeNote(itemCount: 3))
        #expect(AudioGainDialog.choice(index: 2, value: -1) == .normalizeEach(targetDB: -1))
    }

    @Test func peakOfAClipsSourceRange() {
        // One channel, 1000 frames/s, one bucket per second: second 0 peaks at 0.1, second 1 at 0.8 (negative side).
        let data = WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 2000, baseBucketSize: 1000, levels: [[-0.1, 0.1, -0.8, 0.4]])
        #expect(abs(AudioGainPlan.peak(of: data, source: TimeRange(start: .zero, duration: s(1))) - 0.1) < 0.01)
        #expect(abs(AudioGainPlan.peak(of: data, source: TimeRange(start: s(1), duration: s(1))) - 0.8) < 0.01)
    }
}

@MainActor @Suite struct AudioGainSessionTests {
    private func session(_ clips: [(Track.ID?, Clip)]) -> (EditorSession, [Clip]) {
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero, link: link)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(4)), start: .zero, link: link)
        let other = Clip(name: "o", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(4)), start: s(5))
        var vt = Track(kind: .video), at = Track(kind: .audio)
        try! vt.overwrite(v); try! at.overwrite(a); try! at.overwrite(other)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [vt, at])
        return (EditorSession(project: Project(name: "P", timelines: [t])), [v, a, other])
    }

    @Test func targetsAreSelectedAudioAndTheAudioOfLinkedVideo() {
        let (sess, c) = session([])
        sess.select(clips: [c[0].id], captions: [])                       // video only: its linked audio
        #expect(sess.audioGainTargets.map(\.id) == [c[1].id])
        sess.select(clips: [c[2].id], captions: [])
        #expect(sess.audioGainTargets.map(\.id) == [c[2].id])
        sess.select(clips: [], captions: [])
        #expect(sess.audioGainTargets.isEmpty)
    }

    @Test func settingGainIsOneUndoStepAndChangesTheVolume() {
        let (sess, c) = session([])
        let depth = sess.undoDepth
        #expect(sess.setAudioGain([c[1].id: 6.0206, c[2].id: -6.0206]))
        #expect(sess.undoDepth == depth + 1)
        let clips = sess.activeTimeline!.tracks.flatMap(\.clips)
        #expect(abs(clips.first { $0.id == c[1].id }!.volume(at: s(1)) - 2) < 1e-3)
        #expect(abs(clips.first { $0.id == c[2].id }!.volume(at: s(6)) - 0.5) < 1e-3)
        sess.undo()
        #expect(sess.activeTimeline!.tracks.flatMap(\.clips).allSatisfy { $0.audioGainDB == 0 })
    }
}
