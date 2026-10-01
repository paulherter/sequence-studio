import Foundation
import Testing
import SSCore
import SSMedia
@testable import SSEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct AudioGainPlanTests {
    func item(_ gain: Double = 0, peak: Double? = 0.5) -> AudioGainPlan.Item {
        AudioGainPlan.Item(id: UUID(), name: "c", gainDB: gain, peak: peak)
    }

    @Test func setAndAdjust() {
        let a = item(2), b = item(-1)
        let set = AudioGainPlan.plan(.set(5), items: [a, b])
        #expect(set[a.id] == 5 && set[b.id] == 5)
        let adj = AudioGainPlan.plan(.adjust(3), items: [a, b])
        #expect(adj[a.id] == 5 && adj[b.id] == 2)
    }

    @Test func normalizeEachGivesEveryClipItsOwnGain() {
        let loud = item(peak: 0.5), quiet = item(peak: 0.25), unknown = item(peak: nil), silent = item(peak: 0)
        let r = AudioGainPlan.plan(.normalizeEach(targetDB: 0), items: [loud, quiet, unknown, silent])
        #expect(abs(r[loud.id]! - 6.0206) < 1e-3 && abs(r[quiet.id]! - 12.0412) < 1e-3)
        #expect(r[unknown.id] == nil && r[silent.id] == nil)
    }

    @Test func normalizeTogetherKeepsTheBalance() {
        let loud = item(peak: 0.5), quiet = item(peak: 0.25), unknown = item(peak: nil)
        let r = AudioGainPlan.plan(.normalizeTogether(targetDB: -6), items: [loud, quiet, unknown])
        #expect(abs(r[loud.id]! - 0.0206) < 1e-3 && abs(r[quiet.id]! - 0.0206) < 1e-3)     // -6.02 dB peak to -6 dB, same gain for both
        #expect(r[unknown.id] == nil)
    }

    @Test func normalizeCountsTheVolumeLevel() {
        // Peak 0.5 at Volume +6 dB (x2) is already at 0 dBFS; normalising to -6 dB needs -6 dB of gain.
        let it = AudioGainPlan.Item(id: UUID(), name: "c", gainDB: 0, peak: 0.5, volume: 2)
        let r = AudioGainPlan.plan(.normalizeEach(targetDB: -6.0206), items: [it])
        #expect(abs(r[it.id]! + 6.0206) < 1e-3)
        var c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        #expect(AudioGainPlan.volumePeak(of: c) == 1)
        let k1 = c.addVolumeKey(atLocal: .zero), k2 = c.addVolumeKey(atLocal: Time(2, 1))
        c.animation.volume.track.set(k1, value: 0.5); c.animation.volume.track.set(k2, value: 1.5)
        #expect(AudioGainPlan.volumePeak(of: c) == 1.5)
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
