import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Review findings 3 (retimed clips: keys are timeline-local) and 23 (Audio Gain info text).
@Suite struct ReviewAudioTests {
    private func retimed(_ percent: Double) -> Clip {
        var c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: s(5),
                     speed: ClipSpeed(percent: percent))
        c.animation.volume.track.insert(Keyframe(time: Time(1, 1), value: 1))
        c.animation.volume.track.insert(Keyframe(time: c.duration - Time(1, 1), value: 0.5))
        return c
    }

    @Test func keysAreDrawnAndClampedInTimelineTimeAtAnySpeed() {
        for pct in [50.0, 200.0] {
            var c = retimed(pct)
            let rect = CGRect(x: 100, y: 0, width: 400, height: 60)
            let d = Double(c.duration.value) / Double(c.duration.timescale)
            let pts = VolumeLine.keyPoints(clip: c, clipRect: rect)
            #expect(abs(pts[0].x - (100 + 400 / d)) < 1e-6, "first key at \(pct)%")
            #expect(abs(pts[1].x - (500 - 400 / d)) < 1e-6, "last key at \(pct)%")
            // A key cannot be dragged past the clip end (timeline duration), and can reach the second half.
            let id = c.animation.volume.track.keys[1].id
            c.moveVolumeKey(id, toLocal: s(1000), gainDB: 0)
            #expect(c.animation.volume.track.key(id: id)!.time <= c.duration)
            c.moveVolumeKey(id, toLocal: c.duration - Time(1, 10), gainDB: 0)
            #expect(c.animation.volume.track.key(id: id)!.time == c.duration - Time(1, 10))
        }
    }

    @Test func gainDialogShowsThePeakForOneClipToo() {
        let one = AudioGainPlan.Item(id: UUID(), name: "Interview", gainDB: 0, peak: 0.5)
        #expect(AudioGainDialog.infoText(items: [one]) == "Interview\nPeak amplitude: -6.0 dB")
        let two = AudioGainDialog.infoText(items: [one, AudioGainPlan.Item(id: UUID(), name: "B", gainDB: 0, peak: 0.25)])
        #expect(two == "2 clips\nPeak amplitude: -6.0 dB")
        #expect(AudioGainDialog.infoText(items: [AudioGainPlan.Item(id: UUID(), name: "X", gainDB: 0, peak: nil)]) == "X")
    }
}
