import Foundation
import Testing
@testable import SSCore

@Test func kfBuiltInCurves() {
    #expect(EasingCurve.linear.interpolation == .linear)
    #expect(EasingCurve.hold.interpolation == .hold)
    #expect(EasingCurve.easeInOut.interpolation == .bezier)
    #expect(EasingCurve.easeInOut.outHandle.dy == 0 && EasingCurve.easeInOut.inHandle.dy == 0)
    #expect(EasingCurve.easeIn.inHandle.dy == 0 && EasingCurve.easeIn.outHandle.dy > 0)
    #expect(EasingCurve.easeOut.outHandle.dy == 0 && EasingCurve.easeOut.inHandle.dy > 0)
    #expect(EasingCurve.builtIns.map(\.name) == ["Linear", "Hold", "Ease in/out", "Ease in", "Ease out", "Fast start", "Fast end"])
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
    #expect(lib.all.count == 7)
    var k = kfKey(0, 0, .bezier); k.outHandle = EaseHandle(dx: 0.7, dy: 0.1); k.inHandle = EaseHandle(dx: 0.2, dy: 0.9)
    let id = lib.saveCurve(from: k, name: "Mine")
    #expect(lib.all.count == 8)
    let saved = try #require(lib.userCurves.first)
    #expect(saved.outHandle == k.outHandle && saved.inHandle == k.inHandle && saved.interpolation == .bezier)
    lib.rename(id, to: "Renamed")
    #expect(lib.userCurves[0].name == "Renamed")
    let back = try JSONDecoder().decode(EasingLibrary.self, from: JSONEncoder().encode(lib))
    #expect(back == lib)
    lib.remove(id)
    #expect(lib.userCurves.isEmpty)
    lib.remove(EasingCurve.linear.id) // built-ins cannot be removed
    #expect(lib.all.count == 7)
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
    #expect(tr.keys[0].interpolation == .bezier) // left segment must be bezier for the in-handle to matter
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
