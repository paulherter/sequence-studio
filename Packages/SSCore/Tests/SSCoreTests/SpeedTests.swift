import Foundation
import Testing
@testable import SSCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }

/// A clip of `frames` frames of source starting at source frame `from`, media `mediaFrames` long.
private func clip(start: Int64 = 0, from: Int64 = 0, frames: Int64, media: Int64 = 3000, kind: TrackKind = .video,
                  link: UUID? = nil, speed: ClipSpeed = .normal, reversed: Bool = false) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(media), speed: speed, reversed: reversed)
}
private func timeline(_ tracks: [[Clip]], kinds: [TrackKind]? = nil) throws -> Timeline {
    var ts: [Track] = []
    for (i, cs) in tracks.enumerated() {
        var t = Track(kind: kinds?[i] ?? .video)
        for c in cs { try t.overwrite(c) }
        ts.append(t)
    }
    return Timeline(name: "t", frameDuration: fd, tracks: ts)
}

@Suite struct ClipSpeedTests {
    @Test func ratioIsExactAndClamped() {
        #expect(ClipSpeed(num: 4, den: 2) == ClipSpeed(num: 2, den: 1))
        #expect(pct(33.33).num == 3333 && pct(33.33).den == 10000)
        #expect(pct(250) == ClipSpeed(num: 5, den: 2))
        #expect(pct(0.1) == .minimum && pct(100_000) == .maximum)
        #expect(ClipSpeed(num: 0, den: 1) == .normal)
        #expect(ClipSpeed.normal.isNormal && !pct(200).isNormal)
    }

    @Test func scaleAndUnscaleAreInverse() {
        let s = pct(33.33)
        let t = Time(7, 3)
        #expect(s.unscale(s.scale(t)) == t)
        #expect(pct(200).scale(f(30)) == Time(2, 1))
    }

    @Test func codableRoundTrip() throws {
        let c = clip(frames: 90, speed: pct(33.33), reversed: true)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back == c && back.speed == pct(33.33) && back.reversed)
    }

    @Test func oldClipJSONDecodesAtNormalSpeed() throws {
        let c = clip(frames: 30)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        obj.removeValue(forKey: "speed"); obj.removeValue(forKey: "reversed"); obj.removeValue(forKey: "keepsPitch")
        let back = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.speed == .normal && !back.reversed && back.keepsPitch)
    }
}

@Suite struct ClipMappingTests {
    @Test func durationAndSourceTimeForwardAt200() {
        let c = clip(start: 10, from: 20, frames: 60, speed: pct(200))
        #expect(c.duration == f(30) && c.timeline == TimeRange(start: f(10), duration: f(30)))
        #expect(c.sourceTime(at: f(10), frameDuration: fd) == f(20))
        #expect(c.sourceTime(at: f(15), frameDuration: fd) == f(30))   // 5 timeline frames = 10 source frames
        #expect(c.timelineTime(forSource: f(30)) == f(15))
    }

    @Test func halfSpeedNonIntegerRatio() {
        let c = clip(frames: 30, speed: pct(33.33))
        #expect(c.duration == ClipSpeed(percent: 33.33).unscale(f(30)))
        #expect(c.sourceTime(at: f(3), frameDuration: fd) == pct(33.33).scale(f(3)))
    }

    @Test func reverseShowsLastFrameFirst() {
        let c = clip(start: 5, from: 10, frames: 30, reversed: true)        // source frames 10..<40
        #expect(c.sourceTime(at: f(5), frameDuration: fd) == f(39))          // first shown = last source frame
        #expect(c.sourceTime(at: f(6), frameDuration: fd) == f(38))
        #expect(c.sourceTime(at: f(34), frameDuration: fd) == f(10))         // last shown = first source frame
    }

    @Test func reverseAt200() {
        let c = clip(from: 0, frames: 60, speed: pct(200), reversed: true)   // duration 30 frames
        #expect(c.sourceTime(at: f(0), frameDuration: fd) == f(58))
        #expect(c.sourceTime(at: f(10), frameDuration: fd) == f(38))
        #expect(c.timelineTime(forSource: f(40)) == f(10))
    }

    @Test func splitKeepsPictureContinuousWhenSpedUp() throws {
        var t = Track(kind: .video)
        try t.overwrite(clip(from: 0, frames: 60, speed: pct(200)))          // 30 timeline frames
        try t.split(at: f(12))
        let l = t.clips[0], r = t.clips[1]
        #expect(l.duration == f(12) && r.duration == f(18) && r.start == f(12))
        #expect(l.source == TimeRange(start: f(0), duration: f(24)) && r.source == TimeRange(start: f(24), duration: f(36)))
        #expect(r.sourceTime(at: f(12), frameDuration: fd) == l.source.end)
        #expect(r.speed == pct(200) && l.speed == pct(200))
    }

    @Test func splitReversedClipPlaysBackwardsAcrossTheCut() throws {
        var t = Track(kind: .video)
        try t.overwrite(clip(from: 0, frames: 30, reversed: true))
        try t.split(at: f(10))
        let l = t.clips[0], r = t.clips[1]
        #expect(l.source == TimeRange(start: f(20), duration: f(10)))        // plays first: the end of the source
        #expect(r.source == TimeRange(start: f(0), duration: f(20)))
        #expect(l.sourceTime(at: f(9), frameDuration: fd) == f(20))          // last frame of left
        #expect(r.sourceTime(at: f(10), frameDuration: fd) == f(19))         // next source frame backwards
        #expect(l.reversed && r.reversed)
    }

    @Test func splitAtNonIntegerRatioIsExactRational() throws {
        var t = Track(kind: .video)
        let s = pct(33.33)
        try t.overwrite(clip(from: 0, frames: 30, speed: s))
        let d = t.clips[0].duration
        try t.split(at: f(10))
        let l = t.clips[0], r = t.clips[1]
        #expect(l.source.duration == s.scale(f(10)))
        #expect(l.duration == f(10) && r.duration == d - f(10))
        #expect(l.source.end == r.source.start && r.source.end == f(30))
    }

    @Test func keyframesStayInClipTimelineTimeWhenSplit() throws {
        var c = clip(from: 0, frames: 60, speed: pct(200))
        c.animation.volume.track.insert(Keyframe(time: f(5), value: 0.0))
        c.animation.volume.track.insert(Keyframe(time: f(25), value: 1.0))
        let before = c.volume(at: f(20))
        var t = Track(kind: .video)
        try t.overwrite(c)
        try t.split(at: f(10))
        #expect(before > 0.5 && t.clips[1].volume(at: f(20)) == before && t.clips[0].volume(at: f(8)) == c.volume(at: f(8)))
    }
}

@Suite struct SpeedTrimTests {
    @Test func tailTrimExposesMoreSourceAtClipSpeed() throws {
        var tl = try timeline([[clip(from: 0, frames: 60, speed: pct(200))]])
        let id = tl.tracks[0].clips[0].id
        let applied = try tl.trim(id, edge: .tail, by: f(5))
        #expect(applied == f(5))
        let c = tl.tracks[0].clips[0]
        #expect(c.duration == f(35) && c.source.duration == f(70))
    }

    @Test func headTrimShortensAtSpeedAndKeepsPictureAnchored() throws {
        var tl = try timeline([[clip(start: 10, from: 20, frames: 60, speed: pct(200))]])
        let id = tl.tracks[0].clips[0].id
        try tl.trim(id, edge: .head, by: f(4))                                // 4 timeline frames = 8 source frames
        let c = tl.tracks[0].clips[0]
        #expect(c.start == f(14) && c.source.start == f(28) && c.duration == f(26))
        #expect(c.sourceTime(at: f(14), frameDuration: fd) == f(28))
    }

    @Test func tailTrimClampedByMediaAtSpeed() throws {
        var tl = try timeline([[clip(from: 0, frames: 60, media: 70, speed: pct(200))]])
        let id = tl.tracks[0].clips[0].id
        let applied = try tl.trim(id, edge: .tail, by: f(20))
        #expect(applied == f(5))                                              // 10 source frames left = 5 timeline frames
    }

    @Test func reversedTailTrimConsumesTheSourceStart() throws {
        var tl = try timeline([[clip(from: 10, frames: 20, reversed: true)]])
        let id = tl.tracks[0].clips[0].id
        let applied = try tl.trim(id, edge: .tail, by: f(30))
        #expect(applied == f(10))                                             // only 10 frames before the in-point
        let c = tl.tracks[0].clips[0]
        #expect(c.source == TimeRange(start: f(0), duration: f(30)) && c.reversed)
    }

    @Test func reversedHeadTrimGrowsFromTheSourceEnd() throws {
        var tl = try timeline([[clip(start: 30, from: 10, frames: 20, media: 50, reversed: true)]])
        let id = tl.tracks[0].clips[0].id
        let applied = try tl.trim(id, edge: .head, by: f(-30))
        #expect(applied == f(-20))                                            // 20 frames after the out-point
        let c = tl.tracks[0].clips[0]
        #expect(c.start == f(10) && c.duration == f(40))
        #expect(c.source.end == f(50) && c.source.start == f(10))
    }

    @Test func rippleTrimAtSpeedShiftsLaterClipsByTimelineChange() throws {
        var tl = try timeline([[clip(from: 0, frames: 60, speed: pct(200)), clip(start: 40, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.rippleTrim(id, edge: .tail, by: f(-10))
        #expect(tl.tracks[0].clips[0].duration == f(20) && tl.tracks[0].clips[1].start == f(20 + 10))
    }

    @Test func slipMovesSourceByFramesTimesSpeed() throws {
        var tl = try timeline([[clip(from: 20, frames: 60, speed: pct(200))]])
        let id = tl.tracks[0].clips[0].id
        let applied = try tl.slip(id, by: f(3))
        #expect(applied == f(3))
        #expect(tl.tracks[0].clips[0].source.start == f(26))
        #expect(tl.tracks[0].clips[0].duration == f(30))
    }

    @Test func slideNeighbourTrimsAtItsOwnSpeed() throws {
        var tl = try timeline([[clip(from: 0, frames: 60, speed: pct(200)), clip(start: 30, from: 100, frames: 30),
                                 clip(start: 60, from: 200, frames: 60, speed: pct(200))]])
        let id = tl.tracks[0].clips[1].id
        try tl.slide(id, by: f(5))
        let cs = tl.tracks[0].clips
        #expect(cs[0].duration == f(35) && cs[0].source.duration == f(70))
        #expect(cs[2].start == f(65) && cs[2].duration == f(25) && cs[2].source.start == f(210))
        #expect(cs[1].start == f(35))
    }

    @Test func rollMovesTheCutAtEachClipsSpeed() throws {
        var tl = try timeline([[clip(from: 0, frames: 60, speed: pct(200)), clip(start: 30, from: 100, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.roll(id, by: f(5))
        let cs = tl.tracks[0].clips
        #expect(cs[0].duration == f(35) && cs[1].start == f(35) && cs[1].duration == f(25) && cs[1].source.start == f(105))
    }

    @Test func liftAndExtractCutSpedUpClips() throws {
        var tl = try timeline([[clip(from: 0, frames: 90, speed: pct(300))]])      // 30 timeline frames
        let tid = tl.tracks[0].id
        try tl.extract(TimeRange(start: f(10), duration: f(10)), tracks: [tid])
        let cs = tl.tracks[0].clips
        #expect(cs.count == 2 && cs[0].duration == f(10) && cs[1].start == f(10) && cs[1].duration == f(10))
        #expect(cs[1].source.start == f(60))                                       // 20 timeline frames in, at 300 %
    }
}

@Suite struct SetSpeedTests {
    @Test func doubleSpeedHalvesTheLengthAndKeepsInOut() throws {
        var tl = try timeline([[clip(start: 10, from: 20, frames: 60)]])
        let id = tl.tracks[0].clips[0].id
        let change = try tl.setSpeed(id, to: pct(200))
        let c = tl.tracks[0].clips[0]
        #expect(change == f(-30) && c.duration == f(30) && c.start == f(10))
        #expect(c.source == TimeRange(start: f(20), duration: f(60)))
    }

    @Test func nonIntegerRatiosRoundTheLengthToFrames() throws {
        var tl = try timeline([[clip(from: 0, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(33.33))
        var c = tl.tracks[0].clips[0]
        #expect(c.duration == f(90))                                           // 30 / 0.3333 = 90.009 frames
        #expect(c.speed == pct(33.33) && c.source.duration == pct(33.33).scale(f(90)))
        try tl.setSpeed(id, to: pct(250))
        c = tl.tracks[0].clips[0]
        #expect(c.duration.frameIndex(frameDuration: fd) == 12 && c.duration == fd * 12)
    }

    @Test func setDurationComputesSpeed() throws {
        var tl = try timeline([[clip(from: 0, frames: 90)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setDuration(id, to: f(45))
        let c = tl.tracks[0].clips[0]
        #expect(c.speed == pct(200) && c.duration == f(45) && c.source.duration == f(90))
    }

    @Test func setDurationClampsToSpeedRange() throws {
        var tl = try timeline([[clip(from: 0, frames: 3000)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setDuration(id, to: f(3))                                       // would be 100000 %
        #expect(tl.tracks[0].clips[0].speed == .maximum)
    }

    @Test func withoutRippleAClipOnlyGrowsIntoFreeSpace() throws {
        var tl = try timeline([[clip(from: 0, frames: 30), clip(start: 50, from: 500, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(50))                                       // wants 60 frames, 50 are free
        let cs = tl.tracks[0].clips
        #expect(cs[0].duration == f(50) && cs[0].source.duration == f(25))     // truncated: shows less source
        #expect(cs[1].start == f(50))
    }

    @Test func withoutRippleShorteningLeavesAGap() throws {
        var tl = try timeline([[clip(from: 0, frames: 60), clip(start: 60, from: 500, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(200))
        #expect(tl.tracks[0].clips[1].start == f(60) && tl.tracks[0].clips[0].duration == f(30))
    }

    @Test func rippleShiftsTrailingClipsOnAllSyncTracks() throws {
        var tl = try timeline([[clip(from: 0, frames: 60), clip(start: 60, from: 500, frames: 30)],
                               [clip(start: 70, from: 0, frames: 20)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(50), ripple: true)                          // +60 frames
        #expect(tl.tracks[0].clips[0].duration == f(120))
        #expect(tl.tracks[0].clips[1].start == f(120) && tl.tracks[1].clips[0].start == f(130))
        try tl.setSpeed(id, to: pct(200), ripple: true)                         // back, -90 frames
        #expect(tl.tracks[0].clips[1].start == f(30) && tl.tracks[1].clips[0].start == f(40))
    }

    @Test func linkedPairChangesTogether() throws {
        let l = UUID()
        var tl = try timeline([[clip(from: 0, frames: 60, link: l)], [clip(from: 0, frames: 60, kind: .audio, link: l)]],
                              kinds: [.video, .audio])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(200), reversed: true, keepsPitch: false)
        for t in tl.tracks {
            let c = t.clips[0]
            #expect(c.speed == pct(200) && c.reversed && !c.keepsPitch && c.duration == f(30))
        }
    }

    @Test func reverseOnlyKeepsRangeAndLength() throws {
        var tl = try timeline([[clip(start: 4, from: 10, frames: 40)]])
        let id = tl.tracks[0].clips[0].id
        let change = try tl.setSpeed(id, to: .normal, reversed: true)
        let c = tl.tracks[0].clips[0]
        #expect(change == .zero && c.reversed && c.source == TimeRange(start: f(10), duration: f(40)) && c.start == f(4))
        try tl.setSpeed(id, to: .normal, reversed: false)
        #expect(!tl.tracks[0].clips[0].reversed)
    }

    @Test func slowingBeyondMediaEndStaysInsideTheMedia() throws {
        var tl = try timeline([[clip(from: 0, frames: 30, media: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(70))
        let c = tl.tracks[0].clips[0]
        #expect(c.source.end <= f(30))
    }

    @Test func refusesNestedGeneratorStillAndLocked() throws {
        var nested = clip(from: 0, frames: 30)
        nested.sequence = UUID()
        var tl = try timeline([[nested]])
        #expect(throws: EditError.speedUnsupported) { try tl.setSpeed(tl.tracks[0].clips[0].id, to: pct(200)) }
        var tl2 = try timeline([[clip(from: 0, frames: 30)]])
        tl2.tracks[0].isLocked = true
        #expect(throws: EditError.trackLocked) { try tl2.setSpeed(tl2.tracks[0].clips[0].id, to: pct(200)) }
    }
}

@Suite struct SpeedChangeTests {
    @Test func unlinkedSpeedKeepsTheLengthAndChangesTheSourceRange() throws {
        var tl = try timeline([[clip(from: 0, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(200), holdingDuration: true)
        let c = tl.tracks[0].clips[0]
        #expect(c.duration == f(30) && c.source.duration == f(60) && c.speed == pct(200))
    }

    @Test func unlinkedSlowdownIsLimitedByTheMedia() throws {
        var tl = try timeline([[clip(from: 0, frames: 30, media: 40)]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(200), holdingDuration: true)               // would need 60 frames of media
        #expect(tl.tracks[0].clips[0].source.end <= f(40) && tl.tracks[0].clips[0].duration == f(20))
    }

    @Test func changeAppliesToSeveralClipsAsOneEdit() throws {
        let l = UUID()
        var tl = try timeline([[clip(from: 0, frames: 60, link: l), clip(start: 100, from: 0, frames: 30)],
                               [clip(from: 0, frames: 60, kind: .audio, link: l)]], kinds: [.video, .audio])
        let ids = [tl.tracks[0].clips[0].id, tl.tracks[1].clips[0].id, tl.tracks[0].clips[1].id]
        try tl.apply(SpeedChange(speed: pct(200)), to: ids)
        #expect(tl.tracks[0].clips[0].duration == f(30) && tl.tracks[1].clips[0].duration == f(30)
                && tl.tracks[0].clips[1].duration == f(15))
        var nested = tl.tracks[0].clips[1]; nested.sequence = UUID()
        var broken = tl
        broken.tracks[0] = Track(kind: .video, clips: [tl.tracks[0].clips[0], nested])
        let before = broken
        #expect(throws: EditError.speedUnsupported) { try broken.apply(SpeedChange(speed: pct(50)), to: ids) }
        #expect(broken == before)
    }

    @Test func durationChangeGoesThroughApply() throws {
        var tl = try timeline([[clip(from: 0, frames: 90)]])
        try tl.apply(SpeedChange(duration: f(45), reversed: true), to: tl.tracks[0].clips[0].id)
        #expect(tl.tracks[0].clips[0].speed == pct(200) && tl.tracks[0].clips[0].reversed)
    }
}

@Suite struct RateStretchTests {
    @Test func tailDragChangesSpeedNotSource() throws {
        var tl = try timeline([[clip(from: 0, frames: 60)]])
        let id = tl.tracks[0].clips[0].id
        let applied = try tl.rateStretch(id, edge: .tail, by: f(-30))
        let c = tl.tracks[0].clips[0]
        #expect(applied == f(-30) && c.duration == f(30) && c.speed == pct(200) && c.source.duration == f(60))
    }

    @Test func headDragMovesStartAndKeepsTheEnd() throws {
        var tl = try timeline([[clip(start: 20, from: 0, frames: 60)]])
        let id = tl.tracks[0].clips[0].id
        try tl.rateStretch(id, edge: .head, by: f(-20))                          // head 20 frames earlier -> 80 frames
        let c = tl.tracks[0].clips[0]
        #expect(c.start == f(0) && c.timeline.end == f(80) && c.speed == pct(75))
    }

    @Test func growingStopsAtTheNeighbour() throws {
        var tl = try timeline([[clip(from: 0, frames: 30), clip(start: 45, from: 100, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        let applied = try tl.rateStretch(id, edge: .tail, by: f(100))
        #expect(applied == f(15) && tl.tracks[0].clips[0].duration == f(45) && tl.tracks[0].clips[1].start == f(45))
    }

    @Test func neverBelowOneFrameOrOutsideTheSpeedRange() throws {
        var tl = try timeline([[clip(from: 0, frames: 3000)]])
        let id = tl.tracks[0].clips[0].id
        try tl.rateStretch(id, edge: .tail, by: f(-2990))
        let c = tl.tracks[0].clips[0]
        #expect(c.speed == .maximum && c.duration >= fd)
    }
}

@Suite struct SpeedEvaluationTests {
    @Test func layerSourceTimeFollowsSpeedAndDirection() throws {
        var c = clip(start: 10, from: 20, frames: 60, speed: pct(200))
        let tl = try timeline([[c]])
        let layer = tl.videoLayers(at: f(15))[0]
        #expect(layer.sourceTime == f(30) && layer.localTime == f(5))
        c.reversed = true
        let tr = try timeline([[c]])
        #expect(tr.videoLayers(at: f(10))[0].sourceTime == f(78))                // 80 - 2 frames
    }

    @Test func audioSegmentCarriesSpeedAndSourceStart() throws {
        let c = clip(start: 10, from: 20, frames: 60, kind: .audio, speed: pct(200))
        let tl = try timeline([[c]], kinds: [.audio])
        let seg = tl.audioSegments(in: TimeRange(start: f(15), duration: f(5)))[0]
        #expect(seg.sourceStart == f(30) && seg.speed == pct(200) && !seg.reversed && seg.clipStart == f(10))
        var r = c; r.reversed = true
        let tr = try timeline([[r]], kinds: [.audio])
        let sr = tr.audioSegments(in: TimeRange(start: f(15), duration: f(5)))[0]
        #expect(sr.sourceStart == f(70) && sr.reversed)                         // 80 - 5 * 2
    }

    @Test func replaceClipRefusesTimingChanges() throws {
        var tl = try timeline([[clip(from: 0, frames: 30)]])
        var c = tl.tracks[0].clips[0]
        c.speed = pct(200)
        #expect(throws: EditError.collision) { try tl.replaceClip(c) }
    }
}

@Suite struct SpeedMigrationTests {
    @Test func v12FileLoadsAtNormalSpeed() throws {
        let pid = UUID(), tid = UUID(), cid = UUID(), mid = UUID()
        let json = #"""
        {"formatVersion":12,"project":{"id":"\#(pid)","name":"Old","media":[],"activeTimeline":"\#(tid)",
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},
        "tracks":[{"id":"\#(UUID())","kind":"video","clips":[{"id":"\#(cid)","name":"c","media":"\#(mid)","kind":"video",
        "source":{"start":{"value":0,"timescale":1},"duration":{"value":4,"timescale":1}},"start":{"value":0,"timescale":1}}]}]}]}}
        """#
        let p = try ProjectFile.decode(Data(json.utf8), migrations: ProjectFile.migrations)
        let c = p.timelines[0].tracks[0].clips[0]
        #expect(c.speed == .normal && !c.reversed && c.keepsPitch && c.duration == Time(4, 1))
    }

    @Test func v13FileLoadsAtNormalSpeed() throws {
        let tid = UUID()
        let json = #"""
        {"formatVersion":13,"project":{"id":"\#(UUID())","name":"Old","media":[],"activeTimeline":"\#(tid)",
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},
        "tracks":[{"id":"\#(UUID())","kind":"video","clips":[{"id":"\#(UUID())","name":"c","media":"\#(UUID())","kind":"video",
        "source":{"start":{"value":0,"timescale":1},"duration":{"value":4,"timescale":1}},"start":{"value":0,"timescale":1}}]}]}]}}
        """#
        let p = try ProjectFile.decode(Data(json.utf8), migrations: ProjectFile.migrations)
        #expect(p.timelines[0].tracks[0].clips[0].speed == .normal)
    }

    @Test func speedRoundTripsThroughTheFile() throws {
        var p = Project(name: "P")
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [Track(kind: .video)])
        try tl.tracks[0].overwrite(clip(from: 0, frames: 30, speed: pct(33.33), reversed: true))
        p.timelines = [tl]
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        let c = back.timelines[0].tracks[0].clips[0]
        #expect(c.speed == pct(33.33) && c.reversed)
    }
}
