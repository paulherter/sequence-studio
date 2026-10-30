import Foundation
import Testing
@testable import SQCore

@Test func kfBuiltInCurves() {
    #expect(EasingCurve.linear.interpolation == .linear)
    #expect(EasingCurve.hold.interpolation == .hold)
    #expect(EasingCurve.easeInOut.interpolation == .bezier)
    #expect(EasingCurve.easeInOut.outHandle.dy == 0 && EasingCurve.easeInOut.inHandle.dy == 0)
    #expect(EasingCurve.easeIn.inHandle.dy == 0 && EasingCurve.easeIn.outHandle.dy > 0)
    #expect(EasingCurve.easeOut.outHandle.dy == 0 && EasingCurve.easeOut.inHandle.dy > 0)
    #expect(EasingCurve.builtIns.map(\.name) == ["Steady", "Hold", "Ease-in-out 33%", "Ease-in 33%", "Ease-out 33%", "Fast start", "Fast end",
                                                   "Classic", "Ease-out 100%", "Ease-in 100%", "Soft landing"])
    // Soft landing: starts steeper than steady, ends flat, stays between 0 and 1 and reaches 1.
    let soft = EasingCurve.softLanding.previewSamples(count: 11)
    #expect(soft[5] > 0.5 && soft.last == 1 && soft.first == 0 && soft.allSatisfy { $0 >= 0 && $0 <= 1.0000001 })
    // fast start covers more than half the distance in the first half
    var a = kfKey(0, 0); EasingCurve.fastStart.apply(to: &a, side: .out)
    var b = kfKey(2, 10); EasingCurve.fastStart.apply(to: &b, side: .in)
    #expect(KeyframeTrack(keys: [a, b]).value(at: kfT(1))! > 6)
    var c = kfKey(0, 0); EasingCurve.fastEnd.apply(to: &c, side: .out)
    var d = kfKey(2, 10); EasingCurve.fastEnd.apply(to: &d, side: .in)
    #expect(KeyframeTrack(keys: [c, d]).value(at: kfT(1))! < 4)
}

@Test func kfLibraryUserPresets() throws {
    var lib = EasingLibrary()
    #expect(lib.all.count == 11)
    var k = kfKey(0, 0, .bezier); k.outHandle = EaseHandle(dx: 0.7, dy: 0.1); k.inHandle = EaseHandle(dx: 0.2, dy: 0.9)
    let id = lib.saveCurve(from: k, name: "Mine")
    #expect(lib.all.count == 12)
    let saved = try #require(lib.userCurves.first)
    #expect(saved.outHandle == k.outHandle && saved.inHandle == k.inHandle && saved.interpolation == .bezier)
    lib.rename(id, to: "Renamed")
    #expect(lib.userCurves[0].name == "Renamed")
    let back = try JSONDecoder().decode(EasingLibrary.self, from: JSONEncoder().encode(lib))
    #expect(back == lib)
    lib.remove(id)
    #expect(lib.userCurves.isEmpty)
    lib.remove(EasingCurve.linear.id) // built-ins cannot be removed
    #expect(lib.all.count == 11)
}

@Test func kfApplyToManyKeys() {
    let ks = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9)]
    var tr = KeyframeTrack(keys: ks)
    tr.apply(.easeInOut, to: [ks[0].id, ks[2].id])
    #expect(tr.keys[0].interpolation == .bezier && tr.keys[0].outHandle == EasingCurve.easeInOut.outHandle)
    #expect(tr.keys[2].inHandle == EasingCurve.easeInOut.inHandle)
    #expect(tr.keys[1] == ks[1])
}

@Test func kfApplyInOnlyAndOutOnly() {
    let ks = [kfKey(0, 0), kfKey(2, 5)]
    var tr = KeyframeTrack(keys: ks)
    tr.apply(.easeInOut, to: [ks[1].id], side: .in)
    #expect(tr.keys[1].inHandle == EasingCurve.easeInOut.inHandle)
    #expect(tr.keys[1].outHandle == ks[1].outHandle)
    #expect(tr.keys[1].interpolation == .linear)
    #expect(tr.keys[0] == ks[0]) // unselected left neighbor is untouched
    tr.apply(.easeInOut, to: [ks[0].id], side: .out)
    #expect(tr.keys[0].outHandle == EasingCurve.easeInOut.outHandle)
    #expect(tr.keys[0].inHandle == ks[0].inHandle)
}

@Test func kfToggleHold() {
    let ks = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9, .hold)]
    var tr = KeyframeTrack(keys: ks)
    let ids = Set(ks.map(\.id))
    tr.toggleHold(ids)            // mixed -> all hold
    #expect(tr.keys.allSatisfy { $0.interpolation == .hold })
    tr.toggleHold(ids)            // all hold -> linear
    #expect(tr.keys.allSatisfy { $0.interpolation == .linear })
}

@Test func kfEaseNeverTouchesUnselectedKeys() {
    let ks = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9), kfKey(6, 1)]
    for side in [EaseSide.in, .out, .both] {
        var tr = KeyframeTrack(keys: ks)
        tr.apply(.easeInOut, to: [ks[1].id], side: side)
        #expect(tr.keys[0] == ks[0] && tr.keys[2] == ks[2] && tr.keys[3] == ks[3])
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        for i in [0, 2, 3] { #expect(try! enc.encode(tr.keys[i]) == enc.encode(ks[i])) }
    }
}

@Test func kfLinearLeftKeyWithEasedRightInHandleEases() {
    // Left key stays .linear with linear out-handle; only the right key's in-handle is eased.
    let ks = [kfKey(0, 0), kfKey(2, 10)]
    var tr = KeyframeTrack(keys: ks)
    tr.apply(.easeInOut, to: [ks[1].id], side: .in)
    #expect(tr.keys[0].interpolation == .linear)
    let v = tr.value(at: Time(1, 2))!          // quarter of the segment: linear would be 2.5
    #expect(v > 2.5 - 1e-9 + 0.1)              // in-handle flattens the end, so the start catches up
    #expect(tr.value(at: kfT(1))! > 5)
    #expect(tr.value(at: kfT(0)) == 0 && tr.value(at: kfT(2)) == 10)
}

@Test func kfHoldOnLeftStillWinsOverRightInHandle() {
    var b = kfKey(2, 10); b.inHandle = EaseHandle(dx: 0.5, dy: 0)
    let tr = KeyframeTrack(keys: [kfKey(0, 3, .hold), b])
    #expect(tr.value(at: kfT(1)) == 3)
}

@Test func kfLinearHandlesStayExactlyLinear() {
    let tr = KeyframeTrack(keys: [kfKey(0, 0), kfKey(3, 9)])
    #expect(tr.value(at: kfT(1)) == 3)
}

private func kfBezierKey(_ s: Int64, _ v: Double) -> Keyframe<Double> {
    var k = kfKey(s, v, .bezier)
    k.outHandle = EaseHandle(dx: 0.7, dy: 0.1); k.inHandle = EaseHandle(dx: 0.2, dy: 0.9)
    return k
}

@Test func kfToggleHoldKeepsBezierHandlesOnTrack() {
    let ks = [kfBezierKey(0, 0), kfBezierKey(2, 5)]
    var tr = KeyframeTrack(keys: ks)
    let ids = Set(ks.map(\.id))
    tr.toggleHold(ids)
    #expect(tr.keys.allSatisfy { $0.interpolation == .hold })
    #expect(tr.keys.map(\.outHandle) == ks.map(\.outHandle) && tr.keys.map(\.inHandle) == ks.map(\.inHandle))
    tr.toggleHold(ids)
    #expect(tr.keys == ks)
}

@Test func kfToggleHoldKeepsBezierHandlesOnSummary() {
    let ks = [kfBezierKey(0, 0), kfBezierKey(2, 5)]
    let p = PropertyID("opacity")
    var s = KeyframeSummary(tracks: [p: .scalar(KeyframeTrack(keys: ks))])
    let sel = s.members(at: kfT(0))
    s.toggleHold(sel)
    guard case .scalar(let held) = s.tracks[p] else { return }
    #expect(held.keys[0].interpolation == .hold && held.keys[0].outHandle == ks[0].outHandle)
    s.toggleHold(sel)
    guard case .scalar(let back) = s.tracks[p] else { return }
    #expect(back.keys == ks)
}
