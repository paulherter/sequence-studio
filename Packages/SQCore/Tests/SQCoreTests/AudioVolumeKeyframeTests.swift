import Foundation
import Testing
@testable import SQCore

private func vclip() -> Clip {
    Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
}

@Suite struct AudioVolumeKeyframeTests {
    @Test func relativeMultiKeyEditMovesAllSelectedVolumeKeys() {
        var c = vclip()
        let a = c.addVolumeKey(atLocal: Time(1, 1)), b = c.addVolumeKey(atLocal: Time(4, 1))
        c.animation.volume.track.set(a, value: 0.5); c.animation.volume.track.set(b, value: 0.25)
        let ok = c.animation.volume.track.setValue(0.6, at: Time(1, 1), selected: [a, b])
        #expect(ok)
        let t = c.animation.volume.track
        #expect(abs(t.key(id: a)!.value - 0.6) < 1e-9 && abs(t.key(id: b)!.value - 0.35) < 1e-9)
    }

    @Test func easeAndHoldApplyToVolumeKeys() {
        var c = vclip()
        let a = c.addVolumeKey(atLocal: Time(1, 1)), b = c.addVolumeKey(atLocal: Time(4, 1))
        c.animation.volume.track.apply(.easeInOut, to: [a, b])
        #expect(c.animation.volume.track.keys.allSatisfy { $0.interpolation != .linear })
        c.animation.volume.track.toggleHold([a, b])
        #expect(c.animation.volume.track.keys.allSatisfy { $0.interpolation.isHold })
    }

    @Test func movedVolumeKeyKeepsOrderAndGainCap() {
        var c = vclip()
        let a = c.addVolumeKey(atLocal: Time(1, 1)), b = c.addVolumeKey(atLocal: Time(4, 1))
        c.moveVolumeKey(a, toLocal: Time(8, 1), gainDB: 40)
        let t = c.animation.volume.track
        #expect(t.keys.map(\.id) == [a, b] && t.key(id: a)!.time < t.key(id: b)!.time)
        #expect(abs(AudioGain.db(fromLinear: t.key(id: a)!.value) - AudioGain.maxVolumeDB) < 1e-6)
    }

    @Test func duplicatedVolumeKeysKeepGain() {
        var c = vclip()
        let a = c.addVolumeKey(atLocal: Time(1, 1))
        c.animation.volume.track.set(a, value: 0.5)
        let copies = c.animation.volume.track.duplicateKeys([a], offset: Time(3, 1))
        #expect(copies.count == 1 && c.animation.volume.track.keys.count == 2)
        #expect(c.animation.volume.track.keys.last?.value == 0.5)
    }
}
