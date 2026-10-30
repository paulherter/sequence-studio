import Foundation
import Testing
@testable import SQCore

@Suite struct AudioGainPlanTests {
    func item(_ gain: Double = 0, peak: Double? = 0.5) -> AudioGainPlan.Item {
        AudioGainPlan.Item(id: UUID(), name: "c", gainDB: gain, peak: peak)
    }

    @Test func noteOnlyForSeveralClips() {
        #expect(AudioGainPlan.peakModeNote(itemCount: 1) == nil)
        #expect(AudioGainPlan.peakModeNote(itemCount: 3)?.contains("All Peaks") == true)
    }

    @Test func choiceRowsInDialogOrder() {
        #expect(AudioGainPlan.choice(index: 0, value: 3) == .set(3))
        #expect(AudioGainPlan.choice(index: 1, value: 3) == .adjust(3))
        #expect(AudioGainPlan.choice(index: 2, value: -1) == .normalizeEach(targetDB: -1))
        #expect(AudioGainPlan.choice(index: 3, value: -1) == .normalizeTogether(targetDB: -1))
        #expect(AudioGainPlan.choice(index: 4, value: -14) == .normalizeLoudness(targetLUFS: -14))
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
        // Peak 0.5 at Volume +6 dB (x2) is already at 0 dBFS; normalizing to -6 dB needs -6 dB of gain.
        let it = AudioGainPlan.Item(id: UUID(), name: "c", gainDB: 0, peak: 0.5, volume: 2)
        let r = AudioGainPlan.plan(.normalizeEach(targetDB: -6.0206), items: [it])
        #expect(abs(r[it.id]! + 6.0206) < 1e-3)
        var c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        #expect(AudioGainPlan.volumePeak(of: c) == 1)
        let k1 = c.addVolumeKey(atLocal: .zero), k2 = c.addVolumeKey(atLocal: Time(2, 1))
        c.animation.volume.track.set(k1, value: 0.5); c.animation.volume.track.set(k2, value: 1.5)
        #expect(AudioGainPlan.volumePeak(of: c) == 1.5)
    }

    @Test func normalizeLoudnessUsesTheMeasuredValue() {
        let a = AudioGainPlan.Item(id: UUID(), name: "a", gainDB: 3, peak: 0.1, lufs: -26)
        let b = AudioGainPlan.Item(id: UUID(), name: "b", gainDB: 0, peak: 0.1, lufs: nil)
        let silent = AudioGainPlan.Item(id: UUID(), name: "s", gainDB: 0, peak: 0.1, lufs: -80)
        let r = AudioGainPlan.plan(.normalizeLoudness(targetLUFS: -14), items: [a, b, silent])
        #expect(r[a.id] == 12)                     // absolute gain from the measurement, not relative to the old gain
        #expect(r[b.id] == nil && r[silent.id] == nil)
    }

    @Test func clipWarningCountsClipsThatEndAboveFullScale() {
        let quiet = AudioGainPlan.Item(id: UUID(), name: "q", gainDB: 0, peak: 0.05, lufs: -30)      // +16 dB: 0.05 -> 0.32
        let peaky = AudioGainPlan.Item(id: UUID(), name: "p", gainDB: 0, peak: 0.9, lufs: -20)       // +6 dB: 0.9 -> 1.8
        let unknownPeak = AudioGainPlan.Item(id: UUID(), name: "u", gainDB: 0, peak: nil, lufs: -20)
        let choice = AudioGainChoice.normalizeLoudness(targetLUFS: -14)
        #expect(AudioGainPlan.clippingClips(choice, items: [quiet, peaky, unknownPeak]) == [peaky.id])
        #expect(AudioGainPlan.warningText(choice: choice, items: [quiet, peaky]) == "1 clip would peak above 0 dB.")
        #expect(AudioGainPlan.warningText(choice: choice, items: [quiet]) == nil)
        #expect(AudioGainPlan.warningText(choice: .adjust(12), items: [peaky, quiet]) == "1 clip would peak above 0 dB.")
        #expect(AudioGainPlan.warningText(choice: .normalizeEach(targetDB: 0), items: [peaky]) == nil)
    }

    @Test func loudnessLine() {
        let a = AudioGainPlan.Item(id: UUID(), name: "a", gainDB: 0, peak: 0.1, lufs: -23.44)
        let b = AudioGainPlan.Item(id: UUID(), name: "b", gainDB: 0, peak: 0.1, lufs: -18.0)
        #expect(AudioGainPlan.loudnessText(items: [a], measuring: false) == "Loudness: \u{2212}23.4 LUFS")
        #expect(AudioGainPlan.loudnessText(items: [a, b], measuring: false) == "Loudness: \u{2212}23.4 to \u{2212}18.0 LUFS")
        #expect(AudioGainPlan.loudnessText(items: [a], measuring: true) == "Loudness: \u{2212}23.4 LUFS (measuring...)")
        let none = AudioGainPlan.Item(id: UUID(), name: "n", gainDB: 0, peak: 0.1)
        #expect(AudioGainPlan.loudnessText(items: [none], measuring: true) == "Loudness: measuring...")
        #expect(AudioGainPlan.loudnessText(items: [none], measuring: false) == "Loudness: silent or unknown")
    }

    @Test func infoLine() {
        let one = AudioGainPlan.Item(id: UUID(), name: "Interview", gainDB: 0, peak: 0.5)
        #expect(AudioGainPlan.infoText(items: [one]) == "Interview\nPeak amplitude: -6.0 dB")
        #expect(AudioGainPlan.infoText(items: [AudioGainPlan.Item(id: UUID(), name: "X", gainDB: 0, peak: nil)]) == "X")
    }
}
