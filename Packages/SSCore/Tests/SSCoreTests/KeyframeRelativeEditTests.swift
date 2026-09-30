import Foundation
import Testing
@testable import SSCore

@Test func kfRelativeEditShiftsAllSelectedBySameDelta() {
    let ks = [kfKey(0, 10), kfKey(2, 20), kfKey(4, 30)]
    var tr = KeyframeTrack(keys: ks)
    let r4 = tr.setValue(15, at: kfT(0), selected: [ks[0].id, ks[1].id])
    #expect(r4)
    #expect(tr.keys.map(\.value) == [15, 25, 30])
}

@Test func kfRelativeEditBetweenKeysUsesInterpolatedReference() {
    let ks = [kfKey(0, 10), kfKey(2, 20)]
    var tr = KeyframeTrack(keys: ks)
    let r9 = tr.setValue(20, at: kfT(1), selected: [ks[0].id, ks[1].id]) // shown 15, now 20: +5
    #expect(r9)
    #expect(tr.keys.map(\.value) == [15, 25])
}

@Test func kfRelativeEditNoSelectionChangesNothing() {
    let ks = [kfKey(0, 10), kfKey(2, 20)]
    var tr = KeyframeTrack(keys: ks)
    let r5 = tr.setValue(99, at: kfT(0), selected: [])
    #expect(!r5)
    let r6 = tr.setValue(99, at: kfT(0), selected: [UUID()])
    #expect(!r6)
    #expect(tr.keys == ks)
}

@Test func kfRelativeEditVec2LeavesTangentsAlone() {
    let a = Keyframe(time: kfT(0), value: Vec2(0, 0), outTangent: Vec2(0, 50))
    let b = Keyframe(time: kfT(2), value: Vec2(10, 10))
    var tr = KeyframeTrack(keys: [a, b])
    let r7 = tr.setValue(Vec2(0, 5), at: kfT(0), selected: [a.id, b.id])
    #expect(r7)
    #expect(tr.keys[0].value == Vec2(0, 5) && tr.keys[1].value == Vec2(10, 15))
    #expect(tr.keys[0].outTangent == Vec2(0, 50))
}

@Test func kfRelativeEditAffectsOnlyGivenTrackInMap() {
    let o = kfKey(0, 1), p = kfKey(0, 5)
    var tracks: [PropertyID: PropertyTrack] = [PropertyID("opacity"): .scalar(KeyframeTrack(keys: [o])),
                                               PropertyID("rotation"): .scalar(KeyframeTrack(keys: [p]))]
    let changed = tracks[PropertyID("opacity")]!.setScalar(3, at: kfT(0), selected: [o.id])
    #expect(changed)
    #expect(tracks[PropertyID("opacity")] == .scalar(KeyframeTrack(keys: [Keyframe(id: o.id, time: kfT(0), value: 3)])))
    #expect(tracks[PropertyID("rotation")] == .scalar(KeyframeTrack(keys: [p])))
}
