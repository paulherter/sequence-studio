import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Hold Ahead is a shape of the key itself: the key shows its own value on its own time and the next key's value right
/// after it. Every edit that used to keep a hidden helper key in step is now right by construction: there is one key,
/// and "the next key" is whatever key follows it.
@Suite struct HoldAheadTests {
    private let l = UUID(), n = UUID(), m = UUID()

    /// Leader (2 s, Hold Ahead), next key (6 s), last key (8 s).
    private func track() -> KeyframeTrack<Double> {
        KeyframeTrack(keys: [
            Keyframe(id: l, time: s(2), value: 0.8, interpolation: .holdAhead),
            Keyframe(id: n, time: s(6), value: 0.2),
            Keyframe(id: m, time: s(8), value: 0.5),
        ])
    }

    private func video() -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        c.animation.opacity.track = track()
        return c
    }

    private func audio() -> Clip {
        var c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        c.animation.volume.track = track()
        return c
    }

    /// The leader is still a Hold Ahead and shows `value` right after its own time, up to the key after it.
    private func expectAhead(_ t: KeyframeTrack<Double>, value: Double, _ name: String, line: Int = #line) {
        guard let k = t.key(id: l), let next = t.nextKey(of: l) else { Issue.record("\(name) (line \(line)): no leader or next key"); return }
        #expect(k.interpolation == .holdAhead, "\(name) (line \(line))")
        #expect(t.value(at: k.time) == k.value, "\(name) (line \(line)): own value on its own time")
        #expect(abs((t.value(at: k.time + Time(1, 1_000_000)) ?? -1) - value) < 1e-9, "\(name) (line \(line)): right after it")
        #expect(abs(next.value - value) < 1e-9, "\(name) (line \(line)): the next key's value")
        #expect(zip(t.keys, t.keys.dropFirst()).allSatisfy { $0.time < $1.time }, "\(name) (line \(line)): sorted")
    }

    // MARK: Evaluation

    @Test func aHoldAheadShowsTheNextKeyRightAfterItsOwnTime() {
        let t = track()
        #expect(t.value(at: s(1)) == 0.8 && t.value(at: s(2)) == 0.8)
        #expect(t.value(at: s(2) + Time(1, 90_000)) == 0.2 && t.value(at: s(4)) == 0.2 && t.value(at: s(6)) == 0.2)
        #expect(abs((t.value(at: s(7)) ?? 0) - 0.35) < 1e-9)
        // Nothing after it: its own value.
        let last = KeyframeTrack(keys: [Keyframe(time: s(1), value: 1.0), Keyframe(time: s(2), value: 3.0, interpolation: .holdAhead)])
        #expect(last.value(at: s(2)) == 3 && last.value(at: s(9)) == 3)
        #expect(Interpolation.holdAhead.isHold && Interpolation.hold.isHold && !Interpolation.linear.isHold)
        // A step has no speed and its graph is the stepped value.
        #expect(t.speedGraph(samples: 4)[0].samples.allSatisfy { $0.speed == 0 })
        #expect(t.valueGraph(samples: 4)[0].samples.map(\.value) == [0.8, 0.2, 0.2, 0.2])
        // A Vec2 path: the stretch stands on the next key.
        let v = KeyframeTrack(keys: [Keyframe(time: s(0), value: Vec2(0, 0), interpolation: .holdAhead, outTangent: Vec2(50, 0)),
                                     Keyframe(time: s(2), value: Vec2(100, 40), inTangent: Vec2(0, -50))])
        #expect(v.value(at: s(0)) == Vec2(0, 0) && v.value(at: s(1)) == Vec2(100, 40))
    }

    // MARK: 1. Moving the leader

    @Test func draggingTheLeaderOnTheOpacityLineKeepsTheStep() {
        var c = video()
        c.moveOpacityKey(l, toLocal: s(3), value: 0.7)
        let t = c.animation.opacity.track
        #expect(t.keys.map(\.time) == [s(3), s(6), s(8)] && t.key(id: l)?.value == 0.7)
        expectAhead(t, value: 0.2, "later")
        c.moveOpacityKey(l, toLocal: s(1), value: 0.7)
        expectAhead(c.animation.opacity.track, value: 0.2, "earlier")
        // Past the next key: the leader now shows the last key.
        c.moveOpacityKey(l, toLocal: s(7), value: 0.7)
        #expect(c.animation.opacity.track.keys.map(\.id) == [n, l, m])
        expectAhead(c.animation.opacity.track, value: 0.5, "past the next key")
        // Onto the last key (the moved key wins): nothing follows, it shows its own value.
        c.moveOpacityKey(l, toLocal: s(8), value: 0.7)
        #expect(c.animation.opacity.track.keys.map(\.id) == [n, l])
        #expect(c.animation.opacity.track.value(at: s(9)) == 0.7)
    }

    // MARK: 2. Volume line

    @Test func theVolumeLeaderIsClampedByTheKeysOnTheLine() {
        var c = audio()
        c.moveVolumeKey(l, toLocal: s(4), gainDB: -6)
        #expect(c.animation.volume.track.key(id: l)?.time == s(4), "the leader moves later")
        expectAhead(c.animation.volume.track, value: 0.2, "later")
        c = audio()
        c.moveVolumeKey(l, toLocal: s(2), gainDB: -12)
        #expect(c.animation.volume.track.key(id: l)?.time == s(2), "a vertical drag does not pull the key earlier")
        expectAhead(c.animation.volume.track, value: 0.2, "vertical")
        c.moveVolumeKey(l, toLocal: s(7), gainDB: -12)
        #expect(c.animation.volume.track.key(id: l)?.time == s(6) - Clip.minKeyGap)
        expectAhead(c.animation.volume.track, value: 0.2, "against the next key")
        // The line drag lifts the leader and the key after it.
        c = audio()
        c.shiftVolumeLine(atLocal: s(3), byDB: 2)
        let t = c.animation.volume.track
        expectAhead(t, value: t.key(id: n)!.value, "line drag")
        #expect(t.key(id: n)!.value > 0.2 && t.key(id: l)!.value > 0.8)
    }

    // MARK: 3. Deleting

    @Test func deletingAroundTheLeaderLeavesNothingBehind() {
        var t = track()
        t.remove(l)
        #expect(t.keys.map(\.id) == [n, m])

        var v = video()
        v.removeOpacityKey(l)
        #expect(v.animation.opacity.track.keys.map(\.id) == [n, m])
        var a = audio()
        a.removeVolumeKey(l)
        #expect(a.animation.volume.track.keys.map(\.id) == [n, m])

        // A key put on the leader's time replaces it (toggle at the playhead, a paste).
        t = track()
        t.insert(Keyframe(time: s(2), value: 0.4))
        #expect(t.keys.count == 3 && t.keys[0].interpolation == .linear)

        // Removing the key after the leader moves the step on to the last key.
        t = track()
        t.remove(n)
        expectAhead(t, value: 0.5, "next key removed")
        t.remove(m)
        #expect(t.keys.map(\.id) == [l] && t.value(at: s(5)) == 0.8)

        // A fade that replaces the keys in its span.
        v = video()
        v.applyVideoFade(.head, duration: s(3))
        #expect(!v.animation.opacity.track.keys.contains { $0.id == l })
        v = video()
        v.applyVideoFade(.tail, duration: s(5))                              // from 5 s: removes the next and last key
        let f = v.animation.opacity.track
        #expect(f.keys.map(\.time) == [s(2), s(5), s(10)])
        expectAhead(f, value: f.keys[1].value, "fade out after the leader")
    }

    // MARK: 4. Edits of the neighbors

    @Test func theKeyAfterTheLeaderIsWhatItShows() {
        var t = track()
        t.set(n, value: 0.6)
        expectAhead(t, value: 0.6, "set")

        t = track()
        let changed = t.setValue(0.9, at: s(6), selected: [n])
        #expect(changed)
        expectAhead(t, value: 0.9, "setValue")

        var v = video()
        v.moveOpacityKey(n, toLocal: s(6), value: 0.6)
        expectAhead(v.animation.opacity.track, value: 0.6, "opacity key drag")
        v = video()
        v.shiftOpacityLine(atLocal: s(7), by: 0.1)                           // the segment next ... last
        expectAhead(v.animation.opacity.track, value: 0.3, "opacity line drag")
        v = video()
        v.shiftOpacityLine(atLocal: s(3), by: 0.1)                           // the stepped span: leader and next key
        expectAhead(v.animation.opacity.track, value: 0.3, "opacity line drag on the step")
        #expect(abs(v.animation.opacity.track.key(id: l)!.value - 0.9) < 1e-9)

        // A key added inside the span is the next key now.
        t = track()
        t.insert(Keyframe(time: s(4), value: 0.9))
        expectAhead(t, value: 0.9, "insert")
        #expect(t.keys.count == 4 && t.value(at: s(3)) == 0.9 && abs((t.value(at: s(5)) ?? 0) - 0.55) < 1e-9)
        // The leader's own value is free.
        t = track()
        t.set(l, value: 0.1)
        expectAhead(t, value: 0.2, "leader value")
    }

    @Test func aLeaderThatLeavesHoldIsAPlainKey() {
        var t = track()
        t.setHold([l], false)
        #expect(t.key(id: l)?.interpolation == .linear && t.keys.count == 3)
        #expect(abs((t.value(at: s(4)) ?? 0) - 0.5) < 1e-9)

        t = track()
        t.toggleHold([l])
        #expect(t.key(id: l)?.interpolation == .linear)
        t = track()
        t.apply(.easeInOut, to: [l])
        #expect(t.key(id: l)?.interpolation == .bezier)
        t = track()
        t.update(l) { $0.interpolation = .linear }
        #expect(t.keys.count == 3 && t.value(at: s(2)) == 0.8)

        // Hold on a Hold Ahead: it stays what it is, the other key becomes a Hold.
        t = track()
        t.setHold([l, n], true)
        expectAhead(t, value: 0.2, "hold on")
        #expect(t.key(id: n)?.interpolation == .hold)
        // A curve on other keys leaves it alone.
        t = track()
        t.apply(.easeInOut, to: [m])
        expectAhead(t, value: 0.2, "curve elsewhere")

        var summary = KeyframeSummary(tracks: ["p": .scalar(track())])
        summary.toggleHold([SummaryMember(property: "p", keyID: l)])
        guard case .scalar(let r)? = summary.tracks["p"] else { Issue.record("no track"); return }
        #expect(r.key(id: l)?.interpolation == .linear)
    }

    @Test func movingKeysPastEachOtherKeepsTheStepOnTheLeader() {
        func moved(_ ids: [UUID], by d: Time) -> KeyframeTrack<Double> {
            var summary = KeyframeSummary(tracks: ["p": .scalar(track())])
            summary.move(Set(ids.map { SummaryMember(property: "p", keyID: $0) }), by: d, frame: Time(1, 30))
            guard case .scalar(let r)? = summary.tracks["p"] else { return KeyframeTrack() }
            return r
        }
        var t = moved([l], by: s(5))                                         // leader past the next key
        #expect(t.keys.map(\.id) == [n, l, m])
        expectAhead(t, value: 0.5, "leader past the next key")

        t = moved([n], by: .zero - s(5))                                     // next key past the leader
        #expect(t.keys.map(\.id) == [n, l, m])
        expectAhead(t, value: 0.5, "next key past the leader")

        t = moved([l, n], by: s(1))
        #expect(t.keys.map(\.time) == [s(3), s(7), s(8)])
        expectAhead(t, value: 0.2, "both")

        t = moved([l], by: s(7))                                             // behind every key
        #expect(t.keys.map(\.id) == [n, m, l] && t.value(at: s(10)) == 0.8)
    }

    // MARK: 5. Copy, paste, Option-drag

    private func paste(_ ids: Set<UUID>, into target: [PropertyID: PropertyTrack], at time: Time = s(1),
                       within range: ClosedRange<Time>? = nil) throws -> KeyframeTrack<Double> {
        let board = try #require(KeyframeClipboard.copy(from: ["p": .scalar(track())], selection: ["p": ids]))
        var target = target
        #expect(board.paste(into: &target, at: time, within: range))
        guard case .scalar(let t)? = target["p"] else { throw CancellationError() }
        return t
    }

    @Test func aCopiedLeaderIsOneKeyThatStaysAHoldAhead() throws {
        let board = try #require(KeyframeClipboard.copy(from: ["p": .scalar(track())], selection: ["p": [l, n]]))
        guard case .scalar(let copied)? = board.tracks["p"] else { Issue.record("no track"); return }
        #expect(copied.map(\.relativeTime) == [.zero, s(4)] && copied.map(\.interpolation) == [.holdAhead, .linear])
        let t = try paste([l, n], into: [:])
        #expect(t.keys.map(\.time) == [s(1), s(5)] && t.value(at: s(1)) == 0.8 && t.value(at: s(3)) == 0.2)
        // The clipboard survives its own coding (the pasteboard).
        let back = try JSONDecoder().decode(KeyframeClipboard.self, from: JSONEncoder().encode(board))
        #expect(back == board)
    }

    @Test func aPastedLeaderShowsTheKeyThatFollowsItThere() throws {
        // Another value follows at the destination: the pasted key steps to that one, as its shape says.
        let other = Keyframe(time: s(9), value: 0.6)
        var t = try paste([l], into: ["p": .scalar(KeyframeTrack(keys: [other]))])
        #expect(t.keys.map(\.time) == [s(1), s(9)] && t.keys[0].interpolation == .holdAhead)
        #expect(t.value(at: s(1)) == 0.8 && t.value(at: s(3)) == 0.6 && t.value(at: s(9)) == 0.6)
        // Nothing follows: one key on its own value.
        t = try paste([l], into: [:])
        #expect(t.keys.count == 1 && t.value(at: s(5)) == 0.8)
        t = try paste([l], into: ["p": .scalar(KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.1)]))])
        #expect(t.keys.count == 2 && t.value(at: s(5)) == 0.8)
        // A range that cuts the next key off leaves the one key, no part of it can be lost.
        t = try paste([l, n], into: [:], within: s(0)...s(3))
        #expect(t.keys.count == 1 && t.keys[0].interpolation == .holdAhead)
        t = try paste([l], into: ["p": .scalar(KeyframeTrack(keys: [Keyframe(time: s(9), value: 0.2)]))], within: s(1)...s(1))
        #expect(t.keys.count == 2 && t.value(at: s(3)) == 0.2)
    }

    /// Open point of "Item lanes rest 7": a key pasted, dropped or Option-dragged inside the span of a Hold Ahead.
    /// By construction it is the next key, so the span up to it shows its value and the span after it is its own.
    @Test func aKeyPutInsideTheSpanIsTheNextKey() throws {
        // Pasted.
        var t = try paste([m], into: ["p": .scalar(track())], at: s(4))
        #expect(t.keys.map(\.time) == [s(2), s(4), s(6), s(8)])
        expectAhead(t, value: 0.5, "pasted inside")
        #expect(t.value(at: s(4)) == 0.5 && abs((t.value(at: s(5)) ?? 0) - 0.35) < 1e-9)
        // Dropped (a plain insert, the preset drop and the playhead toggle use it).
        t = track()
        t.insert(Keyframe(time: s(3), value: 1.0, interpolation: .hold))
        expectAhead(t, value: 1.0, "dropped inside")
        #expect(t.value(at: s(5)) == 1.0 && t.value(at: s(6)) == 0.2)
        // Option-dragged: the last key's copy lands inside the span, the original stays.
        var sum = KeyframeSummary(tracks: ["p": .scalar(track())])
        sum.moveDuplicating([SummaryMember(property: "p", keyID: m)], by: .zero - s(5), frame: Time(1, 30))
        guard case .scalar(let d)? = sum.tracks["p"] else { Issue.record("no track"); return }
        #expect(d.keys.map(\.time) == [s(2), s(3), s(6), s(8)] && d.key(id: m)?.time == s(3))
        expectAhead(d, value: 0.5, "Option-dragged inside")
        #expect(d.value(at: s(8)) == 0.5)
    }

    @Test func anOptionDragCopyOfALeaderIsAHoldAheadToo() {
        var sum = KeyframeSummary(tracks: ["p": .scalar(track())])
        let applied = sum.moveDuplicating([SummaryMember(property: "p", keyID: l)], by: s(-1), frame: Time(1, 30))
        #expect(applied == s(-1))
        guard case .scalar(let t)? = sum.tracks["p"] else { Issue.record("no track"); return }
        #expect(t.keys.map(\.time) == [s(1), s(2), s(6), s(8)] && t.key(id: l)?.time == s(1))
        #expect(t.keys.map(\.interpolation) == [.holdAhead, .holdAhead, .linear, .linear])
        // The copy left on 2 s steps to the next key's value as the original did; the original steps to the copy.
        #expect(t.value(at: s(1)) == 0.8 && t.value(at: Time(3, 2)) == 0.8 && t.value(at: s(2)) == 0.8 && t.value(at: s(3)) == 0.2)
        // The original moved right: the copy is followed by the original, and shows it.
        sum = KeyframeSummary(tracks: ["p": .scalar(track())])
        sum.moveDuplicating([SummaryMember(property: "p", keyID: l)], by: s(1), frame: Time(1, 30))
        guard case .scalar(let u)? = sum.tracks["p"] else { Issue.record("no track"); return }
        #expect(u.keys.map(\.time) == [s(2), s(3), s(6), s(8)])
        #expect(u.value(at: Time(5, 2)) == 0.8 && u.value(at: s(4)) == 0.2)
    }

    // MARK: 6. Shapes, pairs and neighbors

    @Test func aLinearShapeOnLeaderAndNextKeyEases() {
        var sum = KeyframeSummary(tracks: ["p": .scalar(track())])
        let members: Set<SummaryMember> = [SummaryMember(property: "p", keyID: l), SummaryMember(property: "p", keyID: n)]
        let sel = EaseSelection(summary: sum, members: members)
        #expect(sel.segments == [EaseSegment(property: "p", from: l, to: n)])
        let written = sel.apply(.linear, to: &sum)
        #expect(written == 1)
        guard case .scalar(let t)? = sum.tracks["p"] else { Issue.record("no track"); return }
        #expect(t.keys.count == 3 && abs((t.value(at: s(4)) ?? -1) - 0.5) < 1e-9)
        // A hold shape leaves the Hold Ahead what it is.
        var held = KeyframeSummary(tracks: ["p": .scalar(track())])
        let again = sel.apply(.hold, to: &held)
        #expect(again == 1)
        guard case .scalar(let k)? = held.tracks["p"] else { Issue.record("no track"); return }
        expectAhead(k, value: 0.2, "hold shape")
        var c = track()
        c.apply(.hold, to: [l])
        expectAhead(c, value: 0.2, "hold curve")
        #expect(PropertyTrack.scalar(track()).keyIDs == [l, n, m])
    }

    @Test func aSpringBakesBetweenLeaderAndNextKey() {
        var t = track()
        let ok = t.bakeSpring(SpringEasing(bounce: 0.3), from: l, to: n)
        #expect(ok)
        #expect(t.keys.count > 3 && t.key(id: l)?.interpolation == .linear)
    }

    @Test func leaderAndNextKeyAreAPairForPairEase() {
        var t = track()
        #expect(t.hasAdjacentPair([l, n]) && t.pairedKeyIDs([l, n]) == [l, n])
        let changed = t.applyPairEase(.inOut, to: [l, n])
        #expect(changed == 1)
        expectAhead(t, value: 0.2, "pair ease")   // a step stays a step
    }

    @Test func aSmoothInsertAfterALeaderKeepsTheStep() {
        let a = UUID(), c = UUID()
        var t = KeyframeTrack<Vec2>(keys: [
            Keyframe(id: a, time: s(2), value: Vec2(0, 0), interpolation: .holdAhead),
            Keyframe(id: c, time: s(6), value: Vec2(100, 0)),
        ])
        t.insertSmooth(Keyframe(time: s(8), value: Vec2(200, 100)))
        t.insertSmooth(Keyframe(time: s(4), value: Vec2(50, 80)))
        #expect(t.keys.count == 4 && t.key(id: a)?.interpolation == .holdAhead)
        #expect(t.value(at: s(2)) == Vec2(0, 0) && t.value(at: s(3)) == Vec2(50, 80))
        #expect(t.motionPath(samplesPerSegment: 4)[0].points == [Vec2(50, 80)])
    }

    // MARK: 7. Retimes

    @Test func restretchingAKeystoneKeepsTheStep() {
        var c = video()
        let span = KeystoneSpan(start: s(1), duration: s(6), properties: [.opacity])
        let ok = c.restretchKeystone(span, to: KeystoneSpan(start: s(1), duration: s(3), properties: [.opacity]))
        #expect(ok)
        let t = c.animation.opacity.track
        expectAhead(t, value: 0.2, "restretch")
        #expect(t.keys.map(\.time) == [Time(3, 2), Time(7, 2), s(8)])
        var wide = video()
        wide.restretchKeystone(KeystoneSpan(start: s(2), duration: s(4), properties: [.opacity]),
                               to: KeystoneSpan(start: .zero, duration: s(7), properties: [.opacity]))
        expectAhead(wide.animation.opacity.track, value: 0.2, "restretch wider")
        #expect(wide.animation.opacity.track.keys.map(\.time) == [.zero, s(7), s(8)])
    }

    @Test func aRetimeKeepsOneKeyAndAReverseTurnsItIntoAHold() {
        let p = AnimatedProperty(0.0, track: track())
        let slow = p.remapped { Time.scaled($0, by: s(20), over: s(10)) }
        #expect(slow.track.keys.map(\.time) == [s(4), s(12), s(16)] && slow.track.keys[0].interpolation == .holdAhead)
        // Reversed: the key that now leads the stretch holds its value up to the old leader.
        let r = p.remapped { s(10) - $0 }
        #expect(r.track.keys.map(\.time) == [s(2), s(4), s(8)])
        #expect(r.track.keys.map(\.interpolation) == [.linear, .hold, .linear])
        #expect(r.track.value(at: s(6)) == 0.2 && r.track.value(at: s(8)) == 0.8)
        #expect(r.remapped { s(10) - $0 } == p)
    }
}
