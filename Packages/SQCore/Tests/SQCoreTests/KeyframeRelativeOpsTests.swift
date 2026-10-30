import Foundation
import Testing
@testable import SQCore

@Test func kfScaleAboutPivot() {
    let ks = [kfKey(0, 10), kfKey(1, 20), kfKey(2, 40)]
    var tr = KeyframeTrack(keys: ks)
    let ok = tr.scaleValues([ks[1].id, ks[2].id], by: 2, about: 10)
    let none = tr.scaleValues([UUID()], by: 2, about: 0)
    #expect(ok && !none)
    #expect(tr.keys.map(\.value) == [10, 30, 70])
}

@Test func kfScaleAboutMeanKeepsCenter() {
    let ks = [kfKey(0, 10), kfKey(1, 30)]
    var tr = KeyframeTrack(keys: ks)
    tr.scaleValuesAboutMean(Set(ks.map(\.id)), by: 0.5)
    #expect(tr.keys.map(\.value) == [15, 25])
}

@Test func kfDuplicateWithOffsetKeepsEasingAndNewIDs() {
    var a = kfKey(1, 5, .bezier); a.outHandle = EaseHandle(dx: 0.4, dy: 0.1)
    let b = kfKey(2, 7)
    var tr = KeyframeTrack(keys: [a, b])
    let copies = tr.duplicateKeys([a.id], offset: kfT(10))
    #expect(copies.count == 1 && !copies.contains(a.id))
    #expect(tr.keys.map(\.time) == [kfT(1), kfT(2), kfT(11)])
    #expect(tr.keys.last?.outHandle == EaseHandle(dx: 0.4, dy: 0.1) && tr.keys.last?.interpolation == .bezier)
}

@Test func kfDuplicateReplacesKeyAtTarget() {
    let a = kfKey(0, 1), b = kfKey(5, 9)
    var p = PropertyTrack.scalar(KeyframeTrack(keys: [a, b]))
    p.duplicateKeys([a.id], offset: kfT(5))
    guard case .scalar(let t) = p else { return }
    #expect(t.keys.count == 2 && t.keys.last?.value == 1)
}

@Test func kfClipboardCrossClipRangeClipsAndKeepsSource() {
    let src = kfKey(2, 4), src2 = kfKey(6, 8)
    let id = PropertyID("opacity")
    let from: [PropertyID: PropertyTrack] = [id: .scalar(KeyframeTrack(keys: [src, src2]))]
    let clip = KeyframeClipboard.copy(from: from, selection: [id: [src.id, src2.id]])!
    var other: [PropertyID: PropertyTrack] = [:]
    // second clip is 5 s long: key at relative +4 lands at 5 + ... dropped when past the range
    let pasted = clip.paste(into: &other, at: kfT(3), within: kfT(0)...kfT(5))
    #expect(pasted)
    guard case .scalar(let t)? = other[id] else { Issue.record("missing"); return }
    #expect(t.keys.map(\.time) == [kfT(3)] && t.keys[0].value == 4)
    #expect(from[id] == .scalar(KeyframeTrack(keys: [src, src2])))
}
