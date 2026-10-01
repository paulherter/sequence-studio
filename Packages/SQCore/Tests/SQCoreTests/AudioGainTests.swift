import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func audio(_ start: Int64 = 0, _ dur: Int64 = 10) -> Clip {
    Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}

@Suite struct AudioGainTests {
    @Test func gainIsAppliedOnTopOfVolume() {
        var c = audio()
        #expect(c.audioGainDB == 0 && c.volume(at: s(1)) == 1)
        c.audioGainDB = 6.0206
        #expect(abs(c.volume(at: s(1)) - 2) < 1e-3)
        c.animation.volume = AnimatedProperty(0.5)
        #expect(abs(c.volume(at: s(1)) - 1) < 1e-3)
    }

    @Test func gainRoundTripsAndOldClipsHaveNone() throws {
        var c = audio(); c.audioGainDB = -4.5
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back.audioGainDB == -4.5)
        // A file written before the field existed.
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(audio())) as! [String: Any]
        obj["audioGainDB"] = nil
        let old = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.audioGainDB == 0)
    }

    @Test func dbConversions() {
        #expect(abs(AudioGain.db(fromLinear: 1) - 0) < 1e-12)
        #expect(abs(AudioGain.db(fromLinear: 0.5) + 6.0206) < 1e-3)
        #expect(AudioGain.db(fromLinear: 0) == AudioGain.silenceDB)
        #expect(abs(AudioGain.linear(fromDB: 20) - 10) < 1e-12)
        #expect(AudioGain.linear(fromDB: AudioGain.silenceDB) == 0)
    }

    @Test func gainModes() {
        // Set: absolute. Adjust: relative to the clip's current gain. Both clamp.
        #expect(AudioGain.apply(.set(3), to: 10, peak: nil) == 3)
        #expect(AudioGain.apply(.adjust(-2), to: 3, peak: nil) == 1)
        #expect(AudioGain.apply(.set(500), to: 0, peak: nil) == AudioGain.maxGainDB)
        #expect(AudioGain.apply(.adjust(-500), to: 0, peak: nil) == AudioGain.minGainDB)
    }

    @Test func normalizeToPeak() {
        // Peak 0.25 (-12 dB) to -3 dB needs +9 dB.
        let g = AudioGain.apply(.normalize(targetDB: -3), to: 0, peak: 0.25)!
        #expect(abs(g - 9.0412) < 1e-3)
        // The result does not depend on the gain the clip already had: the peak is of the source.
        #expect(abs(AudioGain.apply(.normalize(targetDB: -3), to: 5, peak: 0.25)! - g) < 1e-9)
        // Silence cannot be normalised.
        #expect(AudioGain.apply(.normalize(targetDB: -3), to: 0, peak: 0) == nil)
        #expect(AudioGain.apply(.normalize(targetDB: -3), to: 0, peak: nil) == nil)
    }

    @Test func normalizeAllPeaksTogetherKeepsTheBalance() {
        // Peaks 0.5 and 0.25 together: the loudest clip reaches the target, the quiet one moves by the same amount.
        let gains = AudioGain.normalizeTogether(peaks: [0.5, 0.25], targetDB: 0)!
        #expect(abs(gains[0] - 6.0206) < 1e-3 && abs(gains[1] - 6.0206) < 1e-3)
        #expect(AudioGain.normalizeTogether(peaks: [0, 0], targetDB: 0) == nil)
        #expect(AudioGain.normalizeTogether(peaks: [], targetDB: 0) == nil)
    }
}

@Suite struct VolumeLineEditTests {
    @Test func dragWithoutKeysChangesTheWholeClip() {
        var c = audio()
        c.shiftVolumeLine(atLocal: s(3), byDB: -6.0206)
        #expect(abs(c.animation.volume.value - 0.5) < 1e-3)
        #expect(!c.animation.volume.isAnimated)
    }

    @Test func dragOfASegmentMovesBothKeys() {
        var c = audio()
        let a = c.addVolumeKey(atLocal: s(2)), b = c.addVolumeKey(atLocal: s(6))
        #expect(c.animation.volume.track.keys.count == 2)
        c.shiftVolumeLine(atLocal: s(4), byDB: 6.0206)
        let t = c.animation.volume.track
        #expect(abs(t.key(id: a)!.value - 2) < 1e-3 && abs(t.key(id: b)!.value - 2) < 1e-3)
    }

    @Test func dragBeforeFirstKeyMovesThatKeyOnly() {
        var c = audio()
        let a = c.addVolumeKey(atLocal: s(4)), b = c.addVolumeKey(atLocal: s(8))
        c.shiftVolumeLine(atLocal: s(1), byDB: -6.0206)
        #expect(abs(c.animation.volume.track.key(id: a)!.value - 0.5) < 1e-3)
        #expect(abs(c.animation.volume.track.key(id: b)!.value - 1) < 1e-9)
    }

    @Test func addedKeyTakesTheCurrentValueAndKeepsTheShape() {
        var c = audio()
        c.animation.volume = AnimatedProperty(0.5)
        let k = c.addVolumeKey(atLocal: s(5))
        // The first key makes the line animated: the old constant is preserved as a key at the same level.
        #expect(c.animation.volume.track.key(id: k)!.value == 0.5)
        #expect(c.volume(at: s(0)) == 0.5 && c.volume(at: s(9)) == 0.5)
        // A key in the middle of a ramp lies on the ramp.
        var r = audio()
        let a = r.addVolumeKey(atLocal: s(0)); let b = r.addVolumeKey(atLocal: s(10))
        r.animation.volume.track.set(a, value: 0); r.animation.volume.track.set(b, value: 1)
        let m = r.addVolumeKey(atLocal: s(5))
        #expect(abs(r.animation.volume.track.key(id: m)!.value - 0.5) < 1e-9)
    }

    @Test func movingAKeyChangesTimeAndLevelAndStaysInsideTheClip() {
        var c = audio()
        let k = c.addVolumeKey(atLocal: s(5))
        c.moveVolumeKey(k, toLocal: s(7), gainDB: 3)
        let key = c.animation.volume.track.key(id: k)!
        #expect(key.time == s(7) && abs(key.value - AudioGain.linear(fromDB: 3)) < 1e-9)
        c.moveVolumeKey(k, toLocal: s(99), gainDB: 3)
        #expect(c.animation.volume.track.key(id: k)!.time == s(10))
        c.moveVolumeKey(k, toLocal: s(-4), gainDB: -200)
        #expect(c.animation.volume.track.key(id: k)!.time == .zero)
        #expect(c.animation.volume.track.key(id: k)!.value == 0)        // below the floor = silence
    }

    @Test func removeKeyKeepsTheRest() {
        var c = audio()
        let a = c.addVolumeKey(atLocal: s(1)); _ = c.addVolumeKey(atLocal: s(2))
        c.removeVolumeKey(a)
        #expect(c.animation.volume.track.keys.count == 1)
    }
}
