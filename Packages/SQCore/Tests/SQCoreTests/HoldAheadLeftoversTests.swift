import Foundation
import Testing
@testable import SQCore

/// Leftovers of Hold Ahead: pair rows settle each side of a key on its own, hue holds read exact key values, the hold
/// toggle gets the kind back from its caller, and Hold / Hold Ahead are two menu entries that convert into each other.
@Suite struct HoldAheadLeftoversTests {
    private func q(_ n: Int64) -> Time { Time(n, 4) }

    private func prop(_ keys: [Keyframe<Double>]) -> AnimatedProperty<Double> {
        AnimatedProperty(keys.first?.value ?? 0, track: KeyframeTrack(keys: keys))
    }

    private func samples(_ p: AnimatedProperty<Double>) -> [Double] { (0 ... 16).map { p.value(atLocal: q($0)) } }

    private func expectSameCurve(_ a: AnimatedProperty<Double>, _ b: AnimatedProperty<Double>, _ what: Comment) {
        for (u, v) in zip(samples(a), samples(b)) { #expect(abs(u - v) < 1e-9, what) }
    }

    // MARK: 1. Pair rows

    /// Y eases into a key and holds from it; X does not change at all. Aligning must not flatten Y's arrival.
    @Test func aFlatXKeepsYsEasedArrivalAndHold() {
        var y0 = kfKey(0, 0, .bezier); y0.outHandle = EaseHandle(dx: 0.6, dy: 0)
        var y1 = kfKey(2, 10, .hold); y1.inHandle = EaseHandle(dx: 0.7, dy: 1)
        for kind in [Interpolation.hold, .holdAhead] {
            y1.interpolation = kind
            var x = prop([kfKey(0, 5), kfKey(2, 5), kfKey(4, 5)]), y = prop([y0, y1, kfKey(4, 30)])
            let before = (x, y)
            #expect(abs(y.value(atLocal: q(4)) - 5) > 0.5, "the test needs a real ease")
            KeyframesPair.edit(&x, &y) { _ in }
            #expect(KeyframesPair.isAligned(x, y), "\(kind)")
            expectSameCurve(x, before.0, "x, \(kind)"); expectSameCurve(y, before.1, "y, \(kind)")
            #expect(y.track.keys[1].interpolation == kind)
        }
    }

    /// X sits still under a Hold (or Hold Ahead), Y ramps: Y must not become a step.
    @Test func aFlatHoldOnXDoesNotTurnYsRampIntoAStep() {
        for kind in [Interpolation.hold, .holdAhead] {
            var x = prop([kfKey(0, 5, kind), kfKey(2, 5)]), y = prop([kfKey(0, 0), kfKey(2, 10)])
            let before = (x, y)
            KeyframesPair.edit(&x, &y) { _ in }
            #expect(KeyframesPair.isAligned(x, y), "\(kind)")
            #expect(y.value(atLocal: q(4)) == 5, "\(kind)")
            expectSameCurve(x, before.0, "x, \(kind)"); expectSameCurve(y, before.1, "y, \(kind)")
        }
    }

    /// The sides are independent: X changes into the key and is flat after it, Y the other way round.
    @Test func eachSideOfAKeyFollowsTheMemberThatChangesThere() {
        var x0 = kfKey(0, 0, .bezier); x0.outHandle = EaseHandle(dx: 0.6, dy: 0)
        var x1 = kfKey(2, 10); x1.inHandle = EaseHandle(dx: 0.7, dy: 1)
        var x = prop([x0, x1, kfKey(4, 10)])
        var y = prop([kfKey(0, 3), kfKey(2, 3, .holdAhead), kfKey(4, 40)])
        let before = (x, y)
        KeyframesPair.edit(&x, &y) { _ in }
        #expect(KeyframesPair.isAligned(x, y))
        expectSameCurve(x, before.0, "x"); expectSameCurve(y, before.1, "y")
        #expect(x.track.keys[1].interpolation == .holdAhead && y.track.keys[1].inHandle == x1.inHandle)
    }

    /// Both change over the same stretch with different shapes: as before, Y takes X's.
    @Test func whereBothChangeYStillTakesXsShape() {
        var x0 = kfKey(0, 0, .bezier); x0.outHandle = EaseHandle(dx: 0.6, dy: 0)
        var x = prop([x0, kfKey(2, 10)]), y = prop([kfKey(0, 0, .holdAhead), kfKey(2, 20)])
        let x00 = x
        KeyframesPair.edit(&x, &y) { _ in }
        #expect(KeyframesPair.isAligned(x, y) && x == x00)
        #expect(y.track.keys[0].interpolation == .bezier && y.track.keys[0].outHandle == x0.outHandle)
    }

    /// Aligning twice gives what aligning once gave, and it never changes a member's curve (the pair row's "Y takes X's"
    /// where both change happens in the edit, not here). X is flat up to 1 s, Y eases over a key X has not.
    @Test func aligningIsIdempotentAndKeepsBothCurves() {
        var y0 = kfKey(0, 0, .bezier); y0.outHandle = EaseHandle(dx: 0.5, dy: 0)
        var y2 = kfKey(2, 9); y2.inHandle = EaseHandle(dx: 0.5, dy: 1)
        var x2 = kfKey(2, 5); x2.inHandle = EaseHandle(dx: 0.5, dy: 1)
        var hold = kfKey(0, 0, .hold); hold.outHandle = EaseHandle(dx: 0.4, dy: 0)
        var held = kfKey(2, 10); held.inHandle = EaseHandle(dx: 0.3, dy: 1)
        let cases: [(AnimatedProperty<Double>, AnimatedProperty<Double>)] = [
            (prop([kfKey(0, 1), kfKey(1, 1), x2]), prop([y0, y2])),
            (prop([y0, y2]), prop([kfKey(0, 1), kfKey(1, 1), x2])),
            (prop([hold, held]), prop([kfKey(0, 0), kfKey(2, 4)])),
            (prop([kfKey(0, 0), kfKey(4, 40)]), prop([kfKey(0, 5), kfKey(2, 7, .holdAhead), kfKey(4, 9)])),
        ]
        for (i, (x, y)) in cases.enumerated() {
            let once = KeyframesPair.aligning(x, y)
            let twice = KeyframesPair.aligning(once.x, once.y)
            #expect(twice.x == once.x && twice.y == once.y, "case \(i)")
            expectSameCurve(once.x, x, "x, case \(i)"); expectSameCurve(once.y, y, "y, case \(i)")
        }
    }

    /// A Hold before a key makes the key's in-handle irrelevant to the curve, but it is what un-holding brings back:
    /// a pair edit must not overwrite it with the partner's.
    @Test func aPairEditKeepsTheInHandleBehindAHold() {
        let h = EaseHandle(dx: 0.3, dy: 1)
        var held = kfKey(2, 10); held.inHandle = h
        for out in [EaseHandle.linear, EaseHandle(dx: 0.4, dy: 0)] {
            var start = kfKey(0, 0, .hold); start.outHandle = out
            var x = prop([start, held]), y = prop([kfKey(0, 0), kfKey(2, 4)])
            KeyframesPair.edit(&x, &y) { _ in }
            #expect(x.track.keys[1].inHandle == h, "\(out)")
            x.track.setHold([start.id], false)
            #expect(x.track.keys[0].interpolation == .bezier, "\(out)")
        }
    }

    // MARK: 2. Hue

    @Test func aHeldHueReadsTheKeyValueItself() {
        typealias H = HueKeyframeTests
        let far = H.prop([(0, 400), (2, 100)], .hold)
        #expect(far.hueValue(atLocal: H.s(0)) == 400 && far.hueValue(atLocal: H.s(1)) == 400)   // no jump after the key
        let ahead = H.prop([(0, 350), (2, 0)], .holdAhead)
        #expect(ahead.hueValue(atLocal: H.s(1)) == 0)                                           // not 360
        #expect(ahead.hueValue(atLocal: H.s(0)) == 350)
        let odd = 0.1 + 0.2
        let exact = H.prop([(0, 359.9), (2, odd), (4, 720.25)], .holdAhead)
        #expect(exact.hueValue(atLocal: H.s(1)) == odd && exact.hueValue(atLocal: H.s(3)) == 720.25)
        let back = H.prop([(0, 10), (2, 350)], .hold)
        #expect(back.hueValue(atLocal: H.s(1.999)) == 10)
    }

    @Test func aRampBesideHeldHueKeysStillTakesTheShortWay() {
        typealias H = HueKeyframeTests
        for kind in [Interpolation.hold, .holdAhead] {
            var p = AnimatedProperty(350.0)
            p.track.insert(Keyframe(time: H.s(0), value: 350, interpolation: kind))
            p.track.insert(Keyframe(time: H.s(2), value: 350))
            p.track.insert(Keyframe(time: H.s(4), value: 10, interpolation: kind))
            p.track.insert(Keyframe(time: H.s(6), value: 200))
            #expect(p.hueValue(atLocal: H.s(1)) == 350, "\(kind)")
            #expect(H.sameHue(p.hueValue(atLocal: H.s(3)), 0), "\(kind)")
            #expect(H.sameHue(p.hueValue(atLocal: H.s(2.5)), 355), "\(kind)")
            #expect(p.hueValue(atLocal: H.s(5)) == (kind == .hold ? 10 : 200), "\(kind)")
        }
    }

    // MARK: 3. Hold off and on again

    @Test func setHoldGetsTheKindBackFromItsCaller() {
        let ks = [kfKey(0, 0, .holdAhead), kfKey(2, 10, .hold), kfKey(4, 20)]
        let ids = Set(ks.map(\.id))
        let kinds = Dictionary(uniqueKeysWithValues: ks.dropLast().map { ($0.id, $0.interpolation) })
        var t = KeyframeTrack(keys: ks)
        t.setHold(ids, false)
        #expect(t.keys.allSatisfy { !$0.interpolation.isHold })
        var plain = t
        t.setHold(ids, true, restoring: kinds)
        #expect(t.keys.map(\.interpolation) == [.holdAhead, .hold, .hold])
        plain.setHold(ids, true)
        #expect(plain.keys.map(\.interpolation) == [.hold, .hold, .hold])                       // nobody remembers: Hold
        // A key that is a hold already keeps its kind, whatever the caller remembers.
        var held = KeyframeTrack(keys: ks)
        held.setHold(ids, true, restoring: [ks[0].id: .hold, ks[1].id: .holdAhead])
        #expect(held.keys.map(\.interpolation) == [.holdAhead, .hold, .hold])
        // Only the two hold kinds are restored.
        var odd = KeyframeTrack(keys: [kfKey(0, 0), kfKey(2, 1)])
        odd.setHold(Set(odd.keys.map(\.id)), true, restoring: [odd.keys[0].id: .bezier])
        #expect(odd.keys[0].interpolation == .hold)
    }

    @Test func toggleHoldRestoresAcrossTheSummary() {
        let a = [kfKey(0, 0, .holdAhead), kfKey(2, 10)], b = [kfKey(0, 1, .hold), kfKey(2, 3)]
        let pa = PropertyID("a"), pb = PropertyID("b")
        var s = KeyframeSummary(tracks: [pa: .scalar(KeyframeTrack(keys: a)), pb: .scalar(KeyframeTrack(keys: b))])
        let sel: Set<SummaryMember> = [SummaryMember(property: pa, keyID: a[0].id), SummaryMember(property: pb, keyID: b[0].id)]
        let kinds = Dictionary(uniqueKeysWithValues: sel.compactMap { m in s.interpolation(of: m).map { (m.keyID, $0) } })
        #expect(kinds == [a[0].id: .holdAhead, b[0].id: .hold])
        s.toggleHold(sel)
        #expect(sel.allSatisfy { s.interpolation(of: $0) == .linear })
        s.toggleHold(sel, restoring: kinds)
        #expect(s.interpolation(of: SummaryMember(property: pa, keyID: a[0].id)) == .holdAhead)
        #expect(s.interpolation(of: SummaryMember(property: pb, keyID: b[0].id)) == .hold)
        var t = KeyframeTrack(keys: a)
        t.toggleHold([a[0].id]); t.toggleHold([a[0].id], restoring: [a[0].id: .holdAhead])
        #expect(t.keys[0].interpolation == .holdAhead)
    }

    // MARK: 4. Two menu entries

    @Test func holdAndHoldAheadAreTwoEntriesThatConvertIntoEachOther() {
        let all = KeyInterpolationChoice.allCases
        #expect(all.firstIndex(of: .holdAhead) == all.firstIndex(of: .hold).map { $0 + 1 })     // directly under Hold
        #expect(KeyInterpolationChoice.holdAhead.title == "Hold Ahead" && KeyInterpolationChoice.holdAhead.fullTitle == "Hold Ahead")
        #expect(KeyInterpolationChoice.hold.holdKind == .hold && KeyInterpolationChoice.holdAhead.holdKind == .holdAhead)
        #expect(all.filter { $0.holdKind != nil } == [.hold, .holdAhead])

        var k0 = kfKey(0, 0, .bezier); k0.outHandle = EaseHandle(dx: 0.6, dy: 0)
        let ks = [k0, kfKey(2, 10), kfKey(4, 20)]
        var tr = PropertyTrack.scalar(KeyframeTrack(keys: ks))
        tr.apply(.holdAhead, to: [ks[0].id])
        guard case .scalar(let ahead) = tr else { return }
        #expect(ahead.keys[0].interpolation == .holdAhead && ahead.keys[0].outHandle == k0.outHandle)   // handles stay stored
        #expect(ahead.value(at: kfT(1)) == 10 && ahead.value(at: kfT(0)) == 0)
        #expect(ahead.keys[1] == ks[1] && ahead.keys[2] == ks[2])
        tr.apply(.hold, to: [ks[0].id])
        guard case .scalar(let held) = tr else { return }
        #expect(held.keys[0].interpolation == .hold && held.value(at: kfT(1)) == 0)
        tr.apply(.holdAhead, to: [ks[0].id])
        #expect(tr.interpolation(of: ks[0].id) == .holdAhead)
        // A curve still leaves a Hold Ahead what it is (only the explicit entry converts).
        tr.apply(EasingCurve.hold, to: [ks[0].id], side: .out)
        #expect(tr.interpolation(of: ks[0].id) == .holdAhead)
    }

    @Test func setHoldKindIgnoresOtherKinds() {
        let ks = [kfKey(0, 0, .holdAhead), kfKey(2, 10)]
        var t = KeyframeTrack(keys: ks)
        t.setHoldKind(.linear, [ks[0].id]); t.setHoldKind(.bezier, [ks[0].id])
        #expect(t.keys[0].interpolation == .holdAhead)
        t.setHoldKind(.hold, [ks[0].id])
        #expect(t.keys.map(\.interpolation) == [.hold, .linear])
    }

    @Test func aSegmentSelectionSetsTheKindOnItsLeftKeyOnly() {
        let ks = [kfKey(0, 0), kfKey(2, 10, .hold), kfKey(4, 20)]
        let p = PropertyID("opacity")
        var s = KeyframeSummary(tracks: [p: .scalar(KeyframeTrack(keys: ks))])
        func kinds() -> [Interpolation] { ks.map { s.interpolation(of: SummaryMember(property: p, keyID: $0.id))! } }
        let pair = EaseSelection(summary: s, members: [SummaryMember(property: p, keyID: ks[1].id), SummaryMember(property: p, keyID: ks[2].id)])
        #expect(pair.setHoldKind(.holdAhead, in: &s) == 1)
        #expect(kinds() == [.linear, .holdAhead, .linear])
        #expect(pair.reading(in: s) == .common(.hold))                                         // a shape reads both as Hold
        #expect(pair.setHoldKind(.hold, in: &s) == 1 && kinds() == [.linear, .hold, .linear])
        #expect(pair.setHoldKind(.bezier, in: &s) == 0)
        // The last key alone names its incoming segment: a hold has no in side, nothing is written.
        var open = KeyframeSummary(tracks: [p: .scalar(KeyframeTrack(keys: [kfKey(0, 0), kfKey(2, 10)]))])
        let lastID = open.tracks[p]!.keyIDs[1]
        let last = EaseSelection(summary: open, members: [SummaryMember(property: p, keyID: lastID)])
        #expect(last.setHoldKind(.holdAhead, in: &open) == 0)
        #expect(open.tracks[p]!.keyIDs.allSatisfy { open.tracks[p]!.interpolation(of: $0) == .linear })
    }
}

/// A held hue outside 0...360 (imported key) renders as the same color, not clamped to the range end.
@Suite struct HeldHueRenderTests {
    @Test func heldOutOfRangeKeyHueWrapsInsteadOfClamping() {
        var e = ClipEffect(kind: ClipEffect.ultraKeyKind)
        for (v, want) in [(370.0, 10.0), (-30.0, 330.0), (360.0, 360.0), (120.0, 120.0)] {
            let k0 = kfKey(0, v, .holdAhead), k1 = kfKey(2, 200)
            e.parameters[ClipEffect.keyHueKey] = AnimatedProperty(v, track: KeyframeTrack(keys: [k0, k1]))
            #expect(abs(e.scalar(ClipEffect.keyHueKey, atLocal: Time(1, 1)) - 200) < 1e-9, "ahead \(v)")
            #expect(abs(e.scalar(ClipEffect.keyHueKey, atLocal: Time(0, 4)) - want) < 1e-9, "\(v)")
        }
    }
}
