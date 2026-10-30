import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let pid = PropertyID("pair")

/// Hold Ahead through an X/Y pair row, a preset combined with a clip's own keys, and Auto Duck.
@Suite struct HoldAheadPairPresetDuckingTests {
    private let l = UUID(), n = UUID(), m = UUID()

    /// Leader (2 s, Hold Ahead), next key (6 s), last key (8 s).
    private func ahead() -> AnimatedProperty<Double> {
        AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(id: l, time: s(2), value: 0.8, interpolation: .holdAhead),
            Keyframe(id: n, time: s(6), value: 0.2),
            Keyframe(id: m, time: s(8), value: 0.5),
        ]))
    }

    /// The same key times with `shape` on the first key.
    private func member(_ shape: Interpolation, _ a: Double = 10, _ b: Double = 30, _ c: Double = 50) -> AnimatedProperty<Double> {
        AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(2), value: a, interpolation: shape), Keyframe(time: s(6), value: b), Keyframe(time: s(8), value: c),
        ]))
    }

    private func expectSame(_ a: AnimatedProperty<Double>, _ b: AnimatedProperty<Double>, _ name: String) {
        for i in 0...300 {
            let t = Time(Int64(i), 30)
            #expect(abs(a.value(atLocal: t) - b.value(atLocal: t)) < 1e-9, "\(name), frame \(i)")
        }
    }

    // MARK: Pair rows

    /// A reverse turns the Holds of both members into Hold Aheads: one Vec2 key says it for both.
    @Test func aHoldAheadOfBothMembersIsOneVec2Key() {
        var x = ahead(), y = member(.holdAhead)
        #expect(KeyframesPair.isAligned(x, y))
        let v = KeyframesPair.zipped(x, y)
        #expect(v?.track.keys.map(\.interpolation) == [.holdAhead, .linear, .linear])
        #expect(v?.value(atLocal: s(2)) == Vec2(0.8, 10) && v?.value(atLocal: s(3)) == Vec2(0.2, 30))
        let x0 = x, y0 = y
        KeyframesPair.edit(&x, &y) { _ in }
        #expect(x == x0 && y == y0)
        KeyframesPair.edit(&x, &y) { $0.track.update(n) { $0.value = Vec2(0.3, 4) } }
        #expect(x.value(atLocal: s(3)) == 0.3 && y.value(atLocal: s(3)) == 4 && y.value(atLocal: s(2)) == 10)
        KeyframesPair.edit(&x, &y) { $0.track.move(l, to: s(3)) }
        #expect(x.track.keys.map(\.time) == [s(3), s(6), s(8)] && y.track.keys.map(\.time) == [s(3), s(6), s(8)])
        #expect(x.value(atLocal: s(4)) == 0.3 && y.value(atLocal: s(4)) == 4)
    }

    /// One member steps ahead, the other does not change over the span: both curves stay, whichever member it is.
    @Test func aHoldAheadBesideAFlatPartnerKeepsBothCurves() {
        for flat in [Interpolation.hold, .linear, .holdAhead] {
            var x = ahead(), y = member(flat, 10, 10, 50)
            let x0 = x, y0 = y
            KeyframesPair.edit(&x, &y) { _ in }
            #expect(KeyframesPair.isAligned(x, y), "\(flat)")
            expectSame(x, x0, "x, flat y \(flat)"); expectSame(y, y0, "y, flat \(flat)")
            // The other way around: X is the flat one and takes Y's kind.
            var fx = member(flat, 10, 10, 50), ay = ahead()
            KeyframesPair.edit(&fx, &ay) { _ in }
            #expect(KeyframesPair.isAligned(fx, ay), "\(flat), swapped")
            expectSame(fx, y0, "flat x \(flat)"); expectSame(ay, x0, "y, flat x \(flat)")
        }
    }

    /// The one mix a Vec2 key cannot say: a Hold Ahead and a Hold on one time with both members changing. As with any
    /// other shape the members disagree on, Y takes X's on the first edit through the row.
    @Test func aHoldAgainstAHoldAheadOnOneTimeFollowsX() {
        var x = ahead(), y = member(.hold)
        #expect(!KeyframesPair.isAligned(x, y) && KeyframesPair.zipped(x, y) == nil)
        KeyframesPair.edit(&x, &y) { _ in }
        #expect(KeyframesPair.isAligned(x, y) && x == ahead())
        #expect(y.track.keys[0].interpolation == .holdAhead && y.value(atLocal: s(2)) == 10 && y.value(atLocal: s(3)) == 30)
    }

    /// Open point of "Item lanes rest 7": an unaligned pair with the Hold Ahead on a time only Y has a key on.
    @Test func aHoldAheadOnAYOnlyTimeStaysWithY() {
        let yKeys = [Keyframe(time: s(1), value: 5.0), Keyframe(id: l, time: s(3), value: 0.8, interpolation: .holdAhead),
                     Keyframe(time: s(6), value: 0.2), Keyframe(time: s(8), value: 0.5)]
        // X does not change there (before its first key, on equal neighbors, unanimated): both curves stay.
        let flats: [(String, AnimatedProperty<Double>)] = [
            ("unanimated", AnimatedProperty(7.0)),
            ("after its last key", AnimatedProperty(0.0, track: KeyframeTrack(keys: [Keyframe(time: s(1), value: 7.0)]))),
            ("equal neighbors", AnimatedProperty(0.0, track: KeyframeTrack(keys: [
                Keyframe(time: s(1), value: 7.0), Keyframe(time: s(6), value: 7.0), Keyframe(time: s(8), value: 9.0)]))),
        ]
        for (name, x0) in flats {
            let y0 = AnimatedProperty(0.0, track: KeyframeTrack(keys: yKeys))
            var x = x0, y = y0
            #expect(!KeyframesPair.isAligned(x, y), "\(name)")
            KeyframesPair.edit(&x, &y) { _ in }
            #expect(KeyframesPair.isAligned(x, y), "\(name)")
            #expect(x.track.keys.first { $0.time == s(3) }?.interpolation == .holdAhead, "\(name)")
            expectSame(x, x0, "x, \(name)"); expectSame(y, y0, "y, \(name)")
        }
        // X moves across that time on a line: its curve stays as well (the new key of X is linear), so the members
        // disagree on the shape there and the row writes X's shape into Y, as it does for every other shape.
        let ramp = AnimatedProperty(0.0, track: KeyframeTrack(keys: [Keyframe(time: s(1), value: 0.0), Keyframe(time: s(8), value: 70.0)]))
        let aligned = KeyframesPair.aligning(ramp, AnimatedProperty(0.0, track: KeyframeTrack(keys: yKeys)))
        expectSame(aligned.x, ramp, "ramp x"); expectSame(aligned.y, AnimatedProperty(0.0, track: KeyframeTrack(keys: yKeys)), "ramp y")
        #expect(!KeyframesPair.isAligned(aligned.x, aligned.y))
    }

    @Test func aPasteThroughAPairRowKeepsTheHoldAheadOfBoth() throws {
        var x = ahead(), y = member(.holdAhead)
        let source = KeyframesPair.editable(x, y)
        let cb = try #require(KeyframeClipboard.copy(from: [pid: .vector(source.track)], selection: [pid: [l]]))
        #expect(cb.pastePair(pid, x: &x, y: &y, at: s(4)))
        #expect(KeyframesPair.isAligned(x, y))
        #expect(x.track.keys.map(\.time) == [s(2), s(4), s(6), s(8)] && y.track.keys.count == 4)
        #expect(x.track.keys.map(\.interpolation) == [.holdAhead, .holdAhead, .linear, .linear])
        // The pasted copy of (0.8, 10) is the next key of the first one; it steps on to the old next key.
        #expect(x.value(atLocal: s(3)) == 0.8 && x.value(atLocal: s(4)) == 0.8 && x.value(atLocal: s(5)) == 0.2)
        #expect(y.value(atLocal: s(3)) == 10 && y.value(atLocal: s(5)) == 30)
        #expect(Set(x.track.keys.map(\.id)).isDisjoint(with: y.track.keys.map(\.id)))   // members never share key ids
        // A scalar clipboard is no pair paste.
        let scalar = try #require(KeyframeClipboard.copy(from: [pid: .scalar(ahead().track)], selection: [pid: [l]]))
        var px = ahead(), py = member(.holdAhead)
        #expect(!scalar.pastePair(pid, x: &px, y: &py, at: s(4)))
        #expect(px == ahead() && py.track.keys.count == 3)
    }

    /// Open point of "Item lanes rest 7": a key copied from a pair row and pasted onto a plain Vec2 row. One Vec2 key
    /// carries the shape, so it is what it was.
    @Test func aPairRowCopyOntoAPlainVec2RowIsAHoldAhead() throws {
        let source = KeyframesPair.editable(ahead(), member(.holdAhead))
        let cb = try #require(KeyframeClipboard.copy(from: [pid: .vector(source.track)], selection: [pid: [l, n]]))
        let position = PropertyID("position")
        let board = try #require(cb.retargeted(to: position, isVector: true))
        var target: [PropertyID: PropertyTrack] = [position: .vector(KeyframeTrack(keys: [Keyframe(time: s(9), value: Vec2(1, 1))]))]
        #expect(board.paste(into: &target, at: s(1)))
        guard case .vector(let t)? = target[position] else { Issue.record("no track"); return }
        #expect(t.keys.map(\.time) == [s(1), s(5), s(9)] && t.keys[0].interpolation == .holdAhead)
        #expect(t.value(at: s(1)) == Vec2(0.8, 10) && t.value(at: s(3)) == Vec2(0.2, 30))
    }

    @Test func anOptionDragCopyInAPairRowIsAHoldAheadInBothMembers() {
        var x = ahead(), y = member(.holdAhead)
        KeyframesPair.edit(&x, &y) { v in
            var sum = KeyframeSummary(tracks: [pid: .vector(v.track)])
            sum.moveDuplicating([SummaryMember(property: pid, keyID: l)], by: s(-1), frame: Time(1, 30))
            if case .vector(let t)? = sum.tracks[pid] { v.track = t }
        }
        #expect(x.track.keys.map(\.time) == [s(1), s(2), s(6), s(8)] && KeyframesPair.isAligned(x, y))
        #expect(x.value(atLocal: s(2)) == 0.8 && x.value(atLocal: s(3)) == 0.2)
        #expect(y.value(atLocal: s(2)) == 10 && y.value(atLocal: s(3)) == 30)
    }

    // MARK: Presets

    private func clip() -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        c.animation.opacity.track = ahead().track
        return c
    }

    private func preset(_ keys: [Keyframe<Double>]) -> EffectPreset {
        EffectPreset(anchor: .stretch, referenceDuration: s(10), opacity: AnimatedProperty(1.0, track: KeyframeTrack(keys: keys)))
    }

    @Test func aPresetKeyOnTheLeadersTimeKeepsTheStep() {
        for shape in [Interpolation.hold, .linear, .holdAhead] {
            var c = clip()
            c.applyPreset(preset([Keyframe(time: s(2), value: 1, interpolation: shape), Keyframe(time: s(9), value: 1)]), mode: .relative)
            let t = c.animation.opacity.track
            #expect(t.keys.map(\.time) == [s(2), s(6), s(8), s(9)], "\(shape)")
            // The step is the clip's: its own value on the leader's time, the next key's right after it.
            #expect(t.keys[0].interpolation == .holdAhead, "\(shape)")
            #expect(t.value(at: s(2)) == t.keys[0].value && t.value(at: s(3)) == t.keys[1].value && t.keys[0].value != t.keys[1].value, "\(shape)")
        }
        // A plain Hold of the clip stays a Hold under a linear preset key.
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        c.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: s(2), value: 0.8, interpolation: .hold), Keyframe(time: s(6), value: 0.2)])
        c.applyPreset(preset([Keyframe(time: s(2), value: 1), Keyframe(time: s(9), value: 1)]), mode: .relative)
        let t = c.animation.opacity.track
        #expect(t.keys.count == 3 && t.keys[0].interpolation == .hold && t.value(at: s(4)) == t.keys[0].value)
    }

    /// Open point of "Item lanes rest 7": a linear preset key inside the span. It is a key of the combined track and
    /// so the next key: the step goes to the combined value there, and from there on the track runs as combined.
    @Test func aLinearPresetKeyInsideTheSpanIsTheNextKey() {
        var c = clip()
        c.applyPreset(preset([Keyframe(time: s(1), value: 1), Keyframe(time: s(4), value: 0.5), Keyframe(time: s(9), value: 1)]), mode: .relative)
        let t = c.animation.opacity.track
        #expect(t.keys.map(\.time) == [s(1), s(2), s(4), s(6), s(8), s(9)])
        #expect(t.keys[1].interpolation == .holdAhead && t.keys[2].interpolation == .linear)
        #expect(t.value(at: s(2)) == t.keys[1].value && t.value(at: s(3)) == t.keys[2].value)
        // The clip showed 0.2 over the whole span: the key in it is 0.2 combined with the preset's 0.5 there.
        var one = clip()
        one.applyPreset(preset([Keyframe(time: s(4), value: 0.5)]), mode: .relative)
        #expect(t.keys[2].value == one.animation.opacity.track.keys.first { $0.time == s(4) }?.value)
    }

    @Test func aHoldAheadOfThePresetStaysOne() {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(30)), start: .zero)
        let p = EffectPreset(anchor: .stretch, referenceDuration: s(10), opacity: ahead())
        c.applyPreset(p)
        var t = c.animation.opacity.track
        #expect(t.keys.map(\.time) == [s(6), s(18), s(24)] && t.keys[0].interpolation == .holdAhead && t.value(at: s(7)) == 0.2)
        // Relative onto a clip with keys of its own.
        var d = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(30)), start: .zero)
        d.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: s(3), value: 1), Keyframe(time: s(21), value: 0.5)])
        d.applyPreset(p, mode: .relative)
        t = d.animation.opacity.track
        #expect(t.keys.map(\.time) == [s(3), s(6), s(18), s(21), s(24)] && t.keys[1].interpolation == .holdAhead)
        #expect(t.value(at: s(7)) == t.keys[2].value)
    }

    // MARK: Auto Duck

    private func music() -> Clip {
        var c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        c.animation.volume.track = ahead().track
        return c
    }

    @Test func duckingInsideTheSpanLeavesTheLineAsItWasOutsideTheDuck() {
        var c = music()
        let added = c.applyDucking(dialogue: [TimeRange(start: s(3), duration: s(1))], amountDB: 12, fade: Time(1, 2))
        #expect(added == 4)
        let t = c.animation.volume.track
        #expect(t.keys.count == 7 && t.key(id: l)?.interpolation == .holdAhead)
        // The first generated key sits on the value the line had there, so the step is still the same one.
        #expect(c.volume(at: s(2)) == 0.8 && c.volume(at: Time(9, 4)) == 0.2 && c.volume(at: Time(7, 2)) < 0.1 && c.volume(at: s(5)) == 0.2)
        // A second run replaces the generated keys only; removing the ducking gives the line back.
        c.applyDucking(dialogue: [TimeRange(start: s(4), duration: s(1))], amountDB: 12, fade: Time(1, 2))
        #expect(c.animation.volume.track.keys.count == 7)
        c.applyDucking(dialogue: [])
        #expect(c.animation.volume.track == ahead().track)
    }

    @Test func duckingAcrossTheLeaderKeepsItsKey() {
        for start in [Time(3, 2), s(2)] {
            var c = music()
            c.applyDucking(dialogue: [TimeRange(start: start, duration: s(1))], amountDB: 12, fade: Time(1, 2))
            let t = c.animation.volume.track
            #expect(t.key(id: l)?.value == 0.8 && t.key(id: l)?.interpolation == .holdAhead, "\(start)")
            c.applyDucking(dialogue: [])
            #expect(c.animation.volume.track == ahead().track, "\(start)")
        }
    }

    /// The first ducked key follows the leader: it is the key the leader shows, so the level drops on the leader's time,
    /// a quarter second into the half-second fade, instead of standing on 0.2 for that quarter second. No extra key.
    @Test func aDuckKeyRightAfterTheLeaderIsWhatItShows() {
        var c = music()
        let added = c.applyDucking(dialogue: [TimeRange(start: Time(9, 4), duration: s(1))], amountDB: 12, fade: Time(1, 2))
        #expect(added == 4)
        #expect(c.volume(at: s(2)) == 0.8 && c.volume(at: Time(5, 2)) < 0.1 && c.volume(at: s(5)) == 0.2)
        #expect(c.volume(at: Time(21, 10)) == c.volume(at: Time(9, 4)))
        let once = c.animation.volume.track
        c.applyDucking(dialogue: [TimeRange(start: Time(9, 4), duration: s(1))], amountDB: 12, fade: Time(1, 2))
        #expect(c.animation.volume.track.keys.map(\.time) == once.keys.map(\.time) && c.duckKeyIDs.count == 4)
        c.applyDucking(dialogue: [])
        #expect(c.animation.volume.track == ahead().track)
    }
}
