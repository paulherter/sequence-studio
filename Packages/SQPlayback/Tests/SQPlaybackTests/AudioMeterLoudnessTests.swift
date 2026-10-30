import Foundation
import Testing
import SQAudioFX
@testable import SQPlayback

@Suite struct AudioMeterLoudnessTests {
    private func sine(_ seconds: Double, amp: Float) -> [Float] {
        (0..<Int(48_000 * seconds)).map { amp * Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
    }

    private func feed(_ store: AudioMeterStore, _ x: [Float]) {
        var i = 0
        while i < x.count {   // buffers of 1024 like the tap
            let chunk = Array(x[i..<min(i + 1024, x.count)])
            chunk.withUnsafeBufferPointer { p in store.measure(p.baseAddress!, p.baseAddress!, count: chunk.count) }
            i += 1024
        }
    }

    @Test func storeReportsTheSameNumbersAsTheBS1770Meter() {
        let x = sine(4, amp: 0.25)
        let store = AudioMeterStore()
        feed(store, x)
        var ref = LoudnessMeter(sampleRate: 48_000, channelCount: 2)
        ref.process([x, x])
        let s = store.snapshot.loudness
        #expect(abs((s.momentary ?? -99) - (ref.momentary ?? 99)) < 0.01)
        #expect(abs((s.shortTerm ?? -99) - (ref.shortTerm ?? 99)) < 0.01)
        #expect(abs((s.integrated ?? -99) - ref.integrated) < 0.01)
        #expect(abs(s.truePeakDB - (ref.truePeakDB.max() ?? 0)) < 0.01)
    }

    @Test func notEnoughSignalGivesNilAndResetClears() {
        let store = AudioMeterStore()
        feed(store, sine(0.2, amp: 0.25))
        #expect(store.snapshot.loudness.momentary == nil)
        feed(store, sine(4, amp: 0.25))
        #expect(store.snapshot.loudness.integrated != nil)
        store.resetLoudness()
        #expect(store.snapshot.loudness.integrated == nil)
        #expect(store.snapshot.loudness.truePeakDB == -.infinity)
    }
}
