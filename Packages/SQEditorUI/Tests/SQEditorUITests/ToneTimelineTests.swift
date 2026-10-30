import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQTimelineUI

/// Tone clip on the timeline: a flat waveform band at the tone's level, scaled by the clip gain; a repeated Bleep says so.
@MainActor @Suite struct ToneTimelineTests {
    @Test func toneWaveformIsAFlatBandAtTheToneLevel() {
        let spec = ToneSpec(frequencyHz: 1000, levelDB: -12)
        let end = Time(10, 1)
        let data = ToneWaveform.data(for: spec, sourceEnd: end)
        let amp = Float(pow(10.0, -12.0 / 20))
        for (db, scale) in [(0.0, Float(1)), (-6.0, Float(pow(10.0, -6.0 / 20)))] {
            var input = WaveformPath.Input(data: data, source: TimeRange(start: .zero, duration: end), clipWidth: 200,
                                           visibleColumns: 0..<200, volumeDB: { _ in db })
            input.cache = nil
            let cols = WaveformPath.columns(input)[0]
            #expect(cols.count == 200)
            #expect(cols.allSatisfy { abs($0.hi - amp * scale) < 1e-4 && !$0.clipped })
        }
    }

    @Test func repeatedBleepShowsAShortMessage() throws {
        let talk = Clip(name: "Talk", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)),
                        start: .zero, mediaDuration: Time(10, 1))
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .audio, clips: [talk])])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        s.setInPoint(at: Time(2, 1)); s.setOutPoint(at: Time(4, 1))
        s.bleepRange()
        #expect(s.lastError == nil)
        let tracks = s.activeTimeline?.tracks.count
        s.bleepRange()
        #expect(s.lastError == "Nothing left to bleep there.")
        #expect(s.activeTimeline?.tracks.count == tracks)
    }
}
