import Foundation
import Testing
@testable import SQAudioFX

@Suite struct SpectrumDisplayTests {
    @Test func newReadingShowsAtOnceAndFallsWithoutAudio() {
        var d = SpectrumDisplay()
        #expect(d.levelsDB.isEmpty)
        d.update(sequence: 1, at: 0) { [-20, -40] }
        #expect(d.levelsDB == [-20, -40])
        // Same sequence = no new audio: the curve falls at `fallDBPerSecond`.
        d.update(sequence: 1, at: 0.1) { Issue.record("no FFT without new audio"); return [] }
        #expect(abs(d.levelsDB[0] - (-20 - SpectrumDisplay.fallDBPerSecond * 0.1)) < 0.01)
        // A new reading rises at once, a lower one only pulls the curve down at the fall rate.
        d.update(sequence: 2, at: 0.2) { [-10, -90] }
        #expect(d.levelsDB[0] == -10)
        #expect(abs(d.levelsDB[1] - (-40 - SpectrumDisplay.fallDBPerSecond * 0.2)) < 0.01)
    }

    @Test func staleOrUnwatchedClears() {
        var d = SpectrumDisplay()
        d.update(sequence: 3, at: 1) { [-30] }
        d.update(sequence: 3, at: 1 + SpectrumDisplay.staleSeconds + 0.01) { [] }
        #expect(d.levelsDB.isEmpty)
        d.update(sequence: 4, at: 2) { [-30] }
        d.update(sequence: nil, at: 2.01) { [] }
        #expect(d.levelsDB.isEmpty)
        // Sequence 0 = nothing published since watching began.
        d.update(sequence: 0, at: 3) { [-30] }
        #expect(d.levelsDB.isEmpty)
    }

    @Test func plotMapping() {
        #expect(SpectrumDisplay.fraction(dB: SpectrumDisplay.topDB) == 1)
        #expect(SpectrumDisplay.fraction(dB: SpectrumDisplay.bottomDB) == 0)
        #expect(SpectrumDisplay.fraction(dB: -200) == 0 && SpectrumDisplay.fraction(dB: 10) == 1)
    }
}
