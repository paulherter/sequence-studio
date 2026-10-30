import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func seg(_ frames: Int64, _ a: Double, _ b: Double? = nil, rev: Bool = false) -> SpeedSegment {
    SpeedSegment(duration: f(frames), from: pct(a), to: pct(b ?? a), reversed: rev)
}
private func clip(start: Int64 = 0, from: Int64 = 0, frames: Int64, media: Int64 = 6000, kind: TrackKind = .video,
                  link: UUID? = nil, speed: ClipSpeed = .normal, reversed: Bool = false) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(media), speed: speed, reversed: reversed)
}
private func timeline(_ tracks: [[Clip]]) throws -> Timeline {
    var ts: [Track] = []
    for cs in tracks {
        var t = Track(kind: cs.first?.kind ?? .video)
        for c in cs { try t.overwrite(c) }
        ts.append(t)
    }
    return Timeline(name: "t", frameDuration: fd, tracks: ts)
}

@Suite struct SpeedKeysMathTests {
    @Test func twoConstantSegmentsGiveExactBoundaryTimes() {
        // 30 frames at 100 %, then 30 frames at 200 %: boundary at 1 s of source, end at 3 s.
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 200)], origin: f(60))
        #expect(k.duration == f(60))
        #expect(k.position(at: f(30)) == f(60) + Time(1, 1))
        #expect(k.position(at: f(60)) == f(60) + Time(3, 1))
        #expect(k.position(at: f(45)) == f(60) + Time(2, 1))
        #expect(k.hull == TimeRange(start: f(60), duration: Time(3, 1)))
    }

    @Test func rampUsesTheClosedFormExactly() {
        // 1x -> 3x over 2 s: span T(a+b)/2 = 4 s; at 1 s: a t + (b-a) t^2 / 2T = 1 + 2/4 = 1.5 s.
        let k = SpeedKeys(segments: [SpeedSegment(duration: Time(2, 1), from: pct(100), to: pct(300))], origin: .zero)
        #expect(k.position(at: Time(2, 1)) == Time(4, 1))
        #expect(k.position(at: Time(1, 1)) == Time(3, 2))
        #expect(k.segments[0].span == Time(4, 1))
    }

    @Test func reversedSegmentsAreAllowed() {
        // forward 1 s at 100 %, then backwards 0.5 s of source (30 frames at 50 %).
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 50, rev: true)], origin: .zero)
        #expect(k.position(at: f(30)) == Time(1, 1))
        #expect(k.position(at: f(60)) == Time(1, 2))
        #expect(k.hull == TimeRange(start: .zero, end: Time(1, 1)))
        #expect(k.isReversed(at: f(45)) && !k.isReversed(at: f(10)))
        // Reversed frame convention: the frame shown for [x, x+fd) starts at position(x + fd).
        #expect(k.sourceTime(at: f(30), frameDuration: fd) == k.position(at: f(31)))
        #expect(k.sourceTime(at: f(10), frameDuration: fd) == k.position(at: f(10)))
    }

    @Test func clipDurationFollowsTheTrackAndSourceIsTheHull() {
        var c = clip(from: 100, frames: 60)
        c.setSpeedKeys(SpeedKeys(segments: [seg(30, 100), seg(15, 200)], origin: f(100)))
        #expect(c.duration == f(45))
        #expect(c.source == TimeRange(start: f(100), duration: f(60)))     // 30 + 30 frames of source
    }

    @Test func positionIsMonotoneForPositiveSpeeds() {
        var seed: UInt64 = 42
        func next(_ n: Int64) -> Int64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int64(seed >> 33) % n }
        for _ in 0..<40 {
            var segs: [SpeedSegment] = []
            for _ in 0..<(2 + next(4)) {
                segs.append(seg(1 + next(40), Double(1 + next(900)) + 0.5, next(3) == 0 ? nil : Double(1 + next(900)) + 0.5))
            }
            let k = SpeedKeys(segments: segs, origin: f(next(1000)))
            var prev = k.position(at: .zero)
            let total = k.duration.frameIndex(frameDuration: fd)
            for i in 1...total {
                let p = k.position(at: f(i))
                #expect(p >= prev)
                prev = p
            }
            // Half-frame steps too (ramp interior).
            var h = k.position(at: .zero)
            for i in 1...(total * 2) {
                let p = k.position(at: Time(i, 60))
                #expect(p >= h)
                h = p
            }
        }
    }

    @Test func constantSegmentIsBitIdenticalToClipSpeedScale() {
        let s = pct(33.33)
        let k = SpeedKeys(constant: s, reversed: false, duration: f(90), origin: f(7))
        for i in stride(from: 0 as Int64, through: 90, by: 7) { #expect(k.position(at: f(i)) == f(7) + s.scale(f(i))) }
    }

    @Test func oneSegmentTrackEqualsTheConstantClipFrameByFrame() {
        for rev in [false, true] {
            let plain = clip(from: 10, frames: 120, speed: pct(250), reversed: rev)
            var keyed = plain
            keyed.speedKeys = SpeedKeys.of(plain)
            #expect(keyed.duration == plain.duration)
            #expect(keyed.speedKeys!.hull == plain.source)
            for i in stride(from: 0 as Int64, to: plain.duration.frameIndex(frameDuration: fd), by: 1) {
                #expect(keyed.sourceTime(at: f(i), frameDuration: fd) == plain.sourceTime(at: f(i), frameDuration: fd))
            }
        }
    }

    @Test func timelineTimeInvertsSourceTime() {
        var c = clip(from: 100, frames: 60)
        c.setSpeedKeys(SpeedKeys(segments: [seg(30, 100), seg(30, 100, 400), seg(20, 400)], origin: f(100)))
        for i in stride(from: 0 as Int64, to: c.duration.frameIndex(frameDuration: fd), by: 3) {
            let s = c.sourceTime(at: f(i), frameDuration: fd)
            let back = c.timelineTime(forSource: s, frameDuration: fd)
            #expect(abs((back - f(i)).value * 1000 / (back - f(i)).timescale) <= 1)   // within a millisecond
        }
    }

    @Test func slicingARampKeepsItsSlope() {
        let k = SpeedKeys(segments: [SpeedSegment(duration: Time(4, 1), from: pct(100), to: pct(500))], origin: .zero)
        let s = k.sliced(from: Time(1, 1), to: Time(3, 1))
        #expect(s.segments[0].from == pct(200) && s.segments[0].to == pct(400))
        #expect(s.origin == k.position(at: Time(1, 1)))
        #expect(s.position(at: Time(1, 1)) == k.position(at: Time(2, 1)))
    }

    @Test func extendingTailAndHead() {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 200)], origin: f(300))
        let t = k.extendedTail(by: f(10))
        #expect(t.duration == f(70))
        #expect(t.position(at: f(70)) == k.endPosition + pct(200).scale(f(10)))
        let h = k.extendedHead(by: f(10))
        #expect(h.duration == f(70) && h.origin == f(300) - f(10) && h.position(at: f(10)) == f(300))
        #expect(k.extendedHead(by: f(-10)).origin == f(310))
        #expect(k.extendedTail(by: f(-40)).duration == f(20))
    }

    @Test func codableRoundTripAndOldClipHasNoKeys() throws {
        var c = clip(from: 0, frames: 60)
        c.setSpeedKeys(SpeedKeys(segments: [seg(10, 100), seg(10, 100, 300, rev: false)], origin: .zero))
        c.timeInterpolation = .frameBlend
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip(frames: 30))) as! [String: Any]
        obj.removeValue(forKey: "speedKeys"); obj.removeValue(forKey: "timeInterpolation")
        let old = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.speedKeys == nil && old.timeInterpolation == .frameSampling)
    }

    @Test func v22ProjectFileMigratesWithConstantClipsEqual() throws {
        let c = clip(from: 10, frames: 90, speed: pct(300), reversed: true)
        var p = Project(name: "P")
        var t = Track(kind: .video); try t.overwrite(c)
        p.timelines = [Timeline(name: "s", frameDuration: fd, tracks: [t])]
        let data = try ProjectFile.encode(p)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["formatVersion"] = 22
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(old, migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0] == c)
    }
}

@Suite struct SpeedKeysEditingTests {
    @Test func addingAKeySplitsWithoutChangingTheMapping() throws {
        let k = SpeedKeys(segments: [SpeedSegment(duration: f(60), from: pct(100), to: pct(300))], origin: .zero)
        let (n, b) = try #require(k.addingKey(at: f(20), frameDuration: fd))
        #expect(b == 1 && n.segments.count == 2 && n.duration == f(60))
        for i in stride(from: 0 as Int64, through: 60, by: 5) { #expect(n.position(at: f(i)) == k.position(at: f(i))) }
        #expect(k.addingKey(at: .zero, frameDuration: fd) == nil)
    }

    @Test func settingASegmentSpeedKeepsItsSourceAndChangesTheLength() {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 100)], origin: .zero)
        let split = SpeedKeys(segments: [seg(30, 100), seg(30, 100)], origin: .zero)
        let e = split.settingSpeed(ofSegment: 1, to: pct(200), frameDuration: fd)
        #expect(e.segments.count == 2 && e.segments[1].duration == f(15) && e.duration == f(45))
        #expect(e.endPosition == k.endPosition)
    }

    @Test func splitKeyMakesARampBetweenTheHalves() throws {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 300)], origin: .zero)
        let s = try #require(k.splittingKey(atBoundary: 1, half: f(5), frameDuration: fd))
        #expect(s.segments.count == 3 && s.segments[1].isRamp && s.segments[1].duration == f(10))
        #expect(s.segments[1].from == pct(100) && s.segments[1].to == pct(300))
        #expect(s.duration == k.duration)
        // ramp is linear: speed at its middle is 200 %
        #expect(abs(s.segments[1].speedValue(at: f(5)) - 2) < 1e-12)
        let reversedMix = SpeedKeys(segments: [seg(30, 100), seg(30, 300, rev: true)], origin: .zero)
        #expect(reversedMix.splittingKey(atBoundary: 1, half: f(5), frameDuration: fd) == nil)
    }

    @Test func rampWidthGrowsFromBothNeighbours() throws {
        let k = try #require(SpeedKeys(segments: [seg(30, 100), seg(30, 300)], origin: .zero)
            .splittingKey(atBoundary: 1, half: f(5), frameDuration: fd))
        let w = try #require(k.settingRampWidth(ofSegment: 1, to: f(20), frameDuration: fd))
        #expect(w.segments.map(\.duration) == [f(20), f(20), f(20)] && w.duration == k.duration)
        let n = try #require(k.settingRampWidth(ofSegment: 1, to: f(4), frameDuration: fd))
        #expect(n.segments.map(\.duration) == [f(28), f(4), f(28)])
    }

    @Test func movingAndDeletingKeys() throws {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 200)], origin: .zero)
        let m = try #require(k.movingKey(atBoundary: 1, by: f(10), frameDuration: fd))
        #expect(m.segments.map(\.duration) == [f(40), f(20)] && m.duration == k.duration)
        let d = try #require(k.removingKey(atBoundary: 1))
        #expect(d.segments.count == 1 && d.duration == f(60) && d.endPosition == k.endPosition)
    }

    @Test func scalingKeepsTheSourceSpans() {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 200)], origin: f(5))
        let s = k.scaled(toDuration: f(30), frameDuration: fd)
        #expect(s.duration == f(30) && s.endPosition == k.endPosition)
    }
}

@Suite struct SpeedKeysTimelineTests {
    @Test func firstEditCreatesATrackAndTheClipLengthFollows() throws {
        var tl = try timeline([[clip(from: 0, frames: 90)]])
        let id = tl.tracks[0].clips[0].id
        // key at frame 30, then second half at 200 %
        try tl.editSpeedKeys(id) { $0.addingKey(at: f(30), frameDuration: fd)?.keys }
        #expect(tl.tracks[0].clips[0].speedKeys == nil)             // two equal segments normalize back to constant
        try tl.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: f(30), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: pct(200), frameDuration: fd)
        }
        let c = tl.tracks[0].clips[0]
        #expect(c.speedKeys != nil && c.duration == f(30 + 30) && c.source == TimeRange(start: .zero, duration: f(90)))
        #expect(c.sourceTime(at: f(30), frameDuration: fd) == f(30))
        #expect(c.sourceTime(at: f(45), frameDuration: fd) == f(60))
    }

    @Test func editingBackToOneSpeedGivesAPlainConstantClip() throws {
        var tl = try timeline([[clip(from: 10, frames: 90)]])
        let id = tl.tracks[0].clips[0].id
        let original = tl.tracks[0].clips[0]
        try tl.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: f(30), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: pct(200), frameDuration: fd)
        }
        try tl.editSpeedKeys(id) { $0.settingSpeed(ofSegment: 1, to: pct(100), frameDuration: fd) }
        #expect(tl.tracks[0].clips[0] == original)
    }

    @Test func linkedPartnersGetTheSameTrackAndOneUndoStep() throws {
        let link = UUID()
        var tl = try timeline([[clip(from: 0, frames: 90, link: link)], [clip(from: 0, frames: 90, kind: .audio, link: link)]])
        let id = tl.tracks[0].clips[0].id
        try tl.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: f(30), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: pct(300), frameDuration: fd)
        }
        let a = tl.tracks[0].clips[0], b = tl.tracks[1].clips[0]
        #expect(a.speedKeys?.segments == b.speedKeys?.segments && a.duration == b.duration && a.duration == f(50))
    }

    @Test func growingStopsAtTheNeighbour() throws {
        var tl = try timeline([[clip(from: 0, frames: 60), clip(start: 70, from: 100, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.editSpeedKeys(id) { $0.settingSpeed(ofSegment: 0, to: pct(50), frameDuration: fd) }   // wants 120 frames
        #expect(tl.tracks[0].clips[0].duration == f(70))
    }

    @Test func remappedClipSplitsContinuously() throws {
        var tl = try timeline([[clip(from: 0, frames: 90)]])
        let id = tl.tracks[0].clips[0].id
        try tl.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: f(30), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: pct(200), frameDuration: fd)
        }
        let whole = tl.tracks[0].clips[0]
        try tl.tracks[0].split(at: f(40))
        let l = tl.tracks[0].clips[0], r = tl.tracks[0].clips[1]
        #expect(l.duration == f(40) && r.duration == f(20))
        for i in stride(from: 0 as Int64, to: 40, by: 3) { #expect(l.sourceTime(at: f(i), frameDuration: fd) == whole.sourceTime(at: f(i), frameDuration: fd)) }
        for i in stride(from: 40 as Int64, to: 60, by: 3) { #expect(r.sourceTime(at: f(i), frameDuration: fd) == whole.sourceTime(at: f(i), frameDuration: fd)) }
    }

    @Test func tailTrimOfARemappedClipUsesTheLastSpeed() throws {
        var tl = try timeline([[clip(from: 0, frames: 90)]])
        let id = tl.tracks[0].clips[0].id
        try tl.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: f(30), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: pct(200), frameDuration: fd)
        }
        try tl.trim(id, edge: .tail, by: f(10))
        let c = tl.tracks[0].clips[0]
        #expect(c.duration == f(70) && c.source.end == f(90) + f(20))
    }

    @Test func constantSpeedChangeScalesKeysSpeedKeyEditDoesNot() throws {
        var c = clip(from: 0, frames: 90)
        c.animation.opacity.track.insert(Keyframe(time: f(30), value: 0.5))
        var tl = try timeline([[c]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(200))
        #expect(tl.tracks[0].clips[0].animation.opacity.track.keys.first?.time == f(15))   // scaled with the clip
        try tl.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: f(20), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: pct(400), frameDuration: fd)
        }
        #expect(tl.tracks[0].clips[0].animation.opacity.track.keys.first?.time == f(15))   // stays on its frame
    }

    @Test func speedDialogOnARemappedClipScalesTheShape() throws {
        var tl = try timeline([[clip(from: 0, frames: 90)]])
        let id = tl.tracks[0].clips[0].id
        try tl.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: f(30), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: pct(200), frameDuration: fd)
        }
        let before = tl.tracks[0].clips[0]
        try tl.setSpeed(id, to: pct(200))
        let c = tl.tracks[0].clips[0]
        #expect(c.speedKeys != nil && c.source == before.source && c.duration.frameIndex(frameDuration: fd) == 45)   // 90 frames of path at 200 %
    }
}
